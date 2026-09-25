import ARKit
import OSLog
import PlaneKit
import RealityKit
import UIKit

/// Owns the RealityKit entities for every plane anchor (fill mesh + markers) and its screen-space label.
///
/// Memory rules:
/// - one `MeshResource` per plane fill and per boundary-marker mesh, updated in place (`DynamicMesh`);
/// - rebuilds gated by real geometry change and a minimum interval (slower for suppressed planes);
/// - materials cached per color; labels are UIKit, not text meshes;
/// - suppressed planes get no markers and no label.
@MainActor
final class PlaneRenderer {
    static let visibleRebuildInterval: TimeInterval = 0.25
    static let suppressedRebuildInterval: TimeInterval = 1.0

    private final class Visual {
        let anchorEntity: AnchorEntity
        let fill = DynamicMesh(name: "plane")
        let markers = AnchorMarkers()
        var gate = RebuildGate()
        var color: UIColor?
        var isSuppressed: Bool?
        /// Boundary markers lag the fill until the plane is visible with markers on.
        var boundaryStale = true

        init(anchor: ARAnchor) {
            anchorEntity = AnchorEntity(anchor: anchor)
            anchorEntity.addChild(fill.entity)
            anchorEntity.addChild(markers.root)
        }
    }

    private let logger = Logger(subsystem: "br.com.neuralnexgen.sidingsar", category: "renderer")
    private let scene: RealityKit.Scene
    let labels = LabelOverlay()
    private var visuals: [UUID: Visual] = [:]
    private var materials: [UIColor: UnlitMaterial] = [:]

    var showMarkers = true

    init(scene: RealityKit.Scene) {
        self.scene = scene
    }

    func add(_ anchor: ARPlaneAnchor) {
        guard visuals[anchor.identifier] == nil else { return }
        let v = Visual(anchor: anchor)
        v.markers.root.isEnabled = false
        visuals[anchor.identifier] = v
        scene.addAnchor(v.anchorEntity)
    }

    func remove(id: UUID) {
        labels.remove(id: id)
        guard let v = visuals.removeValue(forKey: id) else { return }
        scene.removeAnchor(v.anchorEntity)
    }

    func removeAll() {
        labels.removeAll()
        visuals.values.forEach { scene.removeAnchor($0.anchorEntity) }
        visuals.removeAll()
    }

    /// Applies the latest tracker state to one plane.
    /// - Returns: `true` when a geometry change was deferred by the rebuild gate, so the caller should retry later.
    @discardableResult
    func update(
        anchor: ARPlaneAnchor, observation: PlaneObservation, state: PlaneState, hideSuppressed: Bool,
        hideAll: Bool = false, now: TimeInterval
    ) -> Bool {
        guard let v = visuals[anchor.identifier] else { return false }
        let suppressed = state.isSuppressed

        let hidden = (suppressed && hideSuppressed) || hideAll
        v.anchorEntity.isEnabled = !hidden
        if v.isSuppressed != suppressed {
            v.fill.entity.components.set(OpacityComponent(opacity: suppressed ? PlaneStyle.suppressedOpacity : 1))
            v.isSuppressed = suppressed
        }
        if hidden || suppressed {
            labels.hide(id: anchor.identifier)
            v.markers.root.isEnabled = false
        }
        guard !hidden else { return false }

        let color = PlaneStyle.color(for: observation)
        if color != v.color {
            v.fill.setMaterial(material(for: color))
            v.color = color
        }

        let vertexCount = anchor.geometry.vertices.count
        let area = observation.area
        let interval = suppressed ? Self.suppressedRebuildInterval : Self.visibleRebuildInterval
        var pending = false
        if v.gate.shouldRebuild(now: now, vertexCount: vertexCount, area: area, minInterval: interval) {
            rebuildFill(v, geometry: anchor.geometry, color: color)
            v.boundaryStale = true
        } else {
            pending = v.gate.hasChanged(vertexCount: vertexCount, area: area)
        }

        guard !suppressed else { return pending }

        v.markers.root.isEnabled = showMarkers
        if showMarkers {
            if v.boundaryStale {
                v.markers.updateBoundary(observation.boundaryLocal)
                v.boundaryStale = false
            }
            v.markers.updateCenter(world: state.smoothed.center)
        }
        let text = PlaneStyle.label(for: observation, width: state.smoothed.width, height: state.smoothed.height)
        labels.set(id: anchor.identifier, text: text, world: state.smoothed.center)
        return pending
    }

    private func rebuildFill(_ v: Visual, geometry: ARPlaneGeometry, color: UIColor) {
        do {
            try v.fill.update(
                positions: geometry.vertices,
                indices: geometry.triangleIndices.map { UInt32($0) },
                material: material(for: color)
            )
        } catch {
            logger.error("Plane mesh update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func material(for color: UIColor) -> UnlitMaterial {
        if let cached = materials[color] { return cached }
        var m = UnlitMaterial(color: color)
        m.blending = .transparent(opacity: .init(floatLiteral: PlaneStyle.fillOpacity))
        m.faceCulling = .none
        materials[color] = m
        return m
    }
}
