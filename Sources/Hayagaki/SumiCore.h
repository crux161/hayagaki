#pragma once
#include <metal_stdlib>
using namespace metal;

// ============================================================================
// SUMI / GLSL COMPATIBILITY TYPES
// ============================================================================
typedef float2 vec2;
typedef float3 vec3;
typedef float4 vec4;
typedef float2x2 mat2;
typedef float3x3 mat3;
typedef float4x4 mat4;

#define PI 3.14159265359

// ============================================================================
// SHARED STRUCTS
// ============================================================================
struct VertOut {
    float4 pos [[position]];
    float2 uv;
};

struct DemoUniforms {
    vec4 iResolution;
    vec4 iTimeVec;
    vec4 iMouse;
};

// ============================================================================
// COMMON HELPER FUNCTIONS
// ============================================================================
// Solves GLSL vs Metal 'mod' behavior differences
inline float mod(float x, float y) { return x - y * floor(x/y); }
inline vec2 mod(vec2 x, float y) { return x - y * floor(x/y); }
inline vec3 mod(vec3 x, float y) { return x - y * floor(x/y); }

// Common random hash used in many Sumi demos
inline float hash(vec2 p) {
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

// Basic noise placeholder (expand if needed)
inline float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i + vec2(0.0,0.0)), hash(i + vec2(1.0,0.0)), u.x),
               mix(hash(i + vec2(0.0,1.0)), hash(i + vec2(1.0,1.0)), u.x), u.y);
}
