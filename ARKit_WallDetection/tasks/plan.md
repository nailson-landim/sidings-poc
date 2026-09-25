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
