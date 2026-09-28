"""A recording at a glance (SPEC.md §5.5 ``planelab info``, and the Blender panel's session info)."""

from collections import Counter
from dataclasses import dataclass

import numpy as np

from planelab.session import Session

TRACKING_NORMAL = 2
ANCHOR_EVENTS = {0: "add", 1: "update", 2: "remove"}


@dataclass(slots=True, frozen=True)
class PointRange:
    """Distance from the camera to each raw feature point, over the whole session (E1)."""

    count: int
    p50_m: float
    p95_m: float
    max_m: float


@dataclass(slots=True, frozen=True)
class Site:
    lat: float
    lon: float
    h_acc_m: float


@dataclass(slots=True, frozen=True)
class SessionInfo:
    name: str
    device: str
    started_at: str
    stop_reason: str
    frames: int
    duration_s: float
    delivered_fps: float | None
    frames_with_image: int
    frames_dropped: int | None
    tracking_normal_pct: float
    points: PointRange | None
    anchor_ids: int
    anchor_events: dict[str, int]
    site: Site | None
    location_fixes: int
    headings: int
    events: int


def summarize(session: Session) -> SessionInfo:
    distances: list[np.ndarray] = []
    tracking_normal = 0
    frames = 0
    for frame in session.frames():
        frames += 1
        tracking_normal += frame.tracking == TRACKING_NORMAL
        if frame.points.size:
            distances.append(np.linalg.norm(frame.points - frame.position, axis=1))

    _, t = session.frame_times()
    anchors = session.anchors()
    locations = session.locations()
    dropped = session.meta.get("frames_dropped")
    all_distances = np.concatenate(distances) if distances else np.empty(0, dtype=np.float32)

    return SessionInfo(
        name=session.bundle.name,
        device=session.meta.get("device_model", "unknown"),
        started_at=session.meta.get("started_at", "unknown"),
        stop_reason=session.meta.get("stop_reason", "not finalized"),
        frames=frames,
        duration_s=float(t[-1] - t[0]) if t.size else 0.0,
        delivered_fps=session.delivered_fps(),
        frames_with_image=int(session.image_flags().sum()),
        frames_dropped=int(dropped) if dropped is not None and dropped.isdigit() else None,
        tracking_normal_pct=100.0 * tracking_normal / frames if frames else 0.0,
        points=PointRange(
            count=int(all_distances.size),
            p50_m=float(np.percentile(all_distances, 50)),
            p95_m=float(np.percentile(all_distances, 95)),
            max_m=float(all_distances.max()),
        )
        if all_distances.size
        else None,
        anchor_ids=len({a.anchor_id for a in anchors}),
        anchor_events={ANCHOR_EVENTS.get(k, str(k)): v for k, v in sorted(Counter(a.event for a in anchors).items())},
        site=Site(locations[0].lat, locations[0].lon, locations[0].h_acc_m) if locations else None,
        location_fixes=len(locations),
        headings=len(session.headings()),
        events=len(session.events()),
    )


def describe(info: SessionInfo) -> str:
    """Human-readable lines for the CLI."""
    fps = f"{info.delivered_fps:.1f} fps delivered" if info.delivered_fps else "fps unknown"
    dropped = "?" if info.frames_dropped is None else str(info.frames_dropped)
    lines = [
        f"{info.name}  ({info.device}, started {info.started_at}, stop: {info.stop_reason})",
        f"frames    {info.frames} in {info.duration_s:.2f} s, {fps}; "
        f"{info.frames_with_image} with an image, {dropped} dropped",
        f"tracking  {info.tracking_normal_pct:.0f} % normal",
    ]
    if info.points:
        p = info.points
        lines.append(f"points    p50 {p.p50_m:.2f} m, p95 {p.p95_m:.2f} m, max {p.max_m:.2f} m ({p.count} points)")
    else:
        lines.append("points    none")
    events = ", ".join(f"{v} {k}" for k, v in info.anchor_events.items()) or "none"
    lines.append(f"anchors   {info.anchor_ids} ARKit planes: {events}")
    if info.site:
        s = info.site
        lines.append(
            f"site      {s.lat:.6f}, {s.lon:.6f} (± {s.h_acc_m:.1f} m); "
            f"{info.location_fixes} fixes, {info.headings} headings"
        )
    else:
        lines.append("site      no location")
    lines.append(f"events    {info.events}")
    return "\n".join(lines)
