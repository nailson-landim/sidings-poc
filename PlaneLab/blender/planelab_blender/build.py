"""Builds a recording's Blender objects (SPEC.md §6): one collection per session holding the camera, its trail and
the point and plane layers (raw points, averaged cloud, ARKit planes, the phone engine's planes), plus timeline markers.
Only the camera and the round-stats empty are keyframed; layers follow the frame through the handler in ``layers.py``.
"""

from pathlib import Path

import bpy
import numpy as np
from bpy_extras import anim_utils

from planelab.axes import SENSOR_WIDTH_MM, lens_from_intrinsics, pose_to_blender, quaternions
from planelab.replay import Replay
from planelab.session import Event, SurfaceRoundRow
from planelab.surfaces import engine_name

SESSION_KEY = "planelab_session"
LAYER_KEY = "planelab_layer"
RAW_POINTS = "raw_points"
AVERAGED_CLOUD = "averaged_cloud"
ARKIT_PLANES = "arkit_planes"
# Points keep a steady size on screen, like CurvSurf's point sprites: radius = size x distance from the recorded camera.
# 0.006 is about 9 px of radius at the recorded focal length (about 1,500 px); P27 doubled P20's 0.003. A fixed radius
# vanished at 10 m. The Plane Lab panel has a slider per layer.
CLOUD_SIZE = 0.006
# Averaged points by samples in their FIFO (CurvSurf's cloud), pale to saturated: young, averaging, well averaged.
# (label, color, upper bound). Clear of the raw points' yellow and of the ARKit plane colors below. Each band is its own
# object (``CLOUD_BAND_KEY`` holds its index), so it can be selected, hidden and sized on its own.
CLOUD_MATERIALS: list[tuple[str, tuple[float, float, float], float]] = [
    ("under 10 samples", (1.0, 0.6, 0.8), 10.0),
    ("10 to 49 samples", (0.9, 0.2, 1.0), 50.0),
    ("50+ samples", (1.0, 0.1, 0.1), float("inf")),
]
CLOUD_BAND_KEY = "planelab_band"
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
X1_SURFACES = "x1_surfaces"
"""The planes layer of the phone's engine, X1's FindSurface or X2's RANSAC (``ENGINE_KEY`` says which). The key keeps
its X1 name so layers saved in earlier .blend files still refill."""
ENGINE_KEY = "planelab_engine"
ROUND_STATS = "round_stats"
# What each round cost, one custom property of the round-stats empty per column of ``surface_round``, each keyed with
# constant interpolation at the round's frame so the Graph Editor draws it over the timeline.
ROUND_CHANNELS: tuple[str, ...] = (
    "total_ms",
    "refit_ms",
    "search_ms",
    "points",
    "unclaimed",
    "tracks",
    "confirmed",
    "refits",
    "searched",
    "planes_found",
    "hypotheses",
    "full_scores",
    "point_tests",
    "skipped",
    "thermal",
)
# The phone's tracks (EXPERIMENTS.md XD6), colored like SidingsAR's SurfaceRenderer: by track number through iOS's
# system colors (orange, blue, teal, indigo, mint, brown, yellow, green), faint while tentative, grey once stale.
# Slots 0-7 confirmed, 8-15 tentative, 16 stale.
SURFACE_PALETTE: list[tuple[str, tuple[float, float, float]]] = [
    ("orange", (1.0, 0.584, 0.0)),
    ("blue", (0.0, 0.478, 1.0)),
    ("teal", (0.188, 0.69, 0.78)),
    ("indigo", (0.345, 0.337, 0.839)),
    ("mint", (0.0, 0.78, 0.745)),
    ("brown", (0.635, 0.518, 0.369)),
    ("yellow", (1.0, 0.8, 0.0)),
    ("green", (0.204, 0.78, 0.349)),
]
SURFACE_ALPHA = {"confirmed": 0.4, "tentative": 0.15, "stale": 0.2}
SURFACE_STALE_RGB = (0.557, 0.557, 0.576)
MARKER_PREFIX = "PL "
DISPLAY_MODIFIER = "PlaneLab display"
POINT_DISPLAY = "PlaneLab point display"
RAW_POINT_COLOR = (1.0, 0.85, 0.1, 1.0)
RAW_POINT_SIZE = 0.008
SIZE_MAX = 0.05
# The picked feature (P27): an empty whose sphere keeps about 30 px of radius through the recorded camera.
PICKED = "picked"
FEATURE_KEY = "planelab_feature"
PICK_SIZE = 0.02


def collection_name(bundle: Path) -> str:
    return f"PlaneLab {bundle.name.removesuffix('.planelab')}"


def build_session(
    scene: bpy.types.Scene,
    bundle: Path,
    replay: Replay,
    events: list[Event],
    rounds: list[SurfaceRoundRow] | None = None,
    engine: str | None = None,
) -> bpy.types.Collection:
    """Replaces any earlier import of the same recording. ``rounds`` (schema v4) become the round-stats empty;
    ``engine`` is the recording's ``surface_engine`` meta."""
    name = collection_name(bundle)
    remove_collection(name)
    collection = bpy.data.collections.new(name)
    scene.collection.children.link(collection)
    collection[SESSION_KEY] = str(bundle)

    configure_scene(scene, replay)
    camera = add_camera(collection, name, replay)
    add_video(camera, bundle, replay)
    add_trail(collection, name, replay)
    add_raw_points(collection, name, bundle, camera)
    add_averaged_cloud(collection, name, bundle, camera)
    add_arkit_planes(collection, name, bundle)
    add_x1_surfaces(collection, name, bundle, engine)
    if rounds:
        add_round_stats(collection, name, bundle, rounds)
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


def add_raw_points(
    collection: bpy.types.Collection, name: str, bundle: Path, camera: bpy.types.Object
) -> bpy.types.Object:
    """An empty mesh that the frame handler fills with the current frame's raw feature points."""
    mesh = bpy.data.meshes.new(f"{name} raw points")
    points = bpy.data.objects.new(f"{name} raw points", mesh)
    points[LAYER_KEY] = RAW_POINTS
    points[SESSION_KEY] = str(bundle)
    collection.objects.link(points)
    material = bpy.data.materials.get("PlaneLab raw points") or bpy.data.materials.new("PlaneLab raw points")
    material.diffuse_color = RAW_POINT_COLOR
    modifier = points.modifiers.new(DISPLAY_MODIFIER, "NODES")
    modifier.node_group = point_display_group()
    set_inputs(modifier, Material=material, Eye=camera, Size=RAW_POINT_SIZE)
    return points


def add_averaged_cloud(
    collection: bpy.types.Collection, name: str, bundle: Path, camera: bpy.types.Object
) -> list[bpy.types.Object]:
    """The averaged cloud as it was at the current frame (what CurvSurf's app shows): one object per sample-count
    band, in a child collection so the whole cloud still toggles at once.
    """
    group = bpy.data.collections.new(f"{name} averaged cloud")
    group[SESSION_KEY] = str(bundle)
    collection.children.link(group)
    bands = []
    for band, (label, rgb, _) in enumerate(CLOUD_MATERIALS):
        object_name = f"{name} averaged cloud {label}"
        points = bpy.data.objects.new(object_name, bpy.data.meshes.new(object_name))
        points[LAYER_KEY] = AVERAGED_CLOUD
        points[CLOUD_BAND_KEY] = band
        points[SESSION_KEY] = str(bundle)
        group.objects.link(points)
        material_name = f"PlaneLab cloud {label}"
        material = bpy.data.materials.get(material_name) or bpy.data.materials.new(material_name)
        material.diffuse_color = (*rgb, 1.0)
        modifier = points.modifiers.new(DISPLAY_MODIFIER, "NODES")
        modifier.node_group = point_display_group()
        set_inputs(modifier, Material=material, Eye=camera, Size=CLOUD_SIZE)
        bands.append(points)
    return bands


def cloud_band(samples: np.ndarray) -> np.ndarray:
    """Each point's band in ``CLOUD_MATERIALS``: 0 under 10 samples, 1 for 10 to 49, 2 for 50 and more."""
    uppers = [upper for _, _, upper in CLOUD_MATERIALS[:-1]]
    return np.searchsorted(uppers, samples, side="right")


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


def add_x1_surfaces(
    collection: bpy.types.Collection, name: str, bundle: Path, engine: str | None = None
) -> bpy.types.Object:
    """An empty mesh that the frame handler fills with the phone engine's tracked planes as they were at the current
    frame (schema v3 ``surface`` rows; empty for older recordings or when the engine was off). Named after the
    engine that drew them: "RANSAC planes" or "FindSurface planes".
    """
    label = engine_name(engine)
    mesh = bpy.data.meshes.new(f"{name} {label} planes")
    for kind in ("confirmed", "tentative"):
        for color, rgb in SURFACE_PALETTE:
            mesh.materials.append(_material(f"PlaneLab surface {color} {kind}", (*rgb, SURFACE_ALPHA[kind])))
    mesh.materials.append(_material("PlaneLab surface stale", (*SURFACE_STALE_RGB, SURFACE_ALPHA["stale"])))
    surfaces = bpy.data.objects.new(f"{name} {label} planes", mesh)
    surfaces[LAYER_KEY] = X1_SURFACES
    surfaces[ENGINE_KEY] = engine or "findsurface"
    surfaces[SESSION_KEY] = str(bundle)
    surfaces.show_transparent = True
    collection.objects.link(surfaces)
    return surfaces


def add_round_stats(
    collection: bpy.types.Collection, name: str, bundle: Path, rounds: list[SurfaceRoundRow]
) -> bpy.types.Object:
    """An empty whose custom properties carry what each round of the phone's engine cost (``ROUND_CHANNELS``), keyed
    with constant interpolation at frame ``frame_idx + 1``. Select it and open the Graph Editor (or the Dope Sheet
    for when rounds ran) to see compute time over the timeline. A round replaces an earlier one on the same frame.
    """
    stats = bpy.data.objects.new(f"{name} round stats", None)
    stats.empty_display_type = "PLAIN_AXES"
    stats.empty_display_size = 0.05
    stats[LAYER_KEY] = ROUND_STATS
    stats[SESSION_KEY] = str(bundle)
    collection.objects.link(stats)
    by_frame = {r.frame_idx + 1: r for r in sorted(rounds, key=lambda r: (r.frame_idx, r.round))}
    frames = np.array(sorted(by_frame), dtype=np.float64)
    ordered = [by_frame[int(f)] for f in frames]
    # Blender holds a curve's first value backwards in time; a zero key on frame 1 keeps the time before the first round
    # at zero instead of repeating that round.
    lead = frames[0] > 1
    if lead:
        frames = np.concatenate([[1.0], frames])
    channels: dict[tuple[str, int], np.ndarray] = {}
    for channel in ROUND_CHANNELS:
        stats[channel] = 0.0
        values = [float(getattr(r, channel)) for r in ordered]
        channels[(f'["{channel}"]', 0)] = np.array(([0.0] if lead else []) + values)
    keyframe(stats, "OBJECT", frames, channels)
    action = stats.animation_data.action
    for curve in anim_utils.action_ensure_channelbag_for_slot(action, stats.animation_data.action_slot).fcurves:
        for point in curve.keyframe_points:
            point.interpolation = "CONSTANT"
    return stats


def _material(name: str, rgba: tuple[float, float, float, float]) -> bpy.types.Material:
    material = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    material.diffuse_color = rgba
    return material


def surface_material_slot(number: int, state: int | None) -> int:
    """Slot in the planes layer's materials: the track number's color, confirmed (0-7) or tentative (8-15); 16 stale."""
    if state == 2:
        return 2 * len(SURFACE_PALETTE)
    color = (number - 1) % len(SURFACE_PALETTE)
    return color if state == 1 else color + len(SURFACE_PALETTE)


def set_inputs(modifier: bpy.types.NodesModifier, **values: object) -> None:
    """Sets a geometry-nodes modifier's inputs by their names in the group's interface."""
    for item in modifier.node_group.interface.items_tree:
        if item.item_type == "SOCKET" and item.in_out == "INPUT" and item.name in values:
            modifier[item.identifier] = values[item.name]


def input_identifier(modifier: bpy.types.NodesModifier, name: str) -> str | None:
    """The modifier's key for the group input called ``name`` (``modifier[key]`` is its value)."""
    for item in modifier.node_group.interface.items_tree if modifier.node_group else ():
        if item.item_type == "SOCKET" and item.in_out == "INPUT" and item.name == name:
            return item.identifier
    return None


def existing_group(name: str) -> bpy.types.NodeTree | None:
    """The group of that name, unless it predates the screen-sized points (no Eye input): that one is rebuilt."""
    group = bpy.data.node_groups.get(name)
    if group is None:
        return None
    if any(item.item_type == "SOCKET" and item.name == "Eye" for item in group.interface.items_tree):
        return group
    bpy.data.node_groups.remove(group)
    return None


def new_points_group(name: str, size: float, material: bool = False) -> bpy.types.NodeTree:
    """A geometry-nodes group with inputs Geometry, [Material,] Eye (the recorded camera) and Size."""
    group = bpy.data.node_groups.new(name, "GeometryNodeTree")
    group.interface.new_socket("Geometry", in_out="INPUT", socket_type="NodeSocketGeometry")
    if material:
        group.interface.new_socket("Material", in_out="INPUT", socket_type="NodeSocketMaterial")
    group.interface.new_socket("Eye", in_out="INPUT", socket_type="NodeSocketObject")
    size_socket = group.interface.new_socket("Size", in_out="INPUT", socket_type="NodeSocketFloat")
    size_socket.default_value = size
    size_socket.min_value = 0.0
    size_socket.max_value = SIZE_MAX
    size_socket.description = "Point radius per metre of distance from the recorded camera"
    group.interface.new_socket("Geometry", in_out="OUTPUT", socket_type="NodeSocketGeometry")
    return group


def screen_sized_points(group: bpy.types.NodeTree, inputs: bpy.types.Node) -> bpy.types.Node:
    """Mesh to Points with radius = Size x distance to Eye, so points look the same size through the camera.

    Loose vertices are invisible outside Edit Mode, hence the conversion to points.
    """
    eye = group.nodes.new("GeometryNodeObjectInfo")
    eye.transform_space = "RELATIVE"
    group.links.new(inputs.outputs["Eye"], eye.inputs["Object"])
    position = group.nodes.new("GeometryNodeInputPosition")
    distance = group.nodes.new("ShaderNodeVectorMath")
    distance.operation = "DISTANCE"
    group.links.new(position.outputs["Position"], distance.inputs[0])
    group.links.new(eye.outputs["Location"], distance.inputs[1])
    radius = group.nodes.new("ShaderNodeMath")
    radius.operation = "MULTIPLY"
    group.links.new(distance.outputs["Value"], radius.inputs[0])
    group.links.new(inputs.outputs["Size"], radius.inputs[1])
    to_points = group.nodes.new("GeometryNodeMeshToPoints")
    group.links.new(inputs.outputs["Geometry"], to_points.inputs["Mesh"])
    group.links.new(radius.outputs["Value"], to_points.inputs["Radius"])
    return to_points


def point_display_group() -> bpy.types.NodeTree:
    group = existing_group(POINT_DISPLAY)
    if group is not None:
        return group
    group = new_points_group(POINT_DISPLAY, RAW_POINT_SIZE, material=True)
    inputs = group.nodes.new("NodeGroupInput")
    to_points = screen_sized_points(group, inputs)
    set_material = group.nodes.new("GeometryNodeSetMaterial")
    outputs = group.nodes.new("NodeGroupOutput")
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
    for obj in list(collection.all_objects):
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
    for child in list(collection.children_recursive):
        bpy.data.collections.remove(child)
    bpy.data.collections.remove(collection)
