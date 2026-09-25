# Implementation Plan: ARKit Plane PoC v2 (RealityKit)

*Created 2026-09-25. Source request: `../REQUEST.md`. Context: `../CONSOLIDATION.md`.*

## Overview

Rebuild the 2018 SceneKit wall-detection tutorial app as a small RealityKit PoC. The goal is to check fast what native ARKit plane detection gives us before we invest in our own RANSAC (CONSOLIDATION D3). The PoC covers:

- vertical and horizontal `ARPlaneAnchor`s, drawn with their real boundary polygon, dimensions and classification
- the full anchor lifecycle (add, update, remove/merge), plus session and tracking delegates
- **Non-Maximum Suppression (NMS)** to hide duplicate or colliding planes, plus temporal smoothing and hysteresis so the result doesn't flicker
- magenta debug spheres for the anchor origin, the plane center and the boundary vertices

Descoped: the LiDAR on/off toggle. ARKit has no public switch for it, and plane detection uses LiDAR automatically. We'll compare LiDAR and non-LiDAR phones by testing on separate devices.

## Why the current app looks "dirty" (root causes found in code)

1. **Double offset:** `Grid.setup()` puts the child `planeNode` at `anchor.center`, and `Grid.update()` also moves the parent `Grid` node to `anchor.center`. Planes drift away from the real wall as they grow.
2. **Rotation ignored:** since iOS 16 the extent can be rotated inside the anchor (`planeExtent.rotationOnYAxis`). The code uses the deprecated axis-aligned `extent`, so rectangles come out skewed.
3. **No `didRemove`:** when ARKit merges two planes it removes the absorbed anchor. The `grids` array keeps stale entries and never drops them.
4. **Rectangles, not shapes:** `ARPlaneGeometry` (the boundary polygon) is never used, so a bounding rectangle over-covers the plane.
5. **No arbitration:** ARKit often keeps several coplanar or overlapping anchors alive, especially without LiDAR. Nothing suppresses them.
6. A physics body is re-created on every update, which is wasted work.

## Architecture Decisions

- **RealityKit `ARView` + SwiftUI**, iOS 18 deployment target, Swift 6, Xcode 26. `ARView` still exposes `ARSession` and its delegate. `RealityView` on iOS doesn't give full ARKit anchor control yet, so we use `ARView` inside `UIViewRepresentable`.
- **A new Xcode project with a *synchronized folder* group** (Xcode 16+), so adding files needs no `pbxproj` edits. The old project moves to `legacy/` for reference and gets deleted later.
- **Pure logic lives in a local Swift package `PlaneKit`** (no ARKit or RealityKit imports): the `PlaneObservation` value type, polygon math, NMS and smoothing. It's unit-tested with `swift test` on the Mac, with no device needed. Tests stay on disk.
- **Wiring:** ARKit anchor → `PlaneObservation` (adapter in the app) → `PlaneTracker` (PlaneKit: NMS + smoothing + hysteresis) → render state per anchor ID (`visible`/`suppressed`, smoothed pose/extent) → `PlaneRenderer` (RealityKit entities).
- **Rendering:** one `AnchorEntity(anchor:)` per `ARPlaneAnchor`. Its children are a mesh built from the `ARPlaneGeometry` boundary with `MeshDescriptor`, a label (`MeshResource.generateText`) and marker spheres. Meshes are rebuilt only when the geometry changes by more than a threshold, at most about 10 Hz per plane.
- **NMS definition:** candidates are grouped by alignment. Two planes *conflict* when all three hold:
  - normals within about 10°
  - plane-to-plane distance under about 8 cm
  - the overlap of their polygons projected onto the dominant plane is at least 0.3 of the smaller one's area

  Score = area × stability (age, and low extent variance). The highest score wins and the losers are *suppressed*, meaning hidden or dimmed but never deleted, because ARKit owns the anchors. All thresholds live in one `PlaneTrackerConfig`.
- **Smoothing:** an exponential moving average (EMA) on the rendered center, extent and yaw per anchor. **Hysteresis** keeps an NMS winner until a challenger beats it by more than 20% for at least N frames, so winners don't flip back and forth.
- **Colors:**
  - vertical planes: cyan
  - horizontal planes by classification: floor green, ceiling yellow, table/seat orange, other white
  - suppressed planes: 15% opacity (or hidden, via the HUD toggle)
  - markers: magenta, with a big sphere for the origin, a medium one for the center and small ones for boundary vertices

## Delegate audit (what we will implement)

| Delegate | Now | Plan |
|---|---|---|
| `session(_:didAdd:)` | ✅ (via SCN renderer) | ✅ create entity + observation |
| `session(_:didUpdate: [ARAnchor])` | ✅ partial | ✅ update geometry, re-run tracker |
| `session(_:didRemove:)` | ❌ | ✅ drop entity; this is how ARKit reports merges |
| `session(_:didUpdate frame:)` | ❌ | ✅ throttled: HUD (feature points, FPS) and tracker tick for hysteresis |
| `session(_:cameraDidChangeTrackingState:)` | ❌ | ✅ HUD banner (limited: excessive motion, insufficient features, relocalizing) |
| `sessionWasInterrupted` / `InterruptionEnded` | stubs | ✅ banner; offer a reset |
| `sessionShouldAttemptRelocalization` | ❌ | ✅ return true |
| `session(_:didFailWithError:)` | stub | ✅ log + alert |
| `ARCoachingOverlayView` | ❌ | ✅ goal `.anyPlane` |

## Dependency graph

```
T1 App skeleton (RealityKit, vertical planes, full lifecycle)
 ├── T2 PlaneKit package + PlaneObservation + tests
 │     ├── T5 NMS (pure + wired)
 │     │     └── T6 Smoothing + hysteresis
 ├── T3 Magenta markers
 └── T4 Horizontal planes + classification
T7 Session/tracking delegates + HUD   (depends on T1 only)
T8 Docs                               (last)
```

## Task List

Full detail is in `tasks/todo.md`.

### Phase 1: Foundation
- [ ] T1: RealityKit skeleton that renders vertical planes correctly, with the full add/update/remove lifecycle
- [ ] T2: `PlaneKit` package: `PlaneObservation` + polygon math + tests

### Checkpoint A
- [ ] App builds and runs on device; walls line up with the real walls (the double-offset and rotation bugs are gone)
- [ ] `swift test` passes in `PlaneKit`

### Phase 2: Core features
- [ ] T3: Magenta markers (origin, center, boundary vertices) with a toggle
- [ ] T4: Horizontal planes + classification colors + labels
- [ ] T5: Non-Maximum Suppression
- [ ] T6: EMA smoothing + winner hysteresis

### Checkpoint B
- [ ] On the same room as `AR_APP.PNG`: visible planes ≤ real surfaces + 1, no stacked labels
- [ ] Side-by-side run on a LiDAR and a non-LiDAR phone; notes recorded

### Phase 3: Polish
- [ ] T7: Session and tracking delegates, coaching overlay, HUD, reset
- [ ] T8: README / CLAUDE.md with findings

### Checkpoint C
- [ ] All acceptance criteria met; findings documented

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Rebuilding `MeshResource` on every update drops FPS | Med | Throttle per plane (≤10 Hz) and rebuild only on vertex-count or area change above 5% |
| NMS thresholds wrong for large facades vs. small interior planes | Med | All thresholds in `PlaneTrackerConfig`; HUD shows raw vs. kept counts; tune on device |
| `ARView` (UIKit-backed) deprecated in favor of `RealityView` later | Low | PoC only. Rendering is isolated in `PlaneRenderer` |
| Classification unavailable on old devices (needs A12+) | Low | Fall back to `.none` → neutral color |
| Non-LiDAR planes remain weak whatever we do | High (for product) | This is the finding we want. It feeds CONSOLIDATION D3 (own RANSAC) |
| Swift 6 strict concurrency friction with ARSession delegate callbacks | Low | Delegate is `@MainActor`-isolated with `nonisolated` hops; delegate queue set to main |

## Open Questions

- Should suppressed planes be **hidden** or **dimmed** by default? The plan dims them and adds a HUD toggle.
- Should the NMS winner absorb the losers' extents (a union, like a "wall" entity), or just win? The plan says just win; a union is a follow-up.

---

## Experiment X2 (2026-10-02): RANSAC live on the phone, with timings

Branch `exp/x2-ransac`, kept for history and **not merged**. The design is `../../EXPERIMENTS.md` *X2* (XD12); the scope changes of this round are XD14–XD18 there.

**Goal.** Run our RANSAC (vertical and horizontal priors, range-scaled MSAC band, NAPSAC and PROSAC sampling, lazy scoring, LO refit, connected pieces, robust extents, slice merging) on the phone's live averaged cloud, tracked by the X1 tracker, and **measure its compute cost on the device**. Field feedback loop: record on site, `pull.sh`, replay and compare in Blender.

**Decisions with the user (2026-10-02).** RANSAC replaces X1 in the UI (X1's code stays, and old recordings still replay). Swift only: no Python RANSAC on this branch (T17–T20 stay open on `main`).

**Shape.**
- `PlaneKit/Ransac/PlaneSearch`: the pure search (points, per-point band, claimed mask → planes with inliers). Mac-testable.
- `RansacScanner`: a round = refit tracked planes, then discover on unclaimed points, split into connected pieces, feed the X1 `SurfaceTracker`. Same `round(cloud:camera:)` shape as `SurfaceScanner`, behind a small `SurfaceEngine` protocol so `LiveSurfaces`, the recorder and the renderer are reused.
- Timings: every round reports its stage times and counters; recordings get a `surface_round` table (schema v4).
- SidingsAR: RANSAC dials, HUD timing stats (last, mean, p95, max), a *Benchmark on live cloud* action.
- Blender: the planes layer says which engine drew it; per-round stats become animated properties on an empty (Graph Editor shows compute ms over the timeline) plus a readout at the current frame.

---

## Experiment X3 (planned 2026-10-02): measure walls from the images, not from the ARKit cloud

Status: **plan, nothing built, not yet approved.** Why: `../../EXPERIMENTS.md` *X2 field test 1* and XD19. Branch from `main` as `exp/x3-image-geometry` (`exp/x2-ransac` stays as history).

**What the field test showed.** Our RANSAC runs in 6 ms on an iPhone 13 and finds the right orientations, but the phone's averaged cloud is a 30–60 cm thick slab around each wall, so planes fitted to it churn (62 tracks for 3–4 surfaces) and the wall's position is only as good as the slab is thick. With area ∝ distance², an offset error e at range d costs about 2e/d of area. The cloud is therefore a good *prior* (global yaw, rough wall offsets, ground height) and a poor *measurement*.

**Idea.** Take the walls from the pictures. Each recording already holds 4032 × 3024 stills and 1440p60 video with ARKit poses (D1 kept: poses are taken as given). Triangulating the same wall edge, corner or siding course from two stills 3 m apart at 8 m gives about 0.7 cm of depth per pixel of matching error (σ_z ≈ z² σ / (f B), f ≈ 3035 px for the 4032-wide stills). That is a back-of-envelope figure; pose drift (about 1 % of the walk) will dominate, and X3.1 measures it. The takeoff is then: wall and opening masks in the stills (D6) back-projected onto the wall plane through the poses, fused over views.

**Principle.** RANSAC is not wrong, the input is. On a clean cloud a plain robust or Manhattan fit is probably enough, so X2's `PlaneSearch` and `ConnectedPieces` may come back as a small step on better data. The first thing that is missing is not code but **ground truth**: no facade measured with a tape yet, so no approach can claim ±5 %.

**Steps and gates** (a gate that fails stops the line and we say so):

| Step | What | Gate |
|---|---|---|
| X3.0 | One facade with ground truth: wall width and height, window and door sizes, siding course spacing, by tape or laser, plus a hand takeoff. Record it with a lateral sweep of 3–4 m at two standoffs (about 8 m and about 12 m). | The numbers are written down and the recording is pulled. |
| X3.1 | T33 on the Linux box: COLMAP on the stills with ARKit poses frozen (`PACK.md` §5). Report reprojection error, then the SfM points against the phone's cloud per distance band. | Reprojection error under about 1 px, and the wall's point slab at 5–8 m is at most about 8 cm thick (ARKit cloud: 30–60 cm). If not, stop and re-plan. |
| X3.2 | Plane per wall from the SfM points: yaw from a global scan, offset from the peak, extents from the mask (X3.3), not from the points. | Against the tape: yaw within 1°, offset within 5 cm at 6 m. |
| X3.3 | Masks: the YOLOv8-seg model (D6) plus a wall/siding class on the stills; back-project to the wall plane; fuse across views; subtract openings. | Wall area within ±5 % of the tape number, on the X3.0 facade, at both standoffs. |
| X3.4 | Only if X3.1 or X3.3 leaves gaps (smooth siding with few matches): monocular metric depth (D5) scaled to the SfM points. | Per-wall area gap closed, or the gap stated. |
| X3.5 | Calibrated margin of error (D4): per-wall features (baseline, standoff, coverage of the mask by at least 2 views, siding-spacing scale check, tracking history) into a regressor. Needs several houses. | Stated ±X % holds about 95 % of the time on held-out walls. |
| X3.6 | What runs on the phone: probably capture-time guidance (baseline and coverage meter, still cadence), with the measurement offline. This revisits **D3 (real-time RANSAC)**, which is the user's decision. | The user's call. |

**Risks.**
- Smooth or repetitive siding gives few or ambiguous matches in COLMAP. Known poses let us guide matching along epipolar lines; X3.1 shows how bad it is.
- Pose drift (D1) sets a floor: about 1 % scale error is 2 % of area. Siding course spacing is a free scale check (`../../CONSOLIDATION.md` §6).
- One facade proves nothing statistical. X3.5 needs houses; X3.0 to X3.3 only decide whether the line is alive.
- The LiDAR path (13 Pro) stops at about 5 m, so it doesn't help at 8–15 m.

**Keep from X2.** The recorder and schema v4 (`surface_round` timings), the Blender layers and `PlaneLab/scripts/report_figures.py`. Nothing in X3 depends on the X2 engine.
