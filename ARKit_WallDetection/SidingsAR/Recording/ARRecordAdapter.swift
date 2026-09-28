import ARKit
import PlaneKit

/// Converts ARKit types into PlaneKit recording records (`../SPEC.md` §17.4 P13). Together with `PlaneAnchorAdapter`
/// for the viewer, it's the only place that reads ARKit types. Everything is copied out inside the delegate call,
/// so no `ARFrame` or anchor outlives it.
enum ARRecordAdapter {
    /// The frame's metadata. `index` and `hasImage` are placeholders; `SessionWriter` sets both.
    static func frameRecord(_ frame: ARFrame) -> FrameRecord {
        let camera = frame.camera
        let (tracking, reason) = codes(camera.trackingState)
        let features = frame.rawFeaturePoints
        return FrameRecord(
            index: 0,
            timestamp: frame.timestamp,
            hasImage: false,
            tracking: tracking,
            trackingReason: reason,
            mapping: frame.worldMappingStatus.rawValue,
            camera: camera.transform,
            intrinsics: camera.intrinsics,
            exposure: camera.exposureDuration,
            thermal: ProcessInfo.processInfo.thermalState.rawValue,
            points: features?.points ?? [],
            pointIDs: features?.identifiers ?? []
        )
    }

    static func codes(_ state: ARCamera.TrackingState) -> (TrackingCode, TrackingReason) {
        switch state {
        case .notAvailable: (.notAvailable, .none)
        case .normal: (.normal, .none)
        case .limited(.initializing): (.limited, .initializing)
        case .limited(.excessiveMotion): (.limited, .excessiveMotion)
        case .limited(.insufficientFeatures): (.limited, .insufficientFeatures)
        case .limited(.relocalizing): (.limited, .relocalizing)
        case .limited: (.limited, .none)
        }
    }
}
