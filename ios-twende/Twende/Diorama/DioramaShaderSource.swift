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
    /// x: ambient-occlusion strength (0 disables sampling), y: bloom strength, z: grade strength,
    /// w: haze density per metre.
    var post: SIMD4<Float>
    /// xy: reveal centre, z: square half-extent in metres, w: active flag.
    var reveal: SIMD4<Float>
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
            sun = simd_normalize(SIMD3<Float>(-0.64, -0.48, 0.60))
            sunColor = SIMD3<Float>(1.0, 0.985, 0.86) * 0.80
            sky = SIMD3<Float>(0.86, 0.87, 0.72)
            ground = SIMD3<Float>(0.55, 0.56, 0.34)
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
            post: .zero,
            reveal: .zero
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
        float4 post;
        float4 reveal;
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

    float dioramaRevealDistance(float3 p, constant DioramaUniforms &u) {
        if (u.reveal.w > 2.5) return u.reveal.z - dot(p.xy, u.reveal.xy);
        if (u.reveal.w > 1.5) return dot(p.xy, u.reveal.xy) - u.reveal.z;
        float2 delta = abs(p.xy - u.reveal.xy);
        return max(delta.x, delta.y) - u.reveal.z;
    }
    void dioramaRevealClip(float3 p, constant DioramaUniforms &u) {
        if (u.shoreline.w > 0.5) {
            float2 uv = (p.xy - u.groundImage.xy) * u.groundImage.zw;
            if (any(uv < float2(0.0)) || any(uv >= float2(1.0))) discard_fragment();
        }
        if (u.reveal.w > 0.5 && dioramaRevealDistance(p, u) > 0.0) discard_fragment();
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
            float3 right = normalize(cross(float3(0.0, 0.0, 1.0), toEye));
            if (length(right) < 0.001) right = float3(1.0, 0.0, 0.0);
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
        return out;
    }

    vertex DioramaVarying dioramaVertex(uint id [[vertex_id]],
                                        const device DioramaInput *vertices [[buffer(0)]],
                                        constant float4x4 &matrix [[buffer(1)]],
                                        constant DioramaUniforms &u [[buffer(2)]]) {
        DioramaInput v = vertices[id];
        return dioramaShade(v, v.position.xyz, v.normal.xyz, matrix, u);
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
        return dioramaShade(v, dioramaPlace(v.position.xyz, inst), dioramaPlaceNormal(v.normal.xyz, inst), matrix, u);
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
            if (u.reveal.w > 0.5 && dioramaRevealDistance(l.position.xyz, u) > 0.0) continue;
            float3 d = l.position.xyz - p;
            float dist2 = dot(d, d);
            float radius = l.position.w;
            if (dist2 > radius * radius) continue;
            float dist = sqrt(dist2);
            float3 L = d / max(dist, 0.01);
            float att = 1.0 - dist / radius;
            att = att * att * (1.0 / (1.0 + dist2 * 0.06));
            float wrap = saturate(dot(n, L) * 0.75 + 0.25);
            sum += l.color.rgb * (l.color.w * att * wrap * 3.2);
        }
        return sum;
    }

    struct DioramaPaintTriangle { float4 edge0; float4 edge1; float4 edge2; float4 color; };

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
        dioramaRevealClip(in.worldPosition, u);
        float code = in.appearance.w;
        float glow = u.params.x;
        bool mirrored = u.params.w > 0.5;

        if (mirrored && (in.clipHeight < -0.05 || (code > 0.5 && code < 1.5))) discard_fragment();
        if (u.reveal.w > 0.5 && !(code > 4.5 && code < 5.5)) {
            float edge = -dioramaRevealDistance(in.worldPosition, u);
            if (edge < 1.4) {
                float heat = 1.0 - smoothstep(0.0, 1.4, edge);
                return float4(mix(in.color.rgb * 0.55, float3(1.0, 0.84, 0.52), heat), 1.0);
            }
        }
        // Reflection pass: only what is above the water surface reflects; never the water itself.
        if (mirrored) {
            if (in.clipHeight < -0.05) discard_fragment();
            if (code > 0.5 && code < 1.5) discard_fragment();
        }

        if (code > 4.5 && code < 5.5) {
            float r = length(in.normal.xy);
            if (r > 1.0) discard_fragment();
            float a = pow(1.0 - r, 2.2) * 0.7 + pow(max(0.0, 1.0 - r * 3.0), 2.0) * 0.5;
            return float4(in.color.rgb * glow, a * min(glow, 1.0));
        }
        if (code > 5.5) { return float4(in.color.rgb, 1.0); }
        if (code > 3.5) {
            float3 c = in.color.rgb * (0.55 + 0.8 * glow) + float3(0.12, 0.05, 0.0) * glow;
            return float4(min(c, float3(1.0)), 1.0);
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
        float2 wp = surfacePosition.xy;
        if (tex > 8.5 && tex < 9.5) {
            // Painted ground: albedo from the tile image, grain code from its alpha (×32).
            constexpr sampler groundSampler(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear, max_anisotropy(8));
            constexpr sampler materialSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
            float2 guv = (wp - u.groundImage.xy) * u.groundImage.zw;
            guv.y = 1.0 - guv.y;
            float4 painted = groundImage.sample(groundSampler, guv);
            albedo = painted.rgb;
            // Codes are categorical: interpolating white paint (0) into asphalt (3) invents
            // grass (1), incorrectly applying coastal pigment inside road markings.
            tex = floor(groundImage.sample(materialSampler, guv, level(0.0)).a * 255.0 / 32.0 + 0.5);
            // Resolution-independent lane paint, spatially indexed into 64×64 cells.
            // Only asphalt receives it: later water/natural paint still owns the coastline.
            if (tex > 2.5 && tex < 3.5) {
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
            if (tex > 0.5 && tex < 1.5) {
                // Natural coast pigment is interpolated on the same mesh as the land and seabed.
                // Hard finishes retain their painted color and never become a second surface.
                albedo = mix(albedo, in.color.rgb, saturate(in.appearance.z));
            }
        }
        if (tex > 0.5 && tex < 1.5) {
            // Regrade existing painted downloads without replacing their material boundaries.
            float luminance = dot(albedo, float3(0.2126, 0.7152, 0.0722));
            float naturalCoverage = in.appearance.y > 8.5 ? saturate(in.appearance.z) : 0.0;
            float greenMask = smoothstep(0.015, 0.10, albedo.g - max(albedo.r, albedo.b));
            float3 grass = mix(float3(171.0, 197.0, 45.0), float3(181.0, 206.0, 54.0),
                               smoothstep(0.42, 0.72, luminance)) / 255.0;
            albedo = mix(albedo, grass, greenMask * (1.0 - naturalCoverage));
            float mottle = dioramaNoise(wp * 0.09) * 0.7 + dioramaNoise(wp * 0.35) * 0.3;
            albedo *= 0.99 + 0.04 * (mottle - 0.5);
        } else if (tex > 1.5 && tex < 2.5) {
            albedo *= 0.98 + 0.04 * (dioramaNoise(wp * 0.5) - 0.5);
        } else if (tex > 2.5 && tex < 3.5) {
            // Quiet warm-grey asphalt, not the old dark violet. Preserve white/yellow paint and earth.
            float coolAsphalt = smoothstep(-0.015, 0.045, albedo.b - albedo.g)
                * (1.0 - smoothstep(0.60, 0.80, min(albedo.r, min(albedo.g, albedo.b))));
            albedo = mix(albedo, float3(173.0, 163.0, 160.0) / 255.0, coolAsphalt);
            albedo *= 0.99 + 0.025 * (dioramaNoise(wp * 0.4) - 0.5);
        } else if (tex > 3.5 && tex < 4.5) {
            albedo *= 0.98 + 0.04 * (dioramaNoise(wp * 0.6) - 0.5);
        } else if (tex > 5.5 && tex < 6.5 && in.appearance.y > 8.5) {
            // Inland compacted earth: quiet ochre/brown clods, distinct from fine coastal sand.
            float clods = dioramaNoise(wp * 1.7) * 0.65 + dioramaNoise(wp * 0.18) * 0.35;
            albedo *= 0.96 + 0.10 * (clods - 0.5);
        }

        if (tex > 9.5 && tex < 10.5) {
            // Same chartreuse ramp for tagged legacy foliage and current prototypes. Flowers/trunks
            // never enter this material. Keep source palette bytes stable for exact roof replay.
            float luminance = dot(albedo, float3(0.2126, 0.7152, 0.0722));
            float tone = smoothstep(0.22, 0.74, luminance);
            float3 shade = float3(145.0, 170.0, 39.0) / 255.0;
            float3 middle = float3(174.0, 198.0, 49.0) / 255.0;
            float3 crown = float3(202.0, 220.0, 77.0) / 255.0;
            albedo = tone < 0.60 ? mix(shade, middle, tone / 0.60)
                                 : mix(middle, crown, (tone - 0.60) / 0.40);
        }

        // Legacy saved wall vertices already carry height grading; texture them without a rebuild.
        if (tex < 0.5 && in.appearance.z > 100.0 && abs(n.z) < 0.25) tex = 12.0;
        // One mipmapped sample: CC0 luminance in RG, original miniature leaf relief/pigment in BA.
        // Surface-gradient shading adds relief without displacement or additional geometry/passes.
        bool foliage = tex > 9.5 && tex < 10.5;
        bool grassSurface = tex > 0.5 && tex < 1.5;
        bool textured = (tex > 0.5 && tex < 4.5) || (tex > 9.5 && tex < 13.5);
        if (textured && u.shoreline.z < 0.5 && u.groundColor.w > 0.5) {
            float repeatSize = grassSurface ? 3.2 : (foliage ? 1.6 : 1.4);
            float2 detailUV = wp / repeatSize;
            if (foliage) {
                float3 axis = abs(surfaceNormal);
                if (axis.z < max(axis.x, axis.y)) {
                    detailUV = (axis.x > axis.y ? surfacePosition.yz : surfacePosition.xz) / repeatSize;
                }
            } else if (tex > 11.5) {
                float2 tangent = normalize(float2(-surfaceNormal.y, surfaceNormal.x) + float2(0.0001, 0.0));
                detailUV = float2(dot(wp, tangent), surfacePosition.z) / repeatSize;
            }
            float resolved = 1.0 - smoothstep(0.04, 0.16, max(length(dfdx(detailUV)), length(dfdy(detailUV))));
            constexpr sampler detailSampler(coord::normalized, address::repeat, filter::linear, mip_filter::linear);
            float4 grain = microdetail.sample(detailSampler, detailUV);
            float value = (grassSurface || foliage) ? grain.r : grain.g;
            float strength = grassSurface ? 0.10 : (foliage ? 0.055 : 0.075);
            albedo *= 1.0 + (value - 0.502) * strength * resolved;
            if (grassSurface || foliage) {
                float naturalCoverage = grassSurface && in.appearance.y > 8.5 ? saturate(in.appearance.z) : 0.0;
                float reliefWeight = resolved * (1.0 - naturalCoverage);
                float height = grain.b * (foliage ? 0.009 : 0.016);
                float3 dx = dfdx(surfacePosition), dy = dfdy(surfacePosition);
                float3 rx = cross(dy, surfaceNormal), ry = cross(surfaceNormal, dx);
                float determinant = dot(dx, rx);
                float3 gradient = (rx * dfdx(height) + ry * dfdy(height)) * sign(determinant);
                if (abs(determinant) > 1e-8) {
                    float3 slope = gradient / abs(determinant);
                    slope *= min(1.0, 0.45 / max(length(slope), 1e-6));
                    // Bounded tilt avoids projection-seam spikes; geometric shadow normals stay intact.
                    float3 reliefNormal = normalize(surfaceNormal - slope * 0.65);
                    detailNormal = normalize(mix(surfaceNormal, reliefNormal, reliefWeight));
                }
                albedo *= 1.0 + (grain.a - 0.502) * 0.24 * reliefWeight;
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
            ao = 1.0 - u.post.x * (1.0 - occlusion.sample(aoSampler, suv).r);
        }
        float ndl = dot(detailNormal, u.sunDirection.xyz);
        float sun = max(ndl, 0.0);
        float visibility = dioramaShadow(litPos, litN, u, shadowMap);
        float ambientStrength = u.params.z < 0.5 ? 0.50 : 0.78;
        float3 light = ambient * ambientStrength * ao + u.sunColor.rgb * sun * visibility * (0.75 + 0.25 * ao);
        float3 pointLight = glow > 0.01 ? dioramaPointLights(litPos, litN, u, lights, lightTable, lightIndices) : float3(0.0);
        light += pointLight * glow * (0.6 + 0.4 * ao);

        float3 color = albedo * light;
        float time = u.params.y;

        if (tex > 4.5 && tex < 5.5) {
            // Pool water: bright turquoise with slow caustic shimmer and a soft sky sheen.
            float c1 = dioramaNoise(wp * 1.6 + float2(time * 0.25, time * 0.18));
            float c2 = dioramaNoise(wp * 2.9 - float2(time * 0.2, -time * 0.14));
            float caustic = smoothstep(0.45, 0.8, c1 * 0.55 + c2 * 0.45);
            color = albedo * light * (0.92 + 0.18 * caustic) + float3(0.10, 0.12, 0.12) * caustic;
            color = mix(color, u.skyColor.rgb * 1.1, 0.12);
            return float4(color, 1.0);
        }

        if (code > 0.5 && code < 1.5) {
            // Distance is baked against the stitched real shoreline, never tile clipping edges.
            float shore = max(0.0, in.appearance.z);
            float shallow = 1.0 - smoothstep(0.0, max(1.0, u.shoreline.x), shore);
            float3 body = mix(u.waterDeep.rgb, u.waterShallow.rgb, shallow);

            // Swells: bands of brightness keyed to the distance from shore, so they always run parallel
            // to the beach, plus a soft 2D choppiness that drifts across the bay.
            // Gentle current: a slow drift of the whole pattern plus quiet swells towards the shore.
            float2 flow = float2(time * 0.18, time * 0.07);
            float phase = shore * 0.55 - time * 0.6 + dioramaNoise((wp + flow) * 0.05) * 2.5;
            float swell = sin(phase) * 0.5 + 0.5;
            swell = pow(swell, 3.0);
            float chop = dioramaNoise((wp + flow) * 0.22) * 0.6
                       + dioramaNoise((wp + flow * 1.6) * 0.6) * 0.4;
            float nearShoreWeight = 0.35 + 0.65 * shallow;
            body *= 0.92 + 0.14 * (chop - 0.5) + 0.15 * swell * nearShoreWeight;
            float2 ripplePhase = float2(dot(wp, float2(0.65, 0.32)) - time * 0.85,
                                       dot(wp, float2(-0.28, 0.72)) - time * 0.6);
            float2 slope = float2(cos(ripplePhase.x) * 0.12 - cos(ripplePhase.y) * 0.055,
                                 cos(ripplePhase.x) * 0.06 + cos(ripplePhase.y) * 0.14);
            float3 waveNormal = normalize(float3(-slope, 1.0));
            float glint = pow(saturate(dot(waveNormal, normalize(view + u.sunDirection.xyz))), 48.0);

            // Broken, transient foam patches, not the former continuous near-white perimeter stroke.
            float lace = dioramaNoise(wp * 0.8 + float2(time * 0.12, -time * 0.09));
            float breath = smoothstep(0.78, 0.98, sin(time * 0.65 + wp.x * 0.16 + wp.y * 0.11) * 0.5 + 0.5);
            float foamWidth = max(0.05, u.shoreline.y);
            float contact = exp(-pow(shore / foamWidth, 2.0));
            float foam = contact * smoothstep(0.62, 0.84, lace) * breath * 0.14 * (1.0 - u.shoreline.z);
            color = body * (ambient * 0.35 + float3(0.72) + u.sunColor.rgb * 0.22);
            color = mix(color, float3(0.78, 0.87, 0.83), foam);
            color += pointLight * glow * 0.15 + u.sunColor.rgb * glint * 0.22;
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
            return float4(color, mix(1.0, 0.48, shallow));
        }

        if (tex > 5.5 && tex < 6.5 && in.appearance.y < 8.5) {
            // Glass has a quiet sky reflection, unlike matte plaster; never a white plastic highlight.
            float fresnel = 0.08 + 0.32 * pow(1.0 - saturate(dot(n, view)), 4.0);
            color = mix(color, u.skyColor.rgb * 0.8, fresnel);
        }
        float rim = pow(1.0 - saturate(dot(n, view)), 4.0) * 0.035;
        color += u.skyColor.rgb * rim;
        return float4(dioramaGrade(color, in.worldPosition, u), 1.0);
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
        out.position = float4(in.worldPosition, 1.0);
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
        out.emissive = float4(c * glow * a * 3.0, 1.0);
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
        if (P.w < 0.5) return float4(1.0);
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
            if (Q.w < 0.5) continue;
            float sampleDist = length(eye - S);
            float sceneDist = length(eye - Q.xyz);
            float delta = sampleDist - sceneDist;
            if (delta > 0.04) {
                float range = smoothstep(0.0, 1.0, radius / max(delta, 0.0001));
                occlusion += range;
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
