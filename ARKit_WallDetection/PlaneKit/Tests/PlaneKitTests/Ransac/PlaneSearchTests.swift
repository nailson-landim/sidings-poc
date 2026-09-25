import Foundation
import simd
import Testing
@testable import PlaneKit

/// X2.1: the pure RANSAC search on synthetic scenes (`../../../tasks/todo.md`).
@Suite("X2 plane search")
struct PlaneSearchTests {
    static func search(
        _ cloud: CloudState, band: Float, maxPlanes: Int = 4, seed: UInt64 = 1, settings: SurfaceSettings = .ransac
    ) -> (planes: [PlaneCandidate], stats: SearchStats) {
        var rng = SearchRNG(seed: seed)
        var stats = SearchStats()
        let planes = PlaneSearch.run(
            points: cloud.points, band: [Float](repeating: band, count: cloud.count), samples: cloud.samples,
            active: [Bool](repeating: true, count: cloud.count), maxPlanes: maxPlanes, settings: settings, rng: &rng,
            stats: &stats
        )
        return (planes, stats)
    }

    static func cornerCloud(noise: Float = 0.02) -> CloudState {
        var rng = SplitMix64(state: 11)
        return SyntheticScene.corner().cloud(noise: noise, rng: &rng)
    }

    @Test func aCornerGivesTwoVerticalPlanesAtRightAngles() throws {
        let (planes, stats) = Self.search(Self.cornerCloud(), band: 0.06, maxPlanes: 2)
        #expect(planes.count == 2)
        let facing = try #require(planes.first { abs($0.normal.z) > 0.9 })
        let side = try #require(planes.first { abs($0.normal.x) > 0.9 })
        #expect(degrees(facing.normal, SIMD3(0, 0, 1)) < 2)
        #expect(degrees(side.normal, SIMD3(1, 0, 0)) < 2)
        #expect(abs(facing.center.z + 4.25) < 0.02)
        #expect(abs(side.center.x - 1.25) < 0.02)
        #expect(planes.allSatisfy { abs($0.normal.y) < 1e-6 })
        #expect(planes.allSatisfy { $0.rmsError < 0.05 })
        #expect(stats.planes == 2 && stats.hypotheses > 0 && stats.fullScores <= stats.hypotheses)
    }

    @Test func aFloorGivesOneExactlyHorizontalPlane() throws {
        let floor = SyntheticScene([
            Patch(origin: SIMD3(-3, -1.5, -8), u: SIMD3(1, 0, 0), v: SIMD3(0, 0, 1), width: 6, height: 8, spacing: 0.15)
        ])
        var rng = SplitMix64(state: 3)
        let (planes, _) = Self.search(floor.cloud(noise: 0.02, rng: &rng), band: 0.06, maxPlanes: 1)
        let plane = try #require(planes.first)
        #expect(plane.normal == SIMD3(0, 1, 0))
        #expect(abs(plane.center.y + 1.5) < 0.02)
        #expect(plane.isHorizontal)
    }

    @Test func aTiltedSurfaceNeverGivesATiltedPlane() {
        // A 40° roof: only verticals and horizontals are allowed, so whatever is found is one of those.
        let tilt = SIMD3<Float>(0, cos(.pi / 4.5), sin(.pi / 4.5))
        let roof = SyntheticScene([Patch(origin: SIMD3(-2, 0, -6), u: SIMD3(1, 0, 0), v: tilt, width: 4, height: 4)])
        var rng = SplitMix64(state: 5)
        let (planes, _) = Self.search(roof.cloud(noise: 0.01, rng: &rng), band: 0.05)
        for plane in planes {
            #expect(plane.normal == SIMD3(0, 1, 0) || abs(plane.normal.y) < 1e-6)
        }
    }

    @Test func aThickSlabIsOnePlaneWithTheWideBand() throws {
        // A wall whose depth error is 30 cm thick, like the real cloud at 4–7 m (X1 verdict).
        var rng = SplitMix64(state: 9)
        let wall = SyntheticScene([
            Patch(origin: SIMD3(-3, -1.5, -5), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 6, height: 3, spacing: 0.08)
        ])
        var cloud = wall.cloud(noise: 0, rng: &rng)
        cloud.points = cloud.points.map { $0 + SIMD3(0, 0, Float.random(in: -0.15...0.15, using: &rng)) }
        let (planes, _) = Self.search(cloud, band: 0.2, maxPlanes: 1)
        let plane = try #require(planes.first)
        #expect(plane.inliers.count > Int(0.95 * Float(cloud.count)))
        #expect(degrees(plane.normal, SIMD3(0, 0, 1)) < 3)
    }

    @Test func aSeedGivesTheSamePlanes() {
        let cloud = Self.cornerCloud()
        let a = Self.search(cloud, band: 0.06, seed: 4)
        let b = Self.search(cloud, band: 0.06, seed: 4)
        #expect(a.planes == b.planes)
        #expect(a.stats == b.stats)
    }

    @Test func tooFewPointsGiveNothing() {
        var cloud = Self.cornerCloud()
        cloud = CloudState(
            ids: Array(cloud.ids.prefix(20)), points: Array(cloud.points.prefix(20)),
            samples: Array(cloud.samples.prefix(20))
        )
        #expect(Self.search(cloud, band: 0.06).planes.isEmpty)
    }

    @Test func claimedPointsAreIgnored() {
        let cloud = Self.cornerCloud()
        var rng = SearchRNG(seed: 1)
        var stats = SearchStats()
        // Hide the facing wall (z ≈ −4.25 and x < 1.25): only the side wall is left to find.
        let active = cloud.points.map { !($0.z < -4.0 && $0.x < 1.2) }
        let planes = PlaneSearch.run(
            points: cloud.points, band: [Float](repeating: 0.06, count: cloud.count), samples: cloud.samples,
            active: active, maxPlanes: 3, settings: .ransac, rng: &rng, stats: &stats
        )
        #expect(planes.count == 1)
        #expect(planes.first.map { abs($0.normal.x) > 0.9 } == true)
    }
}

/// The Mac baseline for the phone's HUD numbers: a facade-sized cloud of about 11k points (the real one in
/// `20261001-142809` had 10,912). Run `swift test --filter searchSpeed` to see the timings in the log.
@Suite("X2 search speed")
struct PlaneSearchSpeedTests {
    static func facadeCloud() -> CloudState {
        var rng = SplitMix64(state: 21)
        let scene = SyntheticScene([
            Patch(origin: SIMD3(-9, -1.5, -6), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 18, height: 8, spacing: 0.12),
            Patch(origin: SIMD3(-9, -1.5, -6), u: SIMD3(1, 0, 0), v: SIMD3(0, 0, 1), width: 18, height: 8, spacing: 0.2),
            Patch(origin: SIMD3(-4, -1.5, -2), u: SIMD3(0, 0, 1), v: SIMD3(0, 1, 0), width: 4, height: 3, spacing: 0.1),
        ])
        var cloud = scene.cloud(noise: 0.03, rng: &rng)
        cloud.points = cloud.points.map { $0 + SIMD3(0, 0, Float.random(in: -0.1...0.1, using: &rng)) }
        return cloud
    }

    @Test func searchSpeed() {
        let cloud = Self.facadeCloud()
        let scanner = RansacScanner()
        let result = scanner.benchmark(cloud: cloud, camera: camera(), runs: 10)!
        let line = String(
            format: "RANSAC search speed (Mac): %d points, %d planes, median %.1f ms, p95 %.1f ms, max %.1f ms, %d hypotheses, %.1f M point tests",
            result.points, result.planes, result.median, result.p95, result.max, result.hypotheses,
            Double(result.pointTests) / 1e6
        )
        print(line)
        #expect(result.planes >= 3)
        #expect(result.median < 500)
    }
}
