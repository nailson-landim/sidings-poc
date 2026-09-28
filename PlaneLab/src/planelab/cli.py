"""``python -m planelab`` (SPEC.md §5.5). Every command also has a Blender operator (L7); both call the same core.

Commands so far: ``info``. ``run``, ``synth`` and ``export`` arrive with their tasks (SPEC.md §18).
"""

import argparse
import json
import sys
from dataclasses import asdict
from pathlib import Path

from planelab import __version__
from planelab.info import describe, summarize
from planelab.log import setup_logging
from planelab.session import SessionError, open_session


def _info(args: argparse.Namespace) -> int:
    with open_session(args.bundle) as session:
        info = summarize(session)
    print(json.dumps(asdict(info), indent=2) if args.json else describe(info))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="planelab", description="Plane Lab: replay SidingsAR recordings.")
    parser.add_argument("--version", action="version", version=f"planelab {__version__}")
    commands = parser.add_subparsers(dest="command", required=True)

    info = commands.add_parser("info", help="duration, frames, drops, tracking, point range, site")
    info.add_argument("bundle", type=Path, help="a .planelab folder or its zip")
    info.add_argument("--json", action="store_true", help="machine-readable output")
    info.set_defaults(handler=_info)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    setup_logging(console=True)
    try:
        return int(args.handler(args))
    except SessionError as error:
        print(f"planelab: {error}", file=sys.stderr)
        return 2
