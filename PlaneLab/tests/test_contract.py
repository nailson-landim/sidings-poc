"""The session-format contract, Python side (SPEC.md §3.5, S7): the Swift-written fixture decodes to expected.json."""

import json
from dataclasses import asdict
from typing import Any

import numpy as np
import pytest
from conftest import FIXTURE_BUNDLE, SCHEMA_FILE, V1_FIXTURES, V2_FIXTURES, V3_FIXTURES

from planelab.info import PhoneCloud, RoundCost, X1Surfaces, describe, summarize
from planelab.schema import DDL
from planelab.session import open_session


def column_major(values: list[float], size: int) -> np.ndarray:
    return np.array(values, dtype=np.float32).reshape(size, size).T


def as_points(values: list[list[float]]) -> np.ndarray:
    return np.array(values, dtype=np.float32).reshape(-1, 3)


def test_embedded_ddl_matches_the_canonical_file() -> None:
    assert SCHEMA_FILE.read_text(encoding="utf-8") == DDL


def test_meta(expected: dict[str, Any]) -> None:
    with open_session(FIXTURE_BUNDLE) as session:
        assert session.meta == expected["meta"]


def test_frames(expected: dict[str, Any]) -> None:
    with open_session(FIXTURE_BUNDLE) as session:
        frames = list(session.frames())
    assert [f.idx for f in frames] == [row["idx"] for row in expected["frame"]]
    for frame, row in zip(frames, expected["frame"], strict=True):
        assert frame.t == row["t"]
        assert frame.has_image == bool(row["has_image"])
        assert (frame.tracking, frame.tracking_reason, frame.mapping) == (
            row["tracking"],
            row["tracking_reason"],
            row["mapping"],
        )
        assert np.array_equal(frame.camera, column_major(row["camera"], 4))
        assert np.array_equal(frame.intrinsics, column_major(row["intrinsics"], 3))
        assert frame.exposure_s == row["exposure_s"]
        assert frame.thermal == row["thermal"]
        assert frame.points.shape == (row["point_count"], 3)
        assert np.array_equal(frame.points, as_points(row["points"]))
        assert frame.point_ids.dtype == np.uint64
        assert frame.point_ids.tolist() == row["point_ids"]


def test_camera_translation_is_in_the_last_column() -> None:
    """Guards the column-major -> row-major conversion: translation lands in camera[:3, 3]."""
    with open_session(FIXTURE_BUNDLE) as session:
        frame = session.frame(8)
    assert frame.position.tolist() == [1.0, 1.5, -2.0]


def test_ids_above_2_pow_53_survive() -> None:
    with open_session(FIXTURE_BUNDLE) as session:
        ids = session.frame(9).point_ids.tolist()
    assert ids[0] == 18_000_000_000_000_000_000
    assert ids[1] == 18_000_000_000_000_000_001


def test_plane_anchors(expected: dict[str, Any]) -> None:
    with open_session(FIXTURE_BUNDLE) as session:
        anchors = session.anchors()
    assert len(anchors) == len(expected["plane_anchor"])
    for anchor, row in zip(anchors, expected["plane_anchor"], strict=True):
        assert (anchor.frame_idx, anchor.anchor_id, anchor.event) == (row["frame_idx"], row["anchor_id"], row["event"])
        # NULL columns are left out of expected.json rows (session-format/README.md).
        assert anchor.alignment == row.get("alignment")
        assert anchor.classification == row.get("classification")
        if "transform" in row:
            assert anchor.transform is not None
            assert np.array_equal(anchor.transform, column_major(row["transform"], 4))
            assert anchor.center is not None and anchor.center.tolist() == row["center"]
            assert anchor.extent is not None and anchor.extent.tolist() == row["extent"]
            assert anchor.boundary is not None
            assert np.array_equal(anchor.boundary, as_points(row["boundary"]))
        else:
            assert anchor.transform is anchor.center is anchor.extent is anchor.boundary is None


@pytest.mark.parametrize("table", ["location", "heading", "event"])
def test_small_tables(expected: dict[str, Any], table: str) -> None:
    with open_session(FIXTURE_BUNDLE) as session:
        rows = {"location": session.locations, "heading": session.headings, "event": session.events}[table]()
    assert [asdict(r) for r in rows] == expected[table]


def test_cloud_rows(expected: dict[str, Any]) -> None:
    with open_session(FIXTURE_BUNDLE) as session:
        assert session.schema_version == 4
        rows = session.cloud_rows()
    assert len(rows) == len(expected["cloud"]) == 2
    for row, want in zip(rows, expected["cloud"], strict=True):
        assert (row.frame_idx, row.full) == (want["frame_idx"], bool(want["full"]))
        assert row.removed.dtype == np.uint64 and row.removed.tolist() == want["removed_ids"]
        assert row.ids.tolist() == want["ids"]
        assert np.array_equal(row.points, as_points(want["points"]))
        assert row.samples.tolist() == want["samples"]
    assert rows[1].ids[-1] == 18_000_000_000_000_000_000
    assert rows[1].samples[-1] == 300


def test_version_1_recordings_stay_readable() -> None:
    old = json.loads((V1_FIXTURES / "expected.json").read_text())
    with open_session(V1_FIXTURES / "tiny.planelab") as session:
        assert session.schema_version == 1
        assert session.meta == old["meta"]
        assert [f.idx for f in session.frames()] == [row["idx"] for row in old["frame"]]
        assert session.cloud_rows() == []
    assert "cloud" not in old


def test_info_reports_the_phones_cloud() -> None:
    with open_session(FIXTURE_BUNDLE) as session:
        info = summarize(session)
    assert info.cloud == PhoneCloud(rows=2, points=2, frames_missed=0)
    assert "cloud     phone: 2 averaged points after 2 rows (0 frames missed)" in describe(info)
    with open_session(V1_FIXTURES / "tiny.planelab") as session:
        old = summarize(session)
    assert old.cloud is None and "none recorded (schema v1" in describe(old)


def test_surface_rows(expected: dict[str, Any]) -> None:
    """Experiment X1's tracks (schema v3): NULL geometry on removes, merged_into only on a merge."""
    with open_session(FIXTURE_BUNDLE) as session:
        rows = session.surface_rows()
    assert len(rows) == len(expected["surface"]) == 7
    for row, want in zip(rows, expected["surface"], strict=True):
        assert (row.frame_idx, row.surface_id, row.number, row.event) == (
            want["frame_idx"],
            want["surface_id"],
            want["number"],
            want["event"],
        )
        assert row.state == want.get("state")
        assert row.merged_into == want.get("merged_into")
        assert (row.width_m, row.height_m, row.rms_m, row.inliers) == tuple(
            want.get(k) for k in ("width_m", "height_m", "rms_m", "inliers")
        )
        if "outline" in want:
            assert row.normal is not None and row.normal.tolist() == want["normal"]
            assert row.center is not None and row.center.tolist() == want["center"]
            assert row.outline is not None and np.array_equal(row.outline, as_points(want["outline"]))
        else:
            assert row.normal is row.center is row.outline is None


def test_version_2_recordings_stay_readable() -> None:
    old = json.loads((V2_FIXTURES / "expected.json").read_text())
    with open_session(V2_FIXTURES / "tiny.planelab") as session:
        assert session.schema_version == 2
        assert session.meta == old["meta"]
        assert len(session.cloud_rows()) == len(old["cloud"]) == 2
        assert session.surface_rows() == []
        info = summarize(session)
    assert "surface" not in old
    assert info.x1 is None and "planes    none recorded (before schema v3)" in describe(info)
    assert info.engine is None and info.cost is None


def test_info_reports_x1() -> None:
    with open_session(FIXTURE_BUNDLE) as session:
        info = summarize(session)
    # After frame 9: #2 merged into #1, #3 dropped; #1 is left, stale.
    assert info.x1 == X1Surfaces(rows=7, tracks=3, at_end=1, confirmed_at_end=0, merges=1)
    assert info.engine == "ransac"
    assert "planes    RANSAC: 3 tracks in 7 rows; 1 at the end (0 confirmed), 1 merges" in describe(info)


def test_surface_round_rows(expected: dict[str, Any]) -> None:
    """The engine's per-round cost (schema v4): integers stay integers, booleans decode, reals keep their value."""
    with open_session(FIXTURE_BUNDLE) as session:
        rows = session.surface_round_rows()
    assert len(rows) == len(expected["surface_round"]) == 3
    for row, want in zip(rows, expected["surface_round"], strict=True):
        got = asdict(row)
        got["searched"] = int(got["searched"])
        assert got == want
    assert rows[2].points == 3_000_000_000  # above int32


def test_info_reports_the_cost_of_a_round() -> None:
    with open_session(FIXTURE_BUNDLE) as session:
        info = summarize(session)
    assert info.cost == RoundCost(
        rounds=3,
        median_ms=4.75,
        p95_ms=12.5,
        max_ms=12.5,
        searched=2,
        search_median_ms=7.6875,
        hypotheses_median=68.0,
        skipped=2,
        hot_rounds=1,
    )
    assert (
        "rounds    3 rounds: median 4.8 ms, p95 12.5 ms, max 12.5 ms; 2 searched (median 7.7 ms, 68 hypotheses); "
        "2 skipped, 1 hot"
    ) in describe(info)


def test_version_3_recordings_stay_readable() -> None:
    old = json.loads((V3_FIXTURES / "expected.json").read_text())
    with open_session(V3_FIXTURES / "tiny.planelab") as session:
        assert session.schema_version == 3
        assert session.meta == old["meta"]
        assert len(session.surface_rows()) == len(old["surface"]) == 7
        assert session.surface_round_rows() == []
        info = summarize(session)
    assert "surface_round" not in old
    assert info.engine == "findsurface" and info.cost is None
    assert "planes    FindSurface: 3 tracks" in describe(info)
