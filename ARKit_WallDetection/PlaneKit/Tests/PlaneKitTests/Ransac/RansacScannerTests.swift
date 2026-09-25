import Foundation
import simd
import Synchronization
import Testing
@testable import PlaneKit

/// X2.2: the RANSAC round on synthetic scenes (`../../../tasks/todo.md`).
@Suite("X2 RANSAC scanner")
struct RansacScannerTests {
    /// Rounds on fresh noise each time; the camera sits at the origin looking down -Z.
    static func run(
        _ scene: SyntheticScene, noise: Float, rounds: Int, settings: SurfaceSettings = .ransac,
        slab: Float = 0, extra: [SIMD3<Float>] = []
    ) throws -> (scanner: RansacScanner, reports: [SurfaceScanner.Report]) {
        let scanner = RansacScanner(settings: settings)
        var rng = SplitMix64(state: 7)
        var reports: [SurfaceScanner.Report] = []
        for _ in 0..<rounds {
            var cloud = scene.cloud(noise: noise, rng: &rng)
            if slab > 0 {
                cloud.points = cloud.points.map { $0 + SIMD3(0, 0, Float.random(in: -slab...slab, using: &rng)) }
            }
            for point in extra {
                cloud.ids.append(UInt64(cloud.ids.count + 1))
                cloud.points.append(point)
                cloud.samples.append(20)
            }
            reports.append(try scanner.round(cloud: cloud, camera: camera()))
        }
        return (scanner, reports)
    }

    @Test func aCornerGivesTwoStablePlanesAtRightAngles() throws {
        let (scanner, reports) = try Self.run(.corner(), noise: 0.02, rounds: 50)
        let tracks = scanner.tracker.ordered
        #expect(tracks.count == 2)
        #expect(tracks.allSatisfy { $0.state == .confirmed && abs($0.normal.y) < 1e-3 })
        let adds = reports.flatMap(\.events).count { if case .add = $0 { true } else { false } }
        #expect(adds == 2)
        let others = reports.flatMap(\.events).count {
            switch $0 {
            case .merge, .drop, .stale: true
            default: false
            }
        }
        #expect(others == 0)
        let facing = try #require(tracks.first { abs($0.normal.z) > 0.9 })
        let side = try #require(tracks.first { abs($0.normal.x) > 0.9 })
        #expect(abs(degrees(facing.normal, side.normal) - 90) < 3)
        #expect(abs(facing.center.z + 4.25) < 0.03)
        #expect(abs(side.center.x - 1.25) < 0.03)
    }

    @Test func theExtentIsCloseToTheLattice() throws {
        let (scanner, _) = try Self.run(.corner(), noise: 0.02, rounds: 10)
        let facing = try #require(scanner.tracker.ordered.first { abs($0.normal.z) > 0.9 })
        let (w, h) = (max(facing.width, facing.height), min(facing.width, facing.height))
        #expect(abs(w - 4) / 4 < 0.2 && abs(h - 3) / 3 < 0.2)
    }

    @Test func coplanarPointsFarAwayDoNotInflateTheWall() throws {
        // A 4 m wall at z = −4.25, plus a lone cluster of 60 coplanar points 20 m to its right.
        let wall = SyntheticScene([
            Patch(origin: SIMD3(-2, -1.5, -4.25), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 4, height: 3)
        ])
        var cluster: [SIMD3<Float>] = []
        for i in 0..<10 { for j in 0..<6 { cluster.append(SIMD3(20 + 0.1 * Float(i), -1 + 0.1 * Float(j), -4.25)) } }
        let (scanner, _) = try Self.run(wall, noise: 0.01, rounds: 6, extra: cluster)
        let tracks = scanner.tracker.ordered
        let big = try #require(tracks.max { $0.width * $0.height < $1.width * $1.height })
        #expect(max(big.width, big.height) < 5)
    }

    @Test func aThickWallIsOneTrack() throws {
        // A 30 cm deep slab, like the real cloud at 4–7 m: slices must end up as one plane.
        let wall = SyntheticScene([
            Patch(origin: SIMD3(-3, -1.5, -5), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 6, height: 3, spacing: 0.08)
        ])
        let (scanner, _) = try Self.run(wall, noise: 0, rounds: 20, slab: 0.15)
        let tracks = scanner.tracker.ordered.filter { $0.state != .tentative }
        #expect(tracks.count == 1)
        #expect(degrees(try #require(tracks.first).normal, SIMD3(0, 0, 1)) < 3)
    }

    @Test func aFloorAndAWallStayTwoTracks() throws {
        let scene = SyntheticScene([
            Patch(origin: SIMD3(-2, -1.5, -5), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 4, height: 3),
            Patch(origin: SIMD3(-2, -1.5, -5), u: SIMD3(1, 0, 0), v: SIMD3(0, 0, 1), width: 4, height: 4.5),
        ])
        let (scanner, _) = try Self.run(scene, noise: 0.015, rounds: 12)
        let tracks = scanner.tracker.ordered
        #expect(tracks.count == 2)
        #expect(tracks.contains { $0.normal.y.magnitude == 1 })
        #expect(tracks.contains { abs($0.normal.y) < 1e-3 })
    }

    @Test func knownPlanesAreRefittedWithoutASearch() throws {
        let (_, reports) = try Self.run(.corner(), noise: 0.02, rounds: 12)
        let late = reports.suffix(6)
        #expect(late.allSatisfy { $0.refits == 2 && $0.refitsMatched == 2 })
        // Discovery is rare once everything is claimed: at most one search in those rounds, and no new plane.
        #expect(late.count { $0.searched } <= 2)
        #expect(late.allSatisfy { $0.seedsAccepted == 0 })
        #expect(reports.first!.searched)
    }

    @Test func roundsCountWhatTheyCost() throws {
        let (_, reports) = try Self.run(.corner(), noise: 0.02, rounds: 3)
        let first = reports[0]
        #expect(first.hypotheses > 0 && first.pointTests > 0 && first.planesFound >= 2)
        #expect(first.milliseconds >= first.searchMilliseconds)
        #expect(first.searchMilliseconds > 0)
    }

    @Test func aWallThatLeavesTheViewGoesStaleNotMissing() throws {
        var (scanner, _) = try Self.run(.corner(), noise: 0.02, rounds: 8)
        var rng = SplitMix64(state: 13)
        // Look the other way: nothing is in view, the tracks are kept.
        var back = matrix_identity_float4x4
        back.columns.0 = SIMD4(-1, 0, 0, 0)
        back.columns.2 = SIMD4(0, 0, -1, 0)
        for _ in 0..<12 { _ = try scanner.round(cloud: SyntheticScene.corner().cloud(noise: 0.02, rng: &rng), camera: back) }
        #expect(scanner.tracker.ordered.count == 2)
    }

    @Test func recordedRoundsCarryTheirCost() throws {
        let live = LiveSurfaces(engine: RansacScanner())
        let rows = Mutex<[SurfaceRoundRecord]>([])
        live.startRecording(sink: { _ in }, roundSink: { row in rows.withLock { $0.append(row) } })
        var rng = SplitMix64(state: 1)
        let cloud = SyntheticScene.corner().cloud(noise: 0.02, rng: &rng)
        for index in 0..<4 {
            live.submit(cloud: cloud, camera: camera(), recordIndex: 10 * index)
            live.drain()
        }
        let summary = live.stopRecording()
        let recorded = rows.withLock { $0 }
        #expect(recorded.count == 4 && summary.rounds == 4)
        #expect(recorded.map(\.frameIndex) == [0, 10, 20, 30])
        #expect(recorded.map(\.round) == [1, 2, 3, 4])
        let first = recorded[0]
        #expect(first.searched && first.hypotheses > 0 && first.totalMilliseconds > 0 && first.tracks == 2)
        #expect(recorded.allSatisfy { $0.points == cloud.count && (0...3).contains($0.thermal) })
        #expect(summary.maxMilliseconds >= summary.p95Milliseconds && summary.p95Milliseconds >= summary.medianMilliseconds)
        #expect(summary.metaRows.contains { $0.key == "surface_rounds" && $0.value == "4" })
    }

    @Test func benchmarkTimesTheSearchAlone() throws {
        var rng = SplitMix64(state: 1)
        let cloud = SyntheticScene.corner().cloud(noise: 0.02, rng: &rng)
        let scanner = RansacScanner()
        let result = try #require(scanner.benchmark(cloud: cloud, camera: camera(), runs: 5))
        #expect(result.runs == 5 && result.points == cloud.count && result.planes >= 2)
        #expect(result.min <= result.median && result.median <= result.max && result.p95 <= result.max)
        #expect(scanner.tracker.ordered.isEmpty)
    }

    @Test func liveSurfacesRunsAnEngineAndKeepsTimings() throws {
        let live = LiveSurfaces(engine: RansacScanner())
        var rng = SplitMix64(state: 1)
        let cloud = SyntheticScene.corner().cloud(noise: 0.02, rng: &rng)
        for _ in 0..<3 {
            live.submit(cloud: cloud, camera: camera())
            live.drain()
        }
        let snapshot = live.latest()
        #expect(snapshot.surfaces.count == 2)
        #expect(snapshot.recentMilliseconds.count == 3)
        live.runBenchmark(cloud: cloud, camera: camera(), runs: 3)
        live.drain()
        #expect(live.latest().benchmark?.runs == 3)
    }
}

@Suite("X2 connected pieces")
struct ConnectedPiecesTests {
    @Test func aFarClusterIsItsOwnPiece() {
        var points: [SIMD3<Float>] = []
        for i in 0..<20 { for j in 0..<10 { points.append(SIMD3(0.1 * Float(i), 0.1 * Float(j), 0)) } }
        for i in 0..<10 { for j in 0..<5 { points.append(SIMD3(20 + 0.1 * Float(i), 0.1 * Float(j), 0)) } }
        let pieces = ConnectedPieces.split(
            Array(points.indices), points: points, normal: SIMD3(0, 0, 1), center: .zero, cell: 0.4, link: 2
        )
        #expect(pieces.count == 2)
        #expect(pieces[0].count == 200 && pieces[1].count == 50)
    }

    @Test func aSmallGapDoesNotSplit() {
        var points: [SIMD3<Float>] = []
        for i in 0..<10 { for j in 0..<10 { points.append(SIMD3(0.1 * Float(i), 0.1 * Float(j), 0)) } }
        // 0.6 m of nothing, then more wall: link of 2 cells × 0.4 m bridges it.
        for i in 0..<10 { for j in 0..<10 { points.append(SIMD3(1.6 + 0.1 * Float(i), 0.1 * Float(j), 0)) } }
        let pieces = ConnectedPieces.split(
            Array(points.indices), points: points, normal: SIMD3(0, 0, 1), center: .zero, cell: 0.4, link: 2
        )
        #expect(pieces.count == 1)
    }

    @Test func emptyGivesNothing() {
        #expect(ConnectedPieces.split([], points: [], normal: SIMD3(0, 0, 1), center: .zero, cell: 0.4, link: 2).isEmpty)
    }
}
