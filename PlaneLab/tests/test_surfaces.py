"""Experiment X1's tracks over time (EXPERIMENTS.md XD6), from the contract fixture's surface rows."""

from conftest import FIXTURE_BUNDLE

from planelab.session import open_session
from planelab.surfaces import CONFIRMED, STALE, TENTATIVE, RoundTimeline, SurfaceTimeline, engine_name

FIRST = "C0000000-0000-4000-8000-000000000001"
SECOND = "C0000000-0000-4000-8000-000000000002"
THIRD = "C0000000-0000-4000-8000-000000000003"


def timeline() -> SurfaceTimeline:
    with open_session(FIXTURE_BUNDLE) as session:
        return SurfaceTimeline(session.surface_rows())


def alive(idx: int) -> list[tuple[int, int | None]]:
    return [(row.number, row.state) for row in timeline().at(idx)]


def test_tracks_appear_change_and_go_frame_by_frame() -> None:
    assert len(timeline()) == 3
    assert alive(2) == []
    assert alive(3) == [(1, TENTATIVE)]
    assert alive(4) == alive(5) == [(1, TENTATIVE), (2, TENTATIVE)]
    assert alive(6) == [(1, CONFIRMED), (2, TENTATIVE)]
    assert alive(7) == [(1, CONFIRMED)]  # #2 merged into #1
    assert alive(8) == [(1, STALE), (3, TENTATIVE)]
    assert alive(9) == [(1, STALE)]  # #3 dropped


def test_the_latest_shape_is_shown() -> None:
    first = timeline().at(6)[0]
    assert first.surface_id == FIRST
    assert first.outline is not None and len(first.outline) == 5
    assert first.width_m == 2.0


def test_merges_name_the_survivor() -> None:
    merges = timeline().merges()
    assert [(m.surface_id, m.merged_into, m.frame_idx) for m in merges] == [(SECOND, FIRST, 7)]
    assert all(r.surface_id != THIRD for r in merges)


def test_no_rows_no_tracks() -> None:
    empty = SurfaceTimeline([])
    assert len(empty) == 0 and empty.at(100) == [] and empty.merges() == []


def rounds() -> RoundTimeline:
    with open_session(FIXTURE_BUNDLE) as session:
        return RoundTimeline(session.surface_round_rows())


def test_the_round_shown_is_the_latest_at_or_before_the_frame() -> None:
    timeline = rounds()
    assert len(timeline) == 3
    assert timeline.at(2) is None
    assert [timeline.at(i).round for i in (3, 5, 6, 8, 9)] == [1, 1, 2, 2, 3]  # type: ignore[union-attr]


def test_round_lines_read_like_the_panel() -> None:
    timeline = rounds()
    assert timeline.lines(2) == []
    first = dict(timeline.lines(3))
    assert first["Time"] == "12.5 ms (refit 0.0, search 12.2)"
    assert first["Search"] == "96 hypotheses, 31 scored in full, 2 planes"
    second = dict(timeline.lines(6))
    assert second["Search"] == "not run this round"
    assert second["Phone"] == "thermal fair, 1 rounds skipped so far"
    assert dict(timeline.lines(9))["Phone"].startswith("thermal serious")


def test_engine_names() -> None:
    assert engine_name("ransac") == "RANSAC"
    assert engine_name("findsurface") == engine_name(None) == "FindSurface"
    assert engine_name("other") == "other"
