"""ARKit's planes over time (planelab.planes)."""

import numpy as np
import pytest
from conftest import FIXTURE_BUNDLE

from planelab.planes import PlaneTimeline, boundary_world
from planelab.session import AnchorEvent, open_session

WALL = "A0000000-0000-4000-8000-000000000001"
FLOOR = "B0000000-0000-4000-8000-000000000002"


@pytest.fixture(scope="module")
def timeline() -> PlaneTimeline:
    with open_session(FIXTURE_BUNDLE) as session:
        return PlaneTimeline(session.anchors())


def alive(timeline: PlaneTimeline, idx: int) -> dict[str, float]:
    """anchor id -> extent width, so tests see which shape is current."""
    return {a.anchor_id: float(a.extent[0]) for a in timeline.at(idx) if a.extent is not None}


def test_add_update_remove_over_time(timeline: PlaneTimeline) -> None:
    assert len(timeline) == 2
    assert alive(timeline, 1) == {}
    assert alive(timeline, 2) == {WALL: 1.0}
    assert alive(timeline, 4) == {WALL: 1.0}
    assert alive(timeline, 5) == {WALL: 2.0}
    assert alive(timeline, 6) == {WALL: 2.0, FLOOR: 3.0}
    assert alive(timeline, 8) == {FLOOR: 3.0}
    assert alive(timeline, 99) == {FLOOR: 3.0}


def test_boundary_in_world(timeline: PlaneTimeline) -> None:
    (wall,) = timeline.at(2)
    world = boundary_world(wall)
    # The wall stands up (anchor +Y -> world +Z) at (1, 0.5, -2); its first vertex is (-0.5, 0, -0.25) locally.
    assert world[0].tolist() == pytest.approx([0.5, 0.75, -2.0])
    assert world.shape == (4, 3)


def test_update_without_add_counts_and_remove_has_no_boundary(timeline: PlaneTimeline) -> None:
    (wall,) = timeline.at(2)
    update_only = AnchorEvent(
        frame_idx=3,
        anchor_id="C",
        event=1,
        alignment=wall.alignment,
        classification=wall.classification,
        transform=wall.transform,
        center=wall.center,
        extent=wall.extent,
        boundary=wall.boundary,
    )
    removed = AnchorEvent(3, "D", 2, None, None, None, None, None, None)
    assert [a.anchor_id for a in PlaneTimeline([update_only, removed]).at(3)] == ["C"]
    assert boundary_world(removed).shape == (0, 3)
    assert np.allclose(boundary_world(update_only), boundary_world(wall))
