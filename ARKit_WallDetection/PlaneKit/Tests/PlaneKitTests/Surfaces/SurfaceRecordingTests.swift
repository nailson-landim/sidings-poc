import Foundation
import simd
import Testing
@testable import PlaneKit

@Suite("X1 recording: surface rows")
struct SurfaceRecordingTests {
    static func track(_ number: Int, version: Int = 1, state: TrackedSurface.State = .tentative) -> TrackedSurface {
        TrackedSurface(
            id: UUID(uuidString: String(format: "D0000000-0000-4000-8000-%012d", number))!, number: number,
            state: state, normal: SIMD3(0, 0, 1), center: SIMD3(Float(number), 0, -3),
            outline: [SIMD3(0, 0, -3), SIMD3(1, 0, -3), SIMD3(1, 1, -3)], width: 1, height: 1, rmsError: 0.01,
            inlierIDs: [1, 2, 3], hits: 1, misses: 0, lastMatchRound: 1, version: version
        )
    }

    @Test func aTrackIsAddedThenUpdatedOnlyWhenItsVersionMoves() {
        var log = SurfaceLog()
        let a = Self.track(1)
        let added = log.rows(frameIndex: 5, surfaces: [a], events: [.add(a.id)])
        #expect(added.map(\.event) == [.add])
        #expect(added[0].frameIndex == 5 && added[0].number == 1)
        #expect(added[0].geometry == SurfaceGeometry(a))
        #expect(log.rows(frameIndex: 6, surfaces: [a], events: []).isEmpty)
        let moved = Self.track(1, version: 2, state: .confirmed)
        let updated = log.rows(frameIndex: 7, surfaces: [moved], events: [.update(a.id)])
        #expect(updated.map(\.event) == [.update])
        #expect(updated[0].geometry?.state == 1)
        #expect(log.rowCount == 2)
    }

    @Test func goneTracksAreRemovedNamingTheSurvivorOfAMerge() {
        var log = SurfaceLog()
        let older = Self.track(1)
        let younger = Self.track(2)
        let dropped = Self.track(3)
        _ = log.rows(frameIndex: 1, surfaces: [older, younger, dropped], events: [])
        let survivor = Self.track(1, version: 2)
        let rows = log.rows(
            frameIndex: 2, surfaces: [survivor],
            events: [.merge(survivor: older.id, absorbed: younger.id), .drop(dropped.id)]
        )
        #expect(rows.map(\.event) == [.update, .remove, .remove])
        #expect(rows[1].surfaceID == younger.id && rows[1].mergedInto == older.id && rows[1].geometry == nil)
        #expect(rows[2].surfaceID == dropped.id && rows[2].mergedInto == nil && rows[2].number == 3)
        #expect(log.rows(frameIndex: 3, surfaces: [survivor], events: []).isEmpty)
    }

    @Test func settingsBecomeMetaRows() {
        let rows = Dictionary(uniqueKeysWithValues: SurfaceSettings().metaRows.map { ($0.key, $0.value) })
        #expect(rows["x1.measurementAccuracy"] == "0.1")
        #expect(rows["x1.lateralExtension"] == "7" && rows["x1.meanDistance"] == "1.0" && rows["x1.mergeGap"] == "0.5")
        #expect(rows["x1.roundInterval"] == "0.25")
        #expect(rows.count == Mirror(reflecting: SurfaceSettings()).children.count)
    }

    /// The real path: `LiveSurfaces` rounds on a corner scene, rows through `SessionWriter`, read back from SQLite.
    /// Replaying the rows gives exactly the tracks the phone ended with.
    @Test func recordedRowsReplayToTheFinalTracks() async throws {
        let folder = TempFolder()
        let writer = try SessionWriter(bundle: folder.url, meta: [], videoSize: nil, autoCommit: false)
        let live = LiveSurfaces(settings: SurfaceSettings(), fitter: ReferenceFitter(band: 0.06))
        live.startRecording { row in writer.enqueue(row) }
        var rng = SplitMix64(state: 9)
        let scene = SyntheticScene.corner()
        for round in 0..<6 {
            let index = writer.enqueue(SessionWriterTests.frame, image: nil)
            #expect(index == round)
            live.submit(cloud: scene.cloud(noise: 0.02, rng: &rng), camera: camera(), recordIndex: index)
            live.drain()
        }
        let summary = live.stopRecording()
        let final = live.latest().surfaces
        // Rounds after Stop write nothing.
        live.submit(cloud: scene.cloud(noise: 0.02, rng: &rng), camera: camera(), recordIndex: 99)
        live.drain()
        _ = try await writer.finish(stopReason: .user, meta: summary.metaRows)

        let db = try SessionDatabase.open(at: folder.file("session.sqlite"))
        let rows = try db.surfaces()
        #expect(rows.count == summary.rows)
        #expect(summary.tracks == 2 && summary.confirmed == 2)
        #expect(try db.meta()["x1_confirmed"] == "2")
        #expect(rows.filter { $0.event == .add }.map(\.frameIndex) == [0, 0])
        #expect(rows.allSatisfy { $0.frameIndex <= 5 })

        var replayed: [UUID: SurfaceGeometry] = [:]
        for row in rows {
            replayed[row.surfaceID] = row.event == .remove ? nil : row.geometry
        }
        #expect(replayed == Dictionary(uniqueKeysWithValues: final.map { ($0.id, SurfaceGeometry($0)) }))
    }

    @Test func startRecordingForgetsEarlierTracks() {
        let live = LiveSurfaces(settings: SurfaceSettings(), fitter: ReferenceFitter(band: 0.06))
        var rng = SplitMix64(state: 2)
        live.submit(cloud: SyntheticScene.corner().cloud(noise: 0.02, rng: &rng), camera: camera())
        live.drain()
        #expect(!live.latest().surfaces.isEmpty)
        live.startRecording { _ in }
        live.drain()
        #expect(live.latest().surfaces.isEmpty)
        #expect(live.stopRecording() == LiveSurfaces.RecordingSummary())
    }
}
