import Foundation
import simd
@testable import PlaneKit

/// Deterministic random numbers for synthetic clouds (SplitMix64).
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Standard normal (Box–Muller).
    mutating func gaussian() -> Float {
        let u1 = max(Float.random(in: 0..<1, using: &self), 1e-7)
        let u2 = Float.random(in: 0..<1, using: &self)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// A rectangle of lattice points: from `origin`, `width` along `u` and `height` along `v`, every `spacing` metres,
/// optionally with a rectangular hole (in u, v metres from the origin).
struct Patch {
    var origin: SIMD3<Float>
    var u: SIMD3<Float>
    var v: SIMD3<Float>
    var width: Float
    var height: Float
    var spacing: Float = 0.1
    var hole: (u: ClosedRange<Float>, v: ClosedRange<Float>)?

    var normal: SIMD3<Float> { simd_normalize(simd_cross(u, v)) }

    func lattice() -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        let nu = Int((width / spacing).rounded())
        let nv = Int((height / spacing).rounded())
        for i in 0...nu {
            for j in 0...nv {
                let a = Float(i) * spacing
                let b = Float(j) * spacing
                if let hole, hole.u.contains(a), hole.v.contains(b) { continue }
                out.append(origin + a * u + b * v)
            }
        }
        return out
    }
}

/// True positions with stable feature ids; each `cloud` call draws fresh noise, like a new averaged cloud.
struct SyntheticScene {
    var truth: [SIMD3<Float>] = []
    var ids: [UInt64] = []
    var samples: UInt16 = 20

    init(_ patches: [Patch]) {
        for patch in patches { truth += patch.lattice() }
        ids = (0..<truth.count).map { UInt64($0 + 1) }
    }

    func cloud(noise: Float, rng: inout SplitMix64) -> CloudState {
        let points = truth.map { $0 + noise * SIMD3(rng.gaussian(), rng.gaussian(), rng.gaussian()) }
        return CloudState(ids: ids, points: points, samples: [UInt16](repeating: samples, count: truth.count))
    }

    /// Two walls 4 m × 3 m meeting at a right-angled corner, in front of a camera at the origin looking down -Z.
    /// Wall A faces the camera at z = -4.25; wall B is the side wall at x = 1.25. Mid-cell, so seeds aren't split.
    static func corner() -> SyntheticScene {
        SyntheticScene([
            Patch(origin: SIMD3(-2.75, -1.5, -4.25), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 4, height: 3),
            Patch(origin: SIMD3(1.25, -1.5, -4.25), u: SIMD3(0, 0, 1), v: SIMD3(0, 1, 0), width: 3, height: 3),
        ])
    }

    /// One wall 4 m × 3 m at z = -4.25 with a 1 m × 1 m window recessed `depth` metres behind it.
    static func recess(depth: Float) -> SyntheticScene {
        let hole = (u: Float(1.45)...Float(2.55), v: Float(0.95)...Float(2.05))
        return SyntheticScene([
            Patch(origin: SIMD3(-2, -1.5, -4.25), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 4, height: 3, hole: hole),
            Patch(origin: SIMD3(-0.5, -0.5, -4.25 - depth), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 1, height: 1),
        ])
    }
}

/// Least-squares stand-in for FindSurface: the plane of the points near the seed (within `radius`, at most `2 × link`),
/// then region growing from the seed through neighbours within `link` that lie within `band` of the plane, refitted
/// three times. The small start keeps a seed on a recessed window off the wall around it.
final class ReferenceFitter: SurfaceFitter {
    let band: Float
    let link: Float
    private(set) var calls = 0
    private var points: [SIMD3<Float>] = []
    private var grid: [SIMD3<Int32>: [Int]] = [:]

    init(band: Float, link: Float = 0.15) {
        self.band = band
        self.link = link
    }

    private(set) var configured: [SurfaceSettings] = []

    func configure(_ settings: SurfaceSettings) {
        configured.append(settings)
    }

    func setPoints(_ points: [SIMD3<Float>]) {
        self.points = points
        grid.removeAll(keepingCapacity: true)
        for (i, p) in points.enumerated() {
            grid[SeedPicker.key(p, cell: link), default: []].append(i)
        }
    }

    func fitPlane(seed: Int, radius: Float) -> SurfaceFit? {
        calls += 1
        let s = points[seed]
        let start = min(radius, 2 * link)
        let region = points.indices.filter { simd_distance(points[$0], s) <= start }
        guard var axes = PrincipalAxes(region.lazy.map { self.points[$0] }) else { return nil }
        var inliers: [Int] = []
        for _ in 0..<3 {
            inliers = grow(from: seed, normal: axes.normal, center: axes.center)
            guard let next = PrincipalAxes(inliers.lazy.map { self.points[$0] }) else { return nil }
            axes = next
        }
        let squares = inliers.map { i -> Float in
            let d = simd_dot(axes.normal, points[i] - axes.center)
            return d * d
        }
        let rms = (squares.reduce(0, +) / Float(inliers.count)).squareRoot()
        return SurfaceFit(normal: axes.normal, center: axes.center, inliers: inliers.sorted(), rmsError: rms)
    }

    private func grow(from seed: Int, normal: SIMD3<Float>, center: SIMD3<Float>) -> [Int] {
        var visited: Set<Int> = [seed]
        var queue = [seed]
        var head = 0
        while head < queue.count {
            let p = points[queue[head]]
            head += 1
            let k = SeedPicker.key(p, cell: link)
            for dx: Int32 in -1...1 {
                for dy: Int32 in -1...1 {
                    for dz: Int32 in -1...1 {
                        for j in grid[k &+ SIMD3(dx, dy, dz)] ?? [] where !visited.contains(j) {
                            let q = points[j]
                            guard simd_distance(q, p) <= link, abs(simd_dot(normal, q - center)) <= band else { continue }
                            visited.insert(j)
                            queue.append(j)
                        }
                    }
                }
            }
        }
        return queue
    }
}

/// A fitter whose upload always fails.
final class FailingFitter: SurfaceFitter {
    struct Failure: Error {}

    func configure(_ settings: SurfaceSettings) {}
    func setPoints(_ points: [SIMD3<Float>]) throws { throw Failure() }
    func fitPlane(seed: Int, radius: Float) throws -> SurfaceFit? { nil }
}

/// Camera at `eye` looking down -Z (ARKit's camera convention), as world ← camera.
func camera(at eye: SIMD3<Float> = .zero) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4(eye, 1)
    return m
}

func degrees(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    PolygonMath.normalAngleDegrees(a, b)
}
