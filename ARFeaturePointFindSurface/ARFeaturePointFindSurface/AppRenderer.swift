//
//  AppRenderer.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/24/25.
//

import Metal
import MetalKit
import ARKit

import FindSurface_iOS

private enum PreviewShape {
    case none
    case plane
    case sphere
    case cylinder
    case cone
    case torus
    case partialTorus
}

fileprivate let maxInFlight: Int = 3

final class AppRenderer {

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    
    private let capturedImageRenderer: CapturedImageRenderer
    
    private let rawFeaturePointRenderer: RawFeaturePointRenderer
    
    private let pointCloudRenderer: PointCloudRenderer
    private var pointCloudBuffers: [PointCloudBuffer]
    
    private let planeRenderer: PlaneRenderer
    private var previewPlane: PlaneBuffer
    private var planes: [PlaneBuffer] = []
    
    private let sphereRenderer: SphereRenderer
    private var previewSphere: SphereBuffer
    private var spheres: [SphereBuffer] = []

    private let cylinderRenderer: CylinderRenderer
    private var previewCylinder: CylinderBuffer
    private var cylinders: [CylinderBuffer] = []
    
    private let coneRenderer: ConeRenderer
    private var previewCone: ConeBuffer
    private var cones: [ConeBuffer] = []
    
    private let torusRenderer: TorusRenderer
    private var previewTorus: TorusBuffer
    private var toruses: [TorusBuffer] = []
    
    private let partialTorusRenderer: PartialTorusRenderer
    private var previewPartialTorus: PartialTorusBuffer
    private var partialToruses: [PartialTorusBuffer] = []
    
    private let inlierPointRenderer: InlierPointRenderer
    private var inlierPointBuffers: [InlierPointBuffer] = []
    
    private var transform: TransformBuffer
    
    private var inFlightIndex: Int = 0
    private let inFlightSemaphore: DispatchSemaphore
    private let textureCache: CVMetalTextureCache
    
    private var previewShape = PreviewShape.none
    
    init(_ state: AppState, _ maxBinCount: Int) {
        let device = MTLCreateSystemDefaultDevice()!
        let library = device.makeDefaultLibrary()!
        let commandQueue = device.makeCommandQueue()!
        
        let capturedImageRenderer = CapturedImageRenderer(device, library)
        let rawFeaturePointRenderer = RawFeaturePointRenderer(device, library)
        let pointCloudRenderer = PointCloudRenderer(device, library)
        let pointCloudBufers: [PointCloudBuffer] = [
            .init(device, maxBinCount),
            .init(device, maxBinCount),
            .init(device, maxBinCount)
        ]
        let planeRenderer = PlaneRenderer(device, library)
        let previewPlane = PlaneBuffer(device: device)
        let sphereRenderer = SphereRenderer(device, library)
        let previewSphere = SphereBuffer(device: device)
        let cylinderRenderer = CylinderRenderer(device, library)
        let previewCylinder = CylinderBuffer(device: device)
        let coneRenderer = ConeRenderer(device, library)
        let previewCone = ConeBuffer(device: device)
        let torusRenderer = TorusRenderer(device, library)
        let previewTorus = TorusBuffer(device: device)
        let partialTorusRenderer = PartialTorusRenderer(device, library)
        let previewPartialTorus = PartialTorusBuffer(device: device)
        let inlierPointRenderer = InlierPointRenderer(device, library)
        
        let transform = TransformBuffer(device: device)
        
        let inFlightSemaphore = DispatchSemaphore(value: maxInFlight)
        var textureCache: CVMetalTextureCache? = nil
        _ = CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        
        self.device = device
        self.commandQueue = commandQueue
        self.capturedImageRenderer = capturedImageRenderer
        self.rawFeaturePointRenderer = rawFeaturePointRenderer
        self.pointCloudRenderer = pointCloudRenderer
        self.pointCloudBuffers = pointCloudBufers
        self.planeRenderer = planeRenderer
        self.previewPlane = previewPlane
        self.sphereRenderer = sphereRenderer
        self.previewSphere = previewSphere
        self.cylinderRenderer = cylinderRenderer
        self.previewCylinder = previewCylinder
        self.coneRenderer = coneRenderer
        self.previewCone = previewCone
        self.torusRenderer = torusRenderer
        self.previewTorus = previewTorus
        self.partialTorusRenderer = partialTorusRenderer
        self.previewPartialTorus = previewPartialTorus
        self.inlierPointRenderer = inlierPointRenderer
        self.transform = transform
        self.inFlightSemaphore = inFlightSemaphore
        self.textureCache = textureCache!
        
        self.capturedImageRenderer.transform = self.transform
        self.rawFeaturePointRenderer.pointColor = .rawFeaturePointColor
        self.rawFeaturePointRenderer.transform = self.transform
        self.pointCloudRenderer.pointColor = currentColorSet.pointCloud
        self.pointCloudRenderer.transform = self.transform
        self.planeRenderer.transform = self.transform
        self.sphereRenderer.transform = self.transform
        self.cylinderRenderer.transform = self.transform
        self.coneRenderer.transform = self.transform
        self.torusRenderer.transform = self.transform
        self.partialTorusRenderer.transform = self.transform
        self.inlierPointRenderer.transform = self.transform
    }
    
    func viewDidChangeOrientation(_ orientation: UIInterfaceOrientation,
                                  _ inverseDisplayTransform: simd_float3x3) {
        transform.displayTransform = inverseDisplayTransform
        rawFeaturePointRenderer.isPortrait = orientation.isPortrait
        pointCloudRenderer.isPortrait = orientation.isPortrait
        inlierPointRenderer.isPortrait = orientation.isPortrait
    }
    
    func wait() {
        inFlightSemaphore.wait()
    }
    
    func updateCapturedImage(_ image: CVPixelBuffer,
                             _ textureHolder: inout [CVMetalTexture]) {
        
        let cvTextureY = image.makeCVMetalTexture(pixelFormat: .r8Unorm,
                                                  planeIndex: 0,
                                                  textureCache: textureCache)
        let cvTextureCbCr = image.makeCVMetalTexture(pixelFormat: .rg8Unorm,
                                                     planeIndex: 1,
                                                     textureCache: textureCache)
        guard let cvTextureY,
              let cvTextureCbCr,
              let textureY = cvTextureY.texture,
              let textureCbCr = cvTextureCbCr.texture
        else { return }
        
        capturedImageRenderer.textureY = textureY
        capturedImageRenderer.textureCbCr = textureCbCr
        textureHolder.append(cvTextureY)
        textureHolder.append(cvTextureCbCr)
    }
    
    func updateRawFeaturePoint(_ points: [simd_float3]) {
        rawFeaturePointRenderer.updatePoints(points)
    }
    
    func updatePickedIndex(_ index: Int) {
        pointCloudRenderer.pickedIndex = index
    }
    
    func updatePointCloudStream<C>(_ pointCloud: C) where C: Collection, C.Element == simd_float3 {
        for i in inFlightIndex..<(inFlightIndex + maxInFlight) {
            pointCloudBuffers[i % maxInFlight].updatePointCloud(pointCloud)
        }
    }
    
    func clearPointCloudStream() {
        for i in 0..<maxInFlight {
            pointCloudBuffers[i].clear()
        }
    }
    
    func updateTransform(_ viewMatrix: simd_float4x4,
                         _ projectionMatrix: simd_float4x4) {
        
        transform.viewMatrix = viewMatrix
        transform.projectionMatrix = projectionMatrix
        transform.viewProjectionMatrix = projectionMatrix * viewMatrix
    }
    
    func setPreviewNone() {
        previewShape = .none
    }
    
    func updatePreview(_ plane: Plane) {
        previewPlane.update(from: plane)
        previewShape = .plane
    }
    
    func updatePreview(_ sphere: Sphere) {
        previewSphere.update(from: sphere)
        previewShape = .sphere
    }
    
    func updatePreview(_ cylinder: Cylinder) {
        previewCylinder.update(from: cylinder)
        previewShape = .cylinder
    }
    
    func updatePreview(_ cone: Cone) {
        previewCone.update(from: cone)
        previewShape = .cone
    }
    
    func updatePreview(_ torus: Torus, _ inliers: [simd_float3]) {
        
        let e = torus.extrinsics
        let t = torus.transform
        let (begin, delta) = calcTorusAngleRange(from: inliers.map { simd_make_float3(t * simd_float4($0, 1)) })
        if delta > 1.5 * Float.pi {
            previewTorus.update(from: torus)
            previewShape = .torus
        } else {
            let start = simd_make_float3(e * simd_float4(cos(begin), 0, sin(begin), 1))
            previewPartialTorus.update(from: torus, start: start, angle: delta)
            previewShape = .partialTorus
        }
    }
    
    func appendPlane(_ plane: Plane, _ inliers: [simd_float3]) {
        let buffer = PlaneBuffer(device: device, plane: plane)
        planes.append(buffer)
        let inlierBuffer = InlierPointBuffer(device, inliers, simd_float4(currentColorSet.planeInlier, 1))
        inlierPointBuffers.append(inlierBuffer)
    }
    
    func appendSphere(_ sphere: Sphere, _ inliers: [simd_float3]) {
        let buffer = SphereBuffer(device: device, sphere: sphere)
        spheres.append(buffer)
        let inlierBuffer = InlierPointBuffer(device, inliers, simd_float4(currentColorSet.sphereInlier, 1))
        inlierPointBuffers.append(inlierBuffer)
    }
    
    func appendCylinder(_ cylinder: Cylinder, _ inliers: [simd_float3]) {
        let buffer = CylinderBuffer(device: device, cylinder: cylinder)
        cylinders.append(buffer)
        let inlierBuffer = InlierPointBuffer(device, inliers, simd_float4(currentColorSet.cylinderInlier, 1))
        inlierPointBuffers.append(inlierBuffer)
    }
    
    func appendCone(_ cone: Cone, _ inliers: [simd_float3]) {
        let buffer = ConeBuffer(device: device, cone: cone)
        cones.append(buffer)
        let inlierBuffer = InlierPointBuffer(device, inliers, simd_float4(.coneInlierColor, 1))
        inlierPointBuffers.append(inlierBuffer)
    }
    
    func appendTorus(_ torus: Torus, _ inliers: [simd_float3]) -> Bool {
        
        let e = torus.extrinsics
        let t = torus.transform
        let (begin, delta) = calcTorusAngleRange(from: inliers.map { simd_make_float3(t * simd_float4($0, 1)) })
        let inlierBuffer = InlierPointBuffer(device, inliers, simd_float4(.torusInlierColor, 1))
        inlierPointBuffers.append(inlierBuffer)
        if delta > 1.5 * Float.pi {
            let buffer = TorusBuffer(device: device, torus: torus)
            toruses.append(buffer)
            return false
        } else {
            let start = simd_make_float3(e * simd_float4(cos(begin), 0, sin(begin), 1))
            let buffer = PartialTorusBuffer(device: device, torus: torus, start: start, angle: delta)
            partialToruses.append(buffer)
            return true
        }
    }
    
    func removeLastPlane() { planes.removeLast() }
    func removeLastSphere() { spheres.removeLast() }
    func removeLastCylinder() { cylinders.removeLast() }
    func removeLastCone() { cones.removeLast() }
    func removeLastTorus() { toruses.removeLast() }
    func removeLastPartialTorus() { partialToruses.removeLast() }
    func removeLastInlierPoints() { inlierPointBuffers.removeLast() }

    func clearGeometries() {
        planes.removeAll(keepingCapacity: true)
        spheres.removeAll(keepingCapacity: true)
        cylinders.removeAll(keepingCapacity: true)
        cones.removeAll(keepingCapacity: true)
        toruses.removeAll(keepingCapacity: true)
        partialToruses.removeAll(keepingCapacity: true)
        inlierPointBuffers.removeAll(keepingCapacity: true)
    }
    
    func draw(view: MTKView, textureHolder: [CVMetalTexture]) {
        
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor),
              let drawable = view.currentDrawable else { return }
        
        capturedImageRenderer.draw(encoder: encoder)
        
//        rawFeaturePointRenderer.draw(encoder: encoder)
        pointCloudRenderer.draw(encoder: encoder, buffer: pointCloudBuffers[inFlightIndex])
        
        inlierPointRenderer.draw(encoder: encoder, buffers: inlierPointBuffers)
        
        planeRenderer.draw(planes: planes, encoder: encoder)
        sphereRenderer.draw(spheres: spheres, encoder: encoder)
        cylinderRenderer.draw(cylinders: cylinders, encoder: encoder)
        coneRenderer.draw(cones: cones, encoder: encoder)
        torusRenderer.draw(toruses: toruses, encoder: encoder)
        partialTorusRenderer.draw(toruses: partialToruses, encoder: encoder)
        
        switch previewShape {
        case .plane: planeRenderer.draw(plane: previewPlane, encoder: encoder)
        case .sphere: sphereRenderer.draw(sphere: previewSphere, encoder: encoder)
        case .cylinder: cylinderRenderer.draw(cylinder: previewCylinder, encoder: encoder)
        case .cone: coneRenderer.draw(cone: previewCone, encoder: encoder)
        case .torus: torusRenderer.draw(torus: previewTorus, encoder: encoder)
        case .partialTorus: partialTorusRenderer.draw(torus: previewPartialTorus, encoder: encoder)
        default: break
        }
        
        encoder.endEncoding()
        
        var textureHolder = textureHolder
        commandBuffer.addCompletedHandler { [weak self] _ in
            textureHolder.removeAll()
            self?.inFlightSemaphore.signal()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        
        inFlightIndex = (inFlightIndex + 1) % maxInFlight
    }
}

fileprivate func makeOrthonormalBases(_ n: simd_float3) -> (simd_float3, simd_float3) {
    guard n.z >= -0.999999 else {
        return (.init(0, -1, 0), .init(-1, 0, 0))
    }
    
    let a = 1.0 / (1.0 + n.z)
    let bx = -n.x * n.y * a
    let t = simd_float3(1.0 - n.x * n.x * a, bx, -n.x)
    let b = simd_float3(bx, 1.0 - n.y * n.y * a, -n.y)
    return (t, b)
}

fileprivate func angle(_ a: simd_float3, _ b: simd_float3, _ c: simd_float3 = .init(0, -1, 0)) -> Float {
    let angle = acos(dot(a, b))
    if dot(c, cross(a, b)) < 0 {
        return -angle
    } else {
        return angle
    }
}

fileprivate func calcTorusAngleRange(from inliers: [simd_float3]) -> (begin: Float, delta: Float) {
    
    let projected = inliers.map { point in
        normalize(simd_float3(point.x, 0, point.z))
    }
    var projectedCenter = projected.reduce(.zero, +) / Float(projected.count)
    
    if length(projectedCenter) < 0.1 {
        return (begin: .zero, delta: .pi * 2.0)
    }
    projectedCenter = normalize(projectedCenter)
    
    let baseAngle = angle(.init(1, 0, 0), projectedCenter)
    
    let angles = projected.map {
        return angle(projectedCenter, $0)
    }
    
    guard let beginAngle = angles.min(),
          let endAngle = angles.max() else {
        return (begin: .zero, delta: .pi * 2.0)
    }
    
    let begin = beginAngle + baseAngle
    let end = endAngle + baseAngle
    let delta = end - begin
    
    return (begin: end, delta: delta)
}
