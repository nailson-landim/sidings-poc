import Foundation
import simd
import Testing
@testable import PlaneKit

@Suite("Feature accumulator")
struct FeatureAccumulatorTests {
    static func accumulator(maxSamples: Int = 100, minSamples: Int = 5, zScore: Double = 2, maxIds: Int = 100_000)
        -> FeatureAccumulator
    {
        FeatureAccumulator(settings: CloudSettings(
            maxSamples: maxSamples, minSamples: minSamples, zScore: zScore, maxIds: maxIds
        ))
    }

    static func point(_ state: CloudState, _ id: UInt64) -> SIMD3<Float>? {
        state.ids.firstIndex(of: id).map { state.points[$0] }
    }

    @Test func aPointAppearsAtMinSamplesAsTheMean() {
        let acc = Self.accumulator(minSamples: 3)
        acc.add(ids: [7], points: [SIMD3(1, 0, 0)])
        acc.add(ids: [7], points: [SIMD3(2, 0, 0)])
        #expect(acc.state().count == 0)
        #expect(acc.trackedIds == 1)
        acc.add(ids: [7], points: [SIMD3(3, 0, 0)])
        let state = acc.state()
        #expect(state.ids == [7])
        #expect(state.points == [SIMD3(2, 0, 0)])
        #expect(state.samples == [3])
        #expect(acc.averagedCount == 1)
    }

    @Test func theFIFOKeepsTheLastMaxSamples() {
        let acc = Self.accumulator(maxSamples: 3, minSamples: 1)
        for x: Float in [100, 1, 2, 3] {
            acc.add(ids: [1], points: [SIMD3(x, 0, 0)])
        }
        // 100 fell out of the FIFO: the mean of 1, 2, 3.
        #expect(Self.point(acc.state(), 1) == SIMD3(2, 0, 0))
        #expect(acc.state().samples == [3])
    }

    @Test func theZScoreFilterDropsAnOutlier() {
        let acc = Self.accumulator(minSamples: 5, zScore: 1.5)
        for x: Float in [1, 1, 1, 1, 1, 1, 1, 1, 1, 11] {
            acc.add(ids: [1], points: [SIMD3(x, 0, 0)])
        }
        // Mean 2, sigma² = 9: 11 is 9 away (> 1.5 sigma = 4.5) and is left out; the ones are 1 away and stay.
        #expect(Self.point(acc.state(), 1) == SIMD3(1, 0, 0))
        #expect(acc.state().samples == [10])
    }

    @Test func aZScoreBelowOneThatRejectsEverySampleKeepsThemAll() {
        let acc = Self.accumulator(minSamples: 2, zScore: 0.5)
        acc.add(ids: [1], points: [SIMD3(0, 0, 0)])
        acc.add(ids: [1], points: [SIMD3(2, 0, 0)])
        #expect(Self.point(acc.state(), 1) == SIMD3(1, 0, 0))
    }

    @Test func theOldestByFirstSightingIsEvictedEvenIfSeenRecently() {
        let acc = Self.accumulator(minSamples: 1, maxIds: 2)
        acc.add(ids: [1], points: [SIMD3(1, 0, 0)])
        acc.add(ids: [2], points: [SIMD3(2, 0, 0)])
        acc.add(ids: [1], points: [SIMD3(1, 0, 0)])
        acc.add(ids: [3], points: [SIMD3(3, 0, 0)])
        #expect(Set(acc.state().ids) == [2, 3])
        #expect(acc.trackedIds == 2)
    }

    @Test func anIdEvictedLaterInTheSameFrameLosesThatFramesSample() {
        let acc = Self.accumulator(minSamples: 1, maxIds: 2)
        acc.add(ids: [1, 2], points: [SIMD3(1, 0, 0), SIMD3(2, 0, 0)])
        _ = acc.takeChanges()
        // Id 1 gets a sample, then 3 and 4 arrive: 1 then 2 are evicted, as CurvSurf's sequential loop does.
        acc.add(ids: [1, 3, 4], points: [SIMD3(9, 0, 0), SIMD3(3, 0, 0), SIMD3(4, 0, 0)])
        #expect(Set(acc.state().ids) == [3, 4])
        let changes = acc.takeChanges()
        #expect(changes.removed == [1, 2])
        #expect(changes.set.ids == [3, 4])
    }

    @Test func changesListRemovalsThenCurrentValues() {
        let acc = Self.accumulator(minSamples: 2, maxIds: 3)
        acc.add(ids: [1, 2], points: [SIMD3(1, 0, 0), SIMD3(2, 0, 0)])
        #expect(acc.takeChanges().isEmpty)  // nothing averaged yet
        acc.add(ids: [1, 2], points: [SIMD3(1, 0, 0), SIMD3(4, 0, 0)])
        let first = acc.takeChanges()
        #expect(first.removed.isEmpty)
        #expect(first.set.ids == [1, 2])
        #expect(first.set.points == [SIMD3(1, 0, 0), SIMD3(3, 0, 0)])
        #expect(first.set.samples == [2, 2])
        #expect(acc.takeChanges().isEmpty)
        acc.add(ids: [3, 4], points: [SIMD3(0, 0, 0), SIMD3(0, 0, 0)])
        let second = acc.takeChanges()
        #expect(second.removed == [1])  // 4 pushed out the oldest id
        #expect(second.set.ids.isEmpty)  // 3 and 4 have one sample each
    }

    @Test func clearForgetsEverything() {
        let acc = Self.accumulator(minSamples: 1)
        acc.add(ids: [1, 2], points: [SIMD3(1, 0, 0), SIMD3(2, 0, 0)])
        acc.clear()
        #expect(acc.state().count == 0)
        #expect(acc.trackedIds == 0)
        #expect(acc.averagedCount == 0)
        #expect(acc.takeChanges().isEmpty)
        #expect(acc.storageBytes == 0)
        acc.add(ids: [5], points: [SIMD3(5, 0, 0)])
        #expect(acc.state().ids == [5])
    }

    @Test func storageGrowsOneChunkAtATime() {
        let acc = Self.accumulator(maxSamples: 10, minSamples: 1)
        #expect(acc.storageBytes == 0)
        acc.add(ids: [1], points: [.zero])
        let chunk = acc.storageBytes
        #expect(chunk == FeatureAccumulator.chunkIds * (10 * 12 + 41))
        let many = (0..<UInt64(FeatureAccumulator.chunkIds)).map { $0 + 100 }
        acc.add(ids: many, points: Array(repeating: .zero, count: many.count))
        #expect(acc.storageBytes == 2 * chunk)
        #expect(acc.state().count == FeatureAccumulator.chunkIds + 1)
    }

    @Test func evictionReusesSlotsSoStorageStaysBounded() {
        let acc = Self.accumulator(maxSamples: 4, minSamples: 1, maxIds: 100)
        for frame in 0..<200 {
            let ids = (0..<10).map { UInt64(frame * 10 + $0) }
            acc.add(ids: ids, points: Array(repeating: SIMD3(1, 2, 3), count: 10))
        }
        #expect(acc.trackedIds == 100)
        #expect(acc.storageBytes == FeatureAccumulator.chunkIds * (4 * 12 + 41))
        #expect(Set(acc.state().ids) == Set((1900..<2000).map(UInt64.init)))
    }
}

@Suite("Cloud filter and gate")
struct CloudGateTests {
    static func camera(x: Double, yawDeg: Double = 0) -> simd_float4x4 {
        let yaw = yawDeg * .pi / 180
        // Looks down -Z turned by yaw about +Y; the -Z column is the view direction.
        let back = SIMD3<Float>(Float(-sin(yaw)), 0, Float(cos(yaw)))
        let right = SIMD3<Float>(Float(cos(yaw)), 0, Float(sin(yaw)))
        return simd_float4x4(columns: (
            SIMD4(right, 0), SIMD4(0, 1, 0, 0), SIMD4(back, 0), SIMD4(Float(x), 1.5, 0, 1)
        ))
    }

    static func accepted(_ gate: CloudGate, _ cameras: [simd_float4x4], moveM: Double = 0.03, turnDeg: Double = 3) -> [Int] {
        var frameGate = CloudFrameGate(CloudSettings(gate: gate, moveM: moveM, turnDeg: turnDeg))
        return cameras.indices.filter { frameGate.accept(camera: cameras[$0]) }
    }

    @Test func intendedWaitsForTheMove() {
        let cameras = (0..<10).map { Self.camera(x: Double($0) * 0.011) }
        #expect(Self.accepted(.intended, cameras) == [0, 3, 6, 9])
    }

    @Test func upstreamPassesSmallStepsAndBlocksBigOnes() {
        #expect(Self.accepted(.upstream, (0..<10).map { Self.camera(x: Double($0) * 0.011) }) == Array(0..<10))
        #expect(Self.accepted(.upstream, (0..<10).map { Self.camera(x: Double($0) * 0.05) }) == [0])
    }

    @Test func turningPassesAFrame() {
        let cameras = (0..<5).map { Self.camera(x: 0, yawDeg: Double($0) * 1.1) }
        #expect(Self.accepted(.intended, cameras) == [0, 3])
        #expect(Self.accepted(.off, cameras) == Array(0..<5))
    }

    @Test func theFilterDropsNearAndOptionallyFarPoints() {
        let eye = SIMD3<Double>(0, 0, 0)
        let points: [SIMD3<Float>] = [SIMD3(0, 0, -0.1), SIMD3(0, 0, -0.25), SIMD3(0, 0, -0.3), SIMD3(0, 0, -40)]
        let near = CloudPointFilter(CloudSettings())
        #expect(points.map { near.keeps($0, eye: eye) } == [false, false, true, true])
        let far = CloudPointFilter(CloudSettings(farCutM: 30))
        #expect(points.map { far.keeps($0, eye: eye) } == [false, false, true, false])
    }

    @Test func thePipelineSkipsLimitedTrackingWhenAsked() {
        let pipeline = CloudPipeline(settings: CloudSettings(normalTrackingOnly: true, minSamples: 1))
        let camera = Self.camera(x: 0)
        #expect(!pipeline.ingest(camera: camera, trackingNormal: false, points: [SIMD3(0, 1.5, -2)], ids: [1]))
        #expect(pipeline.accumulator.state().count == 0)
        #expect(pipeline.ingest(camera: camera, trackingNormal: true, points: [SIMD3(0, 1.5, -2)], ids: [1]))
        #expect(pipeline.accumulator.state().ids == [1])
        pipeline.clear()
        #expect(pipeline.accumulator.state().count == 0)
    }
}
