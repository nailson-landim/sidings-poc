import Foundation

/// Why a recording stopped: `meta.stop_reason` (SPEC §3.3, §4 R3, R9).
public enum StopReason: String, Sendable, CaseIterable {
    /// The Stop button.
    case user
    /// The Reset button.
    case reset
    /// The detection picker changed, which restarts the session.
    case modeChange = "mode_change"
    /// The AR view went away (`onDisappear`).
    case pause
    /// The app went to the background.
    case background
    /// ARKit interrupted the session (for example, another app took the camera).
    case interruption
    /// The session or the writer failed.
    case error
    /// Free space fell below `RecorderConstants.lowDiskBytes`.
    case lowDisk = "low_disk"
}

/// Stops a recording before the disk fills (SPEC §4 R9).
public struct DiskGuard: Sendable, Equatable {
    public let minimumFreeBytes: Int64

    public init(minimumFreeBytes: Int64) {
        self.minimumFreeBytes = minimumFreeBytes
    }

    public init(constants: RecorderConstants) {
        self.init(minimumFreeBytes: constants.lowDiskBytes)
    }

    /// True when the recording must stop. An unknown free-space value never stops it.
    public func shouldStop(freeBytes: Int64?) -> Bool {
        guard let freeBytes else { return false }
        return freeBytes < minimumFreeBytes
    }
}

/// Turns the tracking state of every frame into `event` rows: one when recording starts, then one per change
/// (SPEC §3.3). Relocalization shows up as `limited/relocalizing`.
public struct TrackingChangeDetector: Sendable, Equatable {
    private var last: String?

    public init() {}

    /// The event detail when the state differs from the previous call, nil otherwise.
    public mutating func observe(_ tracking: TrackingCode, _ reason: TrackingReason) -> String? {
        let detail = Self.detail(tracking, reason)
        guard detail != last else { return nil }
        last = detail
        return detail
    }

    /// `normal`, `not_available`, `limited`, or `limited/<reason>`.
    public static func detail(_ tracking: TrackingCode, _ reason: TrackingReason) -> String {
        switch (tracking, reason) {
        case (.normal, _): "normal"
        case (.notAvailable, _): "not_available"
        case (.limited, .none): "limited"
        case (.limited, .initializing): "limited/initializing"
        case (.limited, .excessiveMotion): "limited/excessive_motion"
        case (.limited, .insufficientFeatures): "limited/insufficient_features"
        case (.limited, .relocalizing): "limited/relocalizing"
        }
    }
}

/// Where missing images come from, so a burst can be explained afterwards (SPEC §3.3 `image_skip.*`, T10).
public struct ImageSkipLog: Sendable, Equatable {
    /// Missing images by reason: `no_buffer` (capture side: every pool buffer busy, or the copy failed) or a
    /// `VideoSkipReason` from the encoder.
    public private(set) var counts: [String: Int] = [:]
    private var inBurst = false

    public init() {}

    /// Records one frame's outcome. Returns the reason when it starts a burst of missing images, so the caller can
    /// log one event per burst instead of one per frame.
    public mutating func record(missing reason: String?) -> String? {
        guard let reason else {
            inBurst = false
            return nil
        }
        counts[reason, default: 0] += 1
        defer { inBurst = true }
        return inBurst ? nil : reason
    }

    /// `meta` rows: `image_skip.<reason>` = count, for the reasons that occurred.
    public var metaRows: [(key: String, value: String)] {
        counts.sorted { $0.key < $1.key }.map { ("image_skip.\($0.key)", "\($0.value)") }
    }
}
