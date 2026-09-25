"""``python -m planelab`` (SPEC.md §5.5). Every command also has a Blender operator (L7); both call the same core.

Commands so far: ``info``, ``peek``, ``blend`` and ``synth``; ``run`` and ``export`` arrive with T20 (SPEC §18).
"""

import argparse
import json
import os
import subprocess
import sys
from dataclasses import asdict
from pathlib import Path

from planelab import __version__
from planelab.cloud import compare_recorded, describe_comparison
from planelab.config import config_from_meta
from planelab.info import describe, summarize
from planelab.log import setup_logging
from planelab.peek import table_counts, write_peek
from planelab.replay import load_replay
from planelab.session import SessionError, open_session
from planelab.synth import SCENES, SynthParams, write_synthetic

DEFAULT_BLENDER = "/Applications/Blender.app/Contents/MacOS/Blender"
REPLAY_SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "replay_blend.py"


def _info(args: argparse.Namespace) -> int:
    with open_session(args.bundle) as session:
        info = summarize(session)
        comparison = None
        if args.check_cloud:
            replay = load_replay(session)
            comparison = compare_recorded(replay, session.cloud_rows(), config_from_meta(session.meta))
    if args.json:
        data = asdict(info)
        if comparison is not None:
            data["cloud_check"] = asdict(comparison)
        print(json.dumps(data, indent=2))
    else:
        print(describe(info))
        if comparison is not None:
            print(describe_comparison(comparison))
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


def _synth(args: argparse.Namespace) -> int:
    params = SynthParams(scene=args.scene, seed=args.seed, seconds=args.seconds, fps=args.fps)
    scene = write_synthetic(args.out.expanduser(), params)
    names = ", ".join(p.name for p in scene.planes)
    print(f"wrote {args.out}: {params.scene}, {scene.stats['frames']} frames, planes: {names}")
    print(f"  {scene.stats['plane_features']} features on planes, {scene.stats['clutter_features']} clutter")
    print(f"  truth: {args.out / 'synth_truth.json'}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="planelab", description="Plane Lab: replay SidingsAR recordings.")
    parser.add_argument("--version", action="version", version=f"planelab {__version__}")
    commands = parser.add_subparsers(dest="command", required=True)

    info = commands.add_parser("info", help="duration, frames, drops, tracking, point range, site")
    info.add_argument("bundle", type=Path, help="a .planelab folder or its zip")
    info.add_argument("--json", action="store_true", help="machine-readable output")
    info.add_argument(
        "--check-cloud",
        action="store_true",
        help="replay the recording through the Mac's accumulator and compare it with the phone's recorded cloud",
    )
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

    synth = commands.add_parser("synth", help="write a synthetic session with known planes (no video)")
    synth.add_argument("out", type=Path, help="the .planelab folder to create")
    synth.add_argument("--scene", choices=SCENES, default="facade")
    synth.add_argument("--seed", type=int, default=7)
    synth.add_argument("--seconds", type=float, default=10.0)
    synth.add_argument("--fps", type=int, default=30)
    synth.set_defaults(handler=_synth)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    setup_logging(console=True)
    try:
        return int(args.handler(args))
    except SessionError as error:
        print(f"planelab: {error}", file=sys.stderr)
        return 2
