import CoreImage
import CoreVideo
import Dispatch
import Foundation
import ImageIO
import simd
import Synchronization

/// Decides when to take a high-resolution still (P29): the first one as soon as tracking is normal, then each time
/// the camera has moved `moveM` or turned `turnDeg` since the last one, never within `minIntervalS` of it.
public struct StillTrigger: Sendable, Equatable {
    public let moveM: Float
    public let turnDeg: Float
    public let minIntervalS: TimeInterval
    private var lastTime: TimeInterval?
    private var lastPosition = SIMD3<Float>.zero
    private var lastForward = SIMD3<Float>(0, 0, -1)

    public init(moveM: Double, turnDeg: Double, minIntervalS: TimeInterval) {
        self.moveM = Float(moveM)
        self.turnDeg = Float(turnDeg)
        self.minIntervalS = minIntervalS
    }

    public init(constants: RecorderConstants) {
        self.init(moveM: constants.stillMoveM, turnDeg: constants.stillTurnDeg, minIntervalS: constants.stillMinIntervalS)
    }

    public func isDue(time: TimeInterval, camera: simd_float4x4, trackingNormal: Bool) -> Bool {
        guard trackingNormal else { return false }
        guard let lastTime else { return true }
        guard time - lastTime >= minIntervalS else { return false }
        if simd_distance(Self.position(camera), lastPosition) >= moveM { return true }
        let cosine = simd_clamp(simd_dot(Self.forward(camera), lastForward), -1, 1)
        return acos(cosine) * 180 / .pi >= turnDeg
    }

    /// Call when a still was requested.
    public mutating func fired(time: TimeInterval, camera: simd_float4x4) {
        lastTime = time
        lastPosition = Self.position(camera)
        lastForward = Self.forward(camera)
    }

    public mutating func reset() {
        lastTime = nil
    }

    static func position(_ camera: simd_float4x4) -> SIMD3<Float> {
        SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
    }

    /// ARKit cameras look down their −Z axis.
    static func forward(_ camera: simd_float4x4) -> SIMD3<Float> {
        simd_normalize(-SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z))
    }
}

/// One still's pose and camera, copied out of the high-resolution `ARFrame`.
public struct StillMeta: Sendable, Equatable {
    /// `ARFrame.timestamp`, the same clock as `frame.t`.
    public var timestamp: TimeInterval
    /// The last logged frame when the still arrived.
    public var frameIndex: Int
    /// World ← camera (`ARCamera.transform`), ARKit axes.
    public var camera: simd_float4x4
    /// Intrinsics for `cameraImageSize`.
    public var intrinsics: simd_float3x3
    /// `ARCamera.imageResolution`.
    public var cameraImageSize: SIMD2<Int>
    public var exposure: TimeInterval
    /// `TrackingChangeDetector.detail` text, for example `normal` or `limited/relocalizing`.
    public var tracking: String
    /// `ARFrame.exifData` as JSON, nil when absent.
    public var exif: Data?

    public init(
        timestamp: TimeInterval, frameIndex: Int, camera: simd_float4x4, intrinsics: simd_float3x3,
        cameraImageSize: SIMD2<Int>, exposure: TimeInterval, tracking: String, exif: Data?
    ) {
        self.timestamp = timestamp
        self.frameIndex = frameIndex
        self.camera = camera
        self.intrinsics = intrinsics
        self.cameraImageSize = cameraImageSize
        self.exposure = exposure
        self.tracking = tracking
        self.exif = exif
    }

    /// EXIF as JSON. Values JSON can't hold (such as `Data`) are left out rather than failing the whole dictionary.
    public static func exifJSON(_ exif: [String: Any]) -> Data? {
        guard let clean = jsonSafe(exif) as? [String: Any], !clean.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys])
    }

    static func jsonSafe(_ value: Any) -> Any? {
        switch value {
        case let text as String: return text
        case let number as NSNumber:
            return number.doubleValue.isFinite ? number : nil
        case let array as [Any]: return array.compactMap(jsonSafe)
        case let dictionary as [String: Any]: return dictionary.compactMapValues(jsonSafe)
        default: return nil
        }
    }
}

/// What the stills of one recording came to; its `metaRows` go into `session.sqlite` at Stop.
public struct StillSummary: Sendable, Equatable {
    public var saved = 0
    /// Captures that failed, stills that couldn't be encoded or written, and stills that arrived after Stop.
    public var failed = 0
    public var bytes: Int64 = 0
    /// Size of the last saved still.
    public var width = 0
    public var height = 0

    public init() {}

    public var metaRows: [(key: String, value: String)] {
        [
            ("stills_saved", "\(saved)"), ("stills_failed", "\(failed)"), ("stills_bytes", "\(bytes)"),
            ("stills_width", "\(width)"), ("stills_height", "\(height)"),
        ]
    }
}

/// Writes a recording's high-resolution stills (P29) into `<bundle>/stills/`: one JPEG per still, in the camera's
/// own orientation, plus one line per saved still in `stills.jsonl` with its pose and intrinsics. Poses stay in
/// ARKit's convention; exporters convert.
///
/// One still at a time: `begin()` hands out a number only when none is in flight, and the flight ends when the still
/// is written or given up. So at most one full-size image is in memory. Thread-safe; files are only touched on
/// `queue`.
public final class StillWriter: @unchecked Sendable {
    public static let folderName = "stills"
    public static let indexName = "stills.jsonl"

    public let folder: URL
    private let quality: Double
    private let queue = DispatchQueue(label: "br.com.neuralnexgen.sidingsar.still-writer", qos: .utility)
    private let state = Mutex(State())
    private let context = CIContext(options: [.cacheIntermediates: false])
    // Queue-confined.
    private let index: FileHandle
    private var closed = false

    private struct State {
        var inFlight = false
        var nextNumber = 1
        var summary = StillSummary()
    }

    public init(bundle: URL, quality: Double) throws {
        folder = bundle.appendingPathComponent(Self.folderName, isDirectory: true)
        self.quality = quality
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let indexURL = folder.appendingPathComponent(Self.indexName)
        FileManager.default.createFile(atPath: indexURL.path, contents: nil)
        index = try FileHandle(forWritingTo: indexURL)
    }

    /// The still's file name, for example `000001.jpg`.
    public static func fileName(_ number: Int) -> String {
        String(format: "%06d.jpg", number)
    }

    /// Starts a still: its number, or nil while another is in flight.
    public func begin() -> Int? {
        state.withLock { state in
            guard !state.inFlight else { return nil }
            state.inFlight = true
            defer { state.nextNumber += 1 }
            return state.nextNumber
        }
    }

    /// The capture failed: count it and let the next still start.
    public func abandon() {
        state.withLock { state in
            state.summary.failed += 1
            state.inFlight = false
        }
    }

    /// Encodes and writes still `number` in the background, then lets the next one start.
    public func write(_ number: Int, meta: StillMeta, image: PixelBufferBox) {
        queue.async {
            let saved = self.save(number, meta: meta, image: image)
            self.state.withLock { state in
                if let saved {
                    state.summary.saved += 1
                    state.summary.bytes += saved.bytes
                    state.summary.width = saved.width
                    state.summary.height = saved.height
                } else {
                    state.summary.failed += 1
                }
                state.inFlight = false
            }
        }
    }

    /// Counts so far, for the HUD.
    public var progress: StillSummary {
        state.withLock { $0.summary }
    }

    /// Waits for the stills already handed over, closes `stills.jsonl` and returns the counts. Later stills are
    /// counted as failed and not written.
    public func finish() async -> StillSummary {
        await withCheckedContinuation { continuation in
            queue.async {
                self.closed = true
                try? self.index.close()
                continuation.resume()
            }
        }
        return progress
    }

    // MARK: Queue

    private func save(_ number: Int, meta: StillMeta, image: PixelBufferBox) -> (bytes: Int64, width: Int, height: Int)? {
        guard !closed else { return nil }
        let width = CVPixelBufferGetWidth(image.buffer)
        let height = CVPixelBufferGetHeight(image.buffer)
        let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = context.jpegRepresentation(of: CIImage(cvPixelBuffer: image.buffer), colorSpace: colorSpace, options: options)
        else { return nil }
        let name = Self.fileName(number)
        do {
            try jpeg.write(to: folder.appendingPathComponent(name))
            try index.write(contentsOf: Self.line(number: number, file: name, width: width, height: height, meta: meta))
            try index.synchronize()
        } catch {
            return nil
        }
        return (Int64(jpeg.count), width, height)
    }

    /// One `stills.jsonl` line. `camera_to_world` is `ARCamera.transform` written row by row (ARKit axes: camera +X
    /// right, +Y up, looking down −Z; world +Y up; metres). `fx`, `fy`, `cx`, `cy` belong to
    /// `camera_image_width` × `camera_image_height`; scale them if the JPEG's `width` × `height` differs.
    static func line(number: Int, file: String, width: Int, height: Int, meta: StillMeta) throws -> Data {
        let m = meta.camera
        let rows = (0..<4).map { r in [m.columns.0[r], m.columns.1[r], m.columns.2[r], m.columns.3[r]].map(Double.init) }
        let k = meta.intrinsics
        var object: [String: Any] = [
            "still": number,
            "file": file,
            "t": meta.timestamp,
            "frame_idx": meta.frameIndex,
            "width": width,
            "height": height,
            "camera_image_width": meta.cameraImageSize.x,
            "camera_image_height": meta.cameraImageSize.y,
            "fx": Double(k.columns.0.x),
            "fy": Double(k.columns.1.y),
            "cx": Double(k.columns.2.x),
            "cy": Double(k.columns.2.y),
            "camera_to_world": rows,
            "exposure_s": meta.exposure,
            "tracking": meta.tracking,
        ]
        if let exif = meta.exif, let parsed = try? JSONSerialization.jsonObject(with: exif) {
            object["exif"] = parsed
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }
}
