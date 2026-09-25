"""Picking one feature point in Blender (SPEC.md §6, §17.4 P27): which drawn point is nearest the mouse, and what the
recording says about that feature at a frame. Pure numpy, so it's tested outside Blender.

A feature is its ARKit id: the raw point and the averaged point of the same id are the same feature, so a pick on
either shows both. Only the phone's recorded cloud knows its ids; a Mac recompute's averaged points can't be picked.
"""

from dataclasses import dataclass

import numpy as np
import numpy.typing as npt

from planelab.axes import points_to_blender
from planelab.cloud import CloudTimeline
from planelab.replay import Replay

FloatArray = npt.NDArray[np.float64]

PICK_RADIUS_PX = 20.0
"""How far from a drawn point, in viewport pixels, a click still picks it."""


def nearest_on_screen(
    points: npt.ArrayLike,
    view_projection: npt.ArrayLike,
    width: int,
    height: int,
    mouse: tuple[float, float],
    radius_px: float = PICK_RADIUS_PX,
) -> int | None:
    """Index of the point drawn nearest to ``mouse`` within ``radius_px``, or None.

    ``view_projection`` is the view's (4, 4) matrix from world to clip space (Blender's
    ``RegionView3D.perspective_matrix``), ``points`` are (N, 3) in that world, and ``mouse`` is in region pixels with
    the origin at the bottom left. Points behind the eye are skipped; of two equally near, the one in front wins.
    """
    xyz = np.asarray(points, dtype=np.float64).reshape(-1, 3)
    clip = np.column_stack([xyz, np.ones(len(xyz))]) @ np.asarray(view_projection, dtype=np.float64).T
    front = np.flatnonzero(clip[:, 3] > 1e-9)
    if not len(front):
        return None
    ndc = clip[front, :3] / clip[front, 3:4]
    screen = (ndc[:, :2] + 1.0) / 2.0 * np.array([width, height], dtype=np.float64)
    gap = np.hypot(screen[:, 0] - mouse[0], screen[:, 1] - mouse[1])
    near = np.flatnonzero(gap <= radius_px)
    if not len(near):
        return None
    best = near[np.lexsort((ndc[near, 2], gap[near]))[0]]
    return int(front[best])


@dataclass(slots=True, frozen=True)
class FeatureAt:
    """One feature at one frame, ARKit axes."""

    raw: FloatArray | None
    """The raw point this frame reported for the id, or None."""
    averaged: FloatArray | None
    """The averaged point after this frame, or None (not in the cloud yet, removed, or the cloud has no ids)."""
    samples: int | None
    """Samples in the averaged point's FIFO."""
    camera: FloatArray | None
    """The recorded camera's position at this frame, or None when the frame wasn't logged."""

    @property
    def shown(self) -> FloatArray | None:
        """Where the pick marker goes: the averaged point when there is one, else the raw one."""
        return self.averaged if self.averaged is not None else self.raw

    @property
    def distance(self) -> float | None:
        """Metres from the recorded camera to the shown point."""
        if self.shown is None or self.camera is None:
            return None
        return float(np.linalg.norm(self.shown - self.camera))

    @property
    def offset(self) -> float | None:
        """Metres between the raw and the averaged point, when both exist."""
        if self.raw is None or self.averaged is None:
            return None
        return float(np.linalg.norm(self.raw - self.averaged))


def feature_at(replay: Replay, cloud: CloudTimeline, feature_id: int, idx: int) -> FeatureAt:
    """The raw and averaged points of ``feature_id`` at frame ``idx``. Cheap enough for the frame handler."""
    hits = np.flatnonzero(replay.ids_at(idx) == np.uint64(feature_id))
    raw = replay.points_at(idx)[hits[0]].astype(np.float64) if len(hits) else None
    averaged: FloatArray | None = None
    samples: int | None = None
    if cloud.slot_ids is not None:
        found = cloud.point(idx, feature_id)
        if found is not None:
            averaged, samples = found[0].astype(np.float64), found[1]
    row = replay.row(idx)
    camera = replay.cameras[row, :3, 3].copy() if row is not None else None
    return FeatureAt(raw=raw, averaged=averaged, samples=samples, camera=camera)


@dataclass(slots=True, frozen=True)
class FeatureReport:
    """What the Plane Lab panel shows about a picked feature."""

    feature_id: int
    idx: int
    at: FeatureAt
    cloud_has_ids: bool
    first_idx: int | None
    """First frame whose raw points carry the id."""
    last_idx: int | None
    frames_seen: int


def feature_report(replay: Replay, cloud: CloudTimeline, feature_id: int, idx: int) -> FeatureReport:
    positions = np.flatnonzero(replay.point_ids == np.uint64(feature_id))
    frames = replay.idx[np.searchsorted(replay.offsets, positions, side="right") - 1]
    return FeatureReport(
        feature_id=feature_id,
        idx=idx,
        at=feature_at(replay, cloud, feature_id, idx),
        cloud_has_ids=cloud.slot_ids is not None,
        first_idx=int(frames[0]) if len(frames) else None,
        last_idx=int(frames[-1]) if len(frames) else None,
        frames_seen=len(frames),
    )


def xyz(point: FloatArray) -> str:
    return "  ".join(f"{axis} {value:.3f}" for axis, value in zip("xyz", point, strict=True))


def report_lines(report: FeatureReport) -> list[tuple[str, str]]:
    """(label, value) rows for the panel. Frames are timeline frames (idx + 1), like Blender's; lengths in metres."""
    lines = [("Feature", str(report.feature_id))]
    if report.first_idx is not None and report.last_idx is not None:
        span = f"{report.first_idx + 1} to {report.last_idx + 1}"
        lines.append(("Seen", f"frames {span} ({report.frames_seen} frames)"))
    at = report.at
    for name, point in (("Raw", at.raw), ("Averaged", at.averaged)):
        if point is not None:
            lines.append((f"{name} ARKit", xyz(point)))
            lines.append((f"{name} Blender", xyz(points_to_blender(point)[0])))
        elif name == "Averaged" and not report.cloud_has_ids:
            lines.append((name, "no ids in the Mac's recompute"))
        else:
            lines.append((name, f"not at frame {report.idx + 1}"))
    if at.samples is not None:
        lines.append(("Samples", str(at.samples)))
    if at.offset is not None:
        lines.append(("Raw to averaged", f"{at.offset * 100:.1f} cm"))
    if at.distance is not None:
        lines.append(("From the camera", f"{at.distance:.2f} m"))
    return lines
