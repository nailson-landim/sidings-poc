import RealityKit

extension MeshResource.Contents {
    /// Single model / single part contents, the shape `MeshResource.replace(with:)` expects for simple meshes.
    init(name: String, positions: [SIMD3<Float>], indices: [UInt32]) {
        var part = MeshResource.Part(id: "\(name)-part", materialIndex: 0)
        part.positions = MeshBuffers.Positions(positions)
        part.triangleIndices = MeshBuffers.TriangleIndices(indices)
        self.init()
        models = [MeshResource.Model(id: name, parts: [part])]
        instances = [MeshResource.Instance(id: "\(name)-0", model: name)]
    }
}

/// A `ModelEntity` whose `MeshResource` is allocated once and then updated in place.
/// Avoids the allocate/release churn of generating a fresh resource + `ModelComponent` per update.
@MainActor
final class DynamicMesh {
    let entity = ModelEntity()
    private let name: String
    private var mesh: MeshResource?

    init(name: String) {
        self.name = name
    }

    func update(positions: [SIMD3<Float>], indices: [UInt32], material: @autoclosure () -> any Material) throws {
        guard !positions.isEmpty, !indices.isEmpty else {
            entity.isEnabled = false
            return
        }
        entity.isEnabled = true
        let contents = MeshResource.Contents(name: name, positions: positions, indices: indices)
        if let mesh {
            try mesh.replace(with: contents)
        } else {
            let created = try MeshResource.generate(from: contents)
            mesh = created
            entity.model = ModelComponent(mesh: created, materials: [material()])
        }
    }

    func setMaterial(_ material: any Material) {
        entity.model?.materials = [material]
    }
}
