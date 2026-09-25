import Foundation
import simd

/// One round of Experiment X1 on the averaged cloud (`../../EXPERIMENTS.md`):
/// 1. upload the cloud to the fitter once;
/// 2. refit tracked planes in view, each seeded from its own inliers (least recently tried first);
/// 3. find new planes from automatic seeds among the points no plane has claimed (only these start tracks);
/// 4. let the tracker drop, merge and report.
public final class SurfaceScanner {
    public struct Report: Sendable, Equatable {
        public var round = 0
        public var points = 0
        public var refits = 0
        public var refitsMatched = 0
        public var seedsTried = 0
        public var seedsAccepted = 0
        public var events: [SurfaceEvent] = []
        /// Wall-clock time of the round.
        public var milliseconds: Double = 0
        // The RANSAC engine's own counters (X2); zero for FindSurface rounds.
        public var refitMilliseconds: Double = 0
        public var searchMilliseconds: Double = 0
        /// Whether the round ran a discovery search.
        public var searched = false
        /// Points no track claimed when discovery started.
        public var unclaimed = 0
        public var hypotheses = 0
        public var fullScores = 0
        public var pointTests = 0
        /// Planes the search found, before connected pieces and acceptance.
        public var planesFound = 0

        public init() {}
    }

    public private(set) var settings: SurfaceSettings
    public let tracker: SurfaceTracker
    private let fitter: any SurfaceFitter
    /// Cells that gave no plane, by the round they were tried.
    private var cooldown: [SIMD3<Int32>: Int] = [:]
    /// The round each track was last refitted.
    private var lastTried: [UUID: Int] = [:]

    public init(settings: SurfaceSettings, fitter: any SurfaceFitter) {
        self.settings = settings
        self.fitter = fitter
        tracker = SurfaceTracker(settings: settings)
        fitter.configure(settings)
    }

    /// New settings from the next round on; the tracks are kept.
    public func apply(_ settings: SurfaceSettings) {
        self.settings = settings
        tracker.settings = settings
        fitter.configure(settings)
    }

    public func reset() {
        tracker.reset()
        cooldown.removeAll()
        lastTried.removeAll()
    }

    /// Runs one round on `cloud`, seen from `camera` (world ← camera).
    public func round(cloud: CloudState, camera: simd_float4x4) throws -> Report {
        let clock = ContinuousClock()
        let start = clock.now
        var report = Report()
        report.points = cloud.count
        let points = cloud.points
        let eye = SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let forward = -simd_normalize(SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z))

        tracker.beginRound(points: points, ids: cloud.ids)
        report.round = tracker.round
        guard cloud.count >= settings.minInliers else {
            report.events = tracker.endRound()
            report.milliseconds = Self.ms(clock.now - start)
            return report
        }
        try fitter.setPoints(points)

        var claimed = [Bool](repeating: false, count: points.count)
        for track in tracker.surfaces.values {
            for i in tracker.presentIndices(of: track) { claimed[i] = true }
        }

        // Refit tracked planes in view.
        let due = tracker.ordered
            .filter { isInView($0, eye: eye, forward: forward) }
            .sorted { (lastTried[$0.id] ?? 0, $0.number) < (lastTried[$1.id] ?? 0, $1.number) }
            .prefix(settings.maxRefitsPerRound)
        for track in due {
            lastTried[track.id] = tracker.round
            guard let seed = refitSeed(track, points: points, eye: eye) else {
                tracker.missed(track.id)
                continue
            }
            report.refits += 1
            if let fit = try fitter.fitPlane(seed: seed.index, radius: seed.radius), accept(fit, points: points),
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

        // Find new planes.
        let cooling = Set(cooldown.filter { tracker.round - $0.value < settings.seedCooldownRounds }.keys)
        cooldown = cooldown.filter { cooling.contains($0.key) }
        let cells = SeedPicker.cells(
            points: points, samples: cloud.samples, claimed: claimed, eye: eye, settings: settings, skip: cooling
        )
        for cell in cells {
            guard report.seedsTried < settings.maxSeedAttemptsPerRound,
                  report.seedsAccepted < settings.maxNewPerRound
            else { break }
            guard let seed = SeedPicker.seed(in: cell, points: points, claimed: claimed, eye: eye, settings: settings)
            else { continue }
            report.seedsTried += 1
            if let fit = try fitter.fitPlane(seed: seed.index, radius: seed.radius), accept(fit, points: points) {
                tracker.ingest(fit)
                for i in fit.inliers { claimed[i] = true }
                report.seedsAccepted += 1
            } else {
                cooldown[cell.key] = tracker.round
            }
        }

        report.events = tracker.endRound()
        let live = Set(tracker.surfaces.keys)
        lastTried = lastTried.filter { live.contains($0.key) }
        report.milliseconds = Self.ms(clock.now - start)
        return report
    }

    /// Enough inliers, a small enough RMS error, and spread over an area rather than along one edge.
    public func accept(_ fit: SurfaceFit, points: [SIMD3<Float>]) -> Bool {
        guard fit.inliers.count >= settings.minInliers, fit.rmsError <= settings.maxRMS,
              let axes = PrincipalAxes(fit.inliers.lazy.map { points[$0] })
        else { return false }
        return axes.spread >= settings.minSpread
    }

    /// The track's inlier nearest its center; the radius covers half the plane, at least the radius for its range.
    func refitSeed(_ track: TrackedSurface, points: [SIMD3<Float>], eye: SIMD3<Float>) -> (index: Int, radius: Float)? {
        let present = tracker.presentIndices(of: track)
        guard let best = present.min(by: {
            simd_distance_squared(points[$0], track.center) < simd_distance_squared(points[$1], track.center)
        }) else { return nil }
        let byRange = settings.seedRadius(range: simd_distance(points[best], eye))
        let byExtent = 0.5 * max(track.width, track.height)
        return (best, min(max(byExtent, byRange), settings.seedRadiusMax))
    }

    /// The center or any outline vertex lies within the view cone and the seed range.
    func isInView(_ track: TrackedSurface, eye: SIMD3<Float>, forward: SIMD3<Float>) -> Bool {
        surfaceIsInView(track, eye: eye, forward: forward, settings: settings)
    }

    private static func ms(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}
