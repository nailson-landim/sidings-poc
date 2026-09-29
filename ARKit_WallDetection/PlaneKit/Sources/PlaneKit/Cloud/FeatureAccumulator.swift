import Foundation
import simd

/// The averaged cloud at one moment: every feature id with an averaged point.
public struct CloudState: Sendable, Equatable {
    public var ids: [UInt64] = []
    public var points: [SIMD3<Float>] = []
    /// Samples in each id's FIFO (at most `maxSamples`).
    public var samples: [UInt16] = []

    public init(ids: [UInt64] = [], points: [SIMD3<Float>] = [], samples: [UInt16] = []) {
        self.ids = ids
        self.points = points
        self.samples = samples
    }

    public var count: Int { ids.count }
}

/// What changed since the last `takeChanges()`: apply `removed` first, then set every id in `set`.
public struct CloudChanges: Sendable, Equatable {
    public var removed: [UInt64] = []
    public var set = CloudState()

    public var isEmpty: Bool { removed.isEmpty && set.ids.isEmpty }
}

/// Stage 4 (`../SPEC.md` §5.1, T27): CurvSurf's `FeatureCompressor`
/// (`ARFeaturePointFindSurface/Utilities/FeatureCompressor.swift`), with Plane Lab's accumulator (T16) as the
/// reference; `session-format/fixtures/cloud/golden.json` checks the two agree.
///
/// - Each feature id keeps a FIFO of its last `maxSamples` sightings.
/// - Once it holds `minSamples`, its averaged point is the mean of the samples within `zScore · sigma` of their mean,
///   where `sigma² = mean squared distance to the mean`, recomputed on every new sighting, in Double.
/// - Beyond `maxIds` ids, the oldest by *first* sighting is evicted with its samples and averaged point, even if it was
///   seen a moment ago, and even later in the same frame. Points are taken one at a time, as CurvSurf does.
///
/// Samples live in flat Float storage, 12 bytes each, grown `chunkIds` ids at a time (P25). Not thread-safe: keep it
/// on one queue (`LiveCloud` does).
public final class FeatureAccumulator {
    public static let chunkIds = 4096

    public let settings: CloudSettings
    private var slotOf: [UInt64: Int] = [:]
    /// Ids by first sighting; `orderHead` is the oldest.
    private var order: [UInt64] = []
    private var orderHead = 0
    private var freeSlots: [Int] = []
    private var nextSlot = 0

    private var chunks: [[Float]] = []
    private var slotIds: [UInt64] = []
    private var counts: [Int] = []
    private var heads: [Int] = []
    private var means: [SIMD3<Float>] = []
    private var hasMean: [Bool] = []
    private var scratch: [Double]

    private var changed: Set<UInt64> = []
    private var removed: Set<UInt64> = []

    public init(settings: CloudSettings) {
        precondition(settings.maxSamples > 0 && settings.minSamples > 0 && settings.maxIds > 0)
        self.settings = settings
        scratch = [Double](repeating: 0, count: settings.maxSamples)
    }

    /// Ids tracked, averaged or not.
    public var trackedIds: Int { slotOf.count }

    /// Ids with an averaged point.
    public private(set) var averagedCount = 0

    /// Bytes held by sample storage and per-slot state (for the HUD and P25).
    public var storageBytes: Int {
        // Samples (3 × Float each), then id, count, head (8 bytes each), mean (SIMD3<Float>, 16) and hasMean (1).
        let perSlot: Int = settings.maxSamples * 12 + 41
        return chunks.count * Self.chunkIds * perSlot
    }

    public func clear() {
        slotOf.removeAll()
        order.removeAll()
        orderHead = 0
        freeSlots.removeAll()
        nextSlot = 0
        chunks.removeAll()
        slotIds.removeAll()
        counts.removeAll()
        heads.removeAll()
        means.removeAll()
        hasMean.removeAll()
        changed.removeAll()
        removed.removeAll()
        averagedCount = 0
    }

    /// Adds one frame's sightings, one point at a time. Each id should appear once, as in `rawFeaturePoints`.
    public func add(ids: [UInt64], points: [SIMD3<Float>]) {
        for (id, point) in zip(ids, points) {
            let slot = slotOf[id] ?? insert(id)
            let offset = (slot % Self.chunkIds) * settings.maxSamples * 3 + heads[slot] * 3
            let chunk = slot / Self.chunkIds
            chunks[chunk][offset] = point.x
            chunks[chunk][offset + 1] = point.y
            chunks[chunk][offset + 2] = point.z
            heads[slot] = (heads[slot] + 1) % settings.maxSamples
            counts[slot] = min(counts[slot] + 1, settings.maxSamples)
            if counts[slot] >= settings.minSamples {
                refresh(slot)
                changed.insert(id)
            }
        }
    }

    /// The whole cloud now.
    public func state() -> CloudState {
        var state = CloudState()
        state.ids.reserveCapacity(averagedCount)
        state.points.reserveCapacity(averagedCount)
        state.samples.reserveCapacity(averagedCount)
        for (id, slot) in slotOf where hasMean[slot] {
            state.ids.append(id)
            state.points.append(means[slot])
            state.samples.append(UInt16(counts[slot]))
        }
        return state
    }

    /// Everything that changed since the last call, then forgets it.
    public func takeChanges() -> CloudChanges {
        var changes = CloudChanges(removed: removed.sorted())
        for id in changed.sorted() {
            guard let slot = slotOf[id], hasMean[slot] else { continue }
            changes.set.ids.append(id)
            changes.set.points.append(means[slot])
            changes.set.samples.append(UInt16(counts[slot]))
        }
        changed.removeAll(keepingCapacity: true)
        removed.removeAll(keepingCapacity: true)
        return changes
    }

    // MARK: Storage

    private func insert(_ id: UInt64) -> Int {
        if slotOf.count >= settings.maxIds {
            evictOldest()
        }
        let slot: Int
        if let reused = freeSlots.popLast() {
            slot = reused
        } else {
            slot = nextSlot
            nextSlot += 1
            if slot == slotIds.count { grow() }
        }
        slotIds[slot] = id
        counts[slot] = 0
        heads[slot] = 0
        hasMean[slot] = false
        slotOf[id] = slot
        order.append(id)
        return slot
    }

    private func evictOldest() {
        let oldest = order[orderHead]
        orderHead += 1
        if orderHead > 1024, orderHead * 2 > order.count {
            order.removeFirst(orderHead)
            orderHead = 0
        }
        guard let slot = slotOf.removeValue(forKey: oldest) else { return }
        if hasMean[slot] { averagedCount -= 1 }
        hasMean[slot] = false
        counts[slot] = 0
        freeSlots.append(slot)
        changed.remove(oldest)
        removed.insert(oldest)
    }

    private func grow() {
        chunks.append([Float](repeating: 0, count: Self.chunkIds * settings.maxSamples * 3))
        slotIds += [UInt64](repeating: 0, count: Self.chunkIds)
        counts += [Int](repeating: 0, count: Self.chunkIds)
        heads += [Int](repeating: 0, count: Self.chunkIds)
        means += [SIMD3<Float>](repeating: .zero, count: Self.chunkIds)
        hasMean += [Bool](repeating: false, count: Self.chunkIds)
    }

    /// CurvSurf's `removeOutliersInGaussianDistribution` and mean, over ring positions `0..<count`, in Double.
    /// Scalar loops over raw buffers: generic SIMD code is slow in unoptimized (Debug) builds, which Xcode installs.
    private func refresh(_ slot: Int) {
        let count = counts[slot]
        let base = (slot % Self.chunkIds) * settings.maxSamples * 3
        let zSquared = settings.zScore * settings.zScore
        let mean: (Double, Double, Double) = chunks[slot / Self.chunkIds].withUnsafeBufferPointer { chunk in
            scratch.withUnsafeMutableBufferPointer { distances in
                let samples = chunk.baseAddress! + base
                var sx = 0.0, sy = 0.0, sz = 0.0
                for k in 0..<count {
                    sx += Double(samples[3 * k])
                    sy += Double(samples[3 * k + 1])
                    sz += Double(samples[3 * k + 2])
                }
                let n = Double(count)
                let mx = sx / n, my = sy / n, mz = sz / n
                var total = 0.0
                for k in 0..<count {
                    let dx = Double(samples[3 * k]) - mx
                    let dy = Double(samples[3 * k + 1]) - my
                    let dz = Double(samples[3 * k + 2]) - mz
                    let d = dx * dx + dy * dy + dz * dz
                    distances[k] = d
                    total += d
                }
                let threshold = zSquared * (total / n)
                var kx = 0.0, ky = 0.0, kz = 0.0
                var kept = 0
                for k in 0..<count where distances[k] <= threshold {
                    kx += Double(samples[3 * k])
                    ky += Double(samples[3 * k + 1])
                    kz += Double(samples[3 * k + 2])
                    kept += 1
                }
                // A z-score below 1 can reject every sample; keep them all then, as Plane Lab does.
                guard kept > 0 else { return (mx, my, mz) }
                let m = Double(kept)
                return (kx / m, ky / m, kz / m)
            }
        }
        if !hasMean[slot] { averagedCount += 1 }
        means[slot] = SIMD3<Float>(Float(mean.0), Float(mean.1), Float(mean.2))
        hasMean[slot] = true
    }
}

/// Stages 2–4 for one frame at a time: filter, gate, accumulate (Plane Lab's `run_frames`).
public final class CloudPipeline {
    public let settings: CloudSettings
    public let accumulator: FeatureAccumulator
    private let filter: CloudPointFilter
    private var gate: CloudFrameGate

    public init(settings: CloudSettings) {
        self.settings = settings
        accumulator = FeatureAccumulator(settings: settings)
        filter = CloudPointFilter(settings)
        gate = CloudFrameGate(settings)
    }

    /// Feeds one frame. Returns whether its points reached the accumulator.
    @discardableResult
    public func ingest(camera: simd_float4x4, trackingNormal: Bool, points: [SIMD3<Float>], ids: [UInt64]) -> Bool {
        if settings.normalTrackingOnly && !trackingNormal { return false }
        guard gate.accept(camera: camera) else { return false }
        let eye = SIMD3<Double>(Double(camera.columns.3.x), Double(camera.columns.3.y), Double(camera.columns.3.z))
        var keptPoints: [SIMD3<Float>] = []
        var keptIds: [UInt64] = []
        keptPoints.reserveCapacity(points.count)
        keptIds.reserveCapacity(points.count)
        for (point, id) in zip(points, ids) where filter.keeps(point, eye: eye) {
            keptPoints.append(point)
            keptIds.append(id)
        }
        accumulator.add(ids: keptIds, points: keptPoints)
        return true
    }

    /// Forgets every point and restarts the gate.
    public func clear() {
        accumulator.clear()
        gate = CloudFrameGate(settings)
    }
}
