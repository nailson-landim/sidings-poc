//
//  GeometryRenderer.swift
//  ARPointCloudFindSurface
//
//  Created by CurvSurf-SGKim on 9/4/25.
//

import Metal
import simd

import FindSurface_iOS

@dynamicMemberLookup
final class UniformBuffer<T> {
    
    let buffer: MTLBuffer
    private let pointer: UnsafeMutablePointer<T>
    
    init(_ buffer: MTLBuffer) {
        self.buffer = buffer
        self.pointer = buffer.contents().bindMemory(to: T.self, capacity: 1)
    }
    
    convenience init(device: MTLDevice) {
        let length = MemoryLayout<T>.stride
        let options: MTLResourceOptions = [.storageModeShared, .cpuCacheModeWriteCombined]
        let buffer = device.makeBuffer(length: length, options: options)!
        self.init(buffer)
    }
    
    subscript<V>(dynamicMember keyPath: WritableKeyPath<T, V>) -> V {
        get { pointer.pointee[keyPath: keyPath] }
        set { pointer.pointee[keyPath: keyPath] = newValue }
    }
}

typealias TransformBuffer = UniformBuffer<TransformUniform>

typealias PlaneBuffer = UniformBuffer<PlaneUniform>
extension PlaneBuffer {
    func update(from plane: Plane, isPreview: Bool = false) {
        self.lowerLeft = plane.bottomLeft
        self.upperLeft = plane.topLeft
        self.lowerRight = plane.bottomRight
        self.upperRight = plane.topRight
        self.color = currentColorSet.plane
        self.lineColor = .zero
        self.opacity = isPreview ? 0.2 : 0.6
    }
    convenience init(device: MTLDevice, plane: Plane, isPreview: Bool = false) {
        self.init(device: device)
        self.update(from: plane, isPreview: isPreview)
    }
}

typealias SphereBuffer = UniformBuffer<SphereUniform>
extension SphereBuffer {
    func update(from sphere: Sphere, isPreview: Bool = false) {
        self.position = sphere.center
        self.radius = sphere.radius
        self.color = currentColorSet.sphere
        self.lineColor = .zero
        self.opacity = isPreview ? 0.2 : 0.6
    }
    convenience init(device: MTLDevice, sphere: Sphere, isPreview: Bool = false) {
        self.init(device: device)
        self.update(from: sphere, isPreview: isPreview)
    }
}

typealias CylinderBuffer = UniformBuffer<CylinderUniform>
extension CylinderBuffer {
    func update(from cylinder: Cylinder, isPreview: Bool = false) {
        self.top = cylinder.top
        self.bottom = cylinder.bottom
        self.radius = cylinder.radius
        self.color = currentColorSet.cylinder
        self.lineColor = .zero
        self.opacity = isPreview ? 0.2 : 0.6
    }
    convenience init(device: MTLDevice, cylinder: Cylinder, isPreview: Bool = false) {
        self.init(device: device)
        self.update(from: cylinder, isPreview: isPreview)
    }
}

typealias ConeBuffer = UniformBuffer<ConeUniform>
extension ConeBuffer {
    func update(from cone: Cone, isPreview: Bool = false) {
        self.top = cone.top
        self.bottom = cone.bottom
        self.topRadius = cone.topRadius
        self.bottomRadius = cone.bottomRadius
        self.color = .coneColor
        self.lineColor = .zero
        self.opacity = isPreview ? 0.2 : 0.6
    }
    convenience init(device: MTLDevice, cone: Cone, isPreview: Bool = false) {
        self.init(device: device)
        self.update(from: cone, isPreview: isPreview)
    }
}

typealias TorusBuffer = UniformBuffer<TorusUniform>
extension TorusBuffer {
    func update(from torus: Torus, isPreview: Bool = false) {
        self.center = torus.center
        self.axis = torus.axis
        self.meanRadius = torus.meanRadius
        self.tubeRadius = torus.tubeRadius
        self.color = .torusColor
        self.lineColor = .zero
        self.opacity = isPreview ? 0.2 : 0.6
    }
    convenience init(device: MTLDevice, torus: Torus, isPreview: Bool = false) {
        self.init(device: device)
        self.update(from: torus, isPreview: isPreview)
    }
}

typealias PartialTorusBuffer = UniformBuffer<PartialTorusUniform>
extension PartialTorusBuffer {
    func update(from torus: Torus, start: simd_float3, angle: Float, isPreview: Bool = false) {
        self.center = torus.center
        self.axis = torus.axis
        self.meanRadius = torus.meanRadius
        self.tubeRadius = torus.tubeRadius
        self.start = start
        self.angle = angle
        self.color = .torusColor
        self.lineColor = .zero
        self.opacity = isPreview ? 0.2 : 0.6
    }
    convenience init(device: MTLDevice, torus: Torus, start: simd_float3, angle: Float, isPreview: Bool = false) {
        self.init(device: device)
        self.update(from: torus, start: start, angle: angle, isPreview: isPreview)
    }
}

final class PlaneRenderer {
    
    let pipelineState: MTLRenderPipelineState
    let depthStencilState: MTLDepthStencilState
    
    init(_ device: MTLDevice, _ library: MTLLibrary) {
        
        let vertexFunction = library.makeFunction(name: "geometry_renderpass::plane::vertex_function")!
        let fragmentFunction = library.makeFunction(name: "geometry_renderpass::plane::fragment_function")!
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        pipelineDescriptor.rasterSampleCount = 1
        
        let pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        
        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.isDepthWriteEnabled = true
        depthStencilDescriptor.depthCompareFunction = .less
        
        let depthStencilState = device.makeDepthStencilState(descriptor: depthStencilDescriptor)!
        
        self.pipelineState = pipelineState
        self.depthStencilState = depthStencilState
    }
    
    var transform: TransformBuffer? = nil
    
    private func calcGridSize(_ plane: PlaneBuffer) -> simd_uint2 {
        let ll = plane.lowerLeft
        let lr = plane.lowerRight
        let ul = plane.upperLeft
        let hori = distance(ll, lr)
        let vert = distance(ll, ul)
        if hori > vert {
            return simd_uint2(UInt32(3 * hori / vert), 3)
        } else {
            return simd_uint2(3, UInt32(3 * hori / vert))
        }
    }
    
    func draw(planes: [PlaneBuffer], encoder: MTLRenderCommandEncoder) {
        
        guard let transform else { return }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthStencilState)
        
        encoder.setVertexBuffer(transform.buffer, offset: 0, index: 1)
        
        var isWireframe: Bool = false
        
        for plane in planes {
            var grid = calcGridSize(plane)
            encoder.setVertexBuffer(plane.buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&grid, length: MemoryLayout<simd_uint2>.size, index: 2)
            
            encoder.setFragmentBuffer(plane.buffer, offset: 0, index: 0)
            let vertexCount = Int(grid.x * grid.y * 6)
            
            encoder.setTriangleFillMode(.fill)
            isWireframe = false
            encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
            
            encoder.setTriangleFillMode(.lines)
            isWireframe = true
            encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        }
    }
    
    func draw(plane: PlaneBuffer, encoder: MTLRenderCommandEncoder) {
        
        guard let transform else { return }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthStencilState)
        
        encoder.setVertexBuffer(plane.buffer, offset: 0, index: 0)
        encoder.setVertexBuffer(transform.buffer, offset: 0, index: 1)
        let ll = plane.lowerLeft
        let lr = plane.lowerRight
        let ul = plane.upperLeft
        let hori = distance(ll, lr)
        let vert = distance(ll, ul)
        var grid = if hori > vert {
            simd_uint2(UInt32(3 * hori / vert), 3)
        } else {
            simd_uint2(3, UInt32(3 * hori / vert))
        }
        encoder.setVertexBytes(&grid, length: MemoryLayout<simd_uint2>.size, index: 2)
        
        encoder.setFragmentBuffer(plane.buffer, offset: 0, index: 0)
        
        let vertexCount = Int(grid.x * grid.y * 6)
        encoder.setTriangleFillMode(.fill)
        var isWireframe: Bool = false
        encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        
        encoder.setTriangleFillMode(.lines)
        isWireframe = true
        encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }
}

final class SphereRenderer {
    
    let pipelineState: MTLRenderPipelineState
    let depthStencilState: MTLDepthStencilState
    
    init(_ device: MTLDevice, _ library: MTLLibrary) {
        
        let vertexFunction = library.makeFunction(name: "geometry_renderpass::sphere::vertex_function")!
        let fragmentFunction = library.makeFunction(name: "geometry_renderpass::sphere::fragment_function")!
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "SphereRenderer"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        pipelineDescriptor.rasterSampleCount = 1
        
        let pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        
        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.isDepthWriteEnabled = true
        depthStencilDescriptor.depthCompareFunction = .less
        
        let depthStencilState = device.makeDepthStencilState(descriptor: depthStencilDescriptor)!
        
        self.pipelineState = pipelineState
        self.depthStencilState = depthStencilState
    }
    
    var transform: TransformBuffer? = nil
    
    func draw(spheres: [SphereBuffer], encoder: MTLRenderCommandEncoder) {
        
        guard let transform else { return }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthStencilState)
        
        encoder.setVertexBuffer(transform.buffer, offset: 0, index: 1)
        
        var grid = simd_uint2(36, 36)
        let vertexCount = Int(grid.x * grid.y * 6)
        var isWireframe: Bool = false
        
        for sphere in spheres {
            encoder.setVertexBuffer(sphere.buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&grid, length: MemoryLayout<simd_uint2>.size, index: 2)
            
            encoder.setFragmentBuffer(sphere.buffer, offset: 0, index: 0)
            
            encoder.setTriangleFillMode(.fill)
            isWireframe = false
            encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
            
            encoder.setTriangleFillMode(.lines)
            isWireframe = true
            encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        }
    }
    
    func draw(sphere: SphereBuffer, encoder: MTLRenderCommandEncoder) {
        
        guard let transform else { return }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthStencilState)
        
        encoder.setVertexBuffer(sphere.buffer, offset: 0, index: 0)
        encoder.setVertexBuffer(transform.buffer, offset: 0, index: 1)
        var grid = simd_uint2(36, 36)
        encoder.setVertexBytes(&grid, length: MemoryLayout<simd_uint2>.size, index: 2)
        
        encoder.setFragmentBuffer(sphere.buffer, offset: 0, index: 0)
        
        let vertexCount = Int(grid.x * grid.y * 6)
        encoder.setTriangleFillMode(.fill)
        var isWireframe: Bool = false
        encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        
        encoder.setTriangleFillMode(.lines)
        isWireframe = true
        encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }
}

final class CylinderRenderer {
    
    let pipelineState: MTLRenderPipelineState
    let depthStencilState: MTLDepthStencilState
    
    init(_ device: MTLDevice, _ library: MTLLibrary) {
        
        let vertexFunction = library.makeFunction(name: "geometry_renderpass::cylinder::vertex_function")!
        let fragmentFunction = library.makeFunction(name: "geometry_renderpass::cylinder::fragment_function")!
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        pipelineDescriptor.rasterSampleCount = 1
        
        let pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        
        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.isDepthWriteEnabled = true
        depthStencilDescriptor.depthCompareFunction = .less
        
        let depthStencilState = device.makeDepthStencilState(descriptor: depthStencilDescriptor)!
        
        self.pipelineState = pipelineState
        self.depthStencilState = depthStencilState
    }
    
    var transform: TransformBuffer? = nil
    
    func draw(cylinders: [CylinderBuffer], encoder: MTLRenderCommandEncoder) {
        
        guard let transform else { return }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthStencilState)
        
        encoder.setVertexBuffer(transform.buffer, offset: 0, index: 1)
        
        var grid = simd_uint2(36, 3)
        let vertexCount = Int(grid.x * grid.y * 6)
        var isWireframe: Bool = false
        
        for cylinder in cylinders {
            encoder.setVertexBuffer(cylinder.buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&grid, length: MemoryLayout<simd_uint2>.size, index: 2)
            
            encoder.setFragmentBuffer(cylinder.buffer, offset: 0, index: 0)
         
            encoder.setTriangleFillMode(.fill)
            isWireframe = false
            encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
            
            encoder.setTriangleFillMode(.lines)
            isWireframe = true
            encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        }
    }
    
    func draw(cylinder: CylinderBuffer, encoder: MTLRenderCommandEncoder) {
        
        guard let transform else { return }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthStencilState)
        
        encoder.setVertexBuffer(cylinder.buffer, offset: 0, index: 0)
        encoder.setVertexBuffer(transform.buffer, offset: 0, index: 1)
        var grid = simd_uint2(36, 3)
        encoder.setVertexBytes(&grid, length: MemoryLayout<simd_uint2>.size, index: 2)
        
        encoder.setFragmentBuffer(cylinder.buffer, offset: 0, index: 0)
        
        let vertexCount = Int(grid.x * grid.y * 6)
        encoder.setTriangleFillMode(.fill)
        var isWireframe: Bool = false
        encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        
        encoder.setTriangleFillMode(.lines)
        isWireframe = true
        encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }
}

final class ConeRenderer {
    
    let pipelineState: MTLRenderPipelineState
    let depthStencilState: MTLDepthStencilState
    
    init(_ device: MTLDevice, _ library: MTLLibrary) {
        
        let vertexFunction = library.makeFunction(name: "geometry_renderpass::cone::vertex_function")!
        let fragmentFunction = library.makeFunction(name: "geometry_renderpass::cone::fragment_function")!
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        pipelineDescriptor.rasterSampleCount = 1
        
        let pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        
        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.isDepthWriteEnabled = true
        depthStencilDescriptor.depthCompareFunction = .less
        
        let depthStencilState = device.makeDepthStencilState(descriptor: depthStencilDescriptor)!
        
        self.pipelineState = pipelineState
        self.depthStencilState = depthStencilState
    }
    
    var transform: TransformBuffer? = nil
    
    func draw(cones: [ConeBuffer], encoder: MTLRenderCommandEncoder) {
        
        guard let transform else { return }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthStencilState)
        
        encoder.setVertexBuffer(transform.buffer, offset: 0, index: 1)
        
        var grid = simd_uint2(36, 2)
        let vertexCount = Int(grid.x * grid.y * 6)
        var isWireframe: Bool = false
        
        for cone in cones {
            encoder.setVertexBuffer(cone.buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&grid, length: MemoryLayout<simd_uint2>.size, index: 2)
            
            encoder.setFragmentBuffer(cone.buffer, offset: 0, index: 0)
         
            encoder.setTriangleFillMode(.fill)
            isWireframe = false
            encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
            
            encoder.setTriangleFillMode(.lines)
            isWireframe = true
            encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        }
    }
    
    func draw(cone: ConeBuffer, encoder: MTLRenderCommandEncoder) {
        
        guard let transform else { return }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthStencilState)
        
        encoder.setVertexBuffer(cone.buffer, offset: 0, index: 0)
        encoder.setVertexBuffer(transform.buffer, offset: 0, index: 1)
        var grid = simd_uint2(36, 2)
        encoder.setVertexBytes(&grid, length: MemoryLayout<simd_uint2>.size, index: 2)
        
        encoder.setFragmentBuffer(cone.buffer, offset: 0, index: 0)
        
        let vertexCount = Int(grid.x * grid.y * 6)
        encoder.setTriangleFillMode(.fill)
        var isWireframe: Bool = false
        encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        
        encoder.setTriangleFillMode(.lines)
        isWireframe = true
        encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }
}

final class TorusRenderer {
    
    let pipelineState: MTLRenderPipelineState
    let depthStencilState: MTLDepthStencilState
    
    init(_ device: MTLDevice, _ library: MTLLibrary) {
        
        let vertexFunction = library.makeFunction(name: "geometry_renderpass::torus::vertex_function")!
        let fragmentFunction = library.makeFunction(name: "geometry_renderpass::torus::fragment_function")!
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        pipelineDescriptor.rasterSampleCount = 1
        
        let pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        
        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.isDepthWriteEnabled = true
        depthStencilDescriptor.depthCompareFunction = .less
        
        let depthStencilState = device.makeDepthStencilState(descriptor: depthStencilDescriptor)!
        
        self.pipelineState = pipelineState
        self.depthStencilState = depthStencilState
    }
    
    var transform: TransformBuffer? = nil
    
    func draw(toruses: [TorusBuffer], encoder: MTLRenderCommandEncoder) {
        
        guard let transform else { return }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthStencilState)
        
        encoder.setVertexBuffer(transform.buffer, offset: 0, index: 1)
        
        var grid = simd_uint2(36, 36)
        let vertexCount = Int(grid.x * grid.y * 6)
        var isWireframe: Bool = false
        
        for torus in toruses {
            encoder.setVertexBuffer(torus.buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&grid, length: MemoryLayout<simd_uint2>.size, index: 2)
            
            encoder.setFragmentBuffer(torus.buffer, offset: 0, index: 0)
         
            encoder.setTriangleFillMode(.fill)
            isWireframe = false
            encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
            
            encoder.setTriangleFillMode(.lines)
            isWireframe = true
            encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        }
    }
    
    func draw(torus: TorusBuffer, encoder: MTLRenderCommandEncoder) {
        
        guard let transform else { return }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthStencilState)
        
        encoder.setVertexBuffer(torus.buffer, offset: 0, index: 0)
        encoder.setVertexBuffer(transform.buffer, offset: 0, index: 1)
        var grid = simd_uint2(36, 36)
        encoder.setVertexBytes(&grid, length: MemoryLayout<simd_uint2>.size, index: 2)
        
        encoder.setFragmentBuffer(torus.buffer, offset: 0, index: 0)
        
        let vertexCount = Int(grid.x * grid.y * 6)
        encoder.setTriangleFillMode(.fill)
        var isWireframe: Bool = false
        encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        
        encoder.setTriangleFillMode(.lines)
        isWireframe = true
        encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }
}

final class PartialTorusRenderer {
    
    let pipelineState: MTLRenderPipelineState
    let depthStencilState: MTLDepthStencilState
    
    init(_ device: MTLDevice, _ library: MTLLibrary) {
        
        let vertexFunction = library.makeFunction(name: "geometry_renderpass::partial_torus::vertex_function")!
        let fragmentFunction = library.makeFunction(name: "geometry_renderpass::partial_torus::fragment_function")!
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        pipelineDescriptor.rasterSampleCount = 1
        
        let pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        
        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.isDepthWriteEnabled = true
        depthStencilDescriptor.depthCompareFunction = .less
        
        let depthStencilState = device.makeDepthStencilState(descriptor: depthStencilDescriptor)!
        
        self.pipelineState = pipelineState
        self.depthStencilState = depthStencilState
    }
    
    var transform: TransformBuffer? = nil
    
    func draw(toruses: [PartialTorusBuffer], encoder: MTLRenderCommandEncoder) {
        
        guard let transform else { return }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthStencilState)
        
        encoder.setVertexBuffer(transform.buffer, offset: 0, index: 1)
        
        var isWireframe: Bool = false
        
        for torus in toruses {
            encoder.setVertexBuffer(torus.buffer, offset: 0, index: 0)
            var grid = simd_uint2(UInt32((torus.angle * 180 / .pi) * 0.1), 36)
            encoder.setVertexBytes(&grid, length: MemoryLayout<simd_uint2>.size, index: 2)
            
            encoder.setFragmentBuffer(torus.buffer, offset: 0, index: 0)
         
            let vertexCount = Int(grid.x * grid.y * 6)
            encoder.setTriangleFillMode(.fill)
            isWireframe = false
            encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
            
            encoder.setTriangleFillMode(.lines)
            isWireframe = true
            encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        }
    }
    
    func draw(torus: PartialTorusBuffer, encoder: MTLRenderCommandEncoder) {
        
        guard let transform else { return }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthStencilState)
        
        encoder.setVertexBuffer(torus.buffer, offset: 0, index: 0)
        encoder.setVertexBuffer(transform.buffer, offset: 0, index: 1)
        
        var grid = simd_uint2(UInt32((torus.angle * 180 / .pi) * 0.1), 36)
        encoder.setVertexBytes(&grid, length: MemoryLayout<simd_uint2>.size, index: 2)
        
        encoder.setFragmentBuffer(torus.buffer, offset: 0, index: 0)
        
        let vertexCount = Int(grid.x * grid.y * 6)
        encoder.setTriangleFillMode(.fill)
        var isWireframe: Bool = false
        encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        
        encoder.setTriangleFillMode(.lines)
        isWireframe = true
        encoder.setFragmentBytes(&isWireframe, length: MemoryLayout<Bool>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }
}
