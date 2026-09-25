"""A minimal writer of the session format (schema v1), used only by ``planelab synth`` (SPEC.md §17.4 P7).

Real recordings come from the Swift recorder; this writer exists so synthetic sessions go through the same reader, the
same tables and the same BLOB layouts (little-endian, column-major matrices) as real ones.
"""

import sqlite3
from pathlib import Path
from types import TracebackType
from typing import Self

import numpy as np
import numpy.typing as npt

from planelab.schema import DDL, SCHEMA_VERSION


def _column_major(matrix: npt.ArrayLike) -> bytes:
    return np.asarray(matrix, dtype="<f4").T.tobytes()


class SessionWriter:
    """Writes ``<bundle>/session.sqlite`` in rollback-journal mode, so the result is one file."""

    def __init__(self, bundle: Path, meta: dict[str, str]) -> None:
        bundle.mkdir(parents=True, exist_ok=True)
        path = bundle / "session.sqlite"
        path.unlink(missing_ok=True)
        self._db = sqlite3.connect(path)
        self._db.executescript(DDL)
        rows = {"schema_version": str(SCHEMA_VERSION), **meta}
        self._db.executemany("INSERT INTO meta VALUES (?, ?)", sorted(rows.items()))

    def __enter__(self) -> Self:
        return self

    def __exit__(
        self, kind: type[BaseException] | None, error: BaseException | None, trace: TracebackType | None
    ) -> None:
        self.close()

    def frame(
        self,
        idx: int,
        t: float,
        camera: npt.ArrayLike,
        intrinsics: npt.ArrayLike,
        points: npt.ArrayLike,
        point_ids: npt.ArrayLike,
        *,
        has_image: bool = False,
        tracking: int = 2,
        tracking_reason: int = 0,
        mapping: int = 3,
        exposure_s: float = 1 / 120,
        thermal: int = 1,
    ) -> None:
        """``camera`` is a row-major (4, 4) world <- camera matrix in ARKit axes; ``points`` is (N, 3) world."""
        xyz = np.asarray(points, dtype="<f4").reshape(-1, 3)
        ids = np.asarray(point_ids, dtype="<u8").reshape(-1)
        if len(xyz) != len(ids):
            raise ValueError(f"frame {idx}: {len(xyz)} points but {len(ids)} ids")
        self._db.execute(
            "INSERT INTO frame VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                idx,
                t,
                int(has_image),
                tracking,
                tracking_reason,
                mapping,
                _column_major(camera),
                _column_major(intrinsics),
                exposure_s,
                thermal,
                len(xyz),
                xyz.tobytes(),
                ids.tobytes(),
            ),
        )

    def event(self, frame_idx: int, kind: str, detail: str) -> None:
        self._db.execute("INSERT INTO event VALUES (?, ?, ?)", (frame_idx, kind, detail))

    def set_meta(self, key: str, value: str) -> None:
        self._db.execute("INSERT OR REPLACE INTO meta VALUES (?, ?)", (key, value))

    def close(self) -> None:
        self._db.commit()
        self._db.close()
