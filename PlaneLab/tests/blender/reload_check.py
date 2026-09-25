"""Reload Scripts (F3) must load the add-on's current code, not only its top file (2026-10-01: a Blender started
before schema v3 kept the old reader through F3, refused the new recordings and showed no layers).

Run inside Blender (``tests/test_blender.py`` does this):
    Blender --background --factory-startup --python-exit-code 1 --python tests/blender/reload_check.py -- <bundle>
"""

import importlib
import logging
import sqlite3
import sys
from pathlib import Path

import bpy

PLANELAB = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PLANELAB / "blender"))

import planelab_blender  # noqa: E402


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def frame_handlers(module: object) -> int:
    return sum(1 for h in bpy.app.handlers.frame_change_post if getattr(h, "__module__", "") == module.__name__)


def main(bundle: Path) -> None:
    planelab_blender.register()
    old_layers = sys.modules["planelab_blender.layers"]
    old_session = sys.modules["planelab.session"]
    check(frame_handlers(old_layers) == 1, "one frame handler after register")

    # What F3 does: unregister every add-on, reload its top module, register it again (Blender's addon_utils).
    planelab_blender.unregister()
    importlib.reload(planelab_blender)
    planelab_blender.register()
    new_layers = sys.modules["planelab_blender.layers"]
    check(new_layers is not old_layers, "the layers module was reloaded")
    check(sys.modules["planelab.session"] is not old_session, "the core reader was reloaded")
    check(sum(1 for h in bpy.app.handlers.frame_change_post if h.__name__ == "on_frame_change") == 1, "one handler")
    print("RELOAD OK")

    # A recording the reader refuses: logged to planelab.log and listed for the Plane Lab tab, not silent.
    with sqlite3.connect(bundle / "session.sqlite") as db:
        db.execute("UPDATE meta SET value = '99' WHERE key = 'schema_version'")
    check(new_layers.loaded(str(bundle)) is None, "an unreadable recording loads nothing")
    errors = new_layers.load_errors()
    check(str(bundle) in errors and "'99' is not supported" in errors[str(bundle)], f"error listed: {errors}")
    for handler in logging.getLogger("planelab").handlers:
        handler.flush()
    print("ERROR LISTED OK")
    planelab_blender.unregister()


if __name__ == "__main__":
    main(Path(sys.argv[sys.argv.index("--") + 1]).resolve())
