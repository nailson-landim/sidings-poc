# HANDOFF: Plane Lab build


**Day wrap-up: [`28_SEP_26-HANDOFF.md`](28_SEP_26-HANDOFF.md)** has everything built, tested and found on 28 Sep, plus the full TODO.
*Last updated 2026-09-30 after the scope review (P28). Read this first when resuming; `SPEC.md` has the full detail.*

## Resume prompt

Paste this into a new session:

> Resume the Plane Lab build from `HANDOFF.md` and implement everything still open, task by task: T17 → T18 → T19 → T20, Checkpoint 2B, T21 → T22 → T23 (the full Blender spec), Checkpoint 3, then T26. Read HANDOFF.md, then `SPEC.md` §0, §5, §6, §13, §17.4 (up to P28) and §18. Keep the working agreements in HANDOFF.md. Ask me with AskUserQuestion whenever a call is mine.

*(Written 2026-09-30 for a clean context; the longer version the user copied is in that day's session.)*

## Where things stand

`SPEC.md` is the single source for this work: spec §0–16, plan §17, tasks §18 with checkboxes. The spec and the plan were approved on 2026-09-28, and every §16 question is closed.

| Task | Status | Commit |
|---|---|---|
| T1 Video writer (PlaneKit) | Done | `3f55bae` |
| T2 Spike R2: Blender video alignment | Done. **User scrub check still open** (doesn't block anything) | `8321164` |
| T3 Spike R1: iPhone 13 load | Done, closed by the user | `003c4a4`, `f6ad4e6`, `14cba09` |
| Checkpoint 0 | Passed | `14cba09` |
| T4 Schema v1, records, packing, contract fixture | Done | `899292c` |
| T5 Session writer | Done | `8686b42` |
| T6 Python package, reader, `planelab info` | Done | `08f55cb` |
| T7 Record/Stop in SidingsAR | Done. The user's recording `20260928-160746`: 2,863 frames at 60 Hz, 0 dropped, 0.24 % without an image | `e90e034` + docs commit |
| T8 Blender extension and import (camera, trail, raw points) | Done (headless). The Reload Scripts dev loop waits for the user's OK to add a local repository | this commit |
| T9 Video behind the camera | Done, S11 confirmed by the user | `f788539` |
| Checkpoint 1 | **Passed** (user, 2026-09-28): S11 holds, points sit on the video. The user linked `PlaneLab/blender/` as a local extension repository | — |
| T11 ARKit anchors + Mark | **Closed** (user, 2026-09-30). Device-checked on 2026-09-28; Mark on a device waived | `32fb327`, `12a525c` |
| T10 Stop reasons, events, low disk, startup images | **Closed** (user, 2026-09-30: done or solved; Reset check waived). Startup images still missing but under S2's 1 %: 6 of 6,901 on `20260930-102759` | `f48458f` |
| T14 Synthetic sessions | Done (2026-09-29) | this commit |
| T15 LabConfig and presets | Done (2026-09-29) | this commit |
| T16 Filter, motion gate, accumulator | Done (2026-09-29). It matches a line-by-line port of CurvSurf's Swift. On real recordings, `upstream` = `off` (every frame) | this commit |
| Averaged cloud in Blender (T21 part, P19) | Done (2026-09-29): `planelab.cloud` plus an *averaged cloud* layer that grows over the timeline, colored by samples (pink, magenta, red), cached in `lab/cloud-<hash>.npz`. **User check open:** rerun `pull.sh 20260929-161400` (or `planelab blend`), F3 › Reload Scripts, scrub | this commit |
| **L12 (2026-09-29): CurvSurf's accumulator on the phone, live and recorded** | The user chose "Live cloud + record it". Phase 2C in SPEC §18: T27 Swift accumulator, T28 live cloud in SidingsAR, T29 record it (schema v2), T30 the phone's cloud in Blender | — |
| T27 Swift accumulator (PlaneKit `Cloud/`) | Done (2026-09-29): matches the Python golden (`session-format/fixtures/cloud/golden.json`) to 4.8e-7 m; 0.055 ms per frame; PlaneKit built `-O` in Debug (P26) | this commit |
| T28 Live cloud in SidingsAR | **Done** (user, 2026-09-30): the cloud grows; *mem MB* tops out at about 400 MB; 60.0 fps delivered | this commit |
| T29 Record the cloud: schema v2 | Done (2026-09-29): `cloud` table, v2 fixture (v1 kept and still read on both sides), `info`/`peek` show the phone's cloud | this commit |
| T30 The phone's cloud in Blender + equality check | **Done** (2026-09-30): `20260930-102759` equal, 1151/1151 rows, 0.0010 mm; the user confirmed Blender. Checkpoint 2C passed (cloud rows 2.2 MB/min) | this commit |
| **P27 (2026-09-30): Pick Point and bigger dots** | Code done. The Plane Lab sidebar tab (*Points*) has **Pick Point**: click a dot, and a marker follows that feature id while the tab shows its raw and averaged coordinates (ARKit and Blender), samples, frames seen and distance. Dots are twice as big, with a size slider per layer. On `20260930-102759` a pick takes 0.5 ms and a frame change 1.2 ms. `replay.blend` has been rebuilt. **User check open:** F3 › Reload Scripts, N › Plane Lab, Pick Point, click a dot, scrub | this commit |
| T12 Permissions and GPS · T13 Sessions sheet | T12 **deferred** (user, 2026-09-30: GPS not needed for now, L9). T13 **closed** (`pull.sh` gets recordings off the phone). No code for either | — |
| Checkpoint 2A | **Waived** (user, 2026-09-30) with the recorder tasks | — |
| T24 Field session 1 (building) | **Recorded** (user, 2026-09-30): `20260929-172952` and `20260930-102759`, iPhone 13. The E2/E3 comparison waits for our planes (T21) | — |
| **T31 High-resolution stills (P29, 2026-09-30)** | **Done, device-checked.** Full-sensor JPEGs (4032 × 3024) with ARKit poses in `stills/` while recording. First run `20260930-171700`: 123 stills, all blurred (exposure 9.4 ms) | `508167d` |
| **T32 Exposure cap (P30, 2026-09-30)** | **Done, device-checked** (user: "It made the deal"). `20260930-174033`: ARKit shares the camera, 0.99 ms at ISO 500–1250, predicted blur 1.8 px median, tracking 100 % normal | `e4f388d` |
| **T33 SfM on the stills (COLMAP)** | Not started. Runs on the NVIDIA Linux box: see `PACK.md` | — |
| T17–T23, T25, T26 | Not started. T21's ARKit-planes (P17) and averaged-cloud (P19) layers are already done. Next: T17 | — |

The checks were green at `e90e034`:
- `swift test`: 68 tests in 10 suites.
- The iOS `xcodebuild` compile check: no new warnings. The AppIntents metadata notice is Xcode's own and pre-existing.
- `pytest`: 29 tests, 98 % coverage.
- `ruff`: clean.

## Waiting on the user

1. **T2 scrub check.** The user opens `~/PlaneLab/spikes/r2/r2_scrub.blend`, presses Numpad 0 to look through the camera, and scrubs and plays. They say whether it feels responsive.
2. **P27 pick check.** In `20260930-102759`'s `replay.blend`, the user runs Pick Point on a few dots, in camera view and in a free view. The marker should land on the clicked dot, and the dot sizes and sliders should feel right. Headless tests can't drive the viewport's `perspective_matrix` or a modal click.

## Next steps for Claude

**Moving to the Linux box (2026-09-30):** `PACK.md` says what to copy, what runs where, and how to resume. The next session there starts with **T33** (COLMAP on `20260930-174033`'s stills). The Plane Lab main line below continues after it, on either machine (Python work runs on both; the iOS app only on the Mac).

Scope agreed with the user on 2026-09-30 (SPEC §17.4 P28): the recorder is closed, and the whole Blender spec (T21–T23) stays in. In order:
1. **T17: RANSAC plane models** (vertical, horizontal and free), with the least-squares refit, the range-scaled τ and collinear rejection.
2. **T18: sequential search and extents.**
3. **T19: plane tracker.**
4. **T20: pipeline, `results.sqlite`, `run` and `export`.** Fit on the phone's cloud when the run's cloud settings match the recording's, else recompute (P28). Watch S9: ~1,150 fits on a 10k-point cloud for 116 s of recording.
5. **Checkpoint 2B**, then **T21, T22 and T23** in full, then Checkpoint 3.
6. **T24 analysis** on `20260929-172952` and `20260930-102759` (E2 per wall, E3), **T25** when the user records the far site, then **T26** and the final checkpoint.

## Facts learned the hard way

Each one is also recorded where it belongs.

- **ARKit's rate on the iPhone 13 follows heat.** It promises 60 fps, delivered a flat 30 Hz at thermal *serious* (charging, spike runs) and a steady 60 Hz at *fair* (T7). Also in `CONSOLIDATION.md` §10b. `video_fps` is only a frame counter (PTS = `idx / 60`), and Blender's playback rate comes from `frame.t`. Re-check 60 Hz, heat and memory at Checkpoint 2A with an unplugged, cool phone and a 1-minute no-Rec baseline. (§3.4, §15 R1)
- **Blender drops a leading gap in the video but keeps later ones.** Place the clip at the first image. Random access costs about 50 ms of decoding; no proxies are needed. (§15 R2, `PlaneLab/spikes/README.md`)
- **Keyframes are capped at 30 encoded images, not 0.5 s of time.** Skipped images stretch the time between keyframes. (§3.4)
- **AVAssetReaderTrackOutput** reports media time in passthrough (it ignores the leading empty edit). When decoding, it applies the edit and adds an extra blank frame. `VideoProbe` handles both. (`ARKit_WallDetection/CLAUDE.md`)
- **SQLite:** `SessionDatabase.seal()` closes the database and deletes the stray `-shm` file, so a sealed session is one file. Empty BLOBs are bound with `sqlite3_bind_zeroblob`, never a nil pointer.
- **Xcode's generated Info.plist silently drops `UIFileSharingEnabled`.** It lives in `ARKit_WallDetection/SidingsAR-Info.plist`.
- **Finder's Files tab can't open an app's folders.** Pull files with `devicectl` instead (below).
- **Blender headless:** renders only follow `frame_set` on the *context* scene.
- **The first real recording** (`peek`): intrinsics drift with autofocus (fx 1524.0 → 1527.4); a feature id's position jitters about 2.5–3 cm RMS; startup lost images for frames 5–9 plus a 50 ms gap at frame 10. Warming the pool at Record is a T10 follow-up.
- **The Plane Lab extension can be off in the user's Blender** (found 2026-09-29: the repository was registered, the add-on unticked). Then nothing refreshes and layers show whatever was saved. Check Edit › Preferences › Add-ons first when "nothing shows".
- **Blender point clouds carry one material.** Set Material ignores its selection on a point cloud, so a per-point color needs one point cloud per color (joined as instances), not one cloud with a material index.
- **Outdoors** (`20260929-075854`): points to 15.9 m but about 30 cm spread past 10 m; ARKit classified every horizontal plane "seat". Recordings made before the T10 install (all four so far) can't check T10.
- **Stills need a short exposure more than resolution** (P30). ARKit's auto exposure chose 9.4 ms at ISO 80 in the late afternoon, which blurred every still at walking pace; `ExposureControl` caps it (1 ms by default) through the camera ARKit shares, and ISO rises instead. The morning run's exposure was 0.12 ms, so light decides how much this matters.
- **`pull.sh` copies folders inside a recording** (`stills/` arrived whole).
- **This Mac's locale uses a decimal comma.** Run `awk` over `ffprobe` output with `LC_ALL=C`.

## Working agreements (from the user)

- **Commits:** one per task once its checks are green, with the attribution trailer. Don't ask each time (P14). Never push, and never commit recordings. `*.planelab` is ignored except the contract fixture.
- **Decisions:** minor ones are Claude's to make, logged in `SPEC.md` §17.4 (P-rows) with a date and reason. Use AskUserQuestion for product, scope, device and field calls. The user asks for AskUserQuestion in every session.
- **Devices:** ask before installing. The user installs from Xcode. Reading files with `devicectl` is fine. Never report device results that weren't observed.
- **Spec reviews:** the user annotates `SPEC.md` inline (`USER_ANSWER`, `USER_QUESTION`, `Answer:`, `LAST QUESTION`). Answer each one, then fold it into the spec and remove the markers.
- **Docs change with the code:** the README of the part touched, the relevant `CLAUDE.md`, `SPEC.md` ticks and results, and `CONSOLIDATION.md` §10b for ARKit findings.
- **Notion:** offer to save findings to *LLM Session Memories* and save only on a yes. This session's page is "Plane Lab: spec approved, 26-task plan, and T1 …".
- **Global rules** (`~/.claude/CLAUDE.md`):
  - Python: a `.venv`, pinned requirements, ruff, strict type hints, frozen slotted dataclasses, `logging` with a silent log file.
  - Tests stay on disk.

## Commands

```bash
# Swift
cd ARKit_WallDetection/PlaneKit && swift test
xcodebuild -project ARKit_WallDetection/SidingsAR.xcodeproj -scheme SidingsAR \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build

# Python
cd PlaneLab && source .venv/bin/activate
ruff check . && ruff format --check . && pytest --cov=planelab --cov-fail-under=85
python -m planelab info <bundle>

# Pull the newest recording from the iPhone 13 and open it in Blender (info, peek and blend included): PlaneLab/scripts/pull.sh
# (--list, <name>, --all, --no-open, --force; the manual devicectl steps are in the root README, "Recordings: phone → Mac")
# See everything in one: python -m planelab peek <bundle>  -> <bundle>/lab/peek.sqlite (decoded; _about explains columns)
# (iPhone 13 UDID 782F0FCC-0A00-5F6F-82AE-AC575194E5CA; a 13 Pro is also paired: `xcrun devicectl list devices`)

# Regenerate the contract fixture (only after a deliberate format change + schema_version bump)
cd ARKit_WallDetection/PlaneKit && PLANELAB_WRITE_FIXTURES=1 swift test --filter writeFixtures

# R2 spike
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python-exit-code 1 \
  --python PlaneLab/spikes/r2_video_alignment.py -- ~/PlaneLab/spikes/r2/spike.mov ~/PlaneLab/spikes/r2/spike_frames.json
```

Blender 5.0.1's `sys.executable` is `/Applications/Blender.app/Contents/Resources/5.0/python/bin/python3.11`. It runs the core standalone (numpy 1.26.4, `tomllib`).

## Outside the repo

| Path | What |
|---|---|
| `~/PlaneLab/spikes/r1/` | Both R1 runs from the iPhone 13 (`.mov` + `.json` with timelines) |
| `~/PlaneLab/spikes/r2/` | The R2 spike video, manifest, report and `r2_scrub.blend` |
| `~/PlaneLab/sessions/` | Real recordings on the Mac. `20260928-160746.planelab`: the T7 recording (48 s indoors, iPhone 13, 60 Hz) |
| `~/PlaneLab/logs/planelab.log` | Python log |
| `~/.claude/projects/-Volumes-512G-Developer-beam-sidings-poc/memory/` | Claude memories: working preferences |
| `ARKit_WallDetection/tasks/` | Earlier SidingsAR plan, with 48 unticked items from other work. Not touched by Plane Lab (P1) |
