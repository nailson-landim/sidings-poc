import OSLog
import PlaneKit
import RealityKit
import UIKit

/// The live averaged cloud (`../SPEC.md` L12, T28, P24): one entity whose mesh has one part per sample-count band,
/// colored like Blender's layer (under 10 samples pale pink, 10–49 magenta, 50+ red). Each point is a square facing
/// the camera, sized by distance so it stays about 10 px across. The mesh is generated once and then replaced in
/// place, like `DynamicMesh`, but with one part and material per band.
@MainActor
final class CloudRenderer {
    /// Square half-size per metre of distance (`CloudMesh.billboards`).
    static let size: Float = 0.003
    /// Points drawn at most, evenly strided beyond it. The HUD count is still the whole cloud.
    static let maxPoints = 40_000

    private static let materials: [UnlitMaterial] = [
        UIColor(red: 1.0, green: 0.6, blue: 0.8, alpha: 1),
        UIColor(red: 0.9, green: 0.2, blue: 1.0, alpha: 1),
        UIColor(red: 1.0, green: 0.1, blue: 0.1, alpha: 1),
    ].map { color in
        var material = UnlitMaterial(color: color)
        material.faceCulling = .none
        return material
    }

    private static let logger = Logger(subsystem: "br.com.neuralnexgen.sidingsar", category: "cloud")

    /// World-origin anchor: the cloud's points are ARKit world coordinates.
    let anchor = AnchorEntity(world: .zero)
    private let entity = ModelEntity()
    private var mesh: MeshResource?

    init() {
        anchor.name = "averaged cloud"
        anchor.addChild(entity)
        entity.isEnabled = false
    }

    func update(_ state: CloudState, camera: simd_float4x4) {
        let bands = CloudMesh.billboards(state, camera: camera, size: Self.size, limit: Self.maxPoints)
        var parts: [MeshResource.Part] = []
        for (index, band) in bands.enumerated() where !band.positions.isEmpty {
            var part = MeshResource.Part(id: "cloud-\(index)", materialIndex: index)
            part.positions = MeshBuffers.Positions(band.positions)
            part.triangleIndices = MeshBuffers.TriangleIndices(band.indices)
            parts.append(part)
        }
        guard !parts.isEmpty else {
            entity.isEnabled = false
            return
        }
        var contents = MeshResource.Contents()
        contents.models = [MeshResource.Model(id: "cloud", parts: parts)]
        contents.instances = [MeshResource.Instance(id: "cloud-0", model: "cloud")]
        do {
            if let mesh {
                try mesh.replace(with: contents)
            } else {
                let created = try MeshResource.generate(from: contents)
                mesh = created
                entity.model = ModelComponent(mesh: created, materials: Self.materials)
            }
            entity.isEnabled = true
        } catch {
            Self.logger.error("Cloud mesh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clear() {
        entity.isEnabled = false
    }
}
