#include <metal_stdlib>
#include "SumiCore.h"
using namespace metal;

vec4 palette(float t) {
    vec4 a = vec4(0.5, 0.5, 0.5, 0.0);
    vec4 b = vec4(0.5, 0.5, 0.5, 0.0);
    vec4 c = vec4(1.0, 1.0, 1.0, 0.0);
    vec4 d = vec4(0.263, 0.416, 0.557, 0.0);

    return a + b * cos((c * t + d) * 6.28318);
}

fragment float4 demo_neon(VertOut in [[stage_in]], constant DemoUniforms& u [[buffer(0)]]) {
    vec2 fragCoord = in.pos.xy;
    vec2 iResolution = u.iResolution.xy;
    float iTime = u.iTimeVec.x; // <--- FIX HERE

    vec2 uv = (fragCoord * 2.0 - iResolution) / iResolution.y;
    vec2 uv0 = uv;
    
    vec4 finalColor = vec4(0.0);
    
    for (float i = 0.0; i < 4.0; i++) {
        uv = fract(uv * 1.5) - 0.5;

        float d = length(uv) * exp(-length(uv0));

        vec4 col = palette(length(uv0) + i * 0.4 + iTime * 0.4);

        d = sin(d * 8.0 + iTime) / 8.0;
        d = abs(d); 
        
        d = pow(0.01 / d, 1.2);

        finalColor += col * d;
    }
        
    return float4(finalColor.rgb, 1.0);
}
