// SnailSight 12.27 Scan view: the live coloured point cloud (SnailSightCore ScanCloud.export: packed float3 + RGBA8,
// 16 bytes a point). Round point sprites sized by distance; faint points carry their alpha. Used by the AR
// post-process pass (points over the camera) and the orbit view (ScanCloudRenderer).
#include <metal_stdlib>
using namespace metal;

struct CloudVertex {
    packed_float3 pos;
    uchar4 color;
};

struct CloudUniforms {
    float4x4 viewProj;
    float4x4 view;
    float pointScale;     // pixels at 1 m
    float minSize;
    float maxSize;
    float alpha;          // overall alpha (AR overlay vs orbit view)
};

struct CloudOut {
    float4 position [[position]];
    float size [[point_size]];
    float4 color;
};

vertex CloudOut scanCloudVertex(uint vid [[vertex_id]],
                                const device CloudVertex *verts [[buffer(0)]],
                                constant CloudUniforms &u [[buffer(1)]]) {
    CloudVertex v = verts[vid];
    float4 w = float4(float3(v.pos), 1.0);
    CloudOut o;
    o.position = u.viewProj * w;
    float d = max(0.05, -(u.view * w).z);
    o.size = clamp(u.pointScale / d, u.minSize, u.maxSize);
    o.color = float4(v.color) / 255.0;
    o.color.a *= u.alpha;
    return o;
}

fragment float4 scanCloudFragment(CloudOut in [[stage_in]], float2 pc [[point_coord]]) {
    float2 c = pc - 0.5;
    if (dot(c, c) > 0.25) discard_fragment();
    return in.color;
}
