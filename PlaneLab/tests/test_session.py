"""The session reader beyond the contract: versions, zips, helpers the importer relies on."""

import sqlite3
import zipfile
from pathlib import Path

import numpy as np
import pytest
from conftest import FIXTURE_BUNDLE

from planelab.session import SessionError, UnsupportedSchemaError, matrix, open_session, vectors


def set_meta(bundle: Path, key: str, value: str | None) -> None:
    with sqlite3.connect(bundle / "session.sqlite") as db:
        if value is None:
            db.execute("DELETE FROM meta WHERE key = ?", (key,))
        else:
            db.execute("UPDATE meta SET value = ? WHERE key = ?", (value, key))


@pytest.mark.parametrize("version", ["2", "one", None])
def test_unknown_schema_version_is_refused_clearly(bundle_copy: Path, version: str | None) -> None:
    set_meta(bundle_copy, "schema_version", version)
    with pytest.raises(UnsupportedSchemaError) as caught:
        open_session(bundle_copy)
    message = str(caught.value)
    assert repr(version) in message
    assert "knows 1" in message


def zip_folder(folder: Path, archive: Path, *, nested: bool) -> None:
    with zipfile.ZipFile(archive, "w") as out:
        for path in folder.rglob("*"):
            relative = path.relative_to(folder.parent if nested else folder)
            out.write(path, relative)


@pytest.mark.parametrize("nested", [True, False])
def test_zip_input_is_extracted_once(tmp_path: Path, nested: bool) -> None:
    archive = tmp_path / "shared.zip"
    zip_folder(FIXTURE_BUNDLE, archive, nested=nested)
    cache = tmp_path / "cache"
    with open_session(archive, cache=cache) as first:
        assert first.frame_count() == 10
        first_path = first.bundle
    with open_session(archive, cache=cache) as second:
        assert second.bundle == first_path
    assert len([p for p in cache.iterdir() if not p.name.startswith(".")]) == 1


def test_zip_without_a_session_is_refused(tmp_path: Path) -> None:
    archive = tmp_path / "empty.zip"
    with zipfile.ZipFile(archive, "w") as out:
        out.writestr("notes.txt", "no session here")
    with pytest.raises(SessionError, match=r"holds no session\.sqlite"):
        open_session(archive, cache=tmp_path / "cache")


def test_other_paths_are_refused(tmp_path: Path) -> None:
    with pytest.raises(SessionError, match="neither"):
        open_session(tmp_path / "missing.planelab")
    with pytest.raises(SessionError, match=r"no session\.sqlite"):
        open_session(tmp_path)


def test_importer_helpers() -> None:
    with open_session(FIXTURE_BUNDLE) as session:
        assert session.first_image_idx() == 1
        assert session.delivered_fps() == pytest.approx(32.0)
        assert session.image_flags().tolist() == [i not in (0, 4, 7) for i in range(10)]
        idx, t = session.frame_times()
        assert idx.tolist() == list(range(10))
        assert t[1] - t[0] == pytest.approx(1 / 32)
        assert session.video_path == session.bundle / "video.mov"


def test_empty_frame_has_zero_points() -> None:
    with open_session(FIXTURE_BUNDLE) as session:
        frame = session.frame(0)
    assert frame.points.shape == (0, 3)
    assert frame.point_ids.shape == (0,)


def test_missing_frame_is_an_error() -> None:
    with open_session(FIXTURE_BUNDLE) as session, pytest.raises(SessionError, match="no frame 99"):
        session.frame(99)


def test_mismatched_point_count_is_an_error(bundle_copy: Path) -> None:
    with sqlite3.connect(bundle_copy / "session.sqlite") as db:
        db.execute("UPDATE frame SET point_count = 99 WHERE idx = 3")
    with open_session(bundle_copy) as session, pytest.raises(SessionError, match="point_count 99"):
        session.frame(3)


def test_session_without_frames(bundle_copy: Path) -> None:
    with sqlite3.connect(bundle_copy / "session.sqlite") as db:
        db.execute("DELETE FROM frame")
    (bundle_copy / "video.mov").unlink()
    with open_session(bundle_copy) as session:
        assert session.delivered_fps() is None
        assert session.first_image_idx() is None
        assert session.video_path is None


def test_blob_decoders_reject_wrong_sizes() -> None:
    with pytest.raises(SessionError):
        matrix(np.zeros(15, dtype="<f4").tobytes(), 4)
    with pytest.raises(SessionError):
        vectors(np.zeros(4, dtype="<f4").tobytes())
