"""The averaged cloud over time (SPEC.md §6, §15 R3): what CurvSurf's app shows, frame by frame.

The accumulator runs over the recording once. Every ``every`` frames (and on the last frame) a snapshot records only
what changed since the previous one: slots emptied by eviction, then slots whose averaged point changed. Every
``full_every`` snapshots a full copy is kept too, so any frame is rebuilt from one full copy plus at most
``full_every - 1`` changes. The result is cached next to the recording, keyed by the settings that shape it.
"""

import hashlib
import logging
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import numpy.typing as npt

from planelab.accumulate import Accumulator, run_frames
from planelab.config import LabConfig, config_rows
from planelab.replay import Replay

log = logging.getLogger(__name__)

Int64Array = npt.NDArray[np.int64]
Float32Array = npt.NDArray[np.float32]
Int32Array = npt.NDArray[np.int32]

FORMAT = "cloud-v1"


@dataclass(slots=True, frozen=True)
class _Packed:
    """Variable-length per-snapshot arrays, concatenated with offsets (so they save to one .npz)."""

    offsets: Int64Array
    slots: Int64Array
    points: Float32Array
    samples: Int32Array

    def item(self, k: int) -> tuple[Int64Array, Float32Array, Int32Array]:
        a, b = self.offsets[k], self.offsets[k + 1]
        return self.slots[a:b], self.points[a:b], self.samples[a:b]


def _pack(items: list[tuple[Int64Array, npt.NDArray[np.floating], Int32Array]]) -> _Packed:
    counts = [len(slots) for slots, _, _ in items]
    offsets = np.concatenate([[0], np.cumsum(counts, dtype=np.int64)]).astype(np.int64)
    if not items or offsets[-1] == 0:
        return _Packed(offsets, np.empty(0, np.int64), np.empty((0, 3), np.float32), np.empty(0, np.int32))
    return _Packed(
        offsets,
        np.concatenate([s for s, _, _ in items]).astype(np.int64),
        np.concatenate([p for _, p, _ in items]).astype(np.float32).reshape(-1, 3),
        np.concatenate([n for _, _, n in items]).astype(np.int32),
    )


@dataclass(slots=True)
class CloudTimeline:
    frames: Int64Array
    """(S,) the frame each snapshot was taken after."""
    full_every: int
    capacity: int
    """Storage slots used by the accumulator (the rebuilt state is indexed by slot)."""
    removed: _Packed
    changed: _Packed
    fulls: _Packed
    """One entry per ``full_every`` snapshots: the whole cloud after that snapshot."""
    _cache_key: int = -1
    _cache: tuple[npt.NDArray[np.bool_], Float32Array, Int32Array] | None = None

    def __len__(self) -> int:
        return int(self.frames.shape[0])

    def at(self, idx: int) -> tuple[Float32Array, Int32Array]:
        """The averaged cloud as it was after frame ``idx``: ``(points (K, 3), samples (K,))``, ARKit axes."""
        k = int(np.searchsorted(self.frames, idx, side="right")) - 1
        if k < 0:
            return np.empty((0, 3), np.float32), np.empty(0, np.int32)
        valid, points, samples = self._state(k)
        return points[valid], samples[valid]

    def _state(self, k: int) -> tuple[npt.NDArray[np.bool_], Float32Array, Int32Array]:
        if self._cache is not None and self._cache_key == k:
            return self._cache
        base = k // self.full_every
        valid = np.zeros(self.capacity, dtype=bool)
        points = np.zeros((self.capacity, 3), dtype=np.float32)
        samples = np.zeros(self.capacity, dtype=np.int32)
        slots, full_points, full_samples = self.fulls.item(base)
        valid[slots], points[slots], samples[slots] = True, full_points, full_samples
        for j in range(base * self.full_every + 1, k + 1):
            valid[self.removed.item(j)[0]] = False
            slots, changed_points, changed_samples = self.changed.item(j)
            valid[slots], points[slots], samples[slots] = True, changed_points, changed_samples
        self._cache_key, self._cache = k, (valid, points, samples)
        return self._cache

    def save(self, path: Path) -> None:
        arrays: dict[str, np.ndarray] = {
            "format": np.array(FORMAT),
            "frames": self.frames,
            "meta": np.array([self.full_every, self.capacity], dtype=np.int64),
        }
        for name in ("removed", "changed", "fulls"):
            packed: _Packed = getattr(self, name)
            for part in ("offsets", "slots", "points", "samples"):
                arrays[f"{name}_{part}"] = getattr(packed, part)
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("wb") as handle:
            np.savez(handle, **arrays)

    @classmethod
    def load(cls, path: Path) -> "CloudTimeline":
        with np.load(path) as data:
            if str(data["format"]) != FORMAT:
                raise ValueError(f"{path.name}: not a {FORMAT} file")
            packs = {
                name: _Packed(*(data[f"{name}_{part}"] for part in ("offsets", "slots", "points", "samples")))
                for name in ("removed", "changed", "fulls")
            }
            full_every, capacity = (int(v) for v in data["meta"])
            return cls(data["frames"], full_every, capacity, packs["removed"], packs["changed"], packs["fulls"])


def build_cloud_timeline(replay: Replay, config: LabConfig, every: int = 6, full_every: int = 50) -> CloudTimeline:
    accumulator = Accumulator(config.accumulate)
    frames: list[int] = []
    removed, changed, fulls = [], [], []
    last = int(replay.idx[-1]) if len(replay) else -1
    for idx, acc in run_frames(replay, config, accumulator):
        if (idx + 1) % every and idx != last:
            continue
        gone, slots, points, samples = acc.take_changes()
        if len(frames) % full_every == 0:
            fulls.append(acc.state())
        frames.append(idx)
        removed.append((gone, np.empty((0, 3)), np.empty(0, np.int32)))
        changed.append((slots, points, samples))
    return CloudTimeline(
        frames=np.array(frames, dtype=np.int64),
        full_every=full_every,
        capacity=accumulator.capacity,
        removed=_pack(removed),
        changed=_pack(changed),
        fulls=_pack(fulls),
    )


def cache_path(bundle: Path, config: LabConfig, every: int = 6, full_every: int = 50) -> Path:
    """``<bundle>/lab/cloud-<hash>.npz``: one file per set of settings that shape the cloud."""
    rows = [(k, v) for k, v in config_rows(config) if k.split(".")[0] in ("filter", "gate", "accumulate")]
    key = f"{FORMAT}|{every}|{full_every}|" + "|".join(f"{k}={v}" for k, v in rows)
    return bundle / "lab" / f"cloud-{hashlib.sha1(key.encode()).hexdigest()[:12]}.npz"


def load_or_build(bundle: Path, replay: Replay, config: LabConfig | None = None) -> CloudTimeline:
    """The cached timeline if there is one, otherwise build it and cache it (when the folder is writable)."""
    settings = config or LabConfig()
    path = cache_path(bundle, settings)
    if path.is_file():
        try:
            return CloudTimeline.load(path)
        except (ValueError, KeyError, OSError) as error:
            log.warning("rebuilding %s: %s", path.name, error)
    timeline = build_cloud_timeline(replay, settings)
    try:
        timeline.save(path)
    except OSError as error:
        log.warning("cloud cache not written: %s", error)
    return timeline
