import Dispatch
import Foundation
import simd
import Synchronization

/// The averaged cloud while the app runs (`../SPEC.md` L12, T28): a `CloudPipeline` on its own serial queue, fed one
/// frame at a time, publishing a display copy every `publishEvery` frames.
///
/// Callers never wait. `ingest` takes a lock only to count the backlog, then hands the frame's arrays to the queue;
/// past `maxBacklog` waiting frames it drops the frame and counts it. `latest()` reads the last published copy.
/// Thread-safe; the pipeline is only touched on `queue`.
///
/// **Recording** (T29, P22, P23): `startRecording` clears the cloud, then every recorded frame whose `recordIndex + 1`
/// is a multiple of `snapshotEvery` produces a `CloudRecord` for the sink: a full copy for the first row and every
/// `fullEvery` rows, the changes since the previous row otherwise. `stopRecording` adds a row for the last frame.
public final class LiveCloud: @unchecked Sendable {
    /// What the display reads.
    public struct Snapshot: Sendable {
        public var state = CloudState()
        /// Bumped on every publish.
        public var version = 0
        public var trackedIds = 0
        public var storageBytes = 0
        /// Frames dropped because the queue fell behind.
        public var framesDropped = 0
    }

    /// What a recording's cloud rows hold.
    public struct RecordingSummary: Sendable, Equatable {
        public var rows = 0
        /// Averaged points after the last recorded frame.
        public var points = 0
        /// Recorded frames the cloud never saw because its queue fell behind (the Mac's recompute includes them).
        public var framesDropped = 0

        /// `meta` rows written at Stop (SPEC §3.3).
        public var metaRows: [(key: String, value: String)] {
            [("cloud_rows", "\(rows)"), ("cloud_points", "\(points)"), ("cloud_frames_dropped", "\(framesDropped)")]
        }
    }

    public let settings: CloudSettings
    public let publishEvery: Int
    public let maxBacklog: Int

    private let queue = DispatchQueue(label: "br.com.neuralnexgen.sidingsar.live-cloud", qos: .userInitiated)
    private let shared = Mutex(Shared())

    // Queue-confined.
    private let pipeline: CloudPipeline
    private var framesSincePublish = 0
    private var recording: Recording?

    private struct Recording {
        let snapshotEvery: Int
        let fullEvery: Int
        let dropsAtStart: Int
        let sink: @Sendable (CloudRecord) -> Void
        var rows = 0
        var lastRow = -1
    }

    private struct Shared {
        var snapshot = Snapshot()
        var backlog = 0
        var dropped = 0
    }

    public init(settings: CloudSettings, publishEvery: Int = 6, maxBacklog: Int = 120) {
        self.settings = settings
        self.publishEvery = max(publishEvery, 1)
        self.maxBacklog = maxBacklog
        pipeline = CloudPipeline(settings: settings)
    }

    /// Queues one frame. Returns false when it was dropped because `maxBacklog` frames are already waiting.
    /// `recordIndex` is the frame's `idx` in the recording, when one is running and the writer accepted the frame.
    @discardableResult
    public func ingest(
        camera: simd_float4x4, trackingNormal: Bool, points: [SIMD3<Float>], ids: [UInt64], recordIndex: Int? = nil
    ) -> Bool {
        let queued = shared.withLock { shared in
            guard shared.backlog < maxBacklog else {
                shared.dropped += 1
                return false
            }
            shared.backlog += 1
            return true
        }
        guard queued else { return false }
        queue.async {
            self.pipeline.ingest(camera: camera, trackingNormal: trackingNormal, points: points, ids: ids)
            if let recordIndex, let recording = self.recording, (recordIndex + 1) % recording.snapshotEvery == 0 {
                self.emitRow(at: recordIndex)
            }
            self.framesSincePublish += 1
            if self.framesSincePublish >= self.publishEvery {
                self.publish()
            }
            self.shared.withLock { $0.backlog -= 1 }
        }
        return true
    }

    /// Forgets every point (Reset) and publishes the empty cloud.
    public func clear() {
        queue.async {
            self.pipeline.clear()
            self.publish()
        }
    }

    /// Clears the cloud, so the recording's cloud starts empty at its frame 0 (P22), and starts handing rows to `sink`.
    public func startRecording(
        snapshotEvery: Int, fullEvery: Int, sink: @escaping @Sendable (CloudRecord) -> Void
    ) {
        let drops = shared.withLock { $0.dropped }
        queue.async {
            self.pipeline.clear()
            self.recording = Recording(
                snapshotEvery: max(snapshotEvery, 1), fullEvery: max(fullEvery, 1), dropsAtStart: drops, sink: sink
            )
            self.publish()
        }
    }

    /// Writes a row for `lastIndex` unless it already has one, and ends the recording. Blocks until the queue has
    /// caught up (a few milliseconds), so the row reaches the sink before the caller finishes its writer.
    @discardableResult
    public func stopRecording(lastIndex: Int) -> RecordingSummary {
        queue.sync {
            guard let recording = self.recording else { return RecordingSummary() }
            if lastIndex >= 0, lastIndex > recording.lastRow {
                self.emitRow(at: lastIndex)
            }
            let rows = self.recording?.rows ?? 0
            self.recording = nil
            let dropped = self.shared.withLock { $0.dropped } - recording.dropsAtStart
            return RecordingSummary(rows: rows, points: self.pipeline.accumulator.averagedCount, framesDropped: dropped)
        }
    }

    /// On `queue`: one `cloud` row after frame `index`.
    private func emitRow(at index: Int) {
        guard var recording else { return }
        let accumulator = pipeline.accumulator
        let row: CloudRecord
        if recording.rows % recording.fullEvery == 0 {
            _ = accumulator.takeChanges()
            row = CloudRecord(frameIndex: index, full: true, set: accumulator.state())
        } else {
            let changes = accumulator.takeChanges()
            row = CloudRecord(frameIndex: index, full: false, removed: changes.removed, set: changes.set)
        }
        recording.rows += 1
        recording.lastRow = index
        self.recording = recording
        recording.sink(row)
    }

    /// The last published cloud. Never waits for the queue.
    public func latest() -> Snapshot {
        shared.withLock { $0.snapshot }
    }

    /// Blocks until everything queued so far has run, then publishes (tests, and before reading a final state).
    public func drain() {
        queue.sync { self.publish() }
    }

    /// On `queue`.
    private func publish() {
        framesSincePublish = 0
        let accumulator = pipeline.accumulator
        let state = accumulator.state()
        let tracked = accumulator.trackedIds
        let bytes = accumulator.storageBytes
        shared.withLock { shared in
            shared.snapshot = Snapshot(
                state: state, version: shared.snapshot.version + 1, trackedIds: tracked, storageBytes: bytes,
                framesDropped: shared.dropped
            )
        }
    }

    // MARK: Testing

    func suspendForTesting() { queue.suspend() }
    func resumeForTesting() { queue.resume() }
    /// Waits for the queue without publishing.
    func waitForTesting() { queue.sync {} }
}
