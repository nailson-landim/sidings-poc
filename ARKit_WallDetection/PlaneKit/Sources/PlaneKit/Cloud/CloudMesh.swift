import Foundation
import simd

/// Mesh data for the averaged cloud on screen (`../SPEC.md` P24): one camera-facing square per point, sized by its
/// distance from the camera so every point looks about the same size (CurvSurf draws fixed-size sprites), split into
/// bands by sample count so each band gets its own material. Pure data; SidingsAR turns it into one `MeshResource`.
public enum CloudMesh {
    public static let verticesPerPoint = 4
    public static let indicesPerPoint = 6

    /// Upper sample-count bounds of the bands, like Blender's layer (P19): under 10, 10–49, 50 and more.
    public static let bandLimits: [UInt16] = [10, 50]

    public struct Band: Sendable, Equatable {
        public var positions: [SIMD3<Float>] = []
        public var indices: [UInt32] = []
        public var count: Int { positions.count / CloudMesh.verticesPerPoint }
    }

    /// The band a sample count falls in.
    public static func band(of samples: UInt16) -> Int {
        bandLimits.firstIndex { samples < $0 } ?? bandLimits.count
    }

    /// Squares facing the camera. `camera` is world ← camera; each square's half-size is `size × distance`.
    /// At most `limit` points are drawn, evenly strided.
    public static func billboards(
        _ state: CloudState, camera: simd_float4x4, size: Float, limit: Int = .max
    ) -> [Band] {
        let eye = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let right = simd_normalize(SIMD3<Float>(camera.columns.0.x, camera.columns.0.y, camera.columns.0.z))
        let up = simd_normalize(SIMD3<Float>(camera.columns.1.x, camera.columns.1.y, camera.columns.1.z))
        var bands = [Band](repeating: Band(), count: bandLimits.count + 1)
        let stride = limit > 0 && state.count > limit ? (state.count + limit - 1) / limit : 1
        for i in Swift.stride(from: 0, to: state.count, by: stride) {
            let point = state.points[i]
            let half = size * simd_distance(point, eye)
            let r = right * half
            let u = up * half
            let b = band(of: state.samples[i])
            let base = UInt32(bands[b].positions.count)
            // Counter-clockwise seen from the camera (the camera looks down its -Z, right = +X, up = +Y).
            let low: SIMD3<Float> = point - u
            let high: SIMD3<Float> = point + u
            bands[b].positions.append(low - r)
            bands[b].positions.append(low + r)
            bands[b].positions.append(high + r)
            bands[b].positions.append(high - r)
            let corners: [UInt32] = [0, 1, 2, 0, 2, 3]
            for corner in corners {
                bands[b].indices.append(base + corner)
            }
        }
        return bands
    }
}
