import CoreVideo
import Dispatch
import Foundation
import Synchronization

/// What a finished recording holds.
public struct SessionSummary: Sendable, Equatable {
    public var framesLogged: Int
    public var framesWithImage: Int
    public var framesDropped: Int
    /// Frames without an image, by reason: `no_buffer` (the capture side had no free pool buffer, or the copy failed)
    /// or the encoder's `VideoSkipReason`. Also written to `meta` as `image_skip.<reason>`.
    public var imageSkips: [String: Int]
}

/// Writes one recording bundle (`session.sqlite` + `video.mov`) off the capture thread (SPEC §4 R4–R6).
///
/// The capture thread calls `enqueue`, which never blocks: it takes a lock, bumps counters and hands the record to a
/// serial queue. On that queue, each image goes to the video writer and each record into a batch. The batch is
/// committed as one SQLite transaction every `commitIntervalS`. If `writeQueueFrames` frames are waiting, new
/// frames are dropped whole and counted. Frame numbers are given only to accepted frames, so `idx` has no holes.
///
/// Thread-safe. The database and the video writer are only touched on `queue`.
public final class SessionWriter: @unchecked Sendable {
    public let bundle: URL
    public let constants: RecorderConstants

    private let queue = DispatchQueue(label: "br.com.neuralnexgen.sidingsar.session-writer", qos: .userInitiated)
    private let state = Mutex(Counters())
    private let database: SessionDatabase
    private let video: VideoWriter?
    private var timer: DispatchSourceTimer?

    // Queue-confined.
    private var batch = Batch()
    private var framesWithImage = 0
    private var imageSkips = ImageSkipLog()

    private struct Counters {
        var nextIndex = 0
        var pending = 0
        var dropped = 0
        var accepting = true
        var failed = false
    }

    private struct Batch {
        var frames: [FrameRecord] = []
        var anchors: [AnchorRecord] = []
        var locations: [LocationRecord] = []
        var headings: [HeadingRecord] = []
        var events: [EventRecord] = []
        var clouds: [CloudRecord] = []

        var isEmpty: Bool {
            frames.isEmpty && anchors.isEmpty && locations.isEmpty && headings.isEmpty && events.isEmpty
                && clouds.isEmpty
        }
    }

    /// Creates the bundle folder, `session.sqlite` with `meta` (plus every `const.*` row and `started_at`), and, when
    /// `videoSize` is given, `video.mov`. With `autoCommit` off, nothing commits until `flush()` (tests).
    public init(
        bundle: URL,
        meta: [(key: String, value: String)],
        videoSize: (width: Int, height: Int)?,
        constants: RecorderConstants = .current,
        autoCommit: Bool = true,
        realTimeVideo: Bool = true
    ) throws {
        self.bundle = bundle
        self.constants = constants
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let startedAt = ISO8601DateFormatter().string(from: .now)
        database = try SessionDatabase.create(
            at: bundle.appendingPathComponent("session.sqlite"),
            meta: meta + constants.metaRows + [("started_at", startedAt)]
        )
        video = try videoSize.map {
            try VideoWriter(
                url: bundle.appendingPathComponent("video.mov"), width: $0.width, height: $0.height,
                constants: constants, realTime: realTimeVideo
            )
        }
        // Allocate the pool before the first frame, so capture never pays for it (T10: images went missing at start).
        video?.warmUp()
        if autoCommit { startTimer() }
    }

    deinit { timer?.cancel() }

    // MARK: Capture thread

    /// A buffer to copy the camera image into, or nil when the pool is full (log the frame without an image).
    public func makeImageBuffer() -> CVPixelBuffer? {
        video?.makeBuffer()
    }

    /// Queues one frame. Returns its `idx`, or nil when the frame was dropped (queue full, stopped or failed).
    /// The record's `index` and `hasImage` are set by the writer.
    @discardableResult
    public func enqueue(_ frame: FrameRecord, image: PixelBufferBox?) -> Int? {
        let index: Int? = state.withLock { counters in
            guard counters.accepting, !counters.failed else { return nil }
            guard counters.pending < constants.writeQueueFrames else {
                counters.dropped += 1
                return nil
            }
            counters.pending += 1
            defer { counters.nextIndex += 1 }
            return counters.nextIndex
        }
        guard let index else { return nil }
        var numbered = frame
        numbered.index = index
        let record = numbered
        queue.async { self.accept(record, image: image) }
        return index
    }

    /// The last accepted frame, for stamping anchor callbacks, fixes and events. -1 before the first frame.
    public var lastFrameIndex: Int {
        state.withLock { $0.nextIndex - 1 }
    }

    public var droppedFrames: Int {
        state.withLock { $0.dropped }
    }

    /// True once a commit failed (disk full, I/O error). Nothing more is accepted; stop the recording.
    public var hasFailed: Bool {
        state.withLock { $0.failed }
    }

    public func enqueue(_ anchor: AnchorRecord) { submit { $0.anchors.append(anchor) } }
    public func enqueue(_ location: LocationRecord) { submit { $0.locations.append(location) } }
    public func enqueue(_ heading: HeadingRecord) { submit { $0.headings.append(heading) } }
    public func enqueue(_ event: EventRecord) { submit { $0.events.append(event) } }
    public func enqueue(_ cloud: CloudRecord) { submit { $0.clouds.append(cloud) } }

    // MARK: Lifecycle

    /// Commits whatever is waiting. Blocks until done; use from tests or when stopping.
    public func flush() throws {
        var thrown: (any Error)?
        queue.sync {
            do { try commit() } catch { thrown = error }
        }
        if let thrown { throw thrown }
    }

    /// Stops accepting, commits the rest, writes the final `meta` rows (plus `meta`), finishes the video and seals
    /// the database.
    public func finish(stopReason: StopReason, meta: [(key: String, value: String)] = []) async throws -> SessionSummary {
        state.withLock { $0.accepting = false }
        let summary: SessionSummary = try await onQueue {
            self.timer?.cancel()
            self.timer = nil
            try self.commit()
            let summary = SessionSummary(
                framesLogged: self.state.withLock { $0.nextIndex },
                framesWithImage: self.framesWithImage,
                framesDropped: self.state.withLock { $0.dropped },
                imageSkips: self.imageSkips.counts
            )
            try self.database.transaction {
                try self.database.setMeta("frames_logged", "\(summary.framesLogged)")
                try self.database.setMeta("frames_with_image", "\(summary.framesWithImage)")
                try self.database.setMeta("frames_dropped", "\(summary.framesDropped)")
                try self.database.setMeta("stopped_at", ISO8601DateFormatter().string(from: .now))
                try self.database.setMeta("stop_reason", stopReason.rawValue)
                for row in self.imageSkips.metaRows + meta {
                    try self.database.setMeta(row.key, row.value)
                }
            }
            return summary
        }
        // Nothing else reaches the queue once accepting is off, so finishing the video here can't race it.
        try await video?.finish()
        try await onQueue { try self.database.seal() }
        return summary
    }

    // MARK: Queue

    private func accept(_ frame: FrameRecord, image: PixelBufferBox?) {
        var record = frame
        record.hasImage = false
        if let video {
            var missing: String?
            if let image {
                switch video.append(image.buffer, frameIndex: record.index) {
                case .appended:
                    record.hasImage = true
                    framesWithImage += 1
                case .skipped(let reason):
                    missing = reason.rawValue
                }
            } else {
                missing = "no_buffer"
            }
            if let burst = imageSkips.record(missing: missing) {
                batch.events.append(EventRecord(frameIndex: record.index, kind: "image_skip", detail: burst))
            }
        }
        batch.frames.append(record)
    }

    private func submit(_ add: @escaping @Sendable (inout Batch) -> Void) {
        guard state.withLock({ $0.accepting && !$0.failed }) else { return }
        queue.async { add(&self.batch) }
    }

    /// On `queue`: one transaction for everything waiting.
    private func commit() throws {
        guard !batch.isEmpty else { return }
        let pending = batch
        batch = Batch()
        do {
            try database.transaction {
                for f in pending.frames { try database.insert(f) }
                for a in pending.anchors { try database.insert(a) }
                for l in pending.locations { try database.insert(l) }
                for h in pending.headings { try database.insert(h) }
                for e in pending.events { try database.insert(e) }
                for c in pending.clouds { try database.insert(c) }
            }
        } catch {
            state.withLock { $0.failed = true }
            throw error
        }
        state.withLock { $0.pending -= pending.frames.count }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(Int(constants.commitIntervalS * 1000))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in try? self?.commit() }
        timer.resume()
        self.timer = timer
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    // MARK: Testing

    /// Stops the queue from running, to simulate a stalled disk. Balance with `resumeForTesting()`.
    func suspendForTesting() { queue.suspend() }
    func resumeForTesting() { queue.resume() }
}
