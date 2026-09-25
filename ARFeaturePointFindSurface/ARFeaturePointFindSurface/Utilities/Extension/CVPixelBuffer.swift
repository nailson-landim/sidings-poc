//
//  CVPixelBuffer.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 8/27/25.
//

import MetalKit

// A snippet to easily get an `MTLTexture` from a `CVPixelBuffer`.
public extension CVPixelBuffer {
    
    func makeCVMetalTexture(pixelFormat: MTLPixelFormat,
                            planeIndex: Int,
                            textureCache: CVMetalTextureCache) -> CVMetalTexture? {
        var texture: CVMetalTexture? = nil
        let width = CVPixelBufferGetWidthOfPlane(self, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(self, planeIndex)
        _ = CVMetalTextureCacheCreateTextureFromImage(nil,
                                                      textureCache,
                                                      self,
                                                      nil,
                                                      pixelFormat,
                                                      width, height,
                                                      planeIndex,
                                                      &texture)
        return texture
    }
    
    var texture: MTLTexture? {
        CVMetalTextureGetTexture(self)
    }
}
