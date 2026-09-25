import RealityKit
import UIKit

/// Magenta debug spheres for one plane: anchor origin (large), extent center (medium), boundary vertices (small).
/// Sphere entities are pooled and reused across updates.
@MainActor
final class AnchorMarkers {
    static let maxBoundarySpheres = 64

    private static let material = UnlitMaterial(color: PlaneStyle.markerColor)
    private static let originMesh = MeshResource.generateSphere(radius: 0.02)
    private static let centerMesh = MeshResource.generateSphere(radius: 0.012)
    private static let vertexMesh = MeshResource.generateSphere(radius: 0.005)

    let root = Entity()
    private let origin = ModelEntity(mesh: AnchorMarkers.originMesh, materials: [AnchorMarkers.material])
    private let center = ModelEntity(mesh: AnchorMarkers.centerMesh, materials: [AnchorMarkers.material])
    private var vertices: [ModelEntity] = []

    init() {
        root.name = "markers"
        root.addChild(origin)
        root.addChild(center)
    }

    /// - Parameters:
    ///   - centerWorld: smoothed extent center in world space.
    ///   - boundaryLocal: boundary polygon in the anchor's local space.
    func update(centerWorld: SIMD3<Float>, boundaryLocal: [SIMD3<Float>]) {
        // `root` is a child of the AnchorEntity, so local zero is the anchor origin.
        origin.position = .zero
        center.setPosition(centerWorld, relativeTo: nil)

        let stride = max(1, Int((Double(boundaryLocal.count) / Double(Self.maxBoundarySpheres)).rounded(.up)))
        let sampled = Swift.stride(from: 0, to: boundaryLocal.count, by: stride).map { boundaryLocal[$0] }
        while vertices.count < sampled.count {
            let e = ModelEntity(mesh: Self.vertexMesh, materials: [Self.material])
            vertices.append(e)
            root.addChild(e)
        }
        for (i, e) in vertices.enumerated() {
            if i < sampled.count {
                e.isEnabled = true
                e.position = sampled[i]
            } else {
                e.isEnabled = false
            }
        }
    }
}
