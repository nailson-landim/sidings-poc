"""Everything the Blender timeline needs from a recording, loaded once into packed arrays (SPEC.md §6).

Points of all frames sit in one array; ``offsets[i]:offsets[i + 1]`` are the points of the i-th frame, so the frame
handler only slices.
"""

from dataclasses import dataclass

import numpy as np
import numpy.typing as npt

from planelab.session import Session

Float32Array = npt.NDArray[np.float32]
Float64Array = npt.NDArray[np.float64]
Int64Array = npt.NDArray[np.int64]


@dataclass(slots=True, frozen=True)
class Replay:
    idx: Int64Array
    """(N,) frame numbers, ascending."""
    t: Float64Array
    """(N,) ARFrame timestamps."""
    has_image: npt.NDArray[np.bool_]
    cameras: Float64Array
    """(N, 4, 4) world <- camera, ARKit axes."""
    intrinsics: Float64Array
    """(N, 3, 3)."""
    offsets: Int64Array
    """(N + 1,) point ranges per frame."""
    points: Float32Array
    """(M, 3) raw feature points of every frame, ARKit axes."""
    width: int
    """Captured image width in pixels (meta ``video_width``)."""
    height: int
    fps: int
    """Playback rate: the delivered rate, rounded (SPEC.md §3.4)."""
    first_image: int | None
    """First frame with an image: where the video clip starts (§15 R2)."""

    def __len__(self) -> int:
        return int(self.idx.shape[0])

    def row(self, idx: int) -> int | None:
        """Position of frame ``idx`` in the arrays, or None when it wasn't logged."""
        position = int(np.searchsorted(self.idx, idx))
        return position if position < len(self) and int(self.idx[position]) == idx else None

    def points_at(self, idx: int) -> Float32Array:
        position = self.row(idx)
        if position is None:
            return np.empty((0, 3), dtype=np.float32)
        return self.points[self.offsets[position] : self.offsets[position + 1]]


def load_replay(session: Session) -> Replay:
    idx: list[int] = []
    t: list[float] = []
    has_image: list[bool] = []
    cameras: list[np.ndarray] = []
    intrinsics: list[np.ndarray] = []
    counts: list[int] = []
    chunks: list[np.ndarray] = []
    for frame in session.frames():
        idx.append(frame.idx)
        t.append(frame.t)
        has_image.append(frame.has_image)
        cameras.append(frame.camera)
        intrinsics.append(frame.intrinsics)
        counts.append(frame.points.shape[0])
        chunks.append(frame.points)
    fps = session.delivered_fps()
    return Replay(
        idx=np.array(idx, dtype=np.int64),
        t=np.array(t, dtype=np.float64),
        has_image=np.array(has_image, dtype=bool),
        cameras=np.array(cameras, dtype=np.float64).reshape(-1, 4, 4),
        intrinsics=np.array(intrinsics, dtype=np.float64).reshape(-1, 3, 3),
        offsets=np.concatenate([[0], np.cumsum(counts, dtype=np.int64)]).astype(np.int64),
        points=np.concatenate(chunks).astype(np.float32) if chunks else np.empty((0, 3), dtype=np.float32),
        width=int(session.meta.get("video_width", "1920")),
        height=int(session.meta.get("video_height", "1440")),
        fps=max(1, round(fps)) if fps else 60,
        first_image=session.first_image_idx(),
    )
