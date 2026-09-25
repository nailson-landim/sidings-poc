import Foundation
import simd

/// One plane kept across rounds (Experiment X1).
public struct TrackedSurface: Sendable, Equatable, Identifiable {
    public enum State: String, Sendable {
        case tentative, confirmed, stale
    }

    public let id: UUID
    /// 1, 2, 3… in creation order. When two tracks merge, the older one (smaller number) survives.
    public let number: Int
    public var state: State
    /// Unit normal. The plane is `dot(normal, x) == dot(normal, center)`.
    public var normal: SIMD3<Float>
    /// The inliers' centroid, on the plane.
    public var center: SIMD3<Float>
    /// Convex hull of the inliers on the plane, in world space.
    public var outline: [SIMD3<Float>]
    /// Outline extent along the in-plane horizontal (`PolygonMath.basis` u) and along the other in-plane axis.
    public var width: Float
    public var height: Float
    /// RMS error of the last fit.
    public var rmsError: Float
    /// Feature ids of the inliers.
    public var inlierIDs: Set<UInt64>
    public var hits: Int
    /// In-view refits in a row that found nothing.
    public var misses: Int
    public var lastMatchRound: Int
    /// Bumped whenever something drawn changes.
    public var version: Int

    /// Normal within 20° of horizontal.
    public var isVertical: Bool { abs(normal.y) < 0.342 }
}

public enum SurfaceEvent: Sendable, Equatable {
    case add(UUID)
    case update(UUID)
    case merge(survivor: UUID, absorbed: UUID)
    case stale(UUID)
    /// A tentative track that stopped being found.
    case drop(UUID)
}

/// Keeps planes across rounds (Experiment X1, XD5), like ARKit anchors (`../../SPEC.md` §5.2):
/// - **Match:** a fit joins the track it was seeded from, else the track sharing the most inlier feature ids, when the
///   normal angle and plane distance pass and they share `minSharedRatio` of their ids, overlap by `minOverlapRatio`,
///   or lie within `mergeGap` of each other. Otherwise it starts a tentative track.
/// - **Update:** EMA on the normal and on the plane's position along it; the outline follows the inliers, keeping
///   earlier inliers that stay within `keepBand` of the plane.
/// - **Lifecycle:** tentative → confirmed after `confirmHits` matches; confirmed → stale after `staleMisses` in-view
///   refits that find nothing, and back when found again; tentative tracks are dropped after `dropTentativeMisses`.
/// - **Merge:** two tracks on one surface merge at the end of a round, and the older one survives.
public final class SurfaceTracker {
    public var settings: SurfaceSettings
    public private(set) var surfaces: [UUID: TrackedSurface] = [:]
    public private(set) var round = 0
    private var nextNumber = 1
    private var events: [SurfaceEvent] = []
    /// The round's cloud.
    private var points: [SIMD3<Float>] = []
    private var ids: [UInt64] = []
    private var index: [UInt64: Int] = [:]

    public init(settings: SurfaceSettings = SurfaceSettings()) {
        self.settings = settings
    }

    /// Tracks by creation order.
    public var ordered: [TrackedSurface] { surfaces.values.sorted { $0.number < $1.number } }

    public func reset() {
        surfaces.removeAll()
        round = 0
        nextNumber = 1
        events.removeAll()
        points.removeAll()
        ids.removeAll()
        index.removeAll()
    }

    /// Starts a round on the current cloud: fits refer to these points by index.
    public func beginRound(points: [SIMD3<Float>], ids: [UInt64]) {
        round += 1
        events.removeAll()
        self.points = points
        self.ids = ids
        index = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Indices of a track's inliers that are still in the round's cloud.
    public func presentIndices(of track: TrackedSurface) -> [Int] {
        track.inlierIDs.compactMap { index[$0] }
    }

    /// Feeds one accepted fit on the round's cloud. `hint` is the track the fit was seeded from. A fit that matches no
    /// track starts a tentative one only when `create` is true: refits don't, so a refit that wandered off its surface
    /// can't spawn planes.
    /// - Returns: the id of the track it matched or started, nil when it matched none and `create` is false.
    @discardableResult
    public func ingest(_ fit: SurfaceFit, hint: UUID? = nil, create: Bool = true) -> UUID? {
        let inlierIDs = Set(fit.inliers.map { ids[$0] })
        let fitPoints = fit.inliers.map { points[$0] }
        let fitCenter = fitPoints.reduce(SIMD3<Float>.zero, +) / Float(max(fitPoints.count, 1))
        let fitOutline = Self.hull(fitPoints, normal: fit.normal, center: fitCenter)

        var candidates: [TrackedSurface] = []
        if let hint, let track = surfaces[hint] { candidates.append(track) }
        let others = surfaces.values.filter { $0.id != hint }
            .map { ($0, $0.inlierIDs.intersection(inlierIDs).count) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.number < $1.0.number }
        candidates += others.map(\.0)

        for track in candidates where matches(
            track, normal: fit.normal, center: fitCenter, outline: fitOutline, ids: inlierIDs
        ) {
            update(track.id, normal: fit.normal, center: fitCenter, ids: inlierIDs, rms: fit.rmsError)
            return track.id
        }
        guard create else { return nil }
        let id = UUID()
        var normal = fit.normal
        if simd_length_squared(normal) > 0 { normal = simd_normalize(normal) }
        var track = TrackedSurface(
            id: id, number: nextNumber, state: .tentative, normal: normal, center: fitCenter, outline: [],
            width: 0, height: 0, rmsError: fit.rmsError, inlierIDs: inlierIDs, hits: 1, misses: 0,
            lastMatchRound: round, version: 1
        )
        nextNumber += 1
        Self.reshape(&track, points: fitPoints, trim: settings.extentTrim)
        if settings.confirmHits <= 1 { track.state = .confirmed }
        surfaces[id] = track
        events.append(.add(id))
        return id
    }

    /// An in-view refit of `id` found nothing usable.
    public func missed(_ id: UUID) {
        guard var track = surfaces[id], track.lastMatchRound != round else { return }
        track.misses += 1
        if track.state == .confirmed && track.misses >= settings.staleMisses {
            track.state = .stale
            track.version += 1
            events.append(.stale(id))
        }
        surfaces[id] = track
    }

    /// Drops tentative tracks that keep missing, merges tracks on one surface, and returns the round's events.
    public func endRound() -> [SurfaceEvent] {
        for track in surfaces.values where track.state == .tentative && track.misses >= settings.dropTentativeMisses {
            surfaces[track.id] = nil
            events.append(.drop(track.id))
        }
        mergeAll()
        return events
    }

    // MARK: Matching

    private func matches(
        _ track: TrackedSurface, normal: SIMD3<Float>, center: SIMD3<Float>, outline: [SIMD3<Float>], ids: Set<UInt64>
    ) -> Bool {
        guard PolygonMath.normalAngleDegrees(track.normal, normal) <= settings.maxNormalAngleDegrees,
              Self.planeDistance(track.normal, track.center, normal, center) <= settings.maxPlaneDistance
        else { return false }
        let smaller = min(track.inlierIDs.count, ids.count)
        if smaller > 0, Float(track.inlierIDs.intersection(ids).count) / Float(smaller) >= settings.minSharedRatio {
            return true
        }
        if Self.overlap(track.outline, outline, normal: track.normal, origin: track.center) >= settings.minOverlapRatio {
            return true
        }
        return settings.mergeGap > 0
            && Self.gap(track.outline, outline, normal: track.normal, origin: track.center) <= settings.mergeGap
    }

    private func mergeable(_ a: TrackedSurface, _ b: TrackedSurface) -> Bool {
        matches(a, normal: b.normal, center: b.center, outline: b.outline, ids: b.inlierIDs)
    }

    private func mergeAll() {
        var merged = true
        while merged {
            merged = false
            let tracks = ordered
            search: for i in tracks.indices {
                for j in tracks.index(after: i)..<tracks.endIndex where mergeable(tracks[i], tracks[j]) {
                    merge(survivor: tracks[i].id, absorbed: tracks[j].id)
                    merged = true
                    break search
                }
            }
        }
    }

    private func merge(survivor: UUID, absorbed: UUID) {
        guard var keep = surfaces[survivor], let gone = surfaces.removeValue(forKey: absorbed) else { return }
        keep.inlierIDs.formUnion(gone.inlierIDs)
        keep.hits += gone.hits
        keep.misses = min(keep.misses, gone.misses)
        keep.lastMatchRound = max(keep.lastMatchRound, gone.lastMatchRound)
        if keep.state != .confirmed && (gone.state == .confirmed || keep.hits >= settings.confirmHits) {
            keep.state = .confirmed
        }
        let present = presentIndices(of: keep).map { points[$0] }
        if !present.isEmpty {
            keep.center = Self.onPlane(present.reduce(.zero, +) / Float(present.count), normal: keep.normal, through: keep.center)
            Self.reshape(&keep, points: present, trim: settings.extentTrim)
        }
        keep.version += 1
        surfaces[survivor] = keep
        events.append(.merge(survivor: survivor, absorbed: absorbed))
    }

    // MARK: Updating

    private func update(
        _ id: UUID, normal fitNormal: SIMD3<Float>, center fitCenter: SIMD3<Float>, ids fitIDs: Set<UInt64>, rms: Float
    ) {
        guard var track = surfaces[id] else { return }
        let alpha = settings.emaAlpha
        var n = simd_normalize(fitNormal)
        if simd_dot(n, track.normal) < 0 { n = -n }
        let normal = simd_normalize(track.normal + alpha * (n - track.normal))
        // The plane's position along the normal is smoothed too; the in-plane centroid follows the data.
        let before = simd_dot(normal, track.center)
        let along = before + alpha * (simd_dot(normal, fitCenter) - before)
        let anchor = fitCenter + (along - simd_dot(normal, fitCenter)) * normal

        // Earlier inliers stay while they're still in the cloud and near the smoothed plane.
        var kept = fitIDs
        for old in track.inlierIDs where !kept.contains(old) {
            guard let i = index[old], abs(simd_dot(normal, points[i] - anchor)) <= settings.keepBand else { continue }
            kept.insert(old)
        }
        let present = kept.compactMap { index[$0] }.map { points[$0] }
        let centroid = present.reduce(SIMD3<Float>.zero, +) / Float(max(present.count, 1))
        track.normal = normal
        track.center = Self.onPlane(centroid, normal: normal, through: anchor)
        track.inlierIDs = kept
        track.rmsError = rms
        track.hits += 1
        track.misses = 0
        track.lastMatchRound = round
        if track.state == .stale || (track.state == .tentative && track.hits >= settings.confirmHits) {
            track.state = .confirmed
        }
        Self.reshape(&track, points: present, trim: settings.extentTrim)
        track.version += 1
        surfaces[id] = track
        events.append(.update(id))
    }

    // MARK: Geometry

    /// Sets `outline`, `width` and `height` from `points` projected onto the track's plane.
    /// With `trim` above 0, that fraction of the points is cut from each end of both in-plane axes first (X2), so strays
    /// don't stretch the outline.
    static func reshape(_ track: inout TrackedSurface, points: [SIMD3<Float>], trim: Float = 0) {
        let (u, v) = PolygonMath.basis(for: track.normal)
        var projected = PolygonMath.project(points, origin: track.center, u: u, v: v)
        if trim > 0, projected.count >= 20 {
            let cut = min(Int(trim * Float(projected.count)), projected.count / 4)
            let us = projected.map(\.x).sorted()
            let vs = projected.map(\.y).sorted()
            let (uLo, uHi) = (us[cut], us[us.count - 1 - cut])
            let (vLo, vHi) = (vs[cut], vs[vs.count - 1 - cut])
            projected = projected.filter { $0.x >= uLo && $0.x <= uHi && $0.y >= vLo && $0.y <= vHi }
        }
        let flat = PolygonMath.convexHull(projected)
        track.outline = flat.map { track.center + $0.x * u + $0.y * v }
        let us = flat.map(\.x)
        let vs = flat.map(\.y)
        track.width = (us.max() ?? 0) - (us.min() ?? 0)
        track.height = (vs.max() ?? 0) - (vs.min() ?? 0)
    }

    static func hull(_ points: [SIMD3<Float>], normal: SIMD3<Float>, center: SIMD3<Float>) -> [SIMD3<Float>] {
        let (u, v) = PolygonMath.basis(for: simd_normalize(normal))
        return PolygonMath.convexHull(PolygonMath.project(points, origin: center, u: u, v: v))
            .map { center + $0.x * u + $0.y * v }
    }

    static func onPlane(_ p: SIMD3<Float>, normal: SIMD3<Float>, through q: SIMD3<Float>) -> SIMD3<Float> {
        p - simd_dot(normal, p - q) * normal
    }

    /// Offset between two nearly parallel planes along their mean normal. The mean, not each plane's own normal: two
    /// patches of one big wall several metres apart would otherwise read as offset by their small tilt difference
    /// times that distance.
    static func planeDistance(
        _ na: SIMD3<Float>, _ ca: SIMD3<Float>, _ nb: SIMD3<Float>, _ cb: SIMD3<Float>
    ) -> Float {
        let a = simd_normalize(na)
        var b = simd_normalize(nb)
        if simd_dot(a, b) < 0 { b = -b }
        return abs(simd_dot(simd_normalize(a + b), cb - ca))
    }

    /// Shortest distance between two outlines projected onto the plane through `origin`; 0 when they touch or overlap.
    static func gap(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>], normal: SIMD3<Float>, origin: SIMD3<Float>) -> Float {
        let (u, v) = PolygonMath.basis(for: simd_normalize(normal))
        let ha = PolygonMath.convexHull(PolygonMath.project(a, origin: origin, u: u, v: v))
        let hb = PolygonMath.convexHull(PolygonMath.project(b, origin: origin, u: u, v: v))
        guard ha.count >= 3, hb.count >= 3 else { return .infinity }
        if PolygonMath.area(PolygonMath.intersectConvex(ha, hb)) > 1e-6 { return 0 }
        func pointToSegment(_ p: SIMD2<Float>, _ s: SIMD2<Float>, _ e: SIMD2<Float>) -> Float {
            let d = e - s
            let t = simd_dot(d, d) > 0 ? min(max(simd_dot(p - s, d) / simd_dot(d, d), 0), 1) : 0
            return simd_distance(p, s + t * d)
        }
        func oneWay(_ points: [SIMD2<Float>], _ polygon: [SIMD2<Float>]) -> Float {
            var best = Float.infinity
            for p in points {
                for i in polygon.indices {
                    best = min(best, pointToSegment(p, polygon[i], polygon[(i + 1) % polygon.count]))
                }
            }
            return best
        }
        return min(oneWay(ha, hb), oneWay(hb, ha))
    }

    /// Overlap area over the smaller area, both outlines projected onto the plane through `origin`.
    static func overlap(
        _ a: [SIMD3<Float>], _ b: [SIMD3<Float>], normal: SIMD3<Float>, origin: SIMD3<Float>
    ) -> Float {
        let (u, v) = PolygonMath.basis(for: simd_normalize(normal))
        let ha = PolygonMath.convexHull(PolygonMath.project(a, origin: origin, u: u, v: v))
        let hb = PolygonMath.convexHull(PolygonMath.project(b, origin: origin, u: u, v: v))
        let smaller = min(PolygonMath.area(ha), PolygonMath.area(hb))
        guard smaller > 1e-6 else { return 0 }
        return PolygonMath.area(PolygonMath.intersectConvex(ha, hb)) / smaller
    }
}
