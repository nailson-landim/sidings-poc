import Foundation
import SQLite3
import simd

/// Schema version 4 of `session.sqlite` (SPEC §3.3): version 1, plus the `cloud` table (v2: L12, P23), plus the
/// `surface` table (v3: the phone's tracked planes, `../EXPERIMENTS.md` XD6), plus the `surface_round` table (v4: what
/// each round cost, XD16).
public enum SessionSchema {
    public static let version = 4
    /// Versions `SessionDatabase.open` reads. Version 1 files have no `cloud` table; versions 1 and 2 no `surface`;
    /// versions 1 to 3 no `surface_round`.
    public static let readable: Set<Int> = [1, 2, 3, 4]

    /// A copy of `session-format/schema_v4.sql`; `ContractTests` checks it matches the file exactly (SPEC §17.4 P2).
    public static let ddl = """
    -- Plane Lab session format, schema version 4 (SPEC.md §3.3).
    -- The one source of the DDL (SPEC.md §17.4 P2). Swift (SessionSchema.ddl) and Python (planelab.schema.DDL)
    -- embed copies, and a test on each side checks the copy matches this file exactly.
    -- Conventions: SPEC.md §3.2. BLOBs are little-endian float32 / uint64 / uint16, packed with no padding.
    -- Version 2 adds the cloud table (SPEC.md L12, P23); version 3 adds the surface table (EXPERIMENTS.md X1, XD6);
    -- version 4 adds the surface_round table (EXPERIMENTS.md X2, XD16).
    -- Readers still open versions 1 to 3, which lack the tables added after them.

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

    -- The phone's averaged cloud (CurvSurf's accumulator), every cloudSnapshotEvery recorded frames and at Stop.
    -- full = 1: the whole cloud after frame_idx. full = 0: the changes since the previous row: remove removed_ids,
    -- then set every id in ids to its point and sample count.
    CREATE TABLE cloud (
        frame_idx   INTEGER PRIMARY KEY,
        full        INTEGER NOT NULL,
        removed_ids BLOB    NOT NULL,
        ids         BLOB    NOT NULL,
        points      BLOB    NOT NULL,
        samples     BLOB    NOT NULL
    );

    -- Planes tracked on the phone (meta surface_engine: findsurface or ransac). One row per track that changed in a
    -- round, stamped with the last recorded frame when the round started. event: 0 add, 1 update, 2 remove. state:
    -- 0 tentative, 1 confirmed, 2 stale. normal and center are 3 float32 and outline is N x 3 float32 (the convex hull of
    -- the inliers on the plane), all ARKit world. A remove row carries only the id and number, plus merged_into when the
    -- track merged into an older one (NULL when a tentative track was dropped).
    CREATE TABLE surface (
        frame_idx   INTEGER NOT NULL,
        surface_id  TEXT    NOT NULL,
        number      INTEGER NOT NULL,
        event       INTEGER NOT NULL,
        state       INTEGER,
        normal      BLOB,
        center      BLOB,
        outline     BLOB,
        width_m     REAL,
        height_m    REAL,
        rms_m       REAL,
        inliers     INTEGER,
        merged_into TEXT
    );

    CREATE INDEX surface_frame ON surface (frame_idx);

    -- Experiment X2 (EXPERIMENTS.md XD16): one row per round of the phone's plane engine, with what the round cost.
    -- frame_idx is the last recorded frame when the round started, like surface rows. total_ms is the whole round; refit_ms
    -- and search_ms are its stages (search_ms is 0 when no discovery ran, searched = 0). points is the cloud's size and
    -- unclaimed the points no track held when discovery started. hypotheses, full_scores and point_tests count the search's
    -- work (full_scores are the hypotheses scored on the whole cloud). skipped is the running count of rounds not started
    -- because the previous one was still running. thermal is ProcessInfo.ThermalState (0 nominal, 1 fair, 2 serious,
    -- 3 critical) when the round ran.
    CREATE TABLE surface_round (
        frame_idx    INTEGER NOT NULL,
        round        INTEGER NOT NULL,
        points       INTEGER NOT NULL,
        unclaimed    INTEGER NOT NULL,
        tracks       INTEGER NOT NULL,
        confirmed    INTEGER NOT NULL,
        refits       INTEGER NOT NULL,
        searched     INTEGER NOT NULL,
        planes_found INTEGER NOT NULL,
        hypotheses   INTEGER NOT NULL,
        full_scores  INTEGER NOT NULL,
        point_tests  INTEGER NOT NULL,
        total_ms     REAL    NOT NULL,
        refit_ms     REAL    NOT NULL,
        search_ms    REAL    NOT NULL,
        skipped      INTEGER NOT NULL,
        thermal      INTEGER NOT NULL
    );

    CREATE INDEX surface_round_frame ON surface_round (frame_idx);

    """
}

public enum SessionDatabaseError: Error, Equatable {
    case cannotOpen(String)
    case sqlite(String)
    /// `schema_version` is missing or isn't one this reader knows.
    case unsupportedVersion(found: String?, supported: [Int])
    case corruptRow(String)
}

/// A `session.sqlite`, read and written synchronously. While recording it's in WAL mode; `seal()` folds the WAL back
/// in, so a finished session is one self-contained file.
///
/// Not thread-safe: use one instance from one queue (the session writer's).
public final class SessionDatabase {
    public let url: URL
    /// `meta.schema_version` of the file.
    public private(set) var schemaVersion = SessionSchema.version
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
        guard let number = version.flatMap(Int.init), SessionSchema.readable.contains(number) else {
            throw SessionDatabaseError.unsupportedVersion(found: version, supported: SessionSchema.readable.sorted())
        }
        db.schemaVersion = number
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

    public func insert(_ cloud: CloudRecord) throws {
        guard cloud.set.points.count == cloud.set.ids.count, cloud.set.samples.count == cloud.set.ids.count else {
            throw SessionDatabaseError.corruptRow("cloud \(cloud.frameIndex): ids, points and samples differ in length")
        }
        try run(
            "INSERT INTO cloud VALUES (?, ?, ?, ?, ?, ?)",
            [
                .int(cloud.frameIndex), .int(cloud.full ? 1 : 0), .blob(Packing.pack(cloud.removed)),
                .blob(Packing.pack(cloud.set.ids)), .blob(Packing.pack(cloud.set.points)),
                .blob(Packing.pack(cloud.set.samples)),
            ]
        )
    }

    public func insert(_ surface: SurfaceRecord) throws {
        var values: [Value] = [
            .int(surface.frameIndex), .text(surface.surfaceID.uuidString), .int(surface.number),
            .int(surface.event.rawValue),
        ]
        if let g = surface.geometry {
            values += [
                .int(g.state), .blob(Packing.pack(g.normal)), .blob(Packing.pack(g.center)),
                .blob(Packing.pack(g.outline)), .real(Double(g.width)), .real(Double(g.height)),
                .real(Double(g.rmsError)), .int(g.inliers),
            ]
        } else {
            values += [Value](repeating: .null, count: 8)
        }
        values.append(surface.mergedInto.map { .text($0.uuidString) } ?? .null)
        try run("INSERT INTO surface VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", values)
    }

    public func insert(_ round: SurfaceRoundRecord) throws {
        try run(
            "INSERT INTO surface_round VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                .int(round.frameIndex), .int(round.round), .int(round.points), .int(round.unclaimed),
                .int(round.tracks), .int(round.confirmed), .int(round.refits), .int(round.searched ? 1 : 0),
                .int(round.planesFound), .int(round.hypotheses), .int(round.fullScores), .int(round.pointTests),
                .real(round.totalMilliseconds), .real(round.refitMilliseconds), .real(round.searchMilliseconds),
                .int(round.skipped), .int(round.thermal),
            ]
        )
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

    /// The phone's averaged cloud rows, by frame. Empty for a version 1 file.
    public func clouds() throws -> [CloudRecord] {
        guard schemaVersion >= 2 else { return [] }
        return try query("SELECT * FROM cloud ORDER BY frame_idx") { row in
            guard let removed = Packing.ids(row.blob(2)),
                  let ids = Packing.ids(row.blob(3)),
                  let points = Packing.points(row.blob(4)),
                  let samples = Packing.samples(row.blob(5)),
                  points.count == ids.count, samples.count == ids.count
            else { throw SessionDatabaseError.corruptRow("cloud \(row.int(0))") }
            return CloudRecord(
                frameIndex: row.int(0), full: row.int(1) != 0, removed: removed,
                set: CloudState(ids: ids, points: points, samples: samples)
            )
        }
    }

    /// Experiment X1's track rows, in the order written. Empty before version 3.
    public func surfaces() throws -> [SurfaceRecord] {
        guard schemaVersion >= 3 else { return [] }
        return try query("SELECT * FROM surface ORDER BY rowid") { row in
            guard let id = UUID(uuidString: row.text(1)), let event = AnchorEvent(rawValue: row.int(3)) else {
                throw SessionDatabaseError.corruptRow("surface at frame \(row.int(0))")
            }
            var geometry: SurfaceGeometry?
            if event != .remove {
                guard let normal = Packing.vector3(row.blob(5)),
                      let center = Packing.vector3(row.blob(6)),
                      let outline = Packing.points(row.blob(7))
                else { throw SessionDatabaseError.corruptRow("surface \(id) at frame \(row.int(0))") }
                geometry = SurfaceGeometry(
                    state: row.int(4), normal: normal, center: center, outline: outline, width: Float(row.real(8)),
                    height: Float(row.real(9)), rmsError: Float(row.real(10)), inliers: row.int(11)
                )
            }
            let merged = row.isNull(12) ? nil : UUID(uuidString: row.text(12))
            return SurfaceRecord(
                frameIndex: row.int(0), surfaceID: id, number: row.int(2), event: event, geometry: geometry,
                mergedInto: merged
            )
        }
    }

    /// The engine's round rows, in the order written. Empty before version 4.
    public func surfaceRounds() throws -> [SurfaceRoundRecord] {
        guard schemaVersion >= 4 else { return [] }
        return try query("SELECT * FROM surface_round ORDER BY rowid") { row in
            SurfaceRoundRecord(
                frameIndex: row.int(0), round: row.int(1), points: row.int(2), unclaimed: row.int(3),
                tracks: row.int(4), confirmed: row.int(5), refits: row.int(6), searched: row.int(7) != 0,
                planesFound: row.int(8), hypotheses: row.int(9), fullScores: row.int(10), pointTests: row.int(11),
                totalMilliseconds: row.real(12), refitMilliseconds: row.real(13), searchMilliseconds: row.real(14),
                skipped: row.int(15), thermal: row.int(16)
            )
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
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
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
