#include <metal_stdlib>
#include "SumiCore.h"
using namespace metal;

fragment float4 demo_bubbles(VertOut in [[stage_in]], constant DemoUniforms& u [[buffer(0)]]) {
    vec2 fragCoord = in.pos.xy;
    vec2 iResolution = u.iResolution.xy;
    float iTime = u.iTimeVec.x; // <--- FIX HERE

    vec2 uv = fragCoord / iResolution.y;
    vec2 p = uv * 8.0;
    vec2 i = floor(p);
    vec2 f = fract(p);
    
    float t = iTime * 0.5;
    float v = 0.0;
    
    for(int y=-1; y<=1; y++) {
        for(int x=-1; x<=1; x++) {
            vec2 g = vec2(float(x), float(y));
            vec2 r = g - f + hash(i + g);
            float d = length(r);
            float s = 0.5 + 0.5 * sin(t + hash(i + g) * 6.2831);
            float size = 0.3 * s;
            
            v += 1.0 - smoothstep(size - 0.05, size, d);
        }
    }
    
    vec3 col = vec3(0.2, 0.5, 1.0) * v;
    return float4(col, 1.0);
}
