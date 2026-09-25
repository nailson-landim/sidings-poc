"""Layers that follow the current frame (SPEC.md §6): a frame-change handler refills each layer's mesh from data
cached per recording, and moves the picked feature's marker. Nothing but the camera is keyframed, so scrubbing costs one
slice and one mesh write per layer.
"""

import logging
from dataclasses import dataclass, field
from pathlib import Path

import bpy
import numpy as np
from bpy.app.handlers import persistent

from planelab.axes import points_to_blender
from planelab.cloud import CloudTimeline, session_cloud
from planelab.pick import feature_at
from planelab.planes import PlaneTimeline, boundary_world
from planelab.replay import Replay, load_replay
from planelab.session import SessionError, open_session
from planelab.surfaces import RoundTimeline, SurfaceTimeline

from .build import (
    ARKIT_PLANES,
    AVERAGED_CLOUD,
    CLOUD_BAND_KEY,
    FEATURE_KEY,
    LAYER_KEY,
    PICK_SIZE,
    PICKED,
    RAW_POINTS,
    SESSION_KEY,
    X1_SURFACES,
    cloud_band,
    plane_material_slot,
    surface_material_slot,
)

log = logging.getLogger(__name__)


@dataclass(slots=True, frozen=True)
class Loaded:
    replay: Replay
    planes: PlaneTimeline
    cloud: CloudTimeline
    surfaces: SurfaceTimeline
    """The phone engine's tracks (schema v3); empty for older recordings."""
    rounds: RoundTimeline = field(default_factory=lambda: RoundTimeline([]))
    """What each round cost (schema v4); empty for older recordings."""


_sessions: dict[str, Loaded] = {}
_errors: dict[str, str] = {}
"""Recordings whose layers couldn't be loaded, with why; the Plane Lab tab shows them."""


def remember(
    bundle: Path,
    replay: Replay,
    planes: PlaneTimeline,
    cloud: CloudTimeline,
    surfaces: SurfaceTimeline,
    rounds: RoundTimeline | None = None,
) -> None:
    _sessions[str(bundle)] = Loaded(replay, planes, cloud, surfaces, rounds or RoundTimeline([]))
    _errors.pop(str(bundle), None)


def load_errors() -> dict[str, str]:
    return dict(_errors)


def loaded(bundle: str) -> Loaded | None:
    """The cached data of a recording, read from disk the first time (for example after opening a .blend). A recording
    that can't be read is tried once per file open; the reason is logged and shown in the Plane Lab tab.
    """
    if bundle in _errors:
        return None
    if bundle not in _sessions:
        try:
            with open_session(Path(bundle)) as session:
                replay = load_replay(session)
                cloud, _ = session_cloud(session, replay)
                _sessions[bundle] = Loaded(
                    replay,
                    PlaneTimeline(session.anchors()),
                    cloud,
                    SurfaceTimeline(session.surface_rows()),
                    RoundTimeline(session.surface_round_rows()),
                )
        except SessionError as error:
            log.warning("layer source unavailable: %s", error)
            _errors[bundle] = str(error)
            return None
    return _sessions[bundle]


def set_vertices(mesh: bpy.types.Mesh, points: np.ndarray) -> None:
    mesh.clear_geometry()
    if len(points):
        mesh.vertices.add(len(points))
        mesh.vertices.foreach_set("co", points.astype(np.float32).ravel())
    mesh.update()


def set_cloud(mesh: bpy.types.Mesh, points: np.ndarray, samples: np.ndarray) -> None:
    """Vertices plus a ``samples`` attribute (each point's samples in its FIFO)."""
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
    set_polygons(mesh, polygons, slots)


def set_surfaces(mesh: bpy.types.Mesh, timeline: SurfaceTimeline, idx: int) -> None:
    """One polygon per tracked plane alive at ``idx`` (its outline), colored by track number and state."""
    polygons = []
    slots = []
    for row in timeline.at(idx):
        if row.outline is not None and len(row.outline) >= 3:
            polygons.append(points_to_blender(row.outline))
            slots.append(surface_material_slot(row.number, row.state))
    set_polygons(mesh, polygons, slots)


def set_polygons(mesh: bpy.types.Mesh, polygons: list[np.ndarray], slots: list[int]) -> None:
    mesh.clear_geometry()
    if polygons:
        vertices = np.concatenate(polygons)
        starts = np.cumsum([0] + [len(p) for p in polygons[:-1]])
        faces = [list(range(start, start + len(p))) for start, p in zip(starts, polygons, strict=True)]
        mesh.from_pydata(vertices.tolist(), [], faces)
        mesh.polygons.foreach_set("material_index", slots)
    mesh.update()


def set_marker(marker: bpy.types.Object, data: Loaded, idx: int) -> None:
    """The picked feature's marker follows it by id: on its averaged point, else its raw one, hidden when neither."""
    at = feature_at(data.replay, data.cloud, int(marker[FEATURE_KEY]), idx)
    marker.hide_viewport = at.shown is None
    if at.shown is not None:
        marker.location = points_to_blender(at.shown)[0]
    if at.distance is not None:
        marker.empty_display_size = PICK_SIZE * at.distance


def update_layers(scene: bpy.types.Scene) -> None:
    idx = scene.frame_current - 1
    for obj in scene.objects:
        layer = obj.get(LAYER_KEY)
        expected = "EMPTY" if layer == PICKED else "MESH"
        if layer not in (RAW_POINTS, AVERAGED_CLOUD, ARKIT_PLANES, X1_SURFACES, PICKED) or obj.type != expected:
            continue
        data = loaded(obj[SESSION_KEY])
        if data is None:
            continue
        if layer == RAW_POINTS:
            set_vertices(obj.data, points_to_blender(data.replay.points_at(idx)))
        elif layer == AVERAGED_CLOUD:
            points, samples = data.cloud.at(idx)
            band = obj.get(CLOUD_BAND_KEY)
            if band is not None:  # files saved before the split hold one object with the whole cloud
                keep = cloud_band(samples) == band
                points, samples = points[keep], samples[keep]
            set_cloud(obj.data, points_to_blender(points), samples)
        elif layer == PICKED:
            set_marker(obj, data, idx)
        elif layer == X1_SURFACES:
            set_surfaces(obj.data, data.surfaces, idx)
        else:
            set_planes(obj.data, data.planes, idx)


@persistent
def on_frame_change(scene: bpy.types.Scene, *_: object) -> None:
    update_layers(scene)


@persistent
def on_load(*_: object) -> None:
    """A newly opened file shows its layers at the current frame right away, not only after the first frame change."""
    _sessions.clear()
    _errors.clear()
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
    _errors.clear()
