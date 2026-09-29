"""The averaged cloud over time (SPEC.md §6, §15 R3): what CurvSurf's app shows, frame by frame.

The accumulator runs over the recording once. Every ``every`` frames (and on the last frame) a snapshot records only
what changed since the previous one: slots emptied by eviction, then slots whose averaged point changed. Every
``full_every`` snapshots a full copy is kept too, so any frame is rebuilt from one full copy plus at most
``full_every - 1`` changes. The result is cached next to the recording, keyed by the settings that shape it.

A schema v2 recording also holds the phone's own cloud (``cloud`` rows, SPEC.md L12, P23). ``recorded_timeline``
turns those rows into the same ``CloudTimeline``, so Blender shows either one the same way.
"""

import hashlib
import logging
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import numpy.typing as npt

from planelab.accumulate import Accumulator, run_frames
from planelab.config import LabConfig, config_from_meta, config_rows
from planelab.replay import Replay
from planelab.session import CloudRow, Session

log = logging.getLogger(__name__)

Int64Array = npt.NDArray[np.int64]
Float32Array = npt.NDArray[np.float32]
Int32Array = npt.NDArray[np.int32]
UInt64Array = npt.NDArray[np.uint64]

FORMAT = "cloud-v2"
"""v2 stores which snapshots have a full copy (``full_rows``); v1 caches are rebuilt."""


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
    full_rows: Int64Array
    """Ascending snapshot positions that have a full copy; the first is 0."""
    capacity: int
    """Storage slots (the rebuilt state is indexed by slot: an accumulator slot, or an id's rank for the phone's)."""
    removed: _Packed
    changed: _Packed
    fulls: _Packed
    """One entry per ``full_rows`` position: the whole cloud after that snapshot."""
    slot_ids: UInt64Array | None = None
    """The phone's timeline: the feature id of each slot (ascending). None for the Mac's (slots are storage)."""
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

    def ids_at(self, idx: int) -> tuple[UInt64Array, Float32Array, Int32Array]:
        """Like ``at``, with each point's feature id, ascending. Only the phone's timeline knows the ids."""
        if self.slot_ids is None:
            raise ValueError("this timeline has no feature ids (it was built on the Mac)")
        k = int(np.searchsorted(self.frames, idx, side="right")) - 1
        if k < 0:
            return np.empty(0, np.uint64), np.empty((0, 3), np.float32), np.empty(0, np.int32)
        valid, points, samples = self._state(k)
        return self.slot_ids[valid], points[valid], samples[valid]

    def _state(self, k: int) -> tuple[npt.NDArray[np.bool_], Float32Array, Int32Array]:
        if self._cache is not None and self._cache_key == k:
            return self._cache
        which = int(np.searchsorted(self.full_rows, k, side="right")) - 1
        start = int(self.full_rows[which])
        valid = np.zeros(self.capacity, dtype=bool)
        points = np.zeros((self.capacity, 3), dtype=np.float32)
        samples = np.zeros(self.capacity, dtype=np.int32)
        slots, full_points, full_samples = self.fulls.item(which)
        valid[slots], points[slots], samples[slots] = True, full_points, full_samples
        for j in range(start + 1, k + 1):
            valid[self.removed.item(j)[0]] = False
            slots, changed_points, changed_samples = self.changed.item(j)
            valid[slots], points[slots], samples[slots] = True, changed_points, changed_samples
        self._cache_key, self._cache = k, (valid, points, samples)
        return self._cache

    def save(self, path: Path) -> None:
        arrays: dict[str, np.ndarray] = {
            "format": np.array(FORMAT),
            "frames": self.frames,
            "full_rows": self.full_rows,
            "capacity": np.array(self.capacity, dtype=np.int64),
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
            return cls(
                data["frames"],
                data["full_rows"],
                int(data["capacity"]),
                packs["removed"],
                packs["changed"],
                packs["fulls"],
            )


def build_cloud_timeline(replay: Replay, config: LabConfig, every: int = 6, full_every: int = 50) -> CloudTimeline:
    accumulator = Accumulator(config.accumulate)
    frames: list[int] = []
    full_rows: list[int] = []
    removed, changed, fulls = [], [], []
    last = int(replay.idx[-1]) if len(replay) else -1
    for idx, acc in run_frames(replay, config, accumulator):
        if (idx + 1) % every and idx != last:
            continue
        gone, slots, points, samples = acc.take_changes()
        if len(frames) % full_every == 0:
            full_rows.append(len(frames))
            fulls.append(acc.state())
        frames.append(idx)
        removed.append((gone, np.empty((0, 3)), np.empty(0, np.int32)))
        changed.append((slots, points, samples))
    return CloudTimeline(
        frames=np.array(frames, dtype=np.int64),
        full_rows=np.array(full_rows or [0], dtype=np.int64),
        capacity=accumulator.capacity,
        removed=_pack(removed),
        changed=_pack(changed),
        fulls=_pack(fulls),
    )


def recorded_timeline(rows: list[CloudRow]) -> CloudTimeline:
    """The phone's cloud rows as a timeline. Ids become slots by rank; a first row that isn't full starts from empty."""
    every_id = [r.ids for r in rows] + [r.removed for r in rows]
    ids = np.unique(np.concatenate(every_id)) if rows else np.empty(0, np.uint64)
    empty = (np.empty(0, np.int64), np.empty((0, 3), np.float32), np.empty(0, np.int32))
    removed, changed, fulls, full_rows = [], [], [], []
    for k, row in enumerate(rows):
        entry = (np.searchsorted(ids, row.ids).astype(np.int64), row.points, row.samples.astype(np.int32))
        if row.full or k == 0:
            full_rows.append(k)
            fulls.append(entry)
            removed.append(empty)
            changed.append(empty)
        else:
            removed.append((np.searchsorted(ids, row.removed).astype(np.int64), *empty[1:]))
            changed.append(entry)
    return CloudTimeline(
        frames=np.array([r.frame_idx for r in rows], dtype=np.int64),
        full_rows=np.array(full_rows or [0], dtype=np.int64),
        capacity=len(ids),
        removed=_pack(removed),
        changed=_pack(changed),
        fulls=_pack(fulls),
        slot_ids=ids.astype(np.uint64),
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


PHONE = "phone"
MAC = "mac"


def session_cloud(session: Session, replay: Replay) -> tuple[CloudTimeline, str]:
    """What Blender shows (SPEC.md T30): the phone's recorded cloud when the session has one, otherwise the Mac's
    recompute with the recording's own settings. Returns the timeline and ``"phone"`` or ``"mac"``.
    """
    rows = session.cloud_rows()
    if rows:
        return recorded_timeline(rows), PHONE
    return load_or_build(session.bundle, replay, config_from_meta(session.meta)), MAC


@dataclass(slots=True, frozen=True)
class CloudComparison:
    """The phone's recorded cloud against the Mac's recompute of the same frames (SPEC.md T30)."""

    rows: int
    matching_rows: int
    """Rows whose ids and sample counts equal the recompute's after the same frame."""
    first_mismatch_frame: int | None
    max_position_diff_m: float
    """Largest position difference over the matching rows (float32 rounding is about 1e-6 m at 10 m)."""
    phone_points: int
    mac_points: int
    """Averaged points after the last row, on each side."""

    @property
    def equal(self) -> bool:
        return self.rows == self.matching_rows


def compare_recorded(replay: Replay, rows: list[CloudRow], config: LabConfig) -> CloudComparison:
    """Replays the recording through the Mac's accumulator and compares it with every recorded row."""
    timeline = recorded_timeline(rows)
    wanted = {row.frame_idx for row in rows}
    matching, first, worst = 0, None, 0.0
    phone_points = mac_points = 0
    for idx, accumulator in run_frames(replay, config, Accumulator(config.accumulate)):
        if idx not in wanted:
            continue
        cloud = accumulator.cloud()
        order = np.argsort(cloud.ids)
        ids, points, samples = timeline.ids_at(idx)
        phone_points, mac_points = len(ids), len(cloud)
        if np.array_equal(ids, cloud.ids[order]) and np.array_equal(samples, cloud.samples[order]):
            matching += 1
            if len(ids):
                diff = np.abs(points.astype(np.float64) - cloud.points[order]).max()
                worst = max(worst, float(diff))
        elif first is None:
            first = idx
    return CloudComparison(len(rows), matching, first, worst, phone_points, mac_points)


def describe_comparison(result: CloudComparison) -> str:
    if result.rows == 0:
        return "check     no phone cloud to compare"
    verdict = "equal" if result.equal else f"DIFFERENT from frame {result.first_mismatch_frame}"
    return (
        f"check     phone vs Mac recompute: {verdict} ({result.matching_rows}/{result.rows} rows match, "
        f"largest position difference {result.max_position_diff_m * 1000:.4f} mm; "
        f"{result.phone_points} vs {result.mac_points} points at the end)"
    )
