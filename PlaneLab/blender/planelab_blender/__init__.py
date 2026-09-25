"""Plane Lab for Blender (SPEC.md §6): import SidingsAR recordings and replay them on the timeline.

The core (``planelab``, numpy only) ships inside the extension under ``vendor/``. In the repository ``vendor/planelab``
is a symlink to ``PlaneLab/src/planelab`` so edits show up after Reload Scripts; ``scripts/build_extension.sh`` copies
the real files into the zip (SPEC.md §17.4 P6).
"""

import logging
import sys
from pathlib import Path

if "layers" in locals():
    # Reload Scripts (F3) re-runs only this file: Blender's addon_utils reloads an add-on's top module, so the
    # submodules and the core would keep the code they had when Blender started. Drop them so the imports below load
    # the files as they are now. Blender has already called unregister() on the old modules. A reload keeps this
    # module's namespace, so the old submodules are unbound here too, or `from . import` would hand them back.
    for _name in [m for m in sys.modules if m == "planelab" or m.startswith(("planelab.", f"{__name__}."))]:
        del sys.modules[_name]
        if _name.startswith(f"{__name__}."):
            globals().pop(_name.removeprefix(f"{__name__}.").split(".")[0], None)

_VENDOR = str(Path(__file__).resolve().parent / "vendor")
if _VENDOR not in sys.path:
    # The core is imported as the top-level package `planelab`, the same name the CLI and the Recompute subprocess use.
    sys.path.insert(0, _VENDOR)

from planelab.log import setup_logging  # noqa: E402

from . import import_op, layers, panel, pick_op  # noqa: E402


def register() -> None:
    # The glue logs under this package's name (bl_ext.<repository>.planelab_blender.*), outside the "planelab"
    # logger the file handler sits on, so its warnings get the same handlers.
    core = setup_logging()
    package = logging.getLogger(__name__)
    package.setLevel(core.level)
    for handler in core.handlers:
        if handler not in package.handlers:
            package.addHandler(handler)
    layers.register()
    import_op.register()
    pick_op.register()
    panel.register()


def unregister() -> None:
    panel.unregister()
    pick_op.unregister()
    import_op.unregister()
    layers.unregister()
