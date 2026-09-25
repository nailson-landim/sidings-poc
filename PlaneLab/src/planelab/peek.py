"""A readable copy of a recording for eyeballing in any SQLite browser (``planelab peek``).

Every BLOB of ``session.sqlite`` is decoded into plain columns with units, enums become words, and each table and
column is explained in ``_about``. The recording itself is never modified (SPEC.md §3.2): the copy goes to
``<bundle>/lab/peek.sqlite``.

Angles describe where the phone looks, in ARKit's world (+Y up, origin and heading where the session started):
yaw is the turn left (-) or right (+) from the starting direction, pitch is up (+) or down (-), roll is the tilt of
the image's long side.
"""

import csv
import json
import logging
import math
import sqlite3
from collections.abc import Iterable, Sequence
from dataclasses import asdict
from datetime import UTC, datetime
from pathlib import Path

import numpy as np

from planelab.info import summarize
from planelab.session import AnchorEvent, CloudRow, Frame, Session, SurfaceRoundRow, SurfaceRow

log = logging.getLogger(__name__)

TRACKING = {0: "not_available", 1: "limited", 2: "normal"}
TRACKING_REASON = {0: "", 1: "initializing", 2: "excessive_motion", 3: "insufficient_features", 4: "relocalizing"}
MAPPING = {0: "not_available", 1: "limited", 2: "extending", 3: "mapped"}
THERMAL = {0: "nominal", 1: "fair", 2: "serious", 3: "critical"}
ANCHOR_EVENT = {0: "add", 1: "update", 2: "remove"}
ALIGNMENT = {0: "horizontal", 1: "vertical"}
SURFACE_STATE = {0: "tentative", 1: "confirmed", 2: "stale"}
CLASSIFICATION = {0: "none", 1: "wall", 2: "floor", 3: "ceiling", 4: "table", 5: "seat", 6: "window", 7: "door"}

# (table, column or "", meaning). The empty column describes the table. Tests check every column is listed.
ABOUT: list[tuple[str, str, str]] = [
    ("frames", "", "One row per logged ARFrame, every BLOB decoded. ARKit world: metres, +Y up."),
    ("frames", "idx", "Frame number, the join key everywhere. Blender timeline frame = idx + 1."),
    ("frames", "t", "ARFrame.timestamp, seconds of device uptime."),
    ("frames", "t_rel_s", "Seconds since the first frame."),
    ("frames", "dt_ms", "Milliseconds since the previous frame (16.7 at 60 Hz, 33.3 at 30 Hz)."),
    ("frames", "has_image", "1 when video.mov holds this frame's image."),
    ("frames", "video_time_s", "Time of this frame's image in video.mov (idx / video_fps); empty without an image."),
    ("frames", "tracking", "ARKit tracking state."),
    ("frames", "tracking_reason", "Why tracking is limited; empty when normal."),
    ("frames", "mapping", "ARFrame.worldMappingStatus."),
    ("frames", "thermal", "ProcessInfo thermal state when the frame arrived."),
    ("frames", "exposure_ms", "Camera exposure duration."),
    ("frames", "cam_x", "Camera centre, ARKit world X (m)."),
    ("frames", "cam_y", "Camera centre, ARKit world Y (m, up)."),
    ("frames", "cam_z", "Camera centre, ARKit world Z (m)."),
    ("frames", "blender_x", "Camera centre in Blender axes: X = ARKit X."),
    ("frames", "blender_y", "Camera centre in Blender axes: Y = -ARKit Z."),
    ("frames", "blender_z", "Camera centre in Blender axes: Z = ARKit Y (up)."),
    ("frames", "path_m", "Distance the camera has travelled since the first frame."),
    ("frames", "speed_mps", "Camera speed since the previous frame (m/s)."),
    ("frames", "yaw_deg", "Turn from the starting direction: + right, - left."),
    ("frames", "pitch_deg", "Look direction above (+) or below (-) the horizon."),
    ("frames", "roll_deg", "Tilt of the image's long side from level."),
    ("frames", "fx", "Focal length x, pixels of the 1920x1440-style landscape image."),
    ("frames", "fy", "Focal length y, pixels."),
    ("frames", "cx", "Principal point x, pixels."),
    ("frames", "cy", "Principal point y, pixels."),
    ("frames", "point_count", "Raw feature points in this frame."),
    ("frames", "new_ids", "Points whose feature id appears for the first time in this frame."),
    ("frames", "dist_min_m", "Nearest point to the camera (m)."),
    ("frames", "dist_p50_m", "Median point distance (m)."),
    ("frames", "dist_p95_m", "95th-percentile point distance (m); the E1 range readout."),
    ("frames", "dist_max_m", "Farthest point (m)."),
    ("points", "", "One row per raw feature point per frame."),
    ("points", "idx", "Frame number."),
    ("points", "point_id", "rawFeaturePoints identifier (uint64, as text so no value overflows)."),
    ("points", "x", "ARKit world X (m)."),
    ("points", "y", "ARKit world Y (m, up)."),
    ("points", "z", "ARKit world Z (m)."),
    ("points", "dist_m", "Distance from the camera in that frame (m)."),
    ("features", "", "One row per feature id over the whole session: how often and how consistently it was seen."),
    ("features", "point_id", "rawFeaturePoints identifier (text)."),
    ("features", "first_idx", "First frame with this id."),
    ("features", "last_idx", "Last frame with this id."),
    ("features", "frames_seen", "Frames that reported this id."),
    ("features", "mean_x", "Mean position X over its sightings (m)."),
    ("features", "mean_y", "Mean position Y (m)."),
    ("features", "mean_z", "Mean position Z (m)."),
    ("features", "spread_m", "RMS distance of its sightings from the mean (m): how much ARKit's estimate moved."),
    ("features", "mean_dist_m", "Mean distance from the camera (m)."),
    ("anchors", "", "ARKit plane anchor callbacks, decoded. A remove carries only the id."),
    ("anchors", "frame_idx", "Last logged frame when the callback arrived."),
    ("anchors", "anchor_id", "ARKit anchor UUID."),
    ("anchors", "event", "add / update / remove."),
    ("anchors", "alignment", "horizontal / vertical."),
    ("anchors", "classification", "ARKit plane classification."),
    ("anchors", "pos_x", "Anchor origin, world X (m)."),
    ("anchors", "pos_y", "Anchor origin, world Y (m)."),
    ("anchors", "pos_z", "Anchor origin, world Z (m)."),
    ("anchors", "normal_x", "Plane normal (anchor +Y), world X."),
    ("anchors", "normal_y", "Plane normal, world Y."),
    ("anchors", "normal_z", "Plane normal, world Z."),
    ("anchors", "center_x", "Extent centre in anchor space X (m)."),
    ("anchors", "center_y", "Extent centre in anchor space Y (m)."),
    ("anchors", "center_z", "Extent centre in anchor space Z (m)."),
    ("anchors", "width_m", "planeExtent width (m)."),
    ("anchors", "height_m", "planeExtent height (m)."),
    ("anchors", "rotation_deg", "planeExtent rotationOnYAxis."),
    ("anchors", "boundary_vertices", "Boundary polygon vertex count."),
    ("anchors", "boundary_json", "Boundary polygon, anchor space, as [[x, y, z], ...]."),
    ("locations", "", "GPS fixes (site metadata, never geometry)."),
    ("locations", "frame_idx", "Last logged frame when the fix arrived."),
    ("locations", "utc", "Fix time, ISO 8601 UTC."),
    ("locations", "lat", "Latitude (deg, WGS 84)."),
    ("locations", "lon", "Longitude (deg)."),
    ("locations", "alt_m", "Altitude above sea level (m)."),
    ("locations", "ellipsoidal_alt_m", "Altitude above the WGS 84 ellipsoid (m)."),
    ("locations", "h_acc_m", "Horizontal accuracy (m)."),
    ("locations", "v_acc_m", "Vertical accuracy (m)."),
    ("headings", "", "Compass updates."),
    ("headings", "frame_idx", "Last logged frame when the update arrived."),
    ("headings", "true_deg", "True heading (deg); -1 when invalid."),
    ("headings", "magnetic_deg", "Magnetic heading (deg)."),
    ("headings", "acc_deg", "Heading accuracy (deg)."),
    ("events", "", "Session events: record start/stop, tracking changes, user marks."),
    ("events", "frame_idx", "Frame the event belongs to."),
    ("events", "kind", "Event kind."),
    ("events", "detail", "Event detail."),
    ("cloud_rows", "", "The phone's averaged cloud as recorded (schema v2, SPEC.md P23): one row per cloud row."),
    ("cloud_rows", "frame_idx", "Frame after which the phone took this row."),
    ("cloud_rows", "full", "1: a full copy of the cloud; 0: the changes since the previous row."),
    ("cloud_rows", "removed", "Ids removed by this row (evicted from the accumulator)."),
    ("cloud_rows", "changed", "Ids set by this row (new or updated averaged points)."),
    ("cloud_rows", "points_after", "Averaged points in the phone's cloud after this row."),
    ("cloud_points", "", "Every id a cloud row removes or sets, one row each."),
    ("cloud_points", "frame_idx", "The cloud row's frame."),
    ("cloud_points", "point_id", "Feature id (uint64 as text)."),
    ("cloud_points", "change", "set or removed."),
    ("cloud_points", "x", "Averaged position, ARKit world (m); NULL when removed."),
    ("cloud_points", "y", "Averaged position (m); NULL when removed."),
    ("cloud_points", "z", "Averaged position (m); NULL when removed."),
    ("cloud_points", "samples", "Samples in the id's FIFO; NULL when removed."),
    ("cloud_final", "", "The phone's averaged cloud after the last cloud row."),
    ("cloud_final", "point_id", "Feature id (uint64 as text)."),
    ("cloud_final", "x", "Averaged position, ARKit world (m)."),
    ("cloud_final", "y", "Averaged position (m)."),
    ("cloud_final", "z", "Averaged position (m)."),
    ("cloud_final", "samples", "Samples in the id's FIFO."),
    (
        "x1_surfaces",
        "",
        "The phone's tracked planes as recorded (schema v3, XD6); meta surface_engine names the engine.",
    ),
    ("x1_surfaces", "frame_idx", "Last recorded frame when the round that wrote this row started."),
    ("x1_surfaces", "surface_id", "Track id (UUID)."),
    ("x1_surfaces", "number", "Track number, 1, 2, 3... in creation order (the phone's label and color)."),
    ("x1_surfaces", "event", "add, update or remove."),
    ("x1_surfaces", "state", "tentative, confirmed or stale; NULL on remove."),
    ("x1_surfaces", "normal_x", "Plane normal, ARKit world."),
    ("x1_surfaces", "normal_y", "Plane normal Y (+Y is up: near 0 for a wall)."),
    ("x1_surfaces", "normal_z", "Plane normal Z."),
    ("x1_surfaces", "center_x", "Inlier centroid on the plane, ARKit world (m)."),
    ("x1_surfaces", "center_y", "Inlier centroid Y (m)."),
    ("x1_surfaces", "center_z", "Inlier centroid Z (m)."),
    ("x1_surfaces", "outline_vertices", "Vertices of the outline (convex hull of the inliers on the plane)."),
    ("x1_surfaces", "outline_json", "Outline, ARKit world, as [[x, y, z], ...]."),
    ("x1_surfaces", "width_m", "Outline extent along the plane's horizontal (m)."),
    ("x1_surfaces", "height_m", "Outline extent along the plane's other axis (m)."),
    ("x1_surfaces", "rms_cm", "RMS error of the last fit (cm)."),
    ("x1_surfaces", "inliers", "Inlier feature ids the track holds."),
    ("x1_surfaces", "merged_into", "On a remove: the older track this one merged into; NULL when it was dropped."),
    ("surface_rounds", "", "What each round of the phone's plane engine cost (schema v4, EXPERIMENTS.md XD16)."),
    ("surface_rounds", "frame_idx", "Last recorded frame when the round started."),
    ("surface_rounds", "round", "Round number since the recording started."),
    ("surface_rounds", "points", "Points in the averaged cloud the round ran on."),
    ("surface_rounds", "unclaimed", "Points no track held when discovery started."),
    ("surface_rounds", "tracks", "Tracks after the round."),
    ("surface_rounds", "confirmed", "Confirmed tracks after the round."),
    ("surface_rounds", "refits", "Tracked planes refitted this round."),
    ("surface_rounds", "searched", "1 when the round ran a discovery search."),
    ("surface_rounds", "planes_found", "Planes the search found, before connected pieces and acceptance."),
    ("surface_rounds", "hypotheses", "RANSAC hypotheses drawn."),
    ("surface_rounds", "full_scores", "Hypotheses scored on the whole cloud (the rest were dropped by lazy scoring)."),
    ("surface_rounds", "point_tests", "Point-versus-plane distance tests, in all."),
    ("surface_rounds", "total_ms", "The whole round, wall clock on the phone."),
    ("surface_rounds", "refit_ms", "The refit stage."),
    ("surface_rounds", "search_ms", "The discovery search stage (0 when it didn't run)."),
    ("surface_rounds", "skipped", "Running count of rounds not started because the previous one was still running."),
    ("surface_rounds", "thermal", "Thermal state when the round ran: 0 nominal, 1 fair, 2 serious, 3 critical."),
    ("meta", "", "The recording's meta table, copied as is."),
    ("meta", "key", "Meta key (SPEC.md §3.3)."),
    ("meta", "value", "Meta value."),
    ("summary", "", "The planelab info summary, one value per row."),
    ("summary", "key", "Summary field."),
    ("summary", "value", "Summary value."),
    ("_about", "", "This table: what every table and column means."),
    ("_about", "table_name", "Table."),
    ("_about", "column_name", "Column; empty for the table itself."),
    ("_about", "meaning", "What it holds, with units."),
]

SCHEMA = """
CREATE TABLE frames (
    idx INTEGER PRIMARY KEY, t REAL, t_rel_s REAL, dt_ms REAL, has_image INTEGER, video_time_s REAL,
    tracking TEXT, tracking_reason TEXT, mapping TEXT, thermal TEXT, exposure_ms REAL,
    cam_x REAL, cam_y REAL, cam_z REAL, blender_x REAL, blender_y REAL, blender_z REAL,
    path_m REAL, speed_mps REAL, yaw_deg REAL, pitch_deg REAL, roll_deg REAL,
    fx REAL, fy REAL, cx REAL, cy REAL,
    point_count INTEGER, new_ids INTEGER, dist_min_m REAL, dist_p50_m REAL, dist_p95_m REAL, dist_max_m REAL
);
CREATE TABLE points (idx INTEGER, point_id TEXT, x REAL, y REAL, z REAL, dist_m REAL);
CREATE INDEX points_idx ON points (idx);
CREATE INDEX points_id ON points (point_id);
CREATE TABLE features (
    point_id TEXT PRIMARY KEY, first_idx INTEGER, last_idx INTEGER, frames_seen INTEGER,
    mean_x REAL, mean_y REAL, mean_z REAL, spread_m REAL, mean_dist_m REAL
);
CREATE TABLE anchors (
    frame_idx INTEGER, anchor_id TEXT, event TEXT, alignment TEXT, classification TEXT,
    pos_x REAL, pos_y REAL, pos_z REAL, normal_x REAL, normal_y REAL, normal_z REAL,
    center_x REAL, center_y REAL, center_z REAL, width_m REAL, height_m REAL, rotation_deg REAL,
    boundary_vertices INTEGER, boundary_json TEXT
);
CREATE TABLE locations (
    frame_idx INTEGER, utc TEXT, lat REAL, lon REAL, alt_m REAL, ellipsoidal_alt_m REAL, h_acc_m REAL, v_acc_m REAL
);
CREATE TABLE headings (frame_idx INTEGER, true_deg REAL, magnetic_deg REAL, acc_deg REAL);
CREATE TABLE events (frame_idx INTEGER, kind TEXT, detail TEXT);
CREATE TABLE cloud_rows (
    frame_idx INTEGER PRIMARY KEY, full INTEGER, removed INTEGER, changed INTEGER, points_after INTEGER
);
CREATE TABLE cloud_points (frame_idx INTEGER, point_id TEXT, change TEXT, x REAL, y REAL, z REAL, samples INTEGER);
CREATE INDEX cloud_points_idx ON cloud_points (frame_idx);
CREATE TABLE cloud_final (point_id TEXT PRIMARY KEY, x REAL, y REAL, z REAL, samples INTEGER);
CREATE TABLE x1_surfaces (
    frame_idx INTEGER, surface_id TEXT, number INTEGER, event TEXT, state TEXT,
    normal_x REAL, normal_y REAL, normal_z REAL, center_x REAL, center_y REAL, center_z REAL,
    outline_vertices INTEGER, outline_json TEXT, width_m REAL, height_m REAL, rms_cm REAL, inliers INTEGER,
    merged_into TEXT
);
CREATE INDEX x1_surfaces_idx ON x1_surfaces (frame_idx);
CREATE TABLE surface_rounds (
    frame_idx INTEGER, round INTEGER, points INTEGER, unclaimed INTEGER, tracks INTEGER, confirmed INTEGER,
    refits INTEGER, searched INTEGER, planes_found INTEGER, hypotheses INTEGER, full_scores INTEGER,
    point_tests INTEGER, total_ms REAL, refit_ms REAL, search_ms REAL, skipped INTEGER, thermal INTEGER
);
CREATE INDEX surface_rounds_idx ON surface_rounds (frame_idx);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE summary (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE _about (table_name TEXT, column_name TEXT, meaning TEXT);
CREATE VIEW frames_without_image AS SELECT * FROM frames WHERE has_image = 0;
CREATE VIEW slow_frames AS SELECT * FROM frames WHERE dt_ms > 25;
CREATE VIEW tracking_not_normal AS SELECT * FROM frames WHERE tracking != 'normal';
"""


def angles(camera: np.ndarray) -> tuple[float, float, float]:
    """(yaw, pitch, roll) in degrees for a world <- camera matrix. The camera looks down its -Z axis."""
    forward = -camera[:3, 2]
    right = camera[:3, 0]
    yaw = math.degrees(math.atan2(float(forward[0]), float(-forward[2])))
    pitch = math.degrees(math.asin(max(-1.0, min(1.0, float(forward[1])))))
    roll = math.degrees(math.asin(max(-1.0, min(1.0, float(right[1])))))
    return yaw, pitch, roll


def _frame_row(
    frame: Frame, previous: Frame | None, t0: float, path_m: float, new_ids: int, video_fps: float
) -> tuple[object, ...]:
    position = frame.position.astype(np.float64)
    dt = frame.t - previous.t if previous else 0.0
    step = float(np.linalg.norm(position - previous.position)) if previous else 0.0
    distances = np.linalg.norm(frame.points - frame.position, axis=1) if frame.points.size else None
    yaw, pitch, roll = angles(frame.camera)
    k = frame.intrinsics
    return (
        frame.idx,
        frame.t,
        frame.t - t0,
        dt * 1000 if previous else None,
        int(frame.has_image),
        frame.idx / video_fps if frame.has_image else None,
        TRACKING.get(frame.tracking, str(frame.tracking)),
        TRACKING_REASON.get(frame.tracking_reason, str(frame.tracking_reason)),
        MAPPING.get(frame.mapping, str(frame.mapping)),
        THERMAL.get(frame.thermal, str(frame.thermal)),
        frame.exposure_s * 1000,
        *(float(v) for v in position),
        float(position[0]),
        float(-position[2]),
        float(position[1]),
        path_m,
        step / dt if previous and dt > 0 else None,
        yaw,
        pitch,
        roll,
        float(k[0, 0]),
        float(k[1, 1]),
        float(k[0, 2]),
        float(k[1, 2]),
        int(frame.points.shape[0]),
        new_ids,
        *(
            (float(distances.min()), *(float(v) for v in np.percentile(distances, [50, 95])), float(distances.max()))
            if distances is not None
            else (None, None, None, None)
        ),
    )


def _anchor_row(anchor: AnchorEvent) -> tuple[object, ...]:
    geometry: Sequence[object]
    if anchor.transform is None or anchor.center is None or anchor.extent is None or anchor.boundary is None:
        geometry = (None,) * 14
    else:
        geometry = (
            *(float(v) for v in anchor.transform[:3, 3]),
            *(float(v) for v in anchor.transform[:3, 1]),
            *(float(v) for v in anchor.center),
            float(anchor.extent[0]),
            float(anchor.extent[1]),
            math.degrees(float(anchor.extent[2])),
            int(anchor.boundary.shape[0]),
            str([[round(float(c), 4) for c in v] for v in anchor.boundary]),
        )
    return (
        anchor.frame_idx,
        anchor.anchor_id,
        ANCHOR_EVENT.get(anchor.event, str(anchor.event)),
        None if anchor.alignment is None else ALIGNMENT.get(anchor.alignment, str(anchor.alignment)),
        None if anchor.classification is None else CLASSIFICATION.get(anchor.classification, "other"),
        *geometry,
    )


def _feature_rows(idx: np.ndarray, ids: np.ndarray, xyz: np.ndarray, dist: np.ndarray) -> Iterable[tuple[object, ...]]:
    """Per-id aggregates over every sighting. Sightings are in frame order, so first/last come from positions."""
    unique, first_pos, inverse, counts = np.unique(ids, return_index=True, return_inverse=True, return_counts=True)
    last_pos = len(ids) - 1 - np.unique(ids[::-1], return_index=True)[1]
    mean = np.stack([np.bincount(inverse, weights=xyz[:, c]) for c in range(3)], axis=1) / counts[:, None]
    mean_sq = np.stack([np.bincount(inverse, weights=xyz[:, c] ** 2) for c in range(3)], axis=1) / counts[:, None]
    spread = np.sqrt(np.clip((mean_sq - mean**2).sum(axis=1), 0, None))
    mean_dist = np.bincount(inverse, weights=dist) / counts
    for k, point_id in enumerate(unique.tolist()):
        yield (
            str(point_id),
            int(idx[first_pos[k]]),
            int(idx[last_pos[k]]),
            int(counts[k]),
            *(float(v) for v in mean[k]),
            float(spread[k]),
            float(mean_dist[k]),
        )


def _flatten(prefix: str, value: object) -> Iterable[tuple[str, str]]:
    if isinstance(value, dict):
        for key, inner in value.items():
            yield from _flatten(f"{prefix}.{key}" if prefix else str(key), inner)
    else:
        yield prefix, "" if value is None else str(value)


def write_peek(session: Session, out: Path | None = None, csv_path: Path | None = None) -> Path:
    """Writes the readable copy (replacing an older one) and returns its path."""
    target = out or session.bundle / "lab" / "peek.sqlite"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.unlink(missing_ok=True)
    video_fps = float(session.meta.get("video_fps", "60") or 60)

    db = sqlite3.connect(target)
    try:
        db.executescript(SCHEMA)
        frame_rows: list[tuple[object, ...]] = []
        seen: set[int] = set()
        all_idx: list[np.ndarray] = []
        all_ids: list[np.ndarray] = []
        all_xyz: list[np.ndarray] = []
        all_dist: list[np.ndarray] = []
        previous: Frame | None = None
        t0: float | None = None
        path_m = 0.0
        for frame in session.frames():
            t0 = frame.t if t0 is None else t0
            if previous is not None:
                path_m += float(np.linalg.norm(frame.position - previous.position))
            ids = frame.point_ids.tolist()
            new_ids = sum(1 for i in ids if i not in seen)
            seen.update(ids)
            frame_rows.append(_frame_row(frame, previous, t0, path_m, new_ids, video_fps))
            if frame.points.size:
                distances = np.linalg.norm(frame.points - frame.position, axis=1)
                db.executemany(
                    "INSERT INTO points VALUES (?, ?, ?, ?, ?, ?)",
                    zip(
                        [frame.idx] * len(ids),
                        map(str, ids),
                        *(frame.points[:, c].tolist() for c in range(3)),
                        distances.tolist(),
                        strict=True,
                    ),
                )
                all_idx.append(np.full(len(ids), frame.idx, dtype=np.int64))
                all_ids.append(frame.point_ids)
                all_xyz.append(frame.points.astype(np.float64))
                all_dist.append(distances.astype(np.float64))
            previous = frame
        db.executemany(f"INSERT INTO frames VALUES ({', '.join('?' * 32)})", frame_rows)
        if all_ids:
            db.executemany(
                "INSERT INTO features VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                _feature_rows(
                    np.concatenate(all_idx), np.concatenate(all_ids), np.concatenate(all_xyz), np.concatenate(all_dist)
                ),
            )
        db.executemany(f"INSERT INTO anchors VALUES ({', '.join('?' * 19)})", map(_anchor_row, session.anchors()))
        db.executemany(
            "INSERT INTO locations VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (
                (
                    loc.frame_idx,
                    datetime.fromtimestamp(loc.utc, UTC).isoformat(),
                    loc.lat,
                    loc.lon,
                    loc.alt_m,
                    loc.ellipsoidal_alt_m,
                    loc.h_acc_m,
                    loc.v_acc_m,
                )
                for loc in session.locations()
            ),
        )
        db.executemany(
            "INSERT INTO headings VALUES (?, ?, ?, ?)",
            ((h.frame_idx, h.true_deg, h.magnetic_deg, h.acc_deg) for h in session.headings()),
        )
        db.executemany(
            "INSERT INTO events VALUES (?, ?, ?)", ((e.frame_idx, e.kind, e.detail) for e in session.events())
        )
        _write_cloud(db, session.cloud_rows())
        surfaces = map(_surface_row, session.surface_rows())
        db.executemany(f"INSERT INTO x1_surfaces VALUES ({', '.join('?' * 18)})", surfaces)
        db.executemany(
            f"INSERT INTO surface_rounds VALUES ({', '.join('?' * 17)})",
            map(_round_row, session.surface_round_rows()),
        )
        db.executemany("INSERT INTO meta VALUES (?, ?)", sorted(session.meta.items()))
        db.executemany("INSERT INTO summary VALUES (?, ?)", _flatten("", asdict(summarize(session))))
        db.executemany("INSERT INTO _about VALUES (?, ?, ?)", ABOUT)
        db.commit()
    finally:
        db.close()

    if csv_path is not None:
        _frames_csv(target, csv_path)
    log.info("wrote %s", target)
    return target


def _round_row(row: SurfaceRoundRow) -> tuple[object, ...]:
    return (
        row.frame_idx,
        row.round,
        row.points,
        row.unclaimed,
        row.tracks,
        row.confirmed,
        row.refits,
        int(row.searched),
        row.planes_found,
        row.hypotheses,
        row.full_scores,
        row.point_tests,
        row.total_ms,
        row.refit_ms,
        row.search_ms,
        row.skipped,
        row.thermal,
    )


def _surface_row(row: SurfaceRow) -> tuple[object, ...]:
    def xyz(v: np.ndarray | None) -> list[float | None]:
        return [None] * 3 if v is None else [float(c) for c in v]

    return (
        row.frame_idx,
        row.surface_id,
        row.number,
        ANCHOR_EVENT.get(row.event, str(row.event)),
        None if row.state is None else SURFACE_STATE.get(row.state, str(row.state)),
        *xyz(row.normal),
        *xyz(row.center),
        None if row.outline is None else len(row.outline),
        None if row.outline is None else json.dumps(row.outline.tolist()),
        row.width_m,
        row.height_m,
        None if row.rms_m is None else row.rms_m * 100,
        row.inliers,
        row.merged_into,
    )


def _write_cloud(db: sqlite3.Connection, rows: list[CloudRow]) -> None:
    """The phone's cloud rows, decoded, plus the cloud they add up to (``cloud_final``)."""
    cloud: dict[int, tuple[float, float, float, int]] = {}
    for row in rows:
        if row.full:
            cloud.clear()
        for key in row.removed.tolist():
            cloud.pop(key, None)
        values = list(zip(row.ids.tolist(), row.points.tolist(), row.samples.tolist(), strict=True))
        for key, (x, y, z), n in values:
            cloud[key] = (x, y, z, n)
        db.execute(
            "INSERT INTO cloud_rows VALUES (?, ?, ?, ?, ?)",
            (row.frame_idx, int(row.full), len(row.removed), len(row.ids), len(cloud)),
        )
        db.executemany(
            "INSERT INTO cloud_points VALUES (?, ?, 'removed', NULL, NULL, NULL, NULL)",
            ((row.frame_idx, str(key)) for key in row.removed.tolist()),
        )
        db.executemany(
            "INSERT INTO cloud_points VALUES (?, ?, 'set', ?, ?, ?, ?)",
            ((row.frame_idx, str(key), x, y, z, n) for key, (x, y, z), n in values),
        )
    db.executemany(
        "INSERT INTO cloud_final VALUES (?, ?, ?, ?, ?)",
        ((str(key), x, y, z, n) for key, (x, y, z, n) in sorted(cloud.items())),
    )


def _frames_csv(peek: Path, csv_path: Path) -> None:
    db = sqlite3.connect(peek)
    try:
        cursor = db.execute("SELECT * FROM frames ORDER BY idx")
        with csv_path.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle)
            writer.writerow(column[0] for column in cursor.description)
            writer.writerows(cursor)
    finally:
        db.close()


def table_counts(peek: Path) -> dict[str, int]:
    db = sqlite3.connect(peek)
    try:
        tables = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")]
        return {t: int(db.execute(f'SELECT count(*) FROM "{t}"').fetchone()[0]) for t in tables}
    finally:
        db.close()
