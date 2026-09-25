import ARKit
import AVFoundation
import OSLog
import PlaneKit

/// Caps the camera's exposure time through the capture device ARKit hands out (P30), so auto exposure trades blur
/// for ISO. ARKit may refuse (`configurableCaptureDeviceForPrimaryCamera` is nil when it keeps the camera for itself);
/// then `isAvailable` is false and ARKit's auto exposure stays in charge.
///
/// The cap is lost whenever the camera format changes, so `refresh()` checks it on the HUD tick and applies it again.
@MainActor
final class ExposureControl {
    var cap: ExposureCap {
        didSet { if cap != oldValue { needsApply = true } }
    }
    /// Nil until the first `refresh()`.
    private(set) var isAvailable: Bool?
    private var needsApply = true
    private let logger = Logger(subsystem: "br.com.neuralnexgen.sidingsar", category: "exposure")

    init(cap: ExposureCap) {
        self.cap = cap
    }

    /// The session ran again; the camera may have been reconfigured.
    func sessionDidRun() {
        needsApply = true
    }

    /// The camera's current ISO, when ARKit shares the device.
    var iso: Float? {
        ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera?.iso
    }

    /// Applies the cap when it changed, when the session ran again, or when the camera lost it. Cheap otherwise.
    func refresh() {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else {
            if isAvailable != false {
                logger.warning("ARKit doesn't share the camera; exposure stays automatic")
            }
            isAvailable = false
            return
        }
        isAvailable = true
        let format = device.activeFormat
        let target = cap.seconds(
            formatMin: format.minExposureDuration.seconds, formatMax: format.maxExposureDuration.seconds
        )
        let drifted = target.map { ExposureCap.needsReapply(current: device.activeMaxExposureDuration.seconds, target: $0) }
        guard needsApply || drifted == true else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            // Out-of-range values raise an Objective-C exception, which Swift can't catch. At the format's limits,
            // use its own CMTime values rather than a rounded conversion that could land just outside them.
            device.activeMaxExposureDuration = target.map { seconds in
                if seconds <= format.minExposureDuration.seconds { return format.minExposureDuration }
                if seconds >= format.maxExposureDuration.seconds { return format.maxExposureDuration }
                return CMTime(seconds: seconds, preferredTimescale: 1_000_000)
            } ?? .invalid
            needsApply = false
            logger.info("Max exposure \(self.cap.label, privacy: .public) (\(device.activeMaxExposureDuration.seconds * 1000) ms)")
        } catch {
            logger.error("Exposure cap failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
