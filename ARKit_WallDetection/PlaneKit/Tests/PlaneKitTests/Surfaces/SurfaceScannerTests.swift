import Foundation
import simd
import Testing
@testable import PlaneKit

@Suite("X1 scanner and live surfaces")
struct SurfaceScannerTests {
    /// Runs `rounds` rounds on fresh noise each time.
    static func run(
        _ scene: SyntheticScene, noise: Float, band: Float, rounds: Int, settings: SurfaceSettings = SurfaceSettings()
    ) throws -> (scanner: SurfaceScanner, reports: [SurfaceScanner.Report]) {
        let scanner = SurfaceScanner(settings: settings, fitter: ReferenceFitter(band: band))
        var rng = SplitMix64(state: 7)
        var reports: [SurfaceScanner.Report] = []
        for _ in 0..<rounds {
            reports.append(try scanner.round(cloud: scene.cloud(noise: noise, rng: &rng), camera: camera()))
        }
        return (scanner, reports)
    }

    @Test func aCornerGivesTwoStablePlanesAtRightAngles() throws {
        let (scanner, reports) = try Self.run(.corner(), noise: 0.02, band: 0.06, rounds: 50)
        let tracks = scanner.tracker.ordered
        #expect(tracks.count == 2)
        #expect(tracks.allSatisfy { $0.state == .confirmed })
        // Every track was added in round 1 and never replaced: no add, merge or drop later.
        #expect(reports[0].events.filter { if case .add = $0 { true } else { false } }.count == 2)
        for report in reports.dropFirst() {
            #expect(report.events.allSatisfy { if case .update = $0 { true } else { false } })
        }
        let ids = Set(tracks.map(\.id))
        #expect(ids == Set(reports.last!.events.compactMap { if case let .update(id) = $0 { id } else { nil } }))
        let facing = try #require(tracks.first { abs($0.normal.z) > 0.9 })
        let side = try #require(tracks.first { abs($0.normal.x) > 0.9 })
        #expect(degrees(facing.normal, SIMD3(0, 0, 1)) < 2)
        #expect(degrees(side.normal, SIMD3(1, 0, 0)) < 2)
        #expect(abs(degrees(facing.normal, side.normal) - 90) < 3)
        #expect(abs(facing.center.z + 4.25) < 0.02)
        #expect(abs(side.center.x - 1.25) < 0.02)
        #expect(abs(facing.width - 4) < 0.25 && abs(facing.height - 3) < 0.25)
    }

    @Test func refitsAreSeededFromEachTrackAndMatchIt() throws {
        let (_, reports) = try Self.run(.corner(), noise: 0.02, band: 0.06, rounds: 10)
        for report in reports.dropFirst() {
            #expect(report.refits == 2)
            #expect(report.refitsMatched == 2)
            #expect(report.seedsAccepted == 0)
        }
    }

    @Test func aWindowTenCentimetresDeepIsItsOwnPlane() throws {
        let (scanner, _) = try Self.run(.recess(depth: 0.10), noise: 0.01, band: 0.03, rounds: 10)
        let tracks = scanner.tracker.ordered
        #expect(tracks.count == 2)
        let depths = tracks.map(\.center.z).sorted()
        #expect(abs(depths[0] + 4.35) < 0.02)
        #expect(abs(depths[1] + 4.25) < 0.02)
    }

    @Test func aWindowFiveCentimetresDeepJoinsTheWall() throws {
        let (scanner, _) = try Self.run(.recess(depth: 0.05), noise: 0.01, band: 0.03, rounds: 10)
        #expect(scanner.tracker.ordered.count == 1)
    }

    @Test func pointsAlongOneEdgeGiveNoPlane() throws {
        let line = Patch(origin: SIMD3(-1.45, 0.25, -3.25), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 3, height: 0, spacing: 0.05)
        let (scanner, reports) = try Self.run(SyntheticScene([line]), noise: 0.01, band: 0.03, rounds: 3)
        #expect(scanner.tracker.surfaces.isEmpty)
        #expect(reports[0].seedsTried > 0)
        #expect(reports[0].seedsAccepted == 0)
    }

    @Test func aPlaneOutOfViewIsNotRefitAndDoesNotGoStale() throws {
        var settings = SurfaceSettings()
        settings.staleMisses = 2
        let scene = SyntheticScene.corner()
        let fitter = ReferenceFitter(band: 0.06)
        let scanner = SurfaceScanner(settings: settings, fitter: fitter)
        var rng = SplitMix64(state: 3)
        for _ in 0..<4 { _ = try scanner.round(cloud: scene.cloud(noise: 0.02, rng: &rng), camera: camera()) }
        // Turn around: both walls are behind the camera.
        var back = camera()
        back.columns.0 = SIMD4(-1, 0, 0, 0)
        back.columns.2 = SIMD4(0, 0, -1, 0)
        for _ in 0..<5 {
            let report = try scanner.round(cloud: scene.cloud(noise: 0.02, rng: &rng), camera: back)
            #expect(report.refits == 0)
        }
        #expect(scanner.tracker.ordered.map(\.state) == [.confirmed, .confirmed])
    }

    @Test func aCellThatGaveNoPlaneCoolsDown() throws {
        let line = Patch(origin: SIMD3(-1.45, 0.25, -3.25), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 3, height: 0, spacing: 0.05)
        var settings = SurfaceSettings()
        settings.seedCooldownRounds = 4
        let (_, reports) = try Self.run(SyntheticScene([line]), noise: 0.01, band: 0.03, rounds: 5, settings: settings)
        let tried = reports.map(\.seedsTried)
        #expect(tried[0] > 0)
        #expect(tried[1...3].allSatisfy { $0 == 0 })
        #expect(tried[4] == tried[0])
    }

    @Test func tooFewPointsSkipTheFitter() throws {
        let fitter = ReferenceFitter(band: 0.03)
        let scanner = SurfaceScanner(settings: SurfaceSettings(), fitter: fitter)
        let report = try scanner.round(cloud: CloudState(ids: [1], points: [SIMD3(0, 0, -1)], samples: [20]), camera: camera())
        #expect(report.round == 1)
        #expect(fitter.calls == 0)
    }

    @Test func liveSurfacesPublishAfterEachRound() throws {
        let live = LiveSurfaces(settings: SurfaceSettings(), fitter: ReferenceFitter(band: 0.06))
        var rng = SplitMix64(state: 11)
        let scene = SyntheticScene.corner()
        for _ in 0..<3 {
            #expect(live.submit(cloud: scene.cloud(noise: 0.02, rng: &rng), camera: camera()))
            live.drain()
        }
        let snapshot = live.latest()
        #expect(snapshot.version == 3)
        #expect(snapshot.report.round == 3)
        #expect(snapshot.surfaces.count == 2)
        #expect(snapshot.surfaces.allSatisfy { $0.state == .confirmed })
        #expect(snapshot.lastError == nil)

        live.clear()
        live.drain()
        #expect(live.latest().surfaces.isEmpty)
    }

    @Test func liveSurfacesSkipWhileARoundRuns() {
        let live = LiveSurfaces(settings: SurfaceSettings(), fitter: ReferenceFitter(band: 0.06))
        var rng = SplitMix64(state: 5)
        let cloud = SyntheticScene.corner().cloud(noise: 0.02, rng: &rng)
        live.suspendForTesting()
        #expect(live.submit(cloud: cloud, camera: camera()))
        #expect(!live.submit(cloud: cloud, camera: camera()))
        live.resumeForTesting()
        live.drain()
        #expect(live.latest().skipped == 1)
        #expect(live.submit(cloud: cloud, camera: camera()))
        live.drain()
    }

    @Test func newSettingsApplyFromTheNextRoundAndKeepTheTracks() {
        let fitter = ReferenceFitter(band: 0.06)
        let live = LiveSurfaces(settings: SurfaceSettings(), fitter: fitter)
        var rng = SplitMix64(state: 4)
        let scene = SyntheticScene.corner()
        live.submit(cloud: scene.cloud(noise: 0.02, rng: &rng), camera: camera())
        live.drain()
        let before = Set(live.latest().surfaces.map(\.id))
        var dials = SurfaceSettings()
        dials.lateralExtension = 9
        dials.keepBand = 0.25
        live.update(settings: dials)
        live.submit(cloud: scene.cloud(noise: 0.02, rng: &rng), camera: camera())
        live.drain()
        #expect(live.latest().settings == dials)
        #expect(Set(live.latest().surfaces.map(\.id)) == before)
        #expect(fitter.configured.last == dials)
        #expect(fitter.configured.count == 2)
    }

    @Test func aFitterErrorIsReportedNotThrown() {
        let live = LiveSurfaces(settings: SurfaceSettings(), fitter: FailingFitter())
        var rng = SplitMix64(state: 5)
        live.submit(cloud: SyntheticScene.corner().cloud(noise: 0.02, rng: &rng), camera: camera())
        live.drain()
        #expect(live.latest().lastError != nil)
        #expect(live.latest().surfaces.isEmpty)
    }
}
