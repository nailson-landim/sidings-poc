import Foundation
import simd
import Testing
@testable import PlaneKit

/// `session-format/fixtures/cloud/recorded.planelab`: the golden frames recorded by the real recorder path
/// (`SessionWriter` + `LiveCloud`), so Plane Lab can check that its recompute equals the phone's cloud (SPEC T30).
/// Settings that evict and wrap the FIFO, with a full copy every 2 rows. Regenerate with
/// `PLANELAB_WRITE_FIXTURES=1 swift test --filter writeRecordedCloudFixture`.
@Suite("Recorded cloud fixture", .serialized)
struct RecordedCloudFixtureTests {
    static let bundle = repositoryRoot.appendingPathComponent("session-format/fixtures/cloud/recorded.planelab")

    static var constants: RecorderConstants {
        var constants = RecorderConstants()
        constants.cloudMaxSamples = 4
        constants.cloudMinSamples = 3
        constants.cloudZScore = 1.2
        constants.cloudMaxIds = 50
        constants.cloudFullEvery = 2
        return constants
    }

    /// A 1920 × 1440 camera, like the iPhone's.
    static let intrinsics = simd_float3x3(SIMD3(1500.5, 0, 0), SIMD3(0, 1500.5, 0), SIMD3(960.25, 720.75, 1))

    /// Records the golden frames into `bundle` and returns its cloud rows.
    static func record(to bundle: URL) async throws -> [CloudRecord] {
        try? FileManager.default.removeItem(at: bundle)
        let constants = Self.constants
        let writer = try SessionWriter(
            bundle: bundle,
            meta: [
                ("device_model", "fixture"), ("app_version", "fixture"), ("video_width", "1920"),
                ("video_height", "1440"), ("video_fps", "60"),
            ],
            videoSize: nil,
            constants: constants, autoCommit: false
        )
        let cloud = LiveCloud(settings: constants.cloudSettings)
        cloud.startRecording(snapshotEvery: constants.cloudSnapshotEvery, fullEvery: constants.cloudFullEvery) { row in
            writer.enqueue(row)
        }
        for frame in CloudGoldenTests.golden.frames {
            let record = FrameRecord(
                index: 0, timestamp: 1000 + Double(frame.idx) / 16, hasImage: false,
                tracking: frame.tracking == 2 ? .normal : .limited, trackingReason: .none, mapping: 2,
                camera: CloudGoldenTests.camera(frame.camera), intrinsics: Self.intrinsics, exposure: 0.0078125,
                thermal: 0, points: CloudGoldenTests.points(frame.points), pointIDs: frame.ids
            )
            let index = writer.enqueue(record, image: nil)
            cloud.ingest(
                camera: record.camera, trackingNormal: record.tracking == .normal, points: record.points,
                ids: record.pointIDs, recordIndex: index
            )
        }
        let summary = cloud.stopRecording(lastIndex: writer.lastFrameIndex)
        _ = try await writer.finish(stopReason: .user, meta: summary.metaRows)
        return try SessionDatabase.open(at: bundle.appendingPathComponent("session.sqlite")).clouds()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PLANELAB_WRITE_FIXTURES"] != nil))
    func writeRecordedCloudFixture() async throws {
        _ = try await Self.record(to: Self.bundle)
    }

    @Test func theCommittedFixtureIsWhatTheRecorderWritesToday() async throws {
        let folder = TempFolder()
        let fresh = try await Self.record(to: folder.url.appendingPathComponent("recorded.planelab"))
        let db = try SessionDatabase.open(at: Self.bundle.appendingPathComponent("session.sqlite"))
        #expect(try db.clouds() == fresh)
        #expect(fresh.map(\.frameIndex) == [5, 11, 17, 23, 29])
        #expect(fresh.contains { !$0.removed.isEmpty })
        let meta = try db.meta()
        #expect(meta["cloud_rows"] == "5")
        #expect(meta["const.cloudMaxIds"] == "50")
    }
}
