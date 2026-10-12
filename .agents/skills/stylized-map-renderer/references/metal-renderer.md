# Metal renderer — stylized map on Apple TBDR GPUs

Everything here targets iOS/iPadOS/macOS on Apple silicon (A13+ / M1+), Metal 3 where noted. Code is
MSL + Swift. Adapt the names to the user's engine.

## Contents
1. Frame structure and pass setup (TBDR rules)
2. Vertex formats
3. Shared shader code: uniforms, octahedral normals, stylized lighting, fog
4. Building shell shader (shader bevel, AO, palette)
5. Far-LOD façade windows in the shader
6. Instanced windows and roof props
7. Trees: canopy shading and grain
8. Ground, baked shadows, blob decals
9. Optional runtime shadow map (near field)
10. GPU-driven culling and LOD selection
11. Pipeline creation without load-time stalls
12. Optional: mesh shaders for on-device extrusion
13. Performance rules of thumb
14. Style-specific shader patterns (tiles, curtain walls, timbering, domes)

---

## 1. Frame structure and pass setup

One render pass per frame, plus an optional shadow pass that only runs when the near-field changes:

```
[shadow pass — rarely]  →  main pass (4× MSAA, memoryless) → resolve to drawable
main pass draw order:
  1 building shells (opaque)          per tile, 1 draw per LOD bucket
  2 roof props, windows (instanced)   1 draw per library mesh
  3 trees (instanced)                 1 draw per tree kind per LOD
  4 ground tiles (opaque)
  5 blob decals (multiply blend, depth test on, depth write off)
  6 labels / UI
```

```swift
// Create once (and on resize). Memoryless = lives only in tile memory, never touches DRAM.
func makeTargets(size: CGSize) {
    let c = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
            width: Int(size.width), height: Int(size.height), mipmapped: false)
    c.textureType = .type2DMultisample; c.sampleCount = 4
    c.usage = .renderTarget; c.storageMode = .memoryless
    msaaColor = device.makeTexture(descriptor: c)

    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
            width: c.width, height: c.height, mipmapped: false)
    d.textureType = .type2DMultisample; d.sampleCount = 4
    d.usage = .renderTarget; d.storageMode = .memoryless
    msaaDepth = device.makeTexture(descriptor: d)
}

let rp = MTLRenderPassDescriptor()
rp.colorAttachments[0].texture        = msaaColor
rp.colorAttachments[0].resolveTexture = drawable.texture
rp.colorAttachments[0].loadAction     = .clear
rp.colorAttachments[0].clearColor     = MTLClearColor(red: 0.66, green: 0.80, blue: 0.92, alpha: 1)
rp.colorAttachments[0].storeAction    = .multisampleResolve
rp.depthAttachment.texture     = msaaDepth
rp.depthAttachment.loadAction  = .clear
rp.depthAttachment.clearDepth  = 0.0          // reverse-Z: far = 0
rp.depthAttachment.storeAction = .dontCare
```

Use **reverse-Z** (`depthCompareFunction = .greater`, clear 0, infinite far plane). City scenes span
1 m to 20 km, and reverse-Z with float depth removes z-fighting on roofs and decals.

## 2. Vertex formats

**Building shell vertex (28 bytes, every offset 4-byte aligned):**

| attr | format | content |
|---|---|---|
| 0 | `.short4Normalized` @0 | xyz tile-local position ÷ halfExtent, w unused |
| 1 | `.char4Normalized` @8 | octahedral normal in xy (zw spare) |
| 2 | `.uchar4` @12 | palette index, AO (0–255), flags (bit0 = bevel corner), sweep id |
| 3 | `.half4` @16 | edgeU, wallLen, topDist, heightAboveBase |
| 4 | `.char4Normalized` @24 | octahedral left-neighbour normal (xy), right-neighbour (zw) |

Metal requires attribute offsets to be multiples of 4 bytes, hence the spare bytes in attr 1.

```swift
let vd = MTLVertexDescriptor()
func attr(_ i: Int, _ f: MTLVertexFormat, _ off: Int) {
    vd.attributes[i].format = f; vd.attributes[i].offset = off; vd.attributes[i].bufferIndex = 0
}
attr(0, .short4Normalized, 0)
attr(1, .char4Normalized, 8)
attr(2, .uchar4, 12)
attr(3, .half4, 16)
attr(4, .char4Normalized, 24)
vd.layouts[0].stride = 28
```

**Library mesh vertex (trees, windows, props), 16 bytes:** `half4` position @0 (w = gradient t / AO),
`char4Normalized` @8 (oct normal xy, zw spare), `uchar4` @12 (part id, material slot, spare).

**Instance record (16 bytes, GPU-side after decode):** `float3 pos` (tile-local) + `uint packed`
(yaw:12 | scale:8 | palette:8 | variant:4).

## 3. Shared shader code

```metal
#include <metal_stdlib>
using namespace metal;

struct FrameUniforms {
    float4x4 viewProj;
    float3 cameraPos;   float time;
    float3 sunDir;      float wrap;          // sunDir points TOWARD the sun, normalized
    float3 sunColor;    float fogDensity;
    float3 shadowTint;  float fogHeightFalloff;
    float3 skyColor;    float bevelRadius;
    float3 groundBounce;float rimStrength;
    float3 fogColor;    float aoStrength;
};

struct TileUniforms { float3 origin; float halfExtent; };

inline float3 octDecode(float2 e) {
    float3 n = float3(e, 1.0 - abs(e.x) - abs(e.y));
    float t = saturate(-n.z);
    n.xy += select(float2(t), float2(-t), n.xy >= 0.0);
    return normalize(n);
}

// The heart of the look: wrapped soft diffuse pulled toward a purple shadow tint,
// hemisphere ambient, tinted AO, faint rim.
inline half3 stylize(half3 albedo, float3 N, float3 V, float shadow, float ao,
                     constant FrameUniforms& F) {
    float ndl  = dot(N, F.sunDir);
    float diff = saturate((ndl + F.wrap) / (1.0 + F.wrap));
    diff       = smoothstep(0.02, 0.98, diff);               // soft ramp, no hard terminator
    float lit  = diff * shadow;

    float3 direct  = mix(F.shadowTint, F.sunColor, lit);
    float3 ambient = mix(F.groundBounce, F.skyColor, N.y * 0.5 + 0.5);
    float3 aoTint  = mix(F.shadowTint, float3(1.0), mix(1.0, ao, F.aoStrength));
    float  rim     = pow(1.0 - saturate(dot(N, V)), 3.0) * F.rimStrength;

    float3 c = float3(albedo) * (direct * 0.78 + ambient * 0.30) * aoTint + rim * F.skyColor;
    return half3(c);
}

inline half3 applyFog(half3 c, float3 wp, constant FrameUniforms& F) {
    float d = distance(wp, F.cameraPos);
    float h = exp(-max(wp.y, 0.0) * F.fogHeightFalloff);    // denser near the ground
    float f = 1.0 - exp(-d * F.fogDensity * (0.6 + 0.4 * h));
    return mix(c, half3(F.fogColor), half(saturate(f)));
}
```

Starting values: `wrap 0.45`, `sunDir normalize(-0.5, 0.75, 0.45)`, `sunColor (1.0, 0.97, 0.92)`,
`shadowTint (0.55, 0.53, 0.75)`, `skyColor (0.72, 0.82, 0.95)`, `groundBounce (0.80, 0.78, 0.62)`,
`rimStrength 0.08`, `bevelRadius 0.6 m`, `fogDensity 0.00018`, `fogHeightFalloff 0.004`,
`aoStrength 1.0`. Convert colours to linear if the drawable is `_srgb`.

## 4. Building shell shader

```metal
struct ShellIn {
    float4 pos     [[attribute(0)]];
    float4 oct     [[attribute(1)]];   // xy used
    uchar4 info    [[attribute(2)]];   // palette, ao, flags, sweep
    half4  bevel   [[attribute(3)]];   // edgeU, wallLen, topDist, heightAboveBase
    float4 nbr     [[attribute(4)]];   // oct left (xy), oct right (zw)
};

struct ShellOut {
    float4 position [[position]];
    float3 wp;
    float3 n, nL, nR;
    float4 bevel;
    float  ao;
    uint   palette [[flat]];
    uint   flags   [[flat]];
};

vertex ShellOut shellVS(ShellIn in [[stage_in]],
                        constant FrameUniforms& F [[buffer(1)]],
                        constant TileUniforms&  T [[buffer(2)]]) {
    ShellOut o;
    o.wp      = T.origin + in.pos.xyz * T.halfExtent;
    o.position= F.viewProj * float4(o.wp, 1.0);
    o.n       = octDecode(in.oct.xy);
    o.nL      = octDecode(in.nbr.xy);
    o.nR      = octDecode(in.nbr.zw);
    o.bevel   = float4(in.bevel);
    o.ao      = float(in.info.y) / 255.0;
    o.palette = in.info.x;
    o.flags   = in.info.z;
    return o;
}

// Bend the normal toward the neighbouring face near hard edges. At the exact edge both
// faces produce the same half-vector, so shading is continuous: a rounded edge with 0 triangles.
inline float3 bevelNormal(float3 N, float3 nL, float3 nR, float4 b, float r) {
    float wl = 1.0 - smoothstep(0.0, r, b.x);            // distance to left corner
    float wr = 1.0 - smoothstep(0.0, r, b.y - b.x);      // distance to right corner
    float wt = 1.0 - smoothstep(0.0, r, b.z);            // distance to wall top
    float3 n = N;
    n = normalize(mix(n, normalize(N + nL), wl));
    n = normalize(mix(n, normalize(N + nR), wr));
    n = normalize(mix(n, normalize(n + float3(0, 1, 0)), wt));
    return n;
}

fragment half4 shellFS(ShellOut in [[stage_in]],
                       constant FrameUniforms& F       [[buffer(1)]],
                       constant half4*         palette [[buffer(3)]],
                       texture2d<half>         groundShadow [[texture(0)]]) {
    float3 N = normalize(in.n);
    if (in.flags & 1u) N = bevelNormal(N, in.nL, in.nR, in.bevel, F.bevelRadius);
    float3 V = normalize(F.cameraPos - in.wp);

    half3 albedo = palette[in.palette].rgb;
    // Gentle height gradient: slightly darker at the base, lighter near the top.
    albedo *= half(mix(0.92, 1.04, saturate(in.bevel.w / 12.0)));

    float shadow = 1.0;   // static building-on-building shadows are optional; see §9
    half3 c = stylize(albedo, N, V, shadow, in.ao, F);
    return half4(applyFog(c, in.wp, F), 1.0h);
}
```

## 5. Far-LOD façade windows in the shader

At LOD1 the window instances are dropped. The wall fragment shader draws the *same* grid with
rounded-rect SDFs, so the switch is invisible. The placement constants must match
`geometry-recipes.md` §6 exactly (margin, spacing, sill height, floor height, skip rules).

```metal
inline float sdRoundRect(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

inline half3 facadeWindows(half3 wall, float u, float len, float yb, float floorH,
                           float spacing, half3 frameC, half3 glassTop, half3 glassBot) {
    const float sill = 0.9, halfW = 0.55, halfH = 0.75;
    if (len < 1.5) return wall;
    float margin = min(0.6, max(0.1, (len - 1.3) * 0.5));
    float usable = len - 2.0 * margin;
    float n      = max(floor(usable / spacing), 1.0);
    float start  = margin + (usable - (n - 1.0) * spacing) * 0.5;
    float i      = clamp(round((u - start) / spacing), 0.0, n - 1.0);
    float cx     = start + i * spacing;
    float f      = floor(yb / floorH);
    if (f < 1.0) return wall;                                  // ground floor rule
    float cy     = f * floorH + sill + halfH;
    float2 p     = float2(u - cx, yb - cy);

    float dF = sdRoundRect(p, float2(halfW, halfH), 0.06);
    float dG = sdRoundRect(p, float2(halfW - 0.11, halfH - 0.11), 0.03);
    float aaF = max(fwidth(dF), 1e-4), aaG = max(fwidth(dG), 1e-4);

    half3 glass = mix(glassBot, glassTop, half(saturate((p.y + halfH) / (2.0 * halfH))));
    half3 c = mix(wall, frameC, half(1.0 - smoothstep(0.0, aaF, dF)));
    c = mix(c, glass, half(1.0 - smoothstep(0.0, aaG, dG)));
    return c;
}
```

For skyscrapers, use the same function with office-strip parameters (wide halfW, short floor
spacing), or a 1D band pattern on `yb`. It costs ~20 ALU ops and no texture.

## 6. Instanced windows and roof props

```metal
struct Instance { packed_float3 pos; uint packed; };   // yaw:12 scale:8 palette:8 variant:4

struct LibIn { half4 pos [[attribute(0)]]; float4 oct [[attribute(1)]]; uchar4 part [[attribute(2)]]; };
struct LibOut { float4 position [[position]]; float3 wp; float3 n; float t; uint palette [[flat]]; uint part [[flat]]; };

vertex LibOut libraryVS(LibIn in [[stage_in]],
                        uint iid [[instance_id]],
                        const device Instance* inst [[buffer(4)]],
                        constant FrameUniforms& F   [[buffer(1)]],
                        constant TileUniforms&  T   [[buffer(2)]]) {
    Instance I = inst[iid];
    float yaw   = float(I.packed & 0xFFFu) * (2.0 * M_PI_F / 4096.0);
    float scale = 0.5 + float((I.packed >> 12) & 0xFFu) / 255.0 * 1.5;   // 0.5–2.0
    float s = sin(yaw), c = cos(yaw);
    float3 lp = float3(in.pos.xyz) * scale;
    float3 rp = float3(c * lp.x + s * lp.z, lp.y, -s * lp.x + c * lp.z);
    float3 n  = octDecode(in.oct.xy);
    LibOut o;
    o.wp = T.origin + float3(I.pos) + rp;
    o.position = F.viewProj * float4(o.wp, 1.0);
    o.n  = float3(c * n.x + s * n.z, n.y, -s * n.x + c * n.z);
    o.t  = float(in.pos.w);                 // gradient / AO channel authored in the mesh
    o.palette = (I.packed >> 20) & 0xFFu;
    o.part    = in.part.x;                  // 0 = frame, 1 = glass, 2 = sill, …
    return o;
}
```

The fragment shader picks the colour by `part` (frame/sill = trim colour, glass = gradient on `t`) and
calls `stylize`. Window glass uses `stylize` with a reduced diffuse plus a faint sky reflection:
`mix(glass, skyColor, 0.15 * fresnel)`.

## 7. Trees

The library mesh already carries **canopy normals** and a gradient value `t` (0 = canopy bottom,
1 = top) in `pos.w`. The fragment shader adds the painterly grain:

```metal
inline float hash31(float3 p) {
    p = fract(p * 0.1031); p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}
inline float valueNoise(float3 p) {
    float3 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    float n000 = hash31(i), n100 = hash31(i + float3(1,0,0));
    float n010 = hash31(i + float3(0,1,0)), n110 = hash31(i + float3(1,1,0));
    float n001 = hash31(i + float3(0,0,1)), n101 = hash31(i + float3(1,0,1));
    float n011 = hash31(i + float3(0,1,1)), n111 = hash31(i + float3(1,1,1));
    return mix(mix(mix(n000,n100,f.x), mix(n010,n110,f.x), f.y),
               mix(mix(n001,n101,f.x), mix(n011,n111,f.x), f.y), f.z);
}

fragment half4 canopyFS(LibOut in [[stage_in]],
                        constant FrameUniforms& F [[buffer(1)]],
                        constant half4* palette   [[buffer(3)]]) {
    // palette[p] = bottom colour, palette[p+1] = top colour
    half3 bottom = palette[in.palette].rgb, top = palette[in.palette + 1].rgb;
    half3 albedo = mix(bottom, top, half(smoothstep(0.0, 1.0, in.t)));
    float grain  = valueNoise(in.wp * 7.0) * 0.6 + valueNoise(in.wp * 19.0) * 0.4;
    albedo *= half(0.94 + 0.12 * grain);
    float3 N = normalize(in.n), V = normalize(F.cameraPos - in.wp);
    half3 c = stylize(albedo, N, V, 1.0, mix(0.7, 1.0, in.t), F);
    return half4(applyFog(c, in.wp, F), 1.0h);
}
```

The trunk uses the same library pipeline with `part == trunk` → flat trunk colour.

Optional wind: in the vertex shader, offset canopy vertices by
`sin(time*1.3 + hash(instance)) * 0.03 * t`. Keep it subtle.

## 8. Ground, baked shadows, blob decals

**Ground tile:** a flat mesh per tile. Colour comes from ground polygons (vertex palette) or a small
colour texture. The baked texture `groundShadow` holds R = sun shadow (0 = shadowed), G = AO, at
0.5 m/px (512² per 256 m tile, BC4/BC5 or ASTC, about 128–256 KB).

```metal
fragment half4 groundFS(GroundOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]],
                        texture2d<half> sh [[texture(0)]], sampler s [[sampler(0)]]) {
    half2 so = sh.sample(s, in.uv).rg;
    half3 c  = stylize(in.albedo, float3(0,1,0), normalize(F.cameraPos - in.wp), so.r, so.g, F);
    return half4(applyFog(c, in.wp, F), 1.0h);
}
```

**Blob decals (tree shadows, prop AO):** instanced quads lying on the ground or roof, drawn with
**multiply** blending.

```swift
let ca = pipeDesc.colorAttachments[0]!
ca.isBlendingEnabled = true
ca.rgbBlendOperation = .add
ca.sourceRGBBlendFactor = .destinationColor     // result = dst * src
ca.destinationRGBBlendFactor = .zero
// depth: compare .greater (reverse-Z), write disabled; lift quads 2 cm or use depth bias.
```

```metal
fragment half4 blobFS(BlobOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]]) {
    float r = length(in.uv);                         // uv in [-1, 1]
    float a = (1.0 - smoothstep(0.25, 1.0, r)) * in.strength;   // 0.45 trees, 0.3 props
    return half4(mix(half3(1.0), half3(F.shadowTint), half(a)), 1.0h);
}
```

In the vertex shader, offset the tree's blob centre by
`-sunDir.xz / sunDir.y * canopyHeight * 0.6` and stretch it along the same direction. That reproduces
the elongated blurry tree shadows on roads.

## 9. Optional runtime shadow map (near field)

Only needed if you want building-on-building and building-on-tree shadows near the camera. The sun
is fixed and the city is static, so:

- Render one 2048² `depth16Unorm` shadow map covering ~400 m around the camera focus. Regenerate it
  **only when the focus moves > 50 m**, not every frame.
- Sample with a 12-tap Poisson PCF and a wide radius (~1.5 m in world space) for the soft look. Feed the
  result into `stylize(..., shadow, ...)` multiplied by the baked ground shadow.
- Beyond 400 m, fall back to baked ground shadows only. Fog hides the transition.

## 10. GPU-driven culling and LOD selection

With 50–150 visible tiles, per-tile per-material CPU encoding stays under ~150 draws if you merge.
For instance-heavy content (trees, windows), cull on the GPU:

```metal
struct DrawArgs { atomic_uint indexCount; atomic_uint instanceCount; uint indexStart; int baseVertex; uint baseInstance; };

kernel void cullInstances(const device Instance* src       [[buffer(0)]],
                          device Instance*       dstLOD0   [[buffer(1)]],
                          device Instance*       dstLOD1   [[buffer(2)]],
                          device DrawArgs*       args      [[buffer(3)]],   // [0] LOD0, [1] LOD1
                          constant FrameUniforms& F        [[buffer(4)]],
                          constant float4*        planes   [[buffer(5)]],   // 6 frustum planes
                          constant float2&        lodDist  [[buffer(6)]],   // (lod0Max, lod1Max)
                          constant uint&          count    [[buffer(7)]],
                          uint id [[thread_position_in_grid]]) {
    if (id >= count) return;
    Instance I = src[id];
    float3 p = float3(I.pos);
    const float radius = 8.0;
    for (int k = 0; k < 6; ++k) if (dot(planes[k].xyz, p) + planes[k].w < -radius) return;
    float d = distance(p, F.cameraPos);
    if (d < lodDist.x) {
        uint slot = atomic_fetch_add_explicit(&args[0].instanceCount, 1, memory_order_relaxed);
        dstLOD0[slot] = I;
    } else if (d < lodDist.y) {
        uint slot = atomic_fetch_add_explicit(&args[1].instanceCount, 1, memory_order_relaxed);
        dstLOD1[slot] = I;
    }
}
```

Reset `instanceCount` with a blit fill each frame. Then
`drawIndexedPrimitives(type:indexType:indexBuffer:indexBufferOffset:indirectBuffer:indirectBufferOffset:)`.
For hundreds of tiles, encode the draws into an `MTLIndirectCommandBuffer` and bind tile resources
through **argument buffers** (tier 2, bindless). The CPU then encodes a handful of calls per frame
regardless of tile count.

## 11. Pipeline creation without load-time stalls

Synchronous `makeRenderPipelineState` at launch can cost seconds per pipeline on first run.

```swift
let archDesc = MTLBinaryArchiveDescriptor()
archDesc.url = Bundle.main.url(forResource: "pipelines", withExtension: "metallib")   // shipped archive
let archive = try device.makeBinaryArchive(descriptor: archDesc)
pipeDesc.binaryArchives = [archive]
device.makeRenderPipelineState(descriptor: pipeDesc) { pso, error in /* store */ }   // async
```

- Harvest archives for the shipping GPU families (Xcode's pipeline-script / `metal-tt` workflow). As a
  fallback, add pipelines to an archive on first run and `serialize(to:)` into Caches.
- Keep the pipeline count small (~10–15). Use one shell pipeline with flags rather than one per
  building style. Style variety comes from palette indices, not from shaders.

## 12. Optional: mesh shaders for on-device extrusion (Metal 3, Apple7+)

If tiles ship footprints instead of meshes, an object/mesh shader pair can emit walls directly. The
object stage takes one threadgroup per building and decides the LOD. The mesh stage emits
`2 × edges` wall triangles plus the sweep strips for that building, up to 256 verts / 512 prims per
meshlet, and splits large buildings into several meshlets. This removes vertex buffers for shells
entirely.

It's worth it only when tile download size is the bottleneck. Baked, meshopt-compressed shells
(see `tile-pipeline.md`) are already small and simpler to debug, so start there.

## 13. Performance rules of thumb

- Use `half` for colours and most fragment math. Apple GPUs run FP16 at about twice the rate.
- No `discard` and no alpha-tested foliage. Both break hidden-surface removal on TBDR. Trees are
  solid meshes.
- Keep fragment shaders under ~60 ALU ops for shells and ground. They cover most of the screen.
- One vertex/index buffer per tile (sub-allocated from an `MTLHeap`). Never one buffer per building.
- Use `.storageModePrivate` for static tile data, uploaded via a blit or `MTLIOCommandQueue`, and
  `.storageModeShared` only for per-frame uniforms (triple-buffered).
- Profile in Xcode's GPU frame capture. Check *Performance → Limiters*. For this style the expected
  limiter is fragment ALU or vertex count. If it's "Tiled vertex" with millions of triangles, return to
  the geometry budgets.

## 14. Style-specific shader patterns (zero triangles)

These replace geometry at LOD1+, or add surface character the meshes don't carry. Select them
with the shell vertex's `sweep id` byte (attr 2.w) or a per-building material id in the palette
entry.

**Barrel tiles (Spanish, Mediterranean roofs).** Roof facets carry a facet-local `u` (metres along
the eave) and `s` (metres up-slope). Pass them in the bevel attribute slots for roof vertices, or
derive them from the world position and the facet normal. Then bend the normal across the tile
rows and darken the gaps:

```metal
inline float3 barrelTiles(float3 N, float3 T, float u, float s, thread float& shade) {
    const float pitchU = 0.28, rowS = 0.42;
    float x = fract(u / pitchU) * 2.0 - 1.0;              // -1..1 across one tile
    float bend = x * 0.55;                                // half-cylinder normal tilt
    float row = fract(s / rowS);
    shade = mix(0.82, 1.0, smoothstep(0.0, 0.12, row));  // overlap shadow at each row
    return normalize(N + T * bend);                       // T = eave tangent
}
```

**Curtain wall (glass towers, LOD1+ for all towers).** Same `edgeU` / `heightAboveBase` attributes as
the façade windows: mullion lines every 1.5 m, spandrel band every floor, sky reflection rising
with height.

```metal
inline half3 curtainWall(half3 glass, half3 frame, float u, float yb, float floorH, float3 N, float3 V,
                         constant FrameUniforms& F) {
    float mu = abs(fract(u / 1.5) - 0.5) * 1.5;               // metres to nearest mullion
    float fy = fract(yb / floorH) * floorH;                   // metres into the floor
    float line = 1.0 - smoothstep(0.03, 0.03 + fwidth(u), mu);
    float span = step(floorH - 0.9, fy);                      // spandrel band
    half3 c = mix(glass, glass * 0.8h + half3(F.skyColor) * 0.2h,
                  half(pow(1.0 - saturate(dot(N, V)), 2.0)));
    c = mix(c, frame * 0.9h, half(span * 0.85));
    return mix(c, frame, half(line));
}
```

**Grid (Art Deco) at distance.** Keep the piers as geometry (they make the silhouette ribbing).
Replace the spandrel strips with `span` from the curtain function using a stone colour.

**Half-timbering / Japanese frame at LOD1.** Draw posts as `abs(fract(u / 1.05) - 0.5) < 0.085`
above the first floor line and beams at `fract(yb / floorH)` near 0. Match the spacing in
`styles.py` (`1.05 m`, `1.8 m`) so the LOD switch is invisible.

**Brick / stone texture hint.** Very subtle. Modulate albedo by ±4% with a stretched
`valueNoise(float3(u * 4, yb * 12, 0))` on brick styles (`colonial`, `tudor` ground floor,
`brownstone`, `dutch_canal`). Anything stronger fights the clean look.

**Domes.** Lead and tile domes look best with a slightly stronger rim
(`rimStrength × 2` for dome materials) and a faint vertical rib pattern:
`1 − 0.06·(1 − smoothstep(0, 0.04, abs(fract(atan2(p.z, p.x) · ribs / 2π) − 0.5)))` with
`ribs = 16–24`. Gold domes need `sunColor`-tinted specular: `pow(saturate(dot(reflect(−V, N), sunDir)), 24) × 0.5`.

**Corrugated iron (mabati) roofs.** Bend the normal across the corrugation: `bend = sin(u * 2π / 0.076) * 0.35`
along the eave tangent (76 mm pitch, too fine to model). At distance, fade the bend with
`fwidth(u)` to avoid aliasing. Rust: blend toward `#8B5A3C` using low-frequency
`valueNoise(world * 0.3)` × per-building rust amount (palette alpha). Painted roofs get none.

**Makuti thatch.** Darken along the slope in strands: `shade = 0.88 + 0.12 * valueNoise(float3(u * 6, s * 0.8, 0))`,
plus a warm rim at the eave. Keep the roof thick (`thick 0.35`). The visible thickness is what
reads as thatch in this style; it costs no texture.
