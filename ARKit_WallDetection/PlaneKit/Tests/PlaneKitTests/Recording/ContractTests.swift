import Foundation
import simd
import Testing
@testable import PlaneKit

/// The session-format contract (SPEC §3.5, §17.4 P2 and P3). `session-format/fixtures/v4/` holds a tiny session
/// written by the real Swift writer plus `expected.json`, the values it must decode to. Python checks the same pair.
/// `fixtures/v1/` to `fixtures/v3/` are the earlier versions' fixtures, kept to prove old recordings stay readable.
///
/// Regenerate after a deliberate format change (and bump `schema_version`):
/// `PLANELAB_WRITE_FIXTURES=1 swift test --filter writeFixtures`
@Suite("Session-format contract", .serialized)
struct ContractTests {
    static let schemaFile = repositoryRoot.appendingPathComponent("session-format/schema_v4.sql")
    static let fixtureFolder = repositoryRoot.appendingPathComponent("session-format/fixtures/v4")
    static let version1Folder = repositoryRoot.appendingPathComponent("session-format/fixtures/v1")
    static let version2Folder = repositoryRoot.appendingPathComponent("session-format/fixtures/v2")
    static let version3Folder = repositoryRoot.appendingPathComponent("session-format/fixtures/v3")
    static let bundle = fixtureFolder.appendingPathComponent("tiny.planelab")
    static let expectedFile = fixtureFolder.appendingPathComponent("expected.json")

    @Test func embeddedDDLMatchesTheCanonicalFile() throws {
        let file = try String(contentsOf: Self.schemaFile, encoding: .utf8)
        #expect(SessionSchema.ddl == file)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PLANELAB_WRITE_FIXTURES"] != nil))
    func writeFixtures() async throws {
        try await ContractFixture.write(bundle: Self.bundle, expected: Self.expectedFile)
    }

    @Test func committedFixtureDecodesToExpected() async throws {
        let expected = try JSONDecoder().decode(ExpectedSession.self, from: Data(contentsOf: Self.expectedFile))
        let db = try SessionDatabase.open(at: Self.bundle.appendingPathComponent("session.sqlite"))
        let actual = try ExpectedSession(db)
        #expect(actual.meta == expected.meta)
        #expect(actual.frame == expected.frame)
        #expect(actual.plane_anchor == expected.plane_anchor)
        #expect(actual.location == expected.location)
        #expect(actual.heading == expected.heading)
        #expect(actual.event == expected.event)
        #expect(actual.cloud == expected.cloud)
        #expect(actual.cloud?.count == 2)
        #expect(actual.surface == expected.surface)
        #expect(actual.surface?.count == ContractFixture.surfaces.count)
        #expect(actual.surface_round == expected.surface_round)
        #expect(actual.surface_round?.count == 3)

        // The video holds exactly the frames with has_image = 1, each showing its own number (P4).
        let withImage = expected.frame.filter { $0.has_image == 1 }.map(\.idx)
        let video = Self.bundle.appendingPathComponent("video.mov")
        #expect(try await VideoProbe.read(video, fps: 60).frames == withImage)
        let decoded = try await VideoProbe.decodeNumbers(video, fps: 60)
        #expect(decoded.map(\.frame) == decoded.map(\.number))
    }

    @Test func version1FixtureStillDecodes() throws {
        let expectedFile = Self.version1Folder.appendingPathComponent("expected.json")
        let expected = try JSONDecoder().decode(ExpectedSession.self, from: Data(contentsOf: expectedFile))
        let db = try SessionDatabase.open(at: Self.version1Folder.appendingPathComponent("tiny.planelab/session.sqlite"))
        #expect(db.schemaVersion == 1)
        #expect(try db.clouds().isEmpty)
        #expect(try ExpectedSession(db) == expected)
        #expect(expected.cloud == nil)
    }

    @Test func version2FixtureStillDecodes() throws {
        let expectedFile = Self.version2Folder.appendingPathComponent("expected.json")
        let expected = try JSONDecoder().decode(ExpectedSession.self, from: Data(contentsOf: expectedFile))
        let db = try SessionDatabase.open(at: Self.version2Folder.appendingPathComponent("tiny.planelab/session.sqlite"))
        #expect(db.schemaVersion == 2)
        #expect(try db.surfaces().isEmpty)
        #expect(try ExpectedSession(db) == expected)
        #expect(expected.cloud?.count == 2)
        #expect(expected.surface == nil)
    }

    @Test func version3FixtureStillDecodes() throws {
        let expectedFile = Self.version3Folder.appendingPathComponent("expected.json")
        let expected = try JSONDecoder().decode(ExpectedSession.self, from: Data(contentsOf: expectedFile))
        let db = try SessionDatabase.open(at: Self.version3Folder.appendingPathComponent("tiny.planelab/session.sqlite"))
        #expect(db.schemaVersion == 3)
        #expect(try db.surfaceRounds().isEmpty)
        #expect(try ExpectedSession(db) == expected)
        #expect(expected.surface?.count == 7)
        #expect(expected.surface_round == nil)
    }
}

/// The fixture's content: 10 frames covering every table and the edge cases readers must handle.
///
/// - Frame 0 has no points (empty BLOBs) and, like frames 4 and 7, no image, so the video starts with a gap.
/// - Frame 9 has point ids above 2^53 (JSON and float64 can't hold them loosely).
/// - Values are dyadic fractions, so float32 ↔ decimal conversions are exact in every language.
enum ContractFixture {
    static let width = 256
    static let height = 192
    static let withoutImage: Set<Int> = [0, 4, 7]

    struct Records {
        var frames: [FrameRecord]
        var anchors: [AnchorRecord]
        var locations: [LocationRecord]
        var headings: [HeadingRecord]
        var events: [EventRecord]
        var clouds: [CloudRecord]
        var surfaces: [SurfaceRecord]
        var surfaceRounds: [SurfaceRoundRecord]
    }

    static let records = Records(
        frames: frames, anchors: anchors, locations: locations, headings: headings, events: events, clouds: clouds,
        surfaces: surfaces, surfaceRounds: surfaceRounds
    )

    static var meta: [(key: String, value: String)] {
        [
            ("app_version", "fixture"), ("device_model", "iPhone14,5"), ("os_version", "26.0"), ("lidar", "0"),
            ("plane_detection", "both"), ("world_alignment", "gravity"),
            ("video_width", "\(width)"), ("video_height", "\(height)"), ("video_fps", "60"),
            ("video_codec", "hevc"), ("video_bitrate", "8000000"),
            ("arkit_format_fps", "60"), ("arkit_format_resolution", "\(width)x\(height)"),
            ("started_at", "2026-09-28T12:00:00Z"), ("stopped_at", "2026-09-28T12:00:01Z"), ("stop_reason", "user"),
            ("frames_logged", "10"), ("frames_with_image", "7"), ("frames_dropped", "0"),
            ("location_auth", "when_in_use"), ("location_accuracy", "full"),
            ("cloud_rows", "2"), ("cloud_points", "2"), ("cloud_frames_dropped", "0"),
            ("x1_enabled", "1"), ("x1_rows", "\(surfaces.count)"), ("x1_tracks", "2"), ("x1_confirmed", "0"),
            ("surface_engine", "ransac"), ("surface_rounds", "3"), ("surface_round_median_ms", "1.500"),
            ("surface_round_p95_ms", "12.500"), ("surface_round_max_ms", "12.500"),
        ] + RecorderConstants().metaRows + SurfaceSettings().metaRows
    }

    static var frames: [FrameRecord] {
        let quarterTurnY = simd_float4x4(SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(0, 0, 0, 1))
        let intrinsics = simd_float3x3(SIMD3(1500.5, 0, 0), SIMD3(0, 1500.5, 0), SIMD3(960.25, 720.75, 1))
        return (0..<10).map { i in
            var camera = i.isMultiple(of: 2) ? matrix_identity_float4x4 : quarterTurnY
            camera.columns.3 = SIMD4(0.125 * Float(i), 1.5, -0.25 * Float(i), 1)
            let count = i == 0 ? 0 : 3 + i % 3
            let points = (0..<count).map { j in
                SIMD3<Float>(0.5 * Float(j) + Float(i), 1.25 - 0.125 * Float(j), -3.5 - 0.25 * Float(i))
            }
            let ids = (0..<count).map { j in
                i == 9 ? 18_000_000_000_000_000_000 + UInt64(j) : UInt64(i) << 40 | UInt64(j)
            }
            let limited = i < 2 || i == 5
            return FrameRecord(
                index: i,
                timestamp: 1000 + Double(i) / 32,
                hasImage: !withoutImage.contains(i),
                tracking: limited ? .limited : .normal,
                trackingReason: i < 2 ? .initializing : (i == 5 ? .excessiveMotion : .none),
                mapping: min(i / 3, 3),
                camera: camera,
                intrinsics: intrinsics,
                exposure: 0.0078125,
                thermal: i / 4,
                points: points,
                pointIDs: ids
            )
        }
    }

    static var anchors: [AnchorRecord] {
        let wall = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
        let floor = UUID(uuidString: "B0000000-0000-4000-8000-000000000002")!
        let upright = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(1, 0.5, -2, 1))
        let rectangle: [SIMD3<Float>] = [SIMD3(-0.5, 0, -0.25), SIMD3(0.5, 0, -0.25), SIMD3(0.5, 0, 0.25), SIMD3(-0.5, 0, 0.25)]
        let small = AnchorGeometry(
            alignment: 1, classification: 1, transform: upright,
            center: SIMD3(0.125, 0, -0.25), extent: SIMD3(1, 0.5, 0), boundary: rectangle
        )
        var grown = small
        grown.extent = SIMD3(2, 1.25, 0.5)
        grown.boundary = rectangle.map { $0 * 2 }
        var floorTransform = matrix_identity_float4x4
        floorTransform.columns.3 = SIMD4(0, -1.5, -1, 1)
        let floorShape = AnchorGeometry(
            alignment: 0, classification: 2, transform: floorTransform, center: .zero, extent: SIMD3(3, 2.5, 0),
            boundary: [SIMD3(-1.5, 0, -1.25), SIMD3(1.5, 0, -1.25), SIMD3(0, 0, 1.25)]
        )
        return [
            AnchorRecord(frameIndex: 2, anchorID: wall, event: .add, geometry: small),
            AnchorRecord(frameIndex: 5, anchorID: wall, event: .update, geometry: grown),
            AnchorRecord(frameIndex: 6, anchorID: floor, event: .add, geometry: floorShape),
            AnchorRecord(frameIndex: 8, anchorID: wall, event: .remove, geometry: nil),
        ]
    }

    static var locations: [LocationRecord] {
        [
            LocationRecord(
                frameIndex: 3, utc: 1_790_000_000.5, latitude: -12.9765625, longitude: -38.4765625,
                altitude: 52.5, ellipsoidalAltitude: 43.25, horizontalAccuracy: 4.5, verticalAccuracy: 3
            ),
            LocationRecord(
                frameIndex: 8, utc: 1_790_000_001.5, latitude: -12.9765500, longitude: -38.4765500,
                altitude: 52.75, ellipsoidalAltitude: 43.5, horizontalAccuracy: 6, verticalAccuracy: 3.5
            ),
        ]
    }

    static var headings: [HeadingRecord] {
        [
            HeadingRecord(frameIndex: 2, trueHeading: 271.5, magneticHeading: 293.25, accuracy: 12),
            HeadingRecord(frameIndex: 7, trueHeading: -1, magneticHeading: 290, accuracy: 25),
        ]
    }

    static var events: [EventRecord] {
        [
            EventRecord(frameIndex: 0, kind: "record", detail: "start"),
            EventRecord(frameIndex: 1, kind: "tracking", detail: "limited/initializing"),
            EventRecord(frameIndex: 2, kind: "tracking", detail: "normal"),
            EventRecord(frameIndex: 5, kind: "tracking", detail: "limited/excessiveMotion"),
            EventRecord(frameIndex: 6, kind: "mark", detail: "wall A starts here"),
            EventRecord(frameIndex: 9, kind: "record", detail: "stop:user"),
        ]
    }

    /// Two `cloud` rows (schema v2): a full copy after frame 5, then changes after frame 9 that remove one id and set
    /// one kept id plus an id above 2^53 with a sample count above 255.
    static var clouds: [CloudRecord] {
        let a = UInt64(2) << 40
        let b = UInt64(2) << 40 | 1
        let big: UInt64 = 18_000_000_000_000_000_000
        return [
            CloudRecord(
                frameIndex: 5, full: true,
                set: CloudState(ids: [a, b], points: [SIMD3(2, 1.25, -4), SIMD3(2.5, 1.125, -4.125)], samples: [5, 6])
            ),
            CloudRecord(
                frameIndex: 9, full: false, removed: [a],
                set: CloudState(ids: [b, big], points: [SIMD3(2.5, 1.0625, -4.25), SIMD3(9, 1.25, -5.75)], samples: [7, 300])
            ),
        ]
    }

    /// X1's tracks (schema v3): #1 is added tentative after frame 3 and grows confirmed after frame 6; #2 is added
    /// after frame 4 and merges into #1 after frame 7; #1 goes stale after frame 8; #3, a floor, is added after frame 8
    /// and dropped after frame 9. Outlines are rectangles of 4 or 5 vertices.
    static var surfaces: [SurfaceRecord] {
        let first = UUID(uuidString: "C0000000-0000-4000-8000-000000000001")!
        let second = UUID(uuidString: "C0000000-0000-4000-8000-000000000002")!
        let third = UUID(uuidString: "C0000000-0000-4000-8000-000000000003")!
        func wall(_ x0: Float, _ x1: Float, _ y0: Float, _ y1: Float, z: Float) -> [SIMD3<Float>] {
            [SIMD3(x0, y0, z), SIMD3(x1, y0, z), SIMD3(x1, y1, z), SIMD3(x0, y1, z)]
        }
        let small = SurfaceGeometry(
            state: 0, normal: SIMD3(0, 0, 1), center: SIMD3(0.5, 1, -3.5), outline: wall(0, 1, 0.5, 1.5, z: -3.5),
            width: 1, height: 1, rmsError: 0.015625, inliers: 40
        )
        var grown = small
        grown.state = 1
        grown.center = SIMD3(1, 1, -3.5)
        grown.outline = wall(0, 2, 0.5, 1.5, z: -3.5) + [SIMD3(1, 1.75, -3.5)]
        grown.width = 2
        grown.rmsError = 0.0078125
        grown.inliers = 96
        var stale = grown
        stale.state = 2
        let patch = SurfaceGeometry(
            state: 0, normal: SIMD3(0, 0, -1), center: SIMD3(1.75, 1, -3.4375), outline: wall(1.5, 2, 0.75, 1.25, z: -3.4375),
            width: 0.5, height: 0.5, rmsError: 0.03125, inliers: 31
        )
        let floor = SurfaceGeometry(
            state: 0, normal: SIMD3(0, 1, 0), center: SIMD3(0, -1.5, -2),
            outline: [SIMD3(-1, -1.5, -1), SIMD3(1, -1.5, -1), SIMD3(1, -1.5, -3), SIMD3(-1, -1.5, -3)],
            width: 2, height: 2, rmsError: 0.0234375, inliers: 55
        )
        return [
            SurfaceRecord(frameIndex: 3, surfaceID: first, number: 1, event: .add, geometry: small),
            SurfaceRecord(frameIndex: 4, surfaceID: second, number: 2, event: .add, geometry: patch),
            SurfaceRecord(frameIndex: 6, surfaceID: first, number: 1, event: .update, geometry: grown),
            SurfaceRecord(frameIndex: 7, surfaceID: second, number: 2, event: .remove, geometry: nil, mergedInto: first),
            SurfaceRecord(frameIndex: 8, surfaceID: first, number: 1, event: .update, geometry: stale),
            SurfaceRecord(frameIndex: 8, surfaceID: third, number: 3, event: .add, geometry: floor),
            SurfaceRecord(frameIndex: 9, surfaceID: third, number: 3, event: .remove, geometry: nil),
        ]
    }

    /// Three `surface_round` rows (schema v4): a first round that searched, a cheap refit-only round and a third that
    /// searched again while the phone was hot. Milliseconds are dyadic fractions, like every other real.
    static var surfaceRounds: [SurfaceRoundRecord] {
        [
            SurfaceRoundRecord(
                frameIndex: 3, round: 1, points: 120, unclaimed: 120, tracks: 1, confirmed: 0, refits: 0, searched: true,
                planesFound: 2, hypotheses: 96, fullScores: 31, pointTests: 28_000, totalMilliseconds: 12.5,
                refitMilliseconds: 0, searchMilliseconds: 12.25, skipped: 0, thermal: 0
            ),
            SurfaceRoundRecord(
                frameIndex: 6, round: 2, points: 160, unclaimed: 40, tracks: 2, confirmed: 1, refits: 1, searched: false,
                planesFound: 0, hypotheses: 0, fullScores: 0, pointTests: 640, totalMilliseconds: 1.5,
                refitMilliseconds: 1.25, searchMilliseconds: 0, skipped: 1, thermal: 1
            ),
            SurfaceRoundRecord(
                frameIndex: 9, round: 3, points: 3_000_000_000, unclaimed: 900, tracks: 2, confirmed: 2, refits: 2,
                searched: true, planesFound: 1, hypotheses: 40, fullScores: 12, pointTests: 12_000,
                totalMilliseconds: 4.75, refitMilliseconds: 1.5, searchMilliseconds: 3.125, skipped: 2, thermal: 2
            ),
        ]
    }

    /// Writes `tiny.planelab/` (sealed `session.sqlite` + `video.mov`) and `expected.json`.
    static func write(bundle: URL, expected: URL) async throws {
        let manager = FileManager.default
        try? manager.removeItem(at: bundle)
        try manager.createDirectory(at: bundle, withIntermediateDirectories: true)

        let db = try SessionDatabase.create(at: bundle.appendingPathComponent("session.sqlite"), meta: meta)
        try db.transaction {
            for f in frames { try db.insert(f) }
            for a in anchors { try db.insert(a) }
            for l in locations { try db.insert(l) }
            for h in headings { try db.insert(h) }
            for e in events { try db.insert(e) }
            for c in clouds { try db.insert(c) }
            for s in surfaces { try db.insert(s) }
            for r in surfaceRounds { try db.insert(r) }
        }
        try db.seal()

        let video = try VideoWriter(
            url: bundle.appendingPathComponent("video.mov"), width: width, height: height, realTime: false
        )
        for frame in frames where frame.hasImage {
            let buffer = try await waitForBuffer(video)
            TestFrames.draw(frame.index, into: buffer)
            try await waitUntilReady(video)
            #expect(video.append(buffer, frameIndex: frame.index) == .appended)
        }
        try await video.finish()

        let reopened = try SessionDatabase.open(at: bundle.appendingPathComponent("session.sqlite"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(try ExpectedSession(reopened)).write(to: expected)
    }
}

/// `expected.json`: every table as rows named like its SQL columns, so any language can compare row by row.
/// Matrices are flat column-major float lists, as in the BLOBs.
struct ExpectedSession: Codable, Equatable {
    var meta: [String: String]
    var frame: [FrameRow]
    var plane_anchor: [AnchorRow]
    var location: [LocationRow]
    var heading: [HeadingRow]
    var event: [EventRow]
    /// Absent from version 1 files, which have no `cloud` table.
    var cloud: [CloudRow]?
    /// Absent before version 3, which adds the `surface` table.
    var surface: [SurfaceRow]?
    /// Absent before version 4, which adds the `surface_round` table.
    var surface_round: [SurfaceRoundRow]?

    struct FrameRow: Codable, Equatable {
        var idx: Int
        var t: Double
        var has_image: Int
        var tracking: Int
        var tracking_reason: Int
        var mapping: Int
        var camera: [Float]
        var intrinsics: [Float]
        var exposure_s: Double
        var thermal: Int
        var point_count: Int
        var points: [[Float]]
        var point_ids: [UInt64]
    }

    struct AnchorRow: Codable, Equatable {
        var frame_idx: Int
        var anchor_id: String
        var event: Int
        var alignment: Int?
        var classification: Int?
        var transform: [Float]?
        var center: [Float]?
        var extent: [Float]?
        var boundary: [[Float]]?
    }

    struct LocationRow: Codable, Equatable {
        var frame_idx: Int
        var utc: Double
        var lat: Double
        var lon: Double
        var alt_m: Double
        var ellipsoidal_alt_m: Double
        var h_acc_m: Double
        var v_acc_m: Double
    }

    struct HeadingRow: Codable, Equatable {
        var frame_idx: Int
        var true_deg: Double
        var magnetic_deg: Double
        var acc_deg: Double
    }

    struct EventRow: Codable, Equatable {
        var frame_idx: Int
        var kind: String
        var detail: String
    }

    struct CloudRow: Codable, Equatable {
        var frame_idx: Int
        var full: Int
        var removed_ids: [UInt64]
        var ids: [UInt64]
        var points: [[Float]]
        var samples: [UInt16]
    }

    struct SurfaceRow: Codable, Equatable {
        var frame_idx: Int
        var surface_id: String
        var number: Int
        var event: Int
        var state: Int?
        var normal: [Float]?
        var center: [Float]?
        var outline: [[Float]]?
        var width_m: Double?
        var height_m: Double?
        var rms_m: Double?
        var inliers: Int?
        var merged_into: String?
    }

    struct SurfaceRoundRow: Codable, Equatable {
        var frame_idx: Int
        var round: Int
        var points: Int
        var unclaimed: Int
        var tracks: Int
        var confirmed: Int
        var refits: Int
        var searched: Int
        var planes_found: Int
        var hypotheses: Int
        var full_scores: Int
        var point_tests: Int
        var total_ms: Double
        var refit_ms: Double
        var search_ms: Double
        var skipped: Int
        var thermal: Int
    }

    init(_ db: SessionDatabase) throws {
        meta = try db.meta()
        frame = try db.frames().map { f in
            FrameRow(
                idx: f.index, t: f.timestamp, has_image: f.hasImage ? 1 : 0, tracking: f.tracking.rawValue,
                tracking_reason: f.trackingReason.rawValue, mapping: f.mapping, camera: Self.flat(f.camera),
                intrinsics: Self.flat(f.intrinsics), exposure_s: f.exposure, thermal: f.thermal,
                point_count: f.points.count, points: f.points.map(Self.list), point_ids: f.pointIDs
            )
        }
        plane_anchor = try db.anchors().map { a in
            AnchorRow(
                frame_idx: a.frameIndex, anchor_id: a.anchorID.uuidString, event: a.event.rawValue,
                alignment: a.geometry?.alignment, classification: a.geometry?.classification,
                transform: a.geometry.map { Self.flat($0.transform) }, center: a.geometry.map { Self.list($0.center) },
                extent: a.geometry.map { Self.list($0.extent) }, boundary: a.geometry.map { $0.boundary.map(Self.list) }
            )
        }
        location = try db.locations().map { l in
            LocationRow(
                frame_idx: l.frameIndex, utc: l.utc, lat: l.latitude, lon: l.longitude, alt_m: l.altitude,
                ellipsoidal_alt_m: l.ellipsoidalAltitude, h_acc_m: l.horizontalAccuracy, v_acc_m: l.verticalAccuracy
            )
        }
        heading = try db.headings().map { h in
            HeadingRow(frame_idx: h.frameIndex, true_deg: h.trueHeading, magnetic_deg: h.magneticHeading, acc_deg: h.accuracy)
        }
        event = try db.events().map { EventRow(frame_idx: $0.frameIndex, kind: $0.kind, detail: $0.detail) }
        cloud = db.schemaVersion >= 2 ? try db.clouds().map { c in
            CloudRow(
                frame_idx: c.frameIndex, full: c.full ? 1 : 0, removed_ids: c.removed, ids: c.set.ids,
                points: c.set.points.map(Self.list), samples: c.set.samples
            )
        } : nil
        surface = db.schemaVersion >= 3 ? try db.surfaces().map { s in
            SurfaceRow(
                frame_idx: s.frameIndex, surface_id: s.surfaceID.uuidString, number: s.number, event: s.event.rawValue,
                state: s.geometry?.state, normal: s.geometry.map { Self.list($0.normal) },
                center: s.geometry.map { Self.list($0.center) }, outline: s.geometry.map { $0.outline.map(Self.list) },
                width_m: s.geometry.map { Double($0.width) }, height_m: s.geometry.map { Double($0.height) },
                rms_m: s.geometry.map { Double($0.rmsError) }, inliers: s.geometry?.inliers,
                merged_into: s.mergedInto?.uuidString
            )
        } : nil
        surface_round = db.schemaVersion >= 4 ? try db.surfaceRounds().map { r in
            SurfaceRoundRow(
                frame_idx: r.frameIndex, round: r.round, points: r.points, unclaimed: r.unclaimed, tracks: r.tracks,
                confirmed: r.confirmed, refits: r.refits, searched: r.searched ? 1 : 0, planes_found: r.planesFound,
                hypotheses: r.hypotheses, full_scores: r.fullScores, point_tests: r.pointTests,
                total_ms: r.totalMilliseconds, refit_ms: r.refitMilliseconds, search_ms: r.searchMilliseconds,
                skipped: r.skipped, thermal: r.thermal
            )
        } : nil
    }

    private static func list(_ v: SIMD3<Float>) -> [Float] { [v.x, v.y, v.z] }

    private static func flat(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    private static func flat(_ m: simd_float3x3) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2].flatMap(list)
    }
}
