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

    /// One `plane_anchor` row. A remove carries only the id (SPEC §3.3).
    static func anchorRecord(_ anchor: ARPlaneAnchor, event: AnchorEvent, frameIndex: Int) -> AnchorRecord {
        guard event != .remove else {
            return AnchorRecord(frameIndex: frameIndex, anchorID: anchor.identifier, event: .remove, geometry: nil)
        }
        let extent = anchor.planeExtent
        let geometry = AnchorGeometry(
            alignment: anchor.alignment.rawValue,
            classification: ARPlaneAnchor.isClassificationSupported ? classificationCode(anchor.classification) : 0,
            transform: anchor.transform,
            center: anchor.center,
            extent: SIMD3(extent.width, extent.height, extent.rotationOnYAxis),
            boundary: anchor.geometry.boundaryVertices
        )
        return AnchorRecord(frameIndex: frameIndex, anchorID: anchor.identifier, event: event, geometry: geometry)
    }

    /// `ARPlaneClassification` raw values: none 0, wall 1, floor 2, ceiling 3, table 4, seat 5, window 6, door 7.
    static func classificationCode(_ classification: ARPlaneAnchor.Classification) -> Int {
        switch classification {
        case .wall: 1
        case .floor: 2
        case .ceiling: 3
        case .table: 4
        case .seat: 5
        case .window: 6
        case .door: 7
        default: 0
        }
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
