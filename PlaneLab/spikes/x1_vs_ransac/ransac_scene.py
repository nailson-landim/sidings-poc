"""The RANSAC probe and X1's final planes as a Blender scene, to look at with your own eyes (2026-10-01).

    python spikes/x1_vs_ransac/ransac_scene.py 20261001-142809.planelab [more recordings]

Writes ``<recording>/lab/ransac_probe.blend`` (``replay.blend`` is left alone): the final averaged cloud, each point
coloured by the probe plane it fell into (grey: none), a translucent rectangle per probe plane (its 2-98 % extent), X1's
planes as they were at the end, and the camera path. Static: the end of the recording. A top view (Numpad 7) shows
how one wall or the ground came out as parallel slices.
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from ransac_probe import final_cloud, probe

from planelab.axes import points_to_blender, pose_to_blender
from planelab.session import open_session
from planelab.surfaces import SurfaceTimeline

BLENDER = os.environ.get("BLENDER", "/Applications/Blender.app/Contents/MacOS/Blender")
BUILDER = Path(__file__).with_name("ransac_scene_blender.py")


def write_scene(name: str) -> Path:
    bundle = Path.home() / "PlaneLab/sessions" / name
    points, replay = final_cloud(name)
    cameras = replay.cameras[:: max(1, len(replay) // 300), :3, 3]
    planes = probe(points, cameras)
    labels = np.full(len(points), -1, dtype=np.int64)
    for k, plane in enumerate(planes):
        labels[plane.inliers] = k
    with open_session(bundle) as session:
        x1 = SurfaceTimeline(session.surface_rows()).at(len(replay) - 1)
    x1 = [row for row in x1 if row.outline is not None and len(row.outline) >= 3]
    names = [
        f"{k:02d} {p.kind} {len(p.inliers)} pts, {p.size[0]:.1f}x{p.size[1]:.1f} m, offset {p.offset:+.2f} m, "
        f"rms {p.rms * 100:.0f} cm"
        for k, p in enumerate(planes)
    ]
    x1_names = [
        f"X1 #{r.number} {r.width_m:.1f}x{r.height_m:.1f} m, "
        f"tilt {np.degrees(np.arcsin(min(1.0, abs(r.normal[1])))):.0f} deg from vertical"
        if abs(r.normal[1]) < 0.9
        else f"X1 #{r.number} ground {r.width_m:.1f}x{r.height_m:.1f} m"
        for r in x1
    ]
    out = bundle / "lab" / "ransac_probe.blend"
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as scratch:
        data = Path(scratch) / "scene.npz"
        np.savez(
            data,
            points=points_to_blender(points),
            labels=labels,
            corners=points_to_blender(np.concatenate([p.corners for p in planes])) if planes else np.empty((0, 3)),
            names=np.array(names),
            x1_outlines=points_to_blender(np.concatenate([r.outline for r in x1])) if x1 else np.empty((0, 3)),
            x1_offsets=np.cumsum([0] + [len(r.outline) for r in x1]),
            x1_names=np.array(x1_names),
            x1_numbers=np.array([r.number for r in x1]),
            trail=pose_to_blender(replay.cameras)[:, :3, 3],
        )
        result = subprocess.run(
            [BLENDER, "--background", "--factory-startup", "--python-exit-code", "1", "--python", str(BUILDER), "--",
             str(data), str(out), name],
            capture_output=True, text=True, check=False,
        )  # fmt: skip
    if result.returncode != 0:
        raise SystemExit(result.stdout[-3000:] + result.stderr[-3000:])
    print(f"{name}: {len(planes)} probe planes, {int((labels < 0).sum())} points in none, {len(x1)} X1 planes -> {out}")
    for line in names:
        print(f"   {line}")
    return out


if __name__ == "__main__":
    for recording in sys.argv[1:]:
        write_scene(recording)
