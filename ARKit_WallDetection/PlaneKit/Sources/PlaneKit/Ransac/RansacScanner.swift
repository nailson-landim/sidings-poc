import Foundation
import simd

/// One round of Experiment X2 on the averaged cloud (`../../../EXPERIMENTS.md` *X2*):
/// 1. every point gets its band from its range to the camera;
/// 2. **refit** each tracked plane in view from the points near it, within its extent plus `refitMargin`, so known
///    walls cost a least-squares pass, not a search, and can grow;
/// 3. **discover** with `PlaneSearch` on the points no track claimed, when enough of them are left and changed (or
///    every `discoveryEvery` rounds), split each plane into connected pieces, and feed each piece to the tracker;
/// 4. let the tracker match (shared feature ids, geometry, merge gap), drop, merge and report.
///
/// Slices (a thick surface cut into parallel planes) end up as one track because the tracker merges coplanar tracks
/// within `maxPlaneDistance` (0.25 m for `.ransac`).
public final class RansacScanner: SurfaceEngine {
    public private(set) var settings: SurfaceSettings
    public let tracker: SurfaceTracker
    private var rng: SearchRNG
    /// The round each track was last refitted.
    private var lastTried: [UUID: Int] = [:]
    private var lastSearchRound = 0
    private var lastSearchUnclaimed = 0

    public init(settings: SurfaceSettings = .ransac, seed: UInt64 = 0x5EED) {
        self.settings = settings
        tracker = SurfaceTracker(settings: settings)
        rng = SearchRNG(seed: seed)
    }

    public func apply(_ settings: SurfaceSettings) {
        self.settings = settings
        tracker.settings = settings
    }

    public func reset() {
        tracker.reset()
        lastTried.removeAll()
        lastSearchRound = 0
        lastSearchUnclaimed = 0
    }

    public func round(cloud: CloudState, camera: simd_float4x4) throws -> SurfaceScanner.Report {
        let clock = ContinuousClock()
        let start = clock.now
        var report = SurfaceScanner.Report()
        report.points = cloud.count
        let points = cloud.points
        let (eye, forward) = Self.eyeAndForward(camera)

        tracker.beginRound(points: points, ids: cloud.ids)
        report.round = tracker.round
        guard cloud.count >= settings.minInliers else {
            report.events = tracker.endRound()
            report.milliseconds = Self.ms(clock.now - start)
            return report
        }
        let band = Self.bands(points, eye: eye, settings: settings)
        var claimed = [Bool](repeating: false, count: points.count)
        for track in tracker.surfaces.values {
            for i in tracker.presentIndices(of: track) { claimed[i] = true }
        }
        var stats = SearchStats()

        // Refit tracked planes in view.
        let refitStart = clock.now
        let due = tracker.ordered
            .filter { surfaceIsInView($0, eye: eye, forward: forward, settings: settings) }
            .sorted { (lastTried[$0.id] ?? 0, $0.number) < (lastTried[$1.id] ?? 0, $1.number) }
            .prefix(settings.maxRefitsPerRound)
        for track in due {
            lastTried[track.id] = tracker.round
            report.refits += 1
            if let fit = refit(track, points: points, band: band, stats: &stats), accept(fit, points: points),
               let matched = tracker.ingest(fit, hint: track.id, create: false) {
                for i in fit.inliers { claimed[i] = true }
                if matched == track.id {
                    report.refitsMatched += 1
                } else {
                    tracker.missed(track.id)
                }
            } else {
                tracker.missed(track.id)
            }
        }
        report.refitMilliseconds = Self.ms(clock.now - refitStart)

        // Discover new planes among the points nobody claims.
        let unclaimed = claimed.count { !$0 }
        report.unclaimed = unclaimed
        if shouldSearch(unclaimed: unclaimed, total: points.count) {
            lastSearchRound = tracker.round
            lastSearchUnclaimed = unclaimed
            let searchStart = clock.now
            report.searched = true
            let found = PlaneSearch.run(
                points: points, band: band, samples: cloud.samples, active: claimed.map { !$0 },
                maxPlanes: settings.maxPlanesPerSearch, settings: settings, rng: &rng, stats: &stats
            )
            report.planesFound = found.count
            for plane in found {
                let pieces = ConnectedPieces.split(
                    plane.inliers, points: points, normal: plane.normal, center: plane.center,
                    cell: settings.pieceCell, link: settings.pieceLink
                )
                for piece in pieces where piece.count >= settings.minInliers {
                    report.seedsTried += 1
                    let fit = Self.fit(of: plane, piece: piece, points: points)
                    guard accept(fit, points: points) else { continue }
                    tracker.ingest(fit)
                    for i in fit.inliers { claimed[i] = true }
                    report.seedsAccepted += 1
                }
            }
            report.searchMilliseconds = Self.ms(clock.now - searchStart)
        }
        report.hypotheses = stats.hypotheses
        report.fullScores = stats.fullScores
        report.pointTests = stats.pointTests

        report.events = tracker.endRound()
        let live = Set(tracker.surfaces.keys)
        lastTried = lastTried.filter { live.contains($0.key) }
        report.milliseconds = Self.ms(clock.now - start)
        return report
    }

    // MARK: Benchmark

    /// `runs` full searches on `cloud` with no tracks involved: the cost of the search alone, as the Mac benchmark
    /// measures it (`PlaneLab/spikes/x1_vs_ransac/ransac_bench.swift`), but at the phone's settings.
    public func benchmark(cloud: CloudState, camera: simd_float4x4, runs: Int) -> SearchBenchmark? {
        guard cloud.count >= settings.minInliers else { return nil }
        let (eye, _) = Self.eyeAndForward(camera)
        let band = Self.bands(cloud.points, eye: eye, settings: settings)
        let active = [Bool](repeating: true, count: cloud.count)
        let clock = ContinuousClock()
        var result = SearchBenchmark()
        result.points = cloud.count
        var generator = SearchRNG(seed: 0xBE7C)
        for _ in 0..<max(runs, 1) {
            var stats = SearchStats()
            let start = clock.now
            _ = PlaneSearch.run(
                points: cloud.points, band: band, samples: cloud.samples, active: active,
                maxPlanes: settings.maxPlanesPerSearch, settings: settings, rng: &generator, stats: &stats
            )
            result.milliseconds.append(Self.ms(clock.now - start))
            result.planes = stats.planes
            result.hypotheses = stats.hypotheses
            result.pointTests = stats.pointTests
        }
        return result
    }

    // MARK: Pieces of a round

    private func shouldSearch(unclaimed: Int, total: Int) -> Bool {
        guard unclaimed >= max(settings.minInliers, Int(settings.discoveryMinUnclaimedFraction * Float(total))) else {
            return false
        }
        return tracker.surfaces.isEmpty
            || tracker.round - lastSearchRound >= settings.discoveryEvery
            || Float(unclaimed) >= 1.2 * Float(lastSearchUnclaimed)
    }

    /// The track's plane refitted on the points near it: in its band, within its extent plus the margin.
    private func refit(
        _ track: TrackedSurface, points: [SIMD3<Float>], band: [Float], stats: inout SearchStats
    ) -> SurfaceFit? {
        let horizontal = abs(track.normal.y) > 0.5
        var n = SIMD3<Float>(0, 1, 0)
        if !horizontal {
            let flat = SIMD3(track.normal.x, 0, track.normal.z)
            guard simd_length(flat) > 1e-4 else { return nil }
            n = simd_normalize(flat)
        }
        let offset = simd_dot(n, track.center)
        let (u, v) = PolygonMath.basis(for: n)
        let shape = (track.outline.isEmpty ? [track.center] : track.outline).map { p -> SIMD2<Float> in
            let d = p - track.center
            return SIMD2(simd_dot(d, u), simd_dot(d, v))
        }
        let margin = settings.refitMargin
        let lo = SIMD2(shape.map(\.x).min()! - margin, shape.map(\.y).min()! - margin)
        let hi = SIMD2(shape.map(\.x).max()! + margin, shape.map(\.y).max()! + margin)
        var near: [Int] = []
        for i in points.indices {
            let d = points[i] - track.center
            guard abs(simd_dot(n, points[i]) - offset) < band[i] else { continue }
            let x = simd_dot(d, u), y = simd_dot(d, v)
            if x >= lo.x, x <= hi.x, y >= lo.y, y <= hi.y { near.append(i) }
        }
        guard let plane = PlaneSearch.refit(
            normal: n, offset: offset, points: points, band: band, among: near, settings: settings, stats: &stats
        ) else { return nil }
        // Keep the piece that holds the most of the track's own inliers: far coplanar points stay out.
        let pieces = ConnectedPieces.split(
            plane.inliers, points: points, normal: plane.normal, center: plane.center,
            cell: settings.pieceCell, link: settings.pieceLink
        )
        let own = Set(tracker.presentIndices(of: track))
        guard let piece = pieces.max(by: { a, b in
            let ca = a.count { own.contains($0) }, cb = b.count { own.contains($0) }
            return ca != cb ? ca < cb : a.count < b.count
        }) else { return nil }
        return Self.fit(of: plane, piece: piece, points: points)
    }

    /// `plane` restricted to `piece`, with the center and RMS recomputed on the piece.
    static func fit(of plane: PlaneCandidate, piece: [Int], points: [SIMD3<Float>]) -> SurfaceFit {
        var centroid = SIMD3<Float>.zero
        for i in piece { centroid += points[i] }
        centroid /= Float(max(piece.count, 1))
        centroid -= simd_dot(plane.normal, centroid - plane.center) * plane.normal
        var squares: Float = 0
        for i in piece {
            let d = simd_dot(plane.normal, points[i] - plane.center)
            squares += d * d
        }
        return SurfaceFit(
            normal: plane.normal, center: centroid, inliers: piece,
            rmsError: (squares / Float(max(piece.count, 1))).squareRoot()
        )
    }

    static func bands(_ points: [SIMD3<Float>], eye: SIMD3<Float>, settings: SurfaceSettings) -> [Float] {
        points.map { settings.band(range: simd_distance($0, eye)) }
    }

    static func eyeAndForward(_ camera: simd_float4x4) -> (SIMD3<Float>, SIMD3<Float>) {
        (
            SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z),
            -simd_normalize(SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z))
        )
    }

    private static func ms(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}
