//
//  ShaderTypes.h
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/24/25.
//
#pragma once

#ifdef __METAL_VERSION__
#include <metal_stdlib>
#define PROPERTY_NAME(metal, swift) metal
#else
#include <simd/simd.h>
#define float4x4 simd_float4x4
#define float3x3 simd_float3x3
#define float4 simd_float4
#define float3 simd_float3
#define PROPERTY_NAME(metal, swift) swift
#endif

struct TransformUniform {
    float4x4 PROPERTY_NAME(view_matrix, viewMatrix);
    float4x4 PROPERTY_NAME(projection_matrix, projectionMatrix);
    float4x4 PROPERTY_NAME(view_projection_matrix, viewProjectionMatrix);
    float3x3 PROPERTY_NAME(display_transform, displayTransform);
};

struct PlaneUniform {
    float3 PROPERTY_NAME(upper_left, upperLeft);
    float3 PROPERTY_NAME(lower_left, lowerLeft);
    float3 PROPERTY_NAME(upper_right, upperRight);
    float3 PROPERTY_NAME(lower_right, lowerRight);
    float3 color;
    float3 PROPERTY_NAME(line_color, lineColor);
    float opacity;
};

struct SphereUniform {
    float3 position;
    float3 color;
    float3 PROPERTY_NAME(line_color, lineColor);
    float radius;
    float opacity;
};

struct CylinderUniform {
    float3 bottom;
    float3 top;
    float3 color;
    float3 PROPERTY_NAME(line_color, lineColor);
    float radius;
    float opacity;
};

struct ConeUniform {
    float3 bottom;
    float3 top;
    float3 color;
    float3 PROPERTY_NAME(line_color, lineColor);
    float PROPERTY_NAME(bottom_radius, bottomRadius);
    float PROPERTY_NAME(top_radius, topRadius);
    float opacity;
};

struct TorusUniform {
    float3 center;
    float3 axis;
    float3 color;
    float3 PROPERTY_NAME(line_color, lineColor);
    float PROPERTY_NAME(mean_radius, meanRadius);
    float PROPERTY_NAME(tube_radius, tubeRadius);
    float opacity;
};

struct PartialTorusUniform {
    float3 center;
    float3 axis;
    float3 start;
    float3 color;
    float3 PROPERTY_NAME(line_color, lineColor);
    float PROPERTY_NAME(mean_radius, meanRadius);
    float PROPERTY_NAME(tube_radius, tubeRadius);
    float angle;
    float opacity;
};
