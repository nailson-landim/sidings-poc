import Foundation
import simd

/// `ARCamera.TrackingState`, as stored in `frame.tracking`.
public enum TrackingCode: Int, Sendable, Equatable {
    case notAvailable = 0
    case limited = 1
    case normal = 2
}

/// The reason for limited tracking, as stored in `frame.tracking_reason`.
public enum TrackingReason: Int, Sendable, Equatable {
    case none = 0
    case initializing = 1
    case excessiveMotion = 2
    case insufficientFeatures = 3
    case relocalizing = 4
}

/// Everything the recorder keeps from one `ARFrame` (one `frame` row). Built inside the delegate call; the frame
/// itself is never retained.
public struct FrameRecord: Sendable, Equatable {
    public var index: Int
    public var timestamp: TimeInterval
    public var hasImage: Bool
    public var tracking: TrackingCode
    public var trackingReason: TrackingReason
    /// `ARFrame.worldMappingStatus` raw value (0–3).
    public var mapping: Int
    /// World ← camera (`ARCamera.transform`).
    public var camera: simd_float4x4
    public var intrinsics: simd_float3x3
    public var exposure: TimeInterval
    /// `ProcessInfo.ThermalState` raw value (0–3).
    public var thermal: Int
    /// `rawFeaturePoints.points`, world coordinates.
    public var points: [SIMD3<Float>]
    /// `rawFeaturePoints.identifiers`, one per point.
    public var pointIDs: [UInt64]

    public init(
        index: Int,
        timestamp: TimeInterval,
        hasImage: Bool,
        tracking: TrackingCode,
        trackingReason: TrackingReason,
        mapping: Int,
        camera: simd_float4x4,
        intrinsics: simd_float3x3,
        exposure: TimeInterval,
        thermal: Int,
        points: [SIMD3<Float>],
        pointIDs: [UInt64]
    ) {
        self.index = index
        self.timestamp = timestamp
        self.hasImage = hasImage
        self.tracking = tracking
        self.trackingReason = trackingReason
        self.mapping = mapping
        self.camera = camera
        self.intrinsics = intrinsics
        self.exposure = exposure
        self.thermal = thermal
        self.points = points
        self.pointIDs = pointIDs
    }
}

/// `plane_anchor.event`.
public enum AnchorEvent: Int, Sendable, Equatable {
    case add = 0
    case update = 1
    case remove = 2
}

/// An ARKit plane anchor's shape at one callback. Absent for `remove`.
public struct AnchorGeometry: Sendable, Equatable {
    /// `ARPlaneAnchor.Alignment` raw value.
    public var alignment: Int
    /// `ARPlaneAnchor.Classification` raw value.
    public var classification: Int
    public var transform: simd_float4x4
    public var center: SIMD3<Float>
    /// `planeExtent`: width, height, rotationOnYAxis.
    public var extent: SIMD3<Float>
    /// `geometry.boundaryVertices`, anchor-local.
    public var boundary: [SIMD3<Float>]

    public init(
        alignment: Int,
        classification: Int,
        transform: simd_float4x4,
        center: SIMD3<Float>,
        extent: SIMD3<Float>,
        boundary: [SIMD3<Float>]
    ) {
        self.alignment = alignment
        self.classification = classification
        self.transform = transform
        self.center = center
        self.extent = extent
        self.boundary = boundary
    }
}

/// One ARKit plane callback (one `plane_anchor` row), stamped with the last logged frame.
public struct AnchorRecord: Sendable, Equatable {
    public var frameIndex: Int
    public var anchorID: UUID
    public var event: AnchorEvent
    /// nil for `remove`, which carries only the id.
    public var geometry: AnchorGeometry?

    public init(frameIndex: Int, anchorID: UUID, event: AnchorEvent, geometry: AnchorGeometry?) {
        self.frameIndex = frameIndex
        self.anchorID = anchorID
        self.event = event
        self.geometry = event == .remove ? nil : geometry
    }
}

/// One Core Location fix (one `location` row). Site metadata, never geometry (SPEC §3.3).
public struct LocationRecord: Sendable, Equatable {
    public var frameIndex: Int
    /// `CLLocation.timestamp`, seconds since 1970.
    public var utc: TimeInterval
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var ellipsoidalAltitude: Double
    public var horizontalAccuracy: Double
    public var verticalAccuracy: Double

    public init(
        frameIndex: Int,
        utc: TimeInterval,
        latitude: Double,
        longitude: Double,
        altitude: Double,
        ellipsoidalAltitude: Double,
        horizontalAccuracy: Double,
        verticalAccuracy: Double
    ) {
        self.frameIndex = frameIndex
        self.utc = utc
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.ellipsoidalAltitude = ellipsoidalAltitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
    }
}

/// One compass update (one `heading` row).
public struct HeadingRecord: Sendable, Equatable {
    public var frameIndex: Int
    /// `CLHeading.trueHeading`; −1 when invalid.
    public var trueHeading: Double
    public var magneticHeading: Double
    public var accuracy: Double

    public init(frameIndex: Int, trueHeading: Double, magneticHeading: Double, accuracy: Double) {
        self.frameIndex = frameIndex
        self.trueHeading = trueHeading
        self.magneticHeading = magneticHeading
        self.accuracy = accuracy
    }
}

/// A session event (one `event` row): tracking changes, interruptions, start and stop, user marks.
public struct EventRecord: Sendable, Equatable {
    public var frameIndex: Int
    public var kind: String
    public var detail: String

    public init(frameIndex: Int, kind: String, detail: String) {
        self.frameIndex = frameIndex
        self.kind = kind
        self.detail = detail
    }
}
