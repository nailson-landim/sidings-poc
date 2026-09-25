"""The RANSAC probe over the video replay (2026-10-01): ``<recording>/lab/ransac_replay.blend``.

    python ransac_replay.py 20261001-142809.planelab [--every 10] [more recordings]

The file is the normal Plane Lab replay (camera, video, cloud, ARKit and X1 layers; ``replay.blend`` is left alone) plus
the probe run on the cloud as it was every ``--every`` seconds. Each checkpoint's planes (their points, screen-sized,
and a translucent 2-98 % extent rectangle) show from that moment until the next checkpoint, so playing through the
camera (Numpad 0) shows what RANSAC would have found by then, over the video. Vertical planes are warm colours,
horizontal ones cool, by size within a checkpoint; there's no tracking, so colours can change between checkpoints.
"""

import argparse
import os
import subprocess
import tempfile
from pathlib import Path

import numpy as np
from ransac_probe import probe

from planelab.axes import points_to_blender
from planelab.cloud import session_cloud
from planelab.replay import load_replay
from planelab.session import open_session

BLENDER = os.environ.get("BLENDER", "/Applications/Blender.app/Contents/MacOS/Blender")
BUILDER = Path(__file__).with_name("ransac_replay_blender.py")


def write_replay(name: str, every_s: float) -> Path:
    bundle = Path.home() / "PlaneLab/sessions" / name
    with open_session(bundle) as session:
        replay = load_replay(session)
        cloud, _ = session_cloud(session, replay)
    last = len(replay) - 1
    step = max(1, round(every_s * replay.fps))
    checkpoints = sorted({*range(step, last, step), last})
    starts, names, kinds, ranks, offsets, chunks, corners, owners = [], [], [], [], [0], [], [], []
    for k, idx in enumerate(checkpoints):
        points, _ = cloud.at(idx)
        if len(points) < 150:
            continue
        seen = replay.cameras[: idx + 1 : max(1, (idx + 1) // 300), :3, 3]
        planes = probe(points.astype(np.float64), seen)
        rank = {"V": 0, "H": 0}
        for plane in planes:
            width, height = plane.size
            names.append(
                f"{plane.kind}{rank[plane.kind]} {len(plane.inliers)} pts {width:.1f}x{height:.1f} m "
                f"off {plane.offset:+.2f} rms {plane.rms * 100:.0f} cm"
            )
            kinds.append(plane.kind)
            ranks.append(rank[plane.kind])
            rank[plane.kind] += 1
            chunks.append(points_to_blender(points[plane.inliers]))
            offsets.append(offsets[-1] + len(plane.inliers))
            corners.append(points_to_blender(plane.corners))
            owners.append(k)
        starts.append((k, idx, len(points), len(planes)))
        print(
            f"  {name} checkpoint {idx / replay.fps:5.0f} s (frame {idx + 1}): {len(points)} pts, {len(planes)} planes"
        )
    out = bundle / "lab" / "ransac_replay.blend"
    with tempfile.TemporaryDirectory() as scratch:
        data = Path(scratch) / "replay.npz"
        np.savez(
            data,
            checkpoint_frames=np.array([idx + 1 for idx in checkpoints]),
            checkpoint_seconds=np.array([idx / replay.fps for idx in checkpoints]),
            last_frame=last + 1,
            names=np.array(names),
            kinds=np.array(kinds),
            ranks=np.array(ranks),
            owners=np.array(owners),
            offsets=np.array(offsets),
            points=np.concatenate(chunks) if chunks else np.empty((0, 3)),
            corners=np.array(corners).reshape(-1, 4, 3),
        )
        result = subprocess.run(
            [BLENDER, "--background", "--factory-startup", "--python-exit-code", "1", "--python", str(BUILDER), "--",
             str(data), str(bundle), str(out)],
            capture_output=True, text=True, check=False,
        )  # fmt: skip
    if result.returncode != 0:
        raise SystemExit(result.stdout[-3000:] + result.stderr[-3000:])
    print(f"{name}: {len(checkpoints)} checkpoints, {len(names)} planes -> {out}")
    return out


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("recordings", nargs="+")
    parser.add_argument("--every", type=float, default=10.0, help="seconds between checkpoints (default 10)")
    args = parser.parse_args()
    for recording in args.recordings:
        write_replay(recording, args.every)
