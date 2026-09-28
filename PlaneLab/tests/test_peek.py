"""``planelab peek``: the readable copy of a recording."""

import csv
import shutil
import sqlite3
from pathlib import Path

import numpy as np
import pytest
from conftest import FIXTURE_BUNDLE

from planelab.cli import main
from planelab.peek import ABOUT, angles, table_counts, write_peek
from planelab.session import open_session


@pytest.fixture(scope="module")
def peek(tmp_path_factory: pytest.TempPathFactory) -> sqlite3.Connection:
    out = tmp_path_factory.mktemp("peek") / "peek.sqlite"
    with open_session(FIXTURE_BUNDLE) as session:
        write_peek(session, out=out)
    db = sqlite3.connect(out)
    db.row_factory = sqlite3.Row
    return db


def row(db: sqlite3.Connection, sql: str, *args: object) -> sqlite3.Row:
    return db.execute(sql, args).fetchone()


def test_every_table_and_column_is_explained(peek: sqlite3.Connection) -> None:
    about = {(t, c) for t, c, _ in ABOUT}
    tables = [r[0] for r in peek.execute("SELECT name FROM sqlite_master WHERE type = 'table'")]
    for table in tables:
        assert (table, "") in about, table
        for column in peek.execute(f'PRAGMA table_info("{table}")'):
            assert (table, column[1]) in about, f"{table}.{column[1]}"


def test_frames_are_decoded(peek: sqlite3.Connection) -> None:
    assert row(peek, "SELECT count(*) FROM frames")[0] == 10
    first = row(peek, "SELECT * FROM frames WHERE idx = 0")
    assert (first["tracking"], first["tracking_reason"], first["has_image"]) == ("limited", "initializing", 0)
    assert first["dt_ms"] is None and first["video_time_s"] is None and first["dist_p50_m"] is None
    assert first["exposure_ms"] == pytest.approx(7.8125)
    second = row(peek, "SELECT * FROM frames WHERE idx = 1")
    assert second["dt_ms"] == pytest.approx(1000 / 32)
    assert second["video_time_s"] == pytest.approx(1 / 60)
    assert (second["fx"], second["fy"], second["cx"], second["cy"]) == (1500.5, 1500.5, 960.25, 720.75)
    assert second["point_count"] == second["new_ids"] == 4


def test_camera_position_axes_and_path(peek: sqlite3.Connection) -> None:
    frame = row(peek, "SELECT * FROM frames WHERE idx = 2")
    assert (frame["cam_x"], frame["cam_y"], frame["cam_z"]) == (0.25, 1.5, -0.5)
    assert (frame["blender_x"], frame["blender_y"], frame["blender_z"]) == (0.25, 0.5, 1.5)
    step = np.hypot(0.125, 0.25)
    assert frame["path_m"] == pytest.approx(2 * step)
    assert frame["speed_mps"] == pytest.approx(step * 32)


def test_angles_of_the_fixture_cameras(peek: sqlite3.Connection) -> None:
    straight = row(peek, "SELECT yaw_deg, pitch_deg, roll_deg FROM frames WHERE idx = 0")
    assert tuple(straight) == pytest.approx((0, 0, 0))
    turned = row(peek, "SELECT yaw_deg, pitch_deg, roll_deg FROM frames WHERE idx = 1")
    assert tuple(turned) == pytest.approx((-90, 0, 0))


def test_angles_for_looking_up_and_tilting() -> None:
    up = np.eye(4)
    up[:3, :3] = [[1, 0, 0], [0, 0, -1], [0, 1, 0]]  # camera -Z points to world +Y
    assert angles(up)[1] == pytest.approx(90)
    tilted = np.eye(4)
    tilted[:3, :3] = [[0, -1, 0], [1, 0, 0], [0, 0, 1]]  # image's long side (camera +X) points to world +Y
    assert angles(tilted)[2] == pytest.approx(90)


def test_points_and_features(peek: sqlite3.Connection) -> None:
    assert row(peek, "SELECT count(*) FROM points")[0] == 36
    big = row(peek, "SELECT point_id FROM points WHERE idx = 9 ORDER BY point_id LIMIT 1")
    assert big[0] == "18000000000000000000"
    features = row(peek, "SELECT count(*), max(frames_seen), max(spread_m) FROM features")
    assert tuple(features) == (36, 1, 0.0)
    point = row(peek, "SELECT * FROM points WHERE idx = 1 ORDER BY x LIMIT 1")
    assert (point["x"], point["y"], point["z"]) == (1.0, 1.25, -3.75)


def test_features_aggregate_repeated_sightings(tmp_path: Path) -> None:
    """Same id seen twice at two places: first/last frame, count, mean and spread."""
    bundle = tmp_path / "copy.planelab"

    shutil.copytree(FIXTURE_BUNDLE, bundle)
    with sqlite3.connect(bundle / "session.sqlite") as db:
        one = np.array([[0.0, 0.0, -1.0]], dtype="<f4").tobytes()
        two = np.array([[0.0, 0.0, -3.0]], dtype="<f4").tobytes()
        same_id = np.array([7], dtype="<u8").tobytes()
        db.execute("UPDATE frame SET points = ?, point_ids = ?, point_count = 1 WHERE idx = 1", (one, same_id))
        db.execute("UPDATE frame SET points = ?, point_ids = ?, point_count = 1 WHERE idx = 3", (two, same_id))
    with open_session(bundle) as session:
        out = write_peek(session)
    db = sqlite3.connect(out)
    first, last, seen, mean_z, spread = db.execute(
        "SELECT first_idx, last_idx, frames_seen, mean_z, spread_m FROM features WHERE point_id = '7'"
    ).fetchone()
    assert (first, last, seen, mean_z, spread) == (1, 3, 2, -2.0, 1.0)
    assert out == session.bundle / "lab" / "peek.sqlite"


def test_anchors_are_decoded(peek: sqlite3.Connection) -> None:
    rows = peek.execute("SELECT * FROM anchors ORDER BY rowid").fetchall()
    assert [r["event"] for r in rows] == ["add", "update", "add", "remove"]
    wall = rows[0]
    assert (wall["alignment"], wall["classification"]) == ("vertical", "wall")
    assert (wall["pos_x"], wall["pos_y"], wall["pos_z"]) == (1.0, 0.5, -2.0)
    assert (wall["normal_x"], wall["normal_y"], wall["normal_z"]) == (0.0, 0.0, 1.0)
    assert (wall["width_m"], wall["height_m"], wall["boundary_vertices"]) == (1.0, 0.5, 4)
    assert rows[2]["classification"] == "floor"
    removed = rows[3]
    assert removed["alignment"] is None and removed["boundary_json"] is None


def test_small_tables_meta_summary_and_views(peek: sqlite3.Connection) -> None:
    assert row(peek, "SELECT utc FROM locations LIMIT 1")[0].startswith("2026-")
    assert row(peek, "SELECT true_deg FROM headings WHERE frame_idx = 7")[0] == -1
    assert row(peek, "SELECT count(*) FROM events")[0] == 6
    assert row(peek, "SELECT value FROM meta WHERE key = 'schema_version'")[0] == "1"
    assert row(peek, "SELECT value FROM summary WHERE key = 'points.count'")[0] == "36"
    missing = [r[0] for r in peek.execute("SELECT idx FROM frames_without_image ORDER BY idx")]
    assert missing == [0, 4, 7]
    assert row(peek, "SELECT count(*) FROM slow_frames")[0] == 9  # 31.25 ms apart in the fixture
    assert row(peek, "SELECT count(*) FROM tracking_not_normal")[0] == 3


def test_cli_peek_with_csv(bundle_copy: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    frames_csv = tmp_path / "frames.csv"
    assert main(["peek", str(bundle_copy), "--csv", str(frames_csv)]) == 0
    out = capsys.readouterr().out
    peek_path = bundle_copy.resolve() / "lab" / "peek.sqlite"
    assert f"wrote {peek_path}" in out
    assert "points" in out and "_about" in out
    with frames_csv.open() as handle:
        rows = list(csv.DictReader(handle))
    assert len(rows) == 10 and rows[2]["blender_y"] == "0.5"
    assert table_counts(peek_path)["frames"] == 10
    # Running again replaces the copy instead of failing or appending.
    assert main(["peek", str(bundle_copy)]) == 0
    assert table_counts(peek_path)["frames"] == 10
