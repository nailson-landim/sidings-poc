import Foundation
import SQLite3
import simd

/// Schema version 1 of `session.sqlite` (SPEC §3.3).
public enum SessionSchema {
    public static let version = 1

    /// A copy of `session-format/schema_v1.sql`; `ContractTests` checks it matches the file exactly (SPEC §17.4 P2).
    public static let ddl = """
    -- Plane Lab session format, schema version 1 (SPEC.md §3.3).
    -- The one source of the DDL (SPEC.md §17.4 P2). Swift (SessionSchema.ddl) and Python (planelab.schema.DDL)
    -- embed copies, and a test on each side checks the copy matches this file exactly.
    -- Conventions: SPEC.md §3.2. BLOBs are little-endian float32 / uint64, packed with no padding.

    CREATE TABLE meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );

    CREATE TABLE frame (
        idx             INTEGER PRIMARY KEY,
        t               REAL    NOT NULL,
        has_image       INTEGER NOT NULL,
        tracking        INTEGER NOT NULL,
        tracking_reason INTEGER NOT NULL,
        mapping         INTEGER NOT NULL,
        camera          BLOB    NOT NULL,
        intrinsics      BLOB    NOT NULL,
        exposure_s      REAL    NOT NULL,
        thermal         INTEGER NOT NULL,
        point_count     INTEGER NOT NULL,
        points          BLOB    NOT NULL,
        point_ids       BLOB    NOT NULL
    );

    CREATE TABLE plane_anchor (
        frame_idx      INTEGER NOT NULL,
        anchor_id      TEXT    NOT NULL,
        event          INTEGER NOT NULL,
        alignment      INTEGER,
        classification INTEGER,
        transform      BLOB,
        center         BLOB,
        extent         BLOB,
        boundary       BLOB
    );

    CREATE INDEX plane_anchor_frame ON plane_anchor (frame_idx);

    CREATE TABLE location (
        frame_idx         INTEGER NOT NULL,
        utc               REAL    NOT NULL,
        lat               REAL    NOT NULL,
        lon               REAL    NOT NULL,
        alt_m             REAL    NOT NULL,
        ellipsoidal_alt_m REAL    NOT NULL,
        h_acc_m           REAL    NOT NULL,
        v_acc_m           REAL    NOT NULL
    );

    CREATE TABLE heading (
        frame_idx    INTEGER NOT NULL,
        true_deg     REAL    NOT NULL,
        magnetic_deg REAL    NOT NULL,
        acc_deg      REAL    NOT NULL
    );

    CREATE TABLE event (
        frame_idx INTEGER NOT NULL,
        kind      TEXT    NOT NULL,
        detail    TEXT    NOT NULL
    );

    """
}

public enum SessionDatabaseError: Error, Equatable {
    case cannotOpen(String)
    case sqlite(String)
    /// `schema_version` is missing or isn't one this reader knows.
    case unsupportedVersion(found: String?, supported: Int)
    case corruptRow(String)
}

/// A `session.sqlite`, read and written synchronously. While recording it's in WAL mode; `seal()` folds the WAL back
/// in, so a finished session is one self-contained file.
///
/// Not thread-safe: use one instance from one queue (the session writer's).
public final class SessionDatabase {
    public let url: URL
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    private init(url: URL, handle: OpaquePointer) {
        self.url = url
        self.handle = handle
    }

    deinit { close() }

    /// Creates a new database with the schema, `schema_version` and the given `meta` rows. Fails if the file exists.
    public static func create(at url: URL, meta: [(key: String, value: String)] = []) throws -> SessionDatabase {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw SessionDatabaseError.cannotOpen("\(url.lastPathComponent) already exists")
        }
        let db = try connect(url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        try db.execute("PRAGMA journal_mode=WAL")
        try db.execute("PRAGMA synchronous=NORMAL")
        try db.execute(SessionSchema.ddl)
        try db.transaction {
            try db.setMeta("schema_version", "\(SessionSchema.version)")
            for row in meta { try db.setMeta(row.key, row.value) }
        }
        return db
    }

    /// Opens an existing database and refuses a schema version it doesn't know.
    public static func open(at url: URL, readOnly: Bool = true) throws -> SessionDatabase {
        let db = try connect(url, flags: readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE)
        let version = try db.meta()["schema_version"]
        guard version == "\(SessionSchema.version)" else {
            throw SessionDatabaseError.unsupportedVersion(found: version, supported: SessionSchema.version)
        }
        return db
    }

    public func close() {
        for statement in statements.values { sqlite3_finalize(statement) }
        statements.removeAll()
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    /// Folds the WAL into the main file, leaves WAL mode and closes, so the session is one self-contained file.
    /// SQLite leaves the old `-shm` file behind after the mode switch; with no connection open it's safe to remove.
    public func seal() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try execute("PRAGMA journal_mode=DELETE")
        close()
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    public func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: Writing

    public func setMeta(_ key: String, _ value: String) throws {
        try run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [.text(key), .text(value)])
    }

    public func insert(_ frame: FrameRecord) throws {
        guard frame.points.count == frame.pointIDs.count else {
            throw SessionDatabaseError.corruptRow("frame \(frame.index): \(frame.points.count) points, \(frame.pointIDs.count) ids")
        }
        try run(
            "INSERT INTO frame VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                .int(frame.index), .real(frame.timestamp), .int(frame.hasImage ? 1 : 0),
                .int(frame.tracking.rawValue), .int(frame.trackingReason.rawValue), .int(frame.mapping),
                .blob(Packing.pack(frame.camera)), .blob(Packing.pack(frame.intrinsics)),
                .real(frame.exposure), .int(frame.thermal), .int(frame.points.count),
                .blob(Packing.pack(frame.points)), .blob(Packing.pack(frame.pointIDs)),
            ]
        )
    }

    public func insert(_ anchor: AnchorRecord) throws {
        var values: [Value] = [.int(anchor.frameIndex), .text(anchor.anchorID.uuidString), .int(anchor.event.rawValue)]
        if let g = anchor.geometry {
            values.append(.int(g.alignment))
            values.append(.int(g.classification))
            values.append(.blob(Packing.pack(g.transform)))
            values.append(.blob(Packing.pack(g.center)))
            values.append(.blob(Packing.pack(g.extent)))
            values.append(.blob(Packing.pack(g.boundary)))
        } else {
            values.append(contentsOf: [Value](repeating: .null, count: 6))
        }
        try run("INSERT INTO plane_anchor VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", values)
    }

    public func insert(_ location: LocationRecord) throws {
        try run(
            "INSERT INTO location VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [
                .int(location.frameIndex), .real(location.utc), .real(location.latitude), .real(location.longitude),
                .real(location.altitude), .real(location.ellipsoidalAltitude),
                .real(location.horizontalAccuracy), .real(location.verticalAccuracy),
            ]
        )
    }

    public func insert(_ heading: HeadingRecord) throws {
        try run(
            "INSERT INTO heading VALUES (?, ?, ?, ?)",
            [.int(heading.frameIndex), .real(heading.trueHeading), .real(heading.magneticHeading), .real(heading.accuracy)]
        )
    }

    public func insert(_ event: EventRecord) throws {
        try run("INSERT INTO event VALUES (?, ?, ?)", [.int(event.frameIndex), .text(event.kind), .text(event.detail)])
    }

    // MARK: Reading

    public func meta() throws -> [String: String] {
        let rows = try query("SELECT key, value FROM meta") { ($0.text(0), $0.text(1)) }
        return Dictionary(rows, uniquingKeysWith: { _, last in last })
    }

    public func frames() throws -> [FrameRecord] {
        try query("SELECT * FROM frame ORDER BY idx") { row in
            let index = row.int(0)
            guard let tracking = TrackingCode(rawValue: row.int(3)),
                  let reason = TrackingReason(rawValue: row.int(4)),
                  let camera = Packing.matrix4(row.blob(6)),
                  let intrinsics = Packing.matrix3(row.blob(7)),
                  let points = Packing.points(row.blob(11)),
                  let ids = Packing.ids(row.blob(12)),
                  points.count == row.int(10), ids.count == points.count
            else { throw SessionDatabaseError.corruptRow("frame \(index)") }
            return FrameRecord(
                index: index, timestamp: row.real(1), hasImage: row.int(2) != 0, tracking: tracking,
                trackingReason: reason, mapping: row.int(5), camera: camera, intrinsics: intrinsics,
                exposure: row.real(8), thermal: row.int(9), points: points, pointIDs: ids
            )
        }
    }

    public func anchors() throws -> [AnchorRecord] {
        try query("SELECT * FROM plane_anchor ORDER BY rowid") { row in
            guard let id = UUID(uuidString: row.text(1)), let event = AnchorEvent(rawValue: row.int(2)) else {
                throw SessionDatabaseError.corruptRow("plane_anchor at frame \(row.int(0))")
            }
            var geometry: AnchorGeometry?
            if event != .remove {
                guard let transform = Packing.matrix4(row.blob(5)),
                      let center = Packing.vector3(row.blob(6)),
                      let extent = Packing.vector3(row.blob(7)),
                      let boundary = Packing.points(row.blob(8))
                else { throw SessionDatabaseError.corruptRow("plane_anchor \(id) at frame \(row.int(0))") }
                geometry = AnchorGeometry(
                    alignment: row.int(3), classification: row.int(4), transform: transform,
                    center: center, extent: extent, boundary: boundary
                )
            }
            return AnchorRecord(frameIndex: row.int(0), anchorID: id, event: event, geometry: geometry)
        }
    }

    public func locations() throws -> [LocationRecord] {
        try query("SELECT * FROM location ORDER BY rowid") { row in
            LocationRecord(
                frameIndex: row.int(0), utc: row.real(1), latitude: row.real(2), longitude: row.real(3),
                altitude: row.real(4), ellipsoidalAltitude: row.real(5),
                horizontalAccuracy: row.real(6), verticalAccuracy: row.real(7)
            )
        }
    }

    public func headings() throws -> [HeadingRecord] {
        try query("SELECT * FROM heading ORDER BY rowid") { row in
            HeadingRecord(
                frameIndex: row.int(0), trueHeading: row.real(1), magneticHeading: row.real(2), accuracy: row.real(3)
            )
        }
    }

    public func events() throws -> [EventRecord] {
        try query("SELECT * FROM event ORDER BY rowid") { row in
            EventRecord(frameIndex: row.int(0), kind: row.text(1), detail: row.text(2))
        }
    }

    // MARK: SQLite plumbing

    private enum Value {
        case int(Int)
        case real(Double)
        case text(String)
        case blob(Data)
        case null
    }

    /// A result row; valid only inside the `query` closure.
    private struct Row {
        let statement: OpaquePointer

        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
        func real(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        func blob(_ column: Int32) -> Data {
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: count)
        }
    }

    /// `SQLITE_TRANSIENT`: SQLite copies the bound bytes before the call returns.
    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    private static func connect(_ url: URL, flags: Int32) throws -> SessionDatabase {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(status)"
            if let handle { sqlite3_close_v2(handle) }
            throw SessionDatabaseError.cannotOpen("\(url.lastPathComponent): \(message)")
        }
        sqlite3_busy_timeout(handle, 2000)
        return SessionDatabase(url: url, handle: handle)
    }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
    }

    private func execute(_ sql: String) throws {
        guard let handle else { throw SessionDatabaseError.sqlite("database is closed") }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SessionDatabaseError.sqlite(errorMessage)
        }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let statement = statements[sql] {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            return statement
        }
        guard let handle else { throw SessionDatabaseError.sqlite("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SessionDatabaseError.sqlite(errorMessage)
        }
        statements[sql] = statement
        return statement
    }

    private func bind(_ values: [Value], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .int(let v): status = sqlite3_bind_int64(statement, index, Int64(v))
            case .real(let v): status = sqlite3_bind_double(statement, index, v)
            case .text(let v): status = sqlite3_bind_text(statement, index, v, -1, Self.transient)
            case .null: status = sqlite3_bind_null(statement, index)
            case .blob(let v) where v.isEmpty:
                // A nil pointer would bind NULL; an empty point list is an empty BLOB.
                status = sqlite3_bind_zeroblob(statement, index, 0)
            case .blob(let v):
                status = v.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient)
                }
            }
            guard status == SQLITE_OK else { throw SessionDatabaseError.sqlite(errorMessage) }
        }
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        let statement = try prepared(sql)
        try bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SessionDatabaseError.sqlite(errorMessage) }
    }

    private func query<T>(_ sql: String, _ map: (Row) throws -> T) throws -> [T] {
        let statement = try prepared(sql)
        var result: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw SessionDatabaseError.sqlite(errorMessage) }
            result.append(try map(Row(statement: statement)))
        }
        return result
    }
}
