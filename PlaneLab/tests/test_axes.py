"""ARKit → Blender conversions (SPEC.md §3.2)."""

import math

import numpy as np
import pytest

from planelab.axes import lens_from_intrinsics, points_to_blender, pose_to_blender, quaternions


def rotation_about(axis: str, degrees: float) -> np.ndarray:
    a = math.radians(degrees)
    c, s = math.cos(a), math.sin(a)
    return {
        "x": np.array([[1, 0, 0], [0, c, -s], [0, s, c]]),
        "y": np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]]),
        "z": np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]]),
    }[axis]


def quaternion_to_matrix(q: np.ndarray) -> np.ndarray:
    w, x, y, z = q
    return np.array(
        [
            [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
            [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
            [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)],
        ]
    )


def test_points_rotate_up_to_up() -> None:
    converted = points_to_blender([[1, 2, 3], [0, 1, 0], [0, 0, -1]])
    assert converted.tolist() == [[1, -3, 2], [0, 0, 1], [0, 1, 0]]


def test_pose_keeps_the_camera_frame_and_moves_the_world() -> None:
    camera = np.eye(4)
    camera[:3, 3] = [1, 2, 3]
    blender = pose_to_blender(camera)
    assert blender[:3, 3].tolist() == [1, -3, 2]
    # An ARKit camera looking along world -Z (the session's start) looks along Blender +Y (into the screen from front).
    look = -blender[:3, 2]
    assert look.tolist() == pytest.approx([0, 1, 0])
    up = blender[:3, 1]
    assert up.tolist() == pytest.approx([0, 0, 1])


def test_pose_accepts_batches() -> None:
    poses = np.stack([np.eye(4)] * 3)
    assert pose_to_blender(poses).shape == (3, 4, 4)


def test_lens_for_a_centred_principal_point() -> None:
    lens = lens_from_intrinsics(fx=1500, cx=960, cy=720, width=1920, height=1440)
    assert lens.lens_mm == pytest.approx(1500 * 36 / 1920)
    assert (lens.shift_x, lens.shift_y) == (0, 0)


def test_shift_signs() -> None:
    # Principal point right of centre and below it: Blender shifts the view left (-x) and down (+y in image rows).
    lens = lens_from_intrinsics(fx=1500, cx=1056, cy=816, width=1920, height=1440)
    assert lens.shift_x == pytest.approx(-96 / 1920)
    assert lens.shift_y == pytest.approx(96 / 1920)


@pytest.mark.parametrize(
    ("axis", "degrees"), [("x", 30), ("y", -120), ("z", 179), ("x", 180), ("y", 180), ("z", 180), ("x", 0)]
)
def test_quaternions_round_trip(axis: str, degrees: float) -> None:
    r = rotation_about(axis, degrees)
    q = quaternions(r[None])[0]
    assert np.linalg.norm(q) == pytest.approx(1)
    assert quaternion_to_matrix(q) == pytest.approx(r, abs=1e-9)


def test_quaternions_stay_in_one_hemisphere() -> None:
    rs = np.stack([rotation_about("z", d) for d in range(0, 720, 20)])
    q = quaternions(rs)
    assert all(np.dot(q[i], q[i - 1]) > 0 for i in range(1, len(q)))
    for r, qi in zip(rs, q, strict=True):
        assert quaternion_to_matrix(qi) == pytest.approx(r, abs=1e-9)
