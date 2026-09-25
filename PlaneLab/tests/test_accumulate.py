"""Stage 4, the accumulator (SPEC.md §18 T16), checked against a line-by-line port of CurvSurf's Swift code."""

import math
from collections import deque
from pathlib import Path

import numpy as np
import pytest

from planelab.accumulate import Accumulator, accumulate
from planelab.config import AccumulateConfig, FilterConfig, GateConfig, LabConfig
from planelab.replay import load_replay
from planelab.session import open_session
from planelab.synth import ID_BASE, SynthParams, build_scene, write_synthetic


class CurvSurfReference:
    """FeatureCompressor.append from ARFeaturePointFindSurface/Utilities/FeatureCompressor.swift, in plain Python."""

    def __init__(self, max_ids: int, max_bin: int, min_samples: int = 5, zscore: float = 2.0) -> None:
        self.max_ids, self.max_bin, self.min_samples, self.zscore = max_ids, max_bin, min_samples, zscore
        self.id_set: set[int] = set()
        self.id_list: deque[int] = deque()
        self.bins: dict[int, deque[tuple[float, float, float]]] = {}
        self.points: dict[int, tuple[float, float, float]] = {}

    def append(self, points: list[tuple[float, float, float]], ids: list[int]) -> None:
        for point, key in zip(points, ids, strict=True):
            if key not in self.id_set:
                self.id_set.add(key)
                if len(self.id_set) > self.max_ids:
                    removed = self.id_list.popleft()
                    self.id_set.discard(removed)
                    self.bins.pop(removed, None)
                    self.points.pop(removed, None)
                self.id_list.append(key)
            bin_ = self.bins.get(key, deque())
            bin_.append(point)
            if len(bin_) > self.max_bin:
                bin_.popleft()
            if len(bin_) >= self.min_samples:
                self.points[key] = self._average(list(bin_))
            self.bins[key] = bin_

    def _average(self, samples: list[tuple[float, float, float]]) -> tuple[float, float, float]:
        n = len(samples)
        mean = [sum(s[c] for s in samples) / n for c in range(3)]
        d2 = [sum((s[c] - mean[c]) ** 2 for c in range(3)) for s in samples]
        variance = sum(d2) / n
        kept = [s for s, d in zip(samples, d2, strict=True) if d <= self.zscore**2 * variance]
        return tuple(sum(s[c] for s in kept) / len(kept) for c in range(3))  # type: ignore[return-value]


def cloud_dict(acc: Accumulator) -> dict[int, np.ndarray]:
    cloud = acc.cloud()
    return dict(zip(cloud.ids.tolist(), cloud.points, strict=True))


def test_matches_curvsurf_on_a_random_stream_with_evictions() -> None:
    rng = np.random.default_rng(3)
    config = AccumulateConfig(max_samples=7, min_samples=5, zscore=2.0, max_ids=40)
    ours = Accumulator(config, chunk=8)
    reference = CurvSurfReference(max_ids=40, max_bin=7)
    for _ in range(300):
        ids = rng.choice(np.arange(1, 80, dtype=np.uint64), size=int(rng.integers(1, 25)), replace=False)
        points = rng.normal(0, 1, size=(len(ids), 3)).astype(np.float32)
        points[rng.random(len(ids)) < 0.1] *= 30  # outliers for the z-score filter
        ours.add(ids, points)
        reference.append([tuple(map(float, p)) for p in points], ids.tolist())
    mine = cloud_dict(ours)
    assert set(mine) == set(reference.points)
    for key, point in reference.points.items():
        assert mine[key] == pytest.approx(point, abs=1e-5)
    assert len(ours) == len(reference.id_set) == 40


def test_needs_min_samples_then_averages() -> None:
    acc = Accumulator(AccumulateConfig(max_samples=10, min_samples=5))
    for i in range(4):
        acc.add(np.array([7], dtype=np.uint64), np.array([[i, 0, 0]], dtype=np.float32))
    assert len(acc.cloud()) == 0 and len(acc) == 1
    acc.add(np.array([7], dtype=np.uint64), np.array([[4, 0, 0]], dtype=np.float32))
    cloud = acc.cloud()
    assert cloud.points[0].tolist() == pytest.approx([2, 0, 0])
    assert (cloud.samples[0], cloud.sightings[0]) == (5, 5)


def test_zscore_drops_a_far_sample() -> None:
    acc = Accumulator(AccumulateConfig(max_samples=20, min_samples=5))
    for x in [0.0] * 9 + [10.0]:
        acc.add(np.array([1], dtype=np.uint64), np.array([[x, 0, 0]], dtype=np.float32))
    cloud = acc.cloud()
    assert cloud.points[0].tolist() == pytest.approx([0, 0, 0])  # 10 m sample is > 2 sigma away
    assert cloud.spread[0] == pytest.approx(0)


def test_fifo_keeps_the_last_max_samples() -> None:
    acc = Accumulator(AccumulateConfig(max_samples=3, min_samples=1))
    for x in (100.0, 1.0, 2.0, 3.0):
        acc.add(np.array([5], dtype=np.uint64), np.array([[x, 0, 0]], dtype=np.float32))
    cloud = acc.cloud()
    assert cloud.points[0][0] == pytest.approx(2.0)
    assert (cloud.samples[0], cloud.sightings[0]) == (3, 4)


def test_eviction_is_by_first_sighting_even_if_seen_recently() -> None:
    acc = Accumulator(AccumulateConfig(max_samples=5, min_samples=1, max_ids=2))
    one = np.zeros((1, 3), dtype=np.float32)
    acc.add(np.array([1], dtype=np.uint64), one)
    acc.add(np.array([2], dtype=np.uint64), one)
    acc.add(np.array([1], dtype=np.uint64), one)  # 1 seen again, but it was first
    evicted = acc.add(np.array([3], dtype=np.uint64), one)
    assert evicted == [1]
    assert sorted(cloud_dict(acc)) == [2, 3]


def test_eviction_inside_one_frame_matches_curvsurf() -> None:
    config = AccumulateConfig(max_samples=5, min_samples=1, max_ids=2)
    ours, reference = Accumulator(config), CurvSurfReference(max_ids=2, max_bin=5, min_samples=1)
    ids = np.array([10, 11, 12, 10, 13], dtype=np.uint64)
    points = np.arange(15, dtype=np.float32).reshape(5, 3)
    ours.add(ids, points)
    reference.append([tuple(map(float, p)) for p in points], ids.tolist())
    mine = cloud_dict(ours)
    assert set(mine) == set(reference.points)
    for key, point in reference.points.items():
        assert mine[key].tolist() == pytest.approx(point)


def test_degenerate_zscore_keeps_every_sample() -> None:
    acc = Accumulator(AccumulateConfig(max_samples=4, min_samples=2, zscore=0.5))
    acc.add(np.array([1], dtype=np.uint64), np.array([[-1, 0, 0]], dtype=np.float32))
    acc.add(np.array([1], dtype=np.uint64), np.array([[1, 0, 0]], dtype=np.float32))
    assert acc.cloud().points[0].tolist() == pytest.approx([0, 0, 0])


def test_empty_frames_are_fine() -> None:
    acc = Accumulator(AccumulateConfig())
    assert acc.add(np.empty(0, dtype=np.uint64), np.empty((0, 3), dtype=np.float32)) == []
    assert len(acc.cloud()) == 0


def test_hundred_thousand_ids_at_hundred_samples_stay_within_the_estimate() -> None:
    """SPEC.md §17.5: about ids x max_samples x 12 bytes, plus less than one growth chunk."""
    config = AccumulateConfig(max_samples=100, min_samples=100, max_ids=100_000)
    chunk = 16_384
    acc = Accumulator(config, chunk=chunk)
    ids = np.arange(100_000, dtype=np.uint64)
    frame = np.zeros((100_000, 3), dtype=np.float32)
    for k in range(100):
        frame[:, 0] = k
        acc.add(ids, frame)
    per_slot = 100 * 3 * 4 + 8 + 4 + 4 + 8 + 24 + 8 + 1
    assert acc.nbytes() <= (100_000 + chunk) * per_slot
    assert acc.nbytes() < 150_000_000
    cloud = acc.cloud()
    assert len(cloud) == 100_000
    assert cloud.points[:, 0] == pytest.approx(np.full(100_000, 49.5))


def test_accumulating_a_synthetic_facade_beats_raw_noise(tmp_path: Path) -> None:
    params = SynthParams(scene="facade", seconds=4, fps=30, noise_m=0.02, ray_noise_per_m=0.0)
    bundle = tmp_path / "facade.planelab"
    write_synthetic(bundle, params)
    truth = build_scene(params).features
    with open_session(bundle) as session:
        replay = load_replay(session)
    config = LabConfig(gate=GateConfig(mode="off"), filter=FilterConfig(near_cut_m=0.25))
    cloud = accumulate(replay, config).cloud()
    assert len(cloud) > 500
    well_seen = cloud.samples >= 50
    error = np.linalg.norm(cloud.points[well_seen] - truth[(cloud.ids[well_seen] - ID_BASE).astype(np.int64)], axis=1)
    raw_error = 0.02 * math.sqrt(3)  # expected length of one noisy sighting's error
    assert np.median(error) < raw_error / 3


def test_accumulate_respects_until_and_tracking(tmp_path: Path) -> None:
    bundle = tmp_path / "room.planelab"
    write_synthetic(bundle, SynthParams(scene="room", seconds=1, fps=20))
    with open_session(bundle) as session:
        replay = load_replay(session)
    few = accumulate(replay, LabConfig(accumulate=AccumulateConfig(min_samples=1)), until_idx=0)
    assert few.cloud().sightings.max() == 1
    limited = replay.__class__(**{**{f: getattr(replay, f) for f in replay.__slots__}, "tracking": replay.tracking * 0})
    skipped = accumulate(limited, LabConfig(filter=FilterConfig(normal_tracking_only=True)))
    assert len(skipped) == 0
