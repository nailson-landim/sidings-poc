//
//  ARFrame.swift
//  ARFeaturePointFindSurface
//
//  Created by SG Kim on 8/30/25.
//

import ARKit
import simd

extension ARFrame {
    
    func inversedDisplayTransform(for orientation: UIInterfaceOrientation,
                                  viewportSize: CGSize) -> simd_float3x3 {
        let displayTransform = displayTransform(for: orientation,
                                                viewportSize: viewportSize)
        let t = displayTransform.inverted()
        
        return simd_float3x3(
            simd_float3(Float(t.a), Float(t.b), 0),
            simd_float3(Float(t.c), Float(t.d), 0),
            simd_float3(Float(t.tx), Float(t.ty), 1)
        )
    }
}
