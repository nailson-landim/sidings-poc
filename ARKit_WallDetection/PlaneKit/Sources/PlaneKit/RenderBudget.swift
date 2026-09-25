import Foundation
import simd

/// Rate limiter keyed on a caller-supplied clock (e.g. `ARFrame.timestamp`).
public struct Throttle: Sendable, Equatable {
    public let interval: TimeInterval
    private var last: TimeInterval = -.infinity

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    /// Returns true (and arms the next window) when at least `interval` has passed since the last fire.
    public mutating func fire(now: TimeInterval) -> Bool {
        guard now - last >= interval else { return false }
        last = now
        return true
    }

    public mutating func reset() {
        last = -.infinity
    }
}

/// Decides when a plane's GPU mesh is worth rebuilding: only on a real geometry change and never more often than
/// `minInterval`. The first call always rebuilds.
public struct RebuildGate: Sendable, Equatable {
    public var areaDelta: Float
    private var lastTime: TimeInterval = -.infinity
    private var lastVertexCount = -1
    private var lastArea: Float = 0

    public init(areaDelta: Float = 0.05) {
        self.areaDelta = areaDelta
    }

    /// True when geometry changed since the last rebuild (regardless of the time window).
    public func hasChanged(vertexCount: Int, area: Float) -> Bool {
        if lastVertexCount < 0 || vertexCount != lastVertexCount { return true }
        guard lastArea > 0 else { return area > 0 }
        return abs(area - lastArea) / lastArea > areaDelta
    }

    public mutating func shouldRebuild(now: TimeInterval, vertexCount: Int, area: Float, minInterval: TimeInterval) -> Bool {
        guard hasChanged(vertexCount: vertexCount, area: area) else { return false }
        guard lastVertexCount < 0 || now - lastTime >= minInterval else { return false }
        lastTime = now
        lastVertexCount = vertexCount
        lastArea = area
        return true
    }
}

/// Builds one mesh holding a small octahedron per point, so N debug markers cost one entity instead of N.
public enum PointMarkerMesh {
    public static let verticesPerPoint = 6
    public static let indicesPerPoint = 24

    /// Outward-facing (counter-clockwise) triangles over the 6 tips: +x, -x, +y, -y, +z, -z.
    private static let faces: [UInt32] = [0, 2, 4, 2, 1, 4, 1, 3, 4, 3, 0, 4, 2, 0, 5, 1, 2, 5, 3, 1, 5, 0, 3, 5]

    public static func octahedra(centers: [SIMD3<Float>], radius r: Float) -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        let tips: [SIMD3<Float>] = [
            SIMD3(r, 0, 0), SIMD3(-r, 0, 0), SIMD3(0, r, 0), SIMD3(0, -r, 0), SIMD3(0, 0, r), SIMD3(0, 0, -r)
        ]
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(centers.count * verticesPerPoint)
        indices.reserveCapacity(centers.count * indicesPerPoint)
        for (i, c) in centers.enumerated() {
            let base = UInt32(i * verticesPerPoint)
            positions.append(contentsOf: tips.map { c + $0 })
            indices.append(contentsOf: faces.map { base + $0 })
        }
        return (positions, indices)
    }

    /// Evenly strided subset with at most `limit` points.
    public static func subsample<T>(_ points: [T], limit: Int) -> [T] {
        guard limit > 0, points.count > limit else { return limit > 0 ? points : [] }
        let stride = Int((Double(points.count) / Double(limit)).rounded(.up))
        return Swift.stride(from: 0, to: points.count, by: stride).map { points[$0] }
    }
}
