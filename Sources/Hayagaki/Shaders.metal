#include <metal_stdlib>
using namespace metal;

// 1. Vertex Input (Matches SwiftVertex)
struct SumiVertex {
    packed_float3 position;
    packed_float3 color;
};

// 2. Uniforms (Data that changes per frame)
struct Uniforms {
    float4x4 modelMatrix;
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
};

struct RasterizerData {
    float4 position [[position]];
    float4 color;
};

// 3. Vertex Shader
vertex RasterizerData sumi_vertex_shader(uint vertexID [[vertex_id]],
                                         constant SumiVertex *vertices [[buffer(0)]],
                                         constant Uniforms &uniforms [[buffer(1)]]) 
{
    RasterizerData out;
	
    float4 pos = float4(vertices[vertexID].position, 1.0);

    // Unpack the 12-byte position to a 16-byte float4
    float3 p = vertices[vertexID].position;
    float4 position = float4(p, 1.0);
    
    // Apply the rotation matrix calculated by libsumi
    out.position = uniforms.projectionMatrix * uniforms.viewMatrix * uniforms.modelMatrix * pos;
    
    out.color = float4(vertices[vertexID].color, 1.0);
    return out;
}

fragment float4 sumi_fragment_shader(RasterizerData in [[stage_in]]) {
    return in.color;
}

// Keep the compute test for debugging if you like
kernel void sumi_compute_test(device SumiVertex* vertices [[buffer(0)]],
                              uint id [[thread_position_in_grid]]) {
    float3 pos = vertices[id].position;
    float3 col = vertices[id].color;
    pos += col * 0.001;
    vertices[id].position = pos;
}
