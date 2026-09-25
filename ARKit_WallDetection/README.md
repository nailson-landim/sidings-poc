# SidingsAR: ARKit plane PoC (v2, RealityKit)

This app shows how far **native ARKit plane detection** gets us before we build our own RANSAC (see `../CONSOLIDATION.md`, D3).
It started from the 2018 SceneKit tutorial ([ambujpunn/ARKit_WallDetection](https://github.com/ambujpunn/ARKit_WallDetection)); that code is kept in `legacy/` for reference.

## What it does

- Detects **vertical, horizontal or both** kinds of `ARPlaneAnchor` (HUD picker; each change resets the session).
- Draws each plane from its real **boundary polygon** (`ARPlaneGeometry`), colored by classification:
  - wall: cyan
  - floor: green
  - ceiling: yellow
  - table/seat: orange
  - door/window: purple
  - none: white
- Each plane gets a screen-space label: `W" × H"  (ft²)` plus its classification. Labels are UIKit views projected every frame, not 3D text meshes.
- **Non-Maximum Suppression** over duplicate planes (same alignment, normals ≤10° apart, ≤8 cm apart, overlap ≥30% of the smaller one). The winner is the plane with the highest area × stability score. Losers are dimmed, or hidden with **Hide dupes**. The HUD shows `kept/raw`.
- **Hysteresis:** the current winner gets a ×1.2 score margin. A challenger has to out-score it for 5 consecutive resolves before it takes over.
- **EMA smoothing** (α 0.3) of the label and center position, reset on jumps over 20 cm (relocalization).
- **Magenta markers:**
  - big sphere = anchor origin (`transform`)
  - medium sphere = extent center (`center`, smoothed)
  - small octahedra = boundary vertices (up to 64 per plane, baked into one mesh)
- **Debug menu** (ladybug button):
  - ARKit **feature points** (on by default)
  - anchor markers
  - hide duplicates
  - RealityKit render statistics
- **HUD:** kept/raw planes, feature-point count, **process memory (MB, same number as Xcode's gauge)**, tracking state, LiDAR yes/no.
- Full session delegate coverage: add, update and remove (ARKit reports merges as removals), a throttled frame tick, tracking-state banner, interruption begin/end, relocalization, error alert, coaching overlay and a Reset button.

## Why v1 looked "dirty"

`Grid.update` moved the parent node to `anchor.center` while the child was already offset by it. That double offset grew with the plane. v1 also:
- ignored `planeExtent.rotationOnYAxis`
- never handled `didRemove`, so merged planes stayed on screen
- drew rectangles instead of the boundary polygon
- had nothing to suppress ARKit's coplanar duplicates

## Memory budget (Request 2)

v2.0 memory climbed steadily while scanning. The causes, and what v2.1 does instead:

| Cause in v2.0 | v2.1 |
|---|---|
| `MeshResource.generateText` + background mesh regenerated whenever the rounded size changed (nearly every ARKit update, even for dimmed duplicates) | UIKit labels projected per frame (`LabelOverlay`); the text changes only when the string does |
| One `ModelEntity` per boundary vertex (up to 64 per plane, dimmed planes included) | All boundary vertices of a plane in **one** octahedra mesh (`PointMarkerMesh`); no markers or labels for suppressed planes |
| New `MeshResource` + `ModelComponent` per fill rebuild (up to 10 Hz per plane) | One `MeshResource` per plane updated in place with `replace(with:)` (`DynamicMesh`); rebuilds only on real change (`RebuildGate`), at most 4 Hz visible / 1 Hz suppressed; materials cached per color |
| `renderAll()` on every anchor callback (every plane, 60 Hz) | Callbacks only mark planes dirty. A 10 Hz frame tick resolves NMS and renders dirty planes plus planes whose suppression flipped |
| ARView post-processing (HDR, DoF, motion blur, camera grain, grounding shadows, environment lighting) and their full-screen buffers | Disabled via `renderOptions`; everything drawn is unlit |

If memory is still too high, the next steps are:
- a lower `videoFormat` (smaller camera buffer pool)
- a lower `arView.contentScaleFactor`
- removing long-suppressed tiny anchors from the session. ARKit keeps every plane anchor it ever made.

## Layout

```
SidingsAR.xcodeproj    Xcode 26 project (synchronized folder: new files in SidingsAR/ are picked up automatically)
SidingsAR/             App (SwiftUI + RealityKit ARView, iOS 18, Swift 6)
  ARSessionController  ARSession owner + ARSessionDelegate, anchor → tracker → renderer pipeline
  PlaneRenderer        AnchorEntity per plane: fill mesh + markers; owns LabelOverlay
  DynamicMesh          MeshResource allocated once, updated in place
  AnchorMarkers        origin/center spheres + one boundary-points mesh
  LabelOverlay         screen-space UIKit labels
  MemoryFootprint      phys_footprint readout for the HUD
  PlaneAnchorAdapter   ARPlaneAnchor → PlaneObservation
PlaneKit/              Pure-Swift package (simd only): PlaneObservation, PolygonMath, PlaneTracker (NMS), PlaneSmoother,
                       RenderBudget (Throttle, RebuildGate, PointMarkerMesh)
legacy/                Original SceneKit tutorial project
tasks/                 plan.md + todo.md
```

## Build, test, run

```bash
# Unit tests (on the Mac, no device needed)
cd PlaneKit && swift test

# Compile check
xcodebuild -project SidingsAR.xcodeproj -scheme SidingsAR -destination 'generic/platform=iOS' build
```

To run, open `SidingsAR.xcodeproj` and run on a physical iPhone. ARKit doesn't work in the Simulator. Signing uses team `CBA2GU7TYT` with automatic signing.

All tuning parameters are in `PlaneTrackerConfig` (`PlaneKit/Sources/PlaneKit/PlaneTracker.swift`).

## Findings

- 36 unit tests cover polygon math, NMS cases, EMA, hysteresis and the render-budget helpers. `resolve()` for 50 planes runs in about 2 ms in a debug build.
- Memory before/after on device: *to be filled in* (read "mem MB" in the HUD after about 1 min of scanning the same room).
- LiDAR vs. non-LiDAR: *to be filled in after device tests.* ARKit has no public switch to turn LiDAR off for plane detection, so the comparison needs separate devices.
