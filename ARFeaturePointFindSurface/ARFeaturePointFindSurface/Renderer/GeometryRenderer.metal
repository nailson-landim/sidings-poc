//
//  GeometryRenderer.metal
//  ARPointCloudFindSurface
//
//  Created by CurvSurf-SGKim on 9/4/25.
//

#include <metal_stdlib>
using namespace metal;

#include "ShaderTypes.h"

namespace geometry_renderpass {
    
    typedef struct VertexOut {
        float4 position [[ position ]];
        uint instanceID  [[ flat ]];
    } FragmentIn;
    
    inline void make_orthonormal_bases(float3 n, thread float3 &t, thread float3 &b) {
        if (n.z < -0.999999f) {
            t = float3(0, -1, 0);
            b = float3(-1, 0, 0);
        } else {
            float a = 1.0f / (1.0f + n.z);
            float bx = -n.x * n.y * a;
            t = float3(1.0f - n.x * n.x * a, bx, -n.x);
            b = float3(bx, 1.0f - n.y * n.y * a, -n.y);
        }
    }
    
    // 셀 → (u,v) 복원용 코너 인덱스(두 삼각형: 6 정점)
    constant int2 triangle_corners[6] = {
        int2(0,0), int2(1,0), int2(0,1),
        int2(1,0), int2(1,1), int2(0,1)
    };

    // grid = (nu, nv), vertexID → (u,v)
    inline void uv_from_vertex(uint vertexID, uint2 grid,
                               thread float &u, thread float &v) {
        uint nu = grid.x, nv = grid.y;
        uint triVertex = vertexID % 6;
        uint cell      = vertexID / 6;
        uint i         = cell % nu;
        uint j         = cell / nu;
        int2 c = triangle_corners[triVertex];
        u = ((float)i + c.x) / (float)nu;
        v = ((float)j + c.y) / (float)nv;
    }
    
    namespace plane {
        
        vertex VertexOut vertex_function(uint vertexID                        [[ vertex_id ]],
                                         uint instanceID                      [[ instance_id ]],
                                         constant PlaneUniform *uniforms      [[ buffer(0) ]],
                                         constant TransformUniform &transform [[ buffer(1) ]],
                                         constant uint2 &grid                 [[ buffer(2) ]]) {
            
            float u, v; uv_from_vertex(vertexID, grid, u, v);
            
            auto uniform = uniforms[int(instanceID)];
            const auto ul = uniform.upper_left;
            const auto ll = uniform.lower_left;
            const auto ur = uniform.upper_right;
            const auto lr = uniform.lower_right;
            
            auto upper = mix(ul, ur, u);
            auto lower = mix(ll, lr, u);
            auto wpos = mix(upper, lower, v);
            
            return {
                .position = transform.projection_matrix * transform.view_matrix * float4(wpos, 1.0),
                .instanceID = instanceID
            };
        }
        
        fragment float4 fragment_function(FragmentIn in                   [[ stage_in ]],
                                          constant PlaneUniform *uniforms [[ buffer(0) ]],
                                          constant bool &is_wireframe     [[ buffer(1) ]]) {
            auto uniform = uniforms[int(in.instanceID)];
            return float4(mix(uniform.color, uniform.line_color, is_wireframe), uniform.opacity);
        }
    };
    
    namespace sphere {
        
        vertex VertexOut vertex_function(uint vertexID                        [[ vertex_id ]],
                                         uint instanceID                      [[ instance_id ]],
                                         constant SphereUniform *uniforms     [[ buffer(0) ]],
                                         constant TransformUniform &transform [[ buffer(1) ]],
                                         constant uint2 &grid                 [[ buffer(2) ]]) {
            
            float u, v; uv_from_vertex(vertexID, grid, u, v);
            float theta = u * M_PI_F * 2.0f;
            float phi = v * M_PI_F;
            
            float ct = cos(theta), st = sin(theta);
            float cp = cos(phi), sp = sin(phi);
            
            auto uniform = uniforms[int(instanceID)];
            
            float3 normal = float3(ct * sp, cp, -st * sp);
            float3 position = uniform.position + uniform.radius * normal;
            
            return {
                .position = transform.projection_matrix * transform.view_matrix * float4(position, 1.0),
                .instanceID = instanceID
            };
        }
        
        fragment float4 fragment_function(FragmentIn in                    [[ stage_in ]],
                                          constant SphereUniform *uniforms [[ buffer(0) ]],
                                          constant bool& is_wireframe      [[ buffer(1) ]]) {
            auto uniform = uniforms[int(in.instanceID)];
            return float4(mix(uniform.color, uniform.line_color, is_wireframe), uniform.opacity);
        }
    };
    
    namespace cylinder {
        
        vertex VertexOut vertex_function(uint vertexID                        [[ vertex_id ]],
                                         uint instanceID                      [[ instance_id ]],
                                         constant CylinderUniform *uniforms   [[ buffer(0) ]],
                                         constant TransformUniform &transform [[ buffer(1) ]],
                                         constant uint2 &grid                 [[ buffer(2) ]]) {
            
            float u, v; uv_from_vertex(vertexID, grid, u, v);
            
            auto uniform = uniforms[int(instanceID)];
            auto top = uniform.top;
            auto bottom = uniform.bottom;
            auto axis = normalize(top - bottom);
            float3 T, B; make_orthonormal_bases(axis, T, B);
            
            float theta = u * M_PI_F * 2.0f;
            float ct = cos(theta), st = sin(theta);
            
            float radius = uniform.radius;
            float3 ring_dir = ct * T + st * B;
            
            float3 center = mix(bottom, top, v);
            float3 wpos = center + radius * ring_dir;
            
            return {
                .position = transform.projection_matrix * transform.view_matrix * float4(wpos, 1),
                .instanceID = instanceID
            };
        }
        
        fragment float4 fragment_function(FragmentIn in                      [[ stage_in ]],
                                          constant CylinderUniform *uniforms [[ buffer(0) ]],
                                          constant bool& is_wireframe      [[ buffer(1) ]]) {
            auto uniform = uniforms[int(in.instanceID)];
            return float4(mix(uniform.color, uniform.line_color, is_wireframe), uniform.opacity);
        }
    };
    
    namespace cone {
        
        vertex VertexOut vertex_function(uint vertexID                        [[ vertex_id ]],
                                         uint instanceID                      [[ instance_id ]],
                                         constant ConeUniform *uniforms       [[ buffer(0) ]],
                                         constant TransformUniform &transform [[ buffer(1) ]],
                                         constant uint2 &grid                 [[ buffer(2) ]]) {
            
            float u, v; uv_from_vertex(vertexID, grid, u, v);
            
            auto uniform = uniforms[int(instanceID)];
            auto top = uniform.top;
            auto bottom = uniform.bottom;
            auto axis = normalize(top - bottom);
            
            auto top_radius = uniform.top_radius;
            auto bottom_radius = uniform.bottom_radius;
            
            float3 T, B; make_orthonormal_bases(axis, T, B);
            
            float theta = u * M_PI_F * 2.0f;
            float ct = cos(theta), st = sin(theta);
            
            float radius = mix(bottom_radius, top_radius, v);
            float3 ring_dir = ct * T + st * B;
            
            float3 center = mix(bottom, top, v);
            float3 wpos = center + radius * ring_dir;
            
            return {
                .position = transform.projection_matrix * transform.view_matrix * float4(wpos, 1),
                .instanceID = instanceID
            };
        }
        
        fragment float4 fragment_function(FragmentIn in                  [[ stage_in ]],
                                          constant ConeUniform *uniforms [[ buffer(0) ]],
                                          constant bool& is_wireframe      [[ buffer(1) ]]) {
            auto uniform = uniforms[int(in.instanceID)];
            return float4(mix(uniform.color, uniform.line_color, is_wireframe), uniform.opacity);
        }
    };
    
    namespace torus {
        
        vertex VertexOut vertex_function(uint vertexID                        [[ vertex_id ]],
                                         uint instanceID                      [[ instance_id ]],
                                         constant TorusUniform *uniforms      [[ buffer(0) ]],
                                         constant TransformUniform &transform [[ buffer(1) ]],
                                         constant uint2 &grid                 [[ buffer(2) ]]) {
            
            float u, v; uv_from_vertex(vertexID, grid, u, v);
            
            auto uniform = uniforms[int(instanceID)];
            auto center = uniform.center;
            auto axis = normalize(uniform.axis);
            auto mean_radius = uniform.mean_radius;
            auto tube_radius = uniform.tube_radius;
            
            float3 T, B; make_orthonormal_bases(axis, T, B);
            
            float theta = u * M_PI_F * 2.0f;
            float phi = v * M_PI_F * 2.0f;
            
            float ct = cos(theta), st = sin(theta);
            float cp = cos(phi), sp = sin(phi);
            
            float3 ring_dir = ct * T + st * B;
            float3 wpos = center + (mean_radius + tube_radius * cp) * ring_dir + (tube_radius * sp) * axis;
            
            return {
                .position = transform.projection_matrix * transform.view_matrix * float4(wpos, 1),
                .instanceID = instanceID
            };
        }
        
        fragment float4 fragment_function(FragmentIn in                   [[ stage_in ]],
                                          constant TorusUniform *uniforms [[ buffer(0) ]],
                                          constant bool& is_wireframe      [[ buffer(1) ]]) {
            auto uniform = uniforms[int(in.instanceID)];
            return float4(mix(uniform.color, uniform.line_color, is_wireframe), uniform.opacity);
        }
    };
    
    namespace partial_torus {
        
        vertex VertexOut vertex_function(uint vertexID                          [[ vertex_id ]],
                                         uint instanceID                        [[ instance_id ]],
                                         constant PartialTorusUniform *uniforms [[ buffer(0) ]],
                                         constant TransformUniform &transform   [[ buffer(1) ]],
                                         constant uint2 &grid                   [[ buffer(2) ]]) {
            
            float u, v; uv_from_vertex(vertexID, grid, u, v);
            
            auto uniform = uniforms[int(instanceID)];
            auto center = uniform.center;
            auto axis = normalize(uniform.axis);
            auto mean_radius = uniform.mean_radius;
            auto tube_radius = uniform.tube_radius;
            auto start = uniform.start;
            auto angle = uniform.angle;
            
            float3 v0 = start - center;
            float3 v0p = v0 - dot(v0, axis) * axis;
            float L = length(v0p);
            
            float3 T, B;
            if (L > 1e-6f) {
                T = v0p / L;
                B = normalize(cross(axis, T));
            } else {
                make_orthonormal_bases(axis, T, B);
            }
            
            float theta = u * angle;
            float phi = v * M_PI_F * 2.0f;
            
            float ct = cos(theta), st = sin(theta);
            float cp = cos(phi), sp = sin(phi);
            
            float3 ring_dir = ct * T + st * B;
            float3 wpos = center + (mean_radius + tube_radius * cp) * ring_dir + (tube_radius * sp) * axis;
            
            return {
                .position = transform.projection_matrix * transform.view_matrix * float4(wpos, 1),
                .instanceID = instanceID
            };
        }
        
        fragment float4 fragment_function(FragmentIn in                          [[ stage_in ]],
                                          constant PartialTorusUniform *uniforms [[ buffer(0) ]],
                                          constant bool& is_wireframe      [[ buffer(1) ]]) {
            auto uniform = uniforms[int(in.instanceID)];
            return float4(mix(uniform.color, uniform.line_color, is_wireframe), uniform.opacity);
        }
    };
};
