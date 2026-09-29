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

    public let settings: CloudSettings
    public let publishEvery: Int
    public let maxBacklog: Int

    private let queue = DispatchQueue(label: "br.com.neuralnexgen.sidingsar.live-cloud", qos: .userInitiated)
    private let shared = Mutex(Shared())

    // Queue-confined.
    private let pipeline: CloudPipeline
    private var framesSincePublish = 0

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
    @discardableResult
    public func ingest(camera: simd_float4x4, trackingNormal: Bool, points: [SIMD3<Float>], ids: [UInt64]) -> Bool {
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
