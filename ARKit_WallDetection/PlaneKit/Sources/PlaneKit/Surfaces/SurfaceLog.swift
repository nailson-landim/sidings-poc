import Foundation

/// Experiment X1 while recording (`../../EXPERIMENTS.md` XD6): turns each round's tracks into `surface` rows, one per
/// track that changed. A track is added the first time it's written, updated when its `version` moved, and removed
/// once it's gone: merged into an older track (that round's `merge` event names it) or dropped.
public struct SurfaceLog: Sendable {
    private var written: [UUID: (number: Int, version: Int)] = [:]
    /// Rows produced so far.
    public private(set) var rowCount = 0

    public init() {}

    public mutating func rows(frameIndex: Int, surfaces: [TrackedSurface], events: [SurfaceEvent]) -> [SurfaceRecord] {
        var rows: [SurfaceRecord] = []
        for surface in surfaces {
            let event: AnchorEvent
            if let previous = written[surface.id] {
                guard previous.version != surface.version else { continue }
                event = .update
            } else {
                event = .add
            }
            rows.append(SurfaceRecord(
                frameIndex: frameIndex, surfaceID: surface.id, number: surface.number, event: event,
                geometry: SurfaceGeometry(surface)
            ))
            written[surface.id] = (surface.number, surface.version)
        }
        let live = Set(surfaces.map(\.id))
        var mergedInto: [UUID: UUID] = [:]
        for case let .merge(survivor, absorbed) in events {
            mergedInto[absorbed] = survivor
        }
        for (id, entry) in written.sorted(by: { $0.value.number < $1.value.number }) where !live.contains(id) {
            rows.append(SurfaceRecord(
                frameIndex: frameIndex, surfaceID: id, number: entry.number, event: .remove, geometry: nil,
                mergedInto: mergedInto[id]
            ))
            written[id] = nil
        }
        rowCount += rows.count
        return rows
    }
}

extension TrackedSurface.State {
    /// `surface.state`.
    public var code: Int {
        switch self {
        case .tentative: 0
        case .confirmed: 1
        case .stale: 2
        }
    }
}

extension SurfaceGeometry {
    public init(_ s: TrackedSurface) {
        self.init(
            state: s.state.code, normal: s.normal, center: s.center, outline: s.outline, width: s.width,
            height: s.height, rmsError: s.rmsError, inliers: s.inlierIDs.count
        )
    }
}

extension SurfaceSettings {
    /// One `meta` row per setting, `x1.<name>`, read by reflection so a new setting can't be left out.
    public var metaRows: [(key: String, value: String)] {
        Mirror(reflecting: self).children.compactMap { child in
            child.label.map { ("x1.\($0)", "\(child.value)") }
        }
    }
}
