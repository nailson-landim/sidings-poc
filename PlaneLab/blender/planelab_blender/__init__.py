"""Plane Lab for Blender (SPEC.md §6): import SidingsAR recordings and replay them on the timeline.

The core (``planelab``, numpy only) ships inside the extension under ``vendor/``. In the repository ``vendor/planelab``
is a symlink to ``PlaneLab/src/planelab`` so edits show up after Reload Scripts; ``scripts/build_extension.sh`` copies
the real files into the zip (SPEC.md §17.4 P6).
"""

import sys
from pathlib import Path

_VENDOR = str(Path(__file__).resolve().parent / "vendor")
if _VENDOR not in sys.path:
    # The core is imported as the top-level package `planelab`, the same name the CLI and the Recompute subprocess use.
    sys.path.insert(0, _VENDOR)

from planelab.log import setup_logging  # noqa: E402

from . import import_op, layers, panel, pick_op  # noqa: E402


def register() -> None:
    setup_logging()
    layers.register()
    import_op.register()
    pick_op.register()
    panel.register()


def unregister() -> None:
    panel.unregister()
    pick_op.unregister()
    import_op.unregister()
    layers.unregister()
