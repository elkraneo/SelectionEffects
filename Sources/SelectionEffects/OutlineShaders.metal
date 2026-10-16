//
//  OutlineShaders.metal
//  SelectionEffects
//

#include <metal_stdlib>
using namespace metal;

// One entry per selection style, indexed by style (index 0 is unused).
// Matches `SelectionCompositor.GPUStyle`.
struct SelectionStyle {
    float4 color;            // linear RGB + blend alpha
    float  occludedOpacity;  // alpha multiplier where the selection is hidden
    float  strength;         // highlight: multiplies color.a
    uint   kind;             // 0 = outline, 1 = highlight
    int    width;            // outline width in pixels (0 for highlight)
};

// Matches `SelectionCompositor.DepthParams`.
struct DepthParams {
    uint  useSceneDepth;     // 0: no scene depth, treat everything as visible
    uint  reversedZ;         // 1: nearer is larger
    float epsilon;           // tolerance when comparing the two depths
};

constant uint kOccludedBit = 0x80;

// How the two depth inputs of the dilate and composite kernels are stored
// (set per pipeline by `SelectionCompositor`):
// false: a depth texture (`depth32Float`, `depth32Float_stencil8`), read as depth2d;
// true:  a float color texture (`r32Float`, `r16Float`; e.g. a ray-march
//        distance), read as texture2d, its red channel holding the depth.
constant bool kMaskDepthIsFloat  [[function_constant(0)]];
constant bool kSceneDepthIsFloat [[function_constant(1)]];
constant bool kMaskDepthIsDepth  = !kMaskDepthIsFloat;
constant bool kSceneDepthIsDepth = !kSceneDepthIsFloat;

static inline float loadDepth(depth2d<float, access::read> t, uint2 p) { return t.read(p); }
static inline float loadDepth(texture2d<float, access::read> t, uint2 p) { return t.read(p).r; }

// MARK: - Pass 1: Mask (RealityKit path)

// Renders the selected meshes into an R8Uint texture holding each pixel's style
// index (1…127; 0 = not selected), with depth testing among the selected meshes
// so the depth attachment ends up with the nearest selected surface. Other
// renderers write their own mask and mask depth and start at pass 2.

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

// Is the selected surface at `p` hidden behind scene geometry?
//
// Silhouette-edge pixels are unreliable: the selected mesh only grazes them and
// the scene's rasterization can differ by a pixel. So, like Reality Composer
// Pro's selection shader, take the nearest selected depth in a 3x3 neighborhood
// and the farthest scene depth around the same spot before comparing. A pixel
// counts as selected where the mask holds a style, so the mask depth needs no
// clear value of its own.
template <typename MaskDepth, typename SceneDepth>
static bool isOccluded(
    uint2 p,
    texture2d<uint, access::read> maskTex,
    MaskDepth maskDepth,
    SceneDepth sceneDepth,
    constant DepthParams& depth
) {
    if (depth.useSceneDepth == 0) return false;
    const bool rev = depth.reversedZ != 0;
    const int mw = int(maskTex.get_width()), mh = int(maskTex.get_height());
    const int sw = int(sceneDepth.get_width()), sh = int(sceneDepth.get_height());
    const float2 scale = float2(sw, sh) / float2(mw, mh);

    bool found = false;
    float selected = 0.0;
    float scene = rev ? INFINITY : -INFINITY;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            const int2 q = clamp(int2(p) + int2(dx, dy), int2(0), int2(mw - 1, mh - 1));
            if (maskTex.read(uint2(q)).r != 0) {
                const float m = loadDepth(maskDepth, uint2(q));
                selected = !found ? m : (rev ? max(selected, m) : min(selected, m));  // nearest
                found = true;
            }
            const int2 sq = clamp(int2(float2(q) * scale), int2(0), int2(sw - 1, sh - 1));
            const float d = loadDepth(sceneDepth, uint2(sq));
            scene = rev ? min(scene, d) : max(scene, d);                               // farthest
        }
    }
    if (!found) return false;
    return rev ? selected < scene - depth.epsilon
               : selected > scene + depth.epsilon;
}

// Picks the instantiation of `isOccluded` matching this pipeline's depth inputs.
#define SELECTION_IS_OCCLUDED(p) ( \
    kMaskDepthIsFloat \
        ? (kSceneDepthIsFloat ? isOccluded(p, maskTex, maskDepthF, sceneDepthF, depth) \
                              : isOccluded(p, maskTex, maskDepthF, sceneDepthD, depth)) \
        : (kSceneDepthIsFloat ? isOccluded(p, maskTex, maskDepthD, sceneDepthF, depth) \
                              : isOccluded(p, maskTex, maskDepthD, sceneDepthD, depth)))

// MARK: - Pass 2: Dilate

// Forms the outline rings. A pixel outside every silhouette takes the style of
// the nearest selected pixel within that style's width, and inherits whether
// that pixel is hidden (bit 7). Highlight styles have width 0, so they get no ring.

kernel void outlineDilate(
    texture2d<uint, access::read>  maskTex     [[texture(0)]],
    texture2d<uint, access::write> edgeTex     [[texture(1)]],
    depth2d<float, access::read>   maskDepthD  [[texture(2), function_constant(kMaskDepthIsDepth)]],
    depth2d<float, access::read>   sceneDepthD [[texture(3), function_constant(kSceneDepthIsDepth)]],
    texture2d<float, access::read> maskDepthF  [[texture(6), function_constant(kMaskDepthIsFloat)]],
    texture2d<float, access::read> sceneDepthF [[texture(7), function_constant(kSceneDepthIsFloat)]],
    constant int32_t&              maxWidth    [[buffer(0)]],
    constant SelectionStyle*       styles      [[buffer(1)]],
    constant DepthParams&          depth       [[buffer(2)]],
    uint2 gid                                  [[thread_position_in_grid]]
) {
    const uint w = maskTex.get_width();
    const uint h = maskTex.get_height();
    if (gid.x >= w || gid.y >= h) return;

    if (maskTex.read(gid).r != 0) {
        edgeTex.write(uint4(0), gid);
        return;
    }

    uint bestStyle = 0;
    uint2 bestPixel = gid;
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
            const int sw = styles[style].width;
            if (d2 > sw * sw) continue;
            bestStyle = style;
            bestPixel = uint2(nx, ny);
            bestDistance = d2;
        }
    }

    uint edge = bestStyle;
    if (bestStyle != 0 && SELECTION_IS_OCCLUDED(bestPixel)) {
        edge |= kOccludedBit;
    }
    edgeTex.write(uint4(edge), gid);
}

// MARK: - Pass 3: Composite

// Linear -> sRGB transfer, for writing through a non-sRGB view of an sRGB
// target (see SelectionCompositor.writableTarget).
static float3 encodeSRGB(float3 c) {
    c = saturate(c);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, 12.92 * c, c <= 0.0031308);
}

// Blends outline rings and highlight fills over the source frame. Hidden parts
// are drawn at their style's `occludedOpacity`.
kernel void outlineComposite(
    texture2d<float, access::read>  sourceColor  [[texture(0)]],
    texture2d<uint, access::read>   edgeMask     [[texture(1)]],
    texture2d<float, access::write> targetColor  [[texture(2)]],
    texture2d<uint, access::read>   maskTex      [[texture(3)]],
    depth2d<float, access::read>    maskDepthD   [[texture(4), function_constant(kMaskDepthIsDepth)]],
    depth2d<float, access::read>    sceneDepthD  [[texture(5), function_constant(kSceneDepthIsDepth)]],
    texture2d<float, access::read>  maskDepthF   [[texture(6), function_constant(kMaskDepthIsFloat)]],
    texture2d<float, access::read>  sceneDepthF  [[texture(7), function_constant(kSceneDepthIsFloat)]],
    constant SelectionStyle*        styles       [[buffer(0)]],
    constant uint&                  encodeOutput [[buffer(1)]],
    constant DepthParams&           depth        [[buffer(2)]],
    uint2 gid                                    [[thread_position_in_grid]]
) {
    const uint w = sourceColor.get_width();
    const uint h = sourceColor.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float4 color = sourceColor.read(gid);

    const uint edge = edgeMask.read(gid).r;
    const uint ringStyle = edge & ~kOccludedBit;
    if (ringStyle != 0) {
        const SelectionStyle s = styles[ringStyle];
        const float alpha = s.color.a * ((edge & kOccludedBit) != 0 ? s.occludedOpacity : 1.0);
        color = mix(color, float4(s.color.rgb, 1.0), saturate(alpha));
    } else {
        const uint fillStyle = maskTex.read(gid).r;
        if (fillStyle != 0 && styles[fillStyle].kind == 1) {
            const SelectionStyle s = styles[fillStyle];
            const bool hidden = SELECTION_IS_OCCLUDED(gid);
            const float alpha = s.color.a * s.strength * (hidden ? s.occludedOpacity : 1.0);
            color = mix(color, float4(s.color.rgb, 1.0), saturate(alpha));
        }
    }

    if (encodeOutput != 0) {
        color.rgb = encodeSRGB(color.rgb);
    }
    targetColor.write(color, gid);
}
