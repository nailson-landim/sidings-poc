"""The session-format contract, Python side (SPEC.md §3.5, S7): the Swift-written fixture decodes to expected.json."""

from dataclasses import asdict
from typing import Any

import numpy as np
import pytest
from conftest import FIXTURE_BUNDLE, SCHEMA_FILE

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
