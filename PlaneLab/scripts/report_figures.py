"""Two SVG figures for ``REPORT.md`` from one recording: where the cloud's points sit relative to the facade, and how
long each RANSAC track lived.

    python scripts/report_figures.py ~/PlaneLab/sessions/20261002-115935.planelab ../docs/report

Only numpy and the standard library (no plotting package is pinned). The facade yaw is the one that makes the most
points share an offset, found by scanning, so nothing here depends on what the phone's tracker decided.
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
from pathlib import Path

import numpy as np
import numpy.typing as npt

from planelab.session import open_session

FLOAT = npt.NDArray[np.float64]
BAR = "#4c78a8"
PEAK = "#e45756"
GREY = "#8a8a8a"
FONT = "font-family='Helvetica, Arial, sans-serif'"


def final_cloud(bundle: Path) -> FLOAT:
    """The phone's averaged cloud after the last row, ``(K, 3)``."""
    points: dict[int, FLOAT] = {}
    with open_session(bundle) as session:
        for row in session.cloud_rows():
            if row.full:
                points.clear()
            for identifier in row.removed:
                points.pop(int(identifier), None)
            for identifier, point in zip(row.ids, row.points, strict=True):
                points[int(identifier)] = point.astype(np.float64)
    return np.array(list(points.values()))


def facade_yaw(points: FLOAT) -> float:
    """Yaw in degrees of the vertical plane direction that piles the most points into three 5 cm bins."""
    best_score, best_yaw = -1, 0.0
    for yaw in np.arange(0.0, 180.0, 1.0):
        angle = np.radians(yaw)
        offsets = points @ np.array([np.sin(angle), 0.0, np.cos(angle)])
        counts, _ = np.histogram(offsets, bins=np.arange(offsets.min(), offsets.max() + 0.05, 0.05))
        score = int(np.sort(counts)[-3:].sum())
        if score > best_score:
            best_score, best_yaw = score, float(yaw)
    return best_yaw


def offsets_svg(points: FLOAT, yaw: float) -> str:
    """Histogram of the points' distance along the facade normal, in 10 cm bins."""
    angle = np.radians(yaw)
    offsets = points @ np.array([np.sin(angle), 0.0, np.cos(angle)])
    edges = np.arange(np.floor(offsets.min() * 10) / 10, offsets.max() + 0.1, 0.1)
    counts, _ = np.histogram(offsets, bins=edges)
    peak = int(np.argmax(counts))
    width, height, left, bottom, top = 760, 300, 50, 250, 40
    scale = (bottom - top) / counts.max()
    step = (width - left - 20) / len(counts)
    parts = [
        f"<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 {width} {height}' {FONT} font-size='12'>",
        "<rect width='100%' height='100%' fill='white'/>",
        f"<text x='{left}' y='22' font-size='14' font-weight='bold'>Where the phone's 3D points sit, "
        f"measured across the facade (yaw {yaw:.0f}°)</text>",
    ]
    for i, count in enumerate(counts):
        bar = count * scale
        colour = PEAK if i == peak else BAR
        parts.append(
            f"<rect x='{left + i * step:.1f}' y='{bottom - bar:.1f}' width='{max(step - 1, 1):.1f}' "
            f"height='{bar:.1f}' fill='{colour}'/>"
        )
    for metres in range(int(np.ceil(edges[0])), int(edges[-1]) + 1):
        x = left + (metres - edges[0]) / 0.1 * step
        parts.append(f"<line x1='{x:.1f}' y1='{bottom}' x2='{x:.1f}' y2='{bottom + 5}' stroke='{GREY}'/>")
        parts.append(f"<text x='{x:.1f}' y='{bottom + 20}' text-anchor='middle'>{metres} m</text>")
    peak_x = left + (peak + 0.5) * step
    parts.append(
        f"<text x='{peak_x + 8:.1f}' y='{top + 14}' fill='{PEAK}'>the wall: a peak, but with a thick tail "
        f"toward the camera</text>"
    )
    parts.append(
        f"<text x='{left}' y='{height - 8}' fill='{GREY}'>Each bar is a 10 cm slice. A perfect wall would be one "
        f"thin bar.</text>"
    )
    parts.append("</svg>")
    return "\n".join(parts)


def lifetimes(bundle: Path, fps: float = 60.0) -> list[tuple[int, float, float, bool]]:
    """``(track number, first s, last s, merged away)`` for every surface track, from the ``surface`` table."""
    database = sqlite3.connect(bundle / "session.sqlite")
    try:
        rows = database.execute(
            "SELECT number, MIN(frame_idx), MAX(frame_idx), MAX(event = 2) FROM surface GROUP BY number ORDER BY 2"
        ).fetchall()
    finally:
        database.close()
    return [(int(n), first / fps, last / fps, bool(merged)) for n, first, last, merged in rows]


def tracks_svg(tracks: list[tuple[int, float, float, bool]]) -> str:
    """One horizontal bar per track: long bars are stable tracks, the swarm of short ones is the churn."""
    width, row, left, top = 760, 7, 50, 50
    end = max(last for _, _, last, _ in tracks)
    height = top + row * len(tracks) + 40
    scale = (width - left - 20) / end
    short = sum(1 for _, first, last, _ in tracks if last - first < 3)
    parts = [
        f"<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 {width} {height}' {FONT} font-size='12'>",
        "<rect width='100%' height='100%' fill='white'/>",
        f"<text x='{left}' y='22' font-size='14' font-weight='bold'>{len(tracks)} planes were created in "
        f"{end:.0f} s; {short} lived under 3 s</text>",
        f"<text x='{left}' y='40' fill='{GREY}'>Each bar is one plane. Red = it was later merged into another.</text>",
    ]
    for i, (_, first, last, merged) in enumerate(tracks):
        parts.append(
            f"<rect x='{left + first * scale:.1f}' y='{top + i * row}' width='{max((last - first) * scale, 2):.1f}' "
            f"height='{row - 2}' fill='{PEAK if merged else BAR}'/>"
        )
    axis = top + row * len(tracks) + 6
    for second in range(0, int(end) + 1, 20):
        x = left + second * scale
        parts.append(f"<line x1='{x:.1f}' y1='{axis}' x2='{x:.1f}' y2='{axis + 5}' stroke='{GREY}'/>")
        parts.append(f"<text x='{x:.1f}' y='{axis + 20}' text-anchor='middle'>{second} s</text>")
    parts.append("</svg>")
    return "\n".join(parts)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("bundle", type=Path)
    parser.add_argument("out", type=Path)
    args = parser.parse_args(argv)
    args.out.mkdir(parents=True, exist_ok=True)
    points = final_cloud(args.bundle)
    yaw = facade_yaw(points)
    (args.out / "offsets.svg").write_text(offsets_svg(points, yaw))
    (args.out / "tracks.svg").write_text(tracks_svg(lifetimes(args.bundle)))
    print(f"{len(points)} points, facade yaw {yaw:.0f} deg -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
