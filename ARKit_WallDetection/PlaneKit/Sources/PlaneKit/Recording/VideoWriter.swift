import AVFoundation
import CoreVideo
import Foundation

public enum VideoWriterError: Error, Equatable {
    case cannotStart(String)
    case failed(String)
}

/// Why an image didn't make it into the video. The frame's metadata is logged anyway, with `has_image = 0`.
public enum VideoSkipReason: String, Sendable {
    /// Every pool buffer is still held by the recorder or the encoder.
    case poolExhausted
    /// The encoder input can't take more data right now.
    case notReady
    /// The frame index isn't after the last appended one.
    case outOfOrder
    /// The writer stopped or failed.
    case writerFailed
}

public enum VideoAppendResult: Equatable, Sendable {
    case appended
    case skipped(VideoSkipReason)
}

/// Carries a pixel buffer across one queue hop. `CVPixelBuffer` isn't `Sendable`; the recorder hands each pool buffer
/// to exactly one queue and never touches it again (SPEC §17.5).
public struct PixelBufferBox: @unchecked Sendable {
    public let buffer: CVPixelBuffer

    public init(_ buffer: CVPixelBuffer) {
        self.buffer = buffer
    }
}

/// HEVC `video.mov` for a recording (SPEC §3.4). Log frame `idx` has presentation time `idx / fps`, so frames without
/// an image leave gaps and video time always maps back to `idx`. The file is a fragmented movie, so a killed recording
/// still plays up to its last fragment.
///
/// Keyframes: at most `keyframeIntervalS × videoFPS` encoded images apart (30 by default), so reaching any frame
/// decodes at most 30 images. The encoder counts images, not time, so skipped images stretch the gap in time
/// (measured 2026-09-28: 40 log frames, 0.67 s, around a 10-frame hole).
///
/// Images go through the writer's own pixel pool, capped at `pixelPoolSize` buffers. The cap is the back-pressure:
/// when the encoder falls behind, `makeBuffer()` returns nil and the caller skips that image instead of waiting.
///
/// Not thread-safe: use one instance from one queue. The exception is `makeBuffer()`, which only touches the pixel
/// pool, so the capture thread can copy an image while the writer queue appends the previous one.
public final class VideoWriter {
    public let url: URL
    public let width: Int
    public let height: Int
    public let fps: Int

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let pool: CVPixelBufferPool
    private let poolThreshold: Int
    private var lastIndex = -1

    /// Starts writing at once. `realTime` is true on the phone; tests turn it off and wait for `isReady`.
    public init(
        url: URL,
        width: Int,
        height: Int,
        constants: RecorderConstants = .current,
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        realTime: Bool = true
    ) throws {
        self.url = url
        self.width = width
        self.height = height
        self.fps = constants.videoFPS
        poolThreshold = constants.pixelPoolSize

        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw VideoWriterError.cannotStart(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = false
        writer.movieFragmentInterval = CMTime(seconds: constants.fragmentIntervalS, preferredTimescale: 600)

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: constants.videoBitrate,
            AVVideoMaxKeyFrameIntervalDurationKey: constants.keyframeIntervalS,
            AVVideoMaxKeyFrameIntervalKey: max(1, Int(constants.keyframeIntervalS * Double(constants.videoFPS))),
            AVVideoExpectedSourceFrameRateKey: constants.videoFPS,
            AVVideoAllowFrameReorderingKey: false,
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = realTime
        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: sourceAttributes)

        guard writer.canAdd(input) else { throw VideoWriterError.cannotStart("the writer refused the video input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw VideoWriterError.cannotStart(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw VideoWriterError.cannotStart("no pixel buffer pool") }
        self.pool = pool
    }

    /// Whether the encoder input can take another image now.
    public var isReady: Bool { input.isReadyForMoreMediaData }

    /// A buffer from the writer's pool, or nil when `pixelPoolSize` buffers are already in use. Safe from any thread.
    public func makeBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: poolThreshold] as CFDictionary
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, aux, &buffer)
        return status == kCVReturnSuccess ? buffer : nil
    }

    /// Allocates every pool buffer now and hands them back, so the first frames of a recording don't pay for the
    /// allocation during capture (T10).
    public func warmUp() {
        var held: [CVPixelBuffer] = []
        while held.count < poolThreshold, let buffer = makeBuffer() {
            held.append(buffer)
        }
    }

    /// Appends a pool buffer as log frame `frameIndex`. Never blocks.
    public func append(_ buffer: CVPixelBuffer, frameIndex: Int) -> VideoAppendResult {
        guard writer.status == .writing else { return .skipped(.writerFailed) }
        guard frameIndex > lastIndex else { return .skipped(.outOfOrder) }
        guard input.isReadyForMoreMediaData else { return .skipped(.notReady) }
        let time = Self.presentationTime(frameIndex: frameIndex, fps: fps)
        guard adaptor.append(buffer, withPresentationTime: time) else { return .skipped(.writerFailed) }
        lastIndex = frameIndex
        return .appended
    }

    /// Copies `source` into a pool buffer and appends it. The source isn't retained after the call returns.
    public func append(copyOf source: CVPixelBuffer, frameIndex: Int) -> VideoAppendResult {
        guard let buffer = makeBuffer() else { return .skipped(.poolExhausted) }
        guard Self.copyPixels(from: source, to: buffer) else { return .skipped(.writerFailed) }
        return append(buffer, frameIndex: frameIndex)
    }

    /// Finishes the movie. Throws when the writer failed at any point.
    public func finish() async throws {
        guard writer.status == .writing else {
            throw VideoWriterError.failed(writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw VideoWriterError.failed(writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")
        }
    }

    /// Abandons the movie. AVFoundation deletes the partial file, so use `finish()` to keep what was recorded.
    public func cancel() {
        guard writer.status == .writing else { return }
        writer.cancelWriting()
    }

    public static func presentationTime(frameIndex: Int, fps: Int) -> CMTime {
        CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
    }

    /// Copies pixel data plane by plane. Both buffers must have the same format and size. Returns false otherwise.
    public static func copyPixels(from source: CVPixelBuffer, to destination: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(source) == CVPixelBufferGetPixelFormatType(destination),
              CVPixelBufferGetWidth(source) == CVPixelBufferGetWidth(destination),
              CVPixelBufferGetHeight(source) == CVPixelBufferGetHeight(destination)
        else { return false }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        let planes = CVPixelBufferGetPlaneCount(source)
        if planes == 0 {
            guard let src = CVPixelBufferGetBaseAddress(source), let dst = CVPixelBufferGetBaseAddress(destination)
            else { return false }
            copyRows(
                from: src, sourceStride: CVPixelBufferGetBytesPerRow(source),
                to: dst, destinationStride: CVPixelBufferGetBytesPerRow(destination),
                rows: CVPixelBufferGetHeight(source)
            )
            return true
        }
        for plane in 0..<planes {
            guard let src = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let dst = CVPixelBufferGetBaseAddressOfPlane(destination, plane)
            else { return false }
            copyRows(
                from: src, sourceStride: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                to: dst, destinationStride: CVPixelBufferGetBytesPerRowOfPlane(destination, plane),
                rows: CVPixelBufferGetHeightOfPlane(source, plane)
            )
        }
        return true
    }

    private static func copyRows(
        from src: UnsafeMutableRawPointer, sourceStride: Int,
        to dst: UnsafeMutableRawPointer, destinationStride: Int,
        rows: Int
    ) {
        if sourceStride == destinationStride {
            dst.copyMemory(from: src, byteCount: sourceStride * rows)
            return
        }
        let rowBytes = min(sourceStride, destinationStride)
        for row in 0..<rows {
            (dst + row * destinationStride).copyMemory(from: src + row * sourceStride, byteCount: rowBytes)
        }
    }
}
