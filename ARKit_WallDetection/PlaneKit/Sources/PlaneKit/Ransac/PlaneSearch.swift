import Foundation
import simd

/// One plane the search found (Experiment X2). It is vertical (a normal in the horizontal plane) or horizontal
/// (normal +Y); free orientations are off, because X1's tilted planes are what free orientation gives on this data.
public struct PlaneCandidate: Sendable, Equatable {
    /// Unit normal. Sign: horizontal planes have +Y; vertical ones are `(−sin θ, 0, cos θ)`.
    public var normal: SIMD3<Float>
    /// The inliers' centroid, on the plane.
    public var center: SIMD3<Float>
    /// Indices into the search's points.
    public var inliers: [Int]
    public var rmsError: Float

    public var isHorizontal: Bool { abs(normal.y) > 0.5 }
}

/// What a search cost, for the HUD and the recording.
public struct SearchStats: Sendable, Equatable {
    public var hypotheses = 0
    /// Hypotheses scored on the whole cloud (the rest were dropped by the lazy subset).
    public var fullScores = 0
    /// Point-versus-plane distance tests, in all.
    public var pointTests = 0
    public var planes = 0

    public init() {}

    public static func + (a: SearchStats, b: SearchStats) -> SearchStats {
        var s = SearchStats()
        s.hypotheses = a.hypotheses + b.hypotheses
        s.fullScores = a.fullScores + b.fullScores
        s.pointTests = a.pointTests + b.pointTests
        s.planes = a.planes + b.planes
        return s
    }
}

/// SplitMix64: a small deterministic generator, so a seed gives the same planes (tests, comparisons).
public struct SearchRNG: RandomNumberGenerator, Sendable {
    public var state: UInt64

    public init(seed: UInt64 = 0x5EED) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Sequential RANSAC for vertical and horizontal planes (Experiment X2, `../../../EXPERIMENTS.md` *X2*, XD12).
///
/// Per plane: a hypothesis is a vertical plane through two nearby points (NAPSAC: the second point comes from the
/// first's grid cell) or a horizontal plane through one. Points are drawn best-observed first (PROSAC by sample count),
/// the prefix widening as the loop goes. Each point has its own band (`band`, from its range), and a hypothesis scores
/// by MSAC: an inlier adds `1 − (d/τ)²`. Scoring is lazy: a strided subset first, the whole cloud only if the
/// subset says the hypothesis could still win. The loop stops once the best plane would have been found with
/// `ransacConfidence` (adaptive k). The winner gets a few least-squares refits (LO) that keep its orientation class.
/// Then its inliers leave the cloud and the next plane is searched.
public enum PlaneSearch {
    /// Finds up to `maxPlanes` planes among the points where `active` is true.
    /// - Parameters:
    ///   - band: per-point inlier band τ (m).
    ///   - samples: per-point sample counts (the PROSAC quality order).
    public static func run(
        points: [SIMD3<Float>], band: [Float], samples: [UInt16], active: [Bool], maxPlanes: Int,
        settings: SurfaceSettings, rng: inout SearchRNG, stats: inout SearchStats
    ) -> [PlaneCandidate] {
        var alive = points.indices.filter { active[$0] }
        // PROSAC order: the best-observed points first.
        alive.sort { samples[$0] != samples[$1] ? samples[$0] > samples[$1] : $0 < $1 }
        var found: [PlaneCandidate] = []
        var misses = 0
        while found.count < maxPlanes, alive.count >= settings.minInliers, misses < 2 {
            let p = alive.map { points[$0] }
            let t = alive.map { band[$0] }
            guard let local = findBest(p, t, settings: settings, rng: &rng, stats: &stats) else { break }
            var gone = [Bool](repeating: false, count: alive.count)
            for i in local.inliers { gone[i] = true }
            var plane = local
            plane.inliers = local.inliers.map { alive[$0] }
            var kept: [Int] = []
            kept.reserveCapacity(alive.count - local.inliers.count)
            for (i, index) in alive.enumerated() where !gone[i] { kept.append(index) }
            alive = kept
            if plane.inliers.count >= settings.minInliers {
                found.append(plane)
                stats.planes += 1
            } else {
                misses += 1
            }
        }
        return found
    }

    /// Refits the plane `dot(normal, x) == offset` on the points of `indices` (LO refits that keep its orientation
    /// class); the track's own plane is the start. Nil when too few of them are inliers.
    public static func refit(
        normal: SIMD3<Float>, offset: Float, points: [SIMD3<Float>], band: [Float], among indices: [Int],
        settings: SurfaceSettings, stats: inout SearchStats
    ) -> PlaneCandidate? {
        let p = indices.map { points[$0] }
        let t = indices.map { band[$0] }
        var plane = refine(
            Hypothesis(normal: normal, offset: offset, score: 0, count: 0), p, t, iterations: settings.loIterations,
            stats: &stats
        )
        guard plane.inliers.count >= settings.minInliers else { return nil }
        plane.inliers = plane.inliers.map { indices[$0] }
        return plane
    }

    // MARK: One plane

    /// A hypothesis: the plane `dot(normal, x) == offset`.
    private struct Hypothesis {
        var normal: SIMD3<Float>
        var offset: Float
        var score: Float
        var count: Int
    }

    private static let up = SIMD3<Float>(0, 1, 0)

    private static func findBest(
        _ p: [SIMD3<Float>], _ t: [Float], settings: SurfaceSettings, rng: inout SearchRNG, stats: inout SearchStats
    ) -> PlaneCandidate? {
        let m = p.count
        let inverseSquare = t.map { 1 / ($0 * $0) }
        var best: Hypothesis?
        let confidence = Double(min(max(settings.ransacConfidence, 0.5), 0.9999))
        let firstPrefix = min(m, 200)
        let stride = max(m / max(settings.lazySubset, 1), 1)

        // Grid for the second sample point.
        let cell = max(settings.napsacCell, 0.1)
        var cellOf = [Int32](repeating: 0, count: m)
        var cells: [[Int32]] = []
        var keyed: [SIMD3<Int32>: Int32] = [:]
        for (i, point) in p.enumerated() {
            let key = SIMD3<Int32>(
                Int32((point.x / cell).rounded(.down)), Int32((point.y / cell).rounded(.down)),
                Int32((point.z / cell).rounded(.down))
            )
            if let index = keyed[key] {
                cells[Int(index)].append(Int32(i))
                cellOf[i] = index
            } else {
                keyed[key] = Int32(cells.count)
                cellOf[i] = Int32(cells.count)
                cells.append([Int32(i)])
            }
        }

        p.withUnsafeBufferPointer { pp in
            inverseSquare.withUnsafeBufferPointer { ww in
                // Scores `normal · x − offset` over every `step`-th point from 0.
                func score(_ n: SIMD3<Float>, _ c: Float, step: Int) -> (Float, Int) {
                    var total: Float = 0
                    var count = 0
                    var i = 0
                    while i < m {
                        let d = simd_dot(n, pp[i]) - c
                        let q = d * d * ww[i]
                        if q < 1 {
                            total += 1 - q
                            count += 1
                        }
                        i += step
                    }
                    stats.pointTests += (m + step - 1) / step
                    return (total, count)
                }

                func consider(_ n: SIMD3<Float>, _ c: Float) {
                    stats.hypotheses += 1
                    if let best, stride > 1 {
                        let (rough, _) = score(n, c, step: stride)
                        // The subset estimates the whole score; give it slack, so a good plane isn't dropped by luck.
                        if rough * Float(stride) < 0.6 * best.score { return }
                    }
                    let (s, k) = score(n, c, step: 1)
                    stats.fullScores += 1
                    if best == nil || s > best!.score { best = Hypothesis(normal: n, offset: c, score: s, count: k) }
                }

                /// Hypotheses still needed for `confidence`, for samples of `size` points.
                func needed(size: Int) -> Int {
                    guard let best else { return .max }
                    let w = Double(best.count) / Double(m)
                    let miss = 1 - pow(w, Double(size))
                    guard miss > 1e-12 else { return 0 }
                    return Int((log(1 - confidence) / log(miss)).rounded(.up))
                }

                func prefix(_ iteration: Int, of cap: Int) -> Int {
                    firstPrefix + (m - firstPrefix) * iteration / max(cap, 1)
                }

                // Horizontal: one point.
                var iteration = 0
                while iteration < settings.maxHorizontalHypotheses, iteration < needed(size: 1) {
                    let i = Int.random(in: 0..<max(prefix(iteration, of: settings.maxHorizontalHypotheses), 1), using: &rng)
                    consider(up, pp[min(i, m - 1)].y)
                    iteration += 1
                }

                // Vertical: two nearby points.
                iteration = 0
                while iteration < settings.maxVerticalHypotheses, iteration < needed(size: 2) {
                    defer { iteration += 1 }
                    let i = Int.random(in: 0..<max(prefix(iteration, of: settings.maxVerticalHypotheses), 1), using: &rng)
                    let mates = cells[Int(cellOf[min(i, m - 1)])]
                    guard mates.count >= 2 else { continue }
                    let j = Int(mates[Int.random(in: 0..<mates.count, using: &rng)])
                    var d = pp[j] - pp[i]
                    d.y = 0
                    guard simd_length(d) >= settings.minSampleSeparation else { continue }
                    let n = simd_normalize(SIMD3(-d.z, 0, d.x))
                    consider(n, simd_dot(n, pp[i]))
                }
            }
        }

        guard let winner = best, winner.count >= settings.minInliers else { return nil }
        return refine(winner, p, t, iterations: settings.loIterations, stats: &stats)
    }

    // MARK: Refinement (LO)

    /// Least-squares refits that keep the orientation class (vertical stays vertical, horizontal horizontal), each
    /// accepted only when the MSAC score rises. Returns the final plane with its inliers and RMS.
    private static func refine(
        _ start: Hypothesis, _ p: [SIMD3<Float>], _ t: [Float], iterations: Int, stats: inout SearchStats
    ) -> PlaneCandidate {
        var current = start
        var inliers = inliersOf(current, p, t)
        stats.pointTests += p.count
        for _ in 0..<iterations where inliers.count >= 3 {
            guard let next = leastSquares(current, inliers: inliers, p) else { break }
            let nextInliers = inliersOf(next, p, t)
            stats.pointTests += p.count
            let scored = Hypothesis(
                normal: next.normal, offset: next.offset, score: msac(next, nextInliers, p, t), count: nextInliers.count
            )
            guard scored.score > msac(current, inliers, p, t) else { break }
            current = scored
            inliers = nextInliers
        }
        let n = current.normal
        var centroid = SIMD3<Float>.zero
        var squares: Float = 0
        for i in inliers {
            centroid += p[i]
            let d = simd_dot(n, p[i]) - current.offset
            squares += d * d
        }
        centroid /= Float(max(inliers.count, 1))
        centroid -= (simd_dot(n, centroid) - current.offset) * n
        return PlaneCandidate(
            normal: n, center: centroid, inliers: inliers, rmsError: (squares / Float(max(inliers.count, 1))).squareRoot()
        )
    }

    private static func inliersOf(_ h: Hypothesis, _ p: [SIMD3<Float>], _ t: [Float]) -> [Int] {
        var out: [Int] = []
        for i in p.indices where abs(simd_dot(h.normal, p[i]) - h.offset) < t[i] { out.append(i) }
        return out
    }

    private static func msac(_ h: Hypothesis, _ inliers: [Int], _ p: [SIMD3<Float>], _ t: [Float]) -> Float {
        var total: Float = 0
        for i in inliers {
            let q = (simd_dot(h.normal, p[i]) - h.offset) / t[i]
            total += 1 - q * q
        }
        return total
    }

    /// Horizontal: the mean height. Vertical: the total least-squares line through the inliers in the XZ plane.
    private static func leastSquares(_ h: Hypothesis, inliers: [Int], _ p: [SIMD3<Float>]) -> Hypothesis? {
        let count = Float(inliers.count)
        if abs(h.normal.y) > 0.5 {
            let mean = inliers.reduce(Float(0)) { $0 + p[$1].y } / count
            return Hypothesis(normal: up, offset: mean, score: 0, count: 0)
        }
        var mx: Float = 0, mz: Float = 0
        for i in inliers {
            mx += p[i].x
            mz += p[i].z
        }
        mx /= count
        mz /= count
        var sxx: Float = 0, szz: Float = 0, sxz: Float = 0
        for i in inliers {
            let dx = p[i].x - mx, dz = p[i].z - mz
            sxx += dx * dx
            szz += dz * dz
            sxz += dx * dz
        }
        guard sxx + szz > 1e-9 else { return nil }
        let theta = 0.5 * atan2(2 * sxz, sxx - szz)
        let n = SIMD3<Float>(-sin(theta), 0, cos(theta))
        return Hypothesis(normal: n, offset: n.x * mx + n.z * mz, score: 0, count: 0)
    }
}
