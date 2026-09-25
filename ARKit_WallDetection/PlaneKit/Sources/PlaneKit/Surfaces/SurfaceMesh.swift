import simd

/// Fill mesh for a tracked surface (Experiment X1): its convex outline as a triangle fan, drawn from both sides.
public enum SurfaceMesh {
    public static func fan(_ outline: [SIMD3<Float>]) -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        guard outline.count >= 3 else { return ([], []) }
        var indices: [UInt32] = []
        indices.reserveCapacity((outline.count - 2) * 3)
        for i in 1..<(outline.count - 1) {
            indices += [0, UInt32(i), UInt32(i + 1)]
        }
        return (outline, indices)
    }
}
