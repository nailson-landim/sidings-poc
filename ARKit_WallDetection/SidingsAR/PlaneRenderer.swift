import ARKit
import OSLog
import PlaneKit
import RealityKit
import UIKit

/// Owns the RealityKit entities for every plane anchor: fill mesh, billboard label and markers.
@MainActor
final class PlaneRenderer {
    /// Minimum seconds between mesh rebuilds per plane.
    static let meshRebuildInterval: TimeInterval = 0.1
    /// Relative area change that forces a rebuild regardless of vertex count.
    static let meshRebuildAreaDelta: Float = 0.05

    private final class Visual {
        let anchorEntity: AnchorEntity
        let fill = ModelEntity()
        let label = Entity()
        let markers = AnchorMarkers()
        var labelText = ""
        var lastRebuild: TimeInterval = 0
        var lastVertexCount = 0
        var lastArea: Float = 0
        var color: UIColor = .clear

        init(anchor: ARAnchor) {
            anchorEntity = AnchorEntity(anchor: anchor)
            label.components.set(BillboardComponent())
            anchorEntity.addChild(fill)
            anchorEntity.addChild(label)
            anchorEntity.addChild(markers.root)
        }
    }

    private let logger = Logger(subsystem: "br.com.neuralnexgen.sidingsar", category: "renderer")
    private let scene: RealityKit.Scene
    private var visuals: [UUID: Visual] = [:]

    var showMarkers = true {
        didSet { visuals.values.forEach { $0.markers.root.isEnabled = showMarkers } }
    }

    var count: Int { visuals.count }

    init(scene: RealityKit.Scene) {
        self.scene = scene
    }

    func add(_ anchor: ARPlaneAnchor) {
        guard visuals[anchor.identifier] == nil else { return }
        let v = Visual(anchor: anchor)
        v.markers.root.isEnabled = showMarkers
        visuals[anchor.identifier] = v
        scene.addAnchor(v.anchorEntity)
    }

    func remove(id: UUID) {
        guard let v = visuals.removeValue(forKey: id) else { return }
        scene.removeAnchor(v.anchorEntity)
    }

    func removeAll() {
        visuals.values.forEach { scene.removeAnchor($0.anchorEntity) }
        visuals.removeAll()
    }

    func update(anchor: ARPlaneAnchor, observation: PlaneObservation, state: PlaneState, hideSuppressed: Bool, now: TimeInterval) {
        guard let v = visuals[anchor.identifier] else { return }

        let color = PlaneStyle.color(for: observation)
        let vertexCount = anchor.geometry.vertices.count
        let area = observation.area
        let areaChanged = v.lastArea == 0 || abs(area - v.lastArea) / v.lastArea > Self.meshRebuildAreaDelta
        let due = now - v.lastRebuild >= Self.meshRebuildInterval
        if color != v.color || (due && (vertexCount != v.lastVertexCount || areaChanged)) {
            rebuildFill(v, geometry: anchor.geometry, color: color)
            v.lastRebuild = now
            v.lastVertexCount = vertexCount
            v.lastArea = area
            v.color = color
        }

        // Suppressed planes stay alive (ARKit owns them) but are dimmed or hidden.
        v.anchorEntity.isEnabled = !(state.isSuppressed && hideSuppressed)
        v.fill.components.set(OpacityComponent(opacity: state.isSuppressed ? PlaneStyle.suppressedOpacity : 1))
        v.label.isEnabled = !state.isSuppressed

        let text = PlaneStyle.label(for: observation, width: state.smoothed.width, height: state.smoothed.height)
        if text != v.labelText {
            rebuildLabel(v, text: text)
            v.labelText = text
        }
        // Float the label slightly off the surface, along the plane normal.
        v.label.setPosition(state.smoothed.center + observation.worldNormal * 0.02, relativeTo: nil)

        v.markers.update(centerWorld: state.smoothed.center, boundaryLocal: observation.boundaryLocal)
    }

    private func rebuildFill(_ v: Visual, geometry: ARPlaneGeometry, color: UIColor) {
        var descriptor = MeshDescriptor(name: "plane")
        descriptor.positions = MeshBuffers.Positions(geometry.vertices)
        descriptor.primitives = .triangles(geometry.triangleIndices.map { UInt32($0) })
        do {
            let mesh = try MeshResource.generate(from: [descriptor])
            var material = UnlitMaterial(color: color)
            material.blending = .transparent(opacity: .init(floatLiteral: PlaneStyle.fillOpacity))
            material.faceCulling = .none
            v.fill.model = ModelComponent(mesh: mesh, materials: [material])
        } catch {
            logger.error("Plane mesh generation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rebuildLabel(_ v: Visual, text: String) {
        v.label.children.removeAll()
        let mesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.001,
            font: .systemFont(ofSize: 0.04, weight: .semibold),
            alignment: .center
        )
        let textEntity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .white)])
        let bounds = mesh.bounds
        textEntity.position = -bounds.center

        let padding: Float = 0.015
        var background = UnlitMaterial(color: .black)
        background.blending = .transparent(opacity: .init(floatLiteral: 0.6))
        let backgroundEntity = ModelEntity(
            mesh: .generatePlane(width: bounds.extents.x + padding * 2, height: bounds.extents.y + padding * 2, cornerRadius: 0.01),
            materials: [background]
        )
        backgroundEntity.position = SIMD3(0, 0, -0.002)

        v.label.addChild(backgroundEntity)
        v.label.addChild(textEntity)
    }
}
