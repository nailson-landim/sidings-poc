# SidingsAR

An iOS proof of concept that shows what **native ARKit plane detection** gives us before we build the Siding Scanner's own geometry pipeline (custom RANSAC, see [`../CONSOLIDATION.md`](../CONSOLIDATION.md) decision D3).

SidingsAR detects wall and floor planes and draws each one from its real outline. It labels planes with their size, removes the duplicate planes ARKit tends to produce, and exposes debug views: anchor markers, feature points, and live memory use.

> **Status (2026-09-25):** v2.1. The user tested it on device ("seems a great starter"). The before/after memory numbers and the LiDAR vs. non-LiDAR comparison haven't been recorded yet (see [Findings](#findings)).

---

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Using the app](#using-the-app)
- [Architecture](#architecture)
- [Plane arbitration: NMS, hysteresis, smoothing](#plane-arbitration-nms-hysteresis-smoothing)
- [Rendering and memory budget](#rendering-and-memory-budget)
- [Project layout](#project-layout)
- [Testing](#testing)
- [Tuning guide](#tuning-guide)
- [Known limitations](#known-limitations)
- [History](#history)
- [Findings](#findings)

---

## Requirements

| | |
|---|---|
| Xcode | 26.x (the project uses Xcode 16+ synchronized folders) |
| Deployment target | iOS 18.0, iPhone only, **locked to Landscape Right** (hold the phone with the charging port on the right). UI orientation doesn't change the recording: ARKit's camera pose and `capturedImage` are always in the sensor's landscape orientation. |
| Language | Swift 6, default actor isolation `MainActor` |
| Device | A physical iPhone with ARKit world tracking. **The Simulator can't run ARKit.** |
| Plane classification | A12 Bionic or newer (`ARPlaneAnchor.isClassificationSupported`). Older devices fall back to "none". |
| LiDAR | Optional. ARKit uses it automatically when present; there's no in-app switch (see [Known limitations](#known-limitations)). |

## Quick start

```bash
# 1. Unit tests: pure Swift, run on the Mac, no device needed
cd PlaneKit && swift test

# 2. Compile check for the app
xcodebuild -project SidingsAR.xcodeproj -scheme SidingsAR \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

To run it:
1. Open `SidingsAR.xcodeproj`.
2. Select the shared **SidingsAR** scheme and a connected iPhone.
3. Run.

Signing is automatic with team `CBA2GU7TYT`; change it under *Signing & Capabilities* if you build with another account. The bundle ID is `br.com.neuralnexgen.sidingsar`.

## Using the app

### Planes on screen

Each detected plane is drawn from its real **boundary polygon** (`ARPlaneGeometry`), at 35% opacity, colored by classification:

| Classification | Color |
|---|---|
| wall | cyan |
| floor | green |
| ceiling | yellow |
| table, seat | orange |
| door, window | purple |
| none | cyan if vertical, white if horizontal |

A plane that loses duplicate suppression is dimmed to 15% opacity and gets no label or markers (see [Plane arbitration](#plane-arbitration-nms-hysteresis-smoothing)).

### Labels

Each visible plane has a screen-space label:

```
48" × 83"  (27.1 ft²)
wall
```

- `W × H` is the plane's **extent** (`planeExtent`, a rotated bounding rectangle), in inches, smoothed.
- `ft²` is the area of the **boundary polygon**, so it's usually smaller than W × H.
- The second line is the classification, when ARKit provides one.

### Magenta markers

| Marker | Meaning |
|---|---|
| Large sphere (2 cm) | Anchor **origin**: `ARAnchor.transform`, fixed while the plane grows |
| Medium sphere (1.2 cm) | Extent **center**: `ARPlaneAnchor.center`, smoothed; moves as the plane extends |
| Small octahedra (6 mm) | **Boundary vertices**: up to 64 per plane |

The gap between the origin and the center shows that ARKit anchors a plane where it was first seen, then grows the extent around it.

### Bottom panel

| Field | Meaning |
|---|---|
| **planes** `kept/raw` | Planes shown after suppression / live ARKit plane anchors |
| **points** | ARKit raw feature points in the current frame |
| **mem MB** | Process physical footprint, refreshed at 1 Hz. The same number as Xcode's memory gauge and the jetsam limit. |
| **fps** | Frames ARKit delivered in the last second. It was about 30 on an iPhone 13 during the first R1 spike, not 60. |
| **tracking** | `normal` / `limited` / `n/a` (details appear in the top banner) |
| **LiDAR** | Whether this device supports scene reconstruction |

- **Control row** (one row, for the landscape layout): the detection picker, Debug, Record/Stop and Reset.
- **Detection picker:** `Vertical` / `Horizontal` / `Both`. Changing it resets the session.
- **Debug menu (ladybug):**
  - Feature points (on by default)
  - Anchor markers
  - Hide duplicates
  - RealityKit render statistics
- **Record / Stop (red):** records a Plane Lab session (`../SPEC.md` §4) into `Documents/Sessions/<yyyyMMdd-HHmmss>.planelab/`: `session.sqlite` (pose, intrinsics, raw feature points and ids for every frame, plus `meta`) and `video.mov` (HEVC, one image per frame). The viewer keeps running.
  - While recording, a red row shows seconds, frames logged, frames dropped (write queue full), frames without an image (pool busy), MB written and free GB.
  - After Stop, one line reports what was saved.
  - Reset, a detection-mode change, pausing, an interruption or a session error stop and save the recording first, with the reason in `meta.stop_reason`.
  - Get sessions onto the Mac with `devicectl` (see `CLAUDE.md`), then run `python -m planelab info <bundle>` (`../PlaneLab/`).
- **Reset:** clears all anchors and tracker state, and restarts tracking.

### Banners and overlays

- **Top banner:** shows limited tracking with a reason (initializing, excessive motion, insufficient features, relocalizing) and session interruptions.
- **Coaching overlay:** Apple's "move your iPhone" guidance, with goal `.anyPlane`.
- **Error alert:** shown on session failure, with a Reset action.

---

## Architecture

```
                     ┌──────────────────────── ARSession (ARKit) ────────────────────────┐
                     │ didAdd / didUpdate anchors     didRemove        didUpdate frame (~60 Hz) │
                     └──────────┬─────────────────────────┬──────────────────┬───────────────┘
                                │                         │                  │
                     ARSessionController                  │                  │
                     ingest(): ARPlaneAnchor ──► PlaneObservation            │
                               tracker.upsert (EMA)       │                  │
                               mark dirty                 │                  │
                                │               remove visuals now           │
                                ▼                         ▼                  ▼
                         ┌─────────────────────── throttled frame tick ───────────────────────┐
                         │ 10 Hz: PlaneTracker.resolve() (NMS + hysteresis)                   │
                         │        render dirty planes + planes whose suppression flipped      │
                         │ 10 Hz: feature-point count   ·   1 Hz: memory footprint            │
                         └──────────────┬──────────────────────────────────────────────────────┘
                                        ▼
                                  PlaneRenderer ──► AnchorEntity per plane
                                   │                 ├─ DynamicMesh fill (replace in place, RebuildGate)
                                   │                 └─ AnchorMarkers (origin, center, boundary mesh)
                                   └─► LabelOverlay (UIKit) ◄── SceneEvents.Update: project every frame
```

There are three cadences:

1. **ARKit anchor callbacks.** These only record what changed: snapshot the anchor, feed the EMA, mark it dirty. Removals take visuals off screen immediately, because that's how ARKit reports plane merges.
2. **Frame tick (10 Hz).** `session(_:didUpdate frame:)` resolves NMS and renders only dirty planes and planes whose suppression flipped. If a plane's geometry change was deferred by its rebuild gate, the plane stays dirty and is retried on the next tick.
3. **Every rendered frame.** Labels are re-projected (`ARView.project`), and those behind the camera or off screen are culled.

The session delegate runs on the main queue. With Swift 6's default `MainActor` isolation, `ARSessionDelegate` is adopted as `@preconcurrency`. The frame is never retained.

The **ARKit ↔ logic boundary** is `PlaneAnchorAdapter`, which converts an `ARPlaneAnchor` into a `PlaneObservation`. Everything behind that boundary lives in `PlaneKit` and only depends on `simd` and Foundation, so it's unit-tested on the Mac.

## Plane arbitration: NMS, hysteresis, smoothing

ARKit often keeps several coplanar, overlapping anchors alive for the same surface, especially without LiDAR. `PlaneTracker` applies **Non-Maximum Suppression**:

1. Two planes **conflict** when all of these hold:
   - same alignment
   - normals within `maxNormalAngleDegrees`
   - plane-to-plane distance within `maxPlaneDistance`
   - convex-hull overlap of at least `minOverlapRatio` of the smaller plane
2. **Score** = polygon area × stability, where stability ramps from 0.5 to 1 over `stableUpdateCount` updates.
3. Greedy NMS: the highest effective score wins; conflicting planes are **suppressed**, meaning dimmed or hidden but **never removed**, because ARKit owns the anchors.
4. **Hysteresis:** the current winner's score is multiplied by `incumbentMargin`. A challenger must beat it for `challengerFrames` consecutive resolves before it takes over. At the 10 Hz resolve cadence, 5 resolves is about 0.5 s.
5. **EMA smoothing** of each plane's world center and extent (factor `emaAlpha`). It snaps instead of blending when the center jumps more than `emaResetDistance`, for example after relocalization.

All parameters are in `PlaneTrackerConfig` (`PlaneKit/Sources/PlaneKit/PlaneTracker.swift`):

| Parameter | Default | Effect |
|---|---|---|
| `maxNormalAngleDegrees` | 10° | Max angle between normals for two planes to count as duplicates |
| `maxPlaneDistance` | 0.08 m | Max separation between the two planes |
| `minOverlapRatio` | 0.3 | Intersection / smaller area |
| `incumbentMargin` | 1.2 | The winner's score bonus |
| `challengerFrames` | 5 | Consecutive wins a challenger needs to take over |
| `stableUpdateCount` | 30 | Updates until a plane counts as fully stable |
| `emaAlpha` | 0.3 | Smoothing factor (higher = snappier) |
| `emaResetDistance` | 0.2 m | Center jump that resets the EMA |

The cost is O(n²) pairs with cheap early rejects: bounding sphere, then normal angle, then plane distance, and only then polygon clipping. With 50 planes, `resolve()` takes about 2 ms in a debug build.

## Rendering and memory budget

In v2.0, memory climbed steadily while scanning. The cause was resource churn in the app itself, not ARKit's anchors. v2.1 follows these rules, and new code should too:

| Rule | Implementation |
|---|---|
| **Never generate a `MeshResource` per update.** Allocate once, update in place. | `DynamicMesh`: `MeshResource.generate(from: Contents)` once, then `replace(with:)` |
| **Rebuild only on real change, at a bounded rate.** | `RebuildGate`: vertex count or area changed by more than 5%, and at least 0.25 s since the last rebuild (1 s for suppressed planes) |
| **No 3D text.** | `LabelOverlay`: UIKit labels projected each frame; the text is updated only when the string changes |
| **Batch many small markers into one mesh.** | `PointMarkerMesh.octahedra`: all boundary vertices of a plane in a single entity |
| **Don't do work for planes nobody sees.** | Suppressed planes get no labels or markers, and their fill rebuilds at 1 Hz |
| **Anchor callbacks mark dirty; the tick does the work.** | `ARSessionController.resolveAndRender`, run at 10 Hz |
| **Share materials.** | One `UnlitMaterial` per color, cached in `PlaneRenderer` |
| **Turn off post-processing we don't use.** | `ARView.renderOptions` disables HDR, depth of field, motion blur, camera grain, grounding shadows, environment lighting, person occlusion and face mesh |

What each rule replaced (v2.0 → v2.1):

- `generateText` plus a background mesh was regenerated on almost every ARKit update, even for hidden labels.
- There was one `ModelEntity` per boundary vertex: up to 64 per plane, dimmed planes included.
- Every fill rebuild created a new `MeshResource` and `ModelComponent`, up to 10 Hz per plane.
- Every anchor callback re-rendered every plane.

**If memory is still too high**, the next options are:
- a smaller `ARWorldTrackingConfiguration.videoFormat` (smaller camera buffer pool)
- a lower `arView.contentScaleFactor`
- pruning long-suppressed tiny anchors with `session.remove(anchor:)` (ARKit keeps every plane anchor it ever created)

## Project layout

```
ARKit_WallDetection/
├── SidingsAR.xcodeproj          Xcode project; SidingsAR/ is a synchronized folder, and PlaneKit is a local package
├── SidingsAR-Info.plist         Info.plist keys Xcode can't generate (UIFileSharingEnabled); merged into the generated one
├── SidingsAR/                   App target
│   ├── SidingsARApp.swift       @main; owns ARSessionController
│   ├── ContentView.swift        ARView container, label layer, coaching overlay, banner, alert
│   ├── HUDView.swift            Bottom panel: stats, detection picker, Debug menu, Reset
│   ├── ARSessionController.swift  ARSession owner + delegate; ingest → tick → resolve → render
│   ├── SessionStatus.swift      DetectionMode, tracking-state texts
│   ├── PlaneAnchorAdapter.swift ARPlaneAnchor → PlaneObservation (the ARKit boundary)
│   ├── PlaneRenderer.swift      AnchorEntity per plane: fill, markers, labels, material cache
│   ├── DynamicMesh.swift        MeshResource allocated once, updated with replace(with:)
│   ├── AnchorMarkers.swift      Origin/center spheres + one boundary-points mesh
│   ├── LabelOverlay.swift       Screen-space UIKit labels
│   ├── PlaneStyle.swift         Colors, opacities, label text
│   ├── MemoryFootprint.swift    phys_footprint for the HUD
│   └── Recording/               Plane Lab recorder glue
│       ├── ARRecordAdapter.swift  ARFrame → FrameRecord (with PlaneAnchorAdapter, the only ARKit → PlaneKit conversions)
│       └── SessionRecorder.swift  Record/Stop, the capture path, HUD stats, meta; SessionWriter does the writing
├── PlaneKit/                    Swift package with no ARKit or RealityKit; tested on the Mac
│   ├── Sources/PlaneKit/
│   │   ├── PlaneObservation.swift  ARKit-free plane snapshot; world normal/center/boundary/area
│   │   ├── PolygonMath.swift       Area, convex hull, Sutherland–Hodgman clipping, projection
│   │   ├── PlaneTracker.swift      NMS + hysteresis + PlaneTrackerConfig
│   │   ├── Smoothing.swift         PlaneSmoother (EMA with jump reset)
│   │   ├── RenderBudget.swift      Throttle, RebuildGate, PointMarkerMesh
│   │   └── Recording/              Plane Lab recorder (../SPEC.md §4), being built
│   │       ├── Constants.swift     RecorderConstants: every recorder setting, written to each session's meta
│   │       ├── Records.swift       FrameRecord, AnchorRecord, LocationRecord, HeadingRecord, EventRecord
│   │       ├── Packing.swift       Little-endian BLOB layouts (matrices, points, ids) with no simd padding
│   │       ├── SessionDatabase.swift  session.sqlite: schema v1 (copy of ../session-format/schema_v1.sql), WAL, seal
│   │       ├── SessionWriter.swift    One recording bundle off the capture thread: batched commits, frame drops, finish
│   │       └── VideoWriter.swift   HEVC video.mov: time = frame index / fps, gaps, fragments, capped pixel pool
│   └── Tests/PlaneKitTests/        Swift Testing suites + fixtures (Recording/ has its own helpers)
├── legacy/                      The original 2018 SceneKit tutorial (reference only, not maintained)
└── tasks/                       plan.md (design) and todo.md (task and checkpoint status)
```

## Testing

`cd PlaneKit && swift test` runs 68 Swift Testing cases in 10 suites:

| Suite | Covers |
|---|---|
| PolygonMath | Area, hull, intersection (none, partial, containment), normal angle, plane distance, overlap ratio, boundary vs. extent fallback, yaw |
| Non-Maximum Suppression | Coplanar duplicates, perpendicular walls, parallel walls 30 cm apart, disjoint coplanar walls, floor vs. table, horizontal vs. vertical, chains of duplicates, removal, a 50-plane timing bound |
| Smoothing & hysteresis | EMA convergence and jump reset, winner stable under ±5% jitter, challenger takeover after the streak, a weak challenger never winning |
| Render budget | Throttle, RebuildGate (first build, unchanged geometry, deferred change, area delta), octahedra counts, index range and outward winding, subsampling |
| Recorder constants | Every `RecorderConstants` property becomes one `const.*` meta row |
| BLOB packing | Column-major little-endian matrices (64 and 36 bytes), 12-byte points, uint64 ids, empty arrays, wrong sizes rejected |
| Session database | Every table round-trips, a sealed session is one file, empty point BLOBs aren't NULL, mismatched points/ids refused, unknown `schema_version` refused |
| Session writer | Batched commits (manual and timer), frame numbers with no holes, a stalled queue dropping whole frames in under 50 ms without blocking, committed batches surviving an unfinished session, finish writing counters and a matching video into a one-file bundle, nothing accepted after finish |
| Session-format contract | The embedded DDL matches `../session-format/schema_v1.sql`; the committed fixture decodes to `expected.json`, and its video holds exactly the `has_image` frames with the right numbers. `PLANELAB_WRITE_FIXTURES=1 swift test --filter writeFixtures` regenerates it |
| Video writer | HEVC timestamps with gaps (including a leading gap), keyframe spacing, frame numbers surviving encoding, a full pool skipping instead of blocking, out-of-order frames, plane-by-plane copy, and a half-written movie readable up to its last fragment. `PLANELAB_SPIKE_OUT=<dir> swift test --filter spikeVideo` writes the 1920 × 1440 spike video for Plane Lab T2 |

Anything that can be expressed without ARKit or RealityKit goes into `PlaneKit`, with tests. The app target has no unit tests; its behavior is checked on device against the checkpoints in `tasks/todo.md`.

## Tuning guide

| Symptom | Adjust |
|---|---|
| Duplicate planes still visible | Raise `maxPlaneDistance` or `maxNormalAngleDegrees`, or lower `minOverlapRatio` |
| Distinct surfaces merged (a recessed door or window hidden by its wall) | Lower `maxPlaneDistance` (typical recesses are 3–10 cm) |
| The winning plane flickers | Raise `incumbentMargin` or `challengerFrames` |
| A clearly better plane takes too long to win | Lower `challengerFrames` |
| Labels or centers lag behind | Raise `emaAlpha` |
| Plane outlines lag while scanning | Lower `PlaneRenderer.visibleRebuildInterval` (costs more mesh updates) |
| Memory still climbs | See the next options in [Rendering and memory budget](#rendering-and-memory-budget) |

Use the `kept/raw` counter and the **Hide duplicates** toggle to judge suppression on device.

## Known limitations

- **No LiDAR switch.** ARKit uses LiDAR for plane detection automatically and has no public API to turn it off. Compare LiDAR and non-LiDAR by running on separate devices.
- **Labels are 2D overlays.** They follow the plane but don't scale with distance and aren't occluded by real geometry. That's the price of the memory savings.
- **Suppression is visual only.** Suppressed anchors stay in the ARKit session and in memory.
- **The NMS thresholds are untuned** and don't yet distinguish recessed openings from their wall.
- **ARKit's plane detection is short-range.** It degrades at the 8–15 m standoff a facade capture needs (see [`../CONSOLIDATION.md`](../CONSOLIDATION.md) §4). This app measures that limit; it doesn't solve it.
- **`legacy/`** targets iOS 11 / Swift 4 and isn't expected to build with current Xcode.

## History

| Version | Change |
|---|---|
| v1 (2018) | SceneKit tutorial ([ambujpunn/ARKit_WallDetection](https://github.com/ambujpunn/ARKit_WallDetection)), vertical planes only. Now in `legacy/`. |
| v2.0 | RealityKit rewrite: vertical and horizontal planes, classification, NMS and hysteresis, EMA, magenta markers, full delegate coverage. See `../REQUEST.md` (Original Request). |
| v2.1 | Feature-points debug view and memory-savvy rendering (Request 2). |

v1 looked "dirty" mainly because of bugs, not ARKit:
- **Double offset:** the child node sat at `anchor.center` and `update()` also moved the parent there, so planes drifted as they grew.
- **Rotation ignored:** `planeExtent.rotationOnYAxis` wasn't used.
- **No `didRemove`:** merged planes never left the screen.
- **Rectangles** were drawn instead of the boundary polygon.
- **No duplicate suppression.**

## Findings

- **Device test (2026-09-25, by the user):** works as a starter for native-ARKit validation. Numbers not recorded yet.
- **Memory:** v2.0 grew steadily during a scan; the causes are listed under [Rendering and memory budget](#rendering-and-memory-budget). The v2.1 before/after number is *to be recorded*: read "mem MB" after about 1 min of scanning the same room.
- **LiDAR vs. non-LiDAR** (iPhone 13 Pro vs. iPhone 13, same room): *to be recorded.*
- **NMS effect:** a "small improvement" by eye so far; not tuned.
- **Recording load, iPhone 13 (Plane Lab spike R1, 2026-09-28, two runs of 96 s and 69 s while charging):**
  - Copying each 1920 × 1440 camera image on the main thread costs p50 0.6 ms and p95 under 1 ms.
  - HEVC encoding dropped 0.15 % of images (pool only) and caused no stutter.
  - **ARKit's format promises 60 fps but delivered a flat 30 Hz,** with thermal state already *serious*.
  - *mem MB* rose from about 300 to 440 in a minute. Whether that comes from the viewer or the recording is still open (Plane Lab Checkpoint 2A).
- **First real recording, iPhone 13 (Plane Lab T7, 2026-09-28, 48 s, thermal *fair*):** a steady **60 Hz** delivered. 2,863 frames were logged with 0 dropped, 7 had no image (0.24 %, mostly while the encoder started), and tracking was 100 % normal. The session was 82 MB/min (16.9 MB SQLite plus 48 MB HEVC). So the 30 Hz in the spike came from heat, not from recording.
