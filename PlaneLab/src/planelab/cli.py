"""``python -m planelab`` (SPEC.md §5.5). Every command also has a Blender operator (L7); both call the same core.

Commands so far: ``info`` and ``peek``. ``run``, ``synth`` and ``export`` arrive with their tasks (SPEC.md §18).
"""

import argparse
import json
import sys
from dataclasses import asdict
from pathlib import Path

from planelab import __version__
from planelab.info import describe, summarize
from planelab.log import setup_logging
from planelab.peek import table_counts, write_peek
from planelab.session import SessionError, open_session


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
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    setup_logging(console=True)
    try:
        return int(args.handler(args))
    except SessionError as error:
        print(f"planelab: {error}", file=sys.stderr)
        return 2
