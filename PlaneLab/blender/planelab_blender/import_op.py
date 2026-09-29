"""File > Import > Plane Lab Session (SPEC.md §6)."""

import logging
from pathlib import Path

import bpy
from bpy.props import StringProperty
from bpy_extras.io_utils import ImportHelper

from planelab.cloud import session_cloud
from planelab.planes import PlaneTimeline
from planelab.replay import load_replay
from planelab.session import SessionError, open_session

from . import layers
from .build import build_session

log = logging.getLogger(__name__)


def bundle_from(path: Path) -> Path:
    """The recording a picked path belongs to: a file inside a .planelab folder means that folder."""
    if path.is_file() and path.suffix.lower() in {".sqlite", ".mov"}:
        return path.parent
    return path


class PLANELAB_OT_import_session(bpy.types.Operator, ImportHelper):
    """Import a SidingsAR recording: pick session.sqlite inside its .planelab folder, or a zip of the folder"""

    bl_idname = "planelab.import_session"
    bl_label = "Import Plane Lab Session"
    bl_options = {"REGISTER", "UNDO"}

    filename_ext = ".sqlite"
    filter_glob: StringProperty(default="*.sqlite;*.zip;*.mov", options={"HIDDEN"})  # type: ignore[valid-type]

    def execute(self, context: bpy.types.Context) -> set[str]:
        try:
            with open_session(bundle_from(Path(self.filepath))) as session:
                replay = load_replay(session)
                planes = PlaneTimeline(session.anchors())
                events = session.events()
                bundle = session.bundle
                cloud, source = session_cloud(session, replay)
        except SessionError as error:
            self.report({"ERROR"}, str(error))
            return {"CANCELLED"}
        layers.remember(bundle, replay, planes, cloud)
        build_session(context.scene, bundle, replay, events)
        final = len(cloud.at(int(replay.idx[-1]))[0]) if len(replay) else 0
        message = (
            f"Imported {bundle.name}: {len(replay)} frames at {replay.fps} fps, {len(planes)} ARKit planes, "
            f"{final} averaged points at the end ({source} cloud)"
        )
        log.info(message)
        self.report({"INFO"}, message)
        return {"FINISHED"}


def menu_import(menu: bpy.types.Menu, _context: bpy.types.Context) -> None:
    menu.layout.operator(PLANELAB_OT_import_session.bl_idname, text="Plane Lab Session (.planelab)")


def register() -> None:
    bpy.utils.register_class(PLANELAB_OT_import_session)
    bpy.types.TOPBAR_MT_file_import.append(menu_import)


def unregister() -> None:
    bpy.types.TOPBAR_MT_file_import.remove(menu_import)
    bpy.utils.unregister_class(PLANELAB_OT_import_session)
