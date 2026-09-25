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
- Each plane gets a billboard label: `W" × H"  (ft²)` plus its classification.
- **Non-Maximum Suppression** over duplicate planes (same alignment, normals ≤10° apart, ≤8 cm apart, overlap ≥30% of the smaller one). The winner is the plane with the highest area × stability score. Losers are dimmed, or hidden with **Hide dupes**. The HUD shows `kept/raw`.
- **Hysteresis:** the current winner gets a ×1.2 score margin. A challenger has to out-score it for 5 consecutive resolves before it takes over.
- **EMA smoothing** (α 0.3) of the label and center position, reset on jumps over 20 cm (relocalization).
- **Magenta markers:**
  - big sphere = anchor origin (`transform`)
  - medium sphere = extent center (`center`, smoothed)
  - small spheres = boundary vertices (up to 64 per plane)
- Full session delegate coverage: add, update and remove (ARKit reports merges as removals), a throttled frame tick, tracking-state banner, interruption begin/end, relocalization, error alert, coaching overlay and a Reset button.

## Why v1 looked "dirty"

`Grid.update` moved the parent node to `anchor.center` while the child was already offset by it. That double offset grew with the plane. v1 also:
- ignored `planeExtent.rotationOnYAxis`
- never handled `didRemove`, so merged planes stayed on screen
- drew rectangles instead of the boundary polygon
- had nothing to suppress ARKit's coplanar duplicates

## Layout

```
SidingsAR.xcodeproj    Xcode 26 project (synchronized folder: new files in SidingsAR/ are picked up automatically)
SidingsAR/             App (SwiftUI + RealityKit ARView, iOS 18, Swift 6)
  ARSessionController  ARSession owner + ARSessionDelegate, anchor → tracker → renderer pipeline
  PlaneRenderer        AnchorEntity per plane: fill mesh, label, markers
  AnchorMarkers        pooled magenta spheres
  PlaneAnchorAdapter   ARPlaneAnchor → PlaneObservation
PlaneKit/              Pure-Swift package (simd only): PlaneObservation, PolygonMath, PlaneTracker (NMS), PlaneSmoother
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

- 27 unit tests cover polygon math, NMS cases, EMA and hysteresis. `resolve()` for 50 planes runs in about 2 ms in a debug build.
- LiDAR vs. non-LiDAR: *to be filled in after device tests.* ARKit has no public switch to turn LiDAR off for plane detection, so the comparison needs separate devices.
