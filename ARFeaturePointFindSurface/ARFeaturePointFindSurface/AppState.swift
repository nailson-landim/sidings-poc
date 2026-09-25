//
//  AppState.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/24/25.
//

import SwiftUI
import Metal
import MetalKit
import ARKit

import FindSurface_iOS

fileprivate let maxBinCount: Int = 100_000
fileprivate let maxBinSize: Int = 100

@Observable
final class AppState: MetalViewDelegate {
    
    var device: MTLDevice { renderer.device }
    
    @ObservationIgnored
    private lazy var renderer: AppRenderer = { AppRenderer(self, maxBinCount) }()
    
    @ObservationIgnored
    private var frameProvider: ARFrameProvider
    
    var toastMessage: String = ""
    
    init(preview: Bool = false) {
        let frameProvider: any ARFrameProvider = if preview {
            ARPreviewFrameProvider()
        } else {
            ARWorldTrackingFrameProvider()
        }
        
        if preview {
            hasMotionTrackingStabilized = true
        }
        
        self.frameProvider = frameProvider
    }
    
    func configure(view: MTKView, context: Context) {
        /* do nothing */
    }
    
    // -- MARK: View resizing
    @ObservationIgnored
    private var shouldUpdateDisplayTransform: Bool = false
    private func updateDisplayTransform(_ frame: ARFrame) {
        guard shouldUpdateDisplayTransform else { return }
        
        let displayTransform = frame.displayTransform(for: orientation,
                                                      viewportSize: drawableSize).inverted()
        let transform = simd_float3x3(
            .init(Float(displayTransform.a), Float(displayTransform.b), 0),
            .init(Float(displayTransform.c), Float(displayTransform.d), 0),
            .init(Float(displayTransform.tx), Float(displayTransform.ty), 1)
        )
        
        renderer.viewDidChangeOrientation(orientation, transform)
        shouldUpdateDisplayTransform = false
    }
    
    @ObservationIgnored
    private var drawableSize: CGSize = .zero {
        didSet { if oldValue != drawableSize { shouldUpdateDisplayTransform = true } }
    }
    
    var orientation: UIInterfaceOrientation = .currentValue {
        didSet { if oldValue != orientation { shouldUpdateDisplayTransform  = true } }
    }
    
    func resize(view: MTKView, drawableSize: CGSize) {
        self.drawableSize = drawableSize
    }
    
    
    // -- MARK: Motion tracking stabilization
    private(set) var motionTrackingStabilizationStarted: Bool = false
    private(set) var enoughFeaturesDetected: Bool = false
    private(set) var hasMotionTrackingStabilized: Bool = false
    
    private(set) var stabilizationHelper = MotionTrackingStabilizationHelper()
    
    private func updateMotionTrackingStabilizationState(_ camera: ARCamera,
                                                        _ featureCount: Int) {
        
        if enoughFeaturesDetected && featureCount < 150 {
            enoughFeaturesDetected = false
        }
        if !enoughFeaturesDetected && featureCount >= 150 {
            enoughFeaturesDetected = true
            if !motionTrackingStabilizationStarted {
                motionTrackingStabilizationStarted = true
            }
        }
        
        if !hasMotionTrackingStabilized {
            hasMotionTrackingStabilized = stabilizationHelper.hasEnoughScans(camera, featureCount)
            if hasMotionTrackingStabilized {
                recording = true
                previewEnabled = true
            }
        }
    }
    
    
    // -- MARK: Point collecting
    var recording: Bool = false
    private(set) var pointcloud: [simd_float3] = []
    
    @ObservationIgnored
    private var cameraMotionDetector = CameraMotionDetector()
    
    @ObservationIgnored
    private var featureCompressor = FeatureCompressor(maxIdentifierCount: maxBinCount,
                                                      maxPointBinSize: maxBinSize)
    
    func clearPoints() {
        featureCompressor.clear()
        renderer.clearPointCloudStream()
        pointcloud.removeAll(keepingCapacity: true)
    }
    
    private func collectPoints(_ features: ARPointCloud?, _ camera: ARCamera) {
        guard let features else { return }
        
        var points = features.points
        var identifiers = features.identifiers
        let viewMatrix = camera.viewMatrix(for: orientation)
        
        let invalidIndices = points.indices { point in
            // Filters out points that are within 0.25 meters from the camera (0.25 x 0.25 = 0.0625)
            simd_length_squared(simd_make_float3(viewMatrix * simd_float4(point, 1))) <= 0.0625
        }
        
        if !invalidIndices.isEmpty {
            points.removeSubranges(invalidIndices)
            identifiers.removeSubranges(invalidIndices)
        }
        
        renderer.updateRawFeaturePoint(points)
        
        if recording && cameraMotionDetector.hasCameraMovedEnough(camera) {
            featureCompressor.append(features: points, with: identifiers)
            
            if featureCompressor.updated {
                let compressedPoints = featureCompressor.pointList.values
                renderer.updatePointCloudStream(compressedPoints)
                pointcloud = Array(compressedPoints)
                featureCompressor.updated = false
            }
        }
    }
    
    // -- MARK: FindSurface
    var previewEnabled: Bool = false
    var hasToSaveOne: Bool = false
    
    var seedRadiusRatio: CGFloat = .zero
    var probeRadiusRatio: CGFloat = .zero
    
    @ObservationIgnored
    private var latestFound: FindSurface.Result? = nil
    
    private(set) var transactions: [AppTransaction] = []
    
    private func detectGeometries(_ camera: ARCamera) {
        
        let pickingResult = pickPoints(pointcloud, camera)
        renderer.updatePickedIndex(pickingResult?.index ?? -1)
        
        guard let pickingResult,
        previewEnabled || hasToSaveOne else {
            renderer.setPreviewNone()
            return
        }
        let hasToSaveOne = hasToSaveOne
        if self.hasToSaveOne { self.hasToSaveOne = false }
        
        let pickedIndex = pickingResult.index
        let pickedDepth = pickingResult.depth
        
        Task {
            do {
                var result = try await FindSurface.instance.perform {
                    let tanHalfFovy = camera.tanHalfFovy
                    let seedRadius = tanHalfFovy * Float(seedRadiusRatio) * pickedDepth
                    FindSurface.instance.seedRadius = seedRadius
                    
                    return (pointcloud, pickedIndex)
                }
                
                if result != nil {
                    if hasToSaveOne {
                        if case .none(_) = result!, let latestFound {
                            result = latestFound
                        }
                    } else {
                        latestFound = result
                    }
                } else {
                    if hasToSaveOne {
                        if let latestFound {
                            result = latestFound
                        } else {
                            toastMessage = "Nothing captured, Try again."
                            return
                        }
                    } else {
                        return
                    }
                }
                
                switch result {
                case let .foundPlane(plane, inliers, rmsError):
                    if hasToSaveOne {
                        toastMessage = String(format: "Captured plane! (rms error: %.1f cm)", rmsError * 100)
                        renderer.appendPlane(plane, inliers)
                        transactions.append(.addPlane)
                        latestFound = nil
                    } else {
                        renderer.updatePreview(plane)
                    }
                case let .foundSphere(sphere, inliers, rmsError):
                    if hasToSaveOne {
                        toastMessage = String(format: "Captured sphere! (rms error: %.1f cm)", rmsError * 100)
                        renderer.appendSphere(sphere, inliers)
                        transactions.append(.addSphere)
                        latestFound = nil
                    } else {
                        renderer.updatePreview(sphere)
                    }
                case let .foundCylinder(cylinder, inliers, rmsError):
                    if hasToSaveOne {
                        toastMessage = String(format: "Captured cylinder! (rms error: %.1f cm)", rmsError * 100)
                        renderer.appendCylinder(cylinder, inliers)
                        transactions.append(.addCylinder)
                        latestFound = nil
                    } else {
                        renderer.updatePreview(cylinder)
                    }
                case let .foundCone(cone, inliers, rmsError):
                    if hasToSaveOne {
                        toastMessage = String(format: "Captured cone! (rms error: %.1f cm)", rmsError * 100)
                        renderer.appendCone(cone, inliers)
                        transactions.append(.addCone)
                        latestFound = nil
                    } else {
                        renderer.updatePreview(cone)
                    }
                case let .foundTorus(torus, inliers, rmsError):
                    if hasToSaveOne {
                        toastMessage = String(format: "Captured torus! (rms error: %.1f cm)", rmsError * 100)
                        let isPartial = renderer.appendTorus(torus, inliers)
                        transactions.append(isPartial ? .addPartialTorus : .addTorus)
                        latestFound = nil
                    } else {
                        renderer.updatePreview(torus, inliers)
                    }
                default:
                    if hasToSaveOne {
                        self.toastMessage = "Nothing captured, Try again."
                    } else {
                        renderer.setPreviewNone()
                    }
                    latestFound = nil
                }
                
            } catch {
                fatalError("\(error)")
            }
        }
    }
    
    private func pickPoints(_ points: [simd_float3], _ camera: ARCamera) -> (index: Int, depth: Float)? {
        
        guard points.isEmpty == false else { return nil }
        
        let cameraPosition = camera.position
        let cameraDirection = normalize(camera.direction)
        let tanHalfFov = camera.tanHalfFovy
        let probeRadiusSlope = tanHalfFov * Float(probeRadiusRatio)
        
        var minIndex: Int = -1
        var minDistanceSquared: Float = .infinity
        var minDepth: Float = .infinity
        
        for (index, point) in points.enumerated() {
            // X = O + Dt
            // dot(P - X, D) = 0
            // dot(P - O - Dt, D) = 0
            // dot(P - O, D) = dot(D, D) * t
            // t = dot(P - O, D) / dot(D, D), dot(D, D) = 1
            // t = dot(P - O, D)
            let PO = point - cameraPosition
            let t = dot(PO, cameraDirection)
            guard t > 0 else { continue }
            
            let probeRadius = t * probeRadiusSlope
            let probeRadiusSquared = probeRadius * probeRadius
            
            // d2 = dot(P - X, P - X)
            //    = dot(P - O - Dt, P - O - Dt)
            //    = dot(P - O, P - O) - 2 * dot(P - O, D) * t + t * t, dot(P - O, D) = t
            //    = dot(P - O, P - O) - 2 * t * t + t * t
            //    = dot(P - O, P - O) - t * t
            let r2 = dot(PO, PO) - t * t
            
            guard r2 <= probeRadiusSquared else { continue }
            
            let d2 = length_squared(PO)
            if d2 < minDistanceSquared {
                minIndex = index
                minDistanceSquared = d2
                minDepth = t
            }
        }
        
        guard minIndex >= 0 else { return nil }
        
        return (minIndex, minDepth)
    }
    
    func undoDetectingGeometry() {
        guard transactions.isEmpty == false else { return }
        let t = transactions.removeLast()
        
        switch t {
        case .addPlane:         renderer.removeLastPlane()
        case .addSphere:        renderer.removeLastSphere()
        case .addCylinder:      renderer.removeLastCylinder()
        case .addCone:          renderer.removeLastCone()
        case .addTorus:         renderer.removeLastTorus()
        case .addPartialTorus:  renderer.removeLastPartialTorus()
        }
        
        renderer.removeLastInlierPoints()
    }
    
    func clearGeometries() {
        renderer.clearGeometries()
        transactions.removeAll(keepingCapacity: true)
    }
    
    func draw(view: MTKView) {
        
        guard let frame = frameProvider.currentFrame else { return }
        
        renderer.wait()
        
        updateDisplayTransform(frame)
        
        let camera = frame.camera
        let viewMatrix = camera.viewMatrix(for: orientation)
        let projectionMatrix = camera.projectionMatrix(for: orientation, viewportSize: drawableSize, zNear: 0.05, zFar: 65.0)
        renderer.updateTransform(viewMatrix, projectionMatrix)
        
        let capturedImage = frame.capturedImage
        var textureHolder = [CVMetalTexture]()
        renderer.updateCapturedImage(capturedImage, &textureHolder)
        
        let features = frame.rawFeaturePoints
        updateMotionTrackingStabilizationState(camera, features?.points.count ?? 0)
        
        collectPoints(features, camera)
        detectGeometries(camera)
        
        renderer.draw(view: view, textureHolder: textureHolder)
    }
    
    func viewDidAppear() {
        frameProvider.resume()
    }
    
    func viewDidDisappear() {
        frameProvider.pause()
    }
    
    var exporting: Bool = false
    var exportURL: URL? = nil
    var exportBinding: Binding<Bool> {
        Binding { self.exportURL != nil } set: { if !$0 { self.exportURL = nil } }
    }
    func exportPoints() {
        let points = pointcloud
        Task(priority: .userInitiated) {
            do {
                let url = try await exportToXYZ(points)
                await MainActor.run {
                    self.exportURL = url
                    self.exporting = false
                }
            } catch {
                await MainActor.run {
                    self.exporting = false
                    self.toastMessage = error.localizedDescription
                }
            }
        }
    }
    private func exportToXYZ(_ points: [simd_float3]) async throws -> URL {
        
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        
        let timestamp = formatter.string(from: Date.now)
        let filename = "pointcloud-\(timestamp).xyz"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        
        let fileHandle = try FileHandle(forWritingTo: url)
        defer { try? fileHandle.close() }
        
        var buffer = Data(capacity: 1_048_576)
        let fmt = "%f %f %f\n"
        
        for point in points {
            try Task.checkCancellation()
            let s = String(format: fmt, point.x, point.y, point.z)
            buffer.append(s.data(using: .utf8)!)
            
            if buffer.count >= 1_000_000 {
                try fileHandle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        
        if !buffer.isEmpty {
             try fileHandle.write(contentsOf: buffer)
        }
        return url
    }
}

extension AppState {
    static var preview: AppState = AppState(preview: true)
}
