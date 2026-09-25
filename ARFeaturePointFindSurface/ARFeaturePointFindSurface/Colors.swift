//
//  Untitled.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/24/25.
//

import SwiftUI
import simd

var currentColorSet: ColorSet = .group2

struct ColorSet {
    let pointCloud: simd_float4
    let plane: simd_float3
    let sphere: simd_float3
    let cylinder: simd_float3
    let planeInlier: simd_float3
    let sphereInlier: simd_float3
    let cylinderInlier: simd_float3
    let planeUI: Color
    let sphereUI: Color
    let cylinderUI: Color
    
    static var group1: ColorSet {
        return .init(pointCloud: .init(170.0 / 255.0, 1, 0, 0.8),
                     plane: .init(0.93, 0.30, 0.33),
                     sphere: .init(0.73, 0.85, 0.22),
                     cylinder: .init(0.20, 0.80, 0.60),
                     planeInlier: .init(0.10, 0.75, 0.80),
                     sphereInlier: .init(0.35, 0.30, 0.85),
                     cylinderInlier: .init(0.90, 0.30, 0.70),
                     planeUI: .red,
                     sphereUI: .green,
                     cylinderUI: .blue)
    }
    
    static var group2: ColorSet {
        return .init(pointCloud: .init(1.00, 0.38, 0.00, 0.8),
                     plane: .init(0.93, 0.30, 0.33),
                     sphere: .init(0.96, 0.78, 0.18),
                     cylinder: .init(0.17, 0.78, 0.60),
                     planeInlier: .init(0.10, 0.75, 0.80),
                     sphereInlier: .init(0.32, 0.28, 0.86),
                     cylinderInlier: .init(0.58, 0.25, 0.95),
                     planeUI: .red,
                     sphereUI: .green,
                     cylinderUI: .blue)
    }
    
    static var group3: ColorSet {
        return .init(pointCloud: .init(0.00, 1.00, 0.30, 0.8),
                     plane: .init(0.93, 0.30, 0.33),
                     sphere: .init(0.00, 0.60, 0.35),
                     cylinder: .init(0.20, 0.55, 1.00),
                     planeInlier: .init(0.10, 0.80, 0.90),
                     sphereInlier: .init(0.90, 0.20, 0.80),
                     cylinderInlier: .init(1.00, 0.50, 0.00),
                     planeUI: .red,
                     sphereUI: .green,
                     cylinderUI: .blue)
    }
    
    static var group4: ColorSet {
        return .init(pointCloud: .init(0.00, 0.90, 0.65, 0.8),
                     plane: .init(0.92, 0.28, 0.30),
                     sphere: .init(0.48, 0.88, 0.00),
                     cylinder: .init(0.14, 0.50, 0.95),
                     planeInlier: .init(0.12, 0.78, 0.92),
                     sphereInlier: .init(0.58, 0.25, 0.95),
                     cylinderInlier: .init(1.00, 0.45, 0.10),
                     planeUI: .red,
                     sphereUI: .green,
                     cylinderUI: .blue)
    }
}

extension simd_float3 {
    // not used
    static var coneColor: simd_float3 { .init(0.22, 0.45, 0.95) }
    static var torusColor: simd_float3 { .init(0.75, 0.35, 0.95) }
    // not used
    static var coneInlierColor: simd_float3 { .init(0.95, 0.60, 0.20) }
    static var torusInlierColor: simd_float3 { .init(0.55, 0.85, 0.20) }
}

extension simd_float4 {
    // not used
    static var rawFeaturePointColor: simd_float4 {  .init(170.0 / 255.0, 1, 0, 0.5) }
}

extension Color {
    static var planeUI: Color { .red }
    static var sphereUI: Color { .green }
    static var cylinderUI: Color { .cyan }
    static var coneUI: Color { .blue }
    static var torusUI: Color { .purple }
}
