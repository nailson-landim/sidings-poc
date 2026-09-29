"""Saves a ready-to-open .blend of a recording: the Plane Lab import in an empty scene, opening in camera view.

Run headless:
    Blender --background --factory-startup --python scripts/replay_blend.py -- <bundle> [out.blend]

The default output is ``<bundle>/lab/replay.blend``. The camera path and the video are stored in the file. The
raw points, the averaged cloud and the ARKit planes are refilled on every frame by the Plane Lab extension, so enable it
in the Blender that opens the file. The averaged cloud is cached in ``<bundle>/lab/cloud-<hash>.npz``.
"""

import sys
from pathlib import Path

import bpy

PLANELAB = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PLANELAB / "blender"))

import planelab_blender  # noqa: E402


def main(argv: list[str]) -> None:
    bundle = Path(argv[0]).expanduser().resolve()
    out = Path(argv[1]).expanduser().resolve() if len(argv) > 1 else bundle / "lab" / "replay.blend"
    bpy.ops.wm.read_factory_settings(use_empty=True)  # no default cube, light or camera
    planelab_blender.register()
    bpy.ops.planelab.import_session(filepath=str(bundle))
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type == "VIEW_3D":
                space = area.spaces.active
                space.region_3d.view_perspective = "CAMERA"
                space.overlay.show_overlays = True
    out.parent.mkdir(parents=True, exist_ok=True)
    bpy.context.preferences.filepaths.save_version = 0  # the file is rebuilt on demand: no replay.blend1 backups
    bpy.ops.wm.save_as_mainfile(filepath=str(out))
    planelab_blender.unregister()
    print(f"saved {out}")


if __name__ == "__main__":
    main(sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else [])
