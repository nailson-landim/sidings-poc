import simd

/// Automatic seeds for finding new planes (Experiment X1, XD2): grid cells of unclaimed, well-observed points, flattest
/// first. Flattest rather than densest: where two surfaces meet, a cell holds both and is dense but not flat, and a seed
/// there gives a plane across the corner.
public enum SeedPicker {
    /// One grid cell that can seed a fit.
    public struct Cell: Sendable, Equatable {
        public var key: SIMD3<Int32>
        /// Seedable points in the cell, unclaimed when the cells were built.
        public var indices: [Int]
        public var centroid: SIMD3<Float>
        /// RMS distance of the cell's points to their plane.
        public var thickness: Float
        /// Distance from the camera to the centroid.
        public var range: Float
    }

    public static func key(_ p: SIMD3<Float>, cell: Float) -> SIMD3<Int32> {
        SIMD3<Int32>((p / cell).rounded(.down))
    }

    /// Candidate cells, flattest first, then densest, then nearest the camera, then by key so the order is deterministic.
    /// A cell needs `minSeedCellPoints` unclaimed points with `minSeedSamples` samples or more, within
    /// `maxSeedRange`, and no thicker than `maxSeedThickness`. Cells in `skip` are left out.
    public static func cells(
        points: [SIMD3<Float>], samples: [UInt16], claimed: [Bool], eye: SIMD3<Float>, settings: SurfaceSettings,
        skip: Set<SIMD3<Int32>> = []
    ) -> [Cell] {
        var buckets: [SIMD3<Int32>: [Int]] = [:]
        let maxRange2 = settings.maxSeedRange * settings.maxSeedRange
        for i in points.indices where !claimed[i] && samples[i] >= settings.minSeedSamples {
            guard simd_distance_squared(points[i], eye) <= maxRange2 else { continue }
            let k = key(points[i], cell: settings.seedCell)
            guard !skip.contains(k) else { continue }
            buckets[k, default: []].append(i)
        }
        var cells: [Cell] = []
        for (k, indices) in buckets where indices.count >= settings.minSeedCellPoints {
            guard let axes = PrincipalAxes(indices.lazy.map { points[$0] }),
                  axes.thickness <= settings.maxSeedThickness
            else { continue }
            cells.append(Cell(
                key: k, indices: indices, centroid: axes.center, thickness: axes.thickness,
                range: simd_distance(axes.center, eye)
            ))
        }
        return cells.sorted { a, b in
            if a.thickness != b.thickness { return a.thickness < b.thickness }
            if a.indices.count != b.indices.count { return a.indices.count > b.indices.count }
            if a.range != b.range { return a.range < b.range }
            return (a.key.x, a.key.y, a.key.z) < (b.key.x, b.key.y, b.key.z)
        }
    }

    /// The cell's unclaimed point nearest its centroid, and the seed radius for its range. Nil once fewer than
    /// `minSeedCellPoints` of the cell's points are still unclaimed (an earlier fit this round took them).
    public static func seed(
        in cell: Cell, points: [SIMD3<Float>], claimed: [Bool], eye: SIMD3<Float>, settings: SurfaceSettings
    ) -> (index: Int, radius: Float)? {
        let free = cell.indices.filter { !claimed[$0] }
        guard free.count >= settings.minSeedCellPoints,
              let best = free.min(by: {
                  simd_distance_squared(points[$0], cell.centroid) < simd_distance_squared(points[$1], cell.centroid)
              })
        else { return nil }
        return (best, settings.seedRadius(range: simd_distance(points[best], eye)))
    }
}
