import ARKit
import Foundation
import Observation
import OSLog
import PlaneKit
import UIKit

/// Plane Lab recorder (`../SPEC.md` §4). **Record** writes a `.planelab` bundle (`session.sqlite` + `video.mov`) into
/// `Documents/Sessions/` while the plane viewer keeps running.
///
/// Per frame, inside the delegate: copy the pose, intrinsics and points (`ARRecordAdapter`) and the camera image into
/// a pool buffer, then hand both to `SessionWriter`, which never blocks. The `ARFrame` isn't kept past the call.
@Observable
@MainActor
final class SessionRecorder {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var frames = 0
    private(set) var framesDropped = 0
    /// Frames logged without an image because every pool buffer was busy.
    private(set) var imagesDropped = 0
    private(set) var megabytes: Double = 0
    private(set) var freeGB: Double = 0
    /// One line about the last finished recording, for the HUD.
    private(set) var lastResult: String?
    /// Marks placed in the current recording.
    private(set) var marks = 0

    @ObservationIgnored private var writer: SessionWriter?
    /// The live cloud whose rows go into this recording (`../SPEC.md` T29, P22, P23).
    @ObservationIgnored private var cloud: LiveCloud?
    @ObservationIgnored private var firstTime: TimeInterval?
    @ObservationIgnored private var statsThrottle = Throttle(interval: 1.0)
    @ObservationIgnored private var tracking = TrackingChangeDetector()
    @ObservationIgnored private let diskGuard = DiskGuard(constants: .current)
    @ObservationIgnored private let logger = Logger(subsystem: "br.com.neuralnexgen.sidingsar", category: "recorder")

    func start(configuration: ARConfiguration?, mode: DetectionMode, lidar: Bool, cloud: LiveCloud) {
        guard !isRecording else { return }
        let format = configuration?.videoFormat
        let size = format.map { (width: Int($0.imageResolution.width), height: Int($0.imageResolution.height)) }
        do {
            let bundle = try Self.sessionsFolder().appendingPathComponent("\(Self.stamp()).planelab")
            let created = try SessionWriter(
                bundle: bundle,
                meta: Self.meta(configuration: configuration, mode: mode, lidar: lidar),
                videoSize: size
            )
            writer = created
            // Record clears the cloud, so the recorded cloud starts empty at frame 0 (P22).
            let constants = RecorderConstants.current
            cloud.startRecording(snapshotEvery: constants.cloudSnapshotEvery, fullEvery: constants.cloudFullEvery) { row in
                created.enqueue(row)
            }
            self.cloud = cloud
            logger.info("Recording to \(bundle.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("Recording could not start: \(error.localizedDescription, privacy: .public)")
            lastResult = "Recording failed to start: \(error.localizedDescription)"
            return
        }
        isRecording = true
        firstTime = nil
        elapsed = 0
        frames = 0
        framesDropped = 0
        imagesDropped = 0
        megabytes = 0
        marks = 0
        lastResult = nil
        statsThrottle.reset()
        tracking = TrackingChangeDetector()
    }

    /// Called from `session(_:didUpdate:)` for every frame, with `ARRecordAdapter.frameRecord(frame)`. Never blocks
    /// and never keeps `frame`. Returns the frame's `idx`, or nil when not recording or the writer dropped it.
    @discardableResult
    func capture(_ frame: ARFrame, metadata: FrameRecord) -> Int? {
        guard isRecording, let writer else { return nil }
        firstTime = firstTime ?? frame.timestamp
        // Stop checks come before this frame is recorded, so the cloud's last row covers exactly the recorded frames.
        if statsThrottle.fire(now: frame.timestamp) {
            let free = Self.freeBytes(at: writer.bundle)
            refreshStats(now: frame.timestamp, writer: writer, freeBytes: free)
            if writer.hasFailed {
                stop(reason: .error)
                return nil
            } else if diskGuard.shouldStop(freeBytes: free) {
                stop(reason: .lowDisk)
                return nil
            }
        }

        var image: PixelBufferBox?
        if let buffer = writer.makeImageBuffer(), VideoWriter.copyPixels(from: frame.capturedImage, to: buffer) {
            image = PixelBufferBox(buffer)
        } else {
            imagesDropped += 1
        }
        let index = writer.enqueue(metadata, image: image)
        if index == 0 {
            writer.enqueue(EventRecord(frameIndex: 0, kind: "record", detail: "start"))
            // Planes ARKit found before Record was tapped get no didAdd while recording: log them as added at frame 0.
            record(frame.anchors.compactMap { $0 as? ARPlaneAnchor }, event: .add)
        }
        // The tracking state when recording starts, then every change, on the exact frame (T10).
        if let index, let change = tracking.observe(metadata.tracking, metadata.trackingReason) {
            writer.enqueue(EventRecord(frameIndex: index, kind: "tracking", detail: change))
        }

        return index
    }

    /// ARKit plane callbacks (SPEC §4, T11). Callbacks only record: one queued row per plane, stamped with the last
    /// logged frame.
    func record(_ planes: [ARPlaneAnchor], event: AnchorEvent) {
        guard isRecording, let writer, !planes.isEmpty else { return }
        let frameIndex = max(writer.lastFrameIndex, 0)
        for plane in planes {
            writer.enqueue(ARRecordAdapter.anchorRecord(plane, event: event, frameIndex: frameIndex))
        }
    }

    /// The Mark button: an `event` row to find a moment later, for example "wall A starts here" (SPEC §4 R11).
    func mark() {
        guard isRecording, let writer else { return }
        marks += 1
        writer.enqueue(EventRecord(frameIndex: max(writer.lastFrameIndex, 0), kind: "mark", detail: "mark \(marks)"))
    }

    /// Finishes the bundle in the background. `reason` goes to `meta.stop_reason` (SPEC §3.3, §4 R3 and R9).
    func stop(reason: StopReason) {
        guard isRecording, let writer else { return }
        isRecording = false
        self.writer = nil
        // The cloud's last row reaches the writer before it stops accepting (a few ms of waiting at most).
        let cloudSummary = cloud?.stopRecording(lastIndex: writer.lastFrameIndex)
        cloud = nil
        writer.enqueue(EventRecord(frameIndex: max(writer.lastFrameIndex, 0), kind: "record", detail: "stop:\(reason.rawValue)"))
        let name = writer.bundle.lastPathComponent
        Task {
            do {
                let summary = try await writer.finish(stopReason: reason, meta: cloudSummary?.metaRows ?? [])
                logger.info("Saved \(name, privacy: .public): \(summary.framesLogged) frames, \(summary.framesWithImage) images, \(summary.framesDropped) dropped")
                let reasonNote = reason == .user ? "" : " (stopped: \(reason.rawValue))"
                lastResult = "Saved \(name): \(summary.framesLogged) frames, \(summary.framesWithImage) images\(reasonNote)"
            } catch {
                logger.error("Finishing \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                lastResult = "Saving \(name) failed: \(error.localizedDescription)"
            }
        }
    }

    private func refreshStats(now: TimeInterval, writer: SessionWriter, freeBytes: Int64?) {
        elapsed = now - (firstTime ?? now)
        frames = writer.lastFrameIndex + 1
        framesDropped = writer.droppedFrames
        megabytes = Double(Self.size(of: writer.bundle)) / 1_000_000
        freeGB = Double(freeBytes ?? 0) / 1_000_000_000
    }

    // MARK: Files

    static func sessionsFolder() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let folder = documents.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func size(of folder: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private static func freeBytes(at url: URL) -> Int64? {
        try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }

    // MARK: Meta (SPEC §3.3)

    private static func meta(configuration: ARConfiguration?, mode: DetectionMode, lidar: Bool) -> [(key: String, value: String)] {
        let constants = RecorderConstants.current
        var rows: [(key: String, value: String)] = [
            ("app_version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"),
            ("device_model", deviceModel()),
            ("os_version", UIDevice.current.systemVersion),
            ("lidar", lidar ? "1" : "0"),
            ("plane_detection", mode.rawValue.lowercased()),
            ("world_alignment", alignmentName(configuration?.worldAlignment)),
            ("video_codec", "hevc"),
            ("video_fps", "\(constants.videoFPS)"),
            ("video_bitrate", "\(constants.videoBitrate)"),
        ]
        if let format = configuration?.videoFormat {
            let width = Int(format.imageResolution.width)
            let height = Int(format.imageResolution.height)
            rows += [
                ("video_width", "\(width)"),
                ("video_height", "\(height)"),
                ("arkit_format_fps", "\(format.framesPerSecond)"),
                ("arkit_format_resolution", "\(width)x\(height)"),
            ]
        }
        return rows
    }

    private static func alignmentName(_ alignment: ARConfiguration.WorldAlignment?) -> String {
        switch alignment {
        case .gravity: "gravity"
        case .gravityAndHeading: "gravityAndHeading"
        case .camera: "camera"
        case .none: "unknown"
        @unknown default: "unknown"
        }
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
