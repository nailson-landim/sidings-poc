import Foundation
import simd

/// A round-based plane engine behind `LiveSurfaces`: X1's `SurfaceScanner` (FindSurface seeds) or X2's `RansacScanner`.
/// Both keep their planes in a `SurfaceTracker`, so recording, the renderer and Blender work with either.
public protocol SurfaceEngine: AnyObject {
    var settings: SurfaceSettings { get }
    var tracker: SurfaceTracker { get }
    /// New settings from the next round on; the tracks are kept.
    func apply(_ settings: SurfaceSettings)
    func reset()
    func round(cloud: CloudState, camera: simd_float4x4) throws -> SurfaceScanner.Report
    /// Times the engine's search on `cloud` without touching its tracks; nil when the engine has no such search.
    func benchmark(cloud: CloudState, camera: simd_float4x4, runs: Int) -> SearchBenchmark?
}

extension SurfaceEngine {
    public func benchmark(cloud: CloudState, camera: simd_float4x4, runs: Int) -> SearchBenchmark? { nil }

    /// Enough inliers, a small enough RMS error, and spread over an area rather than along one edge.
    public func accept(_ fit: SurfaceFit, points: [SIMD3<Float>]) -> Bool {
        guard fit.inliers.count >= settings.minInliers, fit.rmsError <= settings.maxRMS,
              let axes = PrincipalAxes(fit.inliers.lazy.map { points[$0] })
        else { return false }
        return axes.spread >= settings.minSpread
    }
}

extension SurfaceScanner: SurfaceEngine {}

/// The track's center or any outline vertex lies within the view cone and the seed range.
func surfaceIsInView(
    _ track: TrackedSurface, eye: SIMD3<Float>, forward: SIMD3<Float>, settings: SurfaceSettings
) -> Bool {
    let cosLimit = cos(settings.viewHalfAngleDegrees * .pi / 180)
    return ([track.center] + track.outline).contains { p in
        let d = p - eye
        let range = simd_length(d)
        guard range > 1e-3, range <= settings.maxSeedRange else { return false }
        return simd_dot(d / range, forward) >= cosLimit
    }
}

/// How long the search took over repeated runs on one cloud (*Debug › Benchmark on live cloud*).
public struct SearchBenchmark: Sendable, Equatable {
    public var points = 0
    public var planes = 0
    /// Per run, in order.
    public var milliseconds: [Double] = []
    public var hypotheses = 0
    public var pointTests = 0

    public init() {}

    public var runs: Int { milliseconds.count }
    public var mean: Double { milliseconds.isEmpty ? 0 : milliseconds.reduce(0, +) / Double(milliseconds.count) }
    public var median: Double { percentile(0.5) }
    public var p95: Double { percentile(0.95) }
    public var max: Double { milliseconds.max() ?? 0 }
    public var min: Double { milliseconds.min() ?? 0 }

    private func percentile(_ q: Double) -> Double {
        guard !milliseconds.isEmpty else { return 0 }
        let sorted = milliseconds.sorted()
        return sorted[Swift.min(Int(Double(sorted.count - 1) * q + 0.5), sorted.count - 1)]
    }
}
