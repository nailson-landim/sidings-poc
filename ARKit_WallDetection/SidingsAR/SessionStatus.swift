import ARKit

enum DetectionMode: String, CaseIterable, Identifiable {
    case vertical = "Vertical"
    case horizontal = "Horizontal"
    case both = "Both"

    var id: String { rawValue }

    var planeDetection: ARWorldTrackingConfiguration.PlaneDetection {
        switch self {
        case .vertical: [.vertical]
        case .horizontal: [.horizontal]
        case .both: [.horizontal, .vertical]
        }
    }
}

extension ARCamera.TrackingState {
    /// Human-readable HUD text; `nil` when tracking is normal.
    var banner: String? {
        switch self {
        case .normal: nil
        case .notAvailable: "Tracking not available"
        case .limited(.initializing): "Limited: initializing — move the phone slowly"
        case .limited(.excessiveMotion): "Limited: excessive motion — slow down"
        case .limited(.insufficientFeatures): "Limited: insufficient features — point at textured surfaces"
        case .limited(.relocalizing): "Limited: relocalizing — return to where you started"
        case .limited: "Limited tracking"
        }
    }

    var shortName: String {
        switch self {
        case .normal: "normal"
        case .notAvailable: "n/a"
        case .limited: "limited"
        }
    }
}
