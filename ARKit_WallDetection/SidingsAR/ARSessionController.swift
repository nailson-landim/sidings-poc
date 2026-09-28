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
        didSet { if mode != oldValue { restart() } }
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
    var showFeaturePoints = true {
        didSet { applyDebugOptions() }
    }
    var showStatistics = false {
        didSet { applyDebugOptions() }
    }
    private(set) var rawCount = 0
    private(set) var keptCount = 0
    private(set) var featurePointCount = 0
    private(set) var memoryMB: Double = 0
    private(set) var trackingName = "n/a"
    private(set) var banner: String?
    var errorMessage: String?

    // MARK: Internals

    /// Resolve/render cadence. Also paces NMS hysteresis (`challengerFrames` resolves ≈ 0.5 s).
    static let resolveInterval: TimeInterval = 0.1
    static let hudInterval: TimeInterval = 0.1
    static let memoryInterval: TimeInterval = 1.0

    @ObservationIgnored let arView: ARView
    /// Spike R1 (`../SPEC.md` §18 T3); replaced by the real recorder in T7.
    @ObservationIgnored let video = VideoCapture()
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
    @ObservationIgnored private var interruptionBanner: String?
    @ObservationIgnored private let logger = Logger(subsystem: "br.com.neuralnexgen.sidingsar", category: "session")

    override init() {
        arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        renderer = PlaneRenderer(scene: arView.scene)
        super.init()
        arView.session.delegate = self
        // Everything we draw is unlit debug geometry: skip post-processing passes and their full-screen buffers.
        arView.renderOptions = [
            .disableMotionBlur, .disableDepthOfField, .disableHDR, .disableCameraGrain,
            .disableGroundingShadows, .disableAREnvironmentLighting, .disablePersonOcclusion, .disableFaceMesh
        ]
        applyDebugOptions()
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
        video.stop(memoryMB: memoryMB)
        arView.session.pause()
    }

    func setVideoSpike(_ on: Bool) {
        if on {
            video.start(memoryMB: memoryMB)
        } else {
            video.stop(memoryMB: memoryMB)
        }
    }

    /// Drops every anchor and tracker state and restarts tracking from scratch.
    func restart() {
        video.stop(memoryMB: memoryMB)
        renderer.removeAll()
        tracker.reset()
        anchors.removeAll()
        dirty.removeAll()
        needsResolve = false
        interruptionBanner = nil
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
        logger.info("Running session: mode=\(self.mode.rawValue, privacy: .public) lidar=\(self.isLiDARDevice)")
        arView.session.run(config, options: options)
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
        return renderer.update(anchor: anchor, observation: observation, state: state, hideSuppressed: hideSuppressed, now: now)
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
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let planes = anchors.compactMap { $0 as? ARPlaneAnchor }
        guard !planes.isEmpty else { return }
        ingest(planes, now: lastFrameTime)
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
    }

    /// Frame tick: throttled resolve/render, HUD and memory readout. Never retains the frame.
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = frame.timestamp
        lastFrameTime = now
        video.capture(frame)
        if (needsResolve || !dirty.isEmpty) && resolveThrottle.fire(now: now) {
            resolveAndRender(now: now)
        }
        if hudThrottle.fire(now: now) {
            let points = frame.rawFeaturePoints?.points.count ?? 0
            if points != featurePointCount { featurePointCount = points }
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
        video.stop(memoryMB: memoryMB)
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
        video.stop(memoryMB: memoryMB)
        errorMessage = error.localizedDescription
    }
}
