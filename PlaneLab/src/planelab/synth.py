"""Synthetic sessions with known planes (SPEC.md §5.5 ``planelab synth``, §17.4 P7, S8).

A scene plants planes, scatters features on them (or only on their outlines, as ``BUILDING_SAMPLE.png`` shows for
plain facades), adds clutter that lies on no plane, and walks a camera through it. Each frame reports what an
ARKit-like tracker would: the visible features with stable ids, each sighting jittered by ``noise_m`` plus extra
noise along the view ray that grows with depth. The session goes through the real schema (``planelab.writer``), and
the truth goes to ``synth_truth.json`` next to it.
"""

import json
import logging
from dataclasses import asdict, dataclass, field
from pathlib import Path

import numpy as np
import numpy.typing as npt

from planelab.writer import SessionWriter

log = logging.getLogger(__name__)

FloatArray = npt.NDArray[np.float64]

SCENES = ("facade", "edges", "room")
WIDTH, HEIGHT = 1920, 1440
FX = FY = 1500.0
CX, CY = WIDTH / 2, HEIGHT / 2
ID_BASE = 1 << 40
"""Feature ids start here, so they look like ARKit's large identifiers."""
CLUTTER = -1


@dataclass(slots=True, frozen=True)
class SynthParams:
    scene: str = "facade"
    seed: int = 7
    seconds: float = 10.0
    fps: int = 30
    noise_m: float = 0.01
    """Sigma of every sighting, in every direction (S8: 1 cm)."""
    ray_noise_per_m: float = 0.002
    """Extra sigma along the view ray per metre of depth: ARKit's needle-shaped depth error."""
    outlier_fraction: float = 0.2
    """Share of all features that lie on no plane (S8: 20 %)."""
    detect_probability: float = 0.8
    max_points: int = 500
    """Sightings per frame at most, like ``rawFeaturePoints``."""
    max_range_m: float = 30.0


@dataclass(slots=True, frozen=True)
class PlantedPlane:
    """A rectangle ``origin + a·u + b·v``, ``a`` in [0, width], ``b`` in [0, height]; normal ``cross(u, v)``."""

    name: str
    origin: tuple[float, float, float]
    u: tuple[float, float, float]
    v: tuple[float, float, float]
    width: float
    height: float
    segments: tuple[tuple[float, float, float, float], ...] = ()
    """Outline segments ``(a0, b0, a1, b1)`` in plane coordinates; when set, features lie only on them."""

    @property
    def normal(self) -> FloatArray:
        n = np.cross(self.u, self.v)
        return n / np.linalg.norm(n)

    @property
    def offset(self) -> float:
        """``d`` in ``normal · x = d``."""
        return float(self.normal @ np.asarray(self.origin))

    def at(self, a: npt.ArrayLike, b: npt.ArrayLike) -> FloatArray:
        a = np.asarray(a, dtype=np.float64)[..., None]
        b = np.asarray(b, dtype=np.float64)[..., None]
        return np.asarray(self.origin) + a * np.asarray(self.u) + b * np.asarray(self.v)

    def corners(self) -> FloatArray:
        return self.at([0, self.width, self.width, 0], [0, 0, self.height, self.height])


@dataclass(slots=True)
class Scene:
    params: SynthParams
    planes: list[PlantedPlane]
    features: FloatArray
    """(N, 3) true feature positions."""
    owner: npt.NDArray[np.int64]
    """(N,) index into ``planes``, or -1 for clutter."""
    cameras: FloatArray
    """(F, 4, 4) world <- camera, ARKit axes."""
    stats: dict[str, int] = field(default_factory=dict)


def look_at(position: npt.ArrayLike, target: npt.ArrayLike) -> FloatArray:
    """A world <- camera matrix looking from ``position`` at ``target``, level (image long side horizontal)."""
    eye = np.asarray(position, dtype=np.float64)
    back = eye - np.asarray(target, dtype=np.float64)
    back /= np.linalg.norm(back)
    right = np.cross([0.0, 1.0, 0.0], back)
    right /= np.linalg.norm(right)
    up = np.cross(back, right)
    camera = np.eye(4)
    camera[:3, 0], camera[:3, 1], camera[:3, 2], camera[:3, 3] = right, up, back, eye
    return camera


def _surface(plane: PlantedPlane, count: int, rng: np.random.Generator) -> FloatArray:
    return plane.at(rng.uniform(0, plane.width, count), rng.uniform(0, plane.height, count))


def _outline(plane: PlantedPlane, count: int, rng: np.random.Generator) -> FloatArray:
    lengths = np.array([np.hypot(a1 - a0, b1 - b0) for a0, b0, a1, b1 in plane.segments])
    picks = rng.choice(len(plane.segments), size=count, p=lengths / lengths.sum())
    s = rng.uniform(0, 1, count)
    seg = np.asarray(plane.segments)[picks]
    return plane.at(seg[:, 0] + s * (seg[:, 2] - seg[:, 0]), seg[:, 1] + s * (seg[:, 3] - seg[:, 1]))


def _layout(scene: str) -> tuple[list[PlantedPlane], dict[str, int], tuple[FloatArray, FloatArray]]:
    """Planes, features per plane, and the clutter box (low, high corners)."""
    up = (0.0, 1.0, 0.0)
    if scene == "facade":
        planes = [
            PlantedPlane("wall", (-8.0, 0.0, -8.0), (1.0, 0.0, 0.0), up, 16.0, 6.0),
            PlantedPlane("ground", (-8.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 0.0, -1.0), 16.0, 8.0),
        ]
        counts = {"wall": 1500, "ground": 500}
        box = (np.array([-7.0, 0.2, -7.0]), np.array([7.0, 4.0, -1.0]))
    elif scene == "edges":
        # A concave corner seen from outside it. Features only on outlines: the shared corner, parapets, bases, two
        # trim lines and two window frames per wall. The corner line is generated once, on wall A.
        def window(a: float, b: float, w: float, h: float) -> list[tuple[float, float, float, float]]:
            return [(a, b, a + w, b), (a + w, b, a + w, b + h), (a + w, b + h, a, b + h), (a, b + h, a, b)]

        def storeys(width: float) -> list[tuple[float, float, float, float]]:
            return [(0, 6, width, 6), (0, 0, width, 0), (0, 3, width, 3), (0, 3.2, width, 3.2)]

        wall_a = [*storeys(8.0), (8, 0, 8, 6), *window(1.5, 1.0, 1.2, 1.5), *window(4.5, 1.0, 1.2, 1.5)]
        wall_b = [*storeys(8.0), *window(2.0, 1.0, 1.2, 1.5), *window(5.0, 1.0, 1.2, 1.5)]
        planes = [
            PlantedPlane("wall_a", (-8.0, 0.0, -8.0), (1.0, 0.0, 0.0), up, 8.0, 6.0, tuple(wall_a)),
            PlantedPlane("wall_b", (0.0, 0.0, -8.0), (0.0, 0.0, 1.0), up, 8.0, 6.0, tuple(wall_b)),
        ]
        counts = {"wall_a": 900, "wall_b": 800}
        box = (np.array([-7.0, 0.2, -7.0]), np.array([-1.0, 4.0, -1.0]))
    elif scene == "room":
        planes = [
            PlantedPlane("back", (-2.5, 0.0, -2.0), (1.0, 0.0, 0.0), up, 5.0, 3.0),
            PlantedPlane("front", (2.5, 0.0, 2.0), (-1.0, 0.0, 0.0), up, 5.0, 3.0),
            PlantedPlane("left", (-2.5, 0.0, 2.0), (0.0, 0.0, -1.0), up, 4.0, 3.0),
            PlantedPlane("right", (2.5, 0.0, -2.0), (0.0, 0.0, 1.0), up, 4.0, 3.0),
            PlantedPlane("floor", (-2.5, 0.0, 2.0), (1.0, 0.0, 0.0), (0.0, 0.0, -1.0), 5.0, 4.0),
        ]
        counts = {p.name: 400 for p in planes}
        box = (np.array([-2.0, 0.2, -1.5]), np.array([2.0, 2.5, 1.5]))
    else:
        raise ValueError(f"unknown scene {scene!r}; choose one of {', '.join(SCENES)}")
    return planes, counts, box


def _path(scene: str, frames: int) -> FloatArray:
    s = np.linspace(0.0, 1.0, frames)
    cameras = np.empty((frames, 4, 4))
    for i, k in enumerate(s):
        if scene == "facade":
            x = -4 + 8 * k
            eye, target = (x, 1.5 + 0.05 * np.sin(12 * k), 0.0), (0.5 * x, 2.5, -8.0)
        elif scene == "edges":
            eye = (-6 + 4 * k, 1.5, -1 - 2 * k)
            target = (0.0 - 2 * np.cos(3 * np.pi * k), 3.0, -8.0 + 2 * np.cos(3 * np.pi * k))
        else:
            angle = 2 * np.pi * k
            eye = (0.3 * np.cos(3 * angle), 1.5, 0.3 * np.sin(3 * angle))
            target = (eye[0] + np.sin(angle), 1.2, eye[2] - np.cos(angle))
        cameras[i] = look_at(eye, target)
    return cameras


def build_scene(params: SynthParams) -> Scene:
    rng = np.random.default_rng(params.seed)
    planes, counts, (low, high) = _layout(params.scene)
    chunks, owners = [], []
    for index, plane in enumerate(planes):
        n = counts[plane.name]
        chunks.append(_outline(plane, n, rng) if plane.segments else _surface(plane, n, rng))
        owners.append(np.full(n, index))
    on_planes = sum(counts.values())
    clutter = round(on_planes * params.outlier_fraction / (1 - params.outlier_fraction))
    chunks.append(rng.uniform(low, high, size=(clutter, 3)))
    owners.append(np.full(clutter, CLUTTER))
    frames = max(1, round(params.seconds * params.fps))
    return Scene(
        params=params,
        planes=planes,
        features=np.concatenate(chunks),
        owner=np.concatenate(owners).astype(np.int64),
        cameras=_path(params.scene, frames),
        stats={"plane_features": on_planes, "clutter_features": clutter, "frames": frames},
    )


def observe(scene: Scene, camera: FloatArray, rng: np.random.Generator) -> tuple[npt.NDArray[np.uint64], FloatArray]:
    """One frame's sightings: ids and noisy world positions of the features the camera sees."""
    params = scene.params
    eye = camera[:3, 3]
    relative = scene.features - eye
    local = relative @ camera[:3, :3]  # camera-space coordinates (rotation transpose applied)
    depth = -local[:, 2]
    with np.errstate(divide="ignore", invalid="ignore"):
        u = FX * local[:, 0] / depth + CX
        v = CY - FY * local[:, 1] / depth
    visible = (depth > 0.3) & (depth < params.max_range_m) & (u >= 0) & (u < WIDTH) & (v >= 0) & (v < HEIGHT)
    on_plane = scene.owner >= 0
    normals = np.array([p.normal for p in scene.planes])
    facing = np.ones(len(scene.features), dtype=bool)
    facing[on_plane] = np.einsum("ij,ij->i", normals[scene.owner[on_plane]], -relative[on_plane]) > 0
    detected = rng.random(len(scene.features)) < params.detect_probability
    chosen = np.flatnonzero(visible & facing & detected)
    if len(chosen) > params.max_points:
        chosen = np.sort(rng.choice(chosen, size=params.max_points, replace=False))

    ray = relative[chosen] / np.linalg.norm(relative[chosen], axis=1, keepdims=True)
    noise = rng.normal(0.0, params.noise_m, size=(len(chosen), 3))
    noise += ray * rng.normal(0.0, 1.0, size=(len(chosen), 1)) * (params.ray_noise_per_m * depth[chosen, None])
    return (ID_BASE + chosen).astype(np.uint64), scene.features[chosen] + noise


def intrinsics() -> FloatArray:
    return np.array([[FX, 0.0, CX], [0.0, FY, CY], [0.0, 0.0, 1.0]])


def write_synthetic(out: Path, params: SynthParams) -> Scene:
    """Writes ``out/session.sqlite`` (no video) and ``out/synth_truth.json``; returns the scene."""
    scene = build_scene(params)
    rng = np.random.default_rng(params.seed + 1)
    frames = len(scene.cameras)
    meta = {
        "app_version": "synth",
        "device_model": f"synth:{params.scene}",
        "os_version": "",
        "lidar": "0",
        "plane_detection": "none",
        "world_alignment": "gravity",
        "video_width": str(WIDTH),
        "video_height": str(HEIGHT),
        "video_fps": "60",
        "arkit_format_fps": str(params.fps),
        "arkit_format_resolution": f"{WIDTH}x{HEIGHT}",
        "started_at": "synthetic",
        "stopped_at": "synthetic",
        "stop_reason": "user",
        "frames_logged": str(frames),
        "frames_with_image": "0",
        "frames_dropped": "0",
        "synth_scene": params.scene,
        "synth_seed": str(params.seed),
    }
    with SessionWriter(out, meta) as writer:
        k = intrinsics()
        for idx, camera in enumerate(scene.cameras):
            ids, points = observe(scene, camera, rng)
            writer.frame(idx, 1000.0 + idx / params.fps, camera, k, points, ids)
        writer.event(0, "record", "start")
        writer.event(frames - 1, "record", "stop:user")
    truth = {
        "params": asdict(params),
        "planes": [
            {
                "name": plane.name,
                "normal": plane.normal.tolist(),
                "offset": plane.offset,
                "corners": plane.corners().tolist(),
                "features": int((scene.owner == index).sum()),
                "outline_only": bool(plane.segments),
            }
            for index, plane in enumerate(scene.planes)
        ],
        "clutter_features": scene.stats["clutter_features"],
        "frames": frames,
        "id_base": ID_BASE,
    }
    (out / "synth_truth.json").write_text(json.dumps(truth, indent=2, sort_keys=True))
    log.info("wrote synthetic %s session to %s (%d frames)", params.scene, out, frames)
    return scene
