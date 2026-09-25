-- Plane Lab session format, schema version 3 (SPEC.md §3.3).
-- The one source of the DDL (SPEC.md §17.4 P2). Swift (SessionSchema.ddl) and Python (planelab.schema.DDL)
-- embed copies, and a test on each side checks the copy matches this file exactly.
-- Conventions: SPEC.md §3.2. BLOBs are little-endian float32 / uint64 / uint16, packed with no padding.
-- Version 2 adds the cloud table (SPEC.md L12, P23); version 3 adds the surface table (EXPERIMENTS.md X1, XD6).
-- Readers still open versions 1 and 2, which lack the tables added after them.

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

-- Experiment X1 (EXPERIMENTS.md): CurvSurf FindSurface planes tracked on the phone. One row per track that changed in a
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
