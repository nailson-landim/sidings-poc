import OSLog
import PlaneKit
import RealityKit
import UIKit

/// The engine's tracked planes (`../EXPERIMENTS.md`): one fill per track, its convex outline in world space,
/// colored by track number. Tentative tracks are lighter and stale ones grey. Labels go through the shared
/// `LabelOverlay`.
///
/// Memory rules: one `DynamicMesh` per track, rebuilt only when the track's `version` changes; materials cached.
@MainActor
final class SurfaceRenderer {
    private static let palette: [UIColor] = [
        .systemOrange, .systemBlue, .systemTeal, .systemIndigo, .systemMint, .systemBrown, .systemYellow, .systemGreen,
    ]

    private final class Visual {
        let fill = DynamicMesh(name: "surface")
        var version = -1
        var material: MaterialKey?
    }

    private struct MaterialKey: Hashable {
        var color: UIColor
        var opacity: Float
    }

    private let logger = Logger(subsystem: "br.com.neuralnexgen.sidingsar", category: "surfaces")
    /// World-origin anchor: the tracks are in ARKit world coordinates.
    let anchor = AnchorEntity(world: .zero)
    private let labels: LabelOverlay
    private var visuals: [UUID: Visual] = [:]
    private var materials: [MaterialKey: UnlitMaterial] = [:]

    init(labels: LabelOverlay) {
        self.labels = labels
        anchor.name = "Tracked surfaces"
    }

    var isVisible = true {
        didSet {
            anchor.isEnabled = isVisible
            if !isVisible { visuals.keys.forEach(labels.hide) }
        }
    }

    func update(_ surfaces: [TrackedSurface]) {
        let live = Set(surfaces.map(\.id))
        for id in visuals.keys where !live.contains(id) {
            remove(id: id)
        }
        for surface in surfaces {
            let v = visuals[surface.id] ?? add(surface.id)
            let key = MaterialKey(color: Self.color(surface), opacity: Self.opacity(surface.state))
            if surface.version != v.version {
                let mesh = SurfaceMesh.fan(surface.outline)
                do {
                    try v.fill.update(positions: mesh.positions, indices: mesh.indices, material: material(key))
                } catch {
                    logger.error("Surface mesh update failed: \(error.localizedDescription, privacy: .public)")
                }
                v.version = surface.version
            }
            if key != v.material {
                v.fill.setMaterial(material(key))
                v.material = key
            }
            if isVisible && surface.state != .tentative {
                labels.set(id: surface.id, text: Self.label(surface), world: surface.center)
            } else {
                labels.hide(id: surface.id)
            }
        }
    }

    func removeAll() {
        for id in Array(visuals.keys) { remove(id: id) }
    }

    private func add(_ id: UUID) -> Visual {
        let v = Visual()
        anchor.addChild(v.fill.entity)
        visuals[id] = v
        return v
    }

    private func remove(id: UUID) {
        labels.remove(id: id)
        visuals.removeValue(forKey: id)?.fill.entity.removeFromParent()
    }

    private func material(_ key: MaterialKey) -> UnlitMaterial {
        if let cached = materials[key] { return cached }
        var m = UnlitMaterial(color: key.color)
        m.blending = .transparent(opacity: .init(floatLiteral: key.opacity))
        m.faceCulling = .none
        materials[key] = m
        return m
    }

    private static func color(_ surface: TrackedSurface) -> UIColor {
        surface.state == .stale ? .systemGray : palette[(surface.number - 1) % palette.count]
    }

    private static func opacity(_ state: TrackedSurface.State) -> Float {
        switch state {
        case .tentative: 0.15
        case .confirmed: 0.4
        case .stale: 0.2
        }
    }

    /// `#3  4.10 × 3.05 m  rms 1.9 cm`, plus the state when it isn't confirmed.
    private static func label(_ s: TrackedSurface) -> String {
        var text = String(format: "#%d  %.2f × %.2f m  rms %.1f cm", s.number, s.width, s.height, s.rmsError * 100)
        if s.state != .confirmed { text += "\n\(s.state.rawValue)" }
        return text
    }
}
