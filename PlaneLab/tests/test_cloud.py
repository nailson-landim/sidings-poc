"""The averaged cloud over time (planelab.cloud), checked against a fresh accumulation at every snapshot."""

from pathlib import Path

import numpy as np
import pytest

from planelab.accumulate import accumulate
from planelab.cloud import CloudTimeline, build_cloud_timeline, cache_path, load_or_build
from planelab.config import AccumulateConfig, FitConfig, GateConfig, LabConfig
from planelab.replay import Replay, load_replay
from planelab.session import open_session
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
