import Foundation
import simd

public enum PlaneAlignment: String, Sendable {
    case horizontal
    case vertical
}

/// Mirrors `ARPlaneAnchor.Classification` without depending on ARKit.
public enum PlaneClass: String, Sendable, CaseIterable {
    case none, wall, floor, ceiling, table, seat, door, window
}

/// ARKit-free snapshot of one `ARPlaneAnchor`.
///
/// Local coordinates follow ARKit: the plane lies in the anchor's local XZ plane and its normal is local +Y.
public struct PlaneObservation: Sendable, Equatable {
    public let id: UUID
    public var alignment: PlaneAlignment
    public var classification: PlaneClass
    /// Anchor pose in world space.
    public var transform: simd_float4x4
    /// Extent center in anchor-local space.
    public var center: SIMD3<Float>
    /// Extent along local X after `yaw` rotation (metres).
    public var width: Float
    /// Extent along local Z after `yaw` rotation (metres).
    public var height: Float
    /// `ARPlaneExtent.rotationOnYAxis` (radians).
    public var yaw: Float
    /// `ARPlaneGeometry.boundaryVertices`, anchor-local.
    public var boundaryLocal: [SIMD3<Float>]
    public var firstSeen: TimeInterval
    public var updateCount: Int

    public init(
        id: UUID,
        alignment: PlaneAlignment,
        classification: PlaneClass = .none,
        transform: simd_float4x4,
        center: SIMD3<Float>,
        width: Float,
        height: Float,
        yaw: Float = 0,
        boundaryLocal: [SIMD3<Float>] = [],
        firstSeen: TimeInterval = 0,
        updateCount: Int = 0
    ) {
        self.id = id
        self.alignment = alignment
        self.classification = classification
        self.transform = transform
        self.center = center
        self.width = width
        self.height = height
        self.yaw = yaw
        self.boundaryLocal = boundaryLocal
        self.firstSeen = firstSeen
        self.updateCount = updateCount
    }

    /// Unit plane normal in world space (anchor local +Y).
    public var worldNormal: SIMD3<Float> {
        simd_normalize(SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z))
    }

    public var worldCenter: SIMD3<Float> {
        transform.transformPoint(center)
    }

    /// Boundary polygon in world space; falls back to the rotated extent rectangle when ARKit gave no geometry.
    public var worldBoundary: [SIMD3<Float>] {
        localPolygon.map { transform.transformPoint($0) }
    }

    /// Polygon area in m², from the boundary when available.
    public var area: Float {
        let pts = localPolygon.map { SIMD2($0.x, $0.z) }
        return PolygonMath.area(pts)
    }

    var localPolygon: [SIMD3<Float>] {
        if boundaryLocal.count >= 3 { return boundaryLocal }
        let hw = width / 2
        let hh = height / 2
        let c = cos(yaw)
        let s = sin(yaw)
        return [SIMD2(-hw, -hh), SIMD2(hw, -hh), SIMD2(hw, hh), SIMD2(-hw, hh)].map { p in
            // Rotation about +Y maps (x, z) -> (x cos + z sin, -x sin + z cos).
            SIMD3(center.x + p.x * c + p.y * s, center.y, center.z - p.x * s + p.y * c)
        }
    }
}

extension simd_float4x4 {
    @inlinable
    func transformPoint(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = self * SIMD4(p, 1)
        return SIMD3(v.x, v.y, v.z)
    }
}
