"""Picking a feature (planelab.pick, SPEC.md §17.4 P27): the nearest point on screen and the feature report."""

import numpy as np
import pytest
from conftest import RECORDED_BUNDLE

from planelab.cloud import CloudTimeline, build_cloud_timeline, session_cloud
from planelab.config import LabConfig
from planelab.pick import feature_at, feature_report, nearest_on_screen, report_lines
from planelab.replay import Replay, load_replay
from planelab.session import open_session

FEATURE = 9007199254780587
"""In the recorded fixture: a raw point at frame 11 and in the phone's cloud after it. Above 2^53, so a float cast
would change it."""


@pytest.fixture(scope="module")
def recorded() -> tuple[Replay, CloudTimeline]:
    with open_session(RECORDED_BUNDLE) as session:
        replay = load_replay(session)
        cloud, source = session_cloud(session, replay)
    assert source == "phone"
    return replay, cloud


def perspective(focal: float = 2.0, near: float = 0.1, far: float = 100.0) -> np.ndarray:
    """An OpenGL-style projection looking down -Z from the origin, like Blender's perspective_matrix."""
    return np.array(
        [
            [focal, 0, 0, 0],
            [0, focal, 0, 0],
            [0, 0, (far + near) / (near - far), 2 * far * near / (near - far)],
            [0, 0, -1, 0],
        ]
    )


def test_the_nearest_point_within_the_radius_wins() -> None:
    # On a 100 x 100 region, x = 0.5 at 2 m away lands 25 px right of the centre.
    points = [(0.5, 0, -2), (0, 0, -2), (0.05, 0, -2)]
    assert nearest_on_screen(points, perspective(), 100, 100, (50, 50)) == 1
    assert nearest_on_screen(points, perspective(), 100, 100, (53, 50)) == 2
    assert nearest_on_screen(points, perspective(), 100, 100, (75, 50)) == 0
    assert nearest_on_screen(points, perspective(), 100, 100, (50, 90)) is None
    assert nearest_on_screen(points, perspective(), 100, 100, (50, 90), radius_px=45) == 1


def test_behind_the_eye_is_skipped_and_the_front_one_wins_a_tie() -> None:
    behind = [(0, 0, 2)]
    assert nearest_on_screen(behind, perspective(), 100, 100, (50, 50)) is None
    assert nearest_on_screen(np.empty((0, 3)), perspective(), 100, 100, (50, 50)) is None
    # Same spot on screen, 8 m and 3 m away: the nearer one is picked, whatever the order.
    assert nearest_on_screen([(0, 0, -8), (0, 0, -3)], perspective(), 100, 100, (50, 50)) == 1
    assert nearest_on_screen([(0, 0, -3), (0, 0, -8)], perspective(), 100, 100, (50, 50)) == 0


def test_a_feature_with_raw_and_averaged_points(recorded: tuple[Replay, CloudTimeline]) -> None:
    replay, cloud = recorded
    at = feature_at(replay, cloud, FEATURE, 11)

    ids = replay.ids_at(11)
    assert at.raw is not None and np.allclose(at.raw, replay.points_at(11)[ids == np.uint64(FEATURE)][0])
    cloud_ids, cloud_points, cloud_samples = cloud.ids_at(11)
    (row,) = np.flatnonzero(cloud_ids == np.uint64(FEATURE))
    assert at.averaged is not None and np.allclose(at.averaged, cloud_points[row])
    assert at.samples == int(cloud_samples[row])
    assert at.shown is at.averaged
    camera = replay.cameras[11, :3, 3]
    assert at.distance == pytest.approx(float(np.linalg.norm(at.averaged - camera)))
    assert at.offset == pytest.approx(float(np.linalg.norm(at.raw - at.averaged)))


def test_the_report_counts_the_frames_that_saw_the_feature(recorded: tuple[Replay, CloudTimeline]) -> None:
    replay, cloud = recorded
    report = feature_report(replay, cloud, FEATURE, 11)
    seen = [int(i) for i in replay.idx if np.uint64(FEATURE) in replay.ids_at(int(i))]
    assert (report.first_idx, report.last_idx, report.frames_seen) == (seen[0], seen[-1], len(seen))
    assert report.cloud_has_ids

    lines = dict(report_lines(report))
    assert lines["Feature"] == str(FEATURE)
    assert lines["Seen"] == f"frames {seen[0] + 1} to {seen[-1] + 1} ({len(seen)} frames)"
    x, y, z = report.at.averaged
    assert lines["Averaged ARKit"] == f"x {x:.3f}  y {y:.3f}  z {z:.3f}"
    assert lines["Averaged Blender"] == f"x {x:.3f}  y {-z:.3f}  z {y:.3f}"
    assert lines["Samples"] == str(report.at.samples)
    assert lines["Raw to averaged"].endswith(" cm") and lines["From the camera"].endswith(" m")


def test_before_the_cloud_has_it_the_raw_point_is_shown(recorded: tuple[Replay, CloudTimeline]) -> None:
    replay, cloud = recorded
    first_raw = int(replay.ids_at(0)[0])
    at = feature_at(replay, cloud, first_raw, 0)
    assert at.averaged is None and at.samples is None and at.offset is None
    assert at.raw is not None and at.shown is at.raw
    assert "Averaged" in dict(report_lines(feature_report(replay, cloud, first_raw, 0)))


def test_an_unknown_feature_or_frame(recorded: tuple[Replay, CloudTimeline]) -> None:
    replay, cloud = recorded
    report = feature_report(replay, cloud, 12345, 11)
    assert report.at.raw is None and report.at.averaged is None and report.at.distance is None
    assert (report.first_idx, report.last_idx, report.frames_seen) == (None, None, 0)
    assert dict(report_lines(report))["Raw"] == "not at frame 12"
    assert "Seen" not in dict(report_lines(report))

    unlogged = feature_at(replay, cloud, FEATURE, 10_000)
    assert unlogged.camera is None and unlogged.raw is None and unlogged.distance is None


def test_the_clouds_point_lookup(recorded: tuple[Replay, CloudTimeline]) -> None:
    replay, cloud = recorded
    assert cloud.point(int(cloud.frames[0]) - 1, FEATURE) is None  # before the first row
    assert cloud.point(11, 12345) is None
    assert cloud.point(11, 2**64 - 1) is None  # past every id
    mac = build_cloud_timeline(replay, LabConfig())
    with pytest.raises(ValueError, match="no feature ids"):
        mac.point(11, FEATURE)


def test_a_mac_cloud_shows_only_the_raw_point(recorded: tuple[Replay, CloudTimeline]) -> None:
    replay, _ = recorded
    mac = build_cloud_timeline(replay, LabConfig())
    report = feature_report(replay, mac, FEATURE, 11)
    assert not report.cloud_has_ids and report.at.averaged is None and report.at.raw is not None
    assert dict(report_lines(report))["Averaged"] == "no ids in the Mac's recompute"
