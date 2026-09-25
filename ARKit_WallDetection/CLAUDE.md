# CLAUDE.md: SidingsAR

- The app is in `SidingsAR/`; logic that can be tested without a device is in `PlaneKit/` (no ARKit/RealityKit imports there, only `simd` and Foundation).
- Tests: `cd PlaneKit && swift test`. Keep tests on disk; add a test for every PlaneKit change.
- Build: `xcodebuild -project SidingsAR.xcodeproj -scheme SidingsAR -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
- The project uses an Xcode 16+ **synchronized folder**, so don't hand-edit `project.pbxproj` just to add files.
- Swift 6 with default MainActor isolation. `ARSessionDelegate` is adopted as `@preconcurrency` (delegate queue = main).
- Logging: `os.Logger` (subsystem `br.com.neuralnexgen.sidingsar`), no `print`.
- ARKit doesn't run in the Simulator; every visual check needs a device.
- Plan and task status: `tasks/plan.md`, `tasks/todo.md`.
