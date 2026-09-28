"""``python -m planelab`` (SPEC.md §5.5). Every command also has a Blender operator (L7); both call the same core.

Commands so far: ``info``, ``peek`` and ``blend``; ``run``, ``synth`` and ``export`` arrive with their tasks (SPEC §18).
"""

import argparse
import json
import os
import subprocess
import sys
from dataclasses import asdict
from pathlib import Path

from planelab import __version__
from planelab.info import describe, summarize
from planelab.log import setup_logging
from planelab.peek import table_counts, write_peek
from planelab.session import SessionError, open_session

DEFAULT_BLENDER = "/Applications/Blender.app/Contents/MacOS/Blender"
REPLAY_SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "replay_blend.py"


def _info(args: argparse.Namespace) -> int:
    with open_session(args.bundle) as session:
        info = summarize(session)
    print(json.dumps(asdict(info), indent=2) if args.json else describe(info))
    return 0


def _peek(args: argparse.Namespace) -> int:
    with open_session(args.bundle) as session:
        peek = write_peek(session, out=args.out, csv_path=args.csv)
    print(f"wrote {peek}")
    for table, count in table_counts(peek).items():
        print(f"  {table:10} {count:>9,} rows")
    if args.csv:
        print(f"frames as CSV: {args.csv}")
    print("Open it in any SQLite browser; the _about table explains every column.")
    return 0


def _blend(args: argparse.Namespace) -> int:
    blender = Path(args.blender or os.environ.get("BLENDER", DEFAULT_BLENDER))
    if not blender.exists():
        print(f"planelab: Blender not found at {blender} (set $BLENDER or pass --blender)", file=sys.stderr)
        return 2
    if not REPLAY_SCRIPT.exists():
        print(f"planelab: {REPLAY_SCRIPT} is missing; `blend` runs from a repository checkout", file=sys.stderr)
        return 2
    with open_session(args.bundle) as session:
        bundle = session.bundle
    out = (args.out or bundle / "lab" / "replay.blend").expanduser().resolve()
    command = [str(blender), "--background", "--factory-startup", "--python-exit-code", "1"]
    command += ["--python", str(REPLAY_SCRIPT), "--", str(bundle), str(out)]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0 or not out.is_file():
        print(f"planelab: Blender failed:\n{result.stdout[-2000:]}{result.stderr[-2000:]}", file=sys.stderr)
        return 1
    print(f"saved {out}")
    print("Open it in Blender with the Plane Lab extension enabled; it opens looking through the recorded camera.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="planelab", description="Plane Lab: replay SidingsAR recordings.")
    parser.add_argument("--version", action="version", version=f"planelab {__version__}")
    commands = parser.add_subparsers(dest="command", required=True)

    info = commands.add_parser("info", help="duration, frames, drops, tracking, point range, site")
    info.add_argument("bundle", type=Path, help="a .planelab folder or its zip")
    info.add_argument("--json", action="store_true", help="machine-readable output")
    info.set_defaults(handler=_info)

    peek = commands.add_parser(
        "peek", help="write a readable copy (every BLOB decoded, every column explained) to <bundle>/lab/peek.sqlite"
    )
    peek.add_argument("bundle", type=Path, help="a .planelab folder or its zip")
    peek.add_argument("--out", type=Path, help="where to write it (default: <bundle>/lab/peek.sqlite)")
    peek.add_argument("--csv", type=Path, help="also write the frames table as CSV here")
    peek.set_defaults(handler=_peek)

    blend = commands.add_parser(
        "blend", help="save a ready-to-open Blender file of the recording to <bundle>/lab/replay.blend"
    )
    blend.add_argument("bundle", type=Path, help="a .planelab folder or its zip")
    blend.add_argument("--out", type=Path, help="where to write it (default: <bundle>/lab/replay.blend)")
    blend.add_argument("--blender", help=f"the Blender executable (default: $BLENDER or {DEFAULT_BLENDER})")
    blend.set_defaults(handler=_blend)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    setup_logging(console=True)
    try:
        return int(args.handler(args))
    except SessionError as error:
        print(f"planelab: {error}", file=sys.stderr)
        return 2
