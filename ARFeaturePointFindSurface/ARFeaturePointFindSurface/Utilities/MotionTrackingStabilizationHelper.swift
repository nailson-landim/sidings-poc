//
//  MotionTrackingStabilizationHelper.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/24/25.
//

import ARKit
import simd

// Because ARKit's feature points rely on camera motion tracking,
// stabilizing motion tracking by thoroughly scanning the surroundings before use
// can improve the quality of the feature points.
//
// This helper guides the user to sweep the environment with the device,
// and tracks whether the device has moved a certain distance (movingDistance, default 2 m).
// Since not only camera translation but also changes in the camera's pose (rotation) contribute to this process,
// it tracks the distance traveled by a virtual point positioned a fixed distance in front of the camera (sensorDistance, default 10 cm).
struct MotionTrackingStabilizationHelper {
    
    private var position: simd_float3 = .zero
    private var distanceRemaining: Float
    
    private let movingDistance: Float
    private let sensorDistance: Float

    init(movingDistance: Float = 2.0, sensorDistance: Float = 0.1) {
        self.movingDistance = movingDistance
        self.distanceRemaining = movingDistance
        self.sensorDistance = sensorDistance
    }
    
    var progress: Float {
        (movingDistance - distanceRemaining) / movingDistance
    }
    
    mutating func hasEnoughScans(_ camera: ARCamera, _ count: Int) -> Bool {
        
        guard distanceRemaining > 0 else { return true }
        
        let cameraPosition = camera.position
        let cameraDirection = camera.direction
        
        let position = cameraPosition + cameraDirection * sensorDistance
        let oldPosition = self.position
        self.position = position
        if count > 150 {
            let distance = distance(position, oldPosition)
            distanceRemaining = max(distanceRemaining - distance, 0)
        }
        return distanceRemaining == 0
    }
}

