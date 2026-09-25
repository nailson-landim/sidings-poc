//
//  CameraMotionDetector.swift
//  ARFeaturePointFindSurface
//
//  Created by SG Kim on 8/30/25.
//

import ARKit
import simd

// Determines whether the camera has moved a certain distance or rotated by a certain angle.
// 3 cm and 3 degrees by default.
struct CameraMotionDetector {
    private var position: simd_float3 = .zero
    private var direction: simd_float3 = .zero
    
    private let minDistanceSquared: Float
    private let minCosAngle: Float
    
    init(minDistance: Float = 0.03, minAngle: Float = 3.0 * .pi / 180.0) {
        self.minDistanceSquared = minDistance * minDistance
        self.minCosAngle = cos(minAngle)
    }
    
    mutating func hasCameraMovedEnough(_ camera: ARCamera) -> Bool {
        let position = camera.position
        let direction = camera.direction
        
        let positionChanged = distance_squared(position, self.position) < minDistanceSquared
        let directionChanged = dot(direction, self.direction) < minCosAngle
        
        if positionChanged || directionChanged {
            self.position = position
            self.direction = direction
            return true
        }
        return false
    }
}
