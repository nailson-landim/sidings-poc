import ARKit
import Combine
import Observation
import OSLog
import PlaneKit
import RealityKit

/// Owns the ARView/ARSession, feeds plane anchors through `PlaneTracker` (NMS + smoothing) and drives `PlaneRenderer`.
///
/// Anchor callbacks only record *what changed*; the actual resolve + render runs on a throttled frame tick and touches
/// only dirty planes or planes whose suppression flipped.
@Observable
@MainActor
final class ARSessionController: NSObject {
    // MARK: HUD state

    var mode: DetectionMode = .both {
        didSet { if mode != oldValue { restart(reason: .modeChange) } }
    }
    var showMarkers = true {
        didSet {
            renderer.showMarkers = showMarkers
            renderAll()
        }
    }
    var hideSuppressed = false {
        didSet { renderAll() }
    }
    /// ARKit's own plane anchors; off leaves only the RANSAC planes on screen.
    var showARKitPlanes = true {
        didSet { renderAll() }
    }
    /// Experiment X2 (`../EXPERIMENTS.md`): RANSAC planes on the live cloud, tracked. Off stops the rounds too.
    /// (X1's FindSurface engine is still in the code, but the UI runs RANSAC; XD14.)
    var showSurfaces = true {
        didSet {
            surfaceRenderer.isVisible = showSurfaces
            surfaceThrottle.reset()
        }
    }
    /// The dials (*Debug › RANSAC dials*, `../EXPERIMENTS.md`): applied from the next round on, tracks kept. While
    /// recording, each change is a `surface_dial` event (a timeline marker in Blender).
    var surfaceSettings = SurfaceSettings.ransac {
        didSet {
            guard surfaceSettings != oldValue else { return }
            liveSurfaces.update(settings: surfaceSettings)
            if surfaceSettings.roundInterval != oldValue.roundInterval {
                surfaceThrottle = Throttle(interval: surfaceSettings.roundInterval)
            }
            let before = Dictionary(uniqueKeysWithValues: oldValue.metaRows.map { ($0.key, $0.value) })
            let changes = surfaceSettings.metaRows
                .filter { before[$0.key] != $0.value }
                .map { "\($0.key.dropFirst(3)) \(before[$0.key] ?? "?")→\($0.value)" }
            logger.info("RANSAC dials: \(changes.joined(separator: ", "), privacy: .public)")
            recorder.note(kind: "surface_dial", detail: changes.joined(separator: ", "))
        }
    }
    var showFeaturePoints = true {
        didSet { applyDebugOptions() }
    }
    var showStatistics = false {
        didSet { applyDebugOptions() }
    }
    /// The live averaged cloud (`../SPEC.md` L12, T28).
    var showCloud = true {
        didSet {
            cloudRenderer.anchor.isEnabled = showCloud
            cloudThrottle.reset()
        }
    }
    /// Longest exposure auto exposure may use (P30); changes apply live and are logged in a recording.
    var exposureCap = ExposureCap(seconds: RecorderConstants.current.maxExposureS) {
        didSet {
            guard exposureCap != oldValue else { return }
            exposure.cap = exposureCap
            exposure.refresh()
            recorder.note(kind: "exposure_cap", detail: "\(exposureCap.rawValue)")
        }
    }
    /// Current exposure time (ms) and ISO; ISO is nil when ARKit doesn't share the camera.
    private(set) var exposureMS: Double = 0
    private(set) var iso: Float?
    /// False when ARKit won't let us set the exposure; nil before the first frame.
    private(set) var exposureControlAvailable: Bool?
    /// Averaged points in the live cloud.
    private(set) var cloudCount = 0
    /// RANSAC: confirmed tracks, all tracks, and the round time: the last, then the median and 95th percentile of the
    /// last 64 rounds. `surfaceSkipped` counts rounds not started because the previous one was still running.
    private(set) var surfaceConfirmed = 0
    private(set) var surfaceTotal = 0
    private(set) var surfaceMS: Double = 0
    private(set) var surfaceMedianMS: Double = 0
    private(set) var surfaceP95MS: Double = 0
    private(set) var surfaceSkipped = 0
    /// The last *Benchmark on live cloud*, as a line for the HUD.
    private(set) var benchmarkLine: String?
    private(set) var rawCount = 0
    private(set) var keptCount = 0
    private(set) var featurePointCount = 0
    private(set) var memoryMB: Double = 0
    /// Frames ARKit delivered in the last second of frame time.
    private(set) var fps: Double = 0
    private(set) var trackingName = "n/a"
    private(set) var banner: String?
    var errorMessage: String?

    // MARK: Internals

    /// Resolve/render cadence. Also paces NMS hysteresis (`challengerFrames` resolves ≈ 0.5 s).
    static let resolveInterval: TimeInterval = 0.1
    static let hudInterval: TimeInterval = 0.1
    static let memoryInterval: TimeInterval = 1.0
    /// Cloud mesh rebuilds (P24): the squares turn to face the camera and new points appear at this cadence.
    static let cloudInterval: TimeInterval = 0.2
    /// How often the tracks are read back and redrawn.
    static let surfaceRenderInterval: TimeInterval = 0.1

    @ObservationIgnored let arView: ARView
    /// Plane Lab recorder (`../SPEC.md` §4).
    @ObservationIgnored let recorder = SessionRecorder()
    /// CurvSurf's accumulator, on its own queue (`../SPEC.md` L12, T28).
    @ObservationIgnored let liveCloud = LiveCloud(settings: RecorderConstants.current.cloudSettings)
    @ObservationIgnored private let cloudRenderer = CloudRenderer()
    /// X2: RANSAC rounds on their own queue, fed from the live cloud.
    @ObservationIgnored let liveSurfaces = LiveSurfaces(engine: RansacScanner(settings: .ransac))
    @ObservationIgnored private let surfaceRenderer: SurfaceRenderer
    @ObservationIgnored private var surfaceThrottle = Throttle(interval: SurfaceSettings.ransac.roundInterval)
    @ObservationIgnored private var surfaceRenderThrottle = Throttle(interval: ARSessionController.surfaceRenderInterval)
    @ObservationIgnored private var surfaceVersion = -1
    @ObservationIgnored private var surfaceError: String?
    @ObservationIgnored private var lastCamera = matrix_identity_float4x4
    @ObservationIgnored private var benchmarkShown: SearchBenchmark?
    @ObservationIgnored private let exposure = ExposureControl(cap: ExposureCap(seconds: RecorderConstants.current.maxExposureS))
    @ObservationIgnored private var cloudThrottle = Throttle(interval: ARSessionController.cloudInterval)
    @ObservationIgnored private let renderer: PlaneRenderer
    @ObservationIgnored private let tracker = PlaneTracker()
    @ObservationIgnored private var anchors: [UUID: ARPlaneAnchor] = [:]
    @ObservationIgnored private var dirty: Set<UUID> = []
    @ObservationIgnored private var needsResolve = false
    @ObservationIgnored private var resolveThrottle = Throttle(interval: ARSessionController.resolveInterval)
    @ObservationIgnored private var hudThrottle = Throttle(interval: ARSessionController.hudInterval)
    @ObservationIgnored private var memoryThrottle = Throttle(interval: ARSessionController.memoryInterval)
    @ObservationIgnored private var sceneUpdate: (any Cancellable)?
    /// Last `ARFrame.timestamp`; the single clock for throttles and rebuild gates.
    @ObservationIgnored private var lastFrameTime: TimeInterval = 0
    @ObservationIgnored private var fpsWindow: (start: TimeInterval, frames: Int) = (0, 0)
    @ObservationIgnored private var interruptionBanner: String?
    @ObservationIgnored private let logger = Logger(subsystem: "br.com.neuralnexgen.sidingsar", category: "session")

    override init() {
        arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        renderer = PlaneRenderer(scene: arView.scene)
        surfaceRenderer = SurfaceRenderer(labels: renderer.labels)
        super.init()
        arView.session.delegate = self
        recorder.session = arView.session
        // Everything we draw is unlit debug geometry: skip post-processing passes and their full-screen buffers.
        arView.renderOptions = [
            .disableMotionBlur, .disableDepthOfField, .disableHDR, .disableCameraGrain,
            .disableGroundingShadows, .disableAREnvironmentLighting, .disablePersonOcclusion, .disableFaceMesh
        ]
        applyDebugOptions()
        arView.scene.addAnchor(cloudRenderer.anchor)
        arView.scene.addAnchor(surfaceRenderer.anchor)
        sceneUpdate = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            guard let self else { return }
            self.renderer.labels.layout(in: self.arView)
        }
    }

    /// Screen-space label layer; ContentView inserts it above the AR content.
    var labelView: UIView { renderer.labels.view }

    var isLiDARDevice: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    func start() {
        run(options: [])
    }

    func pause() {
        recorder.stop(reason: .pause)
        arView.session.pause()
    }

    func toggleRecording() {
        if recorder.isRecording {
            recorder.stop(reason: .user)
        } else {
            let exposureMeta = [
                ("exposure_cap_s", "\(exposureCap.rawValue)"),
                ("exposure_control", exposureControlAvailable == true ? "1" : "0"),
            ]
            // The engine and its settings go in every recording (the `x1.*` rows hold either engine's settings); the
            // rows only while it's on (schema v3 and v4, XD6, XD16).
            let surfaceMeta = [("surface_engine", "ransac"), ("x1_enabled", showSurfaces ? "1" : "0")]
                + surfaceSettings.metaRows
            recorder.start(
                configuration: arView.session.configuration, mode: mode, lidar: isLiDARDevice, cloud: liveCloud,
                surfaces: liveSurfaces, extraMeta: exposureMeta + surfaceMeta
            )
            // Recording clears the cloud (P22) and the tracks with it; clear what's drawn of them too.
            resetSurfaceDisplay()
        }
    }

    /// Drops every anchor and tracker state and restarts tracking from scratch. Stops a recording first (SPEC §4 R3).
    func restart(reason: StopReason = .reset) {
        recorder.stop(reason: reason)
        renderer.removeAll()
        tracker.reset()
        anchors.removeAll()
        dirty.removeAll()
        needsResolve = false
        interruptionBanner = nil
        liveCloud.clear()
        cloudRenderer.clear()
        cloudCount = 0
        clearSurfaces()
        publishCounts()
        run(options: [.resetTracking, .removeExistingAnchors])
    }

    private func run(options: ARSession.RunOptions) {
        guard ARWorldTrackingConfiguration.isSupported else {
            errorMessage = "ARWorldTracking is not supported on this device."
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = mode.planeDetection
        config.environmentTexturing = .none
        // High-resolution stills (P29) need ARKit's recommended format to get the full sensor resolution.
        if RecorderConstants.current.stillsEnabled,
           let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = format
        }
        let format = config.videoFormat
        logger.info("Running session: mode=\(self.mode.rawValue, privacy: .public) lidar=\(self.isLiDARDevice) format=\(Int(format.imageResolution.width))x\(Int(format.imageResolution.height))@\(format.framesPerSecond) hires=\(format.isRecommendedForHighResolutionFrameCapturing)")
        arView.session.run(config, options: options)
        exposure.sessionDidRun()
    }

    /// *Debug › RANSAC dials › Restart*: forgets every track, so a wall is found again with the current dials.
    func restartSurfaces() {
        clearSurfaces()
        recorder.note(kind: "surface_restart", detail: "tracks forgotten")
    }

    /// *Debug › RANSAC dials › Benchmark on live cloud*: 20 full searches on the cloud as it is now, on the engine's
    /// queue. Skipped while a round runs (the timings would include the wait). The result shows in the HUD, goes to the
    /// log and, while recording, becomes a `benchmark` event.
    func benchmarkSurfaces() {
        let cloud = liveCloud.latest().state
        guard liveSurfaces.runBenchmark(cloud: cloud, camera: lastCamera, runs: 20) else {
            benchmarkLine = "benchmark skipped: a round is running, try again"
            return
        }
        benchmarkLine = "benchmark running on \(cloud.count) points…"
    }

    private func clearSurfaces() {
        liveSurfaces.clear()
        resetSurfaceDisplay()
    }

    private func resetSurfaceDisplay() {
        surfaceRenderer.removeAll()
        surfaceVersion = -1
        surfaceConfirmed = 0
        surfaceTotal = 0
        surfaceMS = 0
        surfaceMedianMS = 0
        surfaceP95MS = 0
    }

    /// Redraws the tracks when a round has published, and updates the HUD.
    private func renderSurfaces() {
        let snapshot = liveSurfaces.latest()
        guard snapshot.version != surfaceVersion else { return }
        surfaceVersion = snapshot.version
        surfaceRenderer.update(snapshot.surfaces)
        let confirmed = snapshot.surfaces.count { $0.state == .confirmed }
        if confirmed != surfaceConfirmed { surfaceConfirmed = confirmed }
        if snapshot.surfaces.count != surfaceTotal { surfaceTotal = snapshot.surfaces.count }
        surfaceMS = snapshot.report.milliseconds
        let recent = snapshot.recentMilliseconds.sorted()
        if !recent.isEmpty {
            surfaceMedianMS = recent[recent.count / 2]
            surfaceP95MS = recent[min(Int(Double(recent.count - 1) * 0.95 + 0.5), recent.count - 1)]
        }
        if snapshot.skipped != surfaceSkipped { surfaceSkipped = snapshot.skipped }
        if let bench = snapshot.benchmark, bench != benchmarkShown {
            benchmarkShown = bench
            let line = String(
                format: "benchmark: %d runs on %d points, median %.1f ms, p95 %.1f ms, max %.1f ms, %d planes, %d hypotheses",
                bench.runs, bench.points, bench.median, bench.p95, bench.max, bench.planes, bench.hypotheses
            )
            benchmarkLine = line
            logger.info("RANSAC \(line, privacy: .public)")
            recorder.note(kind: "benchmark", detail: line)
        }
        if let error = snapshot.lastError, error != surfaceError {
            surfaceError = error
            logger.error("RANSAC round failed: \(error, privacy: .public)")
        }
        for event in snapshot.report.events {
            switch event {
            case .add, .update: continue
            case let .merge(survivor, absorbed):
                logger.info("RANSAC merge: \(absorbed, privacy: .public) into \(survivor, privacy: .public)")
            case let .stale(id):
                logger.info("RANSAC stale: \(id, privacy: .public)")
            case let .drop(id):
                logger.debug("RANSAC drop: \(id, privacy: .public)")
            }
        }
    }

    private func applyDebugOptions() {
        var options: ARView.DebugOptions = []
        if showFeaturePoints { options.insert(.showFeaturePoints) }
        if showStatistics { options.insert(.showStatistics) }
        arView.debugOptions = options
    }

    // MARK: Anchor pipeline

    private func ingest(_ planeAnchors: [ARPlaneAnchor], now: TimeInterval) {
        for anchor in planeAnchors {
            anchors[anchor.identifier] = anchor
            let previous = tracker.observations[anchor.identifier]
            tracker.upsert(PlaneObservation(anchor: anchor, previous: previous, now: now))
            dirty.insert(anchor.identifier)
        }
        needsResolve = true
    }

    /// Re-resolves NMS, then renders dirty planes plus any plane whose suppression flipped.
    private func resolveAndRender(now: TimeInterval) {
        var toRender = dirty
        if needsResolve {
            let before = tracker.states.mapValues(\.isSuppressed)
            tracker.resolve()
            for (id, state) in tracker.states where before[id] != state.isSuppressed {
                toRender.insert(id)
            }
            needsResolve = false
        }
        dirty.removeAll()
        for id in toRender where render(id: id, now: now) {
            dirty.insert(id) // geometry change deferred by the rebuild gate; retry next tick
        }
        publishCounts()
    }

    /// - Returns: true when the plane still has a deferred geometry update.
    private func render(id: UUID, now: TimeInterval) -> Bool {
        guard let anchor = anchors[id], let observation = tracker.observations[id], let state = tracker.states[id] else { return false }
        return renderer.update(
            anchor: anchor, observation: observation, state: state, hideSuppressed: hideSuppressed,
            hideAll: !showARKitPlanes, now: now
        )
    }

    /// Full refresh, only for HUD toggles.
    private func renderAll() {
        for id in anchors.keys where render(id: id, now: lastFrameTime) {
            dirty.insert(id)
        }
    }

    private func publishCounts() {
        if rawCount != anchors.count { rawCount = anchors.count }
        if keptCount != tracker.keptCount { keptCount = tracker.keptCount }
    }
}

// MARK: - ARSessionDelegate

extension ARSessionController: @preconcurrency ARSessionDelegate {
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let planes = anchors.compactMap { $0 as? ARPlaneAnchor }
        guard !planes.isEmpty else { return }
        planes.forEach(renderer.add)
        ingest(planes, now: lastFrameTime)
        recorder.record(planes, event: .add)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let planes = anchors.compactMap { $0 as? ARPlaneAnchor }
        guard !planes.isEmpty else { return }
        ingest(planes, now: lastFrameTime)
        recorder.record(planes, event: .update)
    }

    /// ARKit reports plane merges here: the absorbed anchor is removed. Visuals go away immediately.
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let planes = anchors.compactMap { $0 as? ARPlaneAnchor }
        guard !planes.isEmpty else { return }
        for plane in planes {
            self.anchors[plane.identifier] = nil
            dirty.remove(plane.identifier)
            tracker.remove(id: plane.identifier)
            renderer.remove(id: plane.identifier)
        }
        needsResolve = true
        recorder.record(planes, event: .remove)
    }

    /// Frame tick: throttled resolve/render, HUD and memory readout. Never retains the frame.
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = frame.timestamp
        lastFrameTime = now
        fpsWindow.frames += 1
        if now - fpsWindow.start >= 1 {
            fps = Double(fpsWindow.frames) / (now - fpsWindow.start)
            fpsWindow = (now, 0)
        }
        // One copy of the frame's pose and points, shared by the recorder and the cloud. While recording, the cloud
        // sees only the frames the writer accepted, numbered like the recording (P22).
        let record = ARRecordAdapter.frameRecord(frame)
        let index = recorder.capture(frame, metadata: record)
        if index != nil || !recorder.isRecording {
            liveCloud.ingest(
                camera: record.camera, trackingNormal: record.tracking == .normal, points: record.points,
                ids: record.pointIDs, recordIndex: index
            )
        }
        if (needsResolve || !dirty.isEmpty) && resolveThrottle.fire(now: now) {
            resolveAndRender(now: now)
        }
        if showCloud && cloudThrottle.fire(now: now) {
            cloudRenderer.update(liveCloud.latest().state, camera: record.camera)
        }
        lastCamera = record.camera
        if showSurfaces {
            if surfaceThrottle.fire(now: now) {
                liveSurfaces.submit(cloud: liveCloud.latest().state, camera: record.camera, recordIndex: index)
            }
            if surfaceRenderThrottle.fire(now: now) {
                renderSurfaces()
            }
        }
        if hudThrottle.fire(now: now) {
            exposure.refresh()
            exposureMS = frame.camera.exposureDuration * 1000
            iso = exposure.iso
            if exposureControlAvailable != exposure.isAvailable { exposureControlAvailable = exposure.isAvailable }
            let points = record.points.count
            if points != featurePointCount { featurePointCount = points }
            let cloud = liveCloud.latest().state.count
            if cloud != cloudCount { cloudCount = cloud }
        }
        if memoryThrottle.fire(now: now), let mb = MemoryFootprint.currentMB() {
            memoryMB = mb
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        trackingName = camera.trackingState.shortName
        banner = interruptionBanner ?? camera.trackingState.banner
        logger.info("Tracking state: \(self.trackingName, privacy: .public)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        recorder.stop(reason: .interruption)
        interruptionBanner = "Session interrupted — camera unavailable"
        banner = interruptionBanner
        logger.warning("Session interrupted")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        interruptionBanner = nil
        banner = "Interruption ended — relocalizing (tap Reset if planes look wrong)"
        logger.info("Session interruption ended")
    }

    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        true
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        logger.error("Session failed: \(error.localizedDescription, privacy: .public)")
        recorder.stop(reason: .error)
        errorMessage = error.localizedDescription
    }
}
