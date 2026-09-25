"""Stages 2 and 3: the point filter and the motion gates (SPEC.md §18 T16)."""

import math
from pathlib import Path

import numpy as np
import pytest

from planelab.accumulate import accumulate
from planelab.config import FilterConfig, GateConfig, LabConfig
from planelab.gate import FrameGate, ParallaxGate, keep_points
from planelab.replay import load_replay
from planelab.session import open_session
from planelab.synth import SynthParams, look_at, write_synthetic


def slide(steps: int, step_m: float, turn_deg: float = 0.0) -> list[np.ndarray]:
    """Cameras moving along +X by ``step_m`` and turning by ``turn_deg`` per frame."""
    cameras = []
    for i in range(steps):
        yaw = math.radians(turn_deg * i)
        eye = np.array([i * step_m, 1.5, 0.0])
        cameras.append(look_at(eye, eye + np.array([math.sin(yaw), 0.0, -math.cos(yaw)])))
    return cameras


def accepted(mode: str, cameras: list[np.ndarray]) -> list[int]:
    gate = FrameGate(GateConfig(mode=mode))
    return [i for i, camera in enumerate(cameras) if gate.accept(camera)]


def test_intended_gate_waits_for_three_centimetres() -> None:
    assert accepted("intended", slide(10, 0.011)) == [0, 3, 6, 9]


def test_upstream_gate_passes_small_steps_and_blocks_big_ones() -> None:
    # CurvSurf as coded: `distance² < move²` passes frames that moved LESS than 3 cm.
    assert accepted("upstream", slide(10, 0.011)) == list(range(10))
    assert accepted("upstream", slide(10, 0.05)) == [0]


def test_upstream_gate_unblocks_when_the_camera_turns() -> None:
    cameras = slide(4, 0.05)
    turned = look_at(cameras[-1][:3, 3] + [0.05, 0, 0], cameras[-1][:3, 3] + [0.05 + math.sin(0.1), 0, -1])
    assert accepted("upstream", [*cameras, turned]) == [0, 4]


def test_turning_in_place_passes_every_frame_over_three_degrees() -> None:
    assert accepted("intended", slide(5, 0.0, turn_deg=4.0)) == [0, 1, 2, 3, 4]
    # 1.1 degrees per frame reaches 3.3 at frame 3; exactly 3 would sit on the strict `<` of the rule.
    assert accepted("intended", slide(5, 0.0, turn_deg=1.1)) == [0, 3]


def test_off_and_parallax_pass_every_frame() -> None:
    cameras = slide(5, 0.0)
    assert accepted("off", cameras) == accepted("parallax", cameras) == [0, 1, 2, 3, 4]


def test_parallax_gate_is_range_aware() -> None:
    gate = ParallaxGate(GateConfig(mode="parallax", parallax_deg=1.0))
    ids = np.array([1, 2], dtype=np.uint64)
    points = np.array([[0.0, 1.5, -10.0], [0.0, 1.5, -1.0]])  # 10 m and 1 m away
    picks = [gate.select([i * 0.05, 1.5, 0.0], ids, points).tolist() for i in range(9)]
    far = [i for i, pick in enumerate(picks) if pick[0]]
    near = [i for i, pick in enumerate(picks) if pick[1]]
    assert near == list(range(9))  # 5 cm at 1 m is 2.9 degrees
    assert far == [0, 4, 8]  # 1 degree at 10 m needs 17.5 cm
    gate.forget([1])
    assert len(gate) == 1


def test_filter_drops_near_and_optionally_far_points() -> None:
    eye = [0.0, 0.0, 0.0]
    points = np.array([[0, 0, -0.1], [0, 0, -0.25], [0, 0, -0.3], [0, 0, -40.0]])
    assert keep_points(eye, points, FilterConfig()).tolist() == [False, False, True, True]
    assert keep_points(eye, points, FilterConfig(far_cut_m=30.0)).tolist() == [False, False, True, False]


def test_gate_modes_change_what_the_accumulator_sees(tmp_path: Path) -> None:
    bundle = tmp_path / "facade.planelab"
    write_synthetic(bundle, SynthParams(scene="facade", seconds=2, fps=60))
    with open_session(bundle) as session:
        replay = load_replay(session)
    sightings = {
        mode: int(accumulate(replay, LabConfig(gate=GateConfig(mode=mode))).cloud().sightings.sum())
        for mode in ("off", "intended", "upstream", "parallax")
    }
    # The facade path moves about 6.7 cm per frame: intended passes every frame, upstream (as coded) almost none.
    assert sightings["intended"] == pytest.approx(sightings["off"], rel=0.01)
    assert sightings["upstream"] < sightings["off"] / 10
    assert 0 < sightings["parallax"] < sightings["off"]
