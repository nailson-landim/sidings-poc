import CoreVideo
import Foundation
import Testing
@testable import PlaneKit

@Suite("Session writer")
struct SessionWriterTests {
    static let frame = ContractFixture.records.frames[3]

    @Test func framesCommitInBatches() throws {
        let folder = TempFolder()
        let writer = try SessionWriter(bundle: folder.url, meta: [], videoSize: nil, autoCommit: false)
        for _ in 0..<10 { writer.enqueue(Self.frame, image: nil) }
        #expect(try committedFrames(folder) == 0)
        try writer.flush()
        #expect(try committedFrames(folder) == 10)
    }

    @Test func timerCommitsWithoutAFlush() async throws {
        let folder = TempFolder()
        var constants = RecorderConstants()
        constants.commitIntervalS = 0.05
        let writer = try SessionWriter(bundle: folder.url, meta: [], videoSize: nil, constants: constants)
        for _ in 0..<5 { writer.enqueue(Self.frame, image: nil) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(try committedFrames(folder) == 5)
        _ = try await writer.finish(stopReason: .user)
    }

    @Test func indicesHaveNoHolesAndStampTheLastFrame() throws {
        let folder = TempFolder()
        let writer = try SessionWriter(bundle: folder.url, meta: [], videoSize: nil, autoCommit: false)
        #expect(writer.lastFrameIndex == -1)
        let indices = (0..<4).compactMap { _ in writer.enqueue(Self.frame, image: nil) }
        #expect(indices == [0, 1, 2, 3])
        #expect(writer.lastFrameIndex == 3)
        writer.enqueue(EventRecord(frameIndex: writer.lastFrameIndex, kind: "mark", detail: "here"))
        try writer.flush()
        let db = try SessionDatabase.open(at: folder.file("session.sqlite"))
        #expect(try db.frames().map(\.index) == [0, 1, 2, 3])
        #expect(try db.events() == [EventRecord(frameIndex: 3, kind: "mark", detail: "here")])
    }

    /// SPEC §4 R5: a stalled disk never blocks the capture thread; whole frames are dropped and counted.
    @Test func stalledQueueDropsWholeFramesWithoutBlocking() async throws {
        let folder = TempFolder()
        var constants = RecorderConstants()
        constants.writeQueueFrames = 20
        let writer = try SessionWriter(
            bundle: folder.url, meta: [], videoSize: nil, constants: constants, autoCommit: false
        )
        writer.suspendForTesting()
        let start = ContinuousClock.now
        let accepted = (0..<100).compactMap { _ in writer.enqueue(Self.frame, image: nil) }
        let elapsed = ContinuousClock.now - start
        writer.resumeForTesting()

        #expect(accepted == Array(0..<20))
        #expect(writer.droppedFrames == 80)
        #expect(elapsed < .milliseconds(50))

        // Once the queue drains, frames are accepted again.
        try writer.flush()
        #expect(writer.enqueue(Self.frame, image: nil) == 20)

        let summary = try await writer.finish(stopReason: .user)
        #expect(summary.framesLogged == 21)
        #expect(summary.framesDropped == 80)
        let meta = try SessionDatabase.open(at: folder.file("session.sqlite")).meta()
        #expect(meta["frames_logged"] == "21")
        #expect(meta["frames_dropped"] == "80")
    }

    /// SPEC S3 for the database: a writer that never finished (a killed app) leaves every committed batch readable.
    @Test func unfinishedSessionKeepsCommittedBatches() throws {
        let folder = TempFolder()
        let writer = try SessionWriter(bundle: folder.url, meta: [], videoSize: nil, autoCommit: false)
        for _ in 0..<30 { writer.enqueue(Self.frame, image: nil) }
        try writer.flush()
        for _ in 0..<5 { writer.enqueue(Self.frame, image: nil) }

        // Copy the files as they are on disk mid-recording, as a kill would leave them.
        let snapshot = TempFolder()
        for name in ["session.sqlite", "session.sqlite-wal", "session.sqlite-shm"] {
            try? FileManager.default.copyItem(at: folder.file(name), to: snapshot.file(name))
        }
        let db = try SessionDatabase.open(at: snapshot.file("session.sqlite"), readOnly: false)
        #expect(try db.frames().count == 30)
        withExtendedLifetime(writer) {}
    }

    @Test func finishWritesCountersVideoAndOneFile() async throws {
        let folder = TempFolder()
        let writer = try SessionWriter(
            bundle: folder.url, meta: [("device_model", "test")], videoSize: (256, 192), realTimeVideo: false
        )
        var expectedImages: [Int] = []
        for i in 0..<12 {
            // Frames 0 and 7 arrive without an image, as when the pool is full on the capture side.
            var box: PixelBufferBox?
            if i != 0, i != 7 {
                let buffer = try await waitForBufferFrom(writer)
                TestFrames.draw(i, into: buffer)
                box = PixelBufferBox(buffer)
                expectedImages.append(i)
            }
            #expect(writer.enqueue(Self.frame, image: box) == i)
            try await Task.sleep(for: .milliseconds(5))
        }
        let summary = try await writer.finish(stopReason: .user)

        // Every frame either has an image or a counted reason. Frames 0 and 7 had none on the capture side
        // (`no_buffer`, T10); the encoder may also refuse a frame now and then (`notReady`) when fed this fast.
        #expect(summary.framesLogged == 12)
        #expect(summary.framesWithImage + summary.imageSkips.values.reduce(0, +) == 12)
        #expect(summary.imageSkips["no_buffer"] == 2)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()
        #expect(files == ["session.sqlite", "video.mov"])

        let db = try SessionDatabase.open(at: folder.file("session.sqlite"))
        let meta = try db.meta()
        #expect(meta["device_model"] == "test")
        #expect(meta["const.pixelPoolSize"] == "6")
        #expect(meta["started_at"] != nil && meta["stopped_at"] != nil)
        #expect(meta["stop_reason"] == "user")
        let withImage = try db.frames().filter(\.hasImage).map(\.index)
        #expect(meta["frames_with_image"] == "\(withImage.count)")
        #expect(withImage.count == summary.framesWithImage)
        #expect(Set(withImage).isSubset(of: expectedImages))
        for (reason, count) in summary.imageSkips {
            #expect(meta["image_skip.\(reason)"] == "\(count)")
        }
        let skips = try db.events().filter { $0.kind == "image_skip" }
        #expect(skips.first == EventRecord(frameIndex: 0, kind: "image_skip", detail: "no_buffer"))
        #expect(try await VideoProbe.read(folder.file("video.mov"), fps: 60).frames == withImage)
    }

    @Test func nothingIsAcceptedAfterFinish() async throws {
        let folder = TempFolder()
        let writer = try SessionWriter(bundle: folder.url, meta: [], videoSize: nil, autoCommit: false)
        writer.enqueue(Self.frame, image: nil)
        _ = try await writer.finish(stopReason: .reset)
        #expect(writer.enqueue(Self.frame, image: nil) == nil)
        #expect(try SessionDatabase.open(at: folder.file("session.sqlite")).meta()["stop_reason"] == "reset")
    }

    private func committedFrames(_ folder: borrowing TempFolder) throws -> Int {
        try SessionDatabase.open(at: folder.file("session.sqlite")).frames().count
    }

    private func waitForBufferFrom(_ writer: SessionWriter) async throws -> CVPixelBuffer {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let buffer = writer.makeImageBuffer() { return buffer }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw WaitError.timedOut("pool buffer")
    }
}
