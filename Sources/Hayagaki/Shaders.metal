#include <metal_stdlib>
using namespace metal;

// 1. Vertex Input (Mapped via Descriptor)
struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
};

struct Uniforms {
    float4x4 modelMatrix;
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
};

struct SceneDescriptor {
    constant Uniforms* uniforms [[id(0)]];
    texture2d<float>   baseMap  [[id(1)]];
};

struct RasterizerData {
    float4 position [[position]];
    float3 normal;
    float2 uv;
};

// 2. Vertex Shader (Using stage_in)
vertex RasterizerData sumi_vertex_shader(VertexIn in [[stage_in]],
                                         constant SceneDescriptor &scene [[buffer(0)]]) 
{
    RasterizerData out;
    
    // Position Transform
    float4 pos = float4(in.position, 1.0);
    float4x4 mvp = scene.uniforms->projectionMatrix * scene.uniforms->viewMatrix * scene.uniforms->modelMatrix;
    out.position = mvp * pos;
    
    // Normal Transform (Simple rotation)
    // We cast the 4x4 to 3x3 to extract just rotation/scale
    float3x3 rotMat = float3x3(scene.uniforms->modelMatrix[0].xyz, 
                               scene.uniforms->modelMatrix[1].xyz, 
                               scene.uniforms->modelMatrix[2].xyz);
    out.normal = rotMat * in.normal;
    
    out.uv = in.uv;
    return out;
}

// 3. Fragment Shader
fragment float4 sumi_fragment_shader(RasterizerData in [[stage_in]],
                                     constant SceneDescriptor &scene [[buffer(0)]]) 
{
    constexpr sampler s(filter::linear, mip_filter::linear);
    
    // Check if texture exists/is valid (optional safety, Metal handles nil gracefully usually)
    float4 texColor = scene.baseMap.sample(s, in.uv);
    
    // Basic Lighting (Lambertian)
    float3 lightDir = normalize(float3(1.0, 1.0, 1.0)); // Light from top-right-front
    float nDotL = max(dot(normalize(in.normal), lightDir), 0.1); // 0.1 ambient
    
    // Debug: If texture is black, output pink to prove shader works
    // if (texColor.a == 0) return float4(1, 0, 1, 1);
    
    return float4(texColor.rgb * nDotL, 1.0);
}
