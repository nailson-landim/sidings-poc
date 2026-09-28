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

    @ObservationIgnored private var writer: SessionWriter?
    @ObservationIgnored private var firstTime: TimeInterval?
    @ObservationIgnored private var statsThrottle = Throttle(interval: 1.0)
    @ObservationIgnored private let logger = Logger(subsystem: "br.com.neuralnexgen.sidingsar", category: "recorder")

    func start(configuration: ARConfiguration?, mode: DetectionMode, lidar: Bool) {
        guard !isRecording else { return }
        let format = configuration?.videoFormat
        let size = format.map { (width: Int($0.imageResolution.width), height: Int($0.imageResolution.height)) }
        do {
            let bundle = try Self.sessionsFolder().appendingPathComponent("\(Self.stamp()).planelab")
            writer = try SessionWriter(
                bundle: bundle,
                meta: Self.meta(configuration: configuration, mode: mode, lidar: lidar),
                videoSize: size
            )
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
        lastResult = nil
        statsThrottle.reset()
    }

    /// Called from `session(_:didUpdate:)` for every frame. Never blocks and never keeps `frame`.
    func capture(_ frame: ARFrame) {
        guard isRecording, let writer else { return }
        firstTime = firstTime ?? frame.timestamp

        var image: PixelBufferBox?
        if let buffer = writer.makeImageBuffer(), VideoWriter.copyPixels(from: frame.capturedImage, to: buffer) {
            image = PixelBufferBox(buffer)
        } else {
            imagesDropped += 1
        }
        let index = writer.enqueue(ARRecordAdapter.frameRecord(frame), image: image)
        if index == 0 {
            writer.enqueue(EventRecord(frameIndex: 0, kind: "record", detail: "start"))
        }

        if statsThrottle.fire(now: frame.timestamp) {
            refreshStats(now: frame.timestamp, writer: writer)
            if writer.hasFailed { stop(reason: "error") }
        }
    }

    /// Finishes the bundle in the background. `reason` goes to `meta.stop_reason` (SPEC §3.3).
    func stop(reason: String) {
        guard isRecording, let writer else { return }
        isRecording = false
        self.writer = nil
        writer.enqueue(EventRecord(frameIndex: max(writer.lastFrameIndex, 0), kind: "record", detail: "stop:\(reason)"))
        let name = writer.bundle.lastPathComponent
        Task {
            do {
                let summary = try await writer.finish(stopReason: reason)
                logger.info("Saved \(name, privacy: .public): \(summary.framesLogged) frames, \(summary.framesWithImage) images, \(summary.framesDropped) dropped")
                lastResult = "Saved \(name): \(summary.framesLogged) frames, \(summary.framesWithImage) images"
            } catch {
                logger.error("Finishing \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                lastResult = "Saving \(name) failed: \(error.localizedDescription)"
            }
        }
    }

    private func refreshStats(now: TimeInterval, writer: SessionWriter) {
        elapsed = now - (firstTime ?? now)
        frames = writer.lastFrameIndex + 1
        framesDropped = writer.droppedFrames
        megabytes = Double(Self.size(of: writer.bundle)) / 1_000_000
        freeGB = Double(Self.freeBytes(at: writer.bundle) ?? 0) / 1_000_000_000
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
