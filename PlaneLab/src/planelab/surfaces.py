"""The phone's tracked planes over time (EXPERIMENTS.md X1 and X2, XD6), from the ``surface`` rows it recorded (schema
v3), and what each round of its plane engine cost (``surface_round`` rows, schema v4, XD16).

At any frame, a track is shown in its latest add or update at or before that frame, unless its latest row is a
remove (a merge into an older track, or a dropped tentative track).
"""

from bisect import bisect_right
from collections import defaultdict

from planelab.session import SurfaceRoundRow, SurfaceRow

REMOVE = 2
TENTATIVE, CONFIRMED, STALE = 0, 1, 2
ENGINE_NAMES = {"ransac": "RANSAC", "findsurface": "FindSurface"}
THERMAL_NAMES = ("nominal", "fair", "serious", "critical")


def engine_name(engine: str | None) -> str:
    """How an engine reads on screen; recordings from before ``surface_engine`` was written are FindSurface's."""
    return ENGINE_NAMES.get(engine or "findsurface", engine or "")


class SurfaceTimeline:
    def __init__(self, rows: list[SurfaceRow]) -> None:
        by_track: dict[str, list[SurfaceRow]] = defaultdict(list)
        for row in sorted(rows, key=lambda r: r.frame_idx):  # stable: rows keep their recorded order
            by_track[row.surface_id].append(row)
        self._rows = dict(by_track)
        self._frames = {track: [r.frame_idx for r in history] for track, history in by_track.items()}

    def __len__(self) -> int:
        """Tracks seen over the whole recording."""
        return len(self._rows)

    def at(self, idx: int) -> list[SurfaceRow]:
        """The tracks that exist at frame ``idx``, each in its latest shape, by track number."""
        alive = []
        for track, frames in self._frames.items():
            position = bisect_right(frames, idx) - 1
            if position >= 0 and self._rows[track][position].event != REMOVE:
                alive.append(self._rows[track][position])
        return sorted(alive, key=lambda r: r.number)

    def merges(self) -> list[SurfaceRow]:
        """Remove rows that merged a track into an older one."""
        return [r for history in self._rows.values() for r in history if r.event == REMOVE and r.merged_into]


class RoundTimeline:
    """What each round of the phone's plane engine cost, looked up by recorded frame."""

    def __init__(self, rows: list[SurfaceRoundRow]) -> None:
        self.rows = sorted(rows, key=lambda r: (r.frame_idx, r.round))
        self._frames = [r.frame_idx for r in self.rows]

    def __len__(self) -> int:
        return len(self.rows)

    def at(self, idx: int) -> SurfaceRoundRow | None:
        """The latest round that started at or before frame ``idx``; None before the first."""
        position = bisect_right(self._frames, idx) - 1
        return self.rows[position] if position >= 0 else None

    def lines(self, idx: int) -> list[tuple[str, str]]:
        """Label and value pairs for the round shown at ``idx``, for the Plane Lab tab."""
        row = self.at(idx)
        if row is None:
            return []
        thermal = THERMAL_NAMES[row.thermal] if 0 <= row.thermal < len(THERMAL_NAMES) else str(row.thermal)
        lines = [
            ("Round", f"{row.round} (frame {row.frame_idx})"),
            ("Time", f"{row.total_ms:.1f} ms (refit {row.refit_ms:.1f}, search {row.search_ms:.1f})"),
            ("Cloud", f"{row.points} points, {row.unclaimed} unclaimed"),
            ("Tracks", f"{row.tracks} ({row.confirmed} confirmed), {row.refits} refits"),
        ]
        if row.searched:
            lines.append(
                ("Search", f"{row.hypotheses} hypotheses, {row.full_scores} scored in full, {row.planes_found} planes")
            )
        else:
            lines.append(("Search", "not run this round"))
        lines.append(("Phone", f"thermal {thermal}, {row.skipped} rounds skipped so far"))
        return lines
