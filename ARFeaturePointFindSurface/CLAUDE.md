# CLAUDE.md: ARFeaturePointFindSurface (local notes)

This is an upstream clone of [CurvSurf/ARFeaturePointFindSurface](https://github.com/CurvSurf/ARFeaturePointFindSurface) (MIT). We use it as a reference for fitting surfaces to ARKit `rawFeaturePoints` on non-LiDAR devices. `README.md` is CurvSurf's and is left as is; our notes go here.

## Local patches (not upstream)

| File | Change | Why |
| --- | --- | --- |
| `ARFeaturePointFindSurface.xcodeproj/project.pbxproj` | Team `CBA2GU7TYT`, bundle ID `br.com.neuralnexgen.findSurface1` | Sign for our devices |
| `ARFeaturePointFindSurface/Utilities/ARFrameProvider.swift` | Request `.sceneDepth` / `.smoothedSceneDepth` only where supported, instead of refusing to run without them | Fixes the non-LiDAR startup bug below |

## Finding: the app never started AR on non-LiDAR iPhones (2026-09-25)

**Symptom** (iPhone 13, iPhone14,5, no LiDAR): no camera permission prompt, a black background, and a "Scan your surroundings" card with a progress bar stuck at 0 and no buttons.

**Cause:** upstream `ARWorldTrackingFrameProvider.resume()` had
`guard !isRunning && supportsFrameSemantics([.sceneDepth, .smoothedSceneDepth]) else { return }`.
Scene depth needs LiDAR, so on non-LiDAR devices `session.run` was never called, and nothing logged or showed the failure. The effects chain like this:
- The camera is never opened, so iOS never asks for camera permission.
- `AppState.draw` returns early because `currentFrame == nil`, so no camera image is drawn.
- Stabilization never gets frames, so `hasMotionTrackingStabilized` stays false, and `UserInterfaceView` keeps showing only the scan card. All buttons, the picker and the status view appear only after stabilization.

Nothing in the app reads the depth map. It only uses `frame.rawFeaturePoints`, so the requirement was never needed. This contradicts the upstream README, which says non-LiDAR devices are supported.

**Status:** it builds for `generic/platform=iOS` (`CODE_SIGNING_ALLOWED=NO`). **The user checked it on the iPhone 13 (no LiDAR) on 2026-09-25:** AR starts and collects points outdoors (`../BUILDING_SAMPLE.png`).

## Findings from reading the code (2026-09-25, for `../SPEC.md`)

- **The preview flickers by design.** `AppState.detectGeometries` runs every frame. It picks the averaged point nearest the view ray and fits one surface around it from scratch. Nothing links a result to the previous frame's, and nothing persists until Capture is pressed.
- **The motion gate is inverted (upstream).** `CameraMotionDetector.hasCameraMovedEnough` is documented as "moved ≥ 3 cm or turned ≥ 3°", but it tests `distance_squared(...) < minDistanceSquared`. So it fires when the camera moved *less* than 3 cm: nearly every frame at walking speed. During fast translation it blocks until the camera turns ≥ 3°. It isn't patched here; the Plane Lab ports both behaviors so they can be compared.

## UI/UX notes for iPhone

- **Locked to landscape-right** (`UISupportedInterfaceOrientations = LandscapeRight`, `UIRequiresFullScreen`). Hold the phone sideways with the Dynamic Island on the left. There's no portrait layout.
- **Gated main UI:** the controls appear only once there are ≥150 raw feature points per frame and a virtual point 10 cm in front of the camera has travelled 2 m (`MotionTrackingStabilizationHelper`). Before that, the scan card is the whole UI, by design.
- **Silent failures:** there's no `session(_:didFailWithError:)`, no interruption handling and no camera-denied check. If the session can't start, the user just sees the scan card forever.
- **iPad vs. iPhone:** the only idiom branches are where the seed-radius tutorial card goes (next to the status view on iPhone, top-right on iPad) and the trailing padding on the button column. Otherwise the layout is the same on both.

## Build

```sh
xcodebuild -project ARFeaturePointFindSurface.xcodeproj -scheme ARFeaturePointFindSurface \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

The deployment target is iOS 18.6. It depends on `FindSurface-iOS` and `swift-collections` through SPM.
