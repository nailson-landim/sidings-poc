# TODO: ARKit Plane PoC v2 (RealityKit)

> **Status 2026-09-25:** T1–T8 are implemented. `swift test` passes (27 tests) and the xcodebuild build succeeds. **Still open:** all manual on-device checks (screenshots, FPS, flicker, LiDAR vs. non-LiDAR notes). Tick them here as you verify.

See `tasks/plan.md` for the design decisions. Paths below are relative to `ARKit_WallDetection/`.

Commands:
- Unit tests: `cd PlaneKit && swift test`
- Build: `xcodebuild -project SidingsAR.xcodeproj -scheme SidingsAR -destination 'generic/platform=iOS' build`
- Manual checks: run on device from Xcode (LiDAR phone + non-LiDAR phone)

---

## Phase 1: Foundation

## Task 1: RealityKit skeleton with correct vertical planes and full lifecycle

**Description:** Create a new Xcode 26 iOS app `SidingsAR` (SwiftUI, iOS 18, Swift 6, synchronized folder group). Move the old project to `legacy/`. Show an `ARView` in a `UIViewRepresentable` and run `ARWorldTrackingConfiguration` with `planeDetection = [.vertical]`. An `ARSessionDelegate` coordinator handles `didAdd`, `didUpdate` and `didRemove`. Each `ARPlaneAnchor` gets an `AnchorEntity(anchor:)` holding a semi-transparent mesh built from `ARPlaneGeometry` (boundary polygon via `MeshDescriptor`) and a text label (`planeExtent` width × height in inches plus ft²). This replaces the tutorial app and fixes the double-offset and rotation bugs.

**Acceptance criteria:**
- [ ] Plane meshes sit flush on real walls, with no drift as they grow and no skew (they use the boundary polygon, not the rectangle)
- [ ] When ARKit merges planes (`didRemove`), the absorbed plane's entity disappears and the entity dictionary count equals the live anchor count
- [ ] The label faces the camera (billboard) and shows `W" × H"  (A ft²)`

**Verification:**
- [ ] Build succeeds (xcodebuild command above)
- [ ] Manual: point at the same door/wall as `../AR_APP.PNG`; take a screenshot for comparison

**Dependencies:** None

**Files likely touched:** `SidingsAR/SidingsARApp.swift`, `SidingsAR/ARViewContainer.swift`, `SidingsAR/PlaneRenderer.swift`, `SidingsAR/Info.plist` (camera usage), `legacy/` (moved)

**Estimated scope:** M

---

## Task 2: `PlaneKit` package: `PlaneObservation` + polygon math + tests

**Description:** A local Swift package with no ARKit imports (only `simd`), so it's testable on the Mac. It contains:
- `PlaneObservation` (a `Sendable` struct): id, alignment, classification, world transform, center, width, height, yaw, world-space boundary polygon, firstSeen, updateCount
- geometry helpers: plane normal, point-to-plane distance, angle between normals, projecting a polygon onto a plane, polygon area, polygon intersection area (Sutherland–Hodgman clipping on convex hulls)

The app adds an `ARPlaneAnchor → PlaneObservation` adapter.

**Acceptance criteria:**
- [ ] `PlaneKit` is linked into the app; the adapter compiles
- [ ] Unit tests cover area, overlap (none, partial, containment), normal angle and plane distance

**Verification:**
- [ ] `swift test` is green; tests are persisted under `PlaneKit/Tests/PlaneKitTests/`
- [ ] App build succeeds

**Dependencies:** T1

**Files likely touched:** `PlaneKit/Package.swift`, `PlaneKit/Sources/PlaneKit/PlaneObservation.swift`, `PlaneKit/Sources/PlaneKit/PolygonMath.swift`, `PlaneKit/Tests/PlaneKitTests/PolygonMathTests.swift`, `SidingsAR/PlaneAnchorAdapter.swift`

**Estimated scope:** M

### Checkpoint A
- [ ] App builds and runs on device; walls line up with the real walls
- [ ] `swift test` passes
- [ ] Human review before Phase 2

---

## Phase 2: Core features

## Task 3: Magenta anchor markers

**Description:** Add magenta `UnlitMaterial` spheres as children of each plane's entity:
- the **anchor origin** (radius 2 cm)
- the **plane center**, `planeExtent`/`center` (1.2 cm)
- each **boundary vertex** (0.5 cm)

Update them on `didUpdate`, reusing the sphere entities from a pool. A HUD toggle turns markers on and off.

**Acceptance criteria:**
- [ ] All three marker kinds are visible and follow the plane as it grows
- [ ] The origin stays fixed while the center moves as the plane extends. This shows the difference visually.
- [ ] With markers on, FPS stays at 60 or above with 10 planes; boundary spheres are capped at 64 per plane

**Verification:**
- [ ] Build succeeds
- [ ] Manual: screenshot with markers on

**Dependencies:** T1

**Files likely touched:** `SidingsAR/AnchorMarkers.swift`, `SidingsAR/PlaneRenderer.swift`, `SidingsAR/HUDView.swift`

**Estimated scope:** S

---

## Task 4: Horizontal planes + classification

**Description:** Set `planeDetection = [.horizontal, .vertical]`. Color each plane by alignment and `ARPlaneAnchor.classification`: wall cyan, floor green, ceiling yellow, table/seat orange, door/window purple, none white. Add the classification name to the label. A HUD segmented control switches between vertical, horizontal and both; each change re-runs the session with `.resetTracking, .removeExistingAnchors`.

**Acceptance criteria:**
- [ ] Floor and table planes render flat with correct dimensions
- [ ] Classification appears in the label and color, and falls back to white on unsupported devices
- [ ] Switching the filter resets the session cleanly (no orphan entities)

**Verification:**
- [ ] Build succeeds
- [ ] Manual: a room scan shows the floor plus at least 1 wall plus a table, each with its classification

**Dependencies:** T1

**Files likely touched:** `SidingsAR/ARViewContainer.swift`, `SidingsAR/PlaneRenderer.swift`, `SidingsAR/PlaneStyle.swift`, `SidingsAR/HUDView.swift`

**Estimated scope:** S

---

## Task 5: Non-Maximum Suppression

**Description:** In `PlaneKit`, add `PlaneTrackerConfig` (angle 10°, distance 8 cm, overlap 0.3, min age) and `PlaneTracker.resolve([PlaneObservation]) -> [UUID: PlaneState]`. It groups planes by alignment, scores each one as area × stability, and runs greedy NMS using the conflict rule from `plan.md`. The app runs `resolve` after every anchor batch. Suppressed planes are dimmed to 15% opacity, or hidden via the HUD toggle. The HUD shows `raw N / kept M`.

**Acceptance criteria:**
- [ ] Unit tests: two coplanar overlapping planes → 1 kept; a perpendicular pair → 2 kept; parallel planes 30 cm apart → 2 kept; floor vs. table (horizontal, different height) → 2 kept
- [ ] On device, in the `AR_APP.PNG` scene, stacked labels and overlapping grids are gone
- [ ] `resolve` takes under 1 ms for 50 planes (measured in a test)

**Verification:**
- [ ] `swift test` is green
- [ ] Build succeeds; manual before/after screenshots

**Dependencies:** T2 (T4 for the horizontal cases)

**Files likely touched:** `PlaneKit/Sources/PlaneKit/PlaneTracker.swift`, `PlaneKit/Tests/PlaneKitTests/NMSTests.swift`, `SidingsAR/PlaneRenderer.swift`, `SidingsAR/HUDView.swift`

**Estimated scope:** M

---

## Task 6: EMA smoothing + winner hysteresis

**Description:** Extend `PlaneTracker`:
- keep an EMA (α configurable, default 0.3) of the rendered center, extent and yaw per anchor, reset on a jump larger than 20 cm (relocalization)
- **hysteresis**: the current NMS winner keeps winning until a challenger's score is more than 1.2× for 5 consecutive resolves

The renderer uses the smoothed values for the label and marker positions. The raw mesh stays true to ARKit.

**Acceptance criteria:**
- [ ] Unit tests: the EMA converges; a jump resets it; the winner doesn't flip on alternating ±5% scores; the winner does switch on a sustained +30%
- [ ] On device, labels and suppressed/visible states don't flicker while you hold the phone still

**Verification:**
- [ ] `swift test` is green
- [ ] Manual: a 10 s screen recording held still, with no visible flicker

**Dependencies:** T5

**Files likely touched:** `PlaneKit/Sources/PlaneKit/PlaneTracker.swift`, `PlaneKit/Sources/PlaneKit/Smoothing.swift`, `PlaneKit/Tests/PlaneKitTests/SmoothingTests.swift`, `SidingsAR/PlaneRenderer.swift`

**Estimated scope:** S–M

### Checkpoint B
- [ ] All tests pass, build clean
- [ ] In the `AR_APP.PNG` room: visible planes ≤ real surfaces + 1
- [ ] Same scan on a LiDAR and a non-LiDAR phone; screenshots and notes captured
- [ ] Human review before Phase 3

---

## Phase 3: Polish

## Task 7: Session/tracking delegates, coaching overlay, HUD, reset

**Description:** Implement the rest of the delegate audit in `plan.md`:
- `cameraDidChangeTrackingState` → HUD banner with the reason
- interruption begin/end → banner and a reset prompt
- `sessionShouldAttemptRelocalization` → true
- `didFailWithError` → logged with `os.Logger` and shown in an alert
- a `didUpdate frame` tick throttled to 10 Hz for the HUD (feature point count, tracking state)
- `ARCoachingOverlayView` with goal `.anyPlane`
- a Reset button

**Acceptance criteria:**
- [ ] Covering the camera shows "Limited: insufficient features"; shaking the phone shows "excessive motion"
- [ ] Backgrounding and foregrounding the app shows the interruption banner and relocalizes or offers a reset
- [ ] Reset clears all entities and tracker state

**Verification:**
- [ ] Build succeeds; manual checks above

**Dependencies:** T1

**Files likely touched:** `SidingsAR/ARViewContainer.swift`, `SidingsAR/HUDView.swift`, `SidingsAR/SessionStatus.swift`

**Estimated scope:** S–M

---

## Task 8: Documentation

**Description:** Update `README.md` (how to run, architecture, NMS/EMA parameters, LiDAR vs. non-LiDAR findings, and a before/after screenshot) and create `CLAUDE.md` (build and test commands, layout, conventions). Update `../CONSOLIDATION.md` §10 with what native ARKit can and can't do.

**Acceptance criteria:**
- [ ] A fresh reader can build, test and run the app from the README alone
- [ ] Device findings are recorded

**Verification:**
- [ ] Manual read-through

**Dependencies:** T1–T7

**Files likely touched:** `README.md`, `CLAUDE.md`, `../CONSOLIDATION.md`

**Estimated scope:** S

### Checkpoint C
- [ ] All acceptance criteria met
- [ ] Findings documented; ready for review

---

## Request 2 (2026-09-25): debug points + memory

- [x] R2.1: Bring back ARKit feature points (`ARView.debugOptions.showFeaturePoints`, on by default). Add a Debug menu (points, markers, hide duplicates, render stats)
- [x] R2.2: Show process memory (`phys_footprint`) in the HUD at 1 Hz
- [x] R2.3: Replace 3D text labels with UIKit screen-space labels
- [x] R2.4: Bake boundary markers into one mesh per plane; no markers or labels for suppressed planes
- [x] R2.5: Fill meshes updated in place (`replace(with:)`), gated by `RebuildGate` (4 Hz visible / 1 Hz suppressed), materials cached
- [x] R2.6: Anchor callbacks only mark dirty; a 10 Hz frame tick resolves and renders changed planes
- [x] R2.7: Disable unused ARView post-processing
- [x] Tests: `RenderBudgetTests` (Throttle, RebuildGate, PointMarkerMesh); `swift test` 36/36, build clean

### Checkpoint R2 (device)
- [ ] Same room as `AR_APP.PNG`, ~1 min scan: HUD "mem MB" stays flat instead of climbing. Record the number in the README
- [ ] Feature points visible; the toggle works
- [ ] Labels follow planes smoothly while moving; no labels on dimmed duplicates
- [ ] Boundary markers appear on a plane that wins NMS later
