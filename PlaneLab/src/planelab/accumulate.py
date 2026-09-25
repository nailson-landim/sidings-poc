"""Stage 4 (SPEC.md §5.1): CurvSurf's per-feature averaging, on numpy ring buffers.

Same rules as ``FeatureCompressor`` (``ARFeaturePointFindSurface/Utilities/FeatureCompressor.swift``):

* Each feature id keeps a FIFO of its last ``max_samples`` sightings.
* Once it holds ``min_samples`` (CurvSurf hard-codes 5), the samples farther from their mean than
  ``zscore · sigma`` are dropped, where ``sigma² = mean squared distance to the mean``, and the averaged point is the
  mean of the rest. It's recomputed on every new sighting.
* Beyond ``max_ids`` ids, the oldest by *first* sighting is evicted with its samples and averaged point, even if it
  was seen a moment ago.

Storage is preallocated per slot and grows in fixed chunks, so memory stays close to
``ids x max_samples x 12 bytes`` (SPEC.md §17.5). One frame is assumed to report each id once, as ARKit's
``rawFeaturePoints`` does.
"""

from collections import deque
from collections.abc import Iterator
from dataclasses import dataclass

import numpy as np
import numpy.typing as npt

from planelab.config import AccumulateConfig, LabConfig
from planelab.gate import FrameGate, ParallaxGate, keep_points
from planelab.replay import Replay

FloatArray = npt.NDArray[np.floating]
UInt64Array = npt.NDArray[np.uint64]

TRACKING_NORMAL = 2


@dataclass(slots=True, frozen=True)
class Cloud:
    """The averaged points that exist right now."""

    ids: UInt64Array
    points: npt.NDArray[np.float64]
    """(K, 3) averaged positions."""
    samples: npt.NDArray[np.int32]
    """(K,) samples currently in each FIFO."""
    sightings: npt.NDArray[np.int64]
    """(K,) samples ever added for the id."""
    spread: npt.NDArray[np.float64]
    """(K,) RMS distance of the kept samples from the averaged point."""

    def __len__(self) -> int:
        return int(self.ids.shape[0])


class Accumulator:
    def __init__(self, config: AccumulateConfig, chunk: int = 16_384) -> None:
        self.config = config
        self._chunk = chunk
        self._slot: dict[int, int] = {}
        self._order: deque[int] = deque()
        self._free: list[int] = []
        self._next = 0
        s = config.max_samples
        self._ids = np.zeros(0, dtype=np.uint64)
        self._samples = np.zeros((0, s, 3), dtype=np.float32)
        self._count = np.zeros(0, dtype=np.int32)
        self._head = np.zeros(0, dtype=np.int32)
        self._sightings = np.zeros(0, dtype=np.int64)
        self._mean = np.zeros((0, 3), dtype=np.float64)
        self._spread = np.zeros(0, dtype=np.float64)
        self._has_mean = np.zeros(0, dtype=bool)
        # Slots whose averaged point changed, and slots emptied by eviction, since the last take_changes().
        self._changed: set[int] = set()
        self._removed: set[int] = set()

    def __len__(self) -> int:
        """Ids tracked, averaged or not."""
        return len(self._slot)

    @property
    def capacity(self) -> int:
        return int(self._ids.shape[0])

    def nbytes(self) -> int:
        arrays = (self._ids, self._samples, self._count, self._head, self._sightings, self._mean, self._spread)
        return sum(a.nbytes for a in arrays) + self._has_mean.nbytes

    def _grow(self) -> None:
        extra = self._chunk
        self._ids = np.concatenate([self._ids, np.zeros(extra, dtype=np.uint64)])
        self._samples = np.concatenate([self._samples, np.zeros((extra, self.config.max_samples, 3), dtype=np.float32)])
        self._count = np.concatenate([self._count, np.zeros(extra, dtype=np.int32)])
        self._head = np.concatenate([self._head, np.zeros(extra, dtype=np.int32)])
        self._sightings = np.concatenate([self._sightings, np.zeros(extra, dtype=np.int64)])
        self._mean = np.concatenate([self._mean, np.zeros((extra, 3))])
        self._spread = np.concatenate([self._spread, np.zeros(extra)])
        self._has_mean = np.concatenate([self._has_mean, np.zeros(extra, dtype=bool)])

    def _insert(self, key: int, evicted: list[tuple[int, int]]) -> int:
        if len(self._slot) >= self.config.max_ids:
            oldest = self._order.popleft()
            slot = self._slot.pop(oldest)
            self._count[slot] = self._head[slot] = self._sightings[slot] = 0
            self._has_mean[slot] = False
            self._free.append(slot)
            self._changed.discard(slot)
            self._removed.add(slot)
            evicted.append((oldest, slot))
        if self._free:
            slot = self._free.pop()
        else:
            if self._next == self.capacity:
                self._grow()
            slot = self._next
            self._next += 1
        self._ids[slot] = key
        self._slot[key] = slot
        self._order.append(key)
        return slot

    def add(self, ids: UInt64Array, points: FloatArray) -> list[int]:
        """Adds one frame's sightings. Returns the ids evicted to make room."""
        keys = np.asarray(ids).tolist()
        if not keys:
            return []
        slots = np.empty(len(keys), dtype=np.int64)
        evicted: list[tuple[int, int]] = []
        for i, key in enumerate(keys):
            slot = self._slot.get(key)
            slots[i] = self._insert(key, evicted) if slot is None else slot
        valid = np.ones(len(keys), dtype=bool)
        for _, slot in evicted:
            # A slot evicted later in this frame drops what this frame wrote to it earlier (as CurvSurf's
            # sequential loop would): that id's whole bin is gone. The slot's new owner starts empty.
            reused_at = np.flatnonzero(slots == slot)
            owner = self._slot.get(int(self._ids[slot]))
            valid[reused_at[:-1] if owner == slot else reused_at] = False
        slots, xyz = slots[valid], np.asarray(points, dtype=np.float32)[valid]

        heads = self._head[slots]
        self._samples[slots, heads] = xyz
        s = self.config.max_samples
        self._head[slots] = (heads + 1) % s
        self._count[slots] = np.minimum(self._count[slots] + 1, s)
        self._sightings[slots] += 1
        self._refresh(slots[self._count[slots] >= self.config.min_samples])
        return [key for key, _ in evicted]

    def _refresh(self, slots: npt.NDArray[np.int64]) -> None:
        """Recomputes the averaged points of ``slots`` with CurvSurf's z-score filter (in float64, like CurvSurf)."""
        if not len(slots):
            return
        samples = self._samples[slots].astype(np.float64)
        count = self._count[slots]
        valid = np.arange(self.config.max_samples)[None, :] < count[:, None]
        mean = np.einsum("ksc,ks->kc", samples, valid) / count[:, None]
        distance_sq = np.sum((samples - mean[:, None, :]) ** 2, axis=2)
        variance = np.sum(distance_sq * valid, axis=1) / count
        keep = valid & (distance_sq <= (self.config.zscore**2) * variance[:, None])
        # A z-score below 1 can reject every sample (CurvSurf would average nothing, giving NaN); keep them all then.
        empty = ~keep.any(axis=1)
        keep[empty] = valid[empty]
        kept = keep.sum(axis=1)
        mean = np.einsum("ksc,ks->kc", samples, keep) / kept[:, None]
        residual_sq = np.sum((samples - mean[:, None, :]) ** 2, axis=2)
        self._mean[slots] = mean
        self._spread[slots] = np.sqrt(np.sum(residual_sq * keep, axis=1) / kept)
        self._has_mean[slots] = True
        self._changed.update(slots.tolist())

    def _live_slots(self) -> npt.NDArray[np.int64]:
        used = np.zeros(self.capacity, dtype=bool)
        used[list(self._slot.values())] = True
        return np.flatnonzero(used & self._has_mean)

    def state(self) -> tuple[npt.NDArray[np.int64], npt.NDArray[np.float64], npt.NDArray[np.int32]]:
        """``(slots, points, samples)`` of every averaged point, keyed by storage slot (for change tracking)."""
        slots = self._live_slots()
        return slots, self._mean[slots].copy(), self._count[slots].copy()

    def take_changes(
        self,
    ) -> tuple[npt.NDArray[np.int64], npt.NDArray[np.int64], npt.NDArray[np.float64], npt.NDArray[np.int32]]:
        """``(removed, changed, points, samples)`` since the last call: slots to clear first, then slots to set."""
        removed = np.array(sorted(self._removed), dtype=np.int64)
        changed = np.array(sorted(self._changed), dtype=np.int64)
        self._removed.clear()
        self._changed.clear()
        return removed, changed, self._mean[changed].copy(), self._count[changed].copy()

    def cloud(self) -> Cloud:
        slots = self._live_slots()
        return Cloud(
            ids=self._ids[slots].copy(),
            points=self._mean[slots].copy(),
            samples=self._count[slots].copy(),
            sightings=self._sightings[slots].copy(),
            spread=self._spread[slots].copy(),
        )


def accumulate(replay: Replay, config: LabConfig, until_idx: int | None = None) -> Accumulator:
    """Stages 2 to 4 over a recording (or up to ``until_idx``): filter, gate, accumulate."""
    accumulator = Accumulator(config.accumulate)
    for idx, _ in run_frames(replay, config, accumulator):
        if until_idx is not None and idx >= until_idx:
            break
    return accumulator


def run_frames(replay: Replay, config: LabConfig, accumulator: Accumulator) -> Iterator[tuple[int, Accumulator]]:
    """Feeds the recording frame by frame, yielding ``(idx, accumulator)`` after each frame (gated out or not)."""
    frame_gate = FrameGate(config.gate)
    parallax = ParallaxGate(config.gate) if config.gate.mode == "parallax" else None
    for row, idx in enumerate(replay.idx.tolist()):
        camera = replay.cameras[row]
        skip = config.filter.normal_tracking_only and replay.tracking[row] != TRACKING_NORMAL
        if skip or not frame_gate.accept(camera):
            yield idx, accumulator
            continue
        start, end = replay.offsets[row], replay.offsets[row + 1]
        points, ids = replay.points[start:end], replay.point_ids[start:end]
        keep = keep_points(camera[:3, 3], points, config.filter)
        points, ids = points[keep], ids[keep]
        if parallax is not None:
            chosen = parallax.select(camera[:3, 3], ids, points)
            points, ids = points[chosen], ids[chosen]
        evicted = accumulator.add(ids, points)
        if parallax is not None and evicted:
            parallax.forget(evicted)
        yield idx, accumulator
