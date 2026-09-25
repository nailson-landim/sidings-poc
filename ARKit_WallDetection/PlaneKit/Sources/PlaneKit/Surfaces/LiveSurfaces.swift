import Dispatch
import Foundation
import simd
import Synchronization

/// Experiments X1 and X2 while the app runs: a `SurfaceEngine` (`SurfaceScanner` or `RansacScanner`) on its own serial queue, one round at a time.
///
/// Callers never wait. `submit` hands a cloud copy to the queue unless a round is still running, in which case it
/// skips and counts the skip. `latest()` reads the last published tracks. Thread-safe; the engine and its fitter
/// are only touched on `queue`.
///
/// **Recording** (schema v3, `../../EXPERIMENTS.md` XD6): `startRecording` forgets every track, then after each round
/// the tracks that changed go to the sink as `surface` rows (`SurfaceLog`), stamped with the round's `recordIndex`.
/// `stopRecording` waits for a running round and ends it.
public final class LiveSurfaces: @unchecked Sendable {
    public struct Snapshot: Sendable {
        /// Tracks by creation order.
        public var surfaces: [TrackedSurface] = []
        /// Bumped on every publish.
        public var version = 0
        public var report = SurfaceScanner.Report()
        /// Submissions skipped because a round was still running.
        public var skipped = 0
        /// The last error the fitter threw, if any.
        public var lastError: String?
        /// The settings the last round ran with.
        public var settings = SurfaceSettings()
        /// Wall-clock milliseconds of the last rounds (at most `historyLength`), oldest first.
        public var recentMilliseconds: [Double] = []
        /// The last *Benchmark on live cloud*, if one ran.
        public var benchmark: SearchBenchmark?
    }

    /// Rounds kept for the HUD's mean and p95.
    public static let historyLength = 64

    /// What a recording's `surface` rows hold.
    public struct RecordingSummary: Sendable, Equatable {
        public var rows = 0
        /// Tracks, and confirmed tracks, after the last round.
        public var tracks = 0
        public var confirmed = 0
        /// Round rows written, and the median, 95th percentile and slowest round (ms).
        public var rounds = 0
        public var medianMilliseconds: Double = 0
        public var p95Milliseconds: Double = 0
        public var maxMilliseconds: Double = 0

        /// `meta` rows written at Stop.
        public var metaRows: [(key: String, value: String)] {
            [
                ("x1_rows", "\(rows)"), ("x1_tracks", "\(tracks)"), ("x1_confirmed", "\(confirmed)"),
                ("surface_rounds", "\(rounds)"),
                ("surface_round_median_ms", String(format: "%.3f", medianMilliseconds)),
                ("surface_round_p95_ms", String(format: "%.3f", p95Milliseconds)),
                ("surface_round_max_ms", String(format: "%.3f", maxMilliseconds)),
            ]
        }
    }

    private let queue = DispatchQueue(label: "br.com.neuralnexgen.sidingsar.live-surfaces", qos: .userInitiated)
    private let shared = Mutex(Shared())

    // Queue-confined.
    private let scanner: any SurfaceEngine
    private var recording: Recording?

    private struct Recording {
        var log = SurfaceLog()
        let sink: @Sendable (SurfaceRecord) -> Void
        let roundSink: (@Sendable (SurfaceRoundRecord) -> Void)?
        var lastIndex = 0
        var milliseconds: [Double] = []
    }

    private struct Shared {
        var snapshot = Snapshot()
        var busy = false
        var skipped = 0
    }

    public init(settings: SurfaceSettings, fitter: any SurfaceFitter) {
        scanner = SurfaceScanner(settings: settings, fitter: fitter)
        shared.withLock { $0.snapshot.settings = settings }
    }

    public init(engine: any SurfaceEngine) {
        scanner = engine
        let settings = engine.settings
        shared.withLock { $0.snapshot.settings = settings }
    }

    /// New settings from the next round on (the app's X1 dials); the tracks are kept.
    public func update(settings: SurfaceSettings) {
        queue.async {
            self.scanner.apply(settings)
            self.shared.withLock { $0.snapshot.settings = settings }
        }
    }

    /// Queues one round on `cloud` seen from `camera`. Returns false when it skipped because a round is running.
    /// `recordIndex` is the last recorded frame, when recording; rows from the round carry it.
    @discardableResult
    public func submit(cloud: CloudState, camera: simd_float4x4, recordIndex: Int? = nil) -> Bool {
        let start = shared.withLock { shared in
            guard !shared.busy else {
                shared.skipped += 1
                return false
            }
            shared.busy = true
            return true
        }
        guard start else { return false }
        queue.async {
            var failure: String?
            var report = SurfaceScanner.Report()
            do {
                report = try self.scanner.round(cloud: cloud, camera: camera)
            } catch {
                report.round = self.scanner.tracker.round
                failure = String(describing: error)
            }
            self.log(report: report, recordIndex: recordIndex)
            self.publish(report: report, error: failure, timed: failure == nil && report.milliseconds > 0)
            self.shared.withLock { $0.busy = false }
        }
        return true
    }

    /// Times the engine's search on `cloud` `runs` times, on the queue, and publishes the result in `latest().benchmark`.
    /// Skipped while a round is running (the timings would include the wait).
    @discardableResult
    public func runBenchmark(cloud: CloudState, camera: simd_float4x4, runs: Int = 20) -> Bool {
        let start = shared.withLock { shared in
            guard !shared.busy else { return false }
            shared.busy = true
            return true
        }
        guard start else { return false }
        queue.async {
            let result = self.scanner.benchmark(cloud: cloud, camera: camera, runs: runs)
            self.shared.withLock {
                $0.snapshot.benchmark = result
                $0.snapshot.version += 1
                $0.busy = false
            }
        }
        return true
    }

    /// Forgets every track (Reset) and publishes the empty state.
    public func clear() {
        queue.async {
            self.scanner.reset()
            self.publish(report: SurfaceScanner.Report(), error: nil)
        }
    }

    /// Forgets every track, so the recording starts with none, and hands each round's changed tracks to `sink` and,
    /// when given, each round's cost to `roundSink` (schema v4).
    public func startRecording(
        sink: @escaping @Sendable (SurfaceRecord) -> Void, roundSink: (@Sendable (SurfaceRoundRecord) -> Void)? = nil
    ) {
        queue.async {
            self.scanner.reset()
            self.recording = Recording(sink: sink, roundSink: roundSink)
            self.publish(report: SurfaceScanner.Report(), error: nil)
        }
    }

    /// Waits for a running round, then stops handing rows to the sink.
    @discardableResult
    public func stopRecording() -> RecordingSummary {
        queue.sync {
            guard let recording = self.recording else { return RecordingSummary() }
            self.recording = nil
            let tracks = self.scanner.tracker.ordered
            let sorted = recording.milliseconds.sorted()
            func percentile(_ q: Double) -> Double {
                sorted.isEmpty ? 0 : sorted[min(Int(Double(sorted.count - 1) * q + 0.5), sorted.count - 1)]
            }
            return RecordingSummary(
                rows: recording.log.rowCount, tracks: tracks.count,
                confirmed: tracks.count { $0.state == .confirmed }, rounds: sorted.count,
                medianMilliseconds: percentile(0.5), p95Milliseconds: percentile(0.95),
                maxMilliseconds: sorted.last ?? 0
            )
        }
    }

    /// On `queue`: the round's changed tracks as rows, when recording.
    private func log(report: SurfaceScanner.Report, recordIndex: Int?) {
        guard var recording else { return }
        let frame = recordIndex ?? recording.lastIndex
        recording.lastIndex = frame
        let tracks = scanner.tracker.ordered
        for row in recording.log.rows(frameIndex: frame, surfaces: tracks, events: report.events) {
            recording.sink(row)
        }
        if report.round > 0, report.milliseconds > 0, let roundSink = recording.roundSink {
            roundSink(SurfaceRoundRecord(
                frameIndex: frame, round: report.round, points: report.points, unclaimed: report.unclaimed,
                tracks: tracks.count, confirmed: tracks.count { $0.state == .confirmed }, refits: report.refits,
                searched: report.searched, planesFound: report.planesFound, hypotheses: report.hypotheses,
                fullScores: report.fullScores, pointTests: report.pointTests, totalMilliseconds: report.milliseconds,
                refitMilliseconds: report.refitMilliseconds, searchMilliseconds: report.searchMilliseconds,
                skipped: shared.withLock { $0.skipped }, thermal: ProcessInfo.processInfo.thermalState.rawValue
            ))
        }
        if report.round > 0, report.milliseconds > 0 { recording.milliseconds.append(report.milliseconds) }
        self.recording = recording
    }

    /// The last published tracks. Never waits for the queue.
    public func latest() -> Snapshot {
        shared.withLock { $0.snapshot }
    }

    /// Blocks until every queued round has run (tests).
    public func drain() {
        queue.sync {}
    }

    /// On `queue`.
    private func publish(report: SurfaceScanner.Report, error: String?, timed: Bool = false) {
        let surfaces = scanner.tracker.ordered
        shared.withLock { shared in
            var recent = shared.snapshot.recentMilliseconds
            if timed {
                recent.append(report.milliseconds)
                if recent.count > Self.historyLength { recent.removeFirst(recent.count - Self.historyLength) }
            }
            shared.snapshot = Snapshot(
                surfaces: surfaces, version: shared.snapshot.version + 1, report: report, skipped: shared.skipped,
                lastError: error ?? shared.snapshot.lastError, settings: scanner.settings,
                recentMilliseconds: recent, benchmark: shared.snapshot.benchmark
            )
        }
    }

    // MARK: Testing

    func suspendForTesting() { queue.suspend() }
    func resumeForTesting() { queue.resume() }
}
