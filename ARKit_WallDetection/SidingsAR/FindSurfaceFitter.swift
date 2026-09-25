import FindSurfaceFramework
import OSLog
import PlaneKit
import simd

/// Experiment X1 (`../EXPERIMENTS.md`): CurvSurf's FindSurface behind PlaneKit's `SurfaceFitter`.
///
/// It calls the framework's raw context, not the package's wrapper (XD4), so one round uploads the cloud once and then
/// fits many seeds. The points live in a buffer this class owns until the next upload, so the library never sees
/// a Swift array's temporary pointer. Used only on `LiveSurfaces`'s queue; FindSurface keeps one shared context.
nonisolated final class FindSurfaceFitter: SurfaceFitter {
    private static let logger = Logger(subsystem: "br.com.neuralnexgen.sidingsar", category: "findsurface")

    private let context = FindSurface.sharedInstance()
    private var buffer = UnsafeMutableBufferPointer<SIMD3<Float>>.allocate(capacity: 0)
    private var count = 0
    private var failedFits = 0

    func configure(_ settings: SurfaceSettings) {
        context.measurementAccuracy = settings.measurementAccuracy
        context.meanDistance = settings.meanDistance
        context.lateralExtension = Self.level(settings.lateralExtension)
        context.radialExpansion = Self.level(settings.radialExpansion)
        context.smartConversionOptions = []
    }

    deinit {
        buffer.deallocate()
    }

    func setPoints(_ points: [SIMD3<Float>]) throws {
        if buffer.count < points.count {
            let grown = UnsafeMutableBufferPointer<SIMD3<Float>>.allocate(capacity: max(points.count, buffer.count * 2))
            buffer.deallocate()
            buffer = grown
        }
        _ = buffer.initialize(from: points)
        count = points.count
        guard let base = buffer.baseAddress, count > 0 else { return }
        try context.setPointCloudData(
            UnsafeRawPointer(base), pointCount: count, pointStride: MemoryLayout<SIMD3<Float>>.stride,
            useDoublePrecision: false
        )
    }

    func fitPlane(seed: Int, radius: Float) throws -> SurfaceFit? {
        var rms: Float = 0
        let result: FindSurfaceResult?
        do {
            result = try context.findSurface(
                featureType: .plane, seedIndex: seed, seedRadius: radius, rmsError: &rms, requestInlierFlags: true
            )
        } catch {
            // One bad seed shouldn't end the round; the scanner counts it as a miss.
            failedFits += 1
            if failedFits == 1 || failedFits % 100 == 0 {
                Self.logger.error(
                    "FindSurface fit failed (\(self.failedFits) so far): \(String(describing: error), privacy: .public)"
                )
            }
            return nil
        }
        guard let result, let plane = result.getAsPlaneResult(), let flags = result.inlierFlags else { return nil }
        var inliers: [Int] = []
        inliers.reserveCapacity(flags.inlierCount)
        for i in 0..<count where flags.isInlier(at: i) {
            inliers.append(i)
        }
        return SurfaceFit(
            normal: plane.normal, center: plane.center,
            corners: [plane.lowerLeft, plane.lowerRight, plane.upperRight, plane.upperLeft],
            inliers: inliers, rmsError: rms
        )
    }

    private static func level(_ value: Int) -> FindSurface.SearchLevel {
        FindSurface.SearchLevel(rawValue: UInt32(min(max(value, 0), 10))) ?? .default
    }
}
