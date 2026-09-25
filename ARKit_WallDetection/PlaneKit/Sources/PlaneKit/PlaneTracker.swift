import Foundation
import simd

public struct PlaneTrackerConfig: Sendable, Equatable {
    /// Max angle between normals for two planes to be considered duplicates.
    public var maxNormalAngleDegrees: Float = 10
    /// Max plane-to-plane separation (m) for duplicates.
    public var maxPlaneDistance: Float = 0.08
    /// Min intersection / smaller-area ratio for duplicates.
    public var minOverlapRatio: Float = 0.3
    /// Score multiplier an incumbent winner enjoys over challengers.
    public var incumbentMargin: Float = 1.2
    /// Consecutive resolves a challenger must win before it replaces an incumbent.
    public var challengerFrames: Int = 5
    /// Updates after which a plane counts as fully stable in scoring.
    public var stableUpdateCount: Int = 30
    /// EMA blend factor for rendered center/extent.
    public var emaAlpha: Float = 0.3
    /// Center jump (m) that resets the EMA instead of blending.
    public var emaResetDistance: Float = 0.2

    public init() {}
}

public struct PlaneState: Sendable, Equatable {
    public let id: UUID
    public var isSuppressed: Bool
    /// The winner that suppressed this plane, if any.
    public var suppressedBy: UUID?
    public var score: Float
    public var smoothed: PlaneSmoother
}

/// Arbitrates ARKit plane anchors: Non-Maximum Suppression over duplicate planes, with
/// incumbent hysteresis and EMA smoothing so the result is stable frame to frame.
public final class PlaneTracker {
    public var config: PlaneTrackerConfig
    public private(set) var observations: [UUID: PlaneObservation] = [:]
    public private(set) var states: [UUID: PlaneState] = [:]
    private var smoothers: [UUID: PlaneSmoother] = [:]
    private var challengerStreak: [UUID: Int] = [:]

    public init(config: PlaneTrackerConfig = PlaneTrackerConfig()) {
        self.config = config
    }

    public var keptCount: Int { states.values.count { !$0.isSuppressed } }

    public func upsert(_ observation: PlaneObservation) {
        observations[observation.id] = observation
        let c = observation.worldCenter
        if var s = smoothers[observation.id] {
            s.update(
                center: c, width: observation.width, height: observation.height,
                alpha: config.emaAlpha, resetDistance: config.emaResetDistance
            )
            smoothers[observation.id] = s
        } else {
            smoothers[observation.id] = PlaneSmoother(center: c, width: observation.width, height: observation.height)
        }
    }

    public func remove(id: UUID) {
        observations[id] = nil
        states[id] = nil
        smoothers[id] = nil
        challengerStreak[id] = nil
    }

    public func reset() {
        observations.removeAll()
        states.removeAll()
        smoothers.removeAll()
        challengerStreak.removeAll()
    }

    /// Score = area weighted by stability (half weight for brand-new planes).
    public func score(_ o: PlaneObservation) -> Float {
        let stability = min(1, Float(o.updateCount) / Float(max(1, config.stableUpdateCount)))
        return o.area * (0.5 + 0.5 * stability)
    }

    /// True when `a` and `b` describe the same physical surface.
    public func conflicts(_ a: PlaneObservation, _ b: PlaneObservation) -> Bool {
        conflicts(PlaneGeometry(a), PlaneGeometry(b))
    }

    private func conflicts(_ a: PlaneGeometry, _ b: PlaneGeometry) -> Bool {
        guard a.alignment == b.alignment else { return false }
        // Bounding-sphere reject before any polygon work.
        guard simd_distance(a.center, b.center) <= a.radius + b.radius else { return false }
        guard PolygonMath.normalAngleDegrees(a.normal, b.normal) <= config.maxNormalAngleDegrees else { return false }
        let distance = max(abs(simd_dot(a.normal, b.center - a.center)), abs(simd_dot(b.normal, a.center - b.center)))
        guard distance <= config.maxPlaneDistance else { return false }
        let (u, v) = PolygonMath.basis(for: a.normal)
        let ha = PolygonMath.convexHull(PolygonMath.project(a.boundary, origin: a.center, u: u, v: v))
        let hb = PolygonMath.convexHull(PolygonMath.project(b.boundary, origin: a.center, u: u, v: v))
        let smaller = min(PolygonMath.area(ha), PolygonMath.area(hb))
        guard smaller > 1e-6 else { return false }
        return PolygonMath.area(PolygonMath.intersectConvex(ha, hb)) / smaller >= config.minOverlapRatio
    }

    @discardableResult
    public func resolve() -> [UUID: PlaneState] {
        let ids = Array(observations.keys)
        let wasKept = Set(states.values.filter { !$0.isSuppressed }.map(\.id))

        // Conflict graph over cached world geometry (cheap gates first inside `conflicts`).
        let geometry = ids.map { PlaneGeometry(observations[$0]!) }
        var neighbors: [UUID: [UUID]] = [:]
        for i in geometry.indices {
            for j in geometry.index(after: i)..<geometry.endIndex {
                let a = geometry[i]
                let b = geometry[j]
                if conflicts(a, b) {
                    neighbors[a.id, default: []].append(b.id)
                    neighbors[b.id, default: []].append(a.id)
                }
            }
        }

        var raw: [UUID: Float] = [:]
        var effective: [UUID: Float] = [:]
        for id in ids {
            let s = score(observations[id]!)
            raw[id] = s
            effective[id] = wasKept.contains(id) ? s * config.incumbentMargin : s
        }

        // Hysteresis: a challenger outranking a conflicting incumbent must do so for N resolves.
        for id in ids where !wasKept.contains(id) {
            let incumbents = (neighbors[id] ?? []).filter(wasKept.contains)
            guard let weakest = incumbents.compactMap({ effective[$0] }).min() else {
                challengerStreak[id] = 0
                continue
            }
            let strongest = incumbents.compactMap { effective[$0] }.max() ?? weakest
            if effective[id]! > strongest {
                let streak = (challengerStreak[id] ?? 0) + 1
                challengerStreak[id] = streak
                if streak < config.challengerFrames {
                    effective[id] = weakest * 0.999
                }
            } else {
                challengerStreak[id] = 0
            }
        }

        // Greedy NMS, ties broken by id for determinism.
        let order = ids.sorted { effective[$0]! == effective[$1]! ? $0.uuidString < $1.uuidString : effective[$0]! > effective[$1]! }
        var kept: Set<UUID> = []
        var next: [UUID: PlaneState] = [:]
        for id in order {
            let winner = (neighbors[id] ?? []).first(where: kept.contains)
            if winner == nil {
                kept.insert(id)
                challengerStreak[id] = 0
            }
            next[id] = PlaneState(
                id: id,
                isSuppressed: winner != nil,
                suppressedBy: winner,
                score: raw[id]!,
                smoothed: smoothers[id]!
            )
        }
        states = next
        return next
    }
}

/// World-space geometry of one observation, computed once per resolve.
private struct PlaneGeometry {
    let id: UUID
    let alignment: PlaneAlignment
    let normal: SIMD3<Float>
    let center: SIMD3<Float>
    let boundary: [SIMD3<Float>]
    let radius: Float

    init(_ o: PlaneObservation) {
        id = o.id
        alignment = o.alignment
        normal = o.worldNormal
        center = o.worldCenter
        boundary = o.worldBoundary
        let c = center
        radius = boundary.map { simd_distance($0, c) }.max() ?? 0
    }
}
