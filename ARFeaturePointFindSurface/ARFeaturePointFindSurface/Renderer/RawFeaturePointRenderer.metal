//
//  RawFeaturePointRenderer.metal
//  ARPointCloudFindSurface
//
//  Created by CurvSurf-SGKim on 9/8/25.
//

#include <metal_stdlib>
using namespace metal;

#include "ShaderTypes.h"

namespace raw_feature_point_renderpass {
    
    struct Vertex {
        float3 position [[ attribute(0) ]];
    };
    
    typedef struct VertexOut {
        float4 position [[ position ]];
        float point_size [[ point_size ]];
    } FragmentIn;
    
    vertex VertexOut vertex_function(Vertex in                            [[ stage_in ]],
                                     constant TransformUniform &transform [[ buffer(1) ]],
                                     constant bool &is_portrait           [[ buffer(2) ]]) {
        
        auto wpos = float4(in.position, 1.0);
        auto cpos = transform.view_projection_matrix * wpos;
        auto P = transform.projection_matrix;
        auto scale = mix(P[0][0], P[1][1], is_portrait);
        auto point_size = max(2.0 * (scale / pow(cpos.w, 0.6)), 4.0) * 2.5;
        
        return {
            .position = cpos,
            .point_size = point_size
        };
    }
    
    fragment float4 fragment_function(FragmentIn in [[ stage_in ]],
                                      float2 point_coord [[ point_coord ]],
                                      constant float4 &point_color [[ buffer(0) ]]) {
        
        float distance = length(point_coord - float2(0.5));
        if (distance > 0.5) discard_fragment();
        if (distance > 0.4) return float4(0, 0, 0, point_color.w);
        
        return point_color;
    }
};
