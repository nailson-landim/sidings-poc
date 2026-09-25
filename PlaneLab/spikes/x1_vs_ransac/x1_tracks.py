"""X1's tracks in a recording, judged against the cloud they fit (EXPERIMENTS.md, X1 verdict, 2026-10-01).

    python spikes/x1_vs_ransac/x1_tracks.py 20261001-142809.planelab 20261001-143156.planelab

For each track: kind (H horizontal, V vertical, S slanted), fate, lifetime, last shape. For the final tracks: the cloud
points within 15 cm of the plane, their 2-98 % extent, and the camera's median distance to the plane.
"""

import sys
from collections import defaultdict
from pathlib import Path

import numpy as np

from planelab.cloud import session_cloud
from planelab.replay import load_replay
from planelab.session import open_session
from planelab.surfaces import SurfaceTimeline


def basis(n: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    h = np.array([0, 1, 0.0]) if abs(n[1]) < 0.9 else np.array([1, 0, 0.0])
    u = np.cross(h, n)
    u /= np.linalg.norm(u)
    v = np.cross(n, u)
    return u, v


for name in sys.argv[1:]:
    b = Path.home() / "PlaneLab/sessions" / name
    with open_session(b) as s:
        rows = s.surface_rows()
        replay = load_replay(s)
        cloud, _ = session_cloud(s, replay)
        fps = s.delivered_fps()
    tl = SurfaceTimeline(rows)
    last = len(replay) - 1
    pts, smp = cloud.at(last)
    print(f"\n===== {name}: {len(replay)} frames, {len(pts)} cloud pts at end, {len(tl)} tracks ever")
    hist = defaultdict(list)
    for r in rows:
        hist[r.number].append(r)
    for n, rs in sorted(hist.items()):
        alive = [r for r in rs if r.event != 2]
        last_r = alive[-1] if alive else None
        end = rs[-1]
        fate = "alive" if end.event != 2 else ("merged" if end.merged_into else "dropped")
        life = (rs[-1].frame_idx - rs[0].frame_idx) / (fps or 60)
        kind = (
            "?"
            if last_r is None
            else ("H" if abs(last_r.normal[1]) > 0.9 else ("V" if abs(last_r.normal[1]) < 0.34 else "S"))
        )
        sz = (
            ""
            if last_r is None
            else f"{last_r.width_m:.2f}x{last_r.height_m:.2f} rms {last_r.rms_m * 100:.1f}cm "
            f"inl {last_r.inliers} state {last_r.state}"
        )
        print(
            f"  #{n:2d} {kind} {fate:7s} frames {rs[0].frame_idx}-{rs[-1].frame_idx} ({life:.0f}s, {len(rs)} rows) {sz}"
        )
    print(" final tracks, support in the cloud:")
    cam = replay.cameras[:, :3, 3]
    for r in tl.at(last):
        n = r.normal / np.linalg.norm(r.normal)
        c = r.center
        d = (pts - c) @ n
        near = np.abs(d) < 0.15
        u, v = basis(n)
        q = pts[near] - c
        pu, pv = q @ u, q @ v
        hu = (r.outline - c) @ u
        hv = (r.outline - c) @ v
        inside = (pu >= hu.min()) & (pu <= hu.max()) & (pv >= hv.min()) & (pv <= hv.max())
        rng = np.median(np.abs((cam - c) @ n))
        ext = (
            f"{np.percentile(pu, 98) - np.percentile(pu, 2):.1f}x{np.percentile(pv, 98) - np.percentile(pv, 2):.1f}"
            if near.sum() > 10
            else "-"
        )
        tilt = np.degrees(np.arcsin(min(1, abs(n[1]))))
        print(
            f"  #{r.number:2d} n=({n[0]:+.2f},{n[1]:+.2f},{n[2]:+.2f}) tilt-from-vertical {tilt:4.1f}deg  "
            f"track {r.width_m:.1f}x{r.height_m:.1f} m, inl {r.inliers}; "
            f"cloud within 15cm of its plane: {near.sum()} pts spanning {ext} m, "
            f"{inside.sum()} inside the track box; median camera dist {rng:.1f} m"
        )
    # coplanar duplicates among final vertical tracks
    fin = [r for r in tl.at(last) if abs(r.normal[1]) < 0.34]
    for i in range(len(fin)):
        for j in range(i + 1, len(fin)):
            a, b2 = fin[i], fin[j]
            ang = np.degrees(np.arccos(min(1, abs(np.dot(a.normal, b2.normal)))))
            nm = a.normal + np.sign(np.dot(a.normal, b2.normal)) * b2.normal
            nm /= np.linalg.norm(nm)
            off = abs(np.dot(nm, b2.center - a.center))
            if ang < 15:
                print(f"  near-parallel pair #{a.number}/#{b2.number}: angle {ang:.1f}deg offset {off * 100:.0f} cm")
    # how many tracks alive over time
    counts = [len(tl.at(i)) for i in range(0, len(replay), max(1, len(replay) // 12))]
    print("  tracks alive over time:", counts)
