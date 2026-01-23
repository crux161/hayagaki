#include <metal_stdlib>
#include "SumiCore.h"
using namespace metal;

fragment float4 demo_fractal(VertOut in [[stage_in]], constant DemoUniforms& u [[buffer(0)]]) {
    vec2 fragCoord = in.pos.xy;
    vec2 iResolution = u.iResolution.xy;
    float iTime = u.iTimeVec.x; // <--- FIX HERE
    
    vec2 uv = (fragCoord - iResolution * 0.5) / iResolution.y;
    
    vec3 col = vec3(0.0);
    vec2 z = uv;
    float t = iTime * 0.2;
    
    vec2 c = vec2(sin(t), cos(t)) * 0.7;
    
    float iter = 0.0;
    for(float i=0.0; i<32.0; i+=1.0) {
        float x = (z.x * z.x - z.y * z.y) + c.x;
        float y = (2.0 * z.x * z.y) + c.y;
        z = vec2(x, y);
        
        if(length(z) > 4.0) break;
        iter += 1.0;
    }
    
    float val = iter / 32.0;
    
    col = vec3(val, val * 0.5, sin(val * 6.0));
    
    return float4(col, 1.0);
}
