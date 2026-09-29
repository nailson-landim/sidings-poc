import Foundation
import simd
import Testing
@testable import PlaneKit

@Suite("Live cloud")
struct LiveCloudTests {
    static func feed(_ cloud: LiveCloud, frames: [CloudGoldenTests.Golden.Frame]) {
        for frame in frames {
            cloud.ingest(
                camera: CloudGoldenTests.camera(frame.camera), trackingNormal: frame.tracking == 2,
                points: CloudGoldenTests.points(frame.points), ids: frame.ids
            )
        }
    }

    static func sorted(_ state: CloudState) -> [UInt64: SIMD3<Float>] {
        Dictionary(uniqueKeysWithValues: zip(state.ids, state.points))
    }

    @Test func itGivesThePipelinesCloud() {
        let frames = CloudGoldenTests.golden.frames
        let settings = CloudSettings()
        let cloud = LiveCloud(settings: settings)
        Self.feed(cloud, frames: frames)
        cloud.drain()
        let pipeline = CloudPipeline(settings: settings)
        for frame in frames {
            pipeline.ingest(
                camera: CloudGoldenTests.camera(frame.camera), trackingNormal: frame.tracking == 2,
                points: CloudGoldenTests.points(frame.points), ids: frame.ids
            )
        }
        let snapshot = cloud.latest()
        #expect(Self.sorted(snapshot.state) == Self.sorted(pipeline.accumulator.state()))
        #expect(snapshot.state.count == 60)
        #expect(snapshot.trackedIds == 60)
        #expect(snapshot.storageBytes > 0)
        #expect(snapshot.framesDropped == 0)
    }

    @Test func itPublishesEveryFewFrames() {
        let frames = Array(CloudGoldenTests.golden.frames.prefix(12))
        let cloud = LiveCloud(settings: CloudSettings(minSamples: 1), publishEvery: 6)
        Self.feed(cloud, frames: Array(frames.prefix(5)))
        cloud.waitForTesting()
        #expect(cloud.latest().version == 0)
        Self.feed(cloud, frames: [frames[5]])
        cloud.waitForTesting()
        #expect(cloud.latest().version == 1)
        #expect(cloud.latest().state.count > 0)
    }

    @Test func aStalledQueueDropsFramesWithoutBlocking() {
        let frame = CloudGoldenTests.golden.frames[0]
        let cloud = LiveCloud(settings: CloudSettings(minSamples: 1), maxBacklog: 10)
        cloud.suspendForTesting()
        let start = Date()
        Self.feed(cloud, frames: Array(repeating: frame, count: 15))
        #expect(Date().timeIntervalSince(start) < 0.05)
        cloud.resumeForTesting()
        cloud.drain()
        #expect(cloud.latest().framesDropped == 5)
    }

    @Test func clearEmptiesTheCloud() {
        let cloud = LiveCloud(settings: CloudSettings(minSamples: 1))
        Self.feed(cloud, frames: Array(CloudGoldenTests.golden.frames.prefix(3)))
        cloud.drain()
        #expect(cloud.latest().state.count > 0)
        cloud.clear()
        cloud.waitForTesting()
        #expect(cloud.latest().state.count == 0)
        #expect(cloud.latest().trackedIds == 0)
    }
}

@Suite("Cloud mesh")
struct CloudMeshTests {
    static let camera = matrix_identity_float4x4  // at the origin, looking down -Z

    @Test func bandsFollowTheSampleCount() {
        #expect([1, 9, 10, 49, 50, 100].map { CloudMesh.band(of: $0) } == [0, 0, 1, 1, 2, 2])
        let state = CloudState(
            ids: [1, 2, 3, 4], points: Array(repeating: SIMD3(0, 0, -2), count: 4), samples: [5, 20, 60, 70]
        )
        let bands = CloudMesh.billboards(state, camera: Self.camera, size: 0.01)
        #expect(bands.map(\.count) == [1, 1, 2])
        #expect(bands.map(\.indices.count) == [6, 6, 12])
        #expect(bands[2].indices == [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7])
    }

    @Test func squaresGrowWithDistanceAndFaceTheCamera() {
        let state = CloudState(ids: [1, 2], points: [SIMD3(0, 0, -1), SIMD3(3, 0, -10)], samples: [5, 5])
        let band = CloudMesh.billboards(state, camera: Self.camera, size: 0.01)[0]
        let near = band.positions[0..<4]
        let far = band.positions[4..<8]
        #expect(abs(simd_distance(near[near.startIndex], near[near.startIndex + 1]) - 0.02) < 1e-6)
        let farDistance = simd_length(SIMD3<Float>(3, 0, -10))
        #expect(abs(simd_distance(far[far.startIndex], far[far.startIndex + 1]) - 0.02 * farDistance) < 1e-5)
        // Counter-clockwise from the camera: the triangle normal points back at the eye (+Z here).
        let p = Array(near)
        let normal = simd_cross(p[1] - p[0], p[2] - p[0])
        #expect(normal.z > 0)
    }

    @Test func aLimitStridesThePoints() {
        let count = 1000
        let state = CloudState(
            ids: (0..<UInt64(count)).map { $0 }, points: Array(repeating: SIMD3(0, 0, -2), count: count),
            samples: Array(repeating: 60, count: count)
        )
        let bands = CloudMesh.billboards(state, camera: Self.camera, size: 0.01, limit: 300)
        #expect(bands[2].count == 250)  // stride 4
        #expect(CloudMesh.billboards(state, camera: Self.camera, size: 0.01)[2].count == count)
    }
}
