"""Layers that follow the current frame (SPEC.md §6): a frame-change handler refills each layer's mesh from data
cached per recording. Nothing but the camera is keyframed, so scrubbing costs one slice and one mesh write per layer.
"""

import logging
from dataclasses import dataclass
from pathlib import Path

import bpy
import numpy as np
from bpy.app.handlers import persistent

from planelab.axes import points_to_blender
from planelab.cloud import CloudTimeline, load_or_build
from planelab.planes import PlaneTimeline, boundary_world
from planelab.replay import Replay, load_replay
from planelab.session import SessionError, open_session

from .build import ARKIT_PLANES, AVERAGED_CLOUD, LAYER_KEY, RAW_POINTS, SESSION_KEY, plane_material_slot

log = logging.getLogger(__name__)


@dataclass(slots=True, frozen=True)
class Loaded:
    replay: Replay
    planes: PlaneTimeline
    cloud: CloudTimeline


_sessions: dict[str, Loaded] = {}


def remember(bundle: Path, replay: Replay, planes: PlaneTimeline, cloud: CloudTimeline) -> None:
    _sessions[str(bundle)] = Loaded(replay, planes, cloud)


def loaded(bundle: str) -> Loaded | None:
    """The cached data of a recording, read from disk the first time (for example after opening a .blend)."""
    if bundle not in _sessions:
        try:
            with open_session(Path(bundle)) as session:
                replay = load_replay(session)
                _sessions[bundle] = Loaded(
                    replay, PlaneTimeline(session.anchors()), load_or_build(session.bundle, replay)
                )
        except SessionError as error:
            log.warning("layer source unavailable: %s", error)
            return None
    return _sessions[bundle]


def set_vertices(mesh: bpy.types.Mesh, points: np.ndarray) -> None:
    mesh.clear_geometry()
    if len(points):
        mesh.vertices.add(len(points))
        mesh.vertices.foreach_set("co", points.astype(np.float32).ravel())
    mesh.update()


def set_cloud(mesh: bpy.types.Mesh, points: np.ndarray, samples: np.ndarray) -> None:
    """Vertices plus a ``samples`` attribute, which the display group reads to pick each point's color."""
    set_vertices(mesh, points)
    if len(points):
        attribute = mesh.attributes.new("samples", "FLOAT", "POINT")
        attribute.data.foreach_set("value", samples.astype(np.float32))
        mesh.update()


def set_planes(mesh: bpy.types.Mesh, timeline: PlaneTimeline, idx: int) -> None:
    """One polygon per ARKit plane alive at ``idx``, colored by classification."""
    polygons = []
    slots = []
    for anchor in timeline.at(idx):
        boundary = boundary_world(anchor)
        if len(boundary) >= 3:
            polygons.append(points_to_blender(boundary))
            slots.append(plane_material_slot(anchor.classification, anchor.alignment))
    mesh.clear_geometry()
    if polygons:
        vertices = np.concatenate(polygons)
        starts = np.cumsum([0] + [len(p) for p in polygons[:-1]])
        faces = [list(range(start, start + len(p))) for start, p in zip(starts, polygons, strict=True)]
        mesh.from_pydata(vertices.tolist(), [], faces)
        mesh.polygons.foreach_set("material_index", slots)
    mesh.update()


def update_layers(scene: bpy.types.Scene) -> None:
    idx = scene.frame_current - 1
    for obj in scene.objects:
        layer = obj.get(LAYER_KEY)
        if layer not in (RAW_POINTS, AVERAGED_CLOUD, ARKIT_PLANES) or obj.type != "MESH":
            continue
        data = loaded(obj[SESSION_KEY])
        if data is None:
            continue
        if layer == RAW_POINTS:
            set_vertices(obj.data, points_to_blender(data.replay.points_at(idx)))
        elif layer == AVERAGED_CLOUD:
            points, samples = data.cloud.at(idx)
            set_cloud(obj.data, points_to_blender(points), samples)
        else:
            set_planes(obj.data, data.planes, idx)


@persistent
def on_frame_change(scene: bpy.types.Scene, *_: object) -> None:
    update_layers(scene)


@persistent
def on_load(*_: object) -> None:
    """A newly opened file shows its layers at the current frame right away, not only after the first frame change."""
    _sessions.clear()
    scene = bpy.context.scene
    if scene is not None:
        update_layers(scene)


def register() -> None:
    if on_frame_change not in bpy.app.handlers.frame_change_post:
        bpy.app.handlers.frame_change_post.append(on_frame_change)
    if on_load not in bpy.app.handlers.load_post:
        bpy.app.handlers.load_post.append(on_load)


def unregister() -> None:
    for handlers, handler in (
        (bpy.app.handlers.frame_change_post, on_frame_change),
        (bpy.app.handlers.load_post, on_load),
    ):
        while handler in handlers:
            handlers.remove(handler)
    _sessions.clear()
