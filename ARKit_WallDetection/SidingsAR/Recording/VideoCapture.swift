import ARKit
import Foundation
import Observation
import OSLog
import PlaneKit

/// Spike R1 (`../SPEC.md` §18 T3): can the iPhone 13 copy and encode every camera image at 60 fps while the plane
/// viewer runs? Behind a temporary Debug-menu toggle; T7 replaces it with the real recorder.
///
/// Per frame, inside the delegate: copy `capturedImage` into a pool buffer (the only work on the main thread), then
/// hand it to the writer queue. The `ARFrame` and ARKit's buffer are never kept past the call. Output goes to
/// `Documents/Spikes/`: the movie and `r1-<stamp>.json` with the numbers.
@Observable
@MainActor
final class VideoCapture {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    /// Frames delivered by ARKit per second over the last second.
    private(set) var fps: Double = 0
    private(set) var written = 0
    private(set) var dropped = 0
    private(set) var copyP95Ms: Double = 0
    private(set) var thermal = ProcessInfo.ThermalState.nominal

    @ObservationIgnored private var spike: SpikeWriter?
    @ObservationIgnored private var stamp = ""
    @ObservationIgnored private var frameIndex = 0
    @ObservationIgnored private var firstTime: TimeInterval?
    @ObservationIgnored private var copyMs: [Double] = []
    @ObservationIgnored private var poolDrops = 0
    @ObservationIgnored private var maxThermal = ProcessInfo.ThermalState.nominal
    @ObservationIgnored private var startMemoryMB: Double = 0
    @ObservationIgnored private var statsThrottle = Throttle(interval: 0.5)
    @ObservationIgnored private var sampleThrottle = Throttle(interval: 1.0)
    @ObservationIgnored private var window: (time: TimeInterval, frames: Int)?
    @ObservationIgnored private var timeline: [SpikeSample] = []
    @ObservationIgnored private var formatFPS = 0
    @ObservationIgnored private var formatResolution = ""
    @ObservationIgnored private let logger = Logger(subsystem: "br.com.neuralnexgen.sidingsar", category: "spike-r1")

    /// `format` is the running configuration's video format: what ARKit promised, to compare with what it delivers.
    func start(memoryMB: Double, format: ARConfiguration.VideoFormat?) {
        guard !isRecording else { return }
        isRecording = true
        stamp = Self.stampFormatter.string(from: .now)
        frameIndex = 0
        firstTime = nil
        elapsed = 0
        fps = 0
        written = 0
        dropped = 0
        copyMs.removeAll(keepingCapacity: true)
        poolDrops = 0
        maxThermal = ProcessInfo.processInfo.thermalState
        startMemoryMB = memoryMB
        statsThrottle.reset()
        sampleThrottle.reset()
        window = nil
        timeline.removeAll()
        formatFPS = format?.framesPerSecond ?? 0
        formatResolution = format.map { "\(Int($0.imageResolution.width))x\(Int($0.imageResolution.height))" } ?? "unknown"
        logger.info("R1 spike started; ARKit format \(self.formatResolution, privacy: .public) @ \(self.formatFPS) fps")
    }

    /// Called from `session(_:didUpdate:)` for every frame. Never blocks and never keeps `frame`.
    func capture(_ frame: ARFrame, memoryMB: Double) {
        guard isRecording else { return }
        let index = frameIndex
        frameIndex += 1
        let time = frame.timestamp
        firstTime = firstTime ?? time
        elapsed = time - (firstTime ?? time)
        sample(time: time, memoryMB: memoryMB)
        let image = frame.capturedImage

        if spike == nil, !openWriter(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image)) {
            return
        }
        guard let spike else { return }

        let clock = ContinuousClock()
        let started = clock.now
        guard let buffer = spike.writer.makeBuffer() else {
            poolDrops += 1
            dropped += 1
            return
        }
        guard VideoWriter.copyPixels(from: image, to: buffer) else {
            poolDrops += 1
            dropped += 1
            return
        }
        let took = clock.now - started
        copyMs.append(Double(took.components.attoseconds) / 1e15 + Double(took.components.seconds) * 1000)

        let box = PixelBufferBox(buffer)
        spike.queue.async { [weak self] in
            let appended = spike.append(box, frameIndex: index)
            Task { @MainActor in self?.recordAppend(appended) }
        }

        if statsThrottle.fire(now: time) {
            thermal = ProcessInfo.processInfo.thermalState
            if thermal.rawValue > maxThermal.rawValue { maxThermal = thermal }
            copyP95Ms = Self.percentile(copyMs, 0.95)
        }
    }

    /// Once a second of frame time: delivered fps, memory and thermal state, so the summary shows trends, not only
    /// the endpoints.
    private func sample(time: TimeInterval, memoryMB: Double) {
        guard sampleThrottle.fire(now: time) else { return }
        if let window, time > window.time {
            fps = Double(frameIndex - window.frames) / (time - window.time)
        }
        window = (time, frameIndex)
        let state = ProcessInfo.processInfo.thermalState
        timeline.append(SpikeSample(
            t: elapsed, fps: fps, memoryMB: memoryMB, thermal: Self.name(state), dropped: dropped
        ))
    }

    func stop(memoryMB: Double) {
        guard isRecording else { return }
        isRecording = false
        guard let spike else { return }
        self.spike = nil
        let summary = SpikeSummary(
            device: Self.deviceModel(),
            arkitFormatFPS: formatFPS,
            arkitFormatResolution: formatResolution,
            imageWidth: spike.writer.width,
            imageHeight: spike.writer.height,
            frames: frameIndex,
            durationS: elapsed,
            meanFPS: elapsed > 0 ? Double(frameIndex - 1) / elapsed : 0,
            poolDrops: poolDrops,
            copyP50Ms: Self.percentile(copyMs, 0.5),
            copyP95Ms: Self.percentile(copyMs, 0.95),
            copyMaxMs: copyMs.max() ?? 0,
            maxThermal: Self.name(maxThermal),
            memoryStartMB: startMemoryMB,
            memoryEndMB: memoryMB,
            constants: Dictionary(uniqueKeysWithValues: RecorderConstants.current.metaRows.map { ($0.key, $0.value) }),
            timeline: timeline
        )
        let summaryURL = spike.writer.url.deletingPathExtension().appendingPathExtension("json")
        let logger = logger
        spike.queue.async {
            Task {
                do {
                    try await spike.writer.finish()
                } catch {
                    logger.error("R1 spike video failed: \(error.localizedDescription, privacy: .public)")
                }
                spike.writeSummary(summary, to: summaryURL, logger: logger)
            }
        }
        logger.info("R1 spike stopped after \(self.frameIndex) frames")
    }

    private func openWriter(width: Int, height: Int) -> Bool {
        do {
            let folder = try Self.spikesFolder()
            let url = folder.appendingPathComponent("r1-\(stamp).mov")
            let writer = try VideoWriter(url: url, width: width, height: height)
            spike = SpikeWriter(writer: writer)
            logger.info("R1 spike writing \(width)x\(height) to \(url.lastPathComponent, privacy: .public)")
            return true
        } catch {
            logger.error("R1 spike could not start: \(error.localizedDescription, privacy: .public)")
            isRecording = false
            return false
        }
    }

    private func recordAppend(_ result: VideoAppendResult) {
        switch result {
        case .appended: written += 1
        case .skipped: dropped += 1
        }
    }

    private static func spikesFolder() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let folder = documents.appendingPathComponent("Spikes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    private static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

/// The writer and its queue. Everything except `makeBuffer()` runs on `queue`, so the counters need no lock.
nonisolated final class SpikeWriter: @unchecked Sendable {
    let writer: VideoWriter
    let queue = DispatchQueue(label: "br.com.neuralnexgen.sidingsar.spike-r1", qos: .userInitiated)
    private var appended = 0
    private var skipped: [String: Int] = [:]

    init(writer: VideoWriter) {
        self.writer = writer
    }

    /// On `queue`.
    func append(_ box: PixelBufferBox, frameIndex: Int) -> VideoAppendResult {
        let result = writer.append(box.buffer, frameIndex: frameIndex)
        switch result {
        case .appended: appended += 1
        case .skipped(let reason): skipped[reason.rawValue, default: 0] += 1
        }
        return result
    }

    /// On `queue`, after `finish()`.
    func writeSummary(_ summary: SpikeSummary, to url: URL, logger: Logger) {
        var summary = summary
        summary.imagesWritten = appended
        summary.writerSkips = skipped
        let dropped = summary.poolDrops + skipped.values.reduce(0, +)
        summary.droppedPercent = summary.frames > 0 ? 100 * Double(dropped) / Double(summary.frames) : 0
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(summary).write(to: url)
            logger.info("R1 summary: \(summary.droppedPercent, format: .fixed(precision: 2))% dropped")
        } catch {
            logger.error("R1 summary not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// One second of the spike.
nonisolated struct SpikeSample: Encodable, Sendable {
    var t: Double
    var fps: Double
    var memoryMB: Double
    var thermal: String
    var dropped: Int
}

/// What `r1-<stamp>.json` holds.
nonisolated struct SpikeSummary: Encodable, Sendable {
    var device: String
    var arkitFormatFPS: Int
    var arkitFormatResolution: String
    var imageWidth: Int
    var imageHeight: Int
    var frames: Int
    var durationS: Double
    var meanFPS: Double
    var poolDrops: Int
    var copyP50Ms: Double
    var copyP95Ms: Double
    var copyMaxMs: Double
    var maxThermal: String
    var memoryStartMB: Double
    var memoryEndMB: Double
    var constants: [String: String]
    var timeline: [SpikeSample]
    var imagesWritten = 0
    var writerSkips: [String: Int] = [:]
    var droppedPercent: Double = 0
}
