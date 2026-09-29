import Foundation

/// Every recorder setting in one place (SPEC L8, §4 R14). Edit and rebuild; each recording stores them in `meta`
/// as `const.<name>`. Tests build a modified copy instead of changing this file.
public struct RecorderConstants: Sendable, Equatable {
    /// Video frame rate. A log frame's image has presentation time `idx / videoFPS`.
    public var videoFPS = 60
    public var videoBitrate = 8_000_000
    /// Longest gap between keyframes, so seeking in Blender stays fast.
    public var keyframeIntervalS = 0.5
    /// Movie fragment length: a killed recording still plays up to its last fragment.
    public var fragmentIntervalS = 1.0
    /// Pixel buffers the recorder may hold (copies waiting for, or inside, the encoder). When all are in use the
    /// frame's image is skipped (`has_image = 0`) and its metadata is still logged.
    /// 6 since T10 (was 4): headroom while the encoder starts, when every recording lost images at frames 5–9.
    public var pixelPoolSize = 6
    /// One SQLite transaction per this interval.
    public var commitIntervalS = 0.5
    /// Frames the write queue may hold before whole frames are dropped.
    public var writeQueueFrames = 120
    /// Recording stops by itself below this much free space.
    public var lowDiskBytes: Int64 = 1_000_000_000
    public var headingFilterDeg = 1.0

    // Averaged cloud (L12, P21): CurvSurf's accumulator with Plane Lab's defaults. The Mac rebuilds its LabConfig
    // from these `const.cloud*` rows to recompute the same cloud.
    public var cloudNearCutM = 0.25
    /// 0 keeps every distance.
    public var cloudFarCutM = 0.0
    public var cloudNormalTrackingOnly = false
    public var cloudGate = CloudGate.off
    public var cloudMoveM = 0.03
    public var cloudTurnDeg = 3.0
    public var cloudMaxSamples = 100
    public var cloudMinSamples = 5
    public var cloudZScore = 2.0
    public var cloudMaxIds = 100_000
    /// While recording, one `cloud` row every this many recorded frames (P23), and one at Stop.
    public var cloudSnapshotEvery = 6
    /// Every this many rows (and the first) is a full copy of the cloud; the others hold changes.
    public var cloudFullEvery = 50

    public init() {}

    public var cloudSettings: CloudSettings {
        CloudSettings(
            nearCutM: cloudNearCutM, farCutM: cloudFarCutM, normalTrackingOnly: cloudNormalTrackingOnly,
            gate: cloudGate, moveM: cloudMoveM, turnDeg: cloudTurnDeg, maxSamples: cloudMaxSamples,
            minSamples: cloudMinSamples, zScore: cloudZScore, maxIds: cloudMaxIds
        )
    }

    public static let current = RecorderConstants()

    /// One `meta` row per stored property, read by reflection so a new constant can't be left out.
    public var metaRows: [(key: String, value: String)] {
        Mirror(reflecting: self).children.compactMap { child in
            child.label.map { ("const.\($0)", "\(child.value)") }
        }
    }
}
