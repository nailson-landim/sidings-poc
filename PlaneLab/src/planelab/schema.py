"""The session format's schema (SPEC.md §3.3).

``DDL`` is a copy of ``session-format/schema_v1.sql``; ``tests/test_contract.py`` checks it matches the file exactly
(SPEC.md §17.4 P2). The copy lives here so the package works inside Blender with no repository around it.
"""

SCHEMA_VERSION = 1
SUPPORTED_VERSIONS: tuple[int, ...] = (1,)

DDL = """\
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
