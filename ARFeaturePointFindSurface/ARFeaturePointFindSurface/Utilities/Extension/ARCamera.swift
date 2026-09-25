//
//  ARCamera.swift
//  ARFeaturePointFindSurface
//
//  Created by SG Kim on 8/30/25.
//

import ARKit
import simd

extension ARCamera {
    
    var position: simd_float3 {
        simd_make_float3(transform.columns.3)
    }
    
    var direction: simd_float3 {
        -simd_make_float3(transform.columns.2)
    }
    
    var tanHalfFovx: Float {
        return Float(imageResolution.width * 0.5) / intrinsics[0, 0]
    }
    
    var tanHalfFovy: Float {
        return Float(imageResolution.height * 0.5) / intrinsics[1, 1]
    }
}
