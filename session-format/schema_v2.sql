-- Plane Lab session format, schema version 2 (SPEC.md §3.3).
-- The one source of the DDL (SPEC.md §17.4 P2). Swift (SessionSchema.ddl) and Python (planelab.schema.DDL)
-- embed copies, and a test on each side checks the copy matches this file exactly.
-- Conventions: SPEC.md §3.2. BLOBs are little-endian float32 / uint64 / uint16, packed with no padding.
-- Version 2 adds the cloud table (SPEC.md L12, P23). Readers still open version 1 files, which have no cloud table.

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
