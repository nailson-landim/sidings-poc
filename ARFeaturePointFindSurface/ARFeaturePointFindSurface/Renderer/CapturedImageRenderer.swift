//
//  CapturedImageRenderer.swift
//  ARPointCloudFindSurface
//
//  Created by CurvSurf-SGKim on 8/27/25.
//

import Metal
import simd

final class CapturedImageRenderer {
    
    private let pipelineState: MTLRenderPipelineState
    
    init(_ device: MTLDevice, _ library: MTLLibrary) {
        
        let vertexFunction = library.makeFunction(name: "captured_image_renderpass::vertex_function")!
        let fragmentFunction = library.makeFunction(name: "captured_image_renderpass::fragment_function")!
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        pipelineDescriptor.rasterSampleCount = 1
        
        let pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        
        self.pipelineState = pipelineState
    }
    
    var transform: TransformBuffer? = nil
    var textureY: MTLTexture? = nil
    var textureCbCr: MTLTexture? = nil
    
    func draw(encoder: MTLRenderCommandEncoder) {
        
        guard let transform,
              let textureY,
              let textureCbCr else { return }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setCullMode(.none)
        
        encoder.setVertexBuffer(transform.buffer, offset: 0, index: 0)
        
        encoder.setFragmentTexture(textureY, index: 0)
        encoder.setFragmentTexture(textureCbCr, index: 1)
        
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
