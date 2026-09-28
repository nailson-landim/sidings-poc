"""Layers that follow the current frame (SPEC.md §6): a frame-change handler refills each layer's mesh from arrays
cached per recording. Nothing but the camera is keyframed, so scrubbing costs one slice and one mesh write per layer.
"""

import logging
from pathlib import Path

import bpy
import numpy as np
from bpy.app.handlers import persistent

from planelab.axes import points_to_blender
from planelab.replay import Replay, load_replay
from planelab.session import SessionError, open_session

from .build import LAYER_KEY, RAW_POINTS, SESSION_KEY

log = logging.getLogger(__name__)

_replays: dict[str, Replay] = {}


def remember(bundle: Path, replay: Replay) -> None:
    _replays[str(bundle)] = replay


def replay_for(bundle: str) -> Replay | None:
    """The cached arrays of a recording, loaded from disk the first time (for example after opening a .blend)."""
    if bundle not in _replays:
        try:
            with open_session(Path(bundle)) as session:
                _replays[bundle] = load_replay(session)
        except SessionError as error:
            log.warning("layer source unavailable: %s", error)
            return None
    return _replays[bundle]


def set_vertices(mesh: bpy.types.Mesh, points: np.ndarray) -> None:
    mesh.clear_geometry()
    if len(points):
        mesh.vertices.add(len(points))
        mesh.vertices.foreach_set("co", points.astype(np.float32).ravel())
    mesh.update()


def update_layers(scene: bpy.types.Scene) -> None:
    idx = scene.frame_current - 1
    for obj in scene.objects:
        if obj.get(LAYER_KEY) != RAW_POINTS or obj.type != "MESH":
            continue
        replay = replay_for(obj[SESSION_KEY])
        if replay is not None:
            set_vertices(obj.data, points_to_blender(replay.points_at(idx)))


@persistent
def on_frame_change(scene: bpy.types.Scene, *_: object) -> None:
    update_layers(scene)


@persistent
def on_load(*_: object) -> None:
    _replays.clear()


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
    _replays.clear()
