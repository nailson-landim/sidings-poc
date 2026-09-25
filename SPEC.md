# SPEC: Plane Lab (record on the phone, replay and fit on the Mac)

*Status: **draft for review** (Phase 1, Specify). Created 2026-09-25 from `REQUEST.md`. Context: `CONSOLIDATION.md` (D1–D3, §4, §8, §10b).*

This one file holds the spec for the Plane Lab and, once the spec is approved, its plan (§17) and tasks (§18). For this work, `ARKit_WallDetection/tasks/plan.md` and `tasks/todo.md` aren't used.

---

## 0. Decisions from the brainstorm (2026-09-25)

| # | Decision | Status |
|---|---|---|
| L1 | **Offline first.** The phone only records. Point averaging, plane fitting and plane tracking run in Python on the Mac, from a CLI and inside Blender. The config that works best gets ported to `PlaneKit` in a later phase. | Decided (user) |
| L2 | **Images are recorded as HEVC video**, one video frame per logged frame. Pose, intrinsics and feature points are logged for every `ARFrame`. | Decided (user) |
| L3 | **Recall is judged by eye in v1.** No ground truth and no metrics beyond per-frame counts. | Decided (user) |
| L4 | **One file:** this `SPEC.md` holds the spec, the plan and the tasks. | Decided (user) |
| L5 | A session is a **folder bundle**: `session.sqlite` (per-frame data) plus `video.mov`. | Proposed; review in §3 |
| L6 | The Python core depends only on **numpy and the standard library**, so it loads inside Blender with no extra installs. | Proposed; review in §16 |

## 1. Objective

### Why

SidingsAR shows what ARKit's plane detection gives us for free. On LiDAR iPhones that's passable at close range. On non-LiDAR iPhones it isn't enough: ARKit favors **precision over recall**, so walls show up late or not at all. We want the opposite trade: a rough plane early, refined as evidence comes in (CONSOLIDATION D3, D4).

ARFeaturePointFindSurface shows the raw material is there. Its averaged `rawFeaturePoints` cloud is enough to fit planes on a non-LiDAR phone, but its result flickers (see *Background* below). What's missing is the part ARKit does well: **planes that persist**, keep their identity, and update their pose and extent over time.

Tuning an algorithm like that on the phone is slow: every change needs a rebuild, an install and a new walk. So first we build a **lab**:

1. **Record** exactly what ARKit gave the phone, frame by frame.
2. **Replay** it on the Mac, running our own *accumulate → fit → track* pipeline.
3. **Watch** the result on a Blender timeline, next to the video and to ARKit's own planes.
4. **Change a setting and re-run** in seconds, not minutes.

### Who

One researcher (the user). Capture on an iPhone 13 (no LiDAR) and an iPhone 13 Pro (LiDAR). Analysis on the Mac Studio with Blender 5.0.1.

### User stories

- **Record:** I tap **Record**, walk a room or a facade, and tap **Stop**. I get a session I can AirDrop or copy to the Mac.
- **Replay:** I import the session into Blender and scrub the timeline. For each frame I see:
  - the phone's camera with its video
  - that frame's raw feature points
  - the averaged cloud so far
  - ARKit's planes as they were at that moment
  - our planes as they were at that moment
- **Tune:** I change a setting (for example *min samples per feature* or *inlier distance*) and press **Recompute**. Then I check whether our planes appear sooner and hold steadier than ARKit's.

### What we'll look at first

| # | Question | Why it matters |
|---|---|---|
| E1 | **How far do the feature points reach outdoors?** CurvSurf's README says that around December 2025 the range of `rawFeaturePoints` grew from about 10 m to about 65 m. Apple hasn't documented this. The lab shows point-range percentiles per frame. | If it's true, feature points cover the 8–15 m facade standoff (CONSOLIDATION §4). That changes what non-LiDAR phones can do. |
| E2 | **How soon does each wall get a plane**, ARKit vs. ours, in the same session? | This is the recall gap we want to close. |
| E3 | **Which settings buy recall**, and what do they cost in false or unstable planes? | This produces the config to port to the phone. |

### Background: two findings from reading the code (2026-09-25)

- **Why ARFeaturePointFindSurface flickers.** It's a design choice, not only noise. `AppState.detectGeometries` runs every frame and works like this:
  1. It picks the averaged point nearest the view ray.
  2. It asks FindSurface for one surface around that point, from scratch.
  3. It shows whatever comes back.

  Nothing links a result to the previous frame's result, and nothing persists unless you press Capture. The tracker stage in §5 is the missing piece.
- **Its motion gate is inverted.** `CameraMotionDetector.hasCameraMovedEnough` is documented as "moved ≥ 3 cm or turned ≥ 3°". The code tests `distance² < minDistance²`, so it actually accepts frames where the camera moved *less* than 3 cm. At walking speed it accepts nearly every frame, and during fast translation it blocks until the camera turns. The lab implements the documented gate, and can also emulate the upstream behavior so we can compare the two.

### Reference assets

| Asset | What it shows |
|---|---|
| `AR_APP.PNG` | The 2018 tutorial app indoors: the "dirty" native-ARKit baseline that led to SidingsAR |
| `BUILDING_SAMPLE.png` | ARFeaturePointFindSurface outdoors, **the working example to reproduce in the lab** (details below) |

**`BUILDING_SAMPLE.png`** (2026-09-25, iPhone 13 without LiDAR, sunny, plane mode):

- **What was captured.** The buffer holds 3,533 averaged points, including points on the building that the user estimates at 8–10 m high. The user stood less than 5 m from the building and looked up, and says it took a while to collect them.
- **What it doesn't test.** From under 5 m away, those points are roughly 10 m from the camera or less. That's still inside the old ~10 m limit, so this sample doesn't test the ~65 m claim (E1). It does show that a non-LiDAR phone gets **usable points on the upper storey of a tall wall** from close up.
- **Where the points land.** They cluster on **edges and texture**: the parapet line, the tower's vertical corner, the trim band and its corners, window frames and grilles. The large plain plaster faces have almost none. The probe circle on the plain face has no points inside it, and no plane preview shows in this frame.
- **Why that matters for siding.** Plain paint behaves like the textureless and repetitive surfaces of lap siding in sun (CONSOLIDATION §4). Trim and openings are what give the tracker features, which matches the capture advice to keep non-siding texture in frame.

What it means for the lab:

1. **Walls are seen through their outlines.** The fitter gets a wall's corners, trim and openings, not its face. Using the convex hull of the inliers as the extent (§5.1, stage 5) fits that.
2. **Edge points are degenerate samples.** Points along one line (a vertical corner, the parapet) fit infinitely many planes. Every hypothesis needs a **non-collinearity check** on its inliers (§5.1).
3. **Corners belong to two walls.** Sequential RANSAC normally removes a plane's inliers before searching again. Here that would take the shared corner away from the second wall, so points near an edge must stay available (§5.1).
4. **It's the first session to record.** Record the same building with the SidingsAR recorder twice: from under 5 m to reproduce this result, and from 10–15 m for E1. Then compare in Blender how long ARKit and our pipeline each take to get the upper points and planes.

## 2. Capability map

The request bundles four parts that can be tested separately. They stay in this one file, but each keeps a stable id.

| Module id | Responsibility | Depends on |
|---|---|---|
| `session-format` | The on-disk contract between the phone and the Mac: bundle layout, tables, conventions, versioning (§3) | — |
| `recorder` | Record/Stop in SidingsAR, live writing, finalizing, listing and sharing sessions (§4) | `session-format` |
| `lab-core` | Python: read sessions, accumulate points, fit planes, track planes, CLI, synthetic sessions (§5) | `session-format` |
| `blender-addon` | A Blender 5 extension: import, timeline replay, layers, settings, Recompute (§6) | `lab-core` |

**Build order:** first a risk spike (§15, R1 and R2), then `session-format`, then `recorder` and `lab-core` in parallel (the core starts on synthetic sessions), then `blender-addon`.

## 3. Session format (`session-format`)

### 3.1 Bundle

```
20260925-101500.planelab/        one recording (a folder; zipped for transfer)
├── session.sqlite                meta, per-frame data, ARKit plane events, session events
├── video.mov                     HEVC, one video frame per logged frame
└── lab/                          created on the Mac; the phone never writes here
    └── <run-name>/               one Recompute: config.toml + results.sqlite
```

**Why SQLite.** It's a single file that's safe to append to while recording (WAL mode, committed in batches). A killed app loses at most the last uncommitted batch. It's built into iOS (`import SQLite3`) and into Blender's Python (`sqlite3`, SQLite 3.50.4 in Blender 5.0.1). Looking up a frame by index needs no parsing. Per-frame point arrays are stored as BLOBs, so there's **one row per frame**, not one row per point, and Python reads them with `numpy.frombuffer`.

**Alternatives considered:**
- **JSONL plus binary files:** easy to inspect, but more files and no transactions.
- **nerfstudio/Record3D-style folders:** reusable by other tools, but they have no place for per-frame feature points with their ids, or for anchor events.

An export to other formats can come later.

### 3.2 Conventions

- **Frame number (`idx`):** 0-based, assigned by the recorder to every logged `ARFrame`. It's the join key everywhere: tables, video, lab results, and the Blender timeline, where Blender frame = `idx + 1`.
- **Time:** `t` = `ARFrame.timestamp`, in seconds of device uptime. Wall-clock start and stop times are in `meta`.
- **Units and axes:** meters. ARKit world with `worldAlignment = .gravity`: right-handed, +Y up (against gravity), origin wherever the session started. The camera looks down its −Z axis, with +Y up and +X right. Blender uses the same camera convention, so only the world needs rotating: Blender `(x, y, z)` = ARKit `(x, −z, y)`, which is +90° about X.
- **Matrices:** column-major `float32`, as simd stores them. `camera` is the world ← camera transform (`ARCamera.transform`).
- **Intrinsics:** `ARCamera.intrinsics`, in pixels of the captured image. That image is always landscape, in sensor orientation, whatever the UI orientation.
- **BLOBs:** little-endian, packed with no padding.
- **Immutability:** once a recording is finalized, `session.sqlite` and `video.mov` are never modified. Everything computed on the Mac goes under `lab/`.

### 3.3 Tables (schema version 1)

**`meta`** (`key TEXT PRIMARY KEY, value TEXT`):

| Key | Example |
|---|---|
| `schema_version` | `1` |
| `app_version`, `device_model`, `os_version` | `2.2`, `iPhone14,5`, `26.0` |
| `lidar` | `0` / `1` |
| `plane_detection`, `world_alignment` | `both`, `gravity` |
| `video_width`, `video_height`, `video_fps`, `video_codec`, `video_bitrate` | `1920`, `1440`, `60`, `hevc`, `8000000` |
| `started_at`, `stopped_at` | ISO 8601 UTC |
| `stop_reason` | `user` / `interruption` / `reset` / `mode_change` / `low_disk` / `error` |
| `frames_logged`, `frames_with_image`, `frames_dropped` | counters written when the recording is finalized |

**`frame`**, one row per logged `ARFrame`:

| Column | Type | Content |
|---|---|---|
| `idx` | INTEGER PK | Frame number |
| `t` | REAL | `ARFrame.timestamp` |
| `has_image` | INTEGER | 1 when `video.mov` holds this frame's image |
| `tracking` | INTEGER | 0 not available, 1 limited, 2 normal |
| `tracking_reason` | INTEGER | 0 none, 1 initializing, 2 excessive motion, 3 insufficient features, 4 relocalizing |
| `mapping` | INTEGER | `ARFrame.worldMappingStatus` (0–3) |
| `camera` | BLOB 64 B | 16 × f32, world ← camera |
| `intrinsics` | BLOB 36 B | 9 × f32 |
| `exposure_s` | REAL | `ARCamera.exposureDuration` |
| `thermal` | INTEGER | `ProcessInfo.thermalState` (0–3) |
| `point_count` | INTEGER | N |
| `points` | BLOB 12·N B | `rawFeaturePoints.points`, N × 3 f32, world |
| `point_ids` | BLOB 8·N B | `rawFeaturePoints.identifiers`, N × u64 |

**`plane_anchor`**, one row per ARKit plane callback. This is ARKit's own result, kept for side-by-side viewing (see §16 Q1):

| Column | Type | Content |
|---|---|---|
| `frame_idx` | INTEGER | Last logged frame when the callback arrived (±1 frame) |
| `anchor_id` | TEXT | UUID |
| `event` | INTEGER | 0 add, 1 update, 2 remove (a remove has only the id) |
| `alignment`, `classification` | INTEGER | Raw enum values |
| `transform` | BLOB 64 B | `ARAnchor.transform` |
| `center`, `extent` | BLOB 12 B each | `center`; `planeExtent` (width, height, rotationOnYAxis) |
| `boundary` | BLOB 12·M B | `geometry.boundaryVertices`, anchor-local |

**`event`** (`frame_idx INTEGER, kind TEXT, detail TEXT`) logs:
- tracking-state changes
- interruptions and relocalization
- recording start and stop
- user marks (the Mark button, §4)

In Blender these become timeline markers.

### 3.4 Video

- `video.mov`: HEVC, at the captured-image resolution (typically 1920 × 1440), in landscape sensor orientation, with no rotation metadata.
- The video frame for log frame `idx` has presentation time `idx / video_fps`. A frame without an image leaves a gap in the timestamps and has `has_image = 0`, so video time always maps back to `idx`.
- A keyframe at least every 0.5 s, so seeking in Blender stays fast.
- Written as a fragmented movie (`movieFragmentInterval` ≈ 1 s), so a killed recording still plays up to its last fragment.

### 3.5 Versioning

Any change to the tables or conventions bumps `schema_version`. Readers refuse versions they don't know, with a clear message. Contract fixtures in `session-format/fixtures/` are checked by both the Swift tests and the Python tests.

## 4. Recorder (`recorder`, in SidingsAR)

| # | Requirement |
|---|---|
| R1 | A **Record/Stop** button in the HUD. |
| R2 | While recording, the HUD shows elapsed time, frames logged, images dropped, MB written and free disk space. |
| R3 | Recording runs **alongside** the current plane viewer, and everything it does today keeps working. These stop and finalize a recording first, and log the reason: Reset, a detection-mode change, a session interruption, going to the background, or a session error. |
| R4 | **Capture path.** Inside `session(_:didUpdate frame:)`, copy the pose, intrinsics, points and ids into a `FrameRecord`. Copy `capturedImage` into a small pixel-buffer pool the recorder owns (about 4 buffers). Hand both to background writers. **Never retain the `ARFrame` or ARKit's pixel buffer.** If no pool buffer is free, or the video input isn't ready, skip the image (`has_image = 0`) but keep the metadata. |
| R5 | **Write path.** SQLite runs on its own serial queue in WAL mode, with one transaction about every 0.5 s. The queue is bounded. If it ever fills, whole frames are dropped and counted. The delegate is never blocked. |
| R6 | **Stop:** finish the video, commit, write the final `meta` rows, close. |
| R7 | **Sessions sheet:** a list of recordings (date, duration, size, device), with **Share** (zipped with `NSFileCoordinator`'s `.forUploading`, so no dependency) and **Delete**. |
| R8 | Sessions live in `Documents/Sessions/` and are visible in the Files app and in Finder's device view (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`). |
| R9 | Recording stops by itself when free space drops below 1 GB (`stop_reason = low_disk`). |
| R10 | **Memory stays flat** while recording, because every buffer and queue is bounded. It's checked with the existing *mem MB* readout. |
| R11 | *(Should)* A **Mark** button adds an `event` row. Use it to note things like "wall A starts here". |

**Estimated size:** about 100 MB per minute (roughly 60 MB of video at 8 Mbps plus about 35 MB of feature points at 60 Hz). To be measured.

**Where the code goes** (following `ARKit_WallDetection/CLAUDE.md`):
- **In the PlaneKit package, a new library target `SessionLog`:** record types, BLOB packing, the schema, the SQLite writer and the drop policy. It imports Foundation, simd and the system `SQLite3` module, so it's tested with `swift test` on the Mac (see §16 Q3).
- **In `SidingsAR/Recording/`:** the glue for ARKit, AVFoundation (`AVAssetWriter`) and the UI.

## 5. Lab core (`lab-core`, Python)

### 5.1 Pipeline

The pipeline runs over the whole session in order. It's deterministic for a given config and seed.

| Stage | What it does | Starting defaults |
|---|---|---|
| 1. Load | Frames, poses, points, ids, ARKit plane events, session events | — |
| 2. Point filter | Drop points closer than `near_cut_m` to the camera; optionally drop far points and frames without `normal` tracking | 0.25 m (CurvSurf) |
| 3. Motion gate | Use a frame's points only if the camera moved ≥ `gate_move_m` or turned ≥ `gate_turn_deg` since the last accepted frame. Modes: `intended` / `upstream` (the inverted gate, §1) / `off` | 3 cm, 3° (CurvSurf) |
| 4. Accumulator | Per feature id: a FIFO of up to `max_samples`, samples beyond `zscore` σ from the mean dropped, and the point placed at the mean of the rest once there are `min_samples`. The cloud keeps up to `max_ids` ids, evicting the oldest first. Also records each point's sample count and spread. | 100, 2.0, 5, 100 000 (CurvSurf) |
| 5. Plane fit | Every `fit_every` frames: sequential RANSAC on the averaged cloud, then a least-squares refit on the inliers. Models: **vertical** (normal ⟂ gravity, 2-point sample), **horizontal** (normal ∥ gravity, 1-point), **free** (3-point, off by default). The inlier distance can grow with range (`τ = τ₀ + k·z²`) because point depth noise grows with distance. A hypothesis is rejected when its inliers are nearly collinear (an edge seen alone). Points within `edge_keep_m` of an accepted plane's boundary stay available for the next search, so the second wall at a corner keeps its support. Extent = the convex hull of the inliers on the plane, split into connected regions so two separate stretches of the same plane don't merge. See `BUILDING_SAMPLE.png` in §1. | `fit_every` 6 (10 Hz), τ₀ 3 cm, `min_inliers` 30, `min_spread_m` 0.3, `edge_keep_m` 0.1. Starting values, to tune. |
| 6. Plane tracker | Keeps planes across fits, like ARKit anchors: see §5.2. | Merge terms taken from PlaneKit NMS: 10°, 8 cm, 0.3 overlap |
| 7. Results | Written to `lab/<run>/results.sqlite`, next to a copy of `config.toml`. Stored so that any frame can be shown without recomputing. | — |

### 5.2 Plane tracker (stage 6)

- **Match:** each new fit is matched to an existing plane by normal angle, plane distance and overlap, the same terms PlaneKit uses for NMS.
- **Update:** pose and extent are updated by EMA or by a refit over recent inliers.
- **Lifecycle:** a plane is *tentative* until it has been matched `confirm_hits` times, then *confirmed*. Confirmed planes that overlap on the same plane **merge**; the older id survives, the way ARKit reports a merge with `didRemove`. A plane that isn't seen for a long time goes *stale* but isn't deleted, since ARKit also keeps its anchors.
- **Events:** `add` / `update` / `merge` / `stale`, so the logic ports to the phone later as a delegate-style API.

### 5.3 Settings that trade toward recall

| Setting | Toward recall | Cost |
|---|---|---|
| `min_samples` ↓ | Points show up sooner | Noisier points (needle-shaped error along the view ray) |
| `min_inliers` ↓ | Planes from less support | More false planes |
| `min_spread_m` ↓ | Planes from thin strips, such as one trim band | More planes fitted to a single edge |
| `tau0` ↑, range scaling on | Far walls get support | Nearby surfaces bleed into each other |
| Vertical/horizontal prior on | Fewer points needed per hypothesis | Misses slanted surfaces (acceptable for siding) |
| `confirm_hits` ↓ | Planes are shown sooner | More short-lived planes |
| Merge distance ↑ | Fewer duplicates | Hides recessed doors and windows 3–10 cm deep (CLAUDE.md domain note) |

All settings live in one frozen `LabConfig`, loaded from TOML. Presets go in `PlaneLab/configs/` (`default.toml`, `recall.toml`).

### 5.4 Per-frame readouts

For each frame the lab reports:
- tracking state
- raw points
- averaged points
- fitted hypotheses
- our tentative and confirmed planes
- ARKit's planes
- point range p50 / p95 / max (for E1)

The Blender panel shows them, and the CLI can export them as CSV. There's no ground truth and no recall or precision score in v1 (L3).

### 5.5 CLI

```bash
python -m planelab info  <bundle>                            # duration, frames, drops, tracking %, point range
python -m planelab run   <bundle> --config configs/recall.toml --name recall-01
python -m planelab synth <out.planelab> --scene facade --seed 7   # synthetic session, no video; scenes: facade, edges, room
python -m planelab export <bundle> --run recall-01 --csv out.csv  # per-frame readouts
```

## 6. Blender add-on (`blender-addon`)

- **Packaging:** a Blender 5.0+ extension (`blender_manifest.toml`) with no bundled wheels. numpy 1.26.4 and `sqlite3` come with Blender 5.0.1 (checked 2026-09-25). The core has no `bpy` import and ships inside the extension's zip.
- **Import:** *File › Import › Plane Lab Session*. It accepts a `.planelab` folder or its `.zip`; a zip is extracted to a cache folder. It then:
  - sets the scene fps to `video_fps`
  - sets the frame range to `1 … frames_logged`
  - applies the ARKit → Blender axis conversion (§3.2)
- **What it builds,** in one collection per session:
  - **Camera:** keyframed pose per frame; focal length and shift from the intrinsics; resolution from the image size. **The video is its background image** (a movie clip), so looking through the camera shows the frame with our points and planes on top.
  - **Camera trail:** a static polyline.
  - **Layers** that follow the current frame:
    - raw points
    - averaged cloud (colored by sample count)
    - **our planes** (colored by track id; tentative planes lighter, stale ones grey; label with id, age, inliers and RMS)
    - **ARKit's planes** (SidingsAR colors: cyan wall, green floor, and so on)

    A frame-change handler updates these meshes from cached arrays. Only the camera is keyframed.
  - **Timeline markers** from `event` rows.
- **Panel** (*3D View › Sidebar › Plane Lab*):
  - session info
  - layer toggles
  - the per-frame readouts (§5.4)
  - every `LabConfig` setting, with load and save as TOML (the same files the CLI reads)
  - **Recompute:** runs the core in the background with a progress bar and a Cancel button, without freezing Blender, and stores the output as a named run
  - *(Should)* a run picker to switch between runs and compare them

## 7. Tech stack

| Part | Stack |
|---|---|
| iOS | Swift 6, Xcode 26.3, iOS 18, ARKit + RealityKit (existing), AVFoundation `AVAssetWriter` (HEVC), system `SQLite3`, `os.Logger`. No new third-party packages. |
| Python core | Python **3.11**, the same as Blender 5.0.1's bundled 3.11.13. **numpy 1.26.4**, pinned to Blender's version. Standard library: `sqlite3`, `tomllib`, `zipfile`, `logging`, `dataclasses`. |
| Python dev | `virtualenv` `.venv`, pytest, pytest-cov, ruff, all pinned in `requirements.txt` |
| Blender | 5.0.1, extension format (`blender --command extension build`) |

## 8. Commands

```bash
# iOS (unchanged, plus the new SessionLog target)
cd ARKit_WallDetection/PlaneKit && swift test
xcodebuild -project ARKit_WallDetection/SidingsAR.xcodeproj -scheme SidingsAR \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build

# Python core
cd PlaneLab
virtualenv -p python3.11 .venv && source .venv/bin/activate
pip install -r requirements.txt
ruff check . && ruff format --check .
pytest --cov=planelab --cov-fail-under=85

# Blender extension: build, install, headless smoke test
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
$BLENDER --command extension build --source-dir blender --output-dir dist
$BLENDER --command extension install-file -r user_default -e dist/planelab-<version>.zip
$BLENDER --background --factory-startup --python-exit-code 1 \
  --python tests/blender/smoke_import.py -- <synthetic.planelab>
```

## 9. Project structure

```
sidings_poc/
├── SPEC.md                              this file: spec, then plan and tasks
├── session-format/fixtures/             contract fixtures read by the Swift and Python tests
├── ARKit_WallDetection/
│   ├── SidingsAR/Recording/             SessionRecorder, VideoWriter, SessionsView (glue)
│   └── PlaneKit/
│       ├── Sources/SessionLog/          new target: FrameRecord, packing, schema, SQLite writer, drop policy
│       └── Tests/SessionLogTests/
└── PlaneLab/                            new
    ├── requirements.txt / pyproject.toml
    ├── src/planelab/                    core, no bpy: session, accumulate, fit, track, pipeline, synth, cli
    ├── blender/                         extension: manifest, import operator, panel, frame handler
    ├── configs/                         default.toml, recall.toml
    └── tests/                           pytest suites; tests/blender/ for headless Blender smoke tests
```

Recordings stay **out of git**: `*.planelab` goes in `.gitignore`. They are large, and they contain video of houses and possibly people. On the Mac, keep them under `~/PlaneLab/sessions/`.

## 10. Code style

Swift follows the existing SidingsAR rules: value types in `SessionLog`, glue in the app, `os.Logger`, no `print`.

```swift
/// Everything the recorder keeps from one ARFrame. Built inside the delegate call; the frame itself is never retained.
public struct FrameRecord: Sendable, Equatable {
    public let index: Int
    public let timestamp: TimeInterval
    public let camera: simd_float4x4
    public let intrinsics: simd_float3x3
    public let tracking: TrackingCode
    public let points: [SIMD3<Float>]
    public let pointIDs: [UInt64]
    public let hasImage: Bool
}
```

Python follows the global rules:
- strict type hints
- `@dataclass(slots=True, frozen=True)` for internal data
- `logging`, never `print` (except in the CLI entry point)
- imports at the top of the file
- ruff

Reading SQLite is synchronous on purpose: this is a batch tool inside Blender, with no server and no event loop.

```python
@dataclass(slots=True, frozen=True)
class FitConfig:
    tau0_m: float = 0.03
    tau_range_k: float = 0.0
    min_inliers: int = 30
    vertical_prior: bool = True


def fit_vertical_plane(
    points: npt.NDArray[np.float32], cfg: FitConfig, rng: np.random.Generator
) -> PlaneFit | None:
    """2-point RANSAC for planes whose normal is perpendicular to gravity (+Y in ARKit world)."""
```

## 11. Testing strategy

| Level | What | Where |
|---|---|---|
| Swift unit (Mac) | `SessionLog`: packing round-trip, schema, batched commits, drop policy under backpressure, reading a writer that was never closed (crash consistency), contract fixtures | `PlaneKit/Tests/SessionLogTests/` |
| Python unit | Reader (contract fixtures, synthetic bundles, zip input, unknown version refused); accumulator (CurvSurf semantics on hand-built cases, all three gate modes); RANSAC (planted planes with noise and outliers; normal and offset error bounds; the priors); tracker (stable ids under jitter, merge, stale, no id flips); pipeline determinism; CLI smoke | `PlaneLab/tests/` |
| Contract | The same fixtures decoded by Swift and by Python must give the same values | `session-format/fixtures/` |
| Blender, headless | Import a synthetic session; check the objects, frame range and camera keys; check layer vertex counts at chosen frames | `PlaneLab/tests/blender/` |
| Device (user) | The recorder checkpoints in §13. Never reported as done unless the user saw them. | — |

- Coverage floor: **85 %** on `src/planelab`. Blender glue is covered by the headless tests instead.
- Tests stay on disk.

## 12. Boundaries

**Always**
- Keep the SidingsAR invariants: never retain `ARFrame`s, anchor callbacks only record, one clock (`ARFrame.timestamp`).
- `idx` is the only join key.
- Raw recordings are immutable, and results go under `lab/`.
- The core stays `bpy`-free and numpy-only.
- `swift test`, `pytest` and `ruff` pass before a commit.
- Update this spec when a decision changes. Bump `schema_version` on any format change.

**Ask first**
- Any new dependency: a Swift package, a Python package beyond numpy in the core, or wheels in the extension.
- Changing the schema once real recordings exist.
- Installing on a device.
- Changing how the existing plane viewer behaves.
- Using the FindSurface SDK in our code. It's a closed-source binary, and its license for product use hasn't been checked.
- Commits.

**Never**
- Commit recordings.
- Hold ARKit pixel buffers beyond the recorder's own copy.
- Block the ARSession delegate on disk I/O.
- Push, or re-create nested `.git` folders.

## 13. Success criteria

**Recorder** (device checks by the user, iPhone 13 unless noted):

| # | Criterion |
|---|---|
| S1 | A 5-minute recording completes. *mem MB* stays within ±50 MB of its value 30 s after Record. |
| S2 | ≥ 99 % of `ARFrame`s are logged. ≤ 1 % of images are dropped at the default video format. The plane viewer stays as smooth as without recording. |
| S3 | Force-quit the app during a recording: `session.sqlite` still opens with all frames up to about 1 s before the kill, and `video.mov` plays up to its last fragment. |
| S4 | A session appears in the Files app and in Finder, and AirDrops as a `.zip` that `planelab info` reads. |
| S5 | `swift test` is green with the new `SessionLog` tests. The `xcodebuild` compile check has no new warnings. |

**Format and core** (automated on the Mac):

| # | Criterion |
|---|---|
| S6 | Swift and Python both pass the contract fixtures. An unknown `schema_version` is refused with a clear message. |
| S7 | On synthetic sessions with σ = 1 cm noise and 20 % outliers, every planted plane is found with normal error < 2° and offset error < 2 cm, and the tracker keeps **one id per planted plane with no id switches**. This includes an **`edges` scene** where points exist only on corners, trim and openings, as in `BUILDING_SAMPLE.png`: both walls at a shared corner are found, and no plane is fitted to a single edge. |
| S8 | `planelab run` finishes a 2-minute session in < 60 s on the Mac Studio. Pytest coverage is ≥ 85 %. |

**Blender:**

| # | Criterion |
|---|---|
| S9 | A real session imports in < 30 s. Looking through the camera, the raw points sit on the matching image features across the whole timeline, which shows that video, pose and intrinsics are aligned. |
| S10 | Scrubbing to any frame updates every layer in ≤ 100 ms. |
| S11 | Change a setting and press Recompute: the new run shows up without restarting Blender, and the UI stays responsive while it runs. |
| S12 | By eye, on the `BUILDING_SAMPLE.png` building recorded with SidingsAR, you can say for each wall whether our planes appear sooner or later than ARKit's (E2), see the upper-storey points (8–10 m up), and read point-range percentiles (E1). |

**Docs:** `ARKit_WallDetection/README.md` (the recorder), `PlaneLab/README.md` (new), the root `README.md` and `CLAUDE.md`, and `CONSOLIDATION.md` §10b (the E1/E2 findings) are updated.

## 14. Out of scope for v1 (candidates for later)

- Our own fitting on the phone, with our planes shown in AR. This is the port after the lab picks a config (L1).
- LiDAR depth recording, and using LiDAR as a reference.
- Ground truth, hand-marked walls, and recall/precision metrics (L3).
- Segmentation (YOLOv8-seg), monocular depth, raw IMU from CoreMotion (CONSOLIDATION §5 and §4).
- Replaying a recording back into ARKit on the phone.
- Android, and the FindSurface SDK.

## 15. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | HEVC at 1440p60 plus feature-point logging overloads the iPhone 13: dropped images, heat, worse tracking | Hardware encoder, bounded pools, drops and thermal state logged. Fallback: a 30 fps video format, or an image every other frame (the schema already allows `has_image = 0`). **Spike this first.** |
| R2 | Blender's movie clips mishandle timestamp gaps or seek slowly in HEVC, so video and timeline drift | Keyframe at least every 0.5 s; Blender proxies as a fallback. **Spike this first** with a synthetic video that has gaps. |
| R3 | Too much memory to show any frame's averaged cloud (it can reach tens of thousands of points, across thousands of frames) | Snapshots only at the fit cadence, stored as changes since the last snapshot, with periodic full snapshots. Measured against S10. |
| R4 | Pure Python is too slow | Vectorized numpy, fitting every N frames, subsampling. Measured against S8. |
| R5 | Relocalization shifts the world frame mid-session, so poses and points jump | Logged as events and shown as markers. The lab shows the jumps rather than hiding them. Anchor-relative storage (CONSOLIDATION §4) is a product concern, not a concern for this raw log. |
| R6 | ARKit anchor callbacks aren't tied to a frame | Stamped with the last logged frame (±1 frame at 60 Hz). Fine for viewing by eye. |

## 16. Open questions

Each has a proposed default.

1. **Keep recording ARKit's plane anchors?** You chose visual checks only. I kept them because they're cheap (the app already receives them), and seeing them next to ours is the visual comparison for E2. *Default: keep.*
2. **Pydantic.** The global rules use Pydantic at I/O boundaries. The core has to load inside Blender's Python, which ships without Pydantic. *Default: frozen dataclasses with explicit validation for the session reader and the TOML config. Bundling Pydantic wheels into the extension is possible if you want it.*
3. **Where `SessionLog` lives.** *Default: a new target in the PlaneKit package*, which keeps one `swift test`. PlaneKit's current "simd and Foundation only" rule stays true for the `PlaneKit` target; `SessionLog` also imports the system `SQLite3`.
4. **Names:** "Plane Lab", the `.planelab` bundle and the `planelab` package. *Default: as written.*
5. **Session length and devices:** *Default: up to 10 minutes. iPhone 13 first, 13 Pro second.*

## 17. Plan

*Written after this spec is approved.* The outline follows §2's build order: spike R1 and R2, then `session-format`, then `recorder` ∥ `lab-core`, then `blender-addon`, then the first real sessions (E1–E3) and docs.

## 18. Tasks

*Written after the plan is approved.* Each task will have acceptance criteria, a verify step and a device checkpoint where it needs one.
