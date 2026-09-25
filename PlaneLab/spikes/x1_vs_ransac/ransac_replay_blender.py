"""Builds ``ransac_replay.blend`` inside Blender: the Plane Lab import of the recording, plus the probe checkpoints
``ransac_replay.py`` prepared (already in Blender axes), each visible from its frame to the next checkpoint's.

    Blender --background --factory-startup --python ransac_replay_blender.py -- <replay.npz> <bundle> <out.blend>
"""

import sys
from pathlib import Path

import bpy
import numpy as np

PLANELAB = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PLANELAB / "blender"))

import planelab_blender  # noqa: E402
from planelab_blender.build import (  # noqa: E402
    AVERAGED_CLOUD,
    DISPLAY_MODIFIER,
    LAYER_KEY,
    point_display_group,
    set_inputs,
)

# Vertical planes warm, horizontal cool, by size within a checkpoint.
WARM = [(1.0, 0.45, 0.0), (0.9, 0.1, 0.1), (1.0, 0.8, 0.0), (0.7, 0.3, 0.9), (1.0, 0.4, 0.7), (0.6, 0.4, 0.2)]
COOL = [(0.1, 0.5, 1.0), (0.0, 0.85, 0.85), (0.3, 0.85, 0.3), (0.4, 0.4, 1.0), (0.0, 0.6, 0.5)]
POINT_SIZE = 0.008
FILL_ALPHA = 0.25


def material(name: str, rgba: tuple[float, float, float, float]) -> bpy.types.Material:
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.diffuse_color = rgba
    return m


def visible_between(obj: bpy.types.Object, first: int, last: int) -> None:
    """Shown on frames first..last only (keyframed, so it follows the timeline without a handler)."""
    for frame, hidden in ((1, True), (first, False), (last + 1, True)):
        if frame == 1 and first <= 1:
            continue
        obj.hide_viewport = hidden
        obj.hide_render = hidden
        obj.keyframe_insert("hide_viewport", frame=frame)
        obj.keyframe_insert("hide_render", frame=frame)


def main(data_path: str, bundle: str, out: str) -> None:
    data = np.load(data_path)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    planelab_blender.register()
    bpy.ops.planelab.import_session(filepath=bundle)
    scene = bpy.context.scene
    camera = scene.camera
    # The probe recolours the averaged cloud's points; hide the cloud so the two don't sit on top of each other.
    for obj in scene.objects:
        if obj.get(LAYER_KEY) == AVERAGED_CLOUD:
            obj.hide_set(True)

    root = bpy.data.collections.new(f"RANSAC probe every {data['checkpoint_seconds'][0]:.0f} s")
    scene.collection.children.link(root)
    frames = [int(f) for f in data["checkpoint_frames"]]
    last_frame = int(data["last_frame"])
    group = point_display_group()
    owners = data["owners"]
    for k, start in enumerate(frames):
        end = frames[k + 1] - 1 if k + 1 < len(frames) else last_frame
        planes = np.flatnonzero(owners == k)
        checkpoint = bpy.data.collections.new(
            f"RANSAC @ {data['checkpoint_seconds'][k]:.0f} s (frames {start}-{end}, {len(planes)} planes)"
        )
        root.children.link(checkpoint)
        for p in planes:
            kind, rank = str(data["kinds"][p]), int(data["ranks"][p])
            rgb = (WARM if kind == "V" else COOL)[rank % len(WARM if kind == "V" else COOL)]
            label = f"{data['checkpoint_seconds'][k]:.0f}s {data['names'][p]}"
            mesh = bpy.data.meshes.new(f"{label} points")
            mesh.from_pydata(data["points"][data["offsets"][p] : data["offsets"][p + 1]].tolist(), [], [])
            dots = bpy.data.objects.new(f"{label} points", mesh)
            checkpoint.objects.link(dots)
            modifier = dots.modifiers.new(DISPLAY_MODIFIER, "NODES")
            modifier.node_group = group
            set_inputs(modifier, Material=material(f"probe {kind}{rank}", (*rgb, 1.0)), Eye=camera, Size=POINT_SIZE)
            quad = bpy.data.meshes.new(f"{label} extent")
            quad.from_pydata(data["corners"][p].tolist(), [], [[0, 1, 2, 3]])
            quad.materials.append(material(f"probe {kind}{rank} fill", (*rgb, FILL_ALPHA)))
            extent = bpy.data.objects.new(f"{label} extent", quad)
            extent.show_transparent = True
            extent.show_wire = True
            checkpoint.objects.link(extent)
            for obj in (dots, extent):
                visible_between(obj, start, end)

    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type == "VIEW_3D":
                area.spaces.active.region_3d.view_perspective = "CAMERA"
    bpy.context.preferences.filepaths.save_version = 0
    scene.frame_set(frames[len(frames) // 2] if frames else 1)
    bpy.ops.wm.save_as_mainfile(filepath=out)
    planelab_blender.unregister()
    print(f"REPLAY OK {len(frames)} checkpoints, {len(owners)} planes")


if __name__ == "__main__":
    main(*sys.argv[sys.argv.index("--") + 1 :])
