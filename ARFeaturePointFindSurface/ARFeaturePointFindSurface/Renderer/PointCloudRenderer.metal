//
//  PointCloudRenderer.metal
//  ARPointCloudFindSurface
//
//  Created by CurvSurf-SGKim on 8/27/25.
//

#include <metal_stdlib>
using namespace metal;

#include "ShaderTypes.h"

namespace point_cloud_renderpass {
    
    struct Vertex {
        float3 position [[ attribute(0) ]];
    };
    
    struct VertexOut {
        float4 position [[ position ]];
        float point_size [[ point_size ]];
        uint vertexID [[ flat ]];
    };
    
    vertex VertexOut vertex_function(Vertex in                            [[ stage_in ]],
                                     uint vertexID                        [[ vertex_id ]],
                                     constant TransformUniform &transform [[ buffer(1) ]],
                                     constant bool &is_portrait           [[ buffer(2) ]]) {
        auto wpos = float4(in.position, 1.0);
        auto cpos = transform.view_projection_matrix * wpos;
        auto P = transform.projection_matrix;
        auto scale = mix(P[0][0], P[1][1], is_portrait);
        auto point_size = max(2 * (scale / pow(cpos.w, 0.6)), 4.0) * 2.5;
        
        return {
            .position = cpos,
            .point_size = point_size,
            .vertexID = vertexID
        };
    }
    
    fragment float4 fragment_function(VertexOut in                 [[ stage_in ]],
                                      float2 point_coord           [[ point_coord ]],
                                      constant float4 &point_color [[ buffer(0) ]],
                                      constant uint &picked_index  [[ buffer(1) ]]) {
        
        float distance = length(point_coord - float2(0.5));
        if (distance > 0.5) discard_fragment();
        if (distance > 0.4) return float4(0, 0, 0, point_color.w);
        
        return float4(mix(point_color.xyz, float3(1, 0, 0), in.vertexID == picked_index), point_color.w);
    }
};
