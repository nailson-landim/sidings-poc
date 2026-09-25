"""Synthetic sessions with known planes (SPEC.md §18 T14)."""

import hashlib
import json
from pathlib import Path

import numpy as np
import pytest

from planelab.cli import main
from planelab.session import open_session
from planelab.synth import (
    CLUTTER,
    FX,
    HEIGHT,
    ID_BASE,
    SCENES,
    WIDTH,
    SynthParams,
    build_scene,
    look_at,
    observe,
    write_synthetic,
)

EXPECTED_PLANES = {"facade": 2, "edges": 2, "room": 5}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


@pytest.mark.parametrize("scene", SCENES)
def test_every_scene_reads_back_with_its_truth(tmp_path: Path, scene: str) -> None:
    out = tmp_path / f"{scene}.planelab"
    params = SynthParams(scene=scene, seconds=2, fps=15)
    built = write_synthetic(out, params)
    truth = json.loads((out / "synth_truth.json").read_text())
    assert len(truth["planes"]) == EXPECTED_PLANES[scene]
    assert truth["frames"] == 30
    with open_session(out) as session:
        assert session.frame_count() == 30
        assert session.meta["synth_scene"] == scene
        assert session.video_path is None
        frames = list(session.frames())
    assert all(len(f.points) > 20 for f in frames), "every frame sees features"
    assert np.allclose(frames[5].camera, built.cameras[5], atol=1e-6)
    for plane, entry in zip(built.planes, truth["planes"], strict=True):
        on_plane = built.features[built.owner == built.planes.index(plane)]
        assert np.abs(on_plane @ plane.normal - plane.offset).max() < 1e-9
        assert entry["features"] == len(on_plane)


def test_same_seed_same_bytes_other_seed_other_bytes(tmp_path: Path) -> None:
    a, b, c = (tmp_path / n for n in ("a.planelab", "b.planelab", "c.planelab"))
    write_synthetic(a, SynthParams(seed=3, seconds=1))
    write_synthetic(b, SynthParams(seed=3, seconds=1))
    write_synthetic(c, SynthParams(seed=4, seconds=1))
    for name in ("session.sqlite", "synth_truth.json"):
        assert digest(a / name) == digest(b / name)
    assert digest(a / "session.sqlite") != digest(c / "session.sqlite")


def test_edges_scene_puts_features_only_on_outlines() -> None:
    scene = build_scene(SynthParams(scene="edges"))
    for index, plane in enumerate(scene.planes):
        assert plane.segments, "edges walls are outline-only"
        points = scene.features[scene.owner == index]
        rel = points - np.asarray(plane.origin)
        a, b = rel @ np.asarray(plane.u), rel @ np.asarray(plane.v)
        nearest = np.full(len(points), np.inf)
        for a0, b0, a1, b1 in plane.segments:
            d = np.array([a1 - a0, b1 - b0])
            t = np.clip(((a - a0) * d[0] + (b - b0) * d[1]) / (d @ d), 0, 1)
            nearest = np.minimum(nearest, np.hypot(a - (a0 + t * d[0]), b - (b0 + t * d[1])))
        assert nearest.max() < 1e-9
    assert (scene.owner == CLUTTER).sum() == pytest.approx(0.25 * (scene.owner >= 0).sum(), abs=1)


def test_observations_follow_the_noise_model() -> None:
    params = SynthParams(scene="facade", noise_m=0.01, ray_noise_per_m=0.0, detect_probability=1.0, max_points=10_000)
    scene = build_scene(params)
    ids, points = observe(scene, scene.cameras[0], np.random.default_rng(0))
    truth = scene.features[(ids - ID_BASE).astype(np.int64)]
    error = points - truth
    assert np.std(error) == pytest.approx(0.01, rel=0.1)
    local = (truth - scene.cameras[0][:3, 3]) @ scene.cameras[0][:3, :3]
    depth = -local[:, 2]
    assert (depth > 0).all()
    u = FX * local[:, 0] / depth + WIDTH / 2
    v = HEIGHT / 2 - FX * local[:, 1] / depth
    assert ((u >= 0) & (u < WIDTH) & (v >= 0) & (v < HEIGHT)).all()


def test_ray_noise_grows_with_depth() -> None:
    params = SynthParams(noise_m=0.0, ray_noise_per_m=0.01, detect_probability=1.0, max_points=10_000)
    scene = build_scene(params)
    camera = scene.cameras[0]
    ids, points = observe(scene, camera, np.random.default_rng(1))
    truth = scene.features[(ids - ID_BASE).astype(np.int64)]
    rel = truth - camera[:3, 3]
    depth = np.linalg.norm(rel, axis=1)
    along = np.einsum("ij,ij->i", points - truth, rel / depth[:, None])
    across = np.linalg.norm((points - truth) - along[:, None] * rel / depth[:, None], axis=1)
    assert across.max() < 1e-9
    far = depth > np.median(depth)
    assert np.std(along[far]) > np.std(along[~far])


def test_look_at_is_level_and_faces_the_target() -> None:
    camera = look_at((0, 1.5, 0), (0, 1.5, -5))
    assert np.allclose(camera[:3, :3], np.eye(3))
    turned = look_at((0, 0, 0), (5, 0, 0))
    assert np.allclose(-turned[:3, 2], [1, 0, 0]) and np.allclose(turned[:3, 1], [0, 1, 0])


def test_unknown_scene_is_refused() -> None:
    with pytest.raises(ValueError, match="unknown scene"):
        build_scene(SynthParams(scene="castle"))


def test_cli_synth_then_info(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    out = tmp_path / "edges.planelab"
    assert main(["synth", str(out), "--scene", "edges", "--seconds", "1", "--fps", "10"]) == 0
    printed = capsys.readouterr().out
    assert "edges, 10 frames, planes: wall_a, wall_b" in printed
    assert main(["info", str(out)]) == 0
    assert "10 in 0.90 s" in capsys.readouterr().out
