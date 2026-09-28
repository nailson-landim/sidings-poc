# Siding Scanner — Consolidation

*Living summary of the project as of Sep 24, 2026. Detail lives in `research/01-landscape-brief-and-vio-handoff.md`; this doc is the one to read first.*

---

## 1. Product in one paragraph

An on-device iOS/Android app that produces a **siding takeoff** (net wall area in squares, linear feet of corners / J-channel / starter / soffit-fascia, opening counts and sizes) from a few minutes of AR capture around a house. It ships with a **rough but reliable margin of error (MoE)**, delivered **on site, instantly**, instead of the incumbents' tighter numbers delivered hours later.

**Positioning:** Hover gets ~2.6% in 2–12 h. We aim for **±5% (calibrated) in ~5 min in the driveway**, which is enough to quote at the door. Contractors add a 10–15% waste factor anyway.

## 2. Decisions so far

| # | Decision | Status |
| --- | --- | --- |
| D1 | **Platform-first:** ARKit/ARCore VIO pose is taken as given (the "aircraft GPS/IMU" role). No custom VIO/SLAM. If the idea is viable, this is the starting point. | Decided (Nei) |
| D2 | **No calibration work.** Camera/IMU intrinsics are read from the frame only where a specific computation needs them. | Decided (Nei) |
| D3 | **Real-time RANSAC plane fitting**, with a larger MoE accepted in exchange for reliability. | Decided (Nei) |
| D4 | **The MoE is a sales feature**, not a weakness. It must be *calibrated* (e.g. ±5% holds ~95% of the time). | Decided (Nei) |
| D5 | **Monocular depth assists RANSAC.** Model choice is open (see Q1). | Direction (Nei) |
| D6 | The existing **YOLOv8-seg door/window model** is the openings-deduction module. | Carried from kickoff |
| D7 | Human-in-the-loop QA is an acceptable launch strategy. Both incumbents use it. | Carried from kickoff |

## 3. Landscape in brief

- **Sensing reality:** phone LiDAR/ARCore depth is dense only to ~5 m. VIO pose stays metric at 10–20 m+. A 2-storey facade needs 8–15 m standoff, so geometry has to come from **triangulation + priors + semantics**, not dense depth.
- **Hover:** 8+ ground photos, cloud processing with humans in the loop, a CAD-like model. The most IP overlap: planar facades from ground images, scale from standard elements, directed capture.
- **EagleView:** aerial imagery, walls/openings reports for ~$40–67, 24–48 h turnaround. Fails under trees and eaves. The most litigious player ($125M verdict vs Xactware).
- **Matterport/CoStar:** digital twins. Range is solved with hardware (Pro3 LiDAR). No wall-takeoff product found.
- **History lesson:** EagleView worked on 2000s hardware because **pose was measured, not solved**, and humans clicked the vertices. Their moat was data + patents, not algorithms.
- **IP:** risk follows claims (method + output). A proper FTO review is needed before launch, focused on Hover and EagleView.

## 4. VIO essentials (what matters for us)

- VIO = camera (no scale, no gravity) + IMU (metric, gravity, drifts ~t²). Fused, they give metric 6-DoF pose.
- **Observability:**
  - Roll/pitch are gravity-referenced and accurate, so the **vertical-wall prior is trustworthy**.
  - Yaw and global position drift.
  - **Scale is observable only under acceleration.** Smooth constant-velocity walking is the worst case.
- **Area ∝ scale².** 1% scale error becomes 2% area error. Scale is the #1 error term.
- **Drift is global; area is local.** Measure each wall from a short, well-excited segment, then stitch walls with Manhattan + loop-closure constraints. A drifting 60 m lap then hurts perimeter/closure, not per-wall squares.
- **Lap siding is adversarial for tracking:**
  - Horizontal edges cause the aperture problem.
  - The 4–5" repeat causes aliasing.
  - Sun saturation starves features.
  - Mitigation: keep non-siding texture (ground, trim, landscaping) in frame; the ultrawide helps.
- **Gotchas:**
  - Loop closure/relocalization shifts the world frame. Store measurements **relative to anchors** (one per wall), never as raw world coordinates.
  - Raw IMU comes from CoreMotion/SensorManager, not ARKit/ARCore.
- ARKit's built-in plane detection/reconstruction leans on LiDAR and close range, so it's unreliable at 8–15 m. That's why we fit our own planes.

## 5. Geometry architecture (proposed)

```
AR session (pose, gravity, intrinsics, sparse points, ground plane)
   │
   ├─ Segmentation (YOLOv8-seg: wall/siding, openings, trim, roof, ground)
   ├─ Mono depth (relative) ──► per-frame scale/shift fit to VIO sparse points ──► dense metric-ish points + normals
   │
   ├─ Plane hypotheses
   │     a) Constrained RANSAC on points inside wall mask
   │          vertical prior → 2 DoF (2-pt); Manhattan after 1st wall → 1 DoF (1-pt)
   │     b) Ground-ray: wall-base line ∩ ground plane → footprint → vertical wall
   │     c) Mono-depth normals → orientation seed
   │
   ├─ Agreement check across (a)(b)(c) ──► per-wall plane + confidence
   ├─ Mask → plane projection ──► metric polygons (gross wall, openings, gables)
   └─ Takeoff (net area, linear ft, counts) + calibrated MoE per wall and per house
```

Notes:

- **Masks as outlier filters:** RANSAC only sees points inside wall/siding masks, which removes bushes, ground and cars upfront.
- **Ground-ray caveat:** at 1.5 m height and 10 m range, 1 px of error ≈ 5 cm, but a 0.5° yard slope ≈ 0.5 m. Use it as a hypothesis RANSAC confirms, never alone.
- **Mono depth:** it provides density and shape. **VIO always provides scale.** Normals are more trustworthy than absolute depths.

## 6. MoE model (how "reliable" is earned)

Candidate per-wall confidence features:

- Agreement between plane sources (triangulated / ground-ray / mono-normal)
- **Siding exposure check:** measured course spacing on the fitted plane vs nominal 4"/5". A free per-wall scale check.
- Tracking-state history and feature-ID lifetimes during the wall's capture
- Standoff distance and baseline achieved (σ_z ∝ z²/b)
- Coverage: fraction of the wall mask seen from ≥2 viewpoints
- Loop-closure gap after the lap

A simple regressor trained on ground-truth houses outputs ±X%. **The validation set is the moat.**

## 7. Capture UX (proposed)

1. **Init with excitation:** start close to texture (LiDAR helps on Pro devices) and do a deliberate lateral step or arc.
2. **Per-wall segment:** stand at 8–15 m, sweep 2–4 m laterally, and anchor the wall.
3. **Keep context in frame** (ground, trim), not a full-frame blank wall.
4. **Close the loop** at the start corner. That gives a closure and a free drift measurement.
5. **Scale cross-checks:** siding exposure, a standard door, optionally one tape measurement. Flag the capture if a check disagrees with VIO by more than ~1%.

## 8. First spike (iOS, ~2 weeks)

1. Log ARFrames (pose, intrinsics, sparse points, image, tracking state) via ARKit session recording.
2. Run YOLOv8-seg plus a wall/siding class offline on the logs.
3. Python prototype: vertical/Manhattan RANSAC + ground-ray hypothesis + mono-depth densification.
4. One real house vs tape-measure ground truth (AprilTags on the facade).

**Go/no-go:** per-wall area within ±5%, and VIO scale error < ~1% (because area doubles it).

## 9. Evaluation protocol (sketch)

- Ground truth: AprilTag distances by tape or laser meter (total station if available), plus a hand takeoff per house.
- Metrics:
  - Scale error (VIO vs GT tag distances)
  - Per-wall and total net-area error
  - Linear-ft error
  - Loop-closure gap
  - MoE calibration (coverage of the stated interval)
- Matrix: iPhone Pro / non-Pro / 2–3 Android × overcast / sun × wide / ultrawide × smooth / guided capture. ~5 houses for the first signal.

## 10. Open questions

1. **Which depth model?** "YOLO depth" wasn't identified. Candidates: Depth Anything V2 Small (on-device, CoreML available), Depth Pro, Metric3D, UniDepth, MoGe. Nei to confirm.
2. Real VIO scale error and drift outdoors over a 30–60 m lap, ARKit vs ARCore. **Measure it ourselves** (spike).
3. Tracking robustness on lap siding in sun and shadow.
4. Loop closure: do corners close after a full lap, and how large are the pose jumps?
5. Geospatial anchors / VPS as a global constraint. Coverage in Canada?
6. Gable, eave and soffit handling: what is the geometry source above the first storey?
7. Occluders (porches, trees, cars): inpaint, flag, or ask for extra views?
8. FTO review scope and timing.
9. iOS-first, or both platforms from day one?

## 10b. Native ARKit spike (Sep 25, 2026)

`ARKit_WallDetection/` now holds **SidingsAR**, a RealityKit app that shows native `ARPlaneAnchor` output (vertical + horizontal, classification) with NMS de-duplication, EMA/hysteresis smoothing and magenta anchor markers. The goal is to see what ARKit gives us for free before custom RANSAC. The user tested it on device on Sep 25, 2026 and called it "a great starter". The v2.1 memory pass is in, and it adds a live memory readout to the HUD. Numbers (memory, LiDAR vs. non-LiDAR, usable range) are still pending; see `ARKit_WallDetection/README.md` → Findings.

**Feature points on a non-LiDAR phone outdoors** (Sep 25, 2026, `BUILDING_SAMPLE.png`):
- **Setup:** CurvSurf's ARFeaturePointFindSurface demo on an iPhone 13, in sun. The user stood less than 5 m from the building and looked up.
- **Result:** 3,533 averaged `rawFeaturePoints`, including points about 8–10 m up the wall. Collecting them was slow.
- **Where the points land:** almost all on edges and texture: corners, the parapet, the trim band, window frames and grilles. The plain plaster faces got almost none.
- **What it means:**
  - A wall is seen through its outline, not its face.
  - Plane fitting has to handle collinear edge points and corners shared by two walls.
  - This is consistent with the lap-siding texture concerns in §4.
- **What it doesn't answer:** every point is within about 10 m of the camera, so it doesn't test the claimed ~65 m range at the 8–15 m standoff. That's experiment E1 in `SPEC.md`.

**ARKit frame rate and recording load on an iPhone 13** (Sep 28, 2026, Plane Lab recorder, `SPEC.md` §15 R1 and T7):
- **ARKit's frame rate follows heat.** The world-tracking format promises 60 fps (1920 × 1440).
  - Delivered a flat **30 Hz** while the phone sat at thermal state *serious* (charging, already warm).
  - Delivered a steady **60 Hz** at *fair*.
  - The rate is a camera-mode switch, not jitter: the intervals were exactly 33.3 ms or 16.7 ms.
- **Recording everything is affordable on a non-LiDAR phone.**
  - Every frame's pose, intrinsics, ~250 raw feature points, and a full-resolution HEVC image: 48 s gave 2,863 frames, none dropped, and 0.24 % without an image.
  - Copying an image costs under 1 ms at p95.
  - The session takes about 82 MB/min, and the plane viewer didn't stutter.
- **What it means for capture:** a hot phone halves the evidence per second. Capture guidance should keep the phone cool (no charging, shade), and the lab must time things from `ARFrame.timestamp`, never from an assumed rate.
- **What `planelab peek` shows in the first real recording** (48 s indoors):
  - **The intrinsics drift with autofocus:** fx went from 1524.0 to 1527.4 px, so they must be taken per frame, never as a constant.
  - **ARKit's position for a given feature id moves by about 2.5–3 cm RMS** across its sightings (12,177 ids, each seen about 59 times on average). That's the noise the lab's averaging has to remove before fitting planes.
- **Still open:** 60 Hz over a full 5-minute session, whether recording itself pushes the phone into *serious*, and memory growth (300 → 440 MB in a minute in the spike). These are checked at Plane Lab Checkpoint 2A.

## 11. Document index

- `00-consolidation.md` (this file): current state, decisions, plan
- `research/01-landscape-brief-and-vio-handoff.md`: full landscape, incumbents, patents, EagleView history, sources
