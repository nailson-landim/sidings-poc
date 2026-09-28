# Handoff, 28 Sep 2026: an ARSession recorder on the iPhone, replayed in Blender

*Session wrap-up at `740b402` plus this document. `HANDOFF.md` is the living resume point; this file is the snapshot of the day. Details live in `SPEC.md` (spec §0–16, plan §17, tasks §18 with ticks).*

## In one paragraph

The Plane Lab now works end to end.
- **On the iPhone 13,** SidingsAR records an ARKit session while its plane viewer keeps running: every frame's pose, intrinsics and raw feature points, a full-resolution HEVC video, and every ARKit plane callback.
- **On the Mac,** one command (`PlaneLab/scripts/pull.sh`) pulls the recording, summarizes it, writes a readable SQLite copy and opens it in Blender.
- **In Blender,** the camera follows the recorded path with the video behind it, and the raw points and ARKit's planes sit on the image, frame by frame.

The user checked all of it on device and in Blender: *"the test was flawless! perfect."*

## Resume prompt

> Resume the Plane Lab build from `HANDOFF.md` (and `28_SEP_26-HANDOFF.md` for the full picture of 28 Sep). Read `SPEC.md` §0, §15, §17 and §18, then continue with the first open item under *TODO*. Keep the working agreements.

## Progress

| Phase | Task | Status |
|---|---|---|
| Spec and plan | Spec review answers folded in (L5–L11); 26-task plan written and approved | ✅ |
| 0. Risks | T1 video writer (PlaneKit, tested on the Mac) | ✅ |
| | T2 spike R2: does Blender keep the video in step? | ✅ answered, and scrubbing confirmed by the user |
| | T3 spike R1: can the iPhone 13 record video at 60 fps? | ✅ answered: yes; the 30 Hz came from heat |
| | Checkpoint 0 | ✅ |
| 1. Tracer bullet | T4 schema v1, records, packing, contract fixture | ✅ |
| | T5 session writer (batches, drops, crash safety) | ✅ |
| | T6 Python package, reader, `planelab info` | ✅ |
| | T7 Record/Stop in SidingsAR | ✅ device-checked |
| | T8 Blender extension: import of camera, trail and raw points | ✅ |
| | T9 video behind the camera | ✅ S11 confirmed by the user |
| | Checkpoint 1 | ✅ |
| 2A. Recorder | T11 ARKit plane anchors + Mark button | ✅ device-checked (Mark not yet tapped on a device) |
| | T10, T12, T13 | ⏳ next |
| 2B. Lab core | T14–T20 | ⏳ not started |
| 3. Blender | T21's ARKit-planes layer | ✅ brought forward (P17) |
| | the rest of T21, T22, T23 | ⏳ |
| 4. Field and docs | T24–T26 | ⏳ |

Extras the user asked for along the way:
- the Landscape Right lock
- `planelab peek`, a decoded SQLite copy with every column explained
- `planelab blend`, a ready-to-open `.blend`
- `pull.sh`, the phone → Mac → Blender command
- `HANDOFF.md`

## What we built

### iPhone: SidingsAR (`ARKit_WallDetection/`)

- **Record / Stop** (red) writes `Documents/Sessions/<yyyyMMdd-HHmmss>.planelab/`, which holds `session.sqlite` and `video.mov`, while the plane viewer keeps running.
- **Per frame, inside the ARKit delegate:**
  - the pose, intrinsics, raw feature points and ids, tracking, thermal state and exposure are copied into a record (`ARRecordAdapter`)
  - the camera image is copied into a 4-buffer pool (p95 < 1 ms)
  - both are handed to `SessionWriter`, which never blocks
  - the `ARFrame` isn't kept
- **ARKit planes:** every add, update and remove callback is recorded, stamped with its frame. Planes that already exist when Record is tapped are logged as `add` at frame 0.
- **Mark** adds `mark N` events, which become timeline markers.
- **Stopping:** Reset, a detection-mode change, pause, an interruption or a session error stop and save first, with `stop_reason`.
- **HUD:** a recording row (seconds, frames, dropped, frames without an image, marks, MB, free GB), an always-on **fps** readout, and one control row.
- **Locked to Landscape Right.** Hold the phone with the charging port on the right.
- **Files:** `UIFileSharingEnabled` lives in `SidingsAR-Info.plist`, because Xcode's generated plist drops it. The files can be pulled with `devicectl`.

### PlaneKit recorder core (`PlaneKit/Sources/PlaneKit/Recording/`, tested with `swift test`)

| File | What it does |
|---|---|
| `Constants.swift` | `RecorderConstants`: every recorder setting. Each is written to `meta` as `const.*` through reflection |
| `VideoWriter.swift` | HEVC `video.mov`: time = `idx / 60`, gaps kept, fragmented, keyframes ≤ 30 images apart, a capped pool that skips instead of blocking |
| `Records.swift`, `Packing.swift` | One record type per table; little-endian BLOB layouts with no simd padding |
| `SessionDatabase.swift` | Schema v1 (an embedded copy of the canonical DDL), WAL while recording; `seal()` makes it one file |
| `SessionWriter.swift` | Serial queue, one transaction every 0.5 s, whole-frame drops when the queue is full, `idx` with no holes, `finish()` |

### Format contract (`session-format/`)

- **`schema_v1.sql`** is the one source of the DDL. Swift and Python each embed a copy and test it against this file.
- **`fixtures/v1/tiny.planelab` + `expected.json`**: 10 frames written by the real Swift writer, covering every edge case. Both languages decode it to the same values.

### Mac: Python (`PlaneLab/`, `.venv` on Python 3.11, numpy 1.26.4 like Blender)

| Command or module | What it does |
|---|---|
| `python -m planelab info <bundle>` | Summary: frames, delivered fps, drops, tracking, point range, ARKit planes, site, events |
| `python -m planelab peek <bundle>` | `lab/peek.sqlite`: every BLOB decoded (camera position, angles, intrinsics, points, per-feature stats, anchors), with `_about` explaining each column |
| `python -m planelab blend <bundle>` | `lab/replay.blend`, ready to open, via headless Blender |
| `planelab.session` / `replay` / `axes` / `planes` | Reader (folder or zip); packed per-frame arrays; ARKit → Blender axes, lens and quaternions; ARKit planes over time |
| `scripts/pull.sh` | **iPhone 13 → Mac → Blender** in one command (`--list`, `<name>`, `--all`, `--no-open`, `--force`) |

### Mac: Blender 5.0.1 extension (`PlaneLab/blender/planelab_blender/`)

**File › Import › Plane Lab Session** builds one collection per recording:
- **Camera:** pose, lens and shift keyframed on every frame.
- **Video:** the camera's background, starting at the first frame with an image.
- **Trail:** the whole camera path.
- **Raw points:** yellow, refilled per frame.
- **ARKit planes:** outlines in SidingsAR's colors, per frame.
- **Markers:** one per event.

The extension is linked into the user's Blender as a local repository (the dev loop: **F3 › Reload Scripts** picks up code changes). `scripts/build_extension.sh` builds a standalone zip.

## What we tested

**Automated** (all green at the end of the day):
- `swift test`: **69 tests** in 10 suites. The new ones cover constants, the video writer (timestamps with gaps, keyframes, frame numbers surviving encoding, a full pool, out-of-order frames, a half-written file readable), BLOB packing, the database, the session writer (batching, a stall dropping 80 of 100 frames in < 50 ms, crash safety, finish) and the contract.
- The iOS `xcodebuild` compile check: no new warnings.
- `pytest`: **62 tests**, 98 % coverage, `ruff` clean. They cover:
  - the contract against the Swift-written fixture, the reader, `peek`, the axes, replay and plane timeline, and the CLI
  - **real headless Blender runs:** importing the fixture checks camera poses to 1e-5, lens and shift, points, the trail and markers. Rendering the camera's clip proves frame `idx + 1` shows image `idx`, with gaps held. ARKit planes appear, grow and disappear on the right frames. The zip builds and installs into a throwaway profile.

**On device and by eye** (the user):

| Recording | Where | Result |
|---|---|---|
| Spike R1, runs 1 and 2 | iPhone 13, charging | Copy p95 < 1 ms, 0.15 % images dropped, no stutter. ARKit delivered **30 Hz** at thermal *serious* |
| `20260928-160746` (T7) | Indoors, portrait, 48 s | 2,863 frames at a steady **60 Hz**, 0 dropped, 0.24 % without an image, about 82 MB/min |
| `20260928-174840` | Landscape, 16 s | 978 frames at 60 Hz; roll about 2° (level) |
| `20260928-181436` (T11) | Landscape, 20 s | 1,214 frames at 60 Hz, 0 dropped, **2 ARKit planes** (floor + horizontal), 373 anchor rows |
| S11 in Blender | `replay.blend` | Points sit on the video features across the timeline, and ARKit's planes show; *"flawless"* |

All four recordings are on the Mac in `~/PlaneLab/sessions/`, each with `lab/peek.sqlite` and `lab/replay.blend`.

## Findings worth keeping

These are also in `SPEC.md` §3.4, §15, `CONSOLIDATION.md` §10b and the `CLAUDE.md` files.

1. **ARKit's frame rate follows heat.** The format promises 60 fps; the phone delivered 30 Hz at thermal *serious* and a steady 60 Hz at *fair*. The lab times everything from `ARFrame.timestamp`, and `video_fps` only counts frames.
2. **Blender drops a leading gap in a video but keeps later gaps.** The clip therefore starts at the first frame with an image.
3. **Intrinsics drift with autofocus** (fx 1524.0 → 1527.4 px), so they're recorded and keyframed per frame.
4. **ARKit's estimate of one feature point jitters by about 2.5–3 cm RMS** across its sightings. That's the noise the averaging stage (T16) has to remove.
5. **Every recording loses images at frames 5–9**, most likely while the pixel pool allocates its first buffers. The fix is planned in T10.
6. **Recording everything costs about 82 MB/min** on an iPhone 13 (about 21 MB/min of data, about 60 MB/min of video).
7. **Tooling:**
   - Xcode drops `UIFileSharingEnabled`.
   - Finder can't open app folders; use `devicectl`.
   - `AVAssetReaderTrackOutput` handles the leading gap differently in passthrough and in decoding mode.
   - SQLite leaves `-shm` after leaving WAL.
   - Blender 5.0 has no `Action.fcurves`; use the channelbag API.
   - Loose vertices are invisible in Object Mode, so points are drawn with geometry nodes.
   - Headless renders only follow `frame_set` on the context scene.
   - This Mac's locale uses a decimal comma (use `LC_ALL=C` with `awk`).

## TODO

**Next up** (Phase 2, alternating the tracks):
1. **T10: recorder robustness.**
   - Warm the pixel pool when Record is tapped (finding 5).
   - Tracking-state and interruption `event` rows.
   - Stop when the app goes to the background.
   - Stop below 1 GB free.
   - `RecordingPolicy` unit tests.
2. **T12: permissions and location.** A first-launch screen (Camera, then Location While In Use), plus GPS and compass tables.
3. **T13: Sessions sheet** in the app: list, Share as zip (AirDrop), Delete.
4. **Checkpoint 2A** (device, by the user):
   - A 5-minute run, unplugged and cool, with a 1-minute no-Rec baseline for fps and memory. The spike saw 300 → 440 MB in a minute.
   - A force-quit mid-recording.
   - The same checks on the iPhone 13 Pro.
   - Tap **Mark**, since it hasn't been exercised on a device yet.
5. **Track 2B, the lab core: our own planes** (T14–T20): synthetic sessions, settings, motion gate and accumulator, RANSAC, sequential search and extents, the tracker, then the pipeline, `run` and `export`.
6. **Phase 3:** the rest of T21 (averaged cloud, our planes, per-frame readouts in the panel), T22 settings panel and Recompute, T23 the remaining operators.
7. **Phase 4, field work:**
   - T24: the `BUILDING_SAMPLE.png` building from under 5 m (E2, E3).
   - T25: a second site with an open standoff (E1).
   - T26: a docs pass.

**Small loose ends:**
- The 48 unticked items in `ARKit_WallDetection/tasks/todo.md` belong to earlier SidingsAR work. They aren't touched by Plane Lab (P1).
- ARKit plane updates arrive often: 371 in 20 s for 2 planes. That's fine for size, but worth watching in large rooms.
- The Reload Scripts dev loop is set up in the user's Blender but hasn't been exercised with a code change yet.

## Working agreements

- **Commits:** one per task once green, with the attribution trailer. Never push, never commit recordings.
- **Decisions:** minor ones are logged as P-rows in `SPEC.md` §17.4; product, device and field calls go through AskUserQuestion.
- **Devices:** the user installs from Xcode. Reading files with `devicectl` is fine. Device results are reported only when observed.
- **Docs change with the code.** Notion saves happen only on a yes.

## Quick reference

```bash
PlaneLab/scripts/pull.sh                                  # newest recording: pull, info, peek, blend, open in Blender
cd ARKit_WallDetection/PlaneKit && swift test             # 69 tests
cd PlaneLab && source .venv/bin/activate && pytest        # 62 tests, including headless Blender
```

Today's commits, oldest first:
- **Phase 0:** `3f55bae` T1, `8321164` T2, `003c4a4` `f6ad4e6` `14cba09` T3 and Checkpoint 0
- **Phase 1:** `899292c` T4, `8686b42` T5, `08f55cb` T6, `e90e034` `16faef2` T7, `413a734` T8, `f788539` T9, `ac34cae` Checkpoint 1
- **T11 and ARKit planes:** `32fb327`, `12a525c`
- **Tools and fixes:** `657eb47` HANDOFF, `3daa140` landscape lock, `969f0db` scrub file, `bc18500` peek, `167203f` replay script, `740b402` pull.sh
