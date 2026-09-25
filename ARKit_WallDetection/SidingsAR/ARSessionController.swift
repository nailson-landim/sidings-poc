import ARKit
import Observation
import OSLog
import PlaneKit
import RealityKit

/// Owns the ARView/ARSession, feeds plane anchors through `PlaneTracker` (NMS + smoothing) and drives `PlaneRenderer`.
@Observable
@MainActor
final class ARSessionController: NSObject {
    // MARK: HUD state

    var mode: DetectionMode = .both {
        didSet { if mode != oldValue { restart() } }
    }
    var showMarkers = true {
        didSet { renderer.showMarkers = showMarkers }
    }
    var hideSuppressed = false {
        didSet { renderAll() }
    }
    private(set) var rawCount = 0
    private(set) var keptCount = 0
    private(set) var featurePointCount = 0
    private(set) var trackingName = "n/a"
    private(set) var banner: String?
    var errorMessage: String?

    // MARK: Internals

    @ObservationIgnored let arView: ARView
    @ObservationIgnored private let renderer: PlaneRenderer
    @ObservationIgnored private let tracker = PlaneTracker()
    @ObservationIgnored private var anchors: [UUID: ARPlaneAnchor] = [:]
    @ObservationIgnored private var lastHUDTick: TimeInterval = 0
    @ObservationIgnored private var interruptionBanner: String?
    @ObservationIgnored private let logger = Logger(subsystem: "br.com.neuralnexgen.sidingsar", category: "session")

    static let hudInterval: TimeInterval = 0.1

    override init() {
        arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        renderer = PlaneRenderer(scene: arView.scene)
        super.init()
        arView.session.delegate = self
        arView.renderOptions.insert(.disableMotionBlur)
    }

    var isLiDARDevice: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    func start() {
        run(options: [])
    }

    func pause() {
        arView.session.pause()
    }

    /// Drops every anchor and tracker state and restarts tracking from scratch.
    func restart() {
        renderer.removeAll()
        tracker.reset()
        anchors.removeAll()
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

    // MARK: Anchor pipeline

    private func ingest(_ planeAnchors: [ARPlaneAnchor], now: TimeInterval) {
        for anchor in planeAnchors {
            anchors[anchor.identifier] = anchor
            let previous = tracker.observations[anchor.identifier]
            tracker.upsert(PlaneObservation(anchor: anchor, previous: previous, now: now))
        }
    }

    /// Re-resolves NMS and refreshes every plane, since one update can flip another plane's state.
    private func resolveAndRender() {
        tracker.resolve()
        renderAll()
        publishCounts()
    }

    private func renderAll() {
        let now = CACurrentMediaTime()
        for (id, anchor) in anchors {
            guard let observation = tracker.observations[id], let state = tracker.states[id] else { continue }
            renderer.update(anchor: anchor, observation: observation, state: state, hideSuppressed: hideSuppressed, now: now)
        }
    }

    private func publishCounts() {
        rawCount = anchors.count
        keptCount = tracker.keptCount
    }
}

// MARK: - ARSessionDelegate

extension ARSessionController: @preconcurrency ARSessionDelegate {
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let planes = anchors.compactMap { $0 as? ARPlaneAnchor }
        guard !planes.isEmpty else { return }
        planes.forEach(renderer.add)
        ingest(planes, now: CACurrentMediaTime())
        resolveAndRender()
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let planes = anchors.compactMap { $0 as? ARPlaneAnchor }
        guard !planes.isEmpty else { return }
        ingest(planes, now: CACurrentMediaTime())
        resolveAndRender()
    }

    /// ARKit reports plane merges here: the absorbed anchor is removed.
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let planes = anchors.compactMap { $0 as? ARPlaneAnchor }
        guard !planes.isEmpty else { return }
        for plane in planes {
            self.anchors[plane.identifier] = nil
            tracker.remove(id: plane.identifier)
            renderer.remove(id: plane.identifier)
        }
        resolveAndRender()
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = frame.timestamp
        guard now - lastHUDTick >= Self.hudInterval else { return }
        lastHUDTick = now
        featurePointCount = frame.rawFeaturePoints?.points.count ?? 0
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        trackingName = camera.trackingState.shortName
        banner = interruptionBanner ?? camera.trackingState.banner
        logger.info("Tracking state: \(self.trackingName, privacy: .public)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
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
        errorMessage = error.localizedDescription
    }
}
