import Foundation
import simd
import Testing
@testable import PlaneKit

/// Replays a real recording's averaged cloud through the RANSAC engine on the Mac, round by round as the phone would
/// have run it, and prints what it found (`../../../../EXPERIMENTS.md` *X2*, the bar set by the X1 verdict).
///
///     PLANELAB_REPLAY=~/PlaneLab/sessions/20261001-142809.planelab swift test --filter recordedReplay
///
/// Several bundles can be given, separated by `:`. Skipped without the variable, since recordings never go in git.
@Suite("X2 replay of recordings", .serialized)
struct RecordedReplayTests {
    static let bundles: [String] = (ProcessInfo.processInfo.environment["PLANELAB_REPLAY"] ?? "")
        .split(separator: ":").map { NSString(string: String($0)).expandingTildeInPath }

    /// `PLANELAB_SETTINGS="tauMax=0.5,maxPlaneDistance=0.4"` overrides the defaults, to try dials offline.
    static func settings() -> SurfaceSettings {
        var s = SurfaceSettings.ransac
        let text = ProcessInfo.processInfo.environment["PLANELAB_SETTINGS"] ?? ""
        for pair in text.split(separator: ",") {
            let kv = pair.split(separator: "=")
            guard kv.count == 2, let v = Float(kv[1]) else { continue }
            switch kv[0] {
            case "tauBase": s.tauBase = v
            case "tauPerSquareMetre": s.tauPerSquareMetre = v
            case "tauMax": s.tauMax = v
            case "maxPlaneDistance": s.maxPlaneDistance = v
            case "mergeGap": s.mergeGap = v
            case "keepBand": s.keepBand = v
            case "minInliers": s.minInliers = Int(v)
            case "extentTrim": s.extentTrim = v
            case "pieceCell": s.pieceCell = v
            case "pieceLink": s.pieceLink = Int(v)
            case "maxPlanesPerSearch": s.maxPlanesPerSearch = Int(v)
            case "discoveryEvery": s.discoveryEvery = Int(v)
            case "refitMargin": s.refitMargin = v
            case "minSpread": s.minSpread = v
            case "maxRMSFactor": s.maxRMSFactor = v
            case "confirmHits": s.confirmHits = Int(v)
            case "maxNormalAngleDegrees": s.maxNormalAngleDegrees = v
            case "minSharedRatio": s.minSharedRatio = v
            case "maxVerticalHypotheses": s.maxVerticalHypotheses = Int(v)
            default: print("unknown setting \(kv[0])")
            }
        }
        return s
    }

    @Test(.enabled(if: !bundles.isEmpty), arguments: bundles)
    func recordedReplay(path: String) throws {
        let db = try SessionDatabase.open(at: URL(fileURLWithPath: path).appendingPathComponent("session.sqlite"))
        let frames = try db.frames()
        let rows = try db.clouds()
        try #require(!rows.isEmpty, "no cloud rows: a schema v1 recording")
        let byIndex = Dictionary(frames.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })

        let settings = Self.settings()
        let scanner = RansacScanner(settings: settings)
        var cloud: [UInt64: (point: SIMD3<Float>, samples: UInt16)] = [:]
        var lastRound = -Double.infinity
        var reports: [SurfaceScanner.Report] = []
        var lifetimes: [UUID: (first: Int, last: Int)] = [:]
        for row in rows {
            if row.full { cloud.removeAll(keepingCapacity: true) }
            for id in row.removed { cloud[id] = nil }
            for (i, id) in row.set.ids.enumerated() { cloud[id] = (row.set.points[i], row.set.samples[i]) }
            guard let frame = byIndex[row.frameIndex], frame.timestamp - lastRound >= settings.roundInterval else { continue }
            lastRound = frame.timestamp
            let ids = cloud.keys.sorted()
            let state = CloudState(ids: ids, points: ids.map { cloud[$0]!.point }, samples: ids.map { cloud[$0]!.samples })
            let report = try scanner.round(cloud: state, camera: frame.camera)
            reports.append(report)
            for track in scanner.tracker.ordered {
                lifetimes[track.id, default: (report.round, report.round)].last = report.round
            }
        }

        let times = reports.map(\.milliseconds).sorted()
        func pct(_ q: Double) -> Double { times.isEmpty ? 0 : times[min(Int(Double(times.count - 1) * q + 0.5), times.count - 1)] }
        let searched = reports.filter(\.searched)
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        var out = "REPLAY \(name): \(reports.count) rounds on up to \(reports.map(\.points).max() ?? 0) points; "
        out += String(format: "round median %.1f ms, p95 %.1f ms, max %.1f ms; ", pct(0.5), pct(0.95), times.last ?? 0)
        out += "\(searched.count) searched (median \(String(format: "%.1f", searched.map(\.searchMilliseconds).sorted()[searched.count / 2])) ms)\n"
        let tracks = scanner.tracker.ordered
        let events = reports.flatMap(\.events)
        out += "  tracks at end: \(tracks.count); adds \(events.count { if case .add = $0 { true } else { false } }), "
        out += "merges \(events.count { if case .merge = $0 { true } else { false } }), "
        out += "drops \(events.count { if case .drop = $0 { true } else { false } }), "
        out += "stale \(events.count { if case .stale = $0 { true } else { false } })\n"
        for track in tracks {
            let life = lifetimes[track.id].map { "rounds \($0.first)-\($0.last)" } ?? ""
            let flip: Float = (track.isVertical ? track.normal.z : track.normal.y) < 0 ? -1 : 1
            let offset = simd_dot(flip * track.normal, track.center)
            out += String(
                format: "  #%d %@ %@ normal (%.2f, %.2f, %.2f) offset %.2f m at (%.1f, %.1f, %.1f), %.1f x %.1f m, rms %.1f cm, %d ids, %@\n",
                track.number, track.state.rawValue, track.isVertical ? "vertical" : "horizontal", track.normal.x,
                track.normal.y, track.normal.z, offset, track.center.x, track.center.y, track.center.z, track.width,
                track.height, track.rmsError * 100, track.inlierIDs.count, life
            )
        }
        print(out)
        #expect(tracks.allSatisfy { abs($0.normal.y) < 1e-3 || abs($0.normal.y) > 1 - 1e-3 }, "a slanted plane")
    }
}
