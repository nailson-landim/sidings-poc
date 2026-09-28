"""ARKit's planes over time, from the recorded add / update / remove callbacks (SPEC.md §3.3, §6).

At any frame, an anchor is shown with its latest add or update at or before that frame, unless its latest event is a
remove. An update without an earlier add still counts, since the callback proves the plane exists.
"""

from bisect import bisect_right
from collections import defaultdict

import numpy as np
import numpy.typing as npt

from planelab.session import AnchorEvent

REMOVE = 2
ALIGNMENT_VERTICAL = 1

FloatArray = npt.NDArray[np.float64]


class PlaneTimeline:
    def __init__(self, events: list[AnchorEvent]) -> None:
        by_anchor: dict[str, list[AnchorEvent]] = defaultdict(list)
        for event in sorted(events, key=lambda e: e.frame_idx):  # stable: callbacks keep their recorded order
            by_anchor[event.anchor_id].append(event)
        self._events = dict(by_anchor)
        self._frames = {anchor: [e.frame_idx for e in history] for anchor, history in by_anchor.items()}

    def __len__(self) -> int:
        """Anchors seen over the whole recording."""
        return len(self._events)

    def at(self, idx: int) -> list[AnchorEvent]:
        """The planes that exist at frame ``idx``, each in its latest shape."""
        alive = []
        for anchor, frames in self._frames.items():
            position = bisect_right(frames, idx) - 1
            if position >= 0 and self._events[anchor][position].event != REMOVE:
                alive.append(self._events[anchor][position])
        return alive


def boundary_world(anchor: AnchorEvent) -> FloatArray:
    """The anchor's boundary polygon in ARKit world coordinates (boundary vertices are anchor-local)."""
    if anchor.transform is None or anchor.boundary is None:
        return np.empty((0, 3))
    local = np.hstack([anchor.boundary.astype(np.float64), np.ones((anchor.boundary.shape[0], 1))])
    return (local @ anchor.transform.astype(np.float64).T)[:, :3]
