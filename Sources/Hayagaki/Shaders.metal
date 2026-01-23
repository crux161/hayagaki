#include <metal_stdlib>
#include "SumiCore.h" // Import shared definitions
using namespace metal;

// ============================================================================
// INFRASTRUCTURE (Bunny & Screen)
// ============================================================================

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
};

struct SceneUniforms {
    mat4 model; mat4 view; mat4 proj;
};

struct VertexPayload {
    float4 position [[position]];
    float3 worldPos;
    float3 normal;
    float2 uv;
};

struct ArgBuffer {
    constant SceneUniforms* uniforms [[id(0)]];
    texture2d<float> tex [[id(1)]];
};

// --- SCREEN PASS ---
vertex VertOut screen_vert(uint vid [[vertex_id]]) {
    const float2 verts[] = { {-1, -1}, {1, -1}, {-1, 1}, {1, 1} };
    VertOut out;
    out.pos = float4(verts[vid], 0, 1);
    out.uv = verts[vid] * 0.5 + 0.5;
    out.uv.y = 1.0 - out.uv.y;
    return out;
}

fragment float4 screen_frag_blit(VertOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    return tex.sample(s, in.uv);
}

// --- BUNNY 3D SCENE ---
vertex VertexPayload sumi_vertex_shader(VertexIn in [[stage_in]], constant ArgBuffer& args [[buffer(0)]]) {
    VertexPayload out;
    mat4 mvp = args.uniforms->proj * args.uniforms->view * args.uniforms->model;
    out.position = mvp * float4(in.position, 1.0);
    out.worldPos = (args.uniforms->model * float4(in.position, 1.0)).xyz;
    out.normal = (args.uniforms->model * float4(in.normal, 0.0)).xyz;
    out.uv = in.uv;
    return out;
}

fragment float4 sumi_fragment_shader(VertexPayload in [[stage_in]], constant ArgBuffer& args [[buffer(0)]]) {
    constexpr sampler s(filter::linear);
    float3 N = normalize(in.normal);
    float3 L = normalize(float3(1, 1, 1));
    float diff = max(dot(N, L), 0.0);
    float4 color = args.tex.sample(s, in.uv);
    return float4(color.rgb * (diff + 0.2), 1.0);
}

// --- FALLBACK ERROR ---
fragment float4 demo_error(VertOut in [[stage_in]]) {
    float2 uv = in.uv * 10.0;
    float stripe = step(0.5, fract(uv.x + uv.y));
    return float4(1.0, 0.0, 1.0, 1.0) * stripe;
}
