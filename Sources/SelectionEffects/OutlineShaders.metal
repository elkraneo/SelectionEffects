//
//  OutlineShaders.metal
//  SelectionEffects
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Pass 1: Mask

// Renders the selected meshes into a single-channel (R8Uint) texture. Each
// fragment writes the mesh's style index (1…255; 0 = not selected), so meshes
// outlined in different colors and widths share one mask.

struct MaskUniforms {
    float4x4 mvp;
};

vertex float4 outlineMaskVertex(
    const device float3* positions       [[buffer(0)]],
    constant MaskUniforms& u             [[buffer(1)]],
    uint vid                             [[vertex_id]]
) {
    return u.mvp * float4(positions[vid], 1.0);
}

fragment uint outlineMaskFragment(
    float4 position           [[position]],
    constant uint& styleIndex [[buffer(0)]]
) {
    return styleIndex;
}

// MARK: - Pass 2: Dilate

// Forms the outline ring around the silhouettes. A pixel outside every mask
// takes the style of the nearest masked pixel within that style's width
// (`widths[style]`, in pixels); `maxWidth` bounds the search. Interior pixels
// write 0, so the ring only appears around the silhouette, not over the mesh.

kernel void outlineDilate(
    texture2d<uint, access::read>  maskTex  [[texture(0)]],
    texture2d<uint, access::write> edgeTex  [[texture(1)]],
    constant int32_t&              maxWidth [[buffer(0)]],
    constant int32_t*              widths   [[buffer(1)]],
    uint2 gid                               [[thread_position_in_grid]]
) {
    const uint w = maskTex.get_width();
    const uint h = maskTex.get_height();
    if (gid.x >= w || gid.y >= h) return;

    if (maskTex.read(gid).r != 0) {
        edgeTex.write(uint4(0), gid);
        return;
    }

    uint bestStyle = 0;
    int bestDistance = INT_MAX;
    const int r = maxWidth;
    for (int dy = -r; dy <= r; ++dy) {
        for (int dx = -r; dx <= r; ++dx) {
            const int d2 = dx * dx + dy * dy;
            if (d2 > r * r || d2 >= bestDistance) continue;
            const int nx = int(gid.x) + dx;
            const int ny = int(gid.y) + dy;
            if (nx < 0 || ny < 0 || nx >= int(w) || ny >= int(h)) continue;
            const uint style = maskTex.read(uint2(nx, ny)).r;
            if (style == 0) continue;
            const int sw = widths[style];
            if (d2 > sw * sw) continue;
            bestStyle = style;
            bestDistance = d2;
        }
    }

    edgeTex.write(uint4(bestStyle), gid);
}

// MARK: - Pass 3: Composite

// Blends each ring pixel's style color (`colors[style]`, linear RGB + blend
// alpha) over the source frame.

// Linear -> sRGB transfer, for writing through a non-sRGB view of an sRGB
// target (see SelectionRenderer.writableTarget).
static float3 encodeSRGB(float3 c) {
    c = saturate(c);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, 12.92 * c, c <= 0.0031308);
}

kernel void outlineComposite(
    texture2d<float, access::read>  sourceColor  [[texture(0)]],
    texture2d<uint, access::read>   edgeMask     [[texture(1)]],
    texture2d<float, access::write> targetColor  [[texture(2)]],
    constant float4*                colors       [[buffer(0)]],
    constant uint&                  encodeOutput [[buffer(1)]],
    uint2 gid                                    [[thread_position_in_grid]]
) {
    const uint w = sourceColor.get_width();
    const uint h = sourceColor.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float4 color = sourceColor.read(gid);
    const uint style = edgeMask.read(gid).r;
    if (style != 0) {
        const float4 outline = colors[style];
        color = mix(color, float4(outline.rgb, 1.0), outline.a);
    }
    if (encodeOutput != 0) {
        color.rgb = encodeSRGB(color.rgb);
    }
    targetColor.write(color, gid);
}
