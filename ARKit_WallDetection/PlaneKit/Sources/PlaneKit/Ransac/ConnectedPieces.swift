import simd

/// Splits a plane's inliers into connected pieces on an occupancy grid (Experiment X2, `../../../EXPERIMENTS.md` *X2* 7).
///
/// RANSAC counts every point near the plane, so coplanar points tens of metres away join a wall's inliers and inflate
/// its extent (the probe's 26 m "wall"). Cells of `cell` metres are linked when they are within `link` cells of each
/// other (Chebyshev), so a gap of `link − 1` empty cells doesn't split a plane; anything farther does.
public enum ConnectedPieces {
    /// The pieces, largest first. Each piece is a list of indices into `points`.
    public static func split(
        _ indices: [Int], points: [SIMD3<Float>], normal: SIMD3<Float>, center: SIMD3<Float>, cell: Float, link: Int
    ) -> [[Int]] {
        guard !indices.isEmpty else { return [] }
        let (u, v) = PolygonMath.basis(for: simd_normalize(normal))
        let size = max(cell, 0.05)
        var grid: [SIMD2<Int32>: [Int]] = [:]
        for i in indices {
            let d = points[i] - center
            let key = SIMD2<Int32>(Int32((simd_dot(d, u) / size).rounded(.down)), Int32((simd_dot(d, v) / size).rounded(.down)))
            grid[key, default: []].append(i)
        }
        var seen = Set<SIMD2<Int32>>()
        var pieces: [[Int]] = []
        let reach = Int32(max(link, 1))
        for start in grid.keys.sorted(by: { ($0.x, $0.y) < ($1.x, $1.y) }) where !seen.contains(start) {
            var piece: [Int] = []
            var queue = [start]
            seen.insert(start)
            var head = 0
            while head < queue.count {
                let key = queue[head]
                head += 1
                piece += grid[key] ?? []
                for dx in -reach...reach {
                    for dy in -reach...reach {
                        let next = SIMD2(key.x &+ dx, key.y &+ dy)
                        if grid[next] != nil, seen.insert(next).inserted { queue.append(next) }
                    }
                }
            }
            pieces.append(piece.sorted())
        }
        return pieces.sorted { $0.count != $1.count ? $0.count > $1.count : $0[0] < $1[0] }
    }
}
