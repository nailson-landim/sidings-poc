"""Builds a recording's Blender objects (SPEC.md §6): one collection per session holding the camera, its trail and
the raw-points layer, plus timeline markers. Only the camera is keyframed; layers follow the frame through the
handler in ``layers.py``.
"""

from pathlib import Path

import bpy
import numpy as np
from bpy_extras import anim_utils

from planelab.axes import SENSOR_WIDTH_MM, lens_from_intrinsics, pose_to_blender, quaternions
from planelab.replay import Replay
from planelab.session import Event

SESSION_KEY = "planelab_session"
LAYER_KEY = "planelab_layer"
RAW_POINTS = "raw_points"
ARKIT_PLANES = "arkit_planes"
PLANE_ALPHA = 0.35
# SidingsAR's plane colors (PlaneStyle.swift), by material slot. Slots 0-7 follow ARKit's classification codes
# (slot 0 is an unclassified horizontal plane); slot 8 is an unclassified vertical plane.
PLANE_MATERIALS: list[tuple[str, tuple[float, float, float]]] = [
    ("none (horizontal)", (1.0, 1.0, 1.0)),
    ("wall", (0.0, 1.0, 1.0)),
    ("floor", (0.0, 1.0, 0.0)),
    ("ceiling", (1.0, 1.0, 0.0)),
    ("table", (1.0, 0.5, 0.0)),
    ("seat", (1.0, 0.5, 0.0)),
    ("window", (0.5, 0.0, 0.5)),
    ("door", (0.5, 0.0, 0.5)),
    ("none (vertical)", (0.0, 1.0, 1.0)),
]
MARKER_PREFIX = "PL "
POINT_DISPLAY = "PlaneLab point display"
RAW_POINT_COLOR = (1.0, 0.85, 0.1, 1.0)
RAW_POINT_RADIUS_M = 0.01


def collection_name(bundle: Path) -> str:
    return f"PlaneLab {bundle.name.removesuffix('.planelab')}"


def build_session(scene: bpy.types.Scene, bundle: Path, replay: Replay, events: list[Event]) -> bpy.types.Collection:
    """Replaces any earlier import of the same recording."""
    name = collection_name(bundle)
    remove_collection(name)
    collection = bpy.data.collections.new(name)
    scene.collection.children.link(collection)
    collection[SESSION_KEY] = str(bundle)

    configure_scene(scene, replay)
    camera = add_camera(collection, name, replay)
    add_video(camera, bundle, replay)
    add_trail(collection, name, replay)
    add_raw_points(collection, name, bundle)
    add_arkit_planes(collection, name, bundle)
    add_markers(scene, events)
    scene.camera = camera
    scene.frame_set(1)
    return collection


def configure_scene(scene: bpy.types.Scene, replay: Replay) -> None:
    """Delivered frame rate (SPEC §3.4), frame range 1 … last idx + 1, and the captured image size."""
    scene.render.fps = replay.fps
    scene.render.fps_base = 1.0
    scene.frame_start = 1
    scene.frame_end = int(replay.idx[-1]) + 1 if len(replay) else 1
    scene.render.resolution_x = replay.width
    scene.render.resolution_y = replay.height
    scene.render.resolution_percentage = 100


def add_camera(collection: bpy.types.Collection, name: str, replay: Replay) -> bpy.types.Object:
    data = bpy.data.cameras.new(f"{name} camera")
    data.sensor_fit = "HORIZONTAL"
    data.sensor_width = SENSOR_WIDTH_MM
    data.clip_start = 0.01
    data.clip_end = 500.0
    camera = bpy.data.objects.new(f"{name} camera", data)
    camera.rotation_mode = "QUATERNION"
    collection.objects.link(camera)
    if not len(replay):
        return camera

    frames = replay.idx.astype(np.float64) + 1
    poses = pose_to_blender(replay.cameras)
    rotations = quaternions(poses[:, :3, :3])
    channels = {("location", i): poses[:, i, 3] for i in range(3)}
    channels |= {("rotation_quaternion", i): rotations[:, i] for i in range(4)}
    keyframe(camera, "OBJECT", frames, channels)

    lenses = [lens_from_intrinsics(k[0, 0], k[0, 2], k[1, 2], replay.width, replay.height) for k in replay.intrinsics]
    keyframe(
        data,
        "CAMERA",
        frames,
        {
            ("lens", 0): np.array([lens.lens_mm for lens in lenses]),
            ("shift_x", 0): np.array([lens.shift_x for lens in lenses]),
            ("shift_y", 0): np.array([lens.shift_y for lens in lenses]),
        },
    )
    return camera


def add_video(camera: bpy.types.Object, bundle: Path, replay: Replay) -> bpy.types.MovieClip | None:
    """The recording's video as the camera's background (SPEC.md §6, §15 R2).

    Blender drops the empty edit a leading gap leaves in the file, so the clip's first image lands on its first frame.
    Starting the clip at ``1 + first image idx`` puts every image on frame ``idx + 1``; later gaps are kept by Blender,
    which holds the previous image through them.
    """
    video = bundle / "video.mov"
    if not video.is_file() or replay.first_image is None:
        return None
    clip = bpy.data.movieclips.load(str(video))
    clip.frame_start = 1 + replay.first_image
    camera.data.show_background_images = True
    background = camera.data.background_images.new()
    background.source = "MOVIE_CLIP"
    background.clip = clip
    background.alpha = 1.0
    background.display_depth = "BACK"
    background.frame_method = "FIT"
    return clip


def keyframe(
    owner: bpy.types.ID, id_type: str, frames: np.ndarray, channels: dict[tuple[str, int], np.ndarray]
) -> None:
    """One key per frame per channel, written in bulk through Blender 5's slotted-action API."""
    animation = owner.animation_data_create()
    action = bpy.data.actions.new(f"{owner.name} replay")
    slot = action.slots.new(id_type=id_type, name=owner.name)
    animation.action = action
    animation.action_slot = slot
    channelbag = anim_utils.action_ensure_channelbag_for_slot(action, slot)
    for (path, index), values in channels.items():
        curve = channelbag.fcurves.new(path, index=index)
        curve.keyframe_points.add(len(frames))
        co = np.empty(2 * len(frames))
        co[0::2] = frames
        co[1::2] = values
        curve.keyframe_points.foreach_set("co", co)
        curve.update()


def add_trail(collection: bpy.types.Collection, name: str, replay: Replay) -> bpy.types.Object:
    """The camera's whole path as a static polyline."""
    mesh = bpy.data.meshes.new(f"{name} trail")
    if len(replay):
        positions = pose_to_blender(replay.cameras)[:, :3, 3]
        edges = [(i, i + 1) for i in range(len(positions) - 1)]
        mesh.from_pydata(positions.tolist(), edges, [])
    trail = bpy.data.objects.new(f"{name} trail", mesh)
    collection.objects.link(trail)
    return trail


def add_raw_points(collection: bpy.types.Collection, name: str, bundle: Path) -> bpy.types.Object:
    """An empty mesh that the frame handler fills with the current frame's raw feature points."""
    mesh = bpy.data.meshes.new(f"{name} raw points")
    points = bpy.data.objects.new(f"{name} raw points", mesh)
    points[LAYER_KEY] = RAW_POINTS
    points[SESSION_KEY] = str(bundle)
    collection.objects.link(points)
    material = bpy.data.materials.get("PlaneLab raw points") or bpy.data.materials.new("PlaneLab raw points")
    material.diffuse_color = RAW_POINT_COLOR
    show_as_points(points, material, RAW_POINT_RADIUS_M)
    return points


def add_arkit_planes(collection: bpy.types.Collection, name: str, bundle: Path) -> bpy.types.Object:
    """An empty mesh that the frame handler fills with ARKit's planes as they were at the current frame."""
    mesh = bpy.data.meshes.new(f"{name} ARKit planes")
    for label, rgb in PLANE_MATERIALS:
        material_name = f"PlaneLab ARKit {label}"
        material = bpy.data.materials.get(material_name) or bpy.data.materials.new(material_name)
        material.diffuse_color = (*rgb, PLANE_ALPHA)
        mesh.materials.append(material)
    planes = bpy.data.objects.new(f"{name} ARKit planes", mesh)
    planes[LAYER_KEY] = ARKIT_PLANES
    planes[SESSION_KEY] = str(bundle)
    planes.show_transparent = True
    collection.objects.link(planes)
    return planes


def plane_material_slot(classification: int | None, alignment: int | None) -> int:
    """Slot in ``PLANE_MATERIALS``: the classification code, or 8 for an unclassified vertical plane."""
    code = classification or 0
    if code == 0 and alignment == 1:
        return len(PLANE_MATERIALS) - 1
    return code if 0 <= code < len(PLANE_MATERIALS) - 1 else 0


def show_as_points(obj: bpy.types.Object, material: bpy.types.Material, radius: float) -> None:
    """Loose vertices are invisible outside Edit Mode, so a geometry-nodes modifier turns them into points."""
    modifier = obj.modifiers.new("PlaneLab display", "NODES")
    modifier.node_group = point_display_group()
    for item in modifier.node_group.interface.items_tree:
        if item.item_type == "SOCKET" and item.in_out == "INPUT":
            if item.name == "Material":
                modifier[item.identifier] = material
            elif item.name == "Radius":
                modifier[item.identifier] = radius


def point_display_group() -> bpy.types.NodeTree:
    group = bpy.data.node_groups.get(POINT_DISPLAY)
    if group is not None:
        return group
    group = bpy.data.node_groups.new(POINT_DISPLAY, "GeometryNodeTree")
    group.interface.new_socket("Geometry", in_out="INPUT", socket_type="NodeSocketGeometry")
    group.interface.new_socket("Material", in_out="INPUT", socket_type="NodeSocketMaterial")
    radius = group.interface.new_socket("Radius", in_out="INPUT", socket_type="NodeSocketFloat")
    radius.default_value = RAW_POINT_RADIUS_M
    group.interface.new_socket("Geometry", in_out="OUTPUT", socket_type="NodeSocketGeometry")

    inputs = group.nodes.new("NodeGroupInput")
    to_points = group.nodes.new("GeometryNodeMeshToPoints")
    set_material = group.nodes.new("GeometryNodeSetMaterial")
    outputs = group.nodes.new("NodeGroupOutput")
    group.links.new(inputs.outputs["Geometry"], to_points.inputs["Mesh"])
    group.links.new(inputs.outputs["Radius"], to_points.inputs["Radius"])
    group.links.new(to_points.outputs["Points"], set_material.inputs["Geometry"])
    group.links.new(inputs.outputs["Material"], set_material.inputs["Material"])
    group.links.new(set_material.outputs["Geometry"], outputs.inputs["Geometry"])
    return group


def add_markers(scene: bpy.types.Scene, events: list[Event]) -> None:
    """Session events as timeline markers at frame idx + 1; markers from an earlier import are replaced."""
    for marker in [m for m in scene.timeline_markers if m.name.startswith(MARKER_PREFIX)]:
        scene.timeline_markers.remove(marker)
    for event in events:
        scene.timeline_markers.new(f"{MARKER_PREFIX}{event.kind} {event.detail}", frame=event.frame_idx + 1)


def remove_collection(name: str) -> None:
    collection = bpy.data.collections.get(name)
    if collection is None:
        return
    for obj in list(collection.objects):
        data = obj.data
        if isinstance(data, bpy.types.Camera):
            for background in list(data.background_images):
                if background.clip is not None and background.clip.users <= 1:
                    bpy.data.movieclips.remove(background.clip)
        for owner in (obj, data):
            if owner is not None and owner.animation_data and owner.animation_data.action:
                bpy.data.actions.remove(owner.animation_data.action)
        bpy.data.objects.remove(obj)
        if isinstance(data, bpy.types.Mesh):
            bpy.data.meshes.remove(data)
        elif isinstance(data, bpy.types.Camera):
            bpy.data.cameras.remove(data)
    bpy.data.collections.remove(collection)
