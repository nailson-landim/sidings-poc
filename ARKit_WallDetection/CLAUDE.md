# CLAUDE.md: SidingsAR

iOS PoC for native ARKit plane detection (RealityKit `ARView`, SwiftUI, iOS 18, Swift 6). For user-facing docs and the full architecture, see `README.md`. The design and task status are in `tasks/plan.md` and `tasks/todo.md`. The product context is `../CONSOLIDATION.md`.

## Commands

```bash
cd PlaneKit && swift test                                   # unit tests (Mac, no device)
xcodebuild -project SidingsAR.xcodeproj -scheme SidingsAR \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build   # compile check
```

- ARKit **doesn't run in the Simulator**. Visual behavior can only be verified by the user on a device, so say so and never claim device results you didn't get.
- `xcrun devicectl list devices` shows connected iPhones. Ask before installing or launching anything on a device; the connected phones may not be the user's.
- Pulling files the app wrote needs no install. It reads the app container, like Xcode's *Download Container*:
  ```bash
  xcrun devicectl device info files --device <id> --domain-type appDataContainer \
    --domain-identifier br.com.neuralnexgen.sidingsar --subdirectory Documents
  xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
    --domain-identifier br.com.neuralnexgen.sidingsar --source Documents/<path> --destination <local path>
  ```

## Where code goes

- **`PlaneKit/`**: anything expressible without ARKit or RealityKit (geometry, arbitration, smoothing, throttling, mesh-data generation, and the Plane Lab recorder in `Recording/`). The plane code imports only `simd` and Foundation. `Recording/` may also import AVFoundation, CoreVideo and SQLite3, which all exist on macOS, so the whole write path is tested with `swift test` (`../SPEC.md` L11). Never ARKit, RealityKit or UIKit. Every change here gets Swift Testing cases in `PlaneKit/Tests/PlaneKitTests/`. Tests stay on disk.
- **`PlaneKit/Sources/PlaneKit/Cloud/`**: the averaged cloud (`../SPEC.md` L12), a port of Plane Lab's accumulator. Plane Lab (Python) is the reference: a change to the rules goes into Python first, then `python scripts/cloud_golden.py` rewrites `session-format/fixtures/cloud/golden.json`, and the Swift golden test must pass again.
- **`SidingsAR/`**: ARKit/RealityKit/UIKit glue. `PlaneAnchorAdapter` (viewer) and `Recording/ARRecordAdapter` (recorder) are the only places that convert ARKit types into PlaneKit types (`../SPEC.md` §17.4 P13).
- **`legacy/`**: read-only reference. Don't modify or build it.

## Architecture invariants

- **Anchor callbacks only record changes.** `didAdd` and `didUpdate` call `ingest()`, which snapshots the anchor, calls `tracker.upsert` and marks it dirty. `didRemove` removes visuals immediately. All resolve and render work happens on the **10 Hz frame tick** (`resolveAndRender`). Don't render from anchor callbacks.
- **Render only what changed:** dirty planes plus planes whose suppression flipped. `renderAll()` is only for HUD toggles.
- **ARKit owns anchors.** Suppression is visual (dim or hide). Never remove anchors from the session as a side effect of NMS.
- **One clock:** `lastFrameTime` (`ARFrame.timestamp`) drives every `Throttle` and `RebuildGate`. Don't mix in `CACurrentMediaTime()`.
- **Hysteresis counts resolves, not seconds.** Changing `resolveInterval` changes the real-time meaning of `challengerFrames`.
- **Never retain `ARFrame`s.** Read what you need inside `session(_:didUpdate frame:)`. The recorder copies `capturedImage` into its own pool buffer there and hands only that copy to `SessionWriter`.
- **The recorder never blocks the delegate.** `SessionWriter.enqueue` takes a lock and hands off to its queue. A full queue drops the frame, and a busy pool logs the frame without an image.

## Memory rules (v2.1; they fixed a runaway-RAM regression)

- Don't create a `MeshResource` per update. Use `DynamicMesh` (generate once, then `replace(with: MeshResource.Contents)`) behind a `RebuildGate`.
- No `MeshResource.generateText`. Labels go through `LabelOverlay` (UIKit, projected per frame).
- Many small markers go into **one** mesh (`PointMarkerMesh`), not one entity each.
- Cache materials per color. Skip labels and markers for suppressed planes.
- Keep the post-processing `renderOptions` disabled unless a feature really needs lit or PBR rendering.
- Check the **mem MB** readout in the HUD when you touch rendering, and ask the user for the number before and after.

## Swift and tooling gotchas

- Default actor isolation is `MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION`). `ARSessionDelegate` is adopted as `@preconcurrency`, and the delegate queue is main.
- The project uses a **synchronized folder** group (`PBXFileSystemSynchronizedRootGroup`). New files in `SidingsAR/` are picked up automatically, so don't hand-edit `project.pbxproj` to add files. Xcode may rewrite quoting in the file; that's harmless.
- Info.plist is generated from `INFOPLIST_KEY_*` build settings **plus** `SidingsAR-Info.plist`, which sits outside the synchronized folder so it isn't copied as a resource. Some keys have no generator setting and are silently dropped; `UIFileSharingEnabled` is one of them. Put those in `SidingsAR-Info.plist`, and check the built app with `plutil -p <app>/Info.plist`.
- **PlaneKit is built with `-O` even in Debug** (`Package.swift`, `../SPEC.md` P26), because Xcode's Run installs Debug builds and the accumulator is about 60 times slower unoptimized (3.2 ms vs 0.055 ms per frame on the Mac). Stepping through PlaneKit in the debugger is less precise; the app target stays `-Onone`.
- Swift Testing: `#expect(x.mutatingCall())` doesn't compile. Bind to a `let` first.
- Floating-point boundaries: `10.1 - 10.0 < 0.1`. Don't put test timestamps exactly on a throttle boundary.
- Video tests: `AVAssetWriter` stores a leading gap as an empty edit, and `AVAssetReaderTrackOutput` handles it differently by mode:
  - **passthrough** (`outputSettings: nil`) reports media time and ignores the edit, so map timestamps through `track.segments` (`VideoProbe.movieTime`);
  - **decoding** reports movie time with the edit applied, plus one extra blank frame inside the empty edit, so skip frames in empty segments.

  `VideoProbe` handles both.
- SQLite: `SessionDatabase.seal()` closes the database and deletes the `-shm` file that SQLite leaves behind after leaving WAL mode. A sealed session is one file. Bind an empty BLOB with `sqlite3_bind_zeroblob`, because a nil pointer binds NULL.
- Shell checks of `ffprobe` output: this Mac's locale uses a decimal comma, so run `awk` with `LC_ALL=C`, or `0.05` parses as `0`.
- Logging goes through `os.Logger` with subsystem `br.com.neuralnexgen.sidingsar`. No `print`.
- RealityKit API facts used here: `MeshResource.Contents` → `Model(id:parts:)` → `Part(id:materialIndex:)` with `positions` and `triangleIndices`, and `Instance(id:model:)`. `ARView.project(_:)` returns `CGPoint?`. `BillboardComponent` is available but no longer used.

## Before you finish a change

1. `swift test` is green, and new PlaneKit logic has tests.
2. The `xcodebuild` compile check succeeds with no new warnings.
3. `README.md` is updated (features, parameters, layout, findings), along with this file if a rule changed.
4. `tasks/todo.md` has the new work and its device checkpoints; leave device checks unticked until the user confirms them.
5. Commit from the repo root (`../`, branch `main`) with the attribution trailer.
