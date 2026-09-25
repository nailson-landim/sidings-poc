import Foundation

/// The longest exposure the camera's auto exposure may use (P30). A shorter cap keeps stills and video sharp while
/// the phone moves and turns, and auto exposure raises the ISO to make up for it, so the image gets grainier instead
/// of blurrier. `auto` leaves ARKit's own choice, which reached 9.4 ms in the late afternoon (`20260930-171700`).
public enum ExposureCap: Double, CaseIterable, Sendable, Identifiable {
    case auto = 0
    case ms2 = 0.002
    case ms1 = 0.001
    case ms05 = 0.0005

    public var id: Double { rawValue }

    /// The nearest cap to `seconds` (0 or less is `auto`).
    public init(seconds: Double) {
        guard seconds > 0 else {
            self = .auto
            return
        }
        let caps = Self.allCases.filter { $0 != .auto }
        self = caps.min { abs($0.rawValue - seconds) < abs($1.rawValue - seconds) } ?? .ms1
    }

    public var label: String {
        switch self {
        case .auto: "Auto (ARKit)"
        case .ms2: "1/500 s (2 ms)"
        case .ms1: "1/1000 s (1 ms)"
        case .ms05: "1/2000 s (0.5 ms)"
        }
    }

    /// The cap in seconds, kept inside the camera format's exposure range; nil for `auto`.
    public func seconds(formatMin: Double, formatMax: Double) -> Double? {
        guard self != .auto else { return nil }
        return min(max(rawValue, formatMin), formatMax)
    }

    /// True when the camera's current maximum is more than 10 % away from the target, for example because ARKit
    /// reconfigured the camera and the cap went back to its default.
    public static func needsReapply(current: Double, target: Double) -> Bool {
        guard target > 0 else { return false }
        return !current.isFinite || abs(current - target) > 0.1 * target
    }
}
