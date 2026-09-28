import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import PlaneKit

@Suite("Video writer")
struct VideoWriterTests {
    static let width = 256
    static let height = 192

    @Test func timestampsFollowFrameIndicesWithGaps() async throws {
        let folder = TempFolder()
        let url = folder.file("gaps.mov")
        let skip: Set<Int> = [3, 4, 17, 40, 41, 42, 77, 90, 101, 119]
        let writer = try await writeNumbered(to: url, count: 120, skip: skip)
        try await writer.finish()

        let probe = try await VideoProbe.read(url, fps: 60)
        #expect(probe.codec == kCMVideoCodecType_HEVC)
        #expect(probe.frames == (0..<120).filter { !skip.contains($0) })
        // Skipped images stretch keyframe gaps in time, but never past 30 encoded images.
        let keyPositions = probe.keyframes.compactMap { probe.frames.firstIndex(of: $0) }
        #expect(zip(keyPositions, keyPositions.dropFirst()).allSatisfy { $1 - $0 <= 30 })
    }

    @Test func keyframesAtMostHalfASecondApart() async throws {
        let folder = TempFolder()
        let url = folder.file("keys.mov")
        let writer = try await writeNumbered(to: url, count: 180, skip: [])
        try await writer.finish()

        let keys = try await VideoProbe.read(url, fps: 60).keyframes
        #expect(keys.first == 0)
        #expect(zip(keys, keys.dropFirst()).allSatisfy { $1 - $0 <= 30 })
    }

    @Test func frameNumbersSurviveEncoding() async throws {
        let folder = TempFolder()
        let url = folder.file("numbers.mov")
        let skip: Set<Int> = [10, 11, 12, 50]
        let writer = try await writeNumbered(to: url, count: 90, skip: skip)
        try await writer.finish()

        let decoded = try await VideoProbe.decodeNumbers(url, fps: 60)
        #expect(decoded.map(\.frame) == (0..<90).filter { !skip.contains($0) })
        #expect(decoded.allSatisfy { $0.frame == $0.number })
    }

    @Test func fullPoolSkipsInsteadOfBlocking() throws {
        let folder = TempFolder()
        var constants = RecorderConstants()
        constants.pixelPoolSize = 2
        let writer = try VideoWriter(
            url: folder.file("pool.mov"), width: Self.width, height: Self.height, constants: constants, realTime: false
        )
        defer { writer.cancel() }

        var held = [writer.makeBuffer(), writer.makeBuffer()].compactMap { $0 }
        #expect(held.count == 2)
        let start = ContinuousClock.now
        #expect(writer.makeBuffer() == nil)
        let source = TestFrames.numbered(0, width: Self.width, height: Self.height)
        #expect(writer.append(copyOf: source, frameIndex: 0) == .skipped(.poolExhausted))
        #expect(ContinuousClock.now - start < .milliseconds(100))

        held.removeLast()
        #expect(writer.makeBuffer() != nil)
    }

    /// Also covers a leading gap: the first image is frame 5, and the file still says so.
    @Test func outOfOrderFramesAreSkipped() async throws {
        let folder = TempFolder()
        let writer = try VideoWriter(
            url: folder.file("order.mov"), width: Self.width, height: Self.height, realTime: false
        )
        for (index, expected) in [(5, VideoAppendResult.appended), (5, .skipped(.outOfOrder)), (4, .skipped(.outOfOrder)), (6, .appended)] {
            let buffer = try await waitForBuffer(writer)
            TestFrames.draw(index, into: buffer)
            try await waitUntilReady(writer)
            #expect(writer.append(buffer, frameIndex: index) == expected)
        }
        try await writer.finish()
        let frames = try await VideoProbe.read(folder.file("order.mov"), fps: 60).frames
        #expect(frames == [5, 6])
    }

    @Test func copyPixelsCopiesEveryPlane() throws {
        let folder = TempFolder()
        let writer = try VideoWriter(
            url: folder.file("copy.mov"), width: Self.width, height: Self.height, realTime: false
        )
        defer { writer.cancel() }
        let source = TestFrames.numbered(0xBEEF, width: Self.width, height: Self.height)
        let destination = try #require(writer.makeBuffer())
        #expect(VideoWriter.copyPixels(from: source, to: destination))
        #expect(TestFrames.number(in: destination) == 0xBEEF)

        let wrongSize = TestFrames.numbered(1, width: 128, height: 96)
        #expect(!VideoWriter.copyPixels(from: wrongSize, to: destination))
    }

    /// SPEC S3 on the Mac: a copy of the movie taken while it's still being written opens and holds every frame up
    /// to its last whole fragment.
    @Test func unfinishedMovieReadsUpToLastFragment() async throws {
        let folder = TempFolder()
        let url = folder.file("live.mov")
        var constants = RecorderConstants()
        constants.fragmentIntervalS = 0.5
        let writer = try await writeNumbered(to: url, count: 240, skip: [], constants: constants)

        var snapshotFrames: [Int] = []
        let deadline = ContinuousClock.now + .seconds(10)
        while snapshotFrames.count < 120, ContinuousClock.now < deadline {
            let snapshot = folder.file("snapshot-\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: url, to: snapshot)
            snapshotFrames = (try? await VideoProbe.read(snapshot, fps: 60).frames) ?? []
            if snapshotFrames.count < 120 { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(snapshotFrames.count >= 120)
        #expect(snapshotFrames == Array(0..<snapshotFrames.count))

        try await writer.finish()
        #expect(try await VideoProbe.read(url, fps: 60).frames == Array(0..<240))
    }

    /// Writes the R2 spike input (SPEC §18 T2): 10 s at 1920 × 1440 with numbered frames and gaps, including a
    /// leading gap (the first image is frame 3), plus a manifest.
    /// Runs only with `PLANELAB_SPIKE_OUT=<dir> swift test --filter spikeVideo`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PLANELAB_SPIKE_OUT"] != nil))
    func spikeVideo() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PLANELAB_SPIKE_OUT"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("spike.mov")
        try? FileManager.default.removeItem(at: url)

        let count = 600
        let skip = Set((0..<count).filter { $0 % 37 == 5 }).union(0..<3).union(300..<310)
        let writer = try await writeNumbered(to: url, count: count, skip: skip, width: 1920, height: 1440)
        try await writer.finish()

        let manifest = SpikeManifest(fps: 60, width: 1920, height: 1440, count: count, skipped: skip.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("spike_frames.json"))
        #expect(try await VideoProbe.read(url, fps: 60).frames.count == count - skip.count)
    }
}

private struct SpikeManifest: Encodable {
    let fps: Int
    let width: Int
    let height: Int
    let count: Int
    let skipped: [Int]
}

/// Writes numbered frames `0..<count` except `skip`, waiting for the encoder so no image is dropped by accident.
/// Returns the writer unfinished, so a test can look at the file before `finish()`.
private func writeNumbered(
    to url: URL,
    count: Int,
    skip: Set<Int>,
    width: Int = VideoWriterTests.width,
    height: Int = VideoWriterTests.height,
    constants: RecorderConstants = RecorderConstants()
) async throws -> VideoWriter {
    let writer = try VideoWriter(url: url, width: width, height: height, constants: constants, realTime: false)
    for index in 0..<count where !skip.contains(index) {
        let buffer = try await waitForBuffer(writer)
        TestFrames.draw(index, into: buffer)
        try await waitUntilReady(writer)
        let result = writer.append(buffer, frameIndex: index)
        #expect(result == .appended, "frame \(index)")
    }
    return writer
}

private func waitForBuffer(_ writer: VideoWriter) async throws -> CVPixelBuffer {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if let buffer = writer.makeBuffer() { return buffer }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw WaitError.timedOut("pool buffer")
}

private func waitUntilReady(_ writer: VideoWriter) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !writer.isReady {
        guard ContinuousClock.now < deadline else { throw WaitError.timedOut("encoder input") }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private enum WaitError: Error {
    case timedOut(String)
}
