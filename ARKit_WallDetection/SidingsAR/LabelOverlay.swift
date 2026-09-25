import RealityKit
import UIKit

/// Plane labels as plain UIKit views projected onto the screen each frame.
/// Replaces per-plane `MeshResource.generateText` meshes, which were regenerated on nearly every anchor update and
/// were the largest source of GPU/heap churn.
@MainActor
final class LabelOverlay {
    private final class PaddedLabel: UILabel {
        static let insets = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)

        override func drawText(in rect: CGRect) {
            super.drawText(in: rect.inset(by: Self.insets))
        }

        override func sizeThatFits(_ size: CGSize) -> CGSize {
            let s = super.sizeThatFits(size)
            return CGSize(width: s.width + Self.insets.left + Self.insets.right, height: s.height + Self.insets.top + Self.insets.bottom)
        }
    }

    private struct Entry {
        let label: PaddedLabel
        var world: SIMD3<Float>
        var isVisible: Bool
    }

    let view: UIView = {
        let v = UIView()
        v.isUserInteractionEnabled = false
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return v
    }()

    private var entries: [UUID: Entry] = [:]

    /// Creates or updates a label. Text is only re-laid out when it actually changes.
    func set(id: UUID, text: String, world: SIMD3<Float>) {
        if entries[id] == nil {
            let label = PaddedLabel()
            label.numberOfLines = 0
            label.textAlignment = .center
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            label.textColor = .white
            label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
            label.layer.cornerRadius = 6
            label.layer.masksToBounds = true
            label.isHidden = true
            view.addSubview(label)
            entries[id] = Entry(label: label, world: world, isVisible: true)
        }
        entries[id]?.world = world
        entries[id]?.isVisible = true
        guard let label = entries[id]?.label, label.text != text else { return }
        label.text = text
        label.sizeToFit()
    }

    func hide(id: UUID) {
        guard entries[id] != nil else { return }
        entries[id]?.isVisible = false
        entries[id]?.label.isHidden = true
    }

    func remove(id: UUID) {
        entries.removeValue(forKey: id)?.label.removeFromSuperview()
    }

    func removeAll() {
        entries.values.forEach { $0.label.removeFromSuperview() }
        entries.removeAll()
    }

    /// Projects every visible label into screen space. Call once per rendered frame.
    func layout(in arView: ARView) {
        guard !entries.isEmpty else { return }
        let camera = arView.cameraTransform.matrix
        let cameraPosition = SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let forward = -SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
        let bounds = arView.bounds.insetBy(dx: -40, dy: -40)
        for entry in entries.values {
            guard entry.isVisible,
                  simd_dot(entry.world - cameraPosition, forward) > 0,
                  let point = arView.project(entry.world),
                  bounds.contains(point)
            else {
                entry.label.isHidden = true
                continue
            }
            entry.label.center = point
            entry.label.isHidden = false
        }
    }
}
