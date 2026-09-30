import CoreVideo
import Foundation
import ImageIO
import simd
import Testing
@testable import PlaneKit

@Suite("High-resolution stills")
struct StillsTests {
    /// A camera at `position`, turned `yawDeg` about +Y.
    static func camera(_ position: SIMD3<Float>, yawDeg: Float = 0) -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: yawDeg * .pi / 180, axis: SIMD3(0, 1, 0)))
        m.columns.3 = SIMD4(position, 1)
        return m
    }

    static let meta = StillMeta(
        timestamp: 1234.5, frameIndex: 42, camera: camera(SIMD3(1, 2, 3)),
        intrinsics: simd_float3x3(SIMD3(3050, 0, 0), SIMD3(0, 3051, 0), SIMD3(2016, 1512, 1)),
        cameraImageSize: SIMD2(4032, 3024), exposure: 0.001, tracking: "normal",
        exif: StillMeta.exifJSON(["ExposureTime": 0.001, "ISOSpeedRatings": [32]])
    )

    // MARK: Trigger

    @Test func firstStillWaitsForNormalTracking() {
        let trigger = StillTrigger(constants: RecorderConstants())
        #expect(!trigger.isDue(time: 0, camera: Self.camera(.zero), trackingNormal: false))
        #expect(trigger.isDue(time: 0, camera: Self.camera(.zero), trackingNormal: true))
    }

    @Test func nextStillAfterMovingFarEnough() {
        var trigger = StillTrigger(moveM: 0.25, turnDeg: 10, minIntervalS: 0.25)
        trigger.fired(time: 0, camera: Self.camera(.zero))
        #expect(!trigger.isDue(time: 1, camera: Self.camera(SIMD3(0.2, 0, 0)), trackingNormal: true))
        #expect(trigger.isDue(time: 1, camera: Self.camera(SIMD3(0.26, 0, 0)), trackingNormal: true))
        #expect(!trigger.isDue(time: 1, camera: Self.camera(SIMD3(0.26, 0, 0)), trackingNormal: false))
    }

    @Test func nextStillAfterTurningFarEnough() {
        var trigger = StillTrigger(moveM: 0.25, turnDeg: 10, minIntervalS: 0.25)
        trigger.fired(time: 0, camera: Self.camera(.zero))
        #expect(!trigger.isDue(time: 1, camera: Self.camera(.zero, yawDeg: 9), trackingNormal: true))
        #expect(trigger.isDue(time: 1, camera: Self.camera(.zero, yawDeg: 11), trackingNormal: true))
        #expect(trigger.isDue(time: 1, camera: Self.camera(.zero, yawDeg: -11), trackingNormal: true))
    }

    @Test func minimumIntervalHoldsEvenWhenMovingFast() {
        var trigger = StillTrigger(moveM: 0.25, turnDeg: 10, minIntervalS: 0.25)
        trigger.fired(time: 10, camera: Self.camera(.zero))
        #expect(!trigger.isDue(time: 10.2, camera: Self.camera(SIMD3(5, 0, 0)), trackingNormal: true))
        #expect(trigger.isDue(time: 10.3, camera: Self.camera(SIMD3(5, 0, 0)), trackingNormal: true))
    }

    @Test func resetStartsOver() {
        var trigger = StillTrigger(moveM: 0.25, turnDeg: 10, minIntervalS: 0.25)
        trigger.fired(time: 0, camera: Self.camera(.zero))
        #expect(!trigger.isDue(time: 0.1, camera: Self.camera(.zero), trackingNormal: true))
        trigger.reset()
        #expect(trigger.isDue(time: 0.1, camera: Self.camera(.zero), trackingNormal: true))
    }

    // MARK: EXIF

    @Test func exifKeepsWhatJSONCanHold() throws {
        let data = try #require(StillMeta.exifJSON([
            "ExposureTime": 0.002, "LensModel": "wide", "Raw": Data([1, 2]), "Nested": ["ISO": 50, "Blob": Data()],
        ]))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["ExposureTime", "LensModel", "Nested"])
        #expect((object["Nested"] as? [String: Any])?.keys.sorted() == ["ISO"])
        #expect(StillMeta.exifJSON([:]) == nil)
    }

    // MARK: Writer

    @Test func lineCarriesPoseRowByRowAndIntrinsics() throws {
        let data = try StillWriter.line(number: 7, file: "000007.jpg", width: 4032, height: 3024, meta: Self.meta)
        #expect(data.last == 0x0A)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["still"] as? Int == 7)
        #expect(object["file"] as? String == "000007.jpg")
        #expect(object["frame_idx"] as? Int == 42)
        #expect(object["t"] as? Double == 1234.5)
        #expect(object["fx"] as? Double == 3050)
        #expect(object["fy"] as? Double == 3051)
        #expect(object["cx"] as? Double == 2016)
        #expect(object["cy"] as? Double == 1512)
        #expect(object["camera_image_width"] as? Int == 4032)
        let rows = try #require(object["camera_to_world"] as? [[Double]])
        #expect(rows.count == 4)
        #expect(rows.map { $0[3] } == [1, 2, 3, 1])
        #expect(rows[3] == [0, 0, 0, 1])
        #expect((object["exif"] as? [String: Any])?["ExposureTime"] as? Double == 0.001)
    }

    @Test func oneStillInFlightAtATime() async throws {
        let folder = TempFolder()
        let writer = try StillWriter(bundle: folder.url, quality: 0.9)
        let first = try #require(writer.begin())
        #expect(first == 1)
        #expect(writer.begin() == nil)
        writer.abandon()
        let second = try #require(writer.begin())
        #expect(second == 2)
        writer.write(second, meta: Self.meta, image: PixelBufferBox(TestFrames.numbered(5, width: 64, height: 48)))
        let summary = await writer.finish()
        #expect(summary.saved == 1)
        #expect(summary.failed == 1)
        #expect(writer.begin() == 3)
    }

    @Test func writesAJPEGAndItsLine() async throws {
        let folder = TempFolder()
        let writer = try StillWriter(bundle: folder.url, quality: 0.9)
        let number = try #require(writer.begin())
        writer.write(number, meta: Self.meta, image: PixelBufferBox(TestFrames.numbered(5, width: 640, height: 480)))
        let summary = await writer.finish()
        #expect(summary.saved == 1)
        #expect(summary.width == 640)
        #expect(summary.height == 480)
        #expect(summary.bytes > 0)
        #expect(summary.metaRows.first { $0.key == "stills_saved" }?.value == "1")

        let stills = folder.url.appendingPathComponent(StillWriter.folderName)
        let jpeg = stills.appendingPathComponent("000001.jpg")
        let source = try #require(CGImageSourceCreateWithURL(jpeg as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 640)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 480)

        let lines = try String(contentsOf: stills.appendingPathComponent(StillWriter.indexName), encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 1)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(object["file"] as? String == "000001.jpg")
        #expect(object["width"] as? Int == 640)
    }

    @Test func stillsAfterFinishAreCountedNotWritten() async throws {
        let folder = TempFolder()
        let writer = try StillWriter(bundle: folder.url, quality: 0.9)
        let number = try #require(writer.begin())
        _ = await writer.finish()
        writer.write(number, meta: Self.meta, image: PixelBufferBox(TestFrames.numbered(1, width: 64, height: 48)))
        let later = await writer.finish()
        #expect(later.saved == 0)
        #expect(later.failed == 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: writer.folder.path)
        #expect(files == [StillWriter.indexName])
    }
}
