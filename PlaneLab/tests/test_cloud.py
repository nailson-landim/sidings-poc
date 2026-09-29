"""The averaged cloud over time (planelab.cloud), checked against a fresh accumulation at every snapshot."""

from pathlib import Path

import numpy as np
import pytest
from conftest import FIXTURE_BUNDLE, RECORDED_BUNDLE

from planelab.accumulate import accumulate
from planelab.cloud import (
    CloudTimeline,
    build_cloud_timeline,
    cache_path,
    compare_recorded,
    describe_comparison,
    load_or_build,
    recorded_timeline,
    session_cloud,
)
from planelab.config import AccumulateConfig, FitConfig, GateConfig, LabConfig, config_from_meta
from planelab.replay import Replay, load_replay
from planelab.session import CloudRow, open_session
from planelab.synth import SynthParams, write_synthetic


@pytest.fixture(scope="module")
def room(tmp_path_factory: pytest.TempPathFactory) -> tuple[Path, Replay]:
    bundle = tmp_path_factory.mktemp("cloud") / "room.planelab"
    write_synthetic(bundle, SynthParams(scene="room", seconds=2, fps=30))
    with open_session(bundle) as session:
        return bundle, load_replay(session)


def ordered(points: np.ndarray, samples: np.ndarray) -> np.ndarray:
    """Rows sorted by position. The timeline stores float32, so both sides are rounded to it before sorting."""
    table = np.column_stack([points.astype(np.float32).astype(np.float64), samples])
    return table[np.lexsort(table.T[::-1])]


@pytest.mark.parametrize(
    "config",
    [
        LabConfig(),
        # Few ids and frequent full copies: evictions (removals) and full snapshots both get exercised.
        LabConfig(accumulate=AccumulateConfig(max_ids=60, min_samples=3)),
    ],
)
def test_every_snapshot_equals_a_fresh_accumulation(room: tuple[Path, Replay], config: LabConfig) -> None:
    _, replay = room
    timeline = build_cloud_timeline(replay, config, every=6, full_every=3)
    assert timeline.frames.tolist() == list(range(5, 60, 6))  # 60 frames: the last one is a regular snapshot
    for frame in timeline.frames.tolist():
        cloud = accumulate(replay, config, until_idx=frame).cloud()
        points, samples = timeline.at(frame)
        assert np.allclose(ordered(points, samples), ordered(cloud.points, cloud.samples), atol=1e-5), frame


def test_between_and_before_snapshots(room: tuple[Path, Replay]) -> None:
    _, replay = room
    timeline = build_cloud_timeline(replay, LabConfig(accumulate=AccumulateConfig(min_samples=1)), every=6)
    assert len(timeline.at(4)[0]) == 0  # before the first snapshot (after frame 5)
    at_5, at_8 = timeline.at(5), timeline.at(8)
    assert np.array_equal(at_5[0], at_8[0]) and np.array_equal(at_5[1], at_8[1])
    assert len(timeline.at(11)[0]) >= len(at_5[0])
    assert len(timeline) == 10


def test_save_load_and_the_cache(room: tuple[Path, Replay], tmp_path: Path) -> None:
    bundle, replay = room
    config = LabConfig()
    timeline = build_cloud_timeline(replay, config)
    path = tmp_path / "cloud.npz"
    timeline.save(path)
    loaded = CloudTimeline.load(path)
    for frame in (5, 29, 59):
        a, b = timeline.at(frame), loaded.at(frame)
        assert np.array_equal(a[0], b[0]) and np.array_equal(a[1], b[1])

    cached = cache_path(bundle, config)
    cached.unlink(missing_ok=True)
    first = load_or_build(bundle, replay)
    assert cached.is_file()
    stamp = cached.stat().st_mtime_ns
    second = load_or_build(bundle, replay)
    assert cached.stat().st_mtime_ns == stamp  # loaded, not rebuilt
    assert np.array_equal(first.at(59)[0], second.at(59)[0])

    cached.write_bytes(b"not an npz")
    rebuilt = load_or_build(bundle, replay)
    assert np.array_equal(rebuilt.at(59)[0], first.at(59)[0])


def test_cache_key_follows_only_the_settings_that_shape_the_cloud(tmp_path: Path) -> None:
    base = cache_path(tmp_path, LabConfig())
    assert cache_path(tmp_path, LabConfig(fit=FitConfig(min_inliers=10))) == base
    assert cache_path(tmp_path, LabConfig(gate=GateConfig(mode="intended"))) != base


def test_the_last_frame_is_always_a_snapshot(room: tuple[Path, Replay]) -> None:
    _, replay = room
    cut = 58
    short = Replay(
        **{
            **{f: getattr(replay, f) for f in replay.__slots__},
            "idx": replay.idx[:cut],
            "offsets": replay.offsets[: cut + 1],
        }
    )
    timeline = build_cloud_timeline(short, LabConfig())
    assert timeline.frames.tolist() == [*range(5, 54, 6), 57]


def test_empty_replay_gives_an_empty_timeline(room: tuple[Path, Replay]) -> None:
    _, replay = room
    empty = Replay(**{**{f: getattr(replay, f) for f in replay.__slots__}, "idx": replay.idx[:0]})
    timeline = build_cloud_timeline(empty, LabConfig())
    assert len(timeline) == 0 and len(timeline.at(10)[0]) == 0


def test_the_phones_rows_rebuild_the_recorded_cloud() -> None:
    with open_session(FIXTURE_BUNDLE) as session:
        timeline = recorded_timeline(session.cloud_rows())
    a, b, big = 2 << 40, 2 << 40 | 1, 18_000_000_000_000_000_000
    assert timeline.frames.tolist() == [5, 9]
    assert timeline.slot_ids is not None and timeline.slot_ids.tolist() == [a, b, big]
    assert len(timeline.at(4)[0]) == 0
    for frame in (5, 8):
        ids, points, samples = timeline.ids_at(frame)
        assert ids.tolist() == [a, b] and samples.tolist() == [5, 6]
        assert points.tolist() == [[2.0, 1.25, -4.0], [2.5, 1.125, -4.125]]
    ids, points, samples = timeline.ids_at(9)
    assert ids.tolist() == [b, big] and samples.tolist() == [7, 300]
    assert points.tolist() == [[2.5, 1.0625, -4.25], [9.0, 1.25, -5.75]]


def test_recorded_rows_from_a_first_delta_row_and_no_rows() -> None:
    row = CloudRow(
        frame_idx=5,
        full=False,
        removed=np.array([7], dtype=np.uint64),
        ids=np.array([3], dtype=np.uint64),
        points=np.ones((1, 3), dtype=np.float32),
        samples=np.array([5], dtype=np.uint16),
    )
    ids, _, samples = recorded_timeline([row]).ids_at(5)
    assert ids.tolist() == [3] and samples.tolist() == [5]
    empty = recorded_timeline([])
    assert len(empty) == 0 and len(empty.at(3)[0]) == 0


def test_a_mac_timeline_has_no_ids(room: tuple[Path, Replay]) -> None:
    _, replay = room
    timeline = build_cloud_timeline(replay, LabConfig())
    assert timeline.slot_ids is None
    with pytest.raises(ValueError, match="no feature ids"):
        timeline.ids_at(59)


def test_the_phones_recorded_cloud_equals_the_mac_recompute() -> None:
    with open_session(RECORDED_BUNDLE) as session:
        replay = load_replay(session)
        rows = session.cloud_rows()
        config = config_from_meta(session.meta)
        timeline, source = session_cloud(session, replay)
    assert source == "phone" and len(timeline) == len(rows) == 5
    assert config.accumulate == AccumulateConfig(max_samples=4, min_samples=3, zscore=1.2, max_ids=50)
    result = compare_recorded(replay, rows, config)
    assert result.equal and result.first_mismatch_frame is None
    assert result.max_position_diff_m < 2e-6
    assert result.phone_points == result.mac_points == 18
    assert "equal (5/5 rows match" in describe_comparison(result)
    # With the default settings instead of the phone's, the recompute is a different cloud.
    assert not compare_recorded(replay, rows, LabConfig()).equal


def test_a_mismatch_and_nothing_to_compare_are_reported() -> None:
    with open_session(FIXTURE_BUNDLE) as session:
        replay = load_replay(session)
        result = compare_recorded(replay, session.cloud_rows(), config_from_meta(session.meta))
    assert not result.equal and result.first_mismatch_frame == 5
    assert "DIFFERENT from frame 5" in describe_comparison(result)
    assert describe_comparison(compare_recorded(replay, [], LabConfig())) == "check     no phone cloud to compare"


def test_without_rows_blender_gets_the_mac_recompute(room: tuple[Path, Replay]) -> None:
    bundle, replay = room
    with open_session(bundle) as session:
        timeline, source = session_cloud(session, replay)
    assert source == "mac" and timeline.slot_ids is None
