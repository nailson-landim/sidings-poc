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

/// One `cloud` row (schema v2, SPEC P23): the phone's averaged cloud after `frameIndex`, either whole (`full`) or as
/// the changes since the previous row (remove `removed`, then set every id in `set`).
public struct CloudRecord: Sendable, Equatable {
    public var frameIndex: Int
    public var full: Bool
    public var removed: [UInt64]
    public var set: CloudState

    public init(frameIndex: Int, full: Bool, removed: [UInt64] = [], set: CloudState) {
        self.frameIndex = frameIndex
        self.full = full
        self.removed = removed
        self.set = set
    }
}

/// One X1 track's shape when it was written (schema v3, `../../EXPERIMENTS.md` XD6). Absent for `remove`.
public struct SurfaceGeometry: Sendable, Equatable {
    /// `surface.state`: 0 tentative, 1 confirmed, 2 stale.
    public var state: Int
    public var normal: SIMD3<Float>
    public var center: SIMD3<Float>
    /// Convex hull of the inliers on the plane, ARKit world.
    public var outline: [SIMD3<Float>]
    public var width: Float
    public var height: Float
    public var rmsError: Float
    /// Inlier feature ids the track holds.
    public var inliers: Int

    public init(
        state: Int, normal: SIMD3<Float>, center: SIMD3<Float>, outline: [SIMD3<Float>], width: Float, height: Float,
        rmsError: Float, inliers: Int
    ) {
        self.state = state
        self.normal = normal
        self.center = center
        self.outline = outline
        self.width = width
        self.height = height
        self.rmsError = rmsError
        self.inliers = inliers
    }
}

/// One `surface` row (schema v3): an X1 track added, updated or removed, stamped with the last recorded frame when its
/// round started. A remove carries only the id and number, plus `mergedInto` when the track merged into an older one.
public struct SurfaceRecord: Sendable, Equatable {
    public var frameIndex: Int
    public var surfaceID: UUID
    public var number: Int
    public var event: AnchorEvent
    /// nil for `remove`.
    public var geometry: SurfaceGeometry?
    public var mergedInto: UUID?

    public init(
        frameIndex: Int, surfaceID: UUID, number: Int, event: AnchorEvent, geometry: SurfaceGeometry?,
        mergedInto: UUID? = nil
    ) {
        self.frameIndex = frameIndex
        self.surfaceID = surfaceID
        self.number = number
        self.event = event
        self.geometry = event == .remove ? nil : geometry
        self.mergedInto = event == .remove ? mergedInto : nil
    }
}

/// One `surface_round` row (schema v4, `../../EXPERIMENTS.md` XD16): what a round of the plane engine cost, stamped with
/// the last recorded frame when it started.
public struct SurfaceRoundRecord: Sendable, Equatable {
    public var frameIndex: Int
    public var round: Int
    public var points: Int
    public var unclaimed: Int
    public var tracks: Int
    public var confirmed: Int
    public var refits: Int
    public var searched: Bool
    public var planesFound: Int
    public var hypotheses: Int
    public var fullScores: Int
    public var pointTests: Int
    public var totalMilliseconds: Double
    public var refitMilliseconds: Double
    public var searchMilliseconds: Double
    /// Rounds skipped so far because the previous one was still running.
    public var skipped: Int
    /// `ProcessInfo.ThermalState` raw value: 0 nominal, 1 fair, 2 serious, 3 critical.
    public var thermal: Int

    public init(
        frameIndex: Int, round: Int, points: Int, unclaimed: Int, tracks: Int, confirmed: Int, refits: Int,
        searched: Bool, planesFound: Int, hypotheses: Int, fullScores: Int, pointTests: Int, totalMilliseconds: Double,
        refitMilliseconds: Double, searchMilliseconds: Double, skipped: Int, thermal: Int
    ) {
        self.frameIndex = frameIndex
        self.round = round
        self.points = points
        self.unclaimed = unclaimed
        self.tracks = tracks
        self.confirmed = confirmed
        self.refits = refits
        self.searched = searched
        self.planesFound = planesFound
        self.hypotheses = hypotheses
        self.fullScores = fullScores
        self.pointTests = pointTests
        self.totalMilliseconds = totalMilliseconds
        self.refitMilliseconds = refitMilliseconds
        self.searchMilliseconds = searchMilliseconds
        self.skipped = skipped
        self.thermal = thermal
    }
}
