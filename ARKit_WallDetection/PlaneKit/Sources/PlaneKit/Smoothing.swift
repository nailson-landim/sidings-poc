import simd

/// Exponential moving average over a plane's rendered center and extent, with a reset on large jumps.
public struct PlaneSmoother: Sendable, Equatable {
    public private(set) var center: SIMD3<Float>
    public private(set) var width: Float
    public private(set) var height: Float

    public init(center: SIMD3<Float>, width: Float, height: Float) {
        self.center = center
        self.width = width
        self.height = height
    }

    /// Blends toward the new sample; snaps to it when the center moved more than `resetDistance`
    /// (relocalization or ARKit re-anchoring), so we never animate across the room.
    public mutating func update(center newCenter: SIMD3<Float>, width newWidth: Float, height newHeight: Float, alpha: Float, resetDistance: Float) {
        if simd_distance(center, newCenter) > resetDistance {
            center = newCenter
            width = newWidth
            height = newHeight
            return
        }
        center += alpha * (newCenter - center)
        width += alpha * (newWidth - width)
        height += alpha * (newHeight - height)
    }
}
