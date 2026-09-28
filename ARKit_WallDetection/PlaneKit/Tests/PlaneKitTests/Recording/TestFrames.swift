import AVFoundation
import CoreVideo
import Foundation
@testable import PlaneKit

/// Test images that carry their own frame number (SPEC §17.4 P4): the luma plane is a 4 × 4 grid of blocks, and
/// block `i` (row-major from the top left) is white when bit `i` of the number is set. That survives HEVC, so a test
/// can tell which frame a decoder returned without anyone looking.
enum TestFrames {
    static let gridSide = 4
    static let bitCount = gridSide * gridSide
    static let white: UInt8 = 235
    static let black: UInt8 = 16

    /// A new full-range 4:2:0 buffer showing `number`.
    static func numbered(_ number: Int, width: Int, height: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes, &buffer
        )
        precondition(status == kCVReturnSuccess, "CVPixelBufferCreate failed: \(status)")
        draw(number, into: buffer!)
        return buffer!
    }

    /// Paints `number` into an existing 4:2:0 buffer: blocks in luma, neutral chroma.
    static func draw(_ number: Int, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let blockWidth = width / gridSide
        for y in 0..<height {
            let blockRow = min(y * gridSide / height, gridSide - 1)
            let row = luma + y * lumaStride
            for column in 0..<gridSide {
                let bit = blockRow * gridSide + column
                let value = (number >> bit) & 1 == 1 ? white : black
                let start = column * blockWidth
                let count = column == gridSide - 1 ? width - start : blockWidth
                memset(row + start, Int32(value), count)
            }
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        memset(chroma, 128, chromaStride * CVPixelBufferGetHeightOfPlane(buffer, 1))
    }

    /// Reads the number back from the center of each block.
    static func number(in buffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        var number = 0
        for bit in 0..<bitCount {
            let x = (bit % gridSide * 2 + 1) * width / (gridSide * 2)
            let y = (bit / gridSide * 2 + 1) * height / (gridSide * 2)
            if luma[y * stride + x] > 128 { number |= 1 << bit }
        }
        return number
    }
}

/// What a movie file holds, read back with AVFoundation.
///
/// When the first image isn't log frame 0, `AVAssetWriter` keeps the gap as an empty edit at the start of the track
/// (FFmpeg applies it: the stream's `start_time` is the gap). `AVAssetReaderTrackOutput` treats that edit differently
/// by mode (measured 2026-09-28):
/// - **passthrough** (`outputSettings: nil`) reports media time and ignores the edit, so `read` maps timestamps
///   through the track's segments;
/// - **decoding** reports movie time with the edit applied and emits one extra blank frame for the empty edit, so
///   `decodeNumbers` keeps its timestamps and drops frames that fall inside an empty segment.
struct VideoProbe {
    var codec: FourCharCode
    /// Log frame index of every sample, from its presentation time, in file order.
    var frames: [Int]
    /// Log frame indices of the keyframes.
    var keyframes: [Int]

    static func read(_ url: URL, fps: Int) async throws -> VideoProbe {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProbeError.noVideoTrack
        }
        let descriptions = try await track.load(.formatDescriptions)
        let codec = descriptions.first.map(CMFormatDescriptionGetMediaSubType) ?? 0
        let segments = try await track.load(.segments)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw ProbeError.cannotRead(reader.error?.localizedDescription ?? "") }

        var frames: [Int] = []
        var keyframes: [Int] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let time = movieTime(CMSampleBufferGetPresentationTimeStamp(sample), segments: segments)
            let index = frameIndex(time, fps: fps)
            frames.append(index)
            if isKeyframe(sample) { keyframes.append(index) }
        }
        return VideoProbe(codec: codec, frames: frames, keyframes: keyframes)
    }

    /// Decodes every frame and reads its drawn number: `[(log frame index from the timestamp, number in the image)]`.
    static func decodeNumbers(_ url: URL, fps: Int) async throws -> [(frame: Int, number: Int)] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProbeError.noVideoTrack
        }
        let segments = try await track.load(.segments)
        let reader = try AVAssetReader(asset: asset)
        let settings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else { throw ProbeError.cannotRead(reader.error?.localizedDescription ?? "") }

        let emptyRanges = segments.filter(\.isEmpty).map(\.timeMapping.target)
        var result: [(frame: Int, number: Int)] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if emptyRanges.contains(where: { $0.containsTime(time) }) { continue }
            result.append((frameIndex(time, fps: fps), TestFrames.number(in: image)))
        }
        return result
    }

    static func frameIndex(_ time: CMTime, fps: Int) -> Int {
        Int((time.seconds * Double(fps)).rounded())
    }

    /// Maps a media timestamp to movie time through the track's non-empty edit segments.
    static func movieTime(_ mediaTime: CMTime, segments: [AVAssetTrackSegment]) -> CMTime {
        for segment in segments where !segment.isEmpty {
            let mapping = segment.timeMapping
            let end = mapping.source.start + mapping.source.duration
            if mediaTime >= mapping.source.start, mediaTime <= end {
                return mapping.target.start + (mediaTime - mapping.source.start)
            }
        }
        return mediaTime
    }

    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]], let first = attachments.first
        else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    enum ProbeError: Error {
        case noVideoTrack
        case cannotRead(String)
    }
}

/// Waits for a free pool buffer, so tests don't drop images by accident.
func waitForBuffer(_ writer: VideoWriter) async throws -> CVPixelBuffer {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if let buffer = writer.makeBuffer() { return buffer }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw WaitError.timedOut("pool buffer")
}

func waitUntilReady(_ writer: VideoWriter) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !writer.isReady {
        guard ContinuousClock.now < deadline else { throw WaitError.timedOut("encoder input") }
        try await Task.sleep(for: .milliseconds(1))
    }
}

enum WaitError: Error {
    case timedOut(String)
}

/// The repository root (`sidings_poc/`), found from this file's path.
let repositoryRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    // Recording/ → PlaneKitTests/ → Tests/ → PlaneKit/ → ARKit_WallDetection/ → sidings_poc/
    for _ in 0..<6 { url.deleteLastPathComponent() }
    return url
}()

/// A scratch folder per test, removed when the test ends.
struct TempFolder: ~Copyable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaneKitTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    deinit { try? FileManager.default.removeItem(at: url) }
}
