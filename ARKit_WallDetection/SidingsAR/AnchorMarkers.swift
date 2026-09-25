import OSLog
import PlaneKit
import RealityKit
import UIKit

/// Magenta debug markers for one plane: anchor origin (large sphere), extent center (medium sphere) and every
/// boundary vertex (small octahedra, all baked into a single mesh). That is 3 entities per plane instead of 2 + N.
@MainActor
final class AnchorMarkers {
    static let maxBoundaryPoints = 64
    static let boundaryRadius: Float = 0.006

    private static let material: UnlitMaterial = {
        var m = UnlitMaterial(color: PlaneStyle.markerColor)
        m.faceCulling = .none
        return m
    }()
    private static let originMesh = MeshResource.generateSphere(radius: 0.02)
    private static let centerMesh = MeshResource.generateSphere(radius: 0.012)
    private static let logger = Logger(subsystem: "br.com.neuralnexgen.sidingsar", category: "markers")

    let root = Entity()
    private let origin = ModelEntity(mesh: AnchorMarkers.originMesh, materials: [AnchorMarkers.material])
    private let center = ModelEntity(mesh: AnchorMarkers.centerMesh, materials: [AnchorMarkers.material])
    private let boundary = DynamicMesh(name: "boundary")

    init() {
        root.name = "markers"
        // `root` is a child of the AnchorEntity, so local zero is the anchor origin.
        root.addChild(origin)
        root.addChild(center)
        root.addChild(boundary.entity)
    }

    func updateCenter(world: SIMD3<Float>) {
        center.setPosition(world, relativeTo: nil)
    }

    /// - Parameter boundaryLocal: boundary polygon in the anchor's local space.
    func updateBoundary(_ boundaryLocal: [SIMD3<Float>]) {
        let points = PointMarkerMesh.subsample(boundaryLocal, limit: Self.maxBoundaryPoints)
        let (positions, indices) = PointMarkerMesh.octahedra(centers: points, radius: Self.boundaryRadius)
        do {
            try boundary.update(positions: positions, indices: indices, material: Self.material)
        } catch {
            Self.logger.error("Boundary marker mesh failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
