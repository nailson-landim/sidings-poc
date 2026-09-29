"""Writes ``session-format/fixtures/cloud/golden.json``: frames plus the averaged cloud the Python accumulator (T16)
builds from them, under several settings. The Swift port (PlaneKit ``FeatureAccumulator``, SPEC.md §18 T27) replays
the same frames and must give the same cloud. ``tests/test_cloud_golden.py`` keeps the committed file equal to what
this script writes.

    python scripts/cloud_golden.py            # rewrite the committed file
"""

import json
import sys
from dataclasses import asdict
from pathlib import Path
from typing import Any

import numpy as np

from planelab.accumulate import Accumulator, run_frames
from planelab.config import AccumulateConfig, FilterConfig, GateConfig, LabConfig
from planelab.replay import Replay
from planelab.synth import look_at

GOLDEN = Path(__file__).resolve().parents[2] / "session-format" / "fixtures" / "cloud" / "golden.json"
CHECKPOINTS = (9, 19, 29)
LIMITED_FRAMES = range(12, 15)
"""Frames marked ``limited`` tracking, so ``normal_tracking_only`` has something to skip."""

CASES: dict[str, LabConfig] = {
    "default": LabConfig(),
    # A short FIFO, few ids and a low z-score: the ring wraps, ids are evicted (some in the frame that saw them),
    # and the z-score filter drops samples.
    "evict_and_wrap": LabConfig(accumulate=AccumulateConfig(max_samples=4, min_samples=3, zscore=1.2, max_ids=50)),
    "intended_with_cuts": LabConfig(
        filter=FilterConfig(near_cut_m=2.0, far_cut_m=9.0), gate=GateConfig(mode="intended", move_m=0.35)
    ),
    "upstream": LabConfig(gate=GateConfig(mode="upstream", move_m=0.05, turn_deg=1.7)),
    "normal_only": LabConfig(filter=FilterConfig(normal_tracking_only=True)),
}


def f32(values: np.ndarray) -> list[Any]:
    """Shortest decimals that read back as the same float32 (the input frames are float32 in a recording)."""
    return [float(np.format_float_positional(np.float32(v), unique=True, trim="-")) for v in values.ravel()]


def frames() -> Replay:
    """30 frames of 60 fixed features 1-10 m ahead, each seen with 1 cm noise in about 60 % of frames, with 5 %
    outliers 30 cm off (for the z-score filter). The camera slides 10 cm and turns 0.5 degrees per frame. Ids sit
    above 2^53, so a reader that goes through float64 fails.
    """
    rng = np.random.default_rng(11)
    features = np.column_stack([rng.uniform(-4, 4, 60), rng.uniform(0, 3, 60), rng.uniform(-10, -1, 60)])
    ids = (2**53 + 7919 * np.arange(60)).astype(np.uint64)
    cameras, points, point_ids, offsets = [], [], [], [0]
    for i in range(30):
        eye = np.array([0.1 * i, 1.5, 0.0])
        yaw = np.radians(0.5 * i)
        cameras.append(look_at(eye, eye + np.array([np.sin(yaw), 0.0, -np.cos(yaw)])))
        seen = np.flatnonzero(rng.random(60) < 0.6)
        noisy = features[seen] + rng.normal(0, 0.01, (len(seen), 3))
        outliers = rng.random(len(seen)) < 0.05
        noisy[outliers] += rng.choice([-0.3, 0.3], (int(outliers.sum()), 3))
        points.append(noisy.astype(np.float32))
        point_ids.append(ids[seen])
        offsets.append(offsets[-1] + len(seen))
    n = len(cameras)
    tracking = np.full(n, 2, dtype=np.int64)
    tracking[list(LIMITED_FRAMES)] = 1
    return Replay(
        idx=np.arange(n, dtype=np.int64),
        t=np.arange(n) / 15.0,
        has_image=np.zeros(n, dtype=bool),
        tracking=tracking,
        cameras=np.array(cameras, dtype=np.float32).astype(np.float64),
        intrinsics=np.tile(np.eye(3), (n, 1, 1)),
        offsets=np.array(offsets, dtype=np.int64),
        points=np.concatenate(points),
        point_ids=np.concatenate(point_ids),
        width=1920,
        height=1440,
        fps=15,
        first_image=None,
    )


def expected(replay: Replay, config: LabConfig) -> list[dict[str, Any]]:
    accumulator = Accumulator(config.accumulate)
    checkpoints = []
    for idx, acc in run_frames(replay, config, accumulator):
        if idx in CHECKPOINTS:
            cloud = acc.cloud()
            order = np.argsort(cloud.ids)
            checkpoints.append(
                {
                    "after_frame": idx,
                    "ids": [int(i) for i in cloud.ids[order]],
                    "points": [round(float(v), 9) for v in cloud.points[order].ravel()],
                    "samples": [int(n) for n in cloud.samples[order]],
                }
            )
    return checkpoints


def golden() -> dict[str, Any]:
    replay = frames()
    rows = []
    for row, idx in enumerate(replay.idx.tolist()):
        start, end = int(replay.offsets[row]), int(replay.offsets[row + 1])
        rows.append(
            {
                "idx": idx,
                "tracking": int(replay.tracking[row]),
                # Column-major, like the recording's camera BLOB (SPEC §3.2).
                "camera": f32(replay.cameras[row].T),
                "ids": [int(i) for i in replay.point_ids[start:end]],
                "points": f32(replay.points[start:end]),
            }
        )
    return {
        "about": "Frames and the averaged cloud Plane Lab's accumulator builds from them (SPEC.md T27). "
        "points are flat x, y, z lists; camera is column-major world <- camera.",
        "frames": rows,
        "cases": [
            {
                "name": name,
                "filter": asdict(config.filter),
                "gate": asdict(config.gate),
                "accumulate": asdict(config.accumulate),
                "checkpoints": expected(replay, config),
            }
            for name, config in CASES.items()
        ],
    }


def render() -> str:
    return json.dumps(golden(), separators=(",", ":")) + "\n"


def main(argv: list[str]) -> int:
    out = Path(argv[0]) if argv else GOLDEN
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(render())
    print(f"wrote {out} ({out.stat().st_size // 1024} KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
