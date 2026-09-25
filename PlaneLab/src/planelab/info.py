"""A recording at a glance (SPEC.md §5.5 ``planelab info``, and the Blender panel's session info)."""

from collections import Counter
from dataclasses import dataclass

import numpy as np

from planelab.cloud import recorded_timeline
from planelab.session import Session, SurfaceRoundRow
from planelab.surfaces import CONFIRMED, SurfaceTimeline, engine_name

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
class PhoneCloud:
    """The averaged cloud the phone recorded (schema v2, SPEC.md L12, P23)."""

    rows: int
    points: int
    """Averaged points after the last row."""
    frames_missed: int | None
    """Recorded frames the phone's cloud never saw (meta ``cloud_frames_dropped``); None when not finalized."""


@dataclass(slots=True, frozen=True)
class X1Surfaces:
    """Experiment X1's tracked FindSurface planes as recorded (schema v3, EXPERIMENTS.md XD6)."""

    rows: int
    tracks: int
    """Tracks seen over the recording."""
    at_end: int
    """Tracks alive after the last row."""
    confirmed_at_end: int
    merges: int


@dataclass(slots=True, frozen=True)
class RoundCost:
    """What the phone's plane engine cost per round (schema v4, EXPERIMENTS.md XD16)."""

    rounds: int
    median_ms: float
    p95_ms: float
    max_ms: float
    searched: int
    """Rounds that ran a discovery search."""
    search_median_ms: float
    """Median of ``search_ms`` over the rounds that searched; 0 when none did."""
    hypotheses_median: float
    """Median hypotheses over the rounds that searched."""
    skipped: int
    """Rounds skipped over the recording because the previous one was still running."""
    hot_rounds: int
    """Rounds that ran with the phone at thermal ``serious`` or worse."""


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
    image_skips: dict[str, int]
    """Why frames have no image (meta ``image_skip.<reason>``, recordings since T10): ``no_buffer`` on the capture
    side, or the encoder's reason such as ``notReady``."""
    tracking_normal_pct: float
    points: PointRange | None
    anchor_ids: int
    anchor_events: dict[str, int]
    site: Site | None
    location_fixes: int
    headings: int
    events: int
    schema_version: int
    cloud: PhoneCloud | None
    """None when the recording has no cloud rows (schema v1, or nothing recorded)."""
    x1: X1Surfaces | None
    """None when the recording has no surface rows (before schema v3, or the engine was off)."""
    engine: str | None
    """The plane engine that wrote them (meta ``surface_engine``: ``ransac`` or ``findsurface``; recordings from before
    it was written are FindSurface); None when there are no surface rows."""
    cost: RoundCost | None
    """None before schema v4, or when no rounds were recorded."""


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
    rows = session.cloud_rows()
    missed = session.meta.get("cloud_frames_dropped", "")
    cloud = (
        PhoneCloud(
            rows=len(rows),
            points=len(recorded_timeline(rows).at(rows[-1].frame_idx)[0]),
            frames_missed=int(missed) if missed.isdigit() else None,
        )
        if rows
        else None
    )

    surface_rows = session.surface_rows()
    round_rows = session.surface_round_rows()
    engine = session.meta.get("surface_engine", "findsurface") if surface_rows or round_rows else None
    x1 = None
    if surface_rows:
        timeline = SurfaceTimeline(surface_rows)
        alive = timeline.at(max(r.frame_idx for r in surface_rows))
        x1 = X1Surfaces(
            rows=len(surface_rows),
            tracks=len(timeline),
            at_end=len(alive),
            confirmed_at_end=sum(1 for r in alive if r.state == CONFIRMED),
            merges=len(timeline.merges()),
        )

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
        image_skips={
            key.removeprefix("image_skip."): int(value)
            for key, value in sorted(session.meta.items())
            if key.startswith("image_skip.") and value.isdigit()
        },
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
        schema_version=session.schema_version,
        cloud=cloud,
        x1=x1,
        engine=engine,
        cost=_cost(round_rows),
    )


def _cost(rows: list[SurfaceRoundRow]) -> RoundCost | None:
    if not rows:
        return None
    totals = np.array([r.total_ms for r in rows])
    searched = [r for r in rows if r.searched]
    return RoundCost(
        rounds=len(rows),
        median_ms=float(np.median(totals)),
        p95_ms=float(np.percentile(totals, 95, method="higher")),
        max_ms=float(totals.max()),
        searched=len(searched),
        search_median_ms=float(np.median([r.search_ms for r in searched])) if searched else 0.0,
        hypotheses_median=float(np.median([r.hypotheses for r in searched])) if searched else 0.0,
        skipped=max(r.skipped for r in rows),
        hot_rounds=sum(1 for r in rows if r.thermal >= 2),
    )


def _skips(skips: dict[str, int]) -> str:
    if not skips:
        return ""
    return " (no image: " + ", ".join(f"{count} {reason}" for reason, count in skips.items()) + ")"


def describe(info: SessionInfo) -> str:
    """Human-readable lines for the CLI."""
    fps = f"{info.delivered_fps:.1f} fps delivered" if info.delivered_fps else "fps unknown"
    dropped = "?" if info.frames_dropped is None else str(info.frames_dropped)
    lines = [
        f"{info.name}  ({info.device}, started {info.started_at}, stop: {info.stop_reason})",
        f"frames    {info.frames} in {info.duration_s:.2f} s, {fps}; "
        f"{info.frames_with_image} with an image, {dropped} dropped{_skips(info.image_skips)}",
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
    if info.cloud:
        c = info.cloud
        missed = "?" if c.frames_missed is None else str(c.frames_missed)
        lines.append(f"cloud     phone: {c.points} averaged points after {c.rows} rows ({missed} frames missed)")
    else:
        lines.append("cloud     none recorded" + (" (schema v1, before L12)" if info.schema_version < 2 else ""))
    name = engine_name(info.engine)
    if info.x1:
        x = info.x1
        lines.append(
            f"planes    {name}: {x.tracks} tracks in {x.rows} rows; {x.at_end} at the end "
            f"({x.confirmed_at_end} confirmed), {x.merges} merges"
        )
    else:
        lines.append("planes    none recorded" + (" (before schema v3)" if info.schema_version < 3 else ""))
    if info.cost:
        c = info.cost
        lines.append(
            f"rounds    {c.rounds} rounds: median {c.median_ms:.1f} ms, p95 {c.p95_ms:.1f} ms, max {c.max_ms:.1f} ms; "
            f"{c.searched} searched (median {c.search_median_ms:.1f} ms, {c.hypotheses_median:.0f} hypotheses); "
            f"{c.skipped} skipped, {c.hot_rounds} hot"
        )
    elif info.schema_version >= 4 and info.engine:
        lines.append("rounds    none recorded")
    return "\n".join(lines)
