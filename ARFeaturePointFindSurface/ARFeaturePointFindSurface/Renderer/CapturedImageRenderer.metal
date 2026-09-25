//
//  CapturedImageRenderer.metal
//  ARPointCloudFindSurface
//
//  Created by CurvSurf-SGKim on 8/27/25.
//

#include <metal_stdlib>
using namespace metal;

#include "ShaderTypes.h"

namespace captured_image_renderpass {
    
    struct Vertex {
        float2 position;
        float2 texcoord;
    };
    
    constant Vertex vertices[4] = {
        {{ -1.0, -1.0 }, { 0.0, 1.0 }},
        {{ +1.0, -1.0 }, { 1.0, 1.0 }},
        {{ -1.0, +1.0 }, { 0.0, 0.0 }},
        {{ +1.0, +1.0 }, { 1.0, 0.0 }}
    };
    
    struct VertexOut {
        float4 position [[ position ]];
        float2 texcoord;
    };
    
    vertex VertexOut vertex_function(uint vertexID [[ vertex_id ]],
                                     constant TransformUniform &transform [[ buffer(0) ]]) {
        Vertex v = vertices[int(vertexID)];
        
        return {
            .position = float4(v.position, 0.0, 1.0),
            .texcoord = (transform.display_transform * float3(v.texcoord, 1.0)).xy
        };
    }
    
    constant float4x4 ycbcr_to_rgb_transform = float4x4(
        float4(+1.0000f, +1.0000f, +1.0000f, +0.0000f),
        float4(+0.0000f, -0.3441f, +1.7720f, +0.0000f),
        float4(+1.4020f, -0.7141f, +0.0000f, +0.0000f),
        float4(-0.7010f, +0.5291f, -0.8860f, +1.0000f)
    );
    
    // NOTE #37: Converts YCbCr to RGB.
    fragment float4 fragment_function(VertexOut in [[ stage_in ]],
                                      texture2d<float> texture_y [[ texture(0) ]],
                                      texture2d<float> texture_cbcr [[ texture(1) ]]) {
        
        constexpr sampler sampler(filter::linear,
                                  filter::linear,
                                  filter::linear);
        auto y = texture_y.sample(sampler, in.texcoord).r;
        auto cbcr = texture_cbcr.sample(sampler, in.texcoord).rg;
        
        float3 ycbcr = float3(y, cbcr);
        float3 rgb = (ycbcr_to_rgb_transform * float4(ycbcr, 1)).xyz;
        
        return float4(rgb, 1);
    }
};
