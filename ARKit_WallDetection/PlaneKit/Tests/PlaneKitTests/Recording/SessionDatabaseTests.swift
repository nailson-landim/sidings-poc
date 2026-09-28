import Foundation
import SQLite3
import Testing
@testable import PlaneKit

@Suite("Session database")
struct SessionDatabaseTests {
    @Test func everyTableRoundTrips() throws {
        let folder = TempFolder()
        let url = folder.file("session.sqlite")
        let fixture = ContractFixture.records
        let db = try SessionDatabase.create(at: url, meta: [("device_model", "test")])
        try db.transaction {
            for f in fixture.frames { try db.insert(f) }
            for a in fixture.anchors { try db.insert(a) }
            for l in fixture.locations { try db.insert(l) }
            for h in fixture.headings { try db.insert(h) }
            for e in fixture.events { try db.insert(e) }
        }
        try db.seal()

        let read = try SessionDatabase.open(at: url)
        #expect(try read.meta() == ["schema_version": "1", "device_model": "test"])
        #expect(try read.frames() == fixture.frames)
        #expect(try read.anchors() == fixture.anchors)
        #expect(try read.locations() == fixture.locations)
        #expect(try read.headings() == fixture.headings)
        #expect(try read.events() == fixture.events)
    }

    @Test func sealedDatabaseIsOneFile() throws {
        let folder = TempFolder()
        let url = folder.file("session.sqlite")
        let db = try SessionDatabase.create(at: url)
        try db.insert(ContractFixture.records.frames[1])
        try db.seal()
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        #expect(files == ["session.sqlite"])
    }

    @Test func frameWithoutPointsStoresEmptyBlobs() throws {
        let folder = TempFolder()
        let url = folder.file("session.sqlite")
        let db = try SessionDatabase.create(at: url)
        let empty = ContractFixture.records.frames[0]
        #expect(empty.points.isEmpty)
        try db.insert(empty)
        #expect(try db.frames() == [empty])
        db.close()
        // Stored as zero-length BLOBs, not NULL, so readers can always frombuffer() them.
        #expect(try scalar(url, "SELECT typeof(points) || typeof(point_ids) FROM frame") == "blobblob")
    }

    /// SPEC §3.3 and T11: a remove carries only the anchor id, even when the caller passes a shape.
    @Test func removeRowCarriesOnlyTheID() throws {
        let folder = TempFolder()
        let url = folder.file("session.sqlite")
        let added = ContractFixture.records.anchors[0]
        let removed = AnchorRecord(frameIndex: 9, anchorID: added.anchorID, event: .remove, geometry: added.geometry)
        #expect(removed.geometry == nil)
        let db = try SessionDatabase.create(at: url)
        try db.insert(added)
        try db.insert(removed)
        #expect(try db.anchors() == [added, removed])
        db.close()
        #expect(try scalar(url, "SELECT typeof(transform) || typeof(boundary) || typeof(alignment) FROM plane_anchor WHERE event = 2") == "nullnullnull")
    }

    @Test func mismatchedPointsAndIDsAreRefused() throws {
        let folder = TempFolder()
        let db = try SessionDatabase.create(at: folder.file("session.sqlite"))
        var frame = ContractFixture.records.frames[2]
        frame.pointIDs.removeLast()
        #expect(throws: SessionDatabaseError.self) { try db.insert(frame) }
    }

    @Test func unknownSchemaVersionIsRefused() throws {
        let folder = TempFolder()
        let url = folder.file("session.sqlite")
        let db = try SessionDatabase.create(at: url)
        try db.setMeta("schema_version", "2")
        db.close()
        #expect(throws: SessionDatabaseError.unsupportedVersion(found: "2", supported: 1)) {
            try SessionDatabase.open(at: url)
        }
    }

    @Test func createRefusesAnExistingFile() throws {
        let folder = TempFolder()
        let url = folder.file("session.sqlite")
        _ = try SessionDatabase.create(at: url)
        #expect(throws: SessionDatabaseError.self) { try SessionDatabase.create(at: url) }
    }

    /// Reads one value with the raw SQLite API, independent of `SessionDatabase`.
    private func scalar(_ url: URL, _ sql: String) throws -> String {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return "" }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return "" }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return "" }
        return String(cString: text)
    }
}
