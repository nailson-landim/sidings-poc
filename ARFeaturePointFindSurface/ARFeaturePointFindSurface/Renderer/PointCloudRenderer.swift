//
//  PointCloudStreamRenderer.swift
//  ARPointCloudFindSurface
//
//  Created by SG Kim on 8/30/25.
//

import Metal
import simd

struct PointCloudBuffer {
    fileprivate let buffer: MTLBuffer
    private(set) var pointCount: Int = 0
    private let capacity: Int
    init(_ device: MTLDevice, _ capacity: Int) {
        let length = MemoryLayout<simd_float3>.stride * capacity
        let options: MTLResourceOptions = [.storageModeShared,
                                           .cpuCacheModeWriteCombined]
        self.buffer = device.makeBuffer(length: length, options: options)!
        self.capacity = capacity
    }
    
    mutating func clear() {
        pointCount = 0
    }
    
    mutating func updatePointCloud<C>(_ points: C) where C: Collection, C.Element == simd_float3 {
        
        guard points.isEmpty == false else {
            pointCount = 0
            return
        }
        
        let dst = buffer.contents()
            .bindMemory(to: simd_float3.self, capacity: capacity)
        let byteCount = points.count * MemoryLayout<simd_float3>.stride
        _ = points.withContiguousStorageIfAvailable { src in
            memcpy(dst, src.baseAddress!, byteCount)
        } ?? Array(points).withUnsafeBytes { src in
            memcpy(dst, src.baseAddress!, byteCount)
        }
        pointCount = points.count
    }
}

final class PointCloudRenderer {
    
    private let pipelineState: MTLRenderPipelineState
    private let depthStencilState: MTLDepthStencilState
    
    init(_ device: MTLDevice, _ library: MTLLibrary) {
        
        let vertexFunction = library.makeFunction(name: "point_cloud_renderpass::vertex_function")!
        let fragmentFunction = library.makeFunction(name: "point_cloud_renderpass::fragment_function")!
        
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        vertexDescriptor.layouts[0].stepRate = 1
        vertexDescriptor.layouts[0].stride = MemoryLayout<simd_float3>.stride
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
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
        depthStencilDescriptor.depthCompareFunction = .always
        
        let depthStencilState = device.makeDepthStencilState(descriptor: depthStencilDescriptor)!
        
        self.pipelineState = pipelineState
        self.depthStencilState = depthStencilState
    }
    
    var transform: TransformBuffer? = nil
    var isPortrait: Bool = true
    var pointColor: simd_float4 = .init(0, 0, 1, 1)
    var pickedIndex: Int = -1
    
    func draw(encoder: MTLRenderCommandEncoder, buffer: PointCloudBuffer) {
        
        guard let transform,
              buffer.pointCount > 0 else { return }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthStencilState)
        
        encoder.setVertexBuffer(buffer.buffer, offset: 0, index: 0)
        encoder.setVertexBuffer(transform.buffer, offset: 0, index: 1)
        encoder.setVertexBytes(&isPortrait, length: MemoryLayout<Bool>.stride, index: 2)
        
        encoder.setFragmentBytes(&pointColor, length: MemoryLayout<simd_float4>.stride, index: 0)
        var index = pickedIndex > 0 ? UInt32(pickedIndex) : UInt32.max
        encoder.setFragmentBytes(&index, length: MemoryLayout<UInt32>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: buffer.pointCount)
    }
}
