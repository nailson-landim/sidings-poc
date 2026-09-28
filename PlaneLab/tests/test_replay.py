"""planelab.replay: the packed arrays behind the Blender timeline."""

import sqlite3
from pathlib import Path

import numpy as np
from conftest import FIXTURE_BUNDLE

from planelab.replay import load_replay
from planelab.session import open_session


def test_fixture_replay() -> None:
    with open_session(FIXTURE_BUNDLE) as session:
        replay = load_replay(session)
        frames = list(session.frames())
    assert len(replay) == 10
    assert replay.idx.tolist() == list(range(10))
    assert (replay.width, replay.height, replay.fps, replay.first_image) == (256, 192, 32, 1)
    assert replay.has_image.tolist() == [f.has_image for f in frames]
    assert replay.offsets[-1] == replay.points.shape[0] == 36
    for frame in frames:
        assert np.array_equal(replay.points_at(frame.idx), frame.points)
        assert np.array_equal(replay.cameras[frame.idx], frame.camera)
        assert np.array_equal(replay.intrinsics[frame.idx], frame.intrinsics)
    assert replay.points_at(0).shape == (0, 3)
    assert replay.points_at(99).shape == (0, 3)
    assert replay.row(-1) is None


def test_empty_session_defaults(bundle_copy: Path) -> None:
    with sqlite3.connect(bundle_copy / "session.sqlite") as db:
        db.execute("DELETE FROM frame")
        db.execute("DELETE FROM meta WHERE key IN ('video_width', 'video_height')")
    with open_session(bundle_copy) as session:
        replay = load_replay(session)
    assert len(replay) == 0
    assert replay.points.shape == (0, 3)
    assert (replay.width, replay.height, replay.fps, replay.first_image) == (1920, 1440, 60, None)
