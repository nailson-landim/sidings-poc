import Foundation
import simd

/// Which frames may add samples to the averaged cloud (stage 3, `../SPEC.md` §5.1). Same modes as Plane Lab's
/// `GateConfig.mode`, minus the per-point `parallax` gate (P21).
public enum CloudGate: String, Sendable, Equatable, CaseIterable {
    /// Every frame. Plane Lab's default: on real recordings it gives the same cloud as `upstream`.
    case off
    /// The documented rule: the camera moved at least `moveM`, or turned at least `turnDeg`, since the last passing
    /// frame.
    case intended
    /// CurvSurf's `CameraMotionDetector` as coded: `distance² < move²` passes, so frames that moved *less* pass.
    case upstream
}

/// Stages 2–4 of the averaged cloud: the point filter, the frame gate and CurvSurf's accumulator
/// (`../SPEC.md` §5.1, P21). Mirrors Plane Lab's `FilterConfig`, `GateConfig` and `AccumulateConfig`, with the same
/// defaults, which are CurvSurf's. The phone's values are `RecorderConstants.cloud*`.
public struct CloudSettings: Sendable, Equatable {
    /// Points at or closer than this to the camera are dropped (CurvSurf: 0.25 m).
    public var nearCutM: Double
    /// Points farther than this are dropped; 0 keeps every distance.
    public var farCutM: Double
    /// Skip frames whose tracking isn't normal.
    public var normalTrackingOnly: Bool
    public var gate: CloudGate
    public var moveM: Double
    public var turnDeg: Double
    /// FIFO length per feature id (CurvSurf: 100).
    public var maxSamples: Int
    /// An averaged point exists from this many samples on (CurvSurf: 5).
    public var minSamples: Int
    /// Samples farther than `zScore` sigma from their mean are left out of the average (CurvSurf: 2).
    public var zScore: Double
    /// Beyond this many ids, the oldest by first sighting is evicted (CurvSurf: 100 000).
    public var maxIds: Int

    public init(
        nearCutM: Double = 0.25,
        farCutM: Double = 0,
        normalTrackingOnly: Bool = false,
        gate: CloudGate = .off,
        moveM: Double = 0.03,
        turnDeg: Double = 3,
        maxSamples: Int = 100,
        minSamples: Int = 5,
        zScore: Double = 2,
        maxIds: Int = 100_000
    ) {
        self.nearCutM = nearCutM
        self.farCutM = farCutM
        self.normalTrackingOnly = normalTrackingOnly
        self.gate = gate
        self.moveM = moveM
        self.turnDeg = turnDeg
        self.maxSamples = maxSamples
        self.minSamples = minSamples
        self.zScore = zScore
        self.maxIds = maxIds
    }
}

/// Stage 2: whether a point is kept, by its distance from the camera. Computed in Double like Plane Lab's
/// `keep_points`, so both sides agree on points right at a cut.
public struct CloudPointFilter: Sendable, Equatable {
    private let nearSquared: Double
    private let farSquared: Double?

    public init(_ settings: CloudSettings) {
        nearSquared = settings.nearCutM * settings.nearCutM
        farSquared = settings.farCutM > 0 ? settings.farCutM * settings.farCutM : nil
    }

    public func keeps(_ point: SIMD3<Float>, eye: SIMD3<Double>) -> Bool {
        let distanceSquared = simd_distance_squared(SIMD3<Double>(point), eye)
        guard distanceSquared > nearSquared else { return false }
        if let farSquared { return distanceSquared <= farSquared }
        return true
    }
}

/// Stage 3: CurvSurf's `CameraMotionDetector`. The reference position and view direction start at zero; a passing
/// frame becomes the new reference. Same arithmetic as Plane Lab's `FrameGate` (Double, `-Z` column as the view).
public struct CloudFrameGate: Sendable, Equatable {
    public let gate: CloudGate
    private let moveSquared: Double
    private let minCos: Double
    private var position = SIMD3<Double>.zero
    private var direction = SIMD3<Double>.zero

    public init(_ settings: CloudSettings) {
        gate = settings.gate
        moveSquared = settings.moveM * settings.moveM
        minCos = cos(settings.turnDeg * (Double.pi / 180))
    }

    /// Whether this frame's points may reach the accumulator. `camera` is world ← camera.
    public mutating func accept(camera: simd_float4x4) -> Bool {
        guard gate != .off else { return true }
        let now = SIMD3<Double>(Double(camera.columns.3.x), Double(camera.columns.3.y), Double(camera.columns.3.z))
        let view = -SIMD3<Double>(Double(camera.columns.2.x), Double(camera.columns.2.y), Double(camera.columns.2.z))
        let distanceSquared = simd_distance_squared(now, position)
        let moved = gate == .upstream ? distanceSquared < moveSquared : distanceSquared >= moveSquared
        let turned = simd_dot(view, direction) < minCos
        guard moved || turned else { return false }
        position = now
        direction = view
        return true
    }
}
