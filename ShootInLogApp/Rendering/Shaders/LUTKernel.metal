#include <metal_stdlib>
using namespace metal;

struct VtxOut {
    float4 position [[position]];
    float2 uv;
};

vertex VtxOut vertexPassthrough(uint vid [[vertex_id]], const device float* verts [[buffer(0)]]) {
    VtxOut o;
    // verts: x,y,u,v per-vertex
    float4 v = float4(verts[vid*4+0], verts[vid*4+1], 0.0, 1.0);
    o.position = v;
    o.uv = float2(verts[vid*4+2], verts[vid*4+3]);
    return o;
}

fragment float4 fragmentTextured(VtxOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return tex.sample(s, in.uv);
}

kernel void applyLUT(texture2d<float, access::read>  inTex  [[texture(0)]],
                     texture2d<float, access::write> outTex [[texture(1)]],
                     texture3d<half, access::sample> lutTex [[texture(2)]],
                     constant float2 &lutMeta [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    float4 src = inTex.read(gid); // normalized [0,1] from BGRA8Unorm
    float3 rgb = src.rgb;

    // If no LUT provided (size==0), pass-through
    int size = int(lutMeta.x);
    float intensity = lutMeta.y;
    float3 outColor = rgb;
    if (size > 0 && intensity > 0.0) {
        // Sample 3D LUT with trilinear interpolation
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float3 coord = clamp(rgb, 0.0, 1.0);
        // Convert to normalized coords across the 3D texture texel centers
        float invSize = 1.0 / float(size);
        float3 uvw = (coord * (float(size) - 1.0) + 0.5) * invSize;
        float3 lutSample = float3(lutTex.sample(s, uvw).xyz);
        outColor = mix(rgb, lutSample, intensity);
    }
    outTex.write(float4(clamp(outColor, 0.0, 1.0), 1.0), gid);
}
