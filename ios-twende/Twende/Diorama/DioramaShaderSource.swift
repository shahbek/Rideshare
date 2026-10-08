import Foundation
import Metal
import simd

/// Per-frame constants for the diorama shader. Layout mirrors `DioramaUniforms` in the Metal source.
nonisolated struct DioramaShaderUniforms {
    var eye: SIMD4<Float>
    var sunDirection: SIMD4<Float>
    var sunColor: SIMD4<Float>
    var skyColor: SIMD4<Float>
    var groundColor: SIMD4<Float>
    /// x: emissive glow strength, y: animation time in seconds (0 when motion is reduced), z: time-of-day
    /// index, w: reflection pass flag (1 = mirrored).
    var params: SIMD4<Float>
    /// x: grid min x, y: grid min y, z: cell size, w: cells per side.
    var lightGrid: SIMD4<Float>
    /// x: water surface height, y: clip plane enabled, z/w: reflection texture size.
    var water: SIMD4<Float>
    var shadowMatrix: simd_float4x4
    /// x: shadow enabled, y: texel size, z: depth bias, w: world-space soft edge (metres).
    var shadowParams: SIMD4<Float>
    /// x: shallow distance, y: foam width, z: reduced effects, w: reserved.
    var shoreline: SIMD4<Float>
    var waterDeep: SIMD4<Float>
    var waterShallow: SIMD4<Float>
    /// x/y: ground image origin (local metres), z/w: 1 / image extent in metres.
    var groundImage: SIMD4<Float>
    /// xy: stable peninsula-space material origin, z: local-to-reference scale; w reserved.
    var materialFrame: SIMD4<Float>
    /// x: ambient-occlusion strength (0 disables sampling), y: bloom strength, z: grade strength,
    /// w: haze density per metre.
    var post: SIMD4<Float>
    /// xy: reveal centre, z: square half-extent in metres, w: active flag.
    var reveal: SIMD4<Float>
    var lifecycleReveal: SIMD4<Float>
    /// Local tile xmin/ymin/xmax/ymax and exposed-edge weights (left/bottom/right/top).
    var tileBounds: SIMD4<Float>
    var tileEdges: SIMD4<Float>
    /// x opacity, y role (0 context, 1 full, 2 same-tile fallback), z reserved, w paired ownership.
    var tileState: SIMD4<Float>
}

/// Constants for the screen-space passes. Layout mirrors `DioramaPostUniforms` in the Metal source.
nonisolated struct DioramaPostUniforms {
    var matrix: simd_float4x4
    var eye: SIMD4<Float>
    /// x: occlusion radius (m), y: occlusion strength, z/w: target size in pixels.
    var params: SIMD4<Float>
    /// x/y: blur direction in texels, z: bloom strength, w: unused.
    var blur: SIMD4<Float>
}

/// Reference-led warm daylight (default), warm low sun/violet dusk, and cool moonlit night.
nonisolated enum DioramaLighting {
    static func uniforms(for time: DioramaTimeOfDay, eye: SIMD3<Float>) -> DioramaShaderUniforms {
        let sun: SIMD3<Float>, sunColor: SIMD3<Float>, sky: SIMD3<Float>, ground: SIMD3<Float>, glow: Float
        switch time {
        case .day:
            sun = simd_normalize(SIMD3<Float>(-0.55, -0.40, 0.73))
            sunColor = SIMD3<Float>(1.0, 0.99, 0.96) * 0.66
            sky = SIMD3<Float>(0.91, 0.93, 0.90)
            ground = SIMD3<Float>(0.65, 0.69, 0.53)
            glow = 0
        case .dusk:
            sun = simd_normalize(SIMD3<Float>(-0.75, -0.45, 0.34))
            sunColor = SIMD3<Float>(1.0, 0.62, 0.44) * 0.62
            sky = SIMD3<Float>(0.50, 0.42, 0.70)
            ground = SIMD3<Float>(0.30, 0.22, 0.34)
            glow = 1.0
        case .night:
            sun = simd_normalize(SIMD3<Float>(0.3, 0.5, 0.8))
            sunColor = SIMD3<Float>(0.30, 0.36, 0.58) * 0.45
            sky = SIMD3<Float>(0.20, 0.23, 0.40)
            ground = SIMD3<Float>(0.10, 0.09, 0.16)
            glow = 1.25
        }
        return DioramaShaderUniforms(
            eye: SIMD4<Float>(eye, 1),
            sunDirection: SIMD4<Float>(sun, 0),
            sunColor: SIMD4<Float>(sunColor, 1),
            skyColor: SIMD4<Float>(sky, 1),
            groundColor: SIMD4<Float>(ground, 1),
            params: SIMD4<Float>(glow, 0, time.shaderIndex, 0),
            lightGrid: .zero,
            water: .zero,
            shadowMatrix: matrix_identity_float4x4,
            shadowParams: .zero,
            shoreline: .zero,
            waterDeep: .zero,
            waterShallow: .zero,
            groundImage: .zero,
            materialFrame: SIMD4(0, 0, 1, 0),
            post: .zero,
            reveal: .zero,
            lifecycleReveal: .zero,
            tileBounds: .zero,
            tileEdges: .zero,
            tileState: SIMD4(1, 0, 0, 0)
        )
    }
}

/// Diorama shaders, compiled on-device (no offline Metal toolchain needed). One vertex/fragment pair
/// handles every category through `appearance.w`:
///   0 solid lit surface · 1 water · 4 emissive (lit windows, lanterns) · 5 camera-facing halo sprite.
/// Lighting is a hemisphere sky term, one directional sun and point lights looked up through a 2D grid,
/// so street lamps and lit facades really pool light on the pavement and walls beside them.
/// Bay water combines translucent shallows with softened, ripple-distorted planar scene reflections.
nonisolated enum DioramaShaderSource {
    static let source: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct DioramaInput {
        float4 position;
        float4 normal;
        float4 color;
        float4 appearance;
    };

    struct DioramaUniforms {
        float4 eye;
        float4 sunDirection;
        float4 sunColor;
        float4 skyColor;
        float4 groundColor;
        float4 params;
        float4 lightGrid;
        float4 water;
        float4x4 shadowMatrix;
        float4 shadowParams;
        float4 shoreline;
        float4 waterDeep;
        float4 waterShallow;
        float4 groundImage;
        float4 materialFrame;
        float4 post;
        float4 reveal;
        float4 lifecycleReveal;
        float4 tileBounds;
        float4 tileEdges;
        float4 tileState;
    };

    struct DioramaPostUniforms {
        float4x4 matrix;
        float4 eye;
        float4 params;
        float4 blur;
    };

    struct DioramaLight {
        float4 position;
        float4 color;
    };

    float3 dioramaGrade(float3 color, float3 worldPosition, constant DioramaUniforms &u);

    float dioramaFieldDistance(float3 p, float4 reveal) {
        float ripple = \(DioramaRevealStyle.variation) * (0.6 * sin(p.x * 0.025 + p.y * 0.011)
            + 0.4 * sin(p.y * 0.037 - p.x * 0.009));
        if (reveal.w > 1.5) {
            float d = dot(p.xy, reveal.xy) - reveal.z + ripple;
            return reveal.w > 2.5 ? -d : d;
        }
        float radius = min(12.0, max(0.0, reveal.z) * 0.08);
        float2 q = abs(p.xy - reveal.xy) - (reveal.z - radius);
        return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius + ripple;
    }
    float dioramaFieldCoverage(float3 p, float4 field) {
        if (field.w < 0.5) return 1.0;
        return 1.0 - smoothstep(-\(DioramaRevealStyle.feather), \(DioramaRevealStyle.feather), dioramaFieldDistance(p, field));
    }
    float dioramaEdgeCoverage(float3 p, float4 edges, constant DioramaUniforms &u) {
        if (all(edges <= float4(0.0))) return 1.0;
        float4 d = float4(p.xy - u.tileBounds.xy, u.tileBounds.zw - p.xy);
        if (all((d >= float4(\(DioramaRevealStyle.edgeWidth))) | (edges <= float4(0.0)))) return 1.0;
        float4 c = 1.0 - edges * (1.0 - smoothstep(float4(0.0), float4(\(DioramaRevealStyle.edgeWidth)), d));
        return c.x * c.y * c.z * c.w;
    }
    float dioramaFocusCoverage(float3 p, constant DioramaUniforms &u) {
        return dioramaFieldCoverage(p, u.reveal) * dioramaEdgeCoverage(p, u.tileEdges, u);
    }
    float dioramaRevealCoverage(float3 p, constant DioramaUniforms &u) {
        float focus = u.tileState.y > 1.5 ? 1.0 - dioramaFocusCoverage(p, u) : dioramaFieldCoverage(p, u.reveal);
        return focus * dioramaEdgeCoverage(p, u.tileEdges, u) * dioramaFieldCoverage(p, u.lifecycleReveal) * u.tileState.x;
    }
    float dioramaRevealAlpha(float3 p, float2 pixel, float coverage, constant DioramaUniforms &u) {
        if (u.tileState.w > 0.5 && u.params.w < 0.5) {
            float full = dioramaFocusCoverage(p, u);
            if (full > 0.001 && full < 0.999) {
                float threshold = fract(52.9829189 * fract(dot(floor(pixel), float2(0.06711056, 0.00583715))));
                bool selected = u.tileState.y > 1.5 ? threshold >= full : threshold < full;
                if (!selected) discard_fragment();
            } else if (u.tileState.y > 1.5 ? full >= 0.999 : full <= 0.001) {
                discard_fragment();
            }
            return u.tileState.y > 1.5 ? dioramaEdgeCoverage(p, u.tileEdges, u) * dioramaFieldCoverage(p, u.lifecycleReveal) * u.tileState.x : u.tileState.x;
        }
        return coverage;
    }
    float4 dioramaRevealColor(float3 color, float alpha, float coverage, constant DioramaUniforms &u) {
        // Reflection stores premultiplied coverage; the water sampler later unpremultiplies it.
        return u.params.w > 0.5 ? float4(color * alpha * coverage, alpha * coverage)
                               : float4(color, alpha * coverage);
    }
    void dioramaRevealClip(float3 p, constant DioramaUniforms &u) {
        if (u.shoreline.w > 0.5) {
            float2 uv = (p.xy - u.groundImage.xy) * u.groundImage.zw;
            if (any(uv < float2(0.0)) || any(uv >= float2(1.0))) discard_fragment();
        }
        if (dioramaRevealCoverage(p, u) < 0.001) discard_fragment();
    }

    /// One placement of a prototype: xyz translation + rotation about z, xyz scale + bounding radius.
    struct DioramaInstance {
        float4 placement;
        float4 scale;
        float4 tint;
        float4 grading;
    };

    struct DioramaVarying {
        float4 position [[position]];
        float3 worldPosition;
        float3 normal;
        float4 color;
        float4 appearance;
        float clipHeight;
        float treeVariation;
    };

    float3 dioramaPlace(float3 p, DioramaInstance inst) {
        float c = cos(inst.placement.w), s = sin(inst.placement.w);
        float3 q = p * inst.scale.xyz;
        return float3(q.x * c - q.y * s, q.x * s + q.y * c, q.z) + inst.placement.xyz;
    }

    float3 dioramaPlaceNormal(float3 n, DioramaInstance inst) {
        float c = cos(inst.placement.w), s = sin(inst.placement.w);
        float3 q = n / max(inst.scale.xyz, float3(0.0001));
        return normalize(float3(q.x * c - q.y * s, q.x * s + q.y * c, q.z));
    }

    DioramaVarying dioramaShade(DioramaInput v, float3 world, float3 normal, float4x4 matrix, constant DioramaUniforms &u) {
        DioramaVarying out;
        bool mirrored = u.params.w > 0.5;
        float waterZ = u.water.x;
        if (v.appearance.w > 4.5 && v.appearance.w < 5.5) {
            // Halo sprite: the normal carries the corner offset (x, y) and radius (z). Rebuild the quad
            // in world space facing the camera so it always reads as a round glow.
            float3 eye = u.eye.xyz;
            float3 centre = world;
            if (mirrored) { centre.z = 2.0 * waterZ - centre.z; }
            float3 toEye = normalize(eye - centre);
            float3 right = cross(float3(0.0, 0.0, 1.0), toEye);
            right = length(right) < 0.001 ? float3(1.0, 0.0, 0.0) : normalize(right);
            float3 up = cross(toEye, right);
            world = centre + (right * v.normal.x + up * v.normal.y) * v.normal.z;
            normal = float3(v.normal.x, v.normal.y, 0.0);
            out.clipHeight = v.position.z - waterZ;
        } else {
            out.clipHeight = world.z - waterZ;
            if (mirrored) {
                world.z = 2.0 * waterZ - world.z;
                normal.z = -normal.z;
            }
        }
        // Waves are shaded per pixel only. Displacing water vertices opens cracks at the mesh's
        // adaptive T-junctions, which read as a grid of pinholes over the whole bay.
        out.position = matrix * float4(world, 1.0);
        out.worldPosition = world;
        out.normal = normal;
        out.color = v.color;
        out.appearance = v.appearance;
        out.treeVariation = 0.5;
        return out;
    }

    vertex DioramaVarying dioramaVertex(uint id [[vertex_id]],
                                        const device DioramaInput *vertices [[buffer(0)]],
                                        constant float4x4 &matrix [[buffer(1)]],
                                        constant DioramaUniforms &u [[buffer(2)]]) {
        DioramaInput v = vertices[id];
        return dioramaShade(v, v.position.xyz, v.normal.xyz, matrix, u);
    }

    struct DioramaFleetContact { float4 position [[position]]; float2 local; };
    vertex DioramaFleetContact dioramaFleetContactVertex(uint id [[vertex_id]],
        constant float4x4 &matrix [[buffer(1)]], constant DioramaUniforms &u [[buffer(2)]],
        constant float4x4 &model [[buffer(3)]], constant float4 &dimensions [[buffer(4)]]) {
        constexpr float2 corners[6] = {float2(-1,-1),float2(1,-1),float2(1,1),
            float2(-1,-1),float2(1,1),float2(-1,1)};
        float2 local = corners[id];
        float3 world = (model * float4(local * dimensions.xy, 0.035, 1)).xyz;
        world.xy -= u.sunDirection.xy * 0.15;
        return {matrix * float4(world, 1), local};
    }
    fragment float4 dioramaFleetContactFragment(DioramaFleetContact in [[stage_in]]) {
        float alpha = (1.0 - smoothstep(0.20, 1.0, length(in.local))) * 0.20;
        return float4(0, 0, 0, alpha);
    }

    vertex DioramaVarying dioramaFleetVertex(uint id [[vertex_id]],
        const device DioramaInput *vertices [[buffer(0)]], constant float4x4 &matrix [[buffer(1)]],
        constant DioramaUniforms &u [[buffer(2)]], constant float4x4 &model [[buffer(3)]]) {
        DioramaInput v = vertices[id];
        float3 world = (model * v.position).xyz;
        float3 normal = normalize((model * float4(v.normal.xyz, 0.0)).xyz);
        return dioramaShade(v, world, normal, matrix, u);
    }

    /// Prototype geometry placed by the instance table; the instance id includes the base instance.
    vertex DioramaVarying dioramaInstancedVertex(uint id [[vertex_id]], uint instanceID [[instance_id]],
                                                 const device DioramaInput *vertices [[buffer(0)]],
                                                 constant float4x4 &matrix [[buffer(1)]],
                                                 constant DioramaUniforms &u [[buffer(2)]],
                                                 const device DioramaInstance *instances [[buffer(3)]]) {
        DioramaInput v = vertices[id];
        DioramaInstance inst = instances[instanceID];
        v.color.rgb = min(v.color.rgb * inst.tint.rgb, float3(1.0));
        if (inst.grading.w > 0.5) {
            v.appearance.z = (v.position.z * inst.grading.x + inst.grading.y) + 100.0;
        }
        DioramaVarying out = dioramaShade(v, dioramaPlace(v.position.xyz, inst), dioramaPlaceNormal(v.normal.xyz, inst), matrix, u);
        out.treeVariation = fract(sin(dot(inst.placement.xy * u.materialFrame.z + u.materialFrame.xy, float2(12.9898, 78.233))) * 43758.5453);
        return out;
    }

    vertex float4 dioramaShadowVertex(uint id [[vertex_id]],
                                      const device DioramaInput *vertices [[buffer(0)]],
                                      constant float4x4 &matrix [[buffer(1)]]) {
        return matrix * vertices[id].position;
    }

    vertex float4 dioramaInstancedShadowVertex(uint id [[vertex_id]], uint instanceID [[instance_id]],
                                               const device DioramaInput *vertices [[buffer(0)]],
                                               constant float4x4 &matrix [[buffer(1)]],
                                               const device DioramaInstance *instances [[buffer(3)]]) {
        return matrix * float4(dioramaPlace(vertices[id].position.xyz, instances[instanceID]), 1.0);
    }

    float dioramaShadow(float3 p, float3 n, constant DioramaUniforms &u, depth2d<float> shadowMap) {
        if (u.shadowParams.x < 0.5) return 1.0;
        float4 projected = u.shadowMatrix * float4(p + n * 0.06, 1.0);
        float3 q = projected.xyz / projected.w;
        float2 uv = float2(q.x * 0.5 + 0.5, 0.5 - q.y * 0.5);
        if (any(uv < float2(0.002)) || any(uv > float2(0.998)) || q.z <= 0.0 || q.z >= 1.0) return 1.0;
        constexpr sampler shadowSampler(coord::normalized, address::clamp_to_edge, filter::linear, compare_func::less_equal);
        float bias = u.shadowParams.z * (1.0 + 2.0 * (1.0 - saturate(dot(n, u.sunDirection.xyz))));
        // Compare each PCF tap against the receiver plane at that tap, not the centre depth.
        // A constant centre depth self-shadows flat ground/roofs in diagonal texel-sized bands.
        float2 dx = dfdx(uv), dy = dfdy(uv);
        float dzdx = dfdx(q.z), dzdy = dfdy(q.z);
        float det = dx.x * dy.y - dx.y * dy.x;
        float2 gradient = float2(0.0);
        if (abs(det) > 1e-10) {
            gradient = float2(dy.y * dzdx - dx.y * dzdy, dx.x * dzdy - dy.x * dzdx) / det;
        }
        float footprintBias = min(dot(abs(gradient), float2(u.shadowParams.y)) * 0.75, 0.003);
        float2 worldToUV = 0.5 * float2(
            length(float3(u.shadowMatrix[0].x, u.shadowMatrix[1].x, u.shadowMatrix[2].x)),
            length(float3(u.shadowMatrix[0].y, u.shadowMatrix[1].y, u.shadowMatrix[2].y)));
        float2 stepSize = clamp(worldToUV * u.shadowParams.w,
                                float2(u.shadowParams.y), float2(u.shadowParams.y * 5.0));
        constexpr float2 taps[9] = {
            float2(0.0, 0.0), float2(0.78, 0.18), float2(-0.72, -0.26),
            float2(0.21, -0.82), float2(-0.18, 0.76), float2(0.56, 0.64),
            float2(-0.60, 0.55), float2(0.59, -0.57), float2(-0.54, -0.66)
        };
        float visibility = 0.0;
        for (int i = 0; i < 9; i++) {
            float2 offset = taps[i] * stepSize;
            float receiverDepth = q.z + dot(gradient, offset) - bias - footprintBias;
            visibility += shadowMap.sample_compare(shadowSampler, uv + offset, receiverDepth);
        }
        return visibility / 9.0;
    }

    float dioramaHash(float2 p) {
        return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
    }
    float dioramaNoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        return mix(mix(dioramaHash(i), dioramaHash(i + float2(1, 0)), f.x),
                   mix(dioramaHash(i + float2(0, 1)), dioramaHash(i + float2(1, 1)), f.x), f.y);
    }

    float3 dioramaPointLights(float3 p, float3 n, constant DioramaUniforms &u,
                              const device DioramaLight *lights,
                              const device uint2 *table, const device uint *indices) {
        int cells = int(u.lightGrid.w);
        if (cells <= 0) return float3(0.0);
        int cx = clamp(int((p.x - u.lightGrid.x) / u.lightGrid.z), 0, cells - 1);
        int cy = clamp(int((p.y - u.lightGrid.y) / u.lightGrid.z), 0, cells - 1);
        uint2 entry = table[cy * cells + cx];
        float3 sum = float3(0.0);
        for (uint k = 0; k < entry.y; k++) {
            DioramaLight l = lights[indices[entry.x + k]];
            // A not-yet-revealed fixture must not light already-visible ground.
            // Keep off-camera fixtures whose finite radius still reaches a visible receiver.
            float fixtureCoverage = dioramaRevealCoverage(l.position.xyz, u);
            if (fixtureCoverage < 0.001) continue;
            float3 d = l.position.xyz - p;
            float dist2 = dot(d, d);
            float radius = l.position.w;
            if (dist2 > radius * radius) continue;
            float dist = sqrt(dist2);
            float3 L = d / max(dist, 0.01);
            float att = 1.0 - dist / radius;
            att = att * att * (1.0 / (1.0 + dist2 * 0.06));
            float wrap = saturate(dot(n, L) * 0.75 + 0.25);
            sum += l.color.rgb * (l.color.w * att * wrap * 3.2 * fixtureCoverage);
        }
        return sum;
    }

    struct DioramaPaintTriangle { float4 edge0; float4 edge1; float4 edge2; float4 color; };

    // Decode before filtering: averaging IDs 0 and 3 must never manufacture grass ID 1.
    float4 dioramaFinishCoverage(float material) {
        return float4(material == 1.0 ? 1.0 : 0.0, material == 6.0 ? 1.0 : 0.0,
                      material == 3.0 ? 1.0 : 0.0, material == 2.0 ? 1.0 : 0.0);
    }
    struct DioramaFinishLookup { float owner; float4 coverage; };
    DioramaFinishLookup dioramaGroundFinish(texture2d<float> image, float2 uv) {
        int2 size = int2(image.get_width(), image.get_height());
        float2 pixel = uv * float2(size) - 0.5;
        int2 origin = int2(floor(pixel));
        float2 f = fract(pixel);
        float4 alpha = float4(
            image.read(uint2(clamp(origin, int2(0), size - 1)), 0).a,
            image.read(uint2(clamp(origin + int2(1, 0), int2(0), size - 1)), 0).a,
            image.read(uint2(clamp(origin + int2(0, 1), int2(0), size - 1)), 0).a,
            image.read(uint2(clamp(origin + int2(1, 1), int2(0), size - 1)), 0).a);
        float4 ids = floor(alpha * 255.0 / 32.0 + 0.5);
        DioramaFinishLookup result;
        result.owner = f.y < 0.5 ? (f.x < 0.5 ? ids.x : ids.y) : (f.x < 0.5 ? ids.z : ids.w);
        result.coverage = mix(mix(dioramaFinishCoverage(ids.x), dioramaFinishCoverage(ids.y), f.x),
                              mix(dioramaFinishCoverage(ids.z), dioramaFinishCoverage(ids.w), f.x), f.y);
        return result;
    }
    float dioramaEarthFraction(float3 color) {
        // The original painter feathered RGB, but wrote a solid categorical dirt outline.
        // Project onto both unchanged source swatches so saved lawns retain their feather too.
        float3 earth = float3(179.0, 152.0, 122.0) / 255.0;
        float3 grass = float3(131.0, 173.0, 50.0) / 255.0;
        float3 lawn = float3(148.0, 188.0, 59.0) / 255.0;
        float3 dg = earth - grass, dl = earth - lawn;
        float tg = saturate(dot(color - grass, dg) / dot(dg, dg));
        float tl = saturate(dot(color - lawn, dl) / dot(dl, dl));
        float3 eg = color - mix(grass, earth, tg), el = color - mix(lawn, earth, tl);
        return dot(eg, eg) < dot(el, el) ? tg : tl;
    }

    // Non-grid fields avoid the square value-noise lattice in water pigment and caustics.
    float dioramaWaterField(float2 p, float time) {
        float3 phase = float3(dot(p, float2(0.83, 0.56)) - time * 0.71,
                              dot(p, float2(-0.47, 0.91)) + time * 0.53,
                              dot(p, float2(0.29, -1.13)) - time * 0.39);
        float3 resolved = 1.0 - smoothstep(float3(0.7), float3(2.5), fwidth(phase));
        return 0.5 + dot(sin(phase) * resolved, float3(0.22, 0.17, 0.11));
    }

    float dioramaWaterCaustic(float2 p, float time) {
        float3 phase = float3(dot(p, float2(1.7, 0.8)) + time * 0.61,
                              dot(p, float2(-0.9, 1.9)) - time * 0.47,
                              dot(p, float2(1.1, -1.4)) + time * 0.38);
        float3 resolved = 1.0 - smoothstep(float3(0.6), float3(2.0), fwidth(phase));
        float ridge = dot(sin(phase) * resolved, float3(0.40, 0.35, 0.25));
        return smoothstep(0.38, 0.84, ridge);
    }

    float2 dioramaWaterSlope(float2 p, float time) {
        float3 phase = float3(dot(p, float2(0.19, 0.12)) - time * 0.62,
                              dot(p, float2(-0.31, 0.49)) - time * 0.94,
                              dot(p, float2(1.9, 1.2)) - time * 1.75);
        float3 resolved = 1.0 - smoothstep(float3(0.5), float3(2.0), fwidth(phase));
        float3 crest = cos(phase) * resolved;
        return float2(0.19, 0.12) * crest.x * 0.38
            + float2(-0.31, 0.49) * crest.y * 0.16 + float2(1.9, 1.2) * crest.z * 0.015;
    }

    fragment float4 dioramaFragment(DioramaVarying in [[stage_in]],
                                    bool isFront [[front_facing]],
                                    constant DioramaUniforms &u [[buffer(0)]],
                                    const device DioramaLight *lights [[buffer(1)]],
                                    const device uint2 *lightTable [[buffer(2)]],
                                    const device uint *lightIndices [[buffer(3)]],
                                    const device DioramaPaintTriangle *paint [[buffer(4)]],
                                    const device uint2 *paintTable [[buffer(5)]],
                                    const device uint *paintIndices [[buffer(6)]],
                                    texture2d<float> reflection [[texture(0)]],
                                    depth2d<float> shadowMap [[texture(1)]],
                                    texture2d<float> groundImage [[texture(2)]],
                                    texture2d<float> occlusion [[texture(3)]],
                                    texture2d<float> microdetail [[texture(4)]]) {
        if (u.shoreline.w > 0.5) {
            float2 uv = (in.worldPosition.xy - u.groundImage.xy) * u.groundImage.zw;
            if (any(uv < float2(0.0)) || any(uv >= float2(1.0))) discard_fragment();
        }
        float code = in.appearance.w;
        float glow = u.params.x;
        bool mirrored = u.params.w > 0.5;

        if (mirrored && (in.clipHeight < -0.05 || (code > 0.5 && code < 1.5))) discard_fragment();
        float revealCoverage = dioramaRevealCoverage(in.worldPosition, u);
        if (revealCoverage < 0.001) discard_fragment();
        float revealAlpha = dioramaRevealAlpha(in.worldPosition, in.position.xy, revealCoverage, u);
        // Reflection pass: only what is above the water surface reflects; never the water itself.
        if (mirrored) {
            if (in.clipHeight < -0.05) discard_fragment();
            if (code > 0.5 && code < 1.5) discard_fragment();
        }

        if (code > 4.5 && code < 5.5) {
            float r = length(in.normal.xy);
            if (r > 1.0) discard_fragment();
            float a = pow(1.0 - r, 2.2) * 0.7 + pow(max(0.0, 1.0 - r * 3.0), 2.0) * 0.5;
            return dioramaRevealColor(in.color.rgb * glow, a * min(glow, 1.0), revealAlpha, u);
        }
        if (code > 5.5) { return dioramaRevealColor(in.color.rgb, 1.0, revealAlpha, u); }
        if (code > 3.5) {
            float3 c = in.color.rgb * (0.55 + 0.8 * glow) + float3(0.12, 0.05, 0.0) * glow;
            return dioramaRevealColor(min(c, float3(1.0)), 1.0, revealAlpha, u);
        }

        float3 n = normalize(in.normal);
        // Thin double-sided sheets (fronds, sails, canopies) light their back as a real surface.
        if (!isFront) n = -n;
        float3 view = normalize(u.eye.xyz - in.worldPosition);
        float3 albedo = in.color.rgb;
        float3 surfacePosition = in.worldPosition;
        float3 surfaceNormal = n;
        if (mirrored) {
            surfacePosition.z = 2.0 * u.water.x - surfacePosition.z;
            surfaceNormal.z = -surfaceNormal.z;
        }
        float3 detailNormal = surfaceNormal;

        // Walls grade lighter towards the top and darker at the base (height carried in appearance.z).
        if (in.appearance.z > 50.0 && code < 0.5) {
            float h = in.appearance.z - 100.0;
            albedo *= mix(0.90, 1.07, saturate(h / 9.0));
        }

        // Procedural ground textures (appearance.y), kept very quiet so the toy-town surfaces read as
        // smooth painted material with only a faint mottle: grass, sand, asphalt, paving.
        float tex = in.appearance.y;
        bool paintedGround = tex > 8.5 && tex < 9.5;
        float4 finish = dioramaFinishCoverage(tex);
        // Material 6 is glass outside the painted terrain; only its alpha codes mean dirt.
        if (!paintedGround) finish.y = 0.0;
        float grassDetailWeight = finish.x;
        float2 wp = surfacePosition.xy;
        float2 vegetationPosition = wp * u.materialFrame.z + u.materialFrame.xy;
        if (tex > 8.5 && tex < 9.5) {
            // Painted ground: albedo from the tile image, grain code from its alpha (×32).
            constexpr sampler groundSampler(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear, max_anisotropy(8));
            float2 guv = (wp - u.groundImage.xy) * u.groundImage.zw;
            guv.y = 1.0 - guv.y;
            float4 painted = groundImage.sample(groundSampler, guv);
            albedo = painted.rgb;
            DioramaFinishLookup material = dioramaGroundFinish(groundImage, guv);
            tex = material.owner;
            finish = material.coverage;
            if (finish.x > 0.0001) {
                // Coast pigment stays on the same surface; hard finishes keep their ownership.
                albedo = mix(albedo, in.color.rgb, saturate(in.appearance.z) * finish.x);
            }
        }
        float naturalArea = finish.x + finish.y;
        float naturalCoverage = paintedGround ? saturate(in.appearance.z) : 0.0;
        float soilFraction = 0.0;
        grassDetailWeight = 0.0;
        if (naturalArea > 0.0001) {
            float luminance = dot(albedo, float3(0.2126, 0.7152, 0.0722));
            if (paintedGround && finish.y > 0.0001) {
                soilFraction = smoothstep(0.08, 0.94, dioramaEarthFraction(albedo));
            }
            // Stable moisture/dryness fields at landscape, lawn and tuft scales. No moving noise.
            // All fields use the original material coordinates, including mirrored reflections.
            float broad = dioramaNoise(vegetationPosition * 0.027 + float2(11.4, -7.2));
            float2 patchPosition = float2(dot(vegetationPosition, float2(0.80, -0.60)),
                                          dot(vegetationPosition, float2(0.60, 0.80)));
            float patches = dioramaNoise(patchPosition * 0.105 + float2(-4.1, 19.7));
            float tufts = dioramaNoise(patchPosition * 0.73);
            float tone = smoothstep(0.32, 0.66, broad * 0.62 + patches * 0.28 + tufts * 0.10);
            float3 deepGrass = float3(54.0, 90.0, 45.0) / 255.0;
            float3 livingGrass = float3(104.0, 121.0, 54.0) / 255.0;
            float3 sunGrass = float3(169.0, 157.0, 89.0) / 255.0;
            float3 grass = tone < 0.55 ? mix(deepGrass, livingGrass, tone / 0.55)
                                      : mix(livingGrass, sunGrass, (tone - 0.55) / 0.45);
            float dry = smoothstep(0.36, 0.68, patches) * smoothstep(0.34, 0.64, broad);
            grass = mix(grass, float3(179.0, 160.0, 107.0) / 255.0, dry * 0.85);
            grass *= 0.92 + 0.16 * tufts;
            grass *= mix(0.97, 1.03, smoothstep(0.42, 0.72, luminance));
            float3 earth = float3(179.0, 152.0, 122.0) / 255.0;
            float vegetation = naturalArea * (1.0 - naturalCoverage);
            albedo = mix(albedo, mix(grass, earth, soilFraction), vegetation);
            grassDetailWeight = vegetation * (1.0 - soilFraction);
            if (soilFraction > 0.001) {
                float clods = dioramaNoise(wp * 1.7) * 0.65 + dioramaNoise(wp * 0.18) * 0.35;
                albedo *= 1.0 + (clods - 0.5) * 0.10 * vegetation * soilFraction;
            }
        }
        if (tex > 1.5 && tex < 2.5) {
            albedo *= 0.98 + 0.04 * (dioramaNoise(wp * 0.5) - 0.5);
        } else if (finish.z > 0.0001) {
            // Quiet rosy warm-grey; mask out white/yellow paint and red-earth road finishes.
            float coolAsphalt = smoothstep(-0.015, 0.045, albedo.b - albedo.g)
                * (1.0 - smoothstep(0.60, 0.80, min(albedo.r, min(albedo.g, albedo.b))));
            float weather = dioramaNoise(vegetationPosition * 0.055 + float2(8.2, 13.9));
            float aggregate = dioramaNoise(vegetationPosition * 0.85);
            float3 asphalt = mix(float3(119.0, 116.0, 111.0), float3(169.0, 156.0, 151.0), smoothstep(0.25, 0.76, weather)) / 255.0;
            asphalt *= 0.94 + 0.12 * aggregate;
            albedo = mix(albedo, asphalt, coolAsphalt * finish.z);
        } else if (tex > 3.5 && tex < 4.5) {
            albedo *= 0.98 + 0.04 * (dioramaNoise(wp * 0.6) - 0.5);
        }

        if (tex > 9.5 && tex < 10.5) {
            // Source cluster tones + smooth normals retain depth inside each crown. Stable placement
            // variation adds greener trees, rather than assigning every tree one pale lime material.
            float luminance = dot(albedo, float3(0.2126, 0.7152, 0.0722));
            float cluster = dioramaNoise(vegetationPosition * 0.38 + surfacePosition.z * 0.13);
            float tone = saturate(smoothstep(0.20, 0.72, luminance) * 0.68
                + smoothstep(-0.45, 0.92, surfaceNormal.z) * 0.22 + cluster * 0.10);
            float3 shade = float3(48.0, 76.0, 37.0) / 255.0;
            float3 middle = float3(99.0, 130.0, 56.0) / 255.0;
            float3 crown = float3(168.0, 187.0, 98.0) / 255.0;
            float greener = smoothstep(0.54, 0.90, in.treeVariation);
            middle = mix(middle, float3(72.0, 122.0, 65.0) / 255.0, greener * 0.65);
            crown = mix(crown, float3(137.0, 176.0, 94.0) / 255.0, greener * 0.55);
            albedo = tone < 0.58 ? mix(shade, middle, tone / 0.58)
                                 : mix(middle, crown, (tone - 0.58) / 0.42);
        }

        // Legacy saved wall vertices already carry height grading; texture them without a rebuild.
        if (tex < 0.5 && in.appearance.z > 100.0 && abs(n.z) < 0.25) tex = 12.0;
        // One mipmapped sample: CC0 grain in RG, crown leaves in B, larger curved grass blades in A.
        // Surface-gradient shading adds relief without displacement or additional geometry/passes.
        bool foliage = tex > 9.5 && tex < 10.5;
        bool roadSurface = finish.z > 0.001;
        bool roofSurface = tex > 10.5 && tex < 11.5;
        bool plasterSurface = tex > 11.5 && tex < 12.5;
        bool grassSurface = naturalArea > 0.0001;
        bool textured = grassSurface ? grassDetailWeight > 0.0001
            : ((tex > 0.5 && tex < 4.5) || (tex > 9.5 && tex < 13.5));
        if (textured && u.shoreline.z < 0.5 && u.groundColor.w > 0.5) {
            float repeatSize = grassSurface ? 1.6 : (foliage ? 2.4 : 1.4);
            float2 detailUV = vegetationPosition / repeatSize;
            if (foliage) {
                float3 axis = abs(surfaceNormal);
                if (axis.z < max(axis.x, axis.y)) {
                    detailUV = (axis.x > axis.y ? float2(vegetationPosition.y, surfacePosition.z)
                        : float2(vegetationPosition.x, surfacePosition.z)) / repeatSize;
                }
            } else if (tex > 11.5) {
                float2 tangent = normalize(float2(-surfaceNormal.y, surfaceNormal.x) + float2(0.0001, 0.0));
                detailUV = float2(dot(vegetationPosition, tangent), surfacePosition.z) / repeatSize;
            }
            float footprint = max(length(dfdx(detailUV)), length(dfdy(detailUV)));
            // Blade relief must resolve across several physical pixels, not a 2×2 derivative quad.
            float resolved = grassSurface ? 1.0 - smoothstep(0.008, 0.030, footprint)
                : 1.0 - smoothstep(0.04, 0.16, footprint);
            constexpr sampler detailSampler(coord::normalized, address::repeat, filter::linear, mip_filter::linear, max_anisotropy(8));
            float4 grain = microdetail.sample(detailSampler, detailUV);
            float value = (grassSurface || foliage) ? grain.r : grain.g;
            float strength = grassSurface ? 0.060 * grassDetailWeight : (foliage ? 0.025 : (roadSurface ? 0.16 : 0.09));
            albedo *= 1.0 + (value - 0.502) * strength * resolved;
            if (grassSurface || foliage || roadSurface || roofSurface || plasterSurface) {
                float reliefWeight = resolved * (grassSurface ? grassDetailWeight : 1.0);
                float relief = foliage ? grain.b : (grassSurface ? grain.a : grain.g);
                float height = relief * (foliage ? 0.016 : (grassSurface ? 0.012 : (roadSurface ? 0.008 : 0.006)));
                float3 dx = dfdx(surfacePosition), dy = dfdy(surfacePosition);
                float3 rx = cross(dy, surfaceNormal), ry = cross(surfaceNormal, dx);
                float determinant = dot(dx, rx);
                float3 gradient = (rx * dfdx(height) + ry * dfdy(height)) * sign(determinant);
                if (abs(determinant) > 1e-8) {
                    float3 slope = gradient / abs(determinant);
                    if (grassSurface && resolved > 0.001) {
                        // Texture-space finite differences are continuous per fragment; screen-space
                        // height derivatives otherwise create square normals on each fragment quad.
                        float step = max(1.0 / float(microdetail.get_width()), footprint);
                        float hx = microdetail.sample(detailSampler, detailUV + float2(step, 0.0)).a;
                        float hy = microdetail.sample(detailSampler, detailUV + float2(0.0, step)).a;
                        float2 dh = float2(hx - relief, hy - relief) * (0.012 / (step * repeatSize)) * u.materialFrame.z;
                        slope = float3(dh, 0.0);
                        slope -= surfaceNormal * dot(slope, surfaceNormal);
                    }
                    slope *= min(1.0, 0.45 / max(length(slope), 1e-6));
                    // Bounded tilt avoids projection-seam spikes; geometric shadow normals stay intact.
                    float3 reliefNormal = normalize(surfaceNormal - slope * 0.65);
                    detailNormal = normalize(mix(surfaceNormal, reliefNormal, reliefWeight));
                }
                albedo *= 1.0 + relief * (foliage ? 0.018 : (grassSurface ? 0.025 : 0.012)) * reliefWeight;
            }
        }

        if (tex > 6.5 && tex < 7.5 && abs(n.z) > 0.7) {
            // Square 40 cm maroon quarry tiles laid in a straight grid (no running bond).
            float2 bond = wp / float2(0.40, 0.40);
            float2 cell = fract(bond);
            float2 footprint = max(fwidth(bond), float2(0.0001));
            float2 edge = min(cell, 1.0 - cell);
            float2 interior = smoothstep(float2(0.018), float2(0.018) + footprint, edge);
            float resolved = 1.0 - smoothstep(0.15, 0.65, max(footprint.x, footprint.y));
            float joint = (1.0 - interior.x * interior.y) * resolved;
            float variation = (dioramaHash(floor(bond)) - 0.5) * 0.10 * resolved;
            albedo *= 1.0 + variation;
            albedo = mix(albedo, float3(0.80, 0.74, 0.66), joint * 0.6);
        }

        if (roofSurface) {
            float2 tangent = normalize(float2(-surfaceNormal.y, surfaceNormal.x) + float2(0.0001, 0.0));
            float2 roofUV = float2(dot(vegetationPosition, tangent), dot(vegetationPosition, float2(-tangent.y, tangent.x)));
            float weather = dioramaNoise(roofUV * 0.12 + float2(3.1, 9.2));
            bool clay = albedo.r > albedo.g * 1.25 && albedo.r > albedo.b * 1.35;
            float2 bond = roofUV / float2(clay ? 0.36 : 0.24, 0.42);
            float2 cell = fract(bond + float2(floor(bond.y) * (clay ? 0.5 : 0.0), 0.0));
            float2 footprint = max(fwidth(bond), float2(0.0001));
            float resolved = 1.0 - smoothstep(0.20, 0.70, max(footprint.x, footprint.y));
            float2 joint = 1.0 - smoothstep(float2(0.015), float2(0.015) + footprint, min(cell, 1.0 - cell));
            bool concreteRoof = albedo.r >= albedo.g && albedo.g >= albedo.b
                && albedo.r - albedo.b < 0.12 && dot(albedo, float3(0.2126, 0.7152, 0.0722)) > 0.62;
            float course = concreteRoof ? 0.0 : (clay ? max(joint.x, joint.y) : (sin(bond.x * 6.2831853) * 0.5 + 0.5));
            albedo *= 0.89 + 0.18 * weather;
            albedo *= 1.0 - course * resolved * (clay ? 0.15 : 0.055);
        }
        if (plasterSurface) {
            float2 tangent = normalize(float2(-surfaceNormal.y, surfaceNormal.x) + float2(0.0001, 0.0));
            float2 wallUV = float2(dot(vegetationPosition, tangent), surfacePosition.z);
            float weather = dioramaNoise(wallUV * float2(0.16, 0.34));
            float h = in.appearance.z > 50.0 ? max(0.0, in.appearance.z - 100.0) : 9.0;
            float foot = (1.0 - smoothstep(0.0, 1.4, h)) * (0.04 + 0.07 * weather);
            albedo *= 0.97 + 0.06 * weather - foot;
        }

        // Fish are pigment in the arched plaster, not raised discs/triangles casting tiny shadows.
        // Analytic coverage antialiases their outlines and fades detail below a pixel.
        if (tex > 7.5 && tex < 8.5 && abs(n.z) < 0.92) {
            float2 tangent = normalize(float2(-n.y, n.x));
            float2 mural = float2(dot(wp, tangent), in.worldPosition.z) / float2(1.55, 0.86);
            mural.x += floor(mural.y) * 0.43;
            float2 cell = floor(mural);
            float2 p = fract(mural) - 0.5;
            if (fmod(abs(cell.x + cell.y), 2.0) > 0.5) p.x = -p.x;
            float seed = dioramaHash(cell);
            float body = length(p / float2(0.32, 0.27)) - 1.0;
            float tail = max(abs(p.y) - (-p.x - 0.22) * 1.4, max(p.x + 0.22, -0.47 - p.x));
            float edge = max(fwidth(body), 0.02);
            float mask = 1.0 - smoothstep(-edge, edge, min(body, tail * 4.0));
            float stripe = smoothstep(-0.2, 0.2, sin((p.x + 0.08 * sin(p.y * 9.0)) * 37.0));
            float3 ochre = float3(0.85, 0.64, 0.27);
            float3 pale = float3(0.97, 0.94, 0.84);
            float3 paint = mix(ochre, pale, step(0.5, seed));
            paint = mix(float3(0.10, 0.18, 0.23), paint, stripe);
            float eye = 1.0 - smoothstep(0.022, 0.022 + fwidth(p.x), length(p - float2(0.22, 0.065)));
            paint = mix(paint, float3(0.03), eye);
            float detail = 1.0 - smoothstep(0.2, 0.8, max(fwidth(mural.x), fwidth(mural.y)));
            albedo = mix(albedo, paint, mask * detail);
        }

        // Apply analytic lane paint after natural recolouring/detail so boundary coverages cannot
        // tint its white/yellow pigment. Nearest asphalt ownership still excludes coast and paving.
        if (paintedGround && tex > 2.5 && tex < 3.5) {
            int2 cell = clamp(int2((wp - u.groundImage.xy) * u.groundImage.zw * 64.0), int2(0), int2(63));
            uint2 entry = paintTable[cell.y * 64 + cell.x];
            float aa = max(0.003, min(0.5, length(fwidth(wp)) * 0.65));
            float white = 0.0, yellow = 0.0;
            float3 whiteColor = float3(0.98, 0.96, 0.92), yellowColor = float3(0.96, 0.77, 0.19);
            for (uint k = 0; k < entry.y; k++) {
                DioramaPaintTriangle t = paint[paintIndices[entry.x + k]];
                float3 p = float3(wp, 1.0);
                float distance = min(dot(t.edge0.xyz, p), min(dot(t.edge1.xyz, p), dot(t.edge2.xyz, p)));
                float coverage = smoothstep(-aa, aa, distance);
                if (t.color.b < 0.5) { yellow += coverage; yellowColor = t.color.rgb; }
                else { white += coverage; whiteColor = t.color.rgb; }
            }
            albedo = mix(albedo, whiteColor, saturate(white));
            albedo = mix(albedo, yellowColor, saturate(yellow));
        }

        // Shadows and lighting always use the original scene, including in the reflection pass.
        float3 litPos = surfacePosition;
        float3 litN = surfaceNormal;
        float hemi = litN.z * 0.5 + 0.5;
        float3 ambient = mix(u.groundColor.rgb, u.skyColor.rgb, hemi);
        // Screen-space contact shadow wherever surfaces meet: walls and ground, trees and grass.
        float ao = 1.0;
        if (u.post.x > 0.001 && !mirrored) {
            constexpr sampler aoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
            float2 suv = in.position.xy / u.water.zw;
            ao = 1.0 - u.post.x * revealCoverage * (1.0 - occlusion.sample(aoSampler, suv).r);
        }
        float ndl = dot(detailNormal, u.sunDirection.xyz);
        float wrap = foliage && u.params.z < 0.5 ? 0.18 : 0.0;
        float sun = saturate((ndl + wrap) / (1.0 + wrap));
        float visibility = dioramaShadow(litPos, litN, u, shadowMap);
        float ambientStrength = u.params.z < 0.5 ? 0.62 : 0.78;
        float3 light = ambient * ambientStrength * ao + u.sunColor.rgb * sun * visibility * (0.75 + 0.25 * ao);
        float3 pointLight = glow > 0.01 ? dioramaPointLights(litPos, litN, u, lights, lightTable, lightIndices) : float3(0.0);
        light += pointLight * glow * (0.6 + 0.4 * ao);

        float3 color = albedo * light;
        float time = u.params.y;

        if (tex > 4.5 && tex < 5.5) {
            // Pool water: bright turquoise with slow caustic shimmer and a soft sky sheen.
            float2 poolPosition = vegetationPosition;
            float caustic = dioramaWaterCaustic(poolPosition, time);
            float3 poolNormal = normalize(float3(-dioramaWaterSlope(poolPosition, time) * 0.55, 1.0));
            float fresnel = 0.08 + 0.32 * pow(1.0 - saturate(dot(poolNormal, view)), 4.0);
            color = albedo * light * (0.88 + 0.22 * caustic);
            color += u.sunColor.rgb * caustic * 0.12;
            color = mix(color, u.skyColor.rgb * 0.85, fresnel);
            color += u.sunColor.rgb * pow(saturate(dot(poolNormal, normalize(view + u.sunDirection.xyz))), 64.0) * 0.22;
            return dioramaRevealColor(color, 1.0, revealAlpha, u);
        }

        if (code > 0.5 && code < 1.5) {
            // Distance is baked against the stitched real shoreline, never tile clipping edges.
            float shore = max(0.0, in.appearance.z);
            float shallow = 1.0 - smoothstep(0.0, max(1.0, u.shoreline.x), shore);
            float3 body = mix(u.waterDeep.rgb, u.waterShallow.rgb, shallow);
            float2 waterPosition = vegetationPosition;
            float depthMottle = dioramaWaterField(waterPosition * 0.032 + float2(17.4, -8.2), 0.0);
            body *= 0.78 + 0.34 * smoothstep(0.20, 0.78, depthMottle);

            // Positive phase time advances crests towards smaller mapped shore distances. Restrict
            // this field to the coast: archived offshore distances are capped, not a wave coordinate.
            float coastal = 1.0 - smoothstep(5.0, 16.0, shore);
            float along = sin(dot(waterPosition, float2(0.041, -0.029))) * 0.42;
            float phase = shore * 0.78 + time * 1.10 + along;
            float resolvedShore = 1.0 - smoothstep(0.7, 2.5, fwidth(phase));
            float swell = (sin(phase) * 0.5 + 0.5) * resolvedShore;
            float chop = dioramaWaterField(waterPosition * 0.23, time);
            body *= 0.94 + 0.20 * (chop - 0.5) + 0.14 * swell * coastal;
            float2 slope = dioramaWaterSlope(waterPosition, time);
            float3 waveNormal = normalize(float3(-slope, 1.0));
            float glint = pow(saturate(dot(waveNormal, normalize(view + u.sunDirection.xyz))), 48.0);

            // A widening/receding wash and travelling broken crest, not a fixed white outline.
            float lace = dioramaWaterField(waterPosition * 0.62, time * 0.45);
            float breath = sin(time * 1.10 + along) * 0.5 + 0.5;
            float washWidth = max(0.3, u.shoreline.y) * (0.55 + 2.4 * breath);
            float shoreAA = max(0.12, min(1.0, fwidth(shore)));
            float contact = (1.0 - smoothstep(washWidth - shoreAA, washWidth + shoreAA, shore))
                * smoothstep(0.12, 0.80, breath);
            float breaker = smoothstep(0.70, 0.98, swell) * (1.0 - smoothstep(0.8, 9.0, shore));
            float foam = (contact * 0.52 + breaker * 0.42) * smoothstep(0.26, 0.74, lace) * (1.0 - u.shoreline.z);
            float caustic = dioramaWaterCaustic(waterPosition, time) * shallow * (1.0 - u.shoreline.z);
            color = body * (ambient * 0.35 + float3(u.params.z < 0.5 ? 0.58 : 0.18) + u.sunColor.rgb * 0.32);
            color += u.sunColor.rgb * caustic * 0.11;
            color *= 1.0 + dot(slope, float2(0.65, -0.45)) * 0.45;
            color = mix(color, float3(0.78, 0.87, 0.83), foam);
            float fresnelSky = 0.05 + 0.28 * pow(1.0 - saturate(dot(waveNormal, view)), 4.0);
            color = mix(color, u.skyColor.rgb * 0.80, fresnelSky);
            color += pointLight * glow * 0.15 + u.sunColor.rgb * glint * 0.32;
            if (u.water.y > 0.5 && u.shoreline.z < 0.5) {
                constexpr sampler mirrorSampler(coord::normalized, address::clamp_to_edge, filter::linear);
                float2 uv = in.position.xy / u.water.zw + slope * 0.009;
                float2 texel = 1.0 / float2(reflection.get_width(), reflection.get_height());
                float4 reflected = reflection.sample(mirrorSampler, uv) * 0.4;
                reflected += reflection.sample(mirrorSampler, uv + texel * float2(1.5, 0.5)) * 0.15;
                reflected += reflection.sample(mirrorSampler, uv - texel * float2(1.5, 0.5)) * 0.15;
                reflected += reflection.sample(mirrorSampler, uv + texel * float2(0.5, 1.5)) * 0.15;
                reflected += reflection.sample(mirrorSampler, uv - texel * float2(0.5, 1.5)) * 0.15;
                float fresnel = 0.20 + 0.48 * pow(1.0 - saturate(dot(waveNormal, view)), 3.0);
                float edgeFade = smoothstep(0.0, 0.025, min(min(uv.x, uv.y), min(1.0 - uv.x, 1.0 - uv.y)));
                color = mix(color, reflected.rgb / max(reflected.a, 0.001), fresnel * reflected.a * edgeFade * (1.0 - foam));
            }
            // Shallow water still reveals submerged sand and coral beneath the reflection.
            return dioramaRevealColor(color, mix(mix(1.0, 0.48, shallow), 0.94, foam), revealAlpha, u);
        }

        if (tex > 5.5 && tex < 6.5 && in.appearance.y < 8.5) {
            // Glass has a quiet sky reflection, unlike matte plaster; never a white plastic highlight.
            float fresnel = 0.08 + 0.32 * pow(1.0 - saturate(dot(n, view)), 4.0);
            color = mix(color, u.skyColor.rgb * 0.8, fresnel);
        }
        if (roofSurface || roadSurface) {
            float3 halfway = normalize(view + u.sunDirection.xyz);
            float specular = pow(saturate(dot(detailNormal, halfway)), roofSurface ? 28.0 : 12.0);
            color += u.sunColor.rgb * specular * visibility * (roofSurface ? 0.065 : 0.022);
        }
        if (tex > 13.5 && tex < 14.5) {
            float3 halfway = normalize(view + u.sunDirection.xyz);
            float rough = clamp(in.appearance.z, 0.08, 0.9);
            float gloss = pow(saturate(dot(n, halfway)), mix(96.0, 12.0, rough));
            color += u.sunColor.rgb * gloss * visibility * (1.0 - rough) * 0.25;
        }
        float rim = pow(1.0 - saturate(dot(n, view)), 4.0) * 0.035;
        color += u.skyColor.rgb * rim;
        return dioramaRevealColor(dioramaGrade(color, in.worldPosition, u), 1.0, revealAlpha, u);
    }
    """

    /// Shared colour grade: a unifying warm-violet tint plus light distance haze towards the sky colour.
    static let gradeSource: String = """
    float3 dioramaGrade(float3 color, float3 worldPosition, constant DioramaUniforms &u) {
        float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
        color = max(float3(0.0), mix(float3(luminance), color, 1.10));
        float3 graded = color * float3(1.025, 1.0, 0.985);
        color = mix(color, graded, u.post.z);
        float d = length(u.eye.xyz - worldPosition);
        float haze = 1.0 - exp(-d * u.post.w);
        float3 hazeColor = mix(u.skyColor.rgb, float3(0.76, 0.80, 0.84), 0.18);
        return mix(color, hazeColor, haze * 0.65);
    }
    """

    /// Screen-space passes: half-resolution G-buffer, ambient occlusion with blur, bloom pyramid
    /// and the additive bloom composite drawn into Mapbox's own pass.
    static let postSource: String = """
    struct DioramaGBuffer {
        float4 position [[color(0)]];
        float4 normal [[color(1)]];
        float4 emissive [[color(2)]];
    };

    fragment DioramaGBuffer dioramaGBufferFragment(DioramaVarying in [[stage_in]], bool isFront [[front_facing]], constant DioramaUniforms &u [[buffer(0)]]) {
        dioramaRevealClip(in.worldPosition, u);
        DioramaGBuffer out;
        float3 n = normalize(in.normal);
        if (!isFront) n = -n;
        out.position = float4(in.worldPosition, dioramaRevealCoverage(in.worldPosition, u));
        out.normal = float4(n, 0.0);
        out.emissive = float4(0.0);
        return out;
    }

    fragment DioramaGBuffer dioramaEmissiveFragment(DioramaVarying in [[stage_in]], constant DioramaUniforms &u [[buffer(0)]]) {
        DioramaGBuffer out;
        dioramaRevealClip(in.worldPosition, u);
        float code = in.appearance.w;
        float glow = u.params.x;
        float3 c = in.color.rgb;
        float a = 1.0;
        if (code > 4.5 && code < 5.5) {
            float r = length(in.normal.xy);
            if (r > 1.0) discard_fragment();
            a = pow(1.0 - r, 2.2) * 0.9;
            c *= 1.2;
        }
        out.position = float4(0.0);
        out.normal = float4(0.0);
        // Preserve HDR radiance before the blur: display-range colors disappear when downsampled.
        out.emissive = float4(c * glow * a * 3.0 * dioramaRevealCoverage(in.worldPosition, u), 1.0);
        return out;
    }

    struct DioramaScreen {
        float4 position [[position]];
        float2 uv;
    };

    vertex DioramaScreen dioramaFullscreenVertex(uint id [[vertex_id]]) {
        DioramaScreen out;
        float2 p = float2((id == 1) ? 3.0 : -1.0, (id == 2) ? 3.0 : -1.0);
        out.position = float4(p, 0.0, 1.0);
        out.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
        return out;
    }

    float dioramaScreenHash(float2 p) {
        return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
    }

    /// Hemisphere occlusion in world space against the G-buffer positions. Range-checked so distant
    /// occluders do not darken, and dithered per pixel so the blur resolves it smoothly.
    fragment float4 dioramaSSAOFragment(DioramaScreen in [[stage_in]],
                                        constant DioramaPostUniforms &p [[buffer(0)]],
                                        texture2d<float> positions [[texture(0)]],
                                        texture2d<float> normals [[texture(1)]]) {
        constexpr sampler point(coord::normalized, address::clamp_to_edge, filter::nearest);
        float4 P = positions.sample(point, in.uv);
        if (P.w < 0.001) return float4(1.0);
        float3 N = normalize(normals.sample(point, in.uv).xyz);
        float3 eye = p.eye.xyz;
        float radius = p.params.x;
        float3 helper = abs(N.z) < 0.9 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
        float3 t = normalize(cross(N, helper));
        float3 b = cross(N, t);
        float noise = dioramaScreenHash(in.position.xy) * 6.2831853;
        const int K = 12;
        float occlusion = 0.0;
        float weight = 0.0;
        for (int k = 0; k < K; k++) {
            float angle = float(k) * 2.39996 + noise;
            float r = radius * sqrt((float(k) + 0.5) / float(K));
            float lift = radius * (0.15 + 0.55 * fract(float(k) * 0.618 + noise * 0.1));
            float3 S = P.xyz + (t * cos(angle) + b * sin(angle)) * r + N * lift;
            float4 clip = p.matrix * float4(S, 1.0);
            if (clip.w <= 0.0001) continue;
            float2 ndc = clip.xy / clip.w;
            float2 suv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
            if (any(suv < float2(0.0)) || any(suv > float2(1.0))) continue;
            float4 Q = positions.sample(point, suv);
            weight += 1.0;
            if (Q.w < 0.001) continue;
            float sampleDist = length(eye - S);
            float sceneDist = length(eye - Q.xyz);
            float delta = sampleDist - sceneDist;
            if (delta > 0.04) {
                float range = smoothstep(0.0, 1.0, radius / max(delta, 0.0001));
                occlusion += range * Q.w;
            }
        }
        float ao = weight > 0.0 ? 1.0 - occlusion / weight : 1.0;
        return float4(ao, ao, ao, 1.0);
    }

    /// Separable 9-tap gaussian along `blur.xy` texels.
    fragment float4 dioramaBlurFragment(DioramaScreen in [[stage_in]],
                                        constant DioramaPostUniforms &p [[buffer(0)]],
                                        texture2d<float> source [[texture(0)]]) {
        constexpr sampler linear(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 texel = p.blur.xy / p.params.zw;
        const float w[5] = {0.2270270, 0.1945946, 0.1216216, 0.0540541, 0.0162162};
        float4 sum = source.sample(linear, in.uv) * w[0];
        for (int i = 1; i < 5; i++) {
            float2 o = texel * float(i);
            sum += source.sample(linear, in.uv + o) * w[i];
            sum += source.sample(linear, in.uv - o) * w[i];
        }
        return sum;
    }

    /// Bilinear downsample (the sampler does the 2x2 box).
    fragment float4 dioramaCopyFragment(DioramaScreen in [[stage_in]], texture2d<float> source [[texture(0)]]) {
        constexpr sampler linear(coord::normalized, address::clamp_to_edge, filter::linear);
        return source.sample(linear, in.uv);
    }

    /// Additive bloom over Mapbox's frame: glow bleeds into the sky and basemap around each lamp.
    fragment float4 dioramaBloomComposite(DioramaScreen in [[stage_in]],
                                          constant DioramaPostUniforms &p [[buffer(0)]],
                                          texture2d<float> bloom [[texture(0)]]) {
        constexpr sampler linear(coord::normalized, address::clamp_to_edge, filter::linear);
        float3 c = bloom.sample(linear, in.uv).rgb * p.blur.z;
        return float4(c, 1.0);
    }
    """

    /// Everything compiled into the diorama library: main shaders (which forward-declare the grade
    /// helper), the grade helper, then the screen-space passes.
    static var fullSource: String { source + gradeSource + postSource }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (device: ObjectIdentifier, library: MTLLibrary)?

    static func library(for device: MTLDevice) -> MTLLibrary? {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(device)
        if let cached, cached.device == key { return cached.library }
        do {
            let library = try device.makeLibrary(source: fullSource, options: nil)
            cached = (key, library)
            return library
        } catch {
            print("[Diorama] shader compile failed: \(error.localizedDescription)")
            return nil
        }
    }
}
