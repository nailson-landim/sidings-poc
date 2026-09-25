"""Stages 2 and 3 (SPEC.md §5.1): which raw points are used, and which samples reach the accumulator.

The frame gate reproduces CurvSurf's ``CameraMotionDetector``
(``ARFeaturePointFindSurface/Utilities/CameraMotionDetector.swift``): position and view direction start at zero, a
frame passes when the camera moved or turned enough since the last passing frame, and a passing frame becomes the
new reference. ``intended`` is the documented rule (moved **at least** ``move_m``). ``upstream`` is the code as
shipped, which tests ``distance² < move_m²`` and so passes frames that moved **less**: at walking speed nearly every
frame, and during fast translation none until the camera turns. ``off`` passes every frame. ``parallax`` passes every
frame and gates each point instead (``ParallaxGate``).
"""

import math

import numpy as np
import numpy.typing as npt

from planelab.config import FilterConfig, GateConfig

FloatArray = npt.NDArray[np.floating]
BoolArray = npt.NDArray[np.bool_]
UInt64Array = npt.NDArray[np.uint64]


def keep_points(eye: npt.ArrayLike, points: FloatArray, config: FilterConfig) -> BoolArray:
    """Stage 2 mask. CurvSurf drops points with squared distance ``<= near_cut_m²``; so does this."""
    distance_sq = np.sum((np.asarray(points, dtype=np.float64) - np.asarray(eye, dtype=np.float64)) ** 2, axis=1)
    keep = distance_sq > config.near_cut_m**2
    if config.far_cut_m > 0:
        keep &= distance_sq <= config.far_cut_m**2
    return keep


class FrameGate:
    def __init__(self, config: GateConfig) -> None:
        self.mode = config.mode
        self._move_sq = config.move_m**2
        self._min_cos = math.cos(math.radians(config.turn_deg))
        self._position = np.zeros(3)
        self._direction = np.zeros(3)

    def accept(self, camera: FloatArray) -> bool:
        """Whether this frame's points may reach the accumulator. ``camera`` is world <- camera."""
        if self.mode in ("off", "parallax"):
            return True
        position = np.asarray(camera[:3, 3], dtype=np.float64)
        direction = -np.asarray(camera[:3, 2], dtype=np.float64)
        distance_sq = float(np.sum((position - self._position) ** 2))
        moved = distance_sq < self._move_sq if self.mode == "upstream" else distance_sq >= self._move_sq
        turned = float(direction @ self._direction) < self._min_cos
        if moved or turned:
            self._position, self._direction = position, direction
            return True
        return False


class ParallaxGate:
    """Per point: a new sample counts once the direction from the camera to the point has turned by at least
    ``parallax_deg`` since that feature's last accepted sample. A feature's first sample always counts.
    """

    def __init__(self, config: GateConfig) -> None:
        self._min_cos = math.cos(math.radians(config.parallax_deg))
        self._last_eye: dict[int, tuple[float, float, float]] = {}

    def __len__(self) -> int:
        return len(self._last_eye)

    def select(self, eye: npt.ArrayLike, ids: UInt64Array, points: FloatArray) -> BoolArray:
        eye_now = np.asarray(eye, dtype=np.float64)
        keys = ids.tolist()
        nan = (math.nan, math.nan, math.nan)
        last = np.array([self._last_eye.get(k, nan) for k in keys], dtype=np.float64).reshape(-1, 3)
        new = np.isnan(last[:, 0])
        p = np.asarray(points, dtype=np.float64)
        before, now = p - last, p - eye_now
        with np.errstate(invalid="ignore", divide="ignore"):
            cos = np.einsum("ij,ij->i", before, now) / (np.linalg.norm(before, axis=1) * np.linalg.norm(now, axis=1))
        accept = new | (cos <= self._min_cos)
        stamp = tuple(eye_now.tolist())
        for index in np.flatnonzero(accept).tolist():
            self._last_eye[keys[index]] = stamp  # type: ignore[assignment]
        return accept

    def forget(self, ids: list[int]) -> None:
        """Drops features the accumulator evicted, so the gate's memory stays bounded the same way."""
        for key in ids:
            self._last_eye.pop(key, None)
