//
//  RawFeaturePointRenderer.swift
//  ARPointCloudFindSurface
//
//  Created by CurvSurf-SGKim on 8/27/25.
//

import Metal
import simd

fileprivate let maxPointCount = 8192

final class RawFeaturePointRenderer {
    
    private let pipelineState: MTLRenderPipelineState
    private let depthStencilState: MTLDepthStencilState
    
    private let pointBuffer: MTLBuffer
    private var pointCount: Int = 0
    
    init(_ device: MTLDevice, _ library: MTLLibrary) {
        
        let vertexFunction = library.makeFunction(name: "raw_feature_point_renderpass::vertex_function")!
        let fragmentFunction = library.makeFunction(name: "raw_feature_point_renderpass::fragment_function")!
        
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
        depthStencilDescriptor.depthCompareFunction = .less
        
        let depthStencilState = device.makeDepthStencilState(descriptor: depthStencilDescriptor)!
        
        let pointBufferLength = MemoryLayout<simd_float3>.stride * maxPointCount
        let pointBufferOptions: MTLResourceOptions = [.storageModeShared, .cpuCacheModeWriteCombined]
        let pointBuffer = device.makeBuffer(length: pointBufferLength,
                                            options: pointBufferOptions)!
        
        self.pipelineState = pipelineState
        self.depthStencilState = depthStencilState
        self.pointBuffer = pointBuffer
    }
    
    func updatePoints(_ points: [simd_float3]) {
        pointCount = points.count
        guard points.isEmpty == false else { return }
        
        let bufferPointer = pointBuffer.contents()
        let byteCount = points.count * MemoryLayout<simd_float3>.stride
        _ = points.withUnsafeBytes { sourcePointer in
            memcpy(bufferPointer, sourcePointer.baseAddress!, byteCount)
        }
    }
    
    var transform: TransformBuffer? = nil
    var isPortrait: Bool = true
    var pointColor: simd_float4 = .one
    
    func draw(encoder: MTLRenderCommandEncoder) {
        
        guard let transform,
              pointCount > 0 else { return }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthStencilState)
        
        encoder.setVertexBuffer(pointBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(transform.buffer, offset: 0, index: 1)
        encoder.setVertexBytes(&isPortrait, length: MemoryLayout<Bool>.stride, index: 2)
        
        encoder.setFragmentBytes(&pointColor, length: MemoryLayout<simd_float4>.stride, index: 0)
        var index = UInt32.max
        encoder.setFragmentBytes(&index, length: MemoryLayout<UInt32>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointCount)
    }
}
