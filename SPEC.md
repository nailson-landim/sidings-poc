# SPEC: Plane Lab (record on the phone, replay and fit on the Mac)

*Status: **spec approved** (user, 2026-09-28: "Everything seems fine"). **Plan (§17) and tasks (§18) approved 2026-09-28. Phases 0 and 1 are done (Checkpoints 0 and 1 passed); Phase 2 is in progress (T11, T14–T16 done, T10 code done; T21's averaged-cloud layer brought forward, P19). 2026-09-29: L12 puts CurvSurf's accumulator on the phone, live and recorded (Phase 2C, T27–T30).** Created 2026-09-25 from `REQUEST.md`; review answers folded in 2026-09-28 (L5–L11). Context: `CONSOLIDATION.md` (D1–D3, §4, §8, §10b).*

This one file holds the spec for the Plane Lab and, once the spec is approved, its plan (§17) and tasks (§18). For this work, `ARKit_WallDetection/tasks/plan.md` and `tasks/todo.md` aren't used.

---

## 0. Decisions from the brainstorm (2026-09-25)

| # | Decision | Status |
|---|---|---|
| L1 | **Offline first.** The phone only records. Point averaging, plane fitting and plane tracking run in Python on the Mac, from a CLI and inside Blender. The config that works best gets ported to `PlaneKit` in a later phase. | Decided (user) |
| L2 | **Images are recorded as HEVC video**, one video frame per logged frame. Pose, intrinsics and feature points are logged for every `ARFrame`. | Decided (user) |
| L3 | **Recall is judged by eye in v1.** No ground truth and no metrics beyond per-frame counts. | Decided (user) |
| L4 | **One file:** this `SPEC.md` holds the spec, the plan and the tasks. | Decided (user) |
| L5 | A session is a **folder bundle**: `session.sqlite` (per-frame data) plus `video.mov`. | Decided (user, 2026-09-28): "SQLite works everywhere" |
| L6 | The Python core depends only on **numpy and the standard library**, so it loads inside Blender with no extra installs. Internal data and config use frozen dataclasses, not Pydantic. | Decided (user, 2026-09-28, §16 Q2) |
| L7 | **Blender is the main interface.** Every CLI command also has a Blender operator. Recompute runs the CLI in a separate process with Blender's own Python (§6). The CLI stays for scripting. | Decided (user, 2026-09-28), including how Recompute runs |
| L8 | **Settings live in one place and are saved with the data.** Recorder settings live in `Constants.swift` (edit, rebuild) and are written to `meta` in every session. Lab settings live in TOML and are written into each run's `results.sqlite`. | Decided (user, 2026-09-28) |
| L9 | **First-launch permissions: Camera and Location.** GPS fixes and compass heading are logged in the session (§3.3, §4). | Decided (user, 2026-09-28) |
| L10 | **E1 moves to a second site.** The `BUILDING_SAMPLE.png` building has no open ground for a 10–15 m standoff. | Decided (user, 2026-09-28) |
| L11 | **All recorder logic goes into the `PlaneKit` target** (records, SQLite writer, video writer, constants). No separate `SessionLog` target. | Decided (user, 2026-09-28, §16 Q3) |
| L12 | **The phone runs CurvSurf's accumulator live and records it** (amends L1). SidingsAR shows the growing averaged cloud while scanning, like CurvSurf's app, and writes it into the session (`cloud` table, schema v2), so Blender can show exactly what the phone had. Plane fitting and tracking stay on the Mac. | Decided (user, 2026-09-29: "Live cloud + record it", after "there are too few points … lets guarantee the iOS app have such thing") |

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
| E1 | *(Early data, 2026-09-29: outdoors on the iPhone 13 without LiDAR, sightings reached **15.9 m**. 0.9 % were past 10 m, and features averaged past 10 m spread by about 30 cm. So the range goes past the old ~10 m, but it's noisy there. The controlled test at a known standoff is still T25.)* **How far do the feature points reach outdoors?** CurvSurf's README says that around December 2025 the range of `rawFeaturePoints` grew from about 10 m to about 65 m. Apple hasn't documented this. The lab shows point-range percentiles per frame. | If it's true, feature points cover the 8–15 m facade standoff (CONSOLIDATION §4). That changes what non-LiDAR phones can do. |
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
4. **It's the first session to record.** Record this building with the SidingsAR recorder from under 5 m to reproduce this result, then compare in Blender how long ARKit and our pipeline each take to get the upper points and planes (E2). A 10–15 m standoff isn't possible here because there's no open ground in front of it (user, 2026-09-28). **E1 needs a second site:** a building with an open standoff such as a street or parking lot, recorded from 10–15 m and farther (L10).

## 2. Capability map

The request bundles four parts that can be tested separately. They stay in this one file, but each keeps a stable id.

| Module id | Responsibility | Depends on |
|---|---|---|
| `session-format` | The on-disk contract between the phone and the Mac: bundle layout, tables, conventions, versioning (§3) | — |
| `recorder` | First-launch permissions, Record/Stop in SidingsAR, live writing (frames, video, location), finalizing, listing and sharing sessions (§4) | `session-format` |
| `lab-core` | Python: read sessions, accumulate points, fit planes, track planes, CLI, synthetic sessions (§5) | `session-format` |
| `blender-addon` | A Blender 5 extension and the main interface: every CLI command, import, timeline replay, layers, settings, Recompute (§6) | `lab-core` |

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

**Why SQLite** (decided, L5). It's a single file that's safe to append to while recording (WAL mode, committed in batches). A killed app loses at most the last uncommitted batch. It's built into iOS (`import SQLite3`) and into Blender's Python (`sqlite3`, SQLite 3.50.4 in Blender 5.0.1). Looking up a frame by index needs no parsing. Per-frame point arrays are stored as BLOBs, so there's **one row per frame**, not one row per point, and Python reads them with `numpy.frombuffer`.

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

### 3.3 Tables (schema version 2)

**`meta`** (`key TEXT PRIMARY KEY, value TEXT`):

| Key | Example |
|---|---|
| `schema_version` | `2` since L12 (adds `cloud`); `1` before. Readers open both. |
| `app_version`, `device_model`, `os_version` | `2.2`, `iPhone14,5`, `26.0` |
| `lidar` | `0` / `1` |
| `plane_detection`, `world_alignment` | `both`, `gravity` |
| `video_width`, `video_height`, `video_fps`, `video_codec`, `video_bitrate` | `1920`, `1440`, `60`, `hevc`, `8000000` |
| `arkit_format_fps`, `arkit_format_resolution` | `60`, `1920x1440`: the running configuration's `videoFormat`, as promised. The `frame.t` column shows what was delivered; T3 measured 30 Hz against 60 promised (§3.4, §15 R1). |
| `started_at`, `stopped_at` | ISO 8601 UTC |
| `stop_reason` | `user` / `reset` / `mode_change` / `pause` / `background` / `interruption` / `error` / `low_disk` (PlaneKit `StopReason`, T10) |
| `frames_logged`, `frames_with_image`, `frames_dropped` | counters written when the recording is finalized |
| `image_skip.<reason>` | Frames without an image, by reason, written at finalize (T10). `no_buffer`: the capture side had no free pool buffer, or the copy failed. Otherwise the encoder's reason (`notReady`, `outOfOrder`, `writerFailed`). Only reasons that occurred appear. |
| `location_auth`, `location_accuracy` | `when_in_use` / `denied` / `not_determined`; `full` / `reduced` (the user can grant approximate location only) |
| `const.<name>` | One row per `RecorderConstants` property (§4 R14, §10), for example `const.commitIntervalS` = `0.5`. Written at Record, so a killed recording still has them. The `const.cloud*` rows are the averaged cloud's settings (P21). |
| `cloud_rows`, `cloud_points`, `cloud_frames_dropped` | Written at Stop (v2): rows in `cloud`, averaged points after the last one, and recorded frames the phone's cloud never saw because its queue fell behind (0 expected). |

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

**`location`**, one row per Core Location fix (about 1 Hz; empty when location is denied):

| Column | Type | Content |
|---|---|---|
| `frame_idx` | INTEGER | Last logged frame when the fix arrived, like `plane_anchor` |
| `utc` | REAL | `CLLocation.timestamp`, seconds since 1970. For reference only; `frame_idx` is the join key. |
| `lat`, `lon` | REAL | Degrees, WGS 84 |
| `alt_m`, `ellipsoidal_alt_m` | REAL | `altitude` (above sea level), `ellipsoidalAltitude` |
| `h_acc_m`, `v_acc_m` | REAL | `horizontalAccuracy`, `verticalAccuracy` |

**`heading`**, one row per compass update (1° filter):

| Column | Type | Content |
|---|---|---|
| `frame_idx` | INTEGER | Last logged frame when the update arrived |
| `true_deg`, `magnetic_deg` | REAL | `CLHeading.trueHeading` (−1 when invalid), `magneticHeading` |
| `acc_deg` | REAL | `headingAccuracy` |

Location is **site metadata, not geometry**: it identifies the recording site and, with the camera yaw from the same frames, gives each facade's compass direction. Nothing in the pipeline uses it for poses.

**`event`** (`frame_idx INTEGER, kind TEXT, detail TEXT`) logs:

| `kind` | `detail` | When |
|---|---|---|
| `record` | `start`, `stop:<stop_reason>` | Record and Stop. An interruption, going to the background, an error or low disk also stop, as `stop:<reason>` |
| `tracking` | `normal`, `not_available`, `limited`, `limited/<reason>` | The state at frame 0, then every change on its exact frame. Relocalization shows as `limited/relocalizing` (T10) |
| `image_skip` | `no_buffer` or an encoder reason | The first frame of each run of frames without an image (T10) |
| `mark` | `mark N` | The Mark button (§4 R11) |

In Blender these become timeline markers.

**`cloud`** (schema v2, L12, P23): the phone's averaged cloud, one row every `cloudSnapshotEvery` (6) recorded frames and one at Stop. Record clears the cloud, so it starts empty at frame 0 (P22).

| Column | Type | Content |
|---|---|---|
| `frame_idx` | INTEGER PK | The row describes the cloud after this frame |
| `full` | INTEGER | 1: the whole cloud (the first row and every `cloudFullEvery`-th, 50). 0: the changes since the previous row |
| `removed_ids` | BLOB 8·R B | u64 ids to remove first (evicted), empty in a full row |
| `ids` | BLOB 8·K B | u64 ids to set (new or updated averaged points; every id in a full row) |
| `points` | BLOB 12·K B | K × 3 f32, averaged positions, world |
| `samples` | BLOB 2·K B | K × u16, samples in each id's FIFO |

### 3.4 Video

- `video.mov`: HEVC, at the captured-image resolution (typically 1920 × 1440), in landscape sensor orientation, with no rotation metadata.
- The video frame for log frame `idx` has presentation time `idx / video_fps`. A frame without an image leaves a gap in the timestamps and has `has_image = 0`, so video time always maps back to `idx`.
- **`video_fps` is a time base, not the capture rate.** ARKit can deliver fewer frames than its format promises: T3 measured 30 Hz against a promised 60 at thermal `serious`, while T7 got 60 Hz at `fair`. Video time still counts log frames, so the movie can play faster than real time in QuickTime. Blender maps clip frames one to one with timeline frames (T2) and takes its playback rate from `frame.t` (§6).
- A keyframe at least every 0.5 s of images (30 at 60 fps), so reaching any frame decodes at most 30 images and seeking in Blender stays fast. The encoder counts images, not time, so skipped images stretch the gap in time (T1: 0.67 s around a 10-frame hole).
- When the first image isn't log frame 0, `AVAssetWriter` keeps the gap as an empty edit at the start of the track. FFmpeg applies it (the stream's `start_time` is the gap), but `AVAssetReaderTrackOutput` reports media time without it (T1, 2026-09-28). **Blender drops it** (T2), so the importer places the clip at the first log frame with an image (§6, §15 R2).
- Written as a fragmented movie (`movieFragmentInterval` ≈ 1 s), so a killed recording still plays up to its last fragment.

### 3.5 Versioning

Any change to the tables or conventions bumps `schema_version`. Readers refuse versions they don't know, with a clear message. **Version 2** (2026-09-29, L12) adds `cloud` and the `cloud_*` meta rows; readers on both sides open versions 1 and 2, and `session-format/fixtures/v1/` stays to prove it. Contract fixtures in `session-format/fixtures/` cover every table, including `location`, `heading` and the `const.*` rows, and are checked by both the Swift tests and the Python tests.

## 4. Recorder (`recorder`, in SidingsAR)

| # | Requirement |
|---|---|
| R1 | A **Record/Stop** button in the HUD. |
| R2 | While recording, the HUD shows elapsed time, frames logged, images dropped, MB written and free disk space. |
| R3 | Recording runs **alongside** the current plane viewer, and everything it does today keeps working. These stop and finalize a recording first, and log the reason: Reset, a detection-mode change, a session interruption, going to the background, or a session error. |
| R4 | **Capture path.** Inside `session(_:didUpdate frame:)`, copy the pose, intrinsics, points and ids into a `FrameRecord`. Copy `capturedImage` into a small pixel-buffer pool the recorder owns (6 buffers since T10, allocated when Record is tapped). Hand both to background writers. **Never retain the `ARFrame` or ARKit's pixel buffer.** If no pool buffer is free, or the video input isn't ready, skip the image (`has_image = 0`) but keep the metadata. |
| R5 | **Write path.** SQLite runs on its own serial queue in WAL mode, with one transaction about every 0.5 s. The queue is bounded. If it ever fills, whole frames are dropped and counted. The delegate is never blocked. |
| R6 | **Stop:** finish the video, commit, write the final `meta` rows, close. |
| R7 | **Sessions sheet:** a list of recordings (date, duration, size, device), with **Share** (zipped with `NSFileCoordinator`'s `.forUploading`, so no dependency) and **Delete**. |
| R8 | Sessions live in `Documents/Sessions/` and are visible in the Files app and in Finder's device view (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`). `UIFileSharingEnabled` has to come from `SidingsAR-Info.plist`, because Xcode's generated Info.plist ignores its build-setting key (T3). |
| R9 | Recording stops by itself when free space drops below 1 GB (`stop_reason = low_disk`). |
| R10 | **Memory stays flat** while recording, because every buffer and queue is bounded. It's checked with the existing *mem MB* readout. |
| R11 | *(Should)* A **Mark** button adds an `event` row. Use it to note things like "wall A starts here". |
| R12 | **First launch: a permissions screen** (L9). It asks for **Camera**, then **Location While In Use**. Each has a row showing its status, and an **Open Settings** button appears when one is denied, because iOS shows each system prompt only once. The screen comes back at launch while anything is still undecided. |
| R13 | **Nothing else is requested.** Files access needs no prompt (R8 is Info.plist keys only). The video has no audio track, sessions don't go to Photos, raw motion data is out of scope (§14), and there's no network. Recording works with Location denied: the tables stay empty and `meta` says so. |
| R14 | **Constants** (L8). Every recorder setting (video fps, bitrate, keyframe and fragment intervals, commit interval, queue and pool sizes, low-disk threshold, location and heading filters) lives in `RecorderConstants` in `Constants.swift`. To change one, edit and rebuild. Every value is written to `meta` as `const.<name>` when Record is tapped. |
| R15 | **Location logging.** While recording, `CLLocationManager` fixes (best accuracy, no distance filter) and heading updates (1° filter) go to `location` and `heading` through the same bounded writer queue. They start at Record and stop with it. |

**Estimated size:** about 100 MB per minute (roughly 60 MB of video at 8 Mbps plus about 35 MB of feature points at 60 Hz). Location adds a few KB. To be measured.

**Where the code goes** (L11: "get everything into PlaneKit, it's a disposable POC"):
- **In the `PlaneKit` target:** `RecorderConstants` (`Constants.swift`), record types (frame, anchor, location, heading), BLOB packing, the schema, the SQLite writer, the drop policy, and the **`AVAssetWriter` video writer**. AVFoundation and SQLite3 also exist on macOS, so `swift test` checks the whole write path on the Mac, including HEVC output with gaps and a file whose writer never finished (S3). This ends PlaneKit's "simd and Foundation only" rule; `ARKit_WallDetection/CLAUDE.md` gets updated when the code lands.
- **In `SidingsAR/Recording/`, only what needs ARKit or UIKit:** `ARFrame` → `FrameRecord` and `ARPlaneAnchor` → anchor record mapping, the `CLLocationManager` delegate, the permissions screen and the Sessions sheet.

## 5. Lab core (`lab-core`, Python)

### 5.1 Pipeline

The pipeline runs over the whole session in order. It's deterministic for a given config and seed.

| Stage | What it does | Starting defaults |
|---|---|---|
| 1. Load | Frames, poses, points, ids, ARKit plane events, session events | — |
| 2. Point filter | Drop points closer than `near_cut_m` to the camera; optionally drop far points and frames without `normal` tracking | 0.25 m (CurvSurf) |
| 3. Motion gate | Decides which samples reach the accumulator. Modes: **`off`** (every frame); **`intended`** (a frame counts only if the camera moved ≥ `gate_move_m` or turned ≥ `gate_turn_deg` since the last accepted frame); **`upstream`** (the inverted gate, §1); **`parallax`** (per feature: a new sample counts once the direction from the camera to that point has turned ≥ `gate_parallax_deg` since that feature's last sample). See *Why gate at all* below. | Mode `off` (decided, §16 Q6); 3 cm, 3° (CurvSurf) for `intended`; 1° for `parallax` |
| 4. Accumulator | Per feature id: a FIFO of up to `max_samples`, samples beyond `zscore` σ from the mean dropped, and the point placed at the mean of the rest once there are `min_samples`. The cloud keeps up to `max_ids` ids, evicting the oldest first. Also records each point's sample count and spread. | 100, 2.0, 5, 100 000 (CurvSurf) |
| 5. Plane fit | Every `fit_every` frames: sequential RANSAC on the averaged cloud, then a least-squares refit on the inliers. Models: **vertical** (normal ⟂ gravity, 2-point sample), **horizontal** (normal ∥ gravity, 1-point), **free** (3-point, off by default). The inlier distance can grow with range (`τ = τ₀ + k·z²`) because point depth noise grows with distance. A hypothesis is rejected when its inliers are nearly collinear (an edge seen alone). Points within `edge_keep_m` of an accepted plane's boundary stay available for the next search, so the second wall at a corner keeps its support. Extent = the convex hull of the inliers on the plane, split into connected regions so two separate stretches of the same plane don't merge. See `BUILDING_SAMPLE.png` in §1. | `fit_every` 6 (10 Hz), τ₀ 3 cm, `min_inliers` 30, `min_spread_m` 0.3, `edge_keep_m` 0.1. Starting values, to tune. |
| 6. Plane tracker | Keeps planes across fits, like ARKit anchors: see §5.2. | Merge terms taken from PlaneKit NMS: 10°, 8 cm, 0.3 overlap |
| 7. Results | Written to `lab/<run>/results.sqlite`, with every `LabConfig` value in its `config` table (L8) and a copy of `config.toml` next to it. Stored so that any frame can be shown without recomputing. | — |

**Why gate at all** (user question, 2026-09-28: "why 3 cm, why not every frame?"). The gate isn't there to save compute. Averaging only removes noise that differs from sample to sample, and two frames 16 ms apart from the same spot give nearly the same VIO estimate. Without a gate at 60 Hz:
- `min_samples = 5` is reached in 83 ms, so "averaged" means almost nothing.
- The 100-sample FIFO spans only 1.7 s, so standing still for 2 s replaces every sample taken from another viewpoint.

With a gate, 100 samples means 100 viewpoints. But 3 cm ignores range: it gives 1.7° of parallax on a point 1 m away and only 0.17° at 10 m. For facades at 8–15 m it's too small to matter, not too large. The `parallax` mode gates on that angle per point instead. Every frame is also a real candidate: the upstream gate is inverted, so at walking speed (about 1.7 cm per frame) it accepts almost every frame, and `BUILDING_SAMPLE.png` was made that way. The lab can run all four modes on the same session, so which one to use is part of E3.

**Measured on the user's four recordings (T16, 2026-09-29; three indoors, one outdoors):**
- **`upstream` gives exactly the same cloud as `off`** in every recording: a hand-held phone at 60 Hz never moves 3 cm between frames, so CurvSurf's gate as coded passes every frame.
- **`intended` (3 cm or 3°) averages 10–23 % fewer points,** with about 10–15 samples each instead of 60.
- **`parallax` (1°) averages the fewest.**
- **Spread** (the RMS of kept samples around each average) stays about 1 cm in every mode indoors. The recording from 48 s indoors: `off` 12,102 averaged points, `intended` 10,852, `parallax` 10,320.
- **Outdoors** (`20260929-075854`, 51 s, points out to 15.9 m):
  - `off` 4,797 averaged points, `intended` 4,392, `parallax` only 2,225, because a 1° parallax is rarely reached at range.
  - Median spread is about 3.7 cm, since the farther points are noisier.

### 5.2 Plane tracker (stage 6)

- **Match:** each new fit is matched to an existing plane by normal angle, plane distance and overlap, the same terms PlaneKit uses for NMS.
- **Update:** pose and extent are updated by EMA or by a refit over recent inliers.
- **Lifecycle:** a plane is *tentative* until it has been matched `confirm_hits` times, then *confirmed*. Confirmed planes that overlap on the same plane **merge**; the older id survives, the way ARKit reports a merge with `didRemove`. A plane that isn't seen for a long time goes *stale* but isn't deleted, since ARKit also keeps its anchors.
- **Events:** `add` / `update` / `merge` / `stale`, so the logic ports to the phone later as a delegate-style API.

### 5.3 Settings that trade toward recall

| Setting | Toward recall | Cost |
|---|---|---|
| `min_samples` ↓ | Points show up sooner | Noisier points (needle-shaped error along the view ray) |
| Gate `off` | Points reach `min_samples` sooner | The average is dominated by wherever you stood longest |
| `min_inliers` ↓ | Planes from less support | More false planes |
| `min_spread_m` ↓ | Planes from thin strips, such as one trim band | More planes fitted to a single edge |
| `tau0` ↑, range scaling on | Far walls get support | Nearby surfaces bleed into each other |
| Vertical/horizontal prior on | Fewer points needed per hypothesis | Misses slanted surfaces (acceptable for siding) |
| `confirm_hits` ↓ | Planes are shown sooner | More short-lived planes |
| Merge distance ↑ | Fewer duplicates | Hides recessed doors and windows 3–10 cm deep (CLAUDE.md domain note) |

All settings live in one frozen `LabConfig` (`planelab.config`), with sections `filter`, `gate`, `accumulate`, `fit` and `track`, 29 settings in all. It's loaded from TOML, and a file may list only what it changes. Presets go in `PlaneLab/configs/`: `default.toml` has every setting with a comment and is tested equal to the code, and `recall.toml` lists only its overrides.

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
python -m planelab run   <bundle> --config configs/recall.toml --name recall-01 [--progress]
python -m planelab synth <out.planelab> --scene facade --seed 7   # synthetic session, no video; scenes: facade, edges, room
python -m planelab export <bundle> --run recall-01 --csv out.csv  # per-frame readouts
python -m planelab peek  <bundle> [--csv frames.csv]          # readable copy: every BLOB decoded, every column explained
python -m planelab blend <bundle>                             # ready-to-open <bundle>/lab/replay.blend (runs Blender headless)
```

`--progress` prints one JSON line per step (`{"frame": 1200, "of": 7200}`). Blender's Recompute reads it (§6).

## 6. Blender add-on (`blender-addon`)

**Blender is the main interface (L7).** Every CLI command has a Blender operator, so a whole session of work happens in Blender:

| CLI | In Blender |
|---|---|
| `info` | Session info in the panel, filled on import |
| `run` | **Recompute** |
| `synth` | *File › New › Plane Lab Synthetic Session* (scene, seed) |
| `export` | **Export CSV** in the panel |
| `peek` | *(Should)* **Write readable copy** in the panel (P15) |
| `blend` | Not needed inside Blender: it's the import itself, saved to a file (P16) |
| — | *(Should)* a session browser for the sessions folder (set in the add-on preferences; default `~/PlaneLab/sessions/`) and a run picker |

Operators are thin: each calls one core function, so the CLI and Blender can't drift apart.

- **Packaging:** a Blender 5.0+ extension (`blender_manifest.toml`) with no bundled wheels. numpy 1.26.4 and `sqlite3` come with Blender 5.0.1 (checked 2026-09-25). The core has no `bpy` import and ships inside the extension's zip.
- **Import:** *File › Import › Plane Lab Session*. It accepts a `.planelab` folder or its `.zip`; a zip is extracted to a cache folder. It then:
  - sets the scene fps to the delivered rate: the median frame interval in `frame.t`, rounded (30 or 60 on an iPhone 13). It isn't `video_fps`, which only counts frames (§3.4).
  - sets the frame range to `1 … frames_logged`
  - applies the ARKit → Blender axis conversion (§3.2)
- **What it builds,** in one collection per session:
  - **Camera:** keyframed pose per frame; focal length and shift from the intrinsics; resolution from the image size. **The video is its background image** (a movie clip), so looking through the camera shows the frame with our points and planes on top. The clip starts at timeline frame `1 + <first log frame with has_image = 1>`, because Blender drops a leading gap in the video but keeps later ones (§15 R2).
  - **Camera trail:** a static polyline.
  - **Layers** that follow the current frame:
    - raw points
    - averaged cloud (colored by sample count)
    - **our planes** (colored by track id; tentative planes lighter, stale ones grey; label with id, age, inliers and RMS)
    - **ARKit's planes** (SidingsAR colors: cyan wall, green floor, and so on)

    A frame-change handler updates these meshes from cached arrays. Only the camera is keyframed.
  - **Timeline markers** from `event` rows.
- **Panel** (*3D View › Sidebar › Plane Lab*):
  - session info, including the site (lat/lon, accuracy) when location was logged
  - layer toggles
  - the per-frame readouts (§5.4)
  - every `LabConfig` setting, with load and save as TOML (the same files the CLI reads)
  - **Recompute:** runs the pipeline with a progress bar and a Cancel button, without freezing Blender, and stores the output as a named run
  - **Export CSV** of the per-frame readouts
  - *(Should)* a run picker to switch between runs and compare them

**How Recompute runs** (decided with L7). It starts the CLI as a **separate process with Blender's own Python**: `sys.executable -m planelab run <bundle> --config <tmp>.toml --name <run> --progress`. In Blender 5.0.1, `sys.executable` is `…/Blender.app/Contents/Resources/5.0/python/bin/python3.11`, and it runs on its own with numpy 1.26.4 and `tomllib` (checked 2026-09-28). A modal timer operator reads the progress lines, and Cancel ends the process. Compared with a thread inside Blender:
- The UI stays smooth. RANSAC's Python loops would otherwise hold the interpreter lock that Blender's panels and frame handler also need.
- Cancel is immediate and needs no checks inside the core.
- A crash in the core can't take Blender down.
- Several runs can go at once on the Mac Studio's 12 cores, which makes E3 setting sweeps cheap.

Import, scrubbing and Export CSV stay in-process: they need `bpy` or are fast. Results come back through `results.sqlite`, so no data crosses the process boundary.

**Dev loop.** The extension's source folder is linked into a local extension repository, so a code change loads with *Reload Scripts* instead of a zip rebuild and reinstall. The zip is only for the headless tests and for handing over.

## 7. Tech stack

| Part | Stack |
|---|---|
| iOS | Swift 6, Xcode 26.3, iOS 18, ARKit + RealityKit (existing), AVFoundation `AVAssetWriter` (HEVC), system `SQLite3`, CoreLocation, `os.Logger`. No new third-party packages. |
| Python core | Python **3.11**, the same as Blender 5.0.1's bundled 3.11.13. **numpy 1.26.4**, pinned to Blender's version. Standard library: `sqlite3`, `tomllib`, `zipfile`, `logging`, `dataclasses`. |
| Python dev | `virtualenv` `.venv`, pytest, pytest-cov, ruff, all pinned in `requirements.txt` |
| Blender | 5.0.1, extension format (`blender --command extension build`) |

## 8. Commands

```bash
# iOS (unchanged; the recording tests run inside PlaneKit's swift test)
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
./scripts/build_extension.sh        # stages the extension plus a real copy of the core (§17.4 P6), then runs `extension build` into dist/
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
│   ├── SidingsAR/Recording/             ARRecordAdapter, SessionRecorder, LocationFeed, PermissionsView, SessionsView (glue only)
│   └── PlaneKit/
│       ├── Sources/PlaneKit/Recording/  Constants.swift, records, packing, schema, SQLite writer, drop policy, VideoWriter
│       └── Tests/PlaneKitTests/Recording/
└── PlaneLab/                            new
    ├── requirements.txt / pyproject.toml
    ├── src/planelab/                    core, no bpy: session, schema, config, gate, accumulate, fit, search, track, pipeline, results, synth, cli
    ├── blender/planelab_blender/        extension: manifest, operators, panel, frame handler; vendor/planelab links to the core (§17.4 P6)
    ├── scripts/build_extension.sh       stages the extension with a real copy of the core, then builds the zip
    ├── spikes/                          R1 and R2 spike scripts and notes (kept on disk)
    ├── configs/                         default.toml, recall.toml
    └── tests/                           pytest suites; tests/blender/ for headless Blender smoke tests
```

Recordings stay **out of git**: `*.planelab` goes in `.gitignore`. They are large, and they contain video of houses, possibly people, and the site's GPS position. On the Mac, keep them under `~/PlaneLab/sessions/`.

## 10. Code style

Swift follows the existing SidingsAR rules: value types and writers in `PlaneKit`, glue in the app, `os.Logger`, no `print`.

```swift
/// Every recorder setting in one place (L8). Edit and rebuild; each recording stores them in `meta` as `const.<name>`.
public struct RecorderConstants: Sendable {
    public var videoFPS = 60
    public var videoBitrate = 8_000_000
    public var keyframeIntervalS = 0.5
    public var commitIntervalS = 0.5
    public var pixelPoolSize = 6
    public var lowDiskBytes: Int64 = 1_000_000_000
    public var headingFilterDeg = 1.0

    public static let current = RecorderConstants()

    /// One `meta` row per stored property, read by reflection so a new constant can't be left out.
    public var metaRows: [(key: String, value: String)] {
        Mirror(reflecting: self).children.compactMap { child in
            child.label.map { ("const.\($0)", "\(child.value)") }
        }
    }
}
```

Tests build a modified copy (for example `pixelPoolSize = 1` to force image drops) instead of changing the file.

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
class FitConfig:  # planelab.config: one section of LabConfig; __post_init__ checks every value
    fit_every: int = 6
    tau0_m: float = 0.03
    tau_range_k: float = 0.0
    min_inliers: int = 30
    vertical: bool = True
    horizontal: bool = True
    free: bool = False
    # ... see PlaneLab/configs/default.toml for every setting


def fit_vertical_plane(
    points: npt.NDArray[np.float32], cfg: FitConfig, rng: np.random.Generator
) -> PlaneFit | None:
    """2-point RANSAC for planes whose normal is perpendicular to gravity (+Y in ARKit world)."""
```

## 11. Testing strategy

| Level | What | Where |
|---|---|---|
| Swift unit (Mac) | Recording in `PlaneKit`: packing round-trip, schema, batched commits, drop policy under backpressure, reading a writer that was never closed (crash consistency), every constant in `meta`, location and heading rows, contract fixtures. Video writer with synthetic pixel buffers: HEVC output, timestamp gaps for skipped images, and a file that still plays when the writer never finished. | `PlaneKit/Tests/PlaneKitTests/Recording/` |
| Python unit | Reader (contract fixtures, synthetic bundles, zip input, unknown version refused); accumulator (CurvSurf semantics on hand-built cases, all four gate modes); run config stored in `results.sqlite`; `--progress` output; RANSAC (planted planes with noise and outliers; normal and offset error bounds; the priors); tracker (stable ids under jitter, merge, stale, no id flips); pipeline determinism; CLI smoke | `PlaneLab/tests/` |
| Contract | The same fixtures decoded by Swift and by Python must give the same values | `session-format/fixtures/` |
| Blender, headless | Drive every operator through `bpy.ops.planelab.*`: create a synthetic session, import it, Recompute (as a separate process) and wait for it, export CSV. Check the objects, frame range, camera keys and layer vertex counts at chosen frames | `PlaneLab/tests/blender/` |
| Device (user) | The recorder checkpoints in §13. Never reported as done unless the user saw them. | — |

- Coverage floor: **85 %** on `src/planelab`. Blender glue is covered by the headless tests instead.
- Tests stay on disk.

## 12. Boundaries

**Always**
- Keep the SidingsAR invariants: never retain `ARFrame`s, anchor callbacks only record, one clock (`ARFrame.timestamp`).
- `idx` is the only join key.
- Raw recordings are immutable, and results go under `lab/`.
- The core stays `bpy`-free and numpy-only.
- Every CLI command has a Blender operator, and both call the same core function.
- Recorder settings live only in `RecorderConstants`, and every one is written to `meta`.
- `swift test`, `pytest` and `ruff` pass before a commit.
- Update this spec when a decision changes. Bump `schema_version` on any format change.

**Ask first**
- Any new dependency: a Swift package, a Python package beyond numpy in the core, or wheels in the extension.
- Changing the schema once real recordings exist.
- Installing on a device.
- Asking for any iOS permission beyond Camera and Location While In Use.
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
| S5 | After a fresh install, the first launch asks for Camera, then Location, and shows each one's status. With Location denied, recording still works and `meta` says `denied`. With it granted, a session has `location` rows at about 1 Hz and `heading` rows. Every `RecorderConstants` value is in `meta`. |
| S6 | `swift test` is green with the new recording tests, including the video writer. The `xcodebuild` compile check has no new warnings. |

**Format and core** (automated on the Mac):

| # | Criterion |
|---|---|
| S7 | Swift and Python both pass the contract fixtures, including `location`, `heading` and `const.*`. An unknown `schema_version` is refused with a clear message. |
| S8 | On synthetic sessions with σ = 1 cm noise and 20 % outliers, every planted plane is found with normal error < 2° and offset error < 2 cm, and the tracker keeps **one id per planted plane with no id switches**. This includes an **`edges` scene** where points exist only on corners, trim and openings, as in `BUILDING_SAMPLE.png`: both walls at a shared corner are found, and no plane is fitted to a single edge. |
| S9 | `planelab run` finishes a 2-minute session in < 60 s on the Mac Studio. Its `results.sqlite` holds the full config. Pytest coverage is ≥ 85 %. |

**Blender:**

| # | Criterion |
|---|---|
| S10 | Everything the CLI does can be done from the Blender UI: create a synthetic session, import, session info, Recompute, export CSV. The headless test drives all of them through `bpy.ops.planelab.*`. |
| S11 | A real session imports in < 30 s. Looking through the camera, the raw points sit on the matching image features across the whole timeline, which shows that video, pose and intrinsics are aligned. |
| S12 | Scrubbing to any frame updates every layer in ≤ 100 ms. |
| S13 | Change a setting and press Recompute: the run happens in a separate process, the UI stays responsive, Cancel stops it within 1 s, and the new run shows up without restarting Blender. |
| S14 | By eye, on the `BUILDING_SAMPLE.png` building recorded from under 5 m, you can say for each wall whether our planes appear sooner or later than ARKit's (E2) and see the upper-storey points (8–10 m up). On the second site recorded from 10–15 m and farther, you can read point-range percentiles (E1). |

**Docs:** `ARKit_WallDetection/README.md` (the recorder), `PlaneLab/README.md` (new), the root `README.md` and `CLAUDE.md`, and `CONSOLIDATION.md` §10b (the E1/E2 findings) are updated.

## 14. Out of scope for v1 (candidates for later)

- Our own fitting on the phone, with our planes shown in AR. This is the port after the lab picks a config (L1).
- LiDAR depth recording, and using LiDAR as a reference.
- Ground truth, hand-marked walls, and recall/precision metrics (L3).
- Segmentation (YOLOv8-seg), monocular depth, raw IMU from CoreMotion (CONSOLIDATION §5 and §4).
- Replaying a recording back into ARKit on the phone.
- Using location for tracking (`ARGeoTrackingConfiguration`) or `.gravityAndHeading` world alignment. Location is only logged (L9).
- Other iOS permissions: microphone, Photos, Motion & Fitness, Local Network (§4 R13).
- Android, and the FindSurface SDK.

## 15. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | HEVC at 1440p60 plus feature-point logging overloads the iPhone 13: dropped images, heat, worse tracking | **Answered by T3 (2026-09-28), closed by the user; re-checked at Checkpoint 2A.** Two runs on the iPhone 13 (96 s and 69 s, phone charging): copying on the main thread costs p95 < 1 ms, 0.15 % of images were dropped (pool only, never the encoder), and there was no stutter. ARKit's format promised **60 fps but delivered a flat 30.0 Hz** from the first second, with thermal state already `serious`, most likely ARKit halving the camera rate under heat. **T7 backs this up:** with the real recorder at thermal `fair`, it delivered a steady 60 Hz for 48 s with 0 frames dropped. **Decision:** keep a full-resolution image for every delivered frame (no P5 fallback). Keep video time as `idx / video_fps`, a frame counter. Blender plays at the rate measured from `frame.t` (§3.4, §6). Memory rose 300 → 443 MB in 68 s, in steps; whether that's the viewer or the recording is measured at Checkpoint 2A. |
| R2 | Blender's movie clips mishandle timestamp gaps or seek slowly in HEVC, so video and timeline drift | **Answered by T2 (2026-09-28).** Blender 5.0.1 (MovieClip through the compositor, and sequencer strips, default timecode) **drops a leading gap**: the first image lands on the clip's first frame. **Gaps later in the file are kept**: frames inside a gap hold the previous image. **Fix, in the importer:** `clip.frame_start = 1 + <first log frame with has_image = 1>`. That gave 0 mismatches over 72 sampled frames, including every frame right after a gap. Random access costs about 50 ms of decoding per frame, the same as in-order access (keyframes ≤ 30 images apart), so no proxies or timecode index are needed. |
| R3 | Too much memory to show any frame's averaged cloud (it can reach tens of thousands of points, across thousands of frames) | Snapshots only at the fit cadence, stored as changes since the last snapshot, with periodic full snapshots. Measured against S12. **Implemented early (P19, 2026-09-29)** in `planelab.cloud`: a snapshot every 6 frames, a full copy every 50 snapshots. On `20260929-161400` (2,669 frames, 5,735 averaged points at the end) it builds in 1.8 s, caches 2.0 MB, rebuilds any frame in 0.2 ms, and a Blender frame change takes < 3 ms. |
| R4 | Pure Python is too slow | Vectorized numpy, fitting every N frames, subsampling. Measured against S9. |
| R5 | Relocalization shifts the world frame mid-session, so poses and points jump | Logged as events and shown as markers. The lab shows the jumps rather than hiding them. Anchor-relative storage (CONSOLIDATION §4) is a product concern, not a concern for this raw log. |
| R6 | ARKit anchor callbacks aren't tied to a frame | Stamped with the last logged frame (±1 frame at 60 Hz). Fine for viewing by eye. |
| R7 | GPS is off by 5–20 m next to buildings, and the compass is thrown off by cars and steel | Accuracy is logged with every fix and heading. Location is used only to identify the site and give a rough facade direction, never for geometry. |
| R8 | Recompute depends on Blender's bundled Python binary, whose path changes between Blender versions | Always use `sys.executable` at runtime, never a hard-coded path. The headless test runs Recompute for real. |

## 16. Open questions

All closed. The user accepted every remaining default on 2026-09-28 ("Everything seems fine").

1. **Keep recording ARKit's plane anchors?** You chose visual checks only. I kept them because they're cheap (the app already receives them), and seeing them next to ours is the visual comparison for E2. **Decided: keep.**
2. ~~**Pydantic.**~~ **Decided (L6):** frozen dataclasses with explicit validation for the session reader and the TOML config. No Pydantic, because Blender's Python doesn't ship it.
3. ~~**Where `SessionLog` lives.**~~ **Decided (L11):** everything goes into the `PlaneKit` target, including the video writer and `Constants.swift`.
4. **Names:** "Plane Lab", the `.planelab` bundle and the `planelab` package. **Decided: as written.**
5. **Session length and devices:** **Decided: up to 10 minutes. iPhone 13 first, 13 Pro second.**
6. **Default motion gate.** You asked why 3 cm, and why not every frame (see *Why gate at all*, §5.1). **Decided: `off` (every frame), with `intended`, `upstream` and `parallax` kept for comparison in E3.** Any mode can be picked per run from the Blender panel with no rebuild, so the default only sets where tuning starts.

## 17. Plan

*Drafted 2026-09-28 after the spec was approved. Approved by the user the same day.*

### 17.1 Approach

Three ideas set the order:

1. **Risks first.** R1 (the iPhone 13 can't encode video and log at 60 Hz) and R2 (Blender can't keep our video in step with the timeline) could each force a format change. Both need the video writer, so the writer comes first, tested on the Mac, and then the two spikes.
2. **One thin path end to end before going deep.** A tracer bullet takes a real iPhone recording (frames, poses, points, video) through the Python reader into Blender, and the user checks that the points sit on the image (S11). That proves the contract, the axis conversion and the video timing before any fitting code exists.
3. **Two tracks, then the UI.** After the tracer, the recorder (Swift, needs the phone) and the lab core (Python, Mac only) don't depend on each other. The lab core fills the time spent waiting for device checks. Blender comes last because it shows what both produce.

This refines §2's build order: the video writer moves ahead of the spikes, and a tracer bullet crosses all four modules before either track goes deep.

### 17.2 Dependency graph

```
T1 VideoWriter (PlaneKit, Mac)
 ├─ T2 spike R2: Blender video ─────────────────────────────────────────────┐
 ├─ T3 spike R1: iPhone 13 load (device) ──────────┐                        │
 └─ T4 schema v1, records, contract fixture        │                        │
     ├─ T5 SessionWriter ──────────────────────────┴─ T7 Record/Stop on the phone
     │                                                  ├─ T10 stop reasons, events, low disk
     │                                                  ├─ T11 ARKit anchors, Mark
     │                                                  ├─ T12 permissions, location
     │                                                  └─ T13 Sessions sheet
     └─ T6 Python reader, `info`
         ├─ T8 Blender import: camera, raw points ──────── T9 video behind the camera (needs T2, T7)
         ├─ T14 synth ─┐
         └─ T15 LabConfig ─┴─ T16 gate, accumulator ─┐
                        └─ T17 RANSAC ─ T18 search, extents ─ T19 tracker ─┴─ T20 pipeline, run, export
                                                                                 └─ T21 layers (needs T9) ─ T22 Recompute ─ T23 other operators
T24 field session 1 (E2, E3) and T25 field session 2 (E1) need Checkpoint 3. T26 docs runs alongside them.

T16 accumulator ─ T27 Swift accumulator (golden from Python) ─┬─ T28 live cloud in SidingsAR (device)
                                                              └─ T29 record it: schema v2 ─ T30 phone cloud in Blender
```

### 17.3 Phases

| Phase | Tasks | Where | Ends with |
|---|---|---|---|
| 0. Risks | T1–T3 | Mac, then iPhone 13 | Checkpoint 0: R1 and R2 answered |
| 1. Tracer bullet | T4–T9 | Mac, iPhone 13 | Checkpoint 1: S11 on a real recording |
| 2A. Recorder | T10–T13 | Mac, iPhone 13 and 13 Pro | Checkpoint 2A: S1–S6 |
| 2B. Lab core | T14–T20 | Mac | Checkpoint 2B: S7–S9 |
| 2C. Cloud on the phone (L12) | T27–T30 | Mac, iPhone 13 | Checkpoint 2C: the phone's cloud grows live and Blender shows the same cloud |
| 3. Blender | T21–T23 | Mac | Checkpoint 3: S10–S13 |
| 4. Field work and docs | T24–T26 | Outdoors, Mac | Final: S14, docs |

**Parallel work.** Track 2B needs only T6, so it can start as soon as the reader exists, including while T3 and T7 wait for device checks. Tracks 2A and 2B share only the schema, which T4 freezes.

### 17.4 Plan decisions (logged 2026-09-28)

Minor decisions made while planning, under the user's "minor decisions I trust you, just keep them logged". To change one, edit this table.

| # | Decision | Why |
|---|---|---|
| P1 | The plan and tasks live here (L4). `ARKit_WallDetection/tasks/` isn't touched; it still has 48 unticked items from earlier SidingsAR work. | L4, and never overwrite another plan |
| P2 | `session-format/schema_v1.sql` is the one source of the DDL. Swift and Python each embed a copy, and a test on each side checks that the copy matches the file exactly. | One contract, no drift, and the Blender zip stays self-contained |
| P3 | The contract fixture (`session-format/fixtures/v1/tiny.planelab`: 10 frames, every table, a 64 × 48 video) is written by the Swift writer when `PLANELAB_WRITE_FIXTURES=1`, committed, and checked by both sides against `expected.json`. | The real writer makes the fixture, so the contract tests the real thing |
| P4 | Test videos carry their frame number as a pattern of blocks, so a test can tell which frame is on screen. | Makes R2 and S11-style alignment checks automatic |
| P5 | The pixel pool is the writer adaptor's own pool, capped at `pixelPoolSize`; hitting the cap means "skip this image". If R1 fails, fall back in this order: an image every other frame (poses and points stay at 60 Hz), then a 1280 × 720 video format. | No extra pool code, and the fallbacks keep full-rate metadata |
| P6 | Python layout: the core in `PlaneLab/src/planelab/` (`pip install -e .` into `.venv`). The extension in `PlaneLab/blender/planelab_blender/` imports it from `vendor/planelab`, a symlink to the core for the dev loop. `scripts/build_extension.sh` copies the real files into a staging folder before `extension build`. Recompute's subprocess gets `PYTHONPATH=<extension>/vendor`. | One copy of the core, live edits in Blender, and a zip that works on its own |
| P7 | Synthetic sessions write the real schema through a small Python writer used only by `synth`. Their ground truth goes in `synth_truth.json` next to `session.sqlite`, not in the schema. | S8 needs truth; real sessions have none (L3) |
| P8 | Python logs go silently to `~/PlaneLab/logs/planelab.log` (rotating). The CLI also prints warnings to stderr, and Blender operators also use `self.report`. | Global logging rule |
| P9 | Spike scripts and notes stay in `PlaneLab/spikes/`. | Tests stay on disk |
| P10 | Pure recorder logic (stop-reason mapping, the low-disk rule, which permission screen to show, session summaries) goes in PlaneKit with tests. The app keeps only glue. | Testable on the Mac |
| P11 | Every device check asks before installing (§12). An iPhone 13 and a 13 Pro are paired with this Mac as of 2026-09-28. | CLAUDE.md |
| P12 | The results store keeps a full snapshot of the averaged cloud every 60 fits, with changes in between (R3). T20 measures this against S12 and adjusts it. *(P19 already does this for the Blender layer with 50; T20 can store the same arrays.)* | Starting point for R3 |
| P13 | ARKit → record conversions for the recorder live in one file, `SidingsAR/Recording/ARRecordAdapter.swift`. The SidingsAR rule "`PlaneAnchorAdapter` is the only place that converts ARKit types" becomes "`PlaneAnchorAdapter` (viewer) and `ARRecordAdapter` (recorder)". | Keeps the rule's intent: one place per consumer |
| P14 | **Commits** (user, 2026-09-28): one commit per task once its checks are green, with the attribution trailer, without asking each time. Never push, never commit recordings. | User's choice |
| P15 | **`planelab peek`** (user request, 2026-09-28: "a table on the sqlite file to peek the data, structured so I can catch all details"): it writes `<bundle>/lab/peek.sqlite` with every BLOB decoded into columns, enums as words, per-point and per-feature tables, and an `_about` table explaining every column (a test enforces that). It's a separate file because recordings are immutable (§3.2). | The user needs to see raw data before the Blender import exists |
| P16 | **`planelab blend`** (2026-09-28, after the user asked for the Blender file of a new recording): it runs Blender headless with `scripts/replay_blend.py` and saves `<bundle>/lab/replay.blend`, the import in an empty scene that opens in camera view. Blender comes from `--blender`, then `$BLENDER`, then the default app path. It works from a repository checkout. | A new recording goes to Blender in one command |
| P17 | **ARKit planes layer brought forward from T21** (2026-09-28, the user's "hold our horses"): the Blender import adds an *ARKit planes* mesh that the frame handler fills with every live anchor's boundary polygon, in SidingsAR's colors at 35 % opacity. `planelab.planes.PlaneTimeline` shows each anchor's latest add or update until its remove. T21 keeps the rest of its layers (averaged cloud, our planes, readouts). | The user wanted ARKit's planes next to the points now |
| P18 | **Missing images at startup** (T10, 2026-09-29): warm the pixel pool when the writer opens, and raise `pixelPoolSize` from 4 to 6 (about 9 MB more at 1440p). Record why each image is missing (`image_skip.*` in `meta`, and an `image_skip` event per burst). The Mac couldn't reproduce the losses, so the fix is a mitigation, and the counters from the next device recording confirm or redirect it. | Every recording lost frames 5–9; the cause couldn't be seen from the data |
| P19 | **Averaged-cloud layer brought forward from T21** (2026-09-29; the user compared `replay.blend` with CurvSurf's app and chose "Averaged cloud in Blender now"). `planelab.cloud.CloudTimeline` runs filter, gate and accumulator (default `LabConfig`) once over the recording and keeps a snapshot every 6 frames (10 Hz at 60 fps) as changes since the previous one, with a full copy every 50 snapshots (R3). It's cached as `<bundle>/lab/cloud-<hash>.npz`, keyed by the filter, gate and accumulate settings. The Blender import adds an *averaged cloud* object: the frame handler writes the cloud as it was at the current frame, with a `samples` attribute, and a geometry-nodes group splits it into three point clouds by samples in the FIFO: under 10 pale pink, 10–49 magenta, 50+ red. A point cloud carries a single material, so Set Material's selection is ignored there; each band is its own instance. | The user wanted to see what T14–T16 compute, the way CurvSurf's app shows it |
| P20 | **Screen-sized points and fill on open** (2026-09-29, the user "couldn't even see those points"). Raw and averaged points get radius = size × distance from the recorded camera (0.004 and 0.003, about 6 and 4.5 px of radius at a 1,500 px focal length), like CurvSurf's point sprites; a fixed 6 mm radius was under a pixel at 10 m. The size is a modifier input. Opening a `.blend` fills every layer for the current frame (before, layers stayed as saved until the first frame change). *Also found:* the Plane Lab extension was switched off in the user's Blender preferences, so no layer refreshed at all. | The cloud has to be visible at facade range |
| P21 | **Cloud settings are recorder constants** (L12, L8): `cloudNearCutM` 0.25, `cloudFarCutM` 0 (off), `cloudNormalTrackingOnly` false, `cloudGate` off, `cloudMoveM` 0.03, `cloudTurnDeg` 3, `cloudMaxSamples` 100, `cloudMinSamples` 5, `cloudZScore` 2, `cloudMaxIds` 100 000: the lab's defaults, which are CurvSurf's. They reach `meta` as `const.cloud*` like every constant, and the Mac rebuilds the same `LabConfig` from them to recompute and compare. The per-point parallax gate isn't ported (it isn't the default). | One set of numbers on both sides |
| P22 | **Record clears the cloud.** The recorded cloud starts empty at frame 0 and, while recording, only frames the writer accepted feed it, so the Mac's recompute from the same frames must give the same cloud. The live view keeps growing outside recordings; Reset clears it too. | The recording must be reproducible |
| P23 | **`cloud` rows** (schema v2): every `cloudSnapshotEvery` (6) recorded frames, the changes since the previous row by feature id (ids removed, then ids set with point and sample count), a full copy at the first row and every `cloudFullEvery` (50) rows, and a last row at Stop. Keyed by feature id, not by storage slot, so a reader needs no accumulator. Estimated 5–11 MB/min next to about 82 MB/min of recording; measured at Checkpoint 2C. | Same cadence as P19, so Blender shows it the same way |
| P24 | **Phone display:** one entity, three mesh parts (the Blender bands: under 10 samples pale pink, 10–49 magenta, 50+ red), each point a camera-facing quad sized by distance (CurvSurf draws ≥ 10 px sprites), rebuilt at 10 Hz on the frame tick through `DynamicMesh`. The accumulator runs on its own queue, never on the delegate. ARKit's yellow feature points keep their toggle. | Memory rules in `ARKit_WallDetection/CLAUDE.md` |
| P25 | **Accumulator memory:** 1.2 KB per live id (100 samples × 12 B), in chunks of 4,096 ids, so up to about 120 MB at CurvSurf's 100 000 ids. The cloud grows by design (an exception to R10's flat memory), bounded by `cloudMaxIds`; *mem MB* is read at Checkpoint 2C, and `cloudMaxIds` comes down if it hurts. | Fidelity to CurvSurf first, measured before changing it |
| P26 | **PlaneKit is built optimized in Debug** (`unsafeFlags(["-O"], .when(configuration: .debug))` in `Package.swift`). Xcode's Run installs Debug builds, and the accumulator runs on every frame: 3.2 ms per frame unoptimized against 0.055 ms optimized (Mac). Heat already halves ARKit's rate on the iPhone 13 (R1). The app target stays `-Onone`. Local packages may use unsafe flags; the iOS compile check passes. | Keep the cloud cheap on the phone |

### 17.5 Risks found while planning

These are in addition to §15.

| Risk | Impact | Mitigation |
|---|---|---|
| The image copy runs on the main actor, because the ARSession delegate queue is main: about 4.4 MB per frame, 265 MB/s at 60 Hz | The plane viewer stutters | R1 measures the copy time p95. Fallbacks: a GPU copy with `VTPixelTransferSession`, then P5 |
| `CVPixelBuffer` isn't `Sendable`, and the project builds with Swift 6 strict concurrency | Warnings, or an unsafe hand-off | One small `@unchecked Sendable` box owned by the recorder, used only to hand the buffer to the writer queue (T5) |
| A background Blender script may not be able to read a movie clip's pixels | T2 can't check alignment by itself | Render the frame through the sequencer and read the file; failing that, the user checks by eye |
| A 100-sample FIFO for 100 000 ids is about 120 MB as float32 | Slow or heavy in numpy | Preallocated ring buffers sized to the live ids, grown in chunks. Measured against S9 |
| Blender's extension guidelines discourage changing `sys.path` | None for a private add-on | Accepted; revisit only if it's ever published |
| The user can grant only approximate location | The site is known only to within a few km | Logged in `meta.location_accuracy`, and shown on the permissions screen |

### 17.6 Definition of done (every task)

A task is done when its own checks in §18 pass, and:
- **Swift tasks:** `swift test` is green and the `xcodebuild` compile check has no new warnings.
- **Python tasks:** `pytest --cov=planelab --cov-fail-under=85`, `ruff check .` and `ruff format --check .` pass.
- **Blender tasks:** the headless suite in `PlaneLab/tests/blender/` passes.
- New behavior has tests that fail without the change. Tests stay on disk.
- Docs change with the code: the README of the part touched, a `CLAUDE.md` when a rule changes, and this spec when a decision changes.
- Device and user checks stay unticked until the user reports them. Device results that weren't observed are never reported.
- It's committed on its own once green (P14).

## 18. Tasks

Tick a box only when its check has passed. Boxes marked **Device** or **User** are ticked only after the user reports the result.

### Phase 0: Risks

#### T1. Video writer in PlaneKit, tested on the Mac · M · S3, S6 (part)

`RecorderConstants` (`Constants.swift`) and a `VideoWriter` around `AVAssetWriter`: HEVC at the capture size, presentation time `idx / fps`, gaps for skipped images, a keyframe at least every `keyframeIntervalS`, a fragmented movie, and the adaptor's pool capped at `pixelPoolSize` (P5). Both spikes need it, so it comes first. `PLANELAB_SPIKE_OUT=<dir> swift test --filter spikeVideo` writes a 10 s, 1920 × 1440 video with gaps and frame-number blocks (P4) for T2. The PlaneKit import rule in `ARKit_WallDetection/CLAUDE.md` is updated here, since this is where the rule stops being true.

- [x] 120 synthetic frames with 10 skipped read back (`AVAssetReader`) as HEVC with exactly the expected presentation times.
- [x] With the pool full, `append` returns *skipped* at once instead of blocking.
- [x] A copy of the file taken mid-write, after at least two fragments, opens and holds the frames up to its last fragment.
- [x] `metaRows` lists every `RecorderConstants` property.
- **Verify:** `swift test`; `ffprobe` on the spike video shows `hevc` and keyframes ≤ 0.5 s apart.
- **Result (2026-09-28):** done. 46 tests pass, and the compile check is clean. `ffprobe` on the spike video: `hevc`, 1920 × 1440, 571 of 600 frames, `start_time` 0.05 s (the 3-frame leading gap is kept). Two findings, now in §3.4:
  - Keyframes are at most 30 *encoded images* apart; time gaps reach 0.67 s around skipped images.
  - A leading gap is stored as an empty edit, which FFmpeg applies and `AVAssetReaderTrackOutput` doesn't.

  The spike output is in `~/PlaneLab/spikes/r2/` (`spike.mov`, `spike_frames.json`).
- **Depends on:** nothing.
- **Files:** `PlaneKit/Sources/PlaneKit/Recording/Constants.swift`, `.../Recording/VideoWriter.swift`, `PlaneKit/Tests/PlaneKitTests/Recording/VideoWriterTests.swift`, `.../Recording/TestFrames.swift`, `ARKit_WallDetection/CLAUDE.md`

#### T2. Spike R2: Blender keeps our video in step · S · R2

A headless Blender script loads the T1 spike video as a movie clip. For at least 50 sampled frames, including the ones right after gaps, it checks that Blender frame `idx + 1` shows image `idx`. It tries timecode *None* and *Record Run*, and times random seeks. Then the user scrubs it in the Blender UI.

- [x] One setting gives 0 mismatches. It's recorded in §15 R2 with the seek times.
- [x] The median random seek is ≤ 100 ms, or the need for proxies is recorded.
- [x] If no setting works, a fallback is chosen and logged: the recorder repeats the last image for skipped frames, or the importer maps frames through a lookup. *(Not needed: placing the clip at the first image works.)*
- [x] **User:** scrubbing the clip in Blender looks right. *(Covered on 2026-09-28 by scrubbing the real recording in Blender during the S11 check: "everything seems right".)*
- **Verify:** `$BLENDER --background --factory-startup --python PlaneLab/spikes/r2_video_alignment.py -- <video> <manifest>`
- **Result (2026-09-28):** the automated part is done. Blender drops a leading gap and keeps later ones; the fix is `clip.frame_start = 1 + first image` (0 of 72 frames wrong on both the camera-background and the sequencer paths). Decoding is about 50 ms per random frame, with no proxies. Details are in §15 R2 and `PlaneLab/spikes/README.md`. The scrub file for the user check is `~/PlaneLab/spikes/r2/r2_scrub.blend`.
- **Depends on:** T1.
- **Files:** `PlaneLab/spikes/r2_video_alignment.py`, `PlaneLab/spikes/README.md`, `SPEC.md`

#### T3. Spike R1: HEVC 1440p60 on the iPhone 13 · M · R1

Minimal glue behind a temporary HUD toggle, *Rec video*. Inside the frame delegate, each `ARFrame`'s `capturedImage` is copied into the writer's pool, then appended on the writer queue. The frame is never retained. The HUD shows images written and dropped, the copy time p95 and the thermal state, and the same numbers go to `r1-summary.json` next to the video in `Documents/Spikes/`. Adds the file-sharing Info.plist keys (§4 R8) so the files show up in Finder.

- [x] The compile check has no new warnings; `swift test` is green.
- [x] **Device:** 5 minutes on the iPhone 13 at the default format. `r1-summary.json` gives the dropped %, copy p95 and highest thermal state. The user reports whether the plane viewer stutters, and *mem MB* at the start and end. *(Two shorter runs, 96 s and 69 s, accepted by the user. The 5-minute run moves to Checkpoint 2A.)*
- [x] The decision is logged in §15 R1: keep 60 fps images, or take the P5 fallback. `RecorderConstants` is updated to match. *(Full-resolution image per delivered frame; constants unchanged.)*
- **Verify:** compile check; the device run (ask before installing).
- **Run 1 (2026-09-28, iPhone 13, 96 s, phone charging, installed by the user from Xcode):**
  - **Copy on the main thread is cheap:** p50 0.62 ms, p95 0.85 ms, max 2.8 ms. The §17.5 risk is retired.
  - **Drops:** 4 of 2,876 images (0.14 %), all pool drops in one burst, none from the encoder.
  - **No stutter** (user). *mem MB* went 303 → 430 at the ends; the user saw about 350 during the run.
  - **Thermal reached `serious`.**
  - **Open:** ARKit delivered **≈ 30 Hz, not 60** (2,876 frames in 96 s). So the movie, timed at `idx / 60`, lasts 47.9 s for 96 s of walking. Either the format is 30 fps or the rate fell with heat.
- **Tooling fixes found by run 1:**
  - Xcode's generated Info.plist ignores `INFOPLIST_KEY_UIFileSharingEnabled`, so the app didn't show in Finder. It now comes from `SidingsAR-Info.plist`.
  - Files can always be pulled with `xcrun devicectl device copy from … --domain-type appDataContainer` (see `ARKit_WallDetection/CLAUDE.md`).
- **Run 2 (69 s, still charging):** the format promised 60 fps; ARKit delivered a flat 30.0 Hz from the first second, with thermal already `serious` at t = 0. Copy p95 0.96 ms, 0.15 % dropped. Memory went 300 → 318 (4 s) → 404 (30 s) → 443 MB (68 s). Finder's Files tab now lists the app but can't open or copy its folders, so `devicectl` is the dependable pull.
- **Closed** by the user on 2026-09-28 with the decision in §15 R1. The open points (60 Hz on a cool phone, heat caused by recording, memory growth) move to Checkpoint 2A.
- **Depends on:** T1.
- **Files:** `SidingsAR/Recording/VideoCapture.swift`, `SidingsAR/HUDView.swift`, `SidingsAR/ARSessionController.swift`, `SidingsAR.xcodeproj/project.pbxproj` (Info keys only)

#### Checkpoint 0: risks answered

- [x] `swift test` is green and the compile check is clean.
- [x] R1 and R2 have findings and decisions in §15.
- [x] If a spike failed with no working fallback: stop and re-spec with the user. *(Neither failed.)*
- [x] **User:** review before Phase 1. *(2026-09-28: "move on". The T2 scrub check in the Blender UI is still open and doesn't block anything.)*

### Phase 1: Tracer bullet (a real recording reaches Blender)

#### T4. Schema v1, records and the contract fixture · M · S7

`session-format/schema_v1.sql` with every §3.3 table. The Swift records (`FrameRecord`, `AnchorRecord`, `LocationRecord`, `HeadingRecord`, `EventRecord`), little-endian BLOB packing, and a synchronous `SessionDatabase` that creates the schema and writes `meta` (with the `const.*` rows at open) and rows. Generates the contract fixture (P2, P3).

- [x] The DDL embedded in Swift matches `schema_v1.sql` exactly.
- [x] Every BLOB column round-trips.
- [x] `PLANELAB_WRITE_FIXTURES=1 swift test` writes `session-format/fixtures/v1/tiny.planelab/` and `expected.json`. A normal run checks that the committed fixture still matches.
- **Verify:** `swift test`
- **Result (2026-09-28):** done. 61 tests in 9 suites pass, the clean build has no warnings, and the iOS compile check is clean. The fixture is described in `session-format/README.md`. Findings:
  - `seal()` also closes and removes the `-shm` file SQLite leaves after leaving WAL, so a sealed session is one file.
  - When decoding, `AVAssetReaderTrackOutput` applies the leading empty edit and adds a blank frame for it; in passthrough it reports media time (`ARKit_WallDetection/CLAUDE.md`).
  - In `expected.json`, NULL columns are left out of rows.
  - `.gitignore` ignores `*.planelab` except the fixture.
- **Depends on:** T1 (for the fixture's video).
- **Files:** `session-format/schema_v1.sql`, `session-format/README.md`, `PlaneKit/Sources/PlaneKit/Recording/{Records,Packing,SessionDatabase}.swift`, `PlaneKit/Tests/PlaneKitTests/Recording/{PackingTests,ContractTests}.swift`

#### T5. Session writer: queue, batches, drops, crash safety · M · S3, S6

`SessionWriter` runs on its own serial queue over `SessionDatabase`: WAL mode, one transaction per `commitIntervalS` (with the clock injected for tests), a bounded queue that drops whole frames and counts them, and finalize (counters, `stopped_at`, `stop_reason`). The pixel buffer is handed to `VideoWriter` through one `@unchecked Sendable` box (§17.5).

- [x] With a stalled database (a test double), `enqueue` never blocks, drops whole frames, and `frames_dropped` matches.
- [x] A database that was never finalized opens and holds every frame committed before the last batch.
- [x] It builds under strict concurrency with no warnings.
- **Verify:** `swift test`
- **Result (2026-09-28):** done. 68 tests pass three runs in a row; the compile check is clean. Design choices:
  - The writer assigns `idx` only to accepted frames, so `idx` has no holes and `lastFrameIndex` stamps anchors, fixes and events.
  - The stall "test double" is suspending the writer queue: 100 enqueues took under 50 ms, with 80 dropped.
  - Tests turn the commit timer off and call `flush()` instead of injecting a clock.
  - Video appends run on the same serial queue, so each record's `has_image` is known before it's written.
  - Counters sit behind a `Synchronization.Mutex`.
- **Depends on:** T4.
- **Files:** `PlaneKit/Sources/PlaneKit/Recording/SessionWriter.swift`, `PlaneKit/Tests/PlaneKitTests/Recording/SessionWriterTests.swift`, small edits to `VideoWriter.swift`

#### T6. Python package, session reader and `planelab info` · M · S7

Creates `PlaneLab/`: `pyproject.toml`, a pinned `requirements.txt` (numpy 1.26.4, pytest, pytest-cov, ruff), a `.venv` on Python 3.11, ruff settings and logging (P8). `planelab.session` reads `meta`, frames on demand (`numpy.frombuffer`), anchors, location, heading and events. It refuses unknown versions and accepts a zip. `planelab.schema` embeds the DDL (P2). Adds the CLI's `info` command, and adds `*.planelab`, `.venv/` and `dist/` to the root `.gitignore`.

- [x] The contract fixture decodes to `expected.json`, the same values Swift checks.
- [x] `schema_version = 2` is refused with a message naming the version found and the versions supported.
- [x] `python -m planelab info` works on the fixture folder and on its zip.
- **Verify:** `pytest --cov=planelab --cov-fail-under=85`; `ruff check . && ruff format --check .`
- **Result (2026-09-28):** done. 29 tests with 98 % coverage; `ruff` is clean.
  - The same `info` runs unchanged under Blender's own `python3.11`.
  - The reader returns row-major numpy matrices, plus `first_image_idx()` and `delivered_fps()` for the importer (§15 R2, §3.4). `info.summarize()` feeds both the CLI and the future Blender panel.
  - Zips extract once into `~/PlaneLab/cache/`, with the folder at the root of the zip or one level down.
  - The package installs editable (`pip install -e . --no-deps`); pytest uses `pythonpath = src`.
- **Depends on:** T4.
- **Files:** `PlaneLab/pyproject.toml`, `PlaneLab/requirements.txt`, `PlaneLab/src/planelab/{__main__,cli,session,schema,log}.py`, `PlaneLab/tests/{test_session,test_cli}.py`, `.gitignore`

#### T7. Recording on the phone: Record/Stop, frames and video · M · S2, S4

The T3 glue becomes the real recorder, and the spike toggle goes away:
- **Record/Stop** in the HUD.
- `SessionRecorder` builds a `FrameRecord` inside the frame delegate and hands it, with the pool copy of the image, to the writers.
- Sessions go to `Documents/Sessions/<stamp>.planelab`.
- The HUD shows elapsed time, frames, images dropped, MB written and free space.
- The ARKit → record conversion lives in `ARRecordAdapter.swift` (P13).

- [x] The compile check is clean; `swift test` is green.
- [x] **Device:** the user records 1 minute on the iPhone 13 and copies it through Finder. `planelab info` shows ≥ 99 % of frames logged, and the image drop rate. *(Finder can't open app folders (T3), so the copy is done with `devicectl`.)*
- **Device result (2026-09-28, user's recording `20260928-160746`, 48 s):**
  - **2,863 frames, 0 dropped (100 % logged).** 7 frames have no image (0.24 %): a burst at frames 5–9 while the encoder started, plus two isolated ones.
  - **A steady 60.0 Hz delivered** (median interval 16.67 ms, one 50 ms gap) at thermal state *fair* throughout.
  - 100 % normal tracking; about 250 points per frame, p50 1.4 m and max 7.2 m (indoors).
  - The bundle is sealed to 2 files: 16.9 MB SQLite plus 48 MB video, about 82 MB/min.
  - `planelab info` took 0.55 s.
  - The folder pulls in one `devicectl copy` (root `README.md`).
- **Code (2026-09-28):**
  - The Record/Stop button, `SessionRecorder` and `ARRecordAdapter` replace the spike (`VideoCapture.swift` is removed).
  - Reset, mode change, pause, interruption and error stop the recording with `reset`, `mode_change`, `pause`, `interruption` and `error`.
  - Record start and stop become `event` rows. `meta` holds the device, OS, LiDAR, detection mode, world alignment, video format, ARKit's format and every `const.*`.
  - Tracking events, background and low disk follow in T10.
- **Verify:** compile check; `planelab info <session>`
- **Depends on:** T3, T5, T6.
- **Files:** `SidingsAR/Recording/{SessionRecorder,ARRecordAdapter}.swift`, `SidingsAR/HUDView.swift`, `SidingsAR/ARSessionController.swift`; `SidingsAR/Recording/VideoCapture.swift` is removed

#### T8. Blender extension and import: camera and raw points · M · S10 (part)

The extension layout from P6: manifest, the `vendor/planelab` link, `scripts/build_extension.sh`, and the local-repository dev loop. *File › Import › Plane Lab Session* does the following:
- sets the scene fps and frame range, and creates one collection
- keyframes the camera, converted from ARKit to Blender axes
- sets lens, shift and resolution from the intrinsics
- adds the raw-points layer, driven by a frame-change handler from cached arrays
- turns `event` rows into markers

- [x] Headless: importing the fixture gives the expected frame range. Camera keys at 3 sampled frames match the converted poses (to 1e-5), and raw-point vertex counts there equal `point_count`.
- [x] The built zip installs with `extension install-file`, and an edit to the source shows up after *Reload Scripts*. *(The install is tested into a throwaway profile. The Reload Scripts loop needs the local repository in the user's Blender, which waits for the user's OK.)*
- **Result (2026-09-28):**
  - **Core modules:** the pure-numpy conversions went into `planelab.axes` (axes, lens and shift, quaternions) and `planelab.replay` (packed arrays), so pytest covers them.
  - **The Blender glue** (`build.py`, `layers.py`, `import_op.py`):
    - Camera pose, lens and shift are keyframed on every frame, in bulk through Blender 5's slotted-action channelbags.
    - A static trail shows the whole path.
    - Raw points are drawn as a geometry-nodes point cloud (loose vertices are invisible in Object Mode), filled by a frame handler.
    - Events become markers, and importing again replaces the earlier import.
  - **Real recording (2,863 frames), headless:** the import passes the same checks in about 0.05 s, and a frame change costs about 0.1 ms.
  - **Tests:** `tests/test_blender.py` runs the headless import and the build and install. Blender 5.0 removed `Action.fcurves`, so keys go through `bpy_extras.anim_utils.action_ensure_channelbag_for_slot`.
- **Verify:** `$BLENDER --background --factory-startup --python-exit-code 1 --python PlaneLab/tests/blender/smoke_import.py -- <fixture>`
- **Depends on:** T6.
- **Files:** `PlaneLab/blender/planelab_blender/blender_manifest.toml`, `.../{__init__,import_op,layers}.py`, `PlaneLab/scripts/build_extension.sh`, `PlaneLab/tests/blender/smoke_import.py`

#### T9. Blender: the video behind the camera · S · S11

The recording's `video.mov` becomes the camera's background movie clip, starting at timeline frame `1 + <first log frame with has_image = 1>` (T2). It's sized to the captured image. Later `has_image = 0` gaps need nothing: Blender holds the previous image.

- [x] Headless: on the fixture video, frame `idx + 1` shows image `idx` (P4 blocks). *(2026-09-28: frames 1–10 show `[0, 1, 2, 3, 3, 5, 6, 6, 8, 9]`: black before the first image, every image on `idx + 1`, and gaps at idx 4 and 7 holding the previous image. The smoke test renders the camera's own clip through the compositor's Movie Clip node, which maps scene frames to clip frames the same way the camera background does. On the real recording, the clip starts at frame 1 and spans all 2,863 frames.)*
- [x] **User (S11):** on the T7 recording, looking through the camera, the raw points sit on image features across the whole timeline. *(2026-09-28, user: "everything seems right". The screenshot shows the points on the basket holes, the door panels and the machine's edges.)*
- **Verify:** the smoke test, then the user's check in Blender.
- **Depends on:** T2, T7, T8.
- **Files:** `PlaneLab/blender/planelab_blender/{import_op,camera}.py`, `PlaneLab/tests/blender/smoke_import.py`

#### Checkpoint 1: tracer bullet

- [x] `swift test`, the compile check, `pytest` (≥ 85 %) and `ruff` are green.
- [x] **User:** S11 holds on a real iPhone 13 recording, so video, pose, intrinsics and axes agree.
- [x] **User:** review before the two tracks. *(2026-09-28. The user also linked `PlaneLab/blender/` into their Blender as a local extension repository and imported a second, landscape recording, `20260928-174840`: 978 frames at 60 Hz, roll about 2°, images missing only at frames 5–9 and 639.)*

### Phase 2A: Recorder complete (Swift, device)

#### T10. Stop reasons, events and low disk · M · §4 R3, R9

*Follow-up from T7:* warm the pixel pool when Record is tapped. The first recording lost images for frames 5–9, and ARKit skipped two frames at frame 10 (a 50 ms gap), most likely while the first pool buffers were being allocated during capture.

The recording stops and finalizes, with the matching `stop_reason`, on any of: Reset, a detection-mode change, an interruption, going to the background, or a session error. Tracking-state changes, interruptions and relocalization become `event` rows. Recording also stops when free space falls below `lowDiskBytes` (`low_disk`). The reason mapping and the disk rule are pure logic in PlaneKit (P10).

- [x] Unit tests cover every stop reason and the low-disk rule.
- [ ] **Device:** tapping Reset mid-recording leaves a finalized session with `stop_reason = reset`, and its tracking events show as markers in Blender. *(Also check `planelab info` for the new "no image: …" breakdown.)*
  - *First T10 build on the phone (2026-09-29, `20260929-161400`, 2,669 frames, stopped by the user):* `const.pixelPoolSize` 6, a `tracking` event at frame 0, `stop_reason = user`. **3 images missing, all `no_buffer`**, the first at frame 7, against 5 (frames 5–9) in every earlier recording. So the losses are on the capture side (no free pool buffer), and warming the pool helped without closing it. Possible next steps: 8 buffers, or opening the encoder before the first frame. Reset hasn't been tapped yet.
- **Code (2026-09-29):**
  - **PlaneKit `RecordingPolicy.swift`:**
    - `StopReason`, the typed `meta.stop_reason`, now includes `pause` and `background`.
    - `DiskGuard` stops below `lowDiskBytes`; an unknown free space never stops.
    - `TrackingChangeDetector` gives the tracking detail at frame 0 and on every change.
    - `ImageSkipLog` counts missing images by reason, with one event per burst.
  - **Startup image loss** (every recording, frames 5–9):
    - The pool is warmed when the writer opens, and `pixelPoolSize` goes from 4 to 6.
    - Every missing image is attributed (`meta.image_skip.*`, `image_skip` events) (P18).
    - A Mac reproduction at 1440p, real-time, 60 Hz showed no misses with 4 or 6 buffers, warmed or not, so the cause is phone-side. The next recording's counters will say whether it's the pool or the encoder.
  - **App:** tracking events are stamped on the exact frame. The free-space check runs once a second, and `scenePhase == .background` stops the recording (an ARKit interruption may come first and be the recorded reason).
  - **Tests:** 7 new Swift tests (75 in total); `planelab info` shows `(no image: N reason, ...)`.
- **Verify:** `swift test`; compile check; device run.
- **Depends on:** T7.
- **Files:** `PlaneKit/Sources/PlaneKit/Recording/RecordingPolicy.swift`, `PlaneKit/Tests/PlaneKitTests/Recording/RecordingPolicyTests.swift`, `SidingsAR/Recording/SessionRecorder.swift`, `SidingsAR/ARSessionController.swift`, `SidingsAR/ContentView.swift` (scene phase)

#### T11. ARKit plane anchors and the Mark button · S · E2 input

Anchor callbacks enqueue `add`, `update` and `remove` rows through `ARRecordAdapter`, stamped with the last logged frame. They do nothing else, per the SidingsAR invariant. *(Should)* **Mark** adds an `event` row.

- [x] Unit test: a `remove` record carries only the anchor id, and the others round-trip every column.
- **Code (2026-09-28, brought forward at the user's request).** The user saw planes in the app but `info` said `0 ARKit planes`, because T7 recorded frames and video only.
  - The anchor callbacks now queue rows (they still only record).
  - Planes that exist when recording starts are logged as `add` at frame 0.
  - The Mark button is in.
  - Blender shows ARKit's planes (P17).
- [x] **Device:** a room recording has `plane_anchor` rows, and `planelab info` counts the adds, updates and removes. *(2026-09-28, recording `20260928-181436`, 20 s: `2 ARKit planes: 2 add, 371 update` (a floor and an unclassified horizontal plane), shown in Blender next to the points and video. User: "the test was flawless". The Mark button wasn't tapped in this recording, so it hasn't been exercised on the device yet.)*
- **Verify:** `swift test`; compile check; device run.
- **Depends on:** T7.
- **Files:** `SidingsAR/Recording/{ARRecordAdapter,SessionRecorder}.swift`, `SidingsAR/ARSessionController.swift`, `SidingsAR/HUDView.swift`, `PlaneKit/Tests/PlaneKitTests/Recording/PackingTests.swift`

#### T12. Permissions screen and location logging · M · S5

At launch, while Camera or Location is undecided, a `PermissionsView` shows before the AR view: Camera, then Location While In Use, each with a status row, plus **Open Settings** when one is denied. While recording, a `LocationFeed` (`CLLocationManager`, best accuracy, no distance filter, 1° heading filter) sends `LocationRecord` and `HeadingRecord` rows to the writer. `meta` gets `location_auth` and `location_accuracy`. The logic for which screen to show is pure PlaneKit code (P10).

- [ ] Unit tests: the right screen shows for every combination of camera and location states, and location and heading rows are written and read back.
- [ ] **Device (S5):** on a fresh install on the iPhone 13, denying Location still lets recording work, with `meta` saying `denied`. Allowing it gives `location` rows at about 1 Hz, plus `heading` rows.
- **Verify:** `swift test`; compile check; device run.
- **Depends on:** T7.
- **Files:** `SidingsAR/Recording/{PermissionsView,LocationFeed}.swift`, `SidingsAR/ContentView.swift`, `PlaneKit/Sources/PlaneKit/Recording/PermissionState.swift` and its tests, `project.pbxproj` (`NSLocationWhenInUseUsageDescription`)

#### T13. Sessions sheet · S · S4

A sheet lists the recordings (date, duration, size, device, read from `meta`), with **Share** (zipped through `NSFileCoordinator` `.forUploading`) and **Delete**. Reading the summary is PlaneKit code, tested on the fixture.

- [ ] Unit test: the fixture's summary (duration, frames, device, size) is correct.
- [ ] **Device (S4):** a session AirDropped as a zip is read by `planelab info`, and it also shows in the Files app and in Finder.
- **Verify:** `swift test`; compile check; device run.
- **Depends on:** T7.
- **Files:** `SidingsAR/Recording/SessionsView.swift`, `SidingsAR/HUDView.swift`, `PlaneKit/Sources/PlaneKit/Recording/SessionSummary.swift` and its tests

#### Checkpoint 2A: recorder on the device

- [ ] **Conditions (from T3):** phone unplugged and cool. First a 1-minute plain-viewing baseline without Rec, noting HUD fps and *mem MB*. Then note the fps just before Record. This separates ARKit's own 30 Hz and the viewer's memory growth from what recording adds.
- [ ] **Device (S1):** 5 minutes on the iPhone 13, with *mem MB* staying within ±50 MB of its value 30 s after Record.
- [ ] **Device (S2):** ≥ 99 % of frames are logged, ≤ 1 % of images are dropped, and the viewer stays smooth.
- [ ] **Device (S3):** after a force-quit mid-recording, the session opens up to about 1 s before the kill, and the video plays up to its last fragment.
- [ ] **Device:** the same checks pass on the iPhone 13 Pro.
- [ ] S6: `swift test` is green and the compile check is clean.
- [ ] Findings are in `ARKit_WallDetection/README.md`. **User:** review.

### Phase 2C: averaged cloud on the phone (L12, added 2026-09-29)

The user asked for CurvSurf's accumulator in the iOS app, live and recorded (L12). The Python accumulator (T16) is the reference: the Swift port must give the same cloud from the same frames.

#### T27. Swift accumulator in PlaneKit · M · L12

`FeatureAccumulator`: a port of CurvSurf's `FeatureCompressor` with the Python accumulator's rules (T16): a FIFO of `cloudMaxSamples` per id, the z-score-filtered mean from `cloudMinSamples` on, and eviction of the oldest id by first sighting beyond `cloudMaxIds`, including an id evicted later in the same frame. Plus the near/far filter and the frame gate (`off`, `intended`, `upstream`), and the cloud constants (P21). Storage is preallocated per slot and grown in chunks (P25). Changes are tracked by id for snapshots.

- [x] Unit tests: FIFO wrap, `min_samples`, the z-score filter, eviction order (same frame too), each gate mode, the near cut.
- [x] **Golden check:** Python writes `session-format/fixtures/cloud/golden.json` from a synthetic session (a small `max_ids`, so evictions happen), and the Swift replay gives the same ids and sample counts, with positions within 2e-6 m.
- **Result (2026-09-29):** done. 92 Swift tests (17 new), 121 Python tests.
  - **Golden:** 30 frames of 60 features (ids above 2^53, 1 cm noise, 5 % outliers), five cases (defaults; a 4-sample FIFO with 50 ids and z-score 1.2; `intended` with near/far cuts; `upstream`; normal tracking only). The largest difference is 4.8e-7 m, which is float32 rounding at 10 m. Changing the z-score by 0.1 or `min_samples` by 1 misses by 1.6 mm to 15 cm or changes the ids, so the test does catch a wrong port.
  - **Speed** (Mac Studio, 250 sightings per frame, 12,500 averaged points after 60 s at 60 fps): 0.055 ms per frame optimized, worst 0.6 ms; 20 MB of storage. Unoptimized it was 3.2 ms (4.8 ms before a scalar rewrite), hence P26.
- **Verify:** `swift test`; `pytest`.
- **Depends on:** T16.
- **Files:** `PlaneKit/Sources/PlaneKit/Cloud/{FeatureAccumulator,CloudGate}.swift`, `Recording/Constants.swift`, `PlaneKit/Tests/PlaneKitTests/Cloud/`, `PlaneLab/scripts/cloud_golden.py`

#### T28. Live cloud in SidingsAR · M · device

`LiveCloud` (PlaneKit, thread-safe, its own queue) takes each frame's camera, points and ids, and publishes a display copy at 10 Hz. SidingsAR draws it (P24), with an **Averaged cloud** toggle and the point count in the HUD. Reset clears it.

- [x] Unit tests: `LiveCloud` gives the accumulator's cloud, never blocks the caller, and `clear()` empties it.
- **Code (2026-09-29):** `LiveCloud` (a display copy every 6 frames, at most 120 frames waiting, drops counted), `CloudMesh` (squares of half-size 0.003 × distance, 3 bands, at most 40,000 points drawn), `SidingsAR/CloudRenderer.swift` (one entity, one part and `UnlitMaterial` per band, generated once and then `replace(with:)`, rebuilt every 0.2 s). The controller copies each frame once (`ARRecordAdapter.frameRecord`) for both the cloud and the recorder. HUD: a **cloud** count and an **Averaged cloud** toggle in Debug. 99 Swift tests; the iOS compile check is clean.
- [ ] **Device:** the cloud grows while scanning, like CurvSurf's app. *mem MB* and fps before and after (the user reports).
- **Verify:** `swift test`; compile check; device run.
- **Depends on:** T27.
- **Files:** `PlaneKit/Sources/PlaneKit/Cloud/LiveCloud.swift`, `SidingsAR/CloudRenderer.swift`, `SidingsAR/ARSessionController.swift`, `SidingsAR/HUDView.swift`

#### T29. Record the cloud: schema v2 · M · L12

The `cloud` table (P23): `frame_idx` INTEGER PK, `full` INTEGER, `removed_ids` BLOB (u64), `ids` BLOB (u64), `points` BLOB (3 × f32), `samples` BLOB (u16). `schema_version` becomes 2 (§3.5), with `schema_v2.sql` as the DDL source. Record clears the cloud (P22), and `LiveCloud` hands rows to `SessionWriter` on the writer's frame numbers. Python reads v1 and v2; a v2 contract fixture (written by Swift) covers `cloud` rows, including a removal and a second full copy.

- [x] Swift: writer tests for the `cloud` rows, the v2 fixture decodes to `expected.json`, and a v1 file is still readable.
- [x] Python: the v2 contract test, `RecordedCloud.at(idx)` rebuilds the cloud from rows, `peek` decodes the table, and `info` prints the phone's final cloud.
- **Result (2026-09-29):** done. 106 Swift tests, 128 Python tests (99 % coverage); the iOS compile check is clean.
  - **Format:** `session-format/schema_v2.sql` (v1 plus `cloud`), embedded on both sides; `SessionSchema.readable` / `SUPPORTED_VERSIONS` = 1, 2. The v2 fixture adds two rows: a full copy after frame 5, then changes after frame 9 that remove one id and set an id above 2^53 with 300 samples.
  - **Phone:** `LiveCloud.startRecording` clears the cloud and emits rows on recorded frames; `stopRecording` (called in `SessionRecorder.stop`, before the writer finishes) adds the last row and returns the `cloud_*` meta. While recording, the cloud sees only frames the writer accepted, with their `idx`. Disk and error stops are now checked before a frame is recorded, so the last row covers exactly the recorded frames.
  - **Python:** `Session.cloud_rows()`; `recorded_timeline(rows)` gives the same `CloudTimeline` as the Mac's recompute (now with explicit `full_rows`, cache format `cloud-v2`), plus `ids_at`; `peek` writes `cloud_rows`, `cloud_points` and `cloud_final`; `info` prints `cloud  phone: N averaged points after R rows (M frames missed)`.
  - The implementation is `recorded_timeline` in `planelab.cloud`, not a separate `RecordedCloud` class.
- **Verify:** `swift test`; `pytest`.
- **Depends on:** T27.
- **Files:** `session-format/schema_v2.sql`, `session-format/fixtures/v2/`, `PlaneKit/Sources/PlaneKit/Recording/{SessionDatabase,Records,SessionWriter}.swift`, `PlaneLab/src/planelab/{schema,session,peek,info,cloud}.py`

#### T30. The phone's cloud in Blender, and the equality check · S · L12

The averaged-cloud layer shows the recorded cloud when the session has one, otherwise the Mac's recompute (P19). `planelab info` compares the two (the recompute uses the recording's `const.cloud*` settings): same ids, same sample counts, the largest position difference.

- [x] Headless: on the v2 fixture and a synthetic v2 session, the layer shows the recorded rows.
- **Code (2026-09-29):** `planelab.cloud.session_cloud` picks the phone's rows when there are any, else the Mac's recompute with `config_from_meta` (the recording's `const.cloud*` settings); the import reports which (`… averaged points at the end (phone cloud)`). `compare_recorded` replays the recording through the Mac's accumulator and compares every row: ids, sample counts, largest position difference. `planelab info --check-cloud` prints it, and `pull.sh` passes the flag.
  - **End to end without a phone:** `session-format/fixtures/cloud/recorded.planelab` is the golden frames recorded by the real Swift path (`SessionWriter` + `LiveCloud`, with a 4-sample FIFO, 50 ids and a full copy every 2 rows). Python reads its settings back from `meta`, and the recompute matches: 5/5 rows, 18 points, largest difference 0.0003 mm. With the default settings instead, it doesn't, so the check can tell. The Blender smoke test shows the phone source on it. Full rows are now sorted by id so a recording is reproducible.
  - 108 Swift tests, 132 Python tests (98 %).
- [ ] **Device + user:** a new recording shows the phone's cloud in Blender, and `info` reports it equal to the recompute.
- **Depends on:** T28, T29.
- **Files:** `PlaneLab/blender/planelab_blender/layers.py`, `PlaneLab/src/planelab/{cloud,info}.py`

#### Checkpoint 2C

- [ ] **User:** the cloud grows on the phone during a real scan, and the same cloud plays back in Blender. *mem MB*, fps and MB/min are recorded here (P23, P25).

### Phase 2B: Lab core (Python, Mac only; can start right after T6)

#### T14. Synthetic sessions · M · S8 input

`planelab synth` writes the `facade`, `edges` and `room` scenes through a Python writer of the real schema (P7). Each scene has a camera path, features with stable ids, σ noise, outliers and visibility, plus a `synth_truth.json`. There's no video.

- [x] The reader opens every scene, and the truth lists every planted plane.
- [x] The same seed gives identical files, and a different seed gives different ones.
- [x] In `edges`, points exist only near corners, trim and openings.
- **Result (2026-09-29):** done.
  - **Scenes:**
    - `facade`: a 16 × 6 m wall at 8 m plus the ground.
    - `edges`: a concave corner of two 8 × 6 m walls with features only on the corner line, parapets, bases, two trim lines and two window frames per wall.
    - `room`: 4 walls plus a floor, with the camera turning 360°.
  - **Clutter:** every scene has 20 % of its features on no plane.
  - **Sightings:** stable ids from 2^40; features are visible when inside the image, in front of the camera and on the camera side of their plane; detection probability 0.8; at most 500 per frame. Noise is `noise_m` (1 cm) in every direction plus `ray_noise_per_m` × depth along the view ray.
  - **Writing:** sessions go through `planelab.writer` (the real schema, one file, no video). `synth_truth.json` holds each plane's normal, offset, corners and feature count.
  - **Tests:** 10 synth tests plus a headless-Blender import of a synthetic `edges` session (no video, so no background). 74 Python tests, 98.5 % coverage.
- **Verify:** `pytest --cov`; `ruff`
- **Depends on:** T6.
- **Files:** `PlaneLab/src/planelab/{synth,writer,cli}.py`, `PlaneLab/tests/test_synth.py`

#### T15. `LabConfig` and presets · S · L8

Frozen dataclasses for every §5 setting, TOML load and save with validation, `configs/default.toml` and `configs/recall.toml`, and conversion to key/value rows for `results.sqlite`.

- [x] Unknown keys and out-of-range values are rejected with an error naming the field.
- [x] Saving then loading gives an equal config, and `default.toml` equals the dataclass defaults.
- **Result (2026-09-29):** done.
  - **`planelab.config`:** `LabConfig` has five frozen sections (29 settings), and each section checks its values in `__post_init__`, so hand-built configs are checked too.
  - **Loading and saving:** TOML goes in with `tomllib` and out through a small writer (stdlib only, L6). A file may be partial. Integers are accepted where floats are expected; bools are never taken as ints.
  - **Storage:** `config_rows()` gives the `section.key` rows for `results.sqlite` (L8).
  - **Presets:** `configs/default.toml` and `configs/recall.toml` (recall: `min_samples` 3, `tau0_m` 0.05, `tau_range_k` 0.001, `min_inliers` 15, `min_spread_m` 0.15, `confirm_hits` 2).
  - **Tests:** 19. The Python suite is at 93 tests and 98.7 % coverage.
- **Verify:** `pytest --cov`; `ruff`
- **Depends on:** T6.
- **Files:** `PlaneLab/src/planelab/config.py`, `PlaneLab/configs/{default,recall}.toml`, `PlaneLab/tests/test_config.py`

#### T16. Point filter, motion gate and accumulator · M · E3

The near cut, the four gate modes (`off` by default, then `intended`, `upstream` and `parallax`), and the CurvSurf accumulator: a FIFO per id, the z-score filter, `min_samples`, `max_ids` eviction, and each point's sample count and spread. It all runs on preallocated ring buffers (§17.5).

- [x] Hand-built cases match CurvSurf's behavior, including eviction.
- [x] On crafted camera paths, each gate accepts exactly the expected frames or samples, `upstream` included.
- [x] 100 000 ids at 100 samples each stay within the memory estimate (test).
- **Result (2026-09-29):** done.
  - **`planelab.gate`:**
    - `keep_points`: CurvSurf's near cut drops squared distance ≤ 0.25², plus an optional far cut.
    - `FrameGate`: CurvSurf's `CameraMotionDetector` with position and direction starting at zero. `intended` passes on distance² ≥ move², `upstream` on distance² < move² as coded, either way or a turn past `turn_deg`.
    - `ParallaxGate`: per feature, forgetting the ids the accumulator evicts.
  - **`planelab.accumulate`:**
    - `Accumulator`: CurvSurf's `FeatureCompressor` on ring buffers that grow in 16 384-slot chunks, with the z-score filter in float64. Evicting an id earlier in the same frame drops that frame's write, as the sequential Swift loop does. A degenerate z-score (everything rejected) keeps all samples instead of producing NaN.
    - `accumulate(replay, config)`: stages 2–4.
  - **Tests** (19 new, 112 Python tests, 98.8 %):
    - A **line-by-line Python port of the Swift `FeatureCompressor`** matched on a random stream with evictions and outliers.
    - Hand-built cases: min samples, z-score, FIFO, eviction by first sighting, eviction inside one frame.
    - 100 000 ids × 100 samples under `(ids + chunk) × per-slot bytes` (< 150 MB).
    - Averaging a synthetic facade gets the median error below a third of one raw sighting's.
    - Crafted camera paths for every gate mode; parallax is range-aware (every 5 cm step at 1 m, every 4th at 10 m).
  - **Real recordings (all four gate modes):** see *Why gate at all* in §5.1. Stages 2–4 took 3.4 s for 2,863 frames with the gate off.
- **Verify:** `pytest --cov`; `ruff`
- **Depends on:** T14, T15.
- **Files:** `PlaneLab/src/planelab/{gate,accumulate}.py`, `PlaneLab/tests/{test_gate,test_accumulate}.py`

#### T17. RANSAC plane models · M · S8

Vertical (2-point), horizontal (1-point) and free (3-point) hypotheses, a least-squares refit, the range-scaled inlier distance `τ = τ₀ + k·z²`, and rejection of nearly collinear inliers.

- [ ] Planted planes (σ = 1 cm, 20 % outliers) are found with normal error < 2° and offset error < 2 cm, for each model.
- [ ] Points along a single line produce no plane.
- **Verify:** `pytest --cov`; `ruff`
- **Depends on:** T14, T15.
- **Files:** `PlaneLab/src/planelab/fit.py`, `PlaneLab/tests/test_fit.py`

#### T18. Sequential search and extents · M · S8

Sequential RANSAC that keeps points within `edge_keep_m` of accepted planes available, and extents as convex hulls of the inliers, split into connected regions.

- [ ] In the `edges` scene, both walls at a shared corner are found, and no plane is fitted to a single edge.
- [ ] Two separate stretches of one plane give two regions.
- **Verify:** `pytest --cov`; `ruff`
- **Depends on:** T17.
- **Files:** `PlaneLab/src/planelab/{search,hull}.py`, `PlaneLab/tests/{test_search,test_hull}.py`

#### T19. Plane tracker · M · S8

Matching by normal angle, plane distance and overlap; updates by EMA or refit; tentative → confirmed after `confirm_hits`; merges, where the older id survives; stale planes; and `add` / `update` / `merge` / `stale` events.

- [ ] Under per-fit jitter, every planted plane keeps one id with zero switches.
- [ ] Merge and stale unit cases pass. A recessed opening 10 cm behind the wall stays separate. One 5 cm behind merges at the default 8 cm merge distance and stays separate at 4 cm, which documents the trade in §5.3.
- **Verify:** `pytest --cov`; `ruff`
- **Depends on:** T18.
- **Files:** `PlaneLab/src/planelab/track.py`, `PlaneLab/tests/test_track.py`

#### T20. Pipeline, results store, `run` and `export` · M · S9

The whole pipeline over a session, writing:
- `lab/<run>/results.sqlite`, with a `config` table (L8), the per-frame readouts (§5.4), our planes and their events, and snapshots of the averaged cloud (P12)
- a copy of `config.toml`

Also adds `run --progress` (JSON lines) and `export --csv`.

- [ ] Two runs with the same config and seed give identical results.
- [ ] A 2-minute synthetic session runs in < 60 s on the Mac Studio (S9), and every `LabConfig` field is in the `config` table.
- [ ] `run` finishes on the T7 real recording, and `export` writes a CSV.
- **Verify:** `pytest --cov=planelab --cov-fail-under=85`; `ruff`; timing on the Mac Studio.
- **Depends on:** T16, T19.
- **Files:** `PlaneLab/src/planelab/{pipeline,results,cli}.py`, `PlaneLab/tests/{test_pipeline,test_results}.py`

#### Checkpoint 2B: lab core

- [ ] S7 (the Python side), S8 and S9 are green, coverage is ≥ 85 %, and `ruff` is clean.
- [ ] **User:** review of a `planelab run` CSV from the real recording.

### Phase 3: Blender complete

#### T21. Result layers and per-frame readouts · M · S12

Layers for:
- the averaged cloud, colored by sample count
- our planes, colored by track id: tentative planes lighter, stale ones grey, with labels showing id, age, inliers and RMS
- ARKit's planes, in SidingsAR colors

*ARKit's planes (P17) and the averaged cloud (P19) are already in, the cloud from its own cache with the default settings. T21 switches the cloud to the run's `results.sqlite` and adds our planes and the readouts.*

The panel shows the per-frame readouts. The frame handler reads cached arrays loaded from `results.sqlite`.

- [ ] Headless: at sampled frames, vertex and plane counts match `results.sqlite`.
- [ ] Headless: on a 2-minute synthetic run, a frame change updates every layer in ≤ 100 ms (S12).
- **Verify:** the Blender headless suite.
- **Depends on:** T9, T20.
- **Files:** `PlaneLab/blender/planelab_blender/{layers,panel,results_cache}.py`, `PlaneLab/tests/blender/smoke_layers.py`

#### T22. Settings panel and Recompute · M · S13

Panel properties generated from `LabConfig`, TOML load and save, and **Recompute**:
- `sys.executable -m planelab run … --progress` runs in a subprocess with `PYTHONPATH` set (P6)
- a modal timer shows progress, and **Cancel** stops the run
- the new run loads without a restart
- *(Should)* a run picker

- [ ] Headless: Recompute on a synthetic session finishes, and the new run is listed and shown.
- [ ] Headless: Cancel ends the process within 1 s.
- [ ] **User (S13):** on a real recording, the UI stays responsive during Recompute.
- **Verify:** the Blender headless suite; the user's check.
- **Depends on:** T21.
- **Files:** `PlaneLab/blender/planelab_blender/{settings,recompute_op,panel}.py`, `PlaneLab/tests/blender/smoke_recompute.py`

#### T23. The remaining operators · S · S10

*File › New › Plane Lab Synthetic Session*, **Export CSV**, the add-on preferences (sessions folder) and, as a *(Should)*, a session browser. One headless test drives every `bpy.ops.planelab.*` operator in sequence.

- [ ] The all-operators headless test passes (S10).
- **Verify:** the Blender headless suite.
- **Depends on:** T14, T22.
- **Files:** `PlaneLab/blender/planelab_blender/{synth_op,export_op,prefs}.py`, `PlaneLab/tests/blender/smoke_all_ops.py`

#### Checkpoint 3: Blender

- [ ] S10–S13 are met, and the Blender headless suite is green.
- [ ] **User:** a real session reviewed end to end in Blender: import, scrub, Recompute and export.

### Phase 4: Field work and docs

#### T24. Field session 1: the `BUILDING_SAMPLE.png` building · E2, E3 · S14 (part)

The user records the building from under 5 m on the iPhone 13, then on the 13 Pro. In Blender:
- **E2:** for each wall, the first frame with an ARKit plane, compared with our first frame.
- The upper-storey points, 8–10 m up.
- **E3:** all four gate modes and `recall.toml`, compared.

- [ ] **User:** E2 per wall and the upper points confirmed by eye.
- [ ] Findings are in `CONSOLIDATION.md` §10b, and `recall.toml` is updated.
- **Depends on:** Checkpoint 3.

#### T25. Field session 2: the open-standoff site · E1 · S14 (part)

The user picks the site (L10) and records from 10–15 m and farther on the iPhone 13. The per-frame point-range p50 / p95 / max show whether points reach past ~10 m.

- [ ] **User:** the range percentiles are read in Blender, and the ~65 m claim is confirmed or not.
- [ ] Findings are in `CONSOLIDATION.md` §10b.
- **Depends on:** Checkpoint 3.

#### T26. Docs pass · S

`ARKit_WallDetection/README.md` and `CLAUDE.md` (the recorder, the PlaneKit rule, the adapter rule from P13), `PlaneLab/README.md` (new), the root `README.md` and `CLAUDE.md`, and this spec's status. It can run alongside T24 and T25.

- [ ] Every doc listed under §13 *Docs* describes the current state.
- **Depends on:** T23.

#### Final checkpoint

- [ ] S1–S14 are met, with device and field items confirmed by the user.
- [ ] `swift test`, the compile check, `pytest` (≥ 85 %), `ruff` and the Blender headless suite are green.
- [ ] **User:** sign-off. The next step, porting the chosen config to PlaneKit (L1), becomes a new request.
