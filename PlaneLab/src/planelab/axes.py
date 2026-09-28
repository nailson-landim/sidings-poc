"""ARKit → Blender conversions (SPEC.md §3.2). Pure numpy, so they're tested outside Blender.

ARKit's world is +Y up; Blender's is +Z up. Both cameras look down their own -Z with +Y up and +X right, so only the
world needs rotating: Blender ``(x, y, z)`` = ARKit ``(x, -z, y)``, a +90° turn about X.
"""

from dataclasses import dataclass

import numpy as np
import numpy.typing as npt

FloatArray = npt.NDArray[np.float64]

ARKIT_TO_BLENDER = np.array([[1.0, 0.0, 0.0], [0.0, 0.0, -1.0], [0.0, 1.0, 0.0]])
"""Rotation taking ARKit world coordinates to Blender world coordinates."""

SENSOR_WIDTH_MM = 36.0
"""Blender's sensor width. Any value works; the lens is scaled to it so the field of view matches."""


def points_to_blender(points: npt.ArrayLike) -> FloatArray:
    """(N, 3) ARKit world points as Blender world points."""
    return np.asarray(points, dtype=np.float64).reshape(-1, 3) @ ARKIT_TO_BLENDER.T


def pose_to_blender(camera: npt.ArrayLike) -> FloatArray:
    """A (4, 4) or (N, 4, 4) world <- camera matrix in ARKit axes as the same pose in Blender axes."""
    matrix = np.asarray(camera, dtype=np.float64)
    turn = np.eye(4)
    turn[:3, :3] = ARKIT_TO_BLENDER
    return turn @ matrix


@dataclass(slots=True, frozen=True)
class CameraLens:
    """Blender camera settings reproducing a pinhole with the given intrinsics (``sensor_fit = 'HORIZONTAL'``)."""

    lens_mm: float
    shift_x: float
    shift_y: float


def lens_from_intrinsics(
    fx: float, cx: float, cy: float, width: int, height: int, sensor_width_mm: float = SENSOR_WIDTH_MM
) -> CameraLens:
    """Focal length and principal-point shift for an image of ``width`` x ``height`` pixels (landscape).

    Blender's shift is in units of the image width: raising ``shift_x`` moves the view right, so an on-axis point lands
    at ``x = width / 2 - shift_x * width``; pixel rows grow downwards, so it lands at ``y = height / 2 + shift_y *
    width``. Matching those to ``(cx, cy)`` gives the shifts below.
    """
    return CameraLens(
        lens_mm=fx * sensor_width_mm / width,
        shift_x=(width / 2 - cx) / width,
        shift_y=(cy - height / 2) / width,
    )


def quaternions(rotations: npt.ArrayLike) -> FloatArray:
    """(N, 3, 3) rotation matrices as (N, 4) unit quaternions ``(w, x, y, z)``.

    Consecutive quaternions keep the same hemisphere (``q`` and ``-q`` are the same rotation), so interpolating
    between keyframes never takes the long way round.
    """
    r = np.asarray(rotations, dtype=np.float64).reshape(-1, 3, 3)
    m00, m11, m22 = r[:, 0, 0], r[:, 1, 1], r[:, 2, 2]
    # Shepperd's method: pick the largest of the four candidates for a numerically stable square root.
    candidates = np.stack([1 + m00 + m11 + m22, 1 + m00 - m11 - m22, 1 - m00 + m11 - m22, 1 - m00 - m11 + m22], axis=1)
    pick = np.argmax(candidates, axis=1)
    s = np.sqrt(np.maximum(candidates[np.arange(len(r)), pick], 1e-12)) * 2
    q = np.empty((len(r), 4))
    for case in range(4):
        rows = pick == case
        m, k = r[rows], s[rows]
        if case == 0:
            q[rows] = np.stack(
                [k / 4, (m[:, 2, 1] - m[:, 1, 2]) / k, (m[:, 0, 2] - m[:, 2, 0]) / k, (m[:, 1, 0] - m[:, 0, 1]) / k],
                axis=1,
            )
        elif case == 1:
            q[rows] = np.stack(
                [(m[:, 2, 1] - m[:, 1, 2]) / k, k / 4, (m[:, 0, 1] + m[:, 1, 0]) / k, (m[:, 0, 2] + m[:, 2, 0]) / k],
                axis=1,
            )
        elif case == 2:
            q[rows] = np.stack(
                [(m[:, 0, 2] - m[:, 2, 0]) / k, (m[:, 0, 1] + m[:, 1, 0]) / k, k / 4, (m[:, 1, 2] + m[:, 2, 1]) / k],
                axis=1,
            )
        else:
            q[rows] = np.stack(
                [(m[:, 1, 0] - m[:, 0, 1]) / k, (m[:, 0, 2] + m[:, 2, 0]) / k, (m[:, 1, 2] + m[:, 2, 1]) / k, k / 4],
                axis=1,
            )
    q /= np.linalg.norm(q, axis=1, keepdims=True)
    for i in range(1, len(q)):
        if np.dot(q[i], q[i - 1]) < 0:
            q[i] = -q[i]
    return q
