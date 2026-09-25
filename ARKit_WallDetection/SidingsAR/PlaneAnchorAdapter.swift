import ARKit
import PlaneKit

extension PlaneClass {
    init(_ c: ARPlaneAnchor.Classification) {
        switch c {
        case .wall: self = .wall
        case .floor: self = .floor
        case .ceiling: self = .ceiling
        case .table: self = .table
        case .seat: self = .seat
        case .door: self = .door
        case .window: self = .window
        default: self = .none
        }
    }
}

extension PlaneObservation {
    /// Snapshot of an ARKit plane anchor. `previous` carries lifetime bookkeeping across updates.
    init(anchor: ARPlaneAnchor, previous: PlaneObservation?, now: TimeInterval) {
        self.init(
            id: anchor.identifier,
            alignment: anchor.alignment == .vertical ? .vertical : .horizontal,
            classification: ARPlaneAnchor.isClassificationSupported ? PlaneClass(anchor.classification) : .none,
            transform: anchor.transform,
            center: anchor.center,
            width: anchor.planeExtent.width,
            height: anchor.planeExtent.height,
            yaw: anchor.planeExtent.rotationOnYAxis,
            boundaryLocal: anchor.geometry.boundaryVertices,
            firstSeen: previous?.firstSeen ?? now,
            updateCount: (previous?.updateCount ?? -1) + 1
        )
    }
}
