"""Headless smoke test of the Plane Lab extension (SPEC.md §11, §18 T8): import a recording and check the scene.

Run inside Blender (``tests/test_blender.py`` does this):
    Blender --background --factory-startup --python-exit-code 1 --python tests/blender/smoke_import.py -- <bundle>
The extension is loaded from the source tree, so no install is needed.
"""

import sys
from pathlib import Path

import bpy
import numpy as np

PLANELAB = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PLANELAB / "blender"))

import planelab_blender  # noqa: E402

from planelab.axes import lens_from_intrinsics, points_to_blender, pose_to_blender  # noqa: E402
from planelab.replay import load_replay  # noqa: E402
from planelab.session import open_session  # noqa: E402


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main(bundle: Path) -> None:
    planelab_blender.register()
    with open_session(bundle) as session:
        replay = load_replay(session)
        events = session.events()
    name = f"PlaneLab {bundle.name.removesuffix('.planelab')}"

    # Picking the session.sqlite inside the folder imports the folder.
    bpy.ops.planelab.import_session(filepath=str(bundle / "session.sqlite"))
    scene = bpy.context.scene
    collection = bpy.data.collections[name]
    check(scene.frame_start == 1 and scene.frame_end == int(replay.idx[-1]) + 1, "frame range")
    check(scene.render.fps == replay.fps, f"fps {scene.render.fps} != {replay.fps}")
    check((scene.render.resolution_x, scene.render.resolution_y) == (replay.width, replay.height), "resolution")
    camera = bpy.data.objects[f"{name} camera"]
    points = bpy.data.objects[f"{name} raw points"]
    trail = bpy.data.objects[f"{name} trail"]
    check(scene.camera == camera, "scene camera")
    check({camera, points, trail} <= set(collection.objects), "objects in the session collection")

    samples = sorted({0, 1, 2, len(replay) // 2, len(replay) - 1})
    for idx in samples:
        scene.frame_set(idx + 1)
        expected = pose_to_blender(replay.cameras[idx])
        actual = np.array(camera.matrix_world)
        check(np.allclose(actual, expected, atol=1e-5), f"camera pose at idx {idx}:\n{actual}\n!=\n{expected}")
        k = replay.intrinsics[idx]
        lens = lens_from_intrinsics(k[0, 0], k[0, 2], k[1, 2], replay.width, replay.height)
        check(abs(camera.data.lens - lens.lens_mm) < 1e-3, f"lens at idx {idx}")
        check(abs(camera.data.shift_x - lens.shift_x) < 1e-6, f"shift_x at idx {idx}")
        check(abs(camera.data.shift_y - lens.shift_y) < 1e-6, f"shift_y at idx {idx}")
        vertices = np.array([v.co[:] for v in points.data.vertices]).reshape(-1, 3)
        expected_points = points_to_blender(replay.points_at(idx))
        check(vertices.shape == expected_points.shape, f"point count at idx {idx}: {vertices.shape}")
        check(np.allclose(vertices, expected_points, atol=1e-5), f"point positions at idx {idx}")

    check(len(trail.data.vertices) == len(replay) and len(trail.data.edges) == len(replay) - 1, "trail")
    markers = sorted((m.frame, m.name) for m in scene.timeline_markers)
    check(markers == sorted((e.frame_idx + 1, f"PL {e.kind} {e.detail}") for e in events), f"markers {markers}")

    # Importing again (here by folder path) replaces the first import instead of adding a second one.
    bpy.ops.planelab.import_session(filepath=str(bundle))
    check(len([c for c in bpy.data.collections if c.name.startswith(name)]) == 1, "re-import replaced")
    check(len(scene.timeline_markers) == len(events), "markers replaced")

    try:
        bpy.ops.planelab.import_session(filepath="/nonexistent/session.sqlite")
        check(False, "a missing recording must fail")
    except RuntimeError as error:
        check("neither" in str(error), f"clear error: {error}")

    planelab_blender.unregister()
    print("SMOKE OK")


if __name__ == "__main__":
    args = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    main(Path(args[0]).resolve() if args else PLANELAB.parent / "session-format/fixtures/v1/tiny.planelab")
