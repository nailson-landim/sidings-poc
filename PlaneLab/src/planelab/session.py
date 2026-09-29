"""Read a recording (SPEC.md §3): a ``.planelab`` folder with ``session.sqlite`` and ``video.mov``, or its zip.

Matrices come back as ordinary row-major numpy arrays (``camera @ [x, y, z, 1]``), converted from the column-major
BLOBs. Everything stays in ARKit world coordinates (+Y up); converting to Blender axes is the add-on's job.
"""

import hashlib
import logging
import shutil
import sqlite3
import tempfile
import zipfile
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from types import TracebackType
from typing import Any, Self

import numpy as np
import numpy.typing as npt

from planelab.schema import SUPPORTED_VERSIONS

log = logging.getLogger(__name__)

Float32Array = npt.NDArray[np.float32]
Float64Array = npt.NDArray[np.float64]
Int64Array = npt.NDArray[np.int64]
UInt64Array = npt.NDArray[np.uint64]
BoolArray = npt.NDArray[np.bool_]


class SessionError(Exception):
    """The path isn't a readable session."""


class UnsupportedSchemaError(SessionError):
    """The session's ``schema_version`` is missing or newer than this reader."""


@dataclass(slots=True, frozen=True)
class Frame:
    """One ``frame`` row."""

    idx: int
    t: float
    has_image: bool
    tracking: int
    tracking_reason: int
    mapping: int
    camera: Float32Array
    """(4, 4) world <- camera, row-major."""
    intrinsics: Float32Array
    """(3, 3), in pixels of the landscape sensor image."""
    exposure_s: float
    thermal: int
    points: Float32Array
    """(N, 3) raw feature points, world coordinates."""
    point_ids: UInt64Array
    """(N,) feature identifiers."""

    @property
    def position(self) -> Float32Array:
        """Camera centre in world coordinates."""
        return self.camera[:3, 3]


@dataclass(slots=True, frozen=True)
class AnchorEvent:
    """One ``plane_anchor`` row. A remove (``event == 2``) carries only the id."""

    frame_idx: int
    anchor_id: str
    event: int
    alignment: int | None
    classification: int | None
    transform: Float32Array | None
    center: Float32Array | None
    extent: Float32Array | None
    boundary: Float32Array | None


@dataclass(slots=True, frozen=True)
class Location:
    frame_idx: int
    utc: float
    lat: float
    lon: float
    alt_m: float
    ellipsoidal_alt_m: float
    h_acc_m: float
    v_acc_m: float


@dataclass(slots=True, frozen=True)
class Heading:
    frame_idx: int
    true_deg: float
    magnetic_deg: float
    acc_deg: float


@dataclass(slots=True, frozen=True)
class Event:
    frame_idx: int
    kind: str
    detail: str


@dataclass(slots=True, frozen=True)
class CloudRow:
    """One ``cloud`` row (schema v2, SPEC.md P23): the phone's averaged cloud after ``frame_idx``, whole (``full``) or
    as changes since the previous row (remove ``removed``, then set every id in ``ids``).
    """

    frame_idx: int
    full: bool
    removed: UInt64Array
    ids: UInt64Array
    points: Float32Array
    """(K, 3) averaged positions, ARKit world."""
    samples: npt.NDArray[np.uint16]


def matrix(blob: bytes, size: int) -> Float32Array:
    """A column-major ``size`` x ``size`` float32 BLOB as a row-major array."""
    values = np.frombuffer(blob, dtype="<f4")
    if values.size != size * size:
        raise SessionError(f"expected {size * size} floats in a matrix, got {values.size}")
    return np.ascontiguousarray(values.reshape(size, size).T, dtype=np.float32)


def vectors(blob: bytes) -> Float32Array:
    """An N x 3 float32 BLOB. Empty BLOBs give shape (0, 3)."""
    values = np.frombuffer(blob, dtype="<f4")
    if values.size % 3:
        raise SessionError(f"{values.size} floats is not a whole number of 3-vectors")
    return values.reshape(-1, 3).astype(np.float32)


def identifiers(blob: bytes) -> UInt64Array:
    return np.frombuffer(blob, dtype="<u8").astype(np.uint64)


class Session:
    """An open recording. Prefer :func:`open_session`, which also accepts zips; close it, or use ``with``."""

    def __init__(self, bundle: Path) -> None:
        self.bundle = bundle.expanduser().resolve()
        database = self.bundle / "session.sqlite"
        if not database.is_file():
            raise SessionError(f"{bundle} has no session.sqlite")
        self._db = sqlite3.connect(f"{database.as_uri()}?mode=ro", uri=True)
        self.meta: dict[str, str] = dict(self._db.execute("SELECT key, value FROM meta").fetchall())
        version = self.meta.get("schema_version")
        if version is None or not version.isdigit() or int(version) not in SUPPORTED_VERSIONS:
            self.close()
            supported = ", ".join(str(v) for v in SUPPORTED_VERSIONS)
            raise UnsupportedSchemaError(
                f"{bundle.name}: schema_version {version!r} is not supported (this reader knows {supported})"
            )
        self.schema_version = int(version)
        log.info("opened %s (%d frames)", bundle, self.frame_count())

    def __enter__(self) -> Self:
        return self

    def __exit__(
        self, kind: type[BaseException] | None, error: BaseException | None, trace: TracebackType | None
    ) -> None:
        self.close()

    def close(self) -> None:
        self._db.close()

    @property
    def video_path(self) -> Path | None:
        path = self.bundle / "video.mov"
        return path if path.is_file() else None

    def frame_count(self) -> int:
        return int(self._db.execute("SELECT count(*) FROM frame").fetchone()[0])

    def frame(self, idx: int) -> Frame:
        row = self._db.execute("SELECT * FROM frame WHERE idx = ?", (idx,)).fetchone()
        if row is None:
            raise SessionError(f"no frame {idx} in {self.bundle.name}")
        return _frame(row)

    def frames(self) -> Iterator[Frame]:
        for row in self._db.execute("SELECT * FROM frame ORDER BY idx"):
            yield _frame(row)

    def frame_times(self) -> tuple[Int64Array, Float64Array]:
        """``(idx, t)`` of every frame, in order."""
        rows = self._db.execute("SELECT idx, t FROM frame ORDER BY idx").fetchall()
        data = np.array(rows, dtype=np.float64).reshape(-1, 2)
        return data[:, 0].astype(np.int64), data[:, 1]

    def image_flags(self) -> BoolArray:
        """``has_image`` of every frame, in ``idx`` order."""
        rows = self._db.execute("SELECT has_image FROM frame ORDER BY idx").fetchall()
        return np.array([r[0] for r in rows], dtype=bool)

    def first_image_idx(self) -> int | None:
        """The first log frame with an image. Blender drops a leading video gap, so the clip starts here (§15 R2)."""
        value = self._db.execute("SELECT min(idx) FROM frame WHERE has_image = 1").fetchone()[0]
        return None if value is None else int(value)

    def delivered_fps(self) -> float | None:
        """Frames per second ARKit actually delivered: 1 / the median frame interval (§3.4)."""
        _, t = self.frame_times()
        if t.size < 2:
            return None
        return float(1.0 / np.median(np.diff(t)))

    def anchors(self) -> list[AnchorEvent]:
        rows = self._db.execute("SELECT * FROM plane_anchor ORDER BY rowid").fetchall()
        return [_anchor(r) for r in rows]

    def locations(self) -> list[Location]:
        return [Location(*r) for r in self._db.execute("SELECT * FROM location ORDER BY rowid")]

    def headings(self) -> list[Heading]:
        return [Heading(*r) for r in self._db.execute("SELECT * FROM heading ORDER BY rowid")]

    def events(self) -> list[Event]:
        return [Event(*r) for r in self._db.execute("SELECT * FROM event ORDER BY rowid")]

    def cloud_rows(self) -> list[CloudRow]:
        """The phone's averaged cloud (schema v2), by frame. Empty for version 1 files."""
        if self.schema_version < 2:
            return []
        rows = []
        for frame_idx, full, removed, ids, points, samples in self._db.execute(
            "SELECT * FROM cloud ORDER BY frame_idx"
        ):
            row = CloudRow(
                frame_idx=int(frame_idx),
                full=bool(full),
                removed=identifiers(removed),
                ids=identifiers(ids),
                points=vectors(points),
                samples=np.frombuffer(samples, dtype="<u2").astype(np.uint16),
            )
            if not len(row.ids) == len(row.points) == len(row.samples):
                raise SessionError(f"cloud row {frame_idx}: ids, points and samples differ in length")
            rows.append(row)
        return rows


def _frame(row: tuple[Any, ...]) -> Frame:
    idx, t, has_image, tracking, reason, mapping, camera, intrinsics, exposure, thermal, count, points, ids = row
    frame = Frame(
        idx=idx,
        t=t,
        has_image=bool(has_image),
        tracking=tracking,
        tracking_reason=reason,
        mapping=mapping,
        camera=matrix(camera, 4),
        intrinsics=matrix(intrinsics, 3),
        exposure_s=exposure,
        thermal=thermal,
        points=vectors(points),
        point_ids=identifiers(ids),
    )
    if frame.points.shape[0] != count or frame.point_ids.shape[0] != count:
        raise SessionError(f"frame {idx}: point_count {count} doesn't match its BLOBs")
    return frame


def _anchor(row: tuple[Any, ...]) -> AnchorEvent:
    frame_idx, anchor_id, event, alignment, classification, transform, center, extent, boundary = row
    return AnchorEvent(
        frame_idx=frame_idx,
        anchor_id=anchor_id,
        event=event,
        alignment=alignment,
        classification=classification,
        transform=None if transform is None else matrix(transform, 4),
        center=None if center is None else vectors(center)[0],
        extent=None if extent is None else vectors(extent)[0],
        boundary=None if boundary is None else vectors(boundary),
    )


def default_cache() -> Path:
    return Path.home() / "PlaneLab" / "cache"


def open_session(path: Path, cache: Path | None = None) -> Session:
    """Opens a ``.planelab`` folder, or a zip of one, extracted once into ``cache`` (``~/PlaneLab/cache``)."""
    path = path.expanduser()
    if path.is_dir():
        return Session(path)
    if path.is_file() and zipfile.is_zipfile(path):
        return Session(_extract(path, cache or default_cache()))
    raise SessionError(f"{path} is neither a .planelab folder nor a zip of one")


def _extract(archive: Path, cache: Path) -> Path:
    stat = archive.stat()
    key = hashlib.sha1(f"{archive.resolve()}:{stat.st_size}:{stat.st_mtime_ns}".encode()).hexdigest()[:12]
    target = cache / f"{archive.stem}-{key}"
    if not target.is_dir():
        cache.mkdir(parents=True, exist_ok=True)
        staging = Path(tempfile.mkdtemp(dir=cache, prefix=".extract-"))
        try:
            # zipfile strips absolute paths and ".." from member names, so members can't escape `staging`.
            with zipfile.ZipFile(archive) as bundle_zip:
                bundle_zip.extractall(staging)
            staging.rename(target)
        except BaseException:
            shutil.rmtree(staging, ignore_errors=True)
            raise
        log.info("extracted %s to %s", archive.name, target)
    for candidate in (target, *sorted(p.parent for p in target.rglob("session.sqlite"))):
        if (candidate / "session.sqlite").is_file():
            return candidate
    raise SessionError(f"{archive.name} holds no session.sqlite")
