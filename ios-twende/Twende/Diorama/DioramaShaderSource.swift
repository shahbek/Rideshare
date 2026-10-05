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
    /// x: shadow enabled, y: texel size, z: depth bias.
    var shadowParams: SIMD4<Float>
}

/// Lighting presets per time of day: a warm low sun and violet sky at dusk (the default), a cool
/// moonlit night, a plain bright day.
nonisolated enum DioramaLighting {
    static func uniforms(for time: DioramaTimeOfDay, eye: SIMD3<Float>) -> DioramaShaderUniforms {
        let sun: SIMD3<Float>, sunColor: SIMD3<Float>, sky: SIMD3<Float>, ground: SIMD3<Float>, glow: Float
        switch time {
        case .day:
            sun = simd_normalize(SIMD3<Float>(-0.45, -0.35, 0.82))
            sunColor = SIMD3<Float>(1.0, 0.97, 0.90) * 0.85
            sky = SIMD3<Float>(0.60, 0.66, 0.76)
            ground = SIMD3<Float>(0.44, 0.40, 0.36)
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
            shadowParams: .zero
        )
    }
}

/// Diorama shaders, compiled on-device (no offline Metal toolchain needed). One vertex/fragment pair
/// handles every category through `appearance.w`:
///   0 solid lit surface · 1 water · 4 emissive (lit windows, lanterns) · 5 camera-facing halo sprite.
/// Lighting is a hemisphere sky term, one directional sun and point lights looked up through a 2D grid,
/// so street lamps and lit facades really pool light on the pavement and walls beside them.
/// Water samples a planar-reflection texture rendered in a first pass with the scene mirrored about the
/// water plane, so buildings, lamps and trees reflect in the bay.
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
    };

    struct DioramaLight {
        float4 position;
        float4 color;
    };

    struct DioramaVarying {
        float4 position [[position]];
        float3 worldPosition;
        float3 normal;
        float4 color;
        float4 appearance;
        float clipHeight;
    };

    vertex DioramaVarying dioramaVertex(uint id [[vertex_id]],
                                        const device DioramaInput *vertices [[buffer(0)]],
                                        constant float4x4 &matrix [[buffer(1)]],
                                        constant DioramaUniforms &u [[buffer(2)]]) {
        DioramaInput v = vertices[id];
        DioramaVarying out;
        float3 world = v.position.xyz;
        float3 normal = v.normal.xyz;
        bool mirrored = u.params.w > 0.5;
        float waterZ = u.water.x;
        if (v.appearance.w > 4.5) {
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
        out.position = matrix * float4(world, 1.0);
        out.worldPosition = world;
        out.normal = normal;
        out.color = v.color;
        out.appearance = v.appearance;
        return out;
    }

    vertex float4 dioramaShadowVertex(uint id [[vertex_id]],
                                      const device DioramaInput *vertices [[buffer(0)]],
                                      constant float4x4 &matrix [[buffer(1)]]) {
        return matrix * vertices[id].position;
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
        float visibility = 0.0;
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                float2 offset = float2(x, y) * u.shadowParams.y;
                float receiverDepth = q.z + dot(gradient, offset) - bias - footprintBias;
                visibility += shadowMap.sample_compare(shadowSampler, uv + offset, receiverDepth);
            }
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

    fragment float4 dioramaFragment(DioramaVarying in [[stage_in]],
                                    constant DioramaUniforms &u [[buffer(0)]],
                                    const device DioramaLight *lights [[buffer(1)]],
                                    const device uint2 *lightTable [[buffer(2)]],
                                    const device uint *lightIndices [[buffer(3)]],
                                    texture2d<float> reflection [[texture(0)]],
                                    depth2d<float> shadowMap [[texture(1)]]) {
        float code = in.appearance.w;
        float glow = u.params.x;
        bool mirrored = u.params.w > 0.5;

        // Reflection pass: only what is above the water surface reflects; never the water itself.
        if (mirrored) {
            if (in.clipHeight < -0.05) discard_fragment();
            if (code > 0.5 && code < 1.5) discard_fragment();
        }

        if (code > 4.5) {
            float r = length(in.normal.xy);
            if (r > 1.0) discard_fragment();
            float a = pow(1.0 - r, 2.2) * 0.7 + pow(max(0.0, 1.0 - r * 3.0), 2.0) * 0.5;
            return float4(in.color.rgb * glow, a * min(glow, 1.0));
        }
        if (code > 3.5) {
            float3 c = in.color.rgb * (0.55 + 0.8 * glow) + float3(0.12, 0.05, 0.0) * glow;
            return float4(min(c, float3(1.0)), 1.0);
        }

        float3 n = normalize(in.normal);
        float3 view = normalize(u.eye.xyz - in.worldPosition);
        float3 albedo = in.color.rgb;

        // Procedural ground textures (appearance.y), kept very quiet so the toy-town surfaces read as
        // smooth painted material with only a faint mottle: grass, sand, asphalt, paving.
        float tex = in.appearance.y;
        float2 wp = in.worldPosition.xy;
        if (tex > 0.5 && tex < 1.5) {
            float mottle = dioramaNoise(wp * 0.09) * 0.7 + dioramaNoise(wp * 0.35) * 0.3;
            albedo *= 0.96 + 0.08 * (mottle - 0.5);
        } else if (tex > 1.5 && tex < 2.5) {
            albedo *= 0.98 + 0.04 * (dioramaNoise(wp * 0.5) - 0.5);
        } else if (tex > 2.5 && tex < 3.5) {
            albedo *= 0.98 + 0.04 * (dioramaNoise(wp * 0.4) - 0.5);
        } else if (tex > 3.5 && tex < 4.5) {
            albedo *= 0.98 + 0.04 * (dioramaNoise(wp * 0.6) - 0.5);
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
        float3 litPos = in.worldPosition;
        float3 litN = n;
        if (mirrored) { litPos.z = 2.0 * u.water.x - litPos.z; litN.z = -litN.z; }
        float hemi = litN.z * 0.5 + 0.5;
        float3 ambient = mix(u.groundColor.rgb, u.skyColor.rgb, hemi);
        float ndl = dot(litN, u.sunDirection.xyz);
        float sun = max(ndl, 0.0);
        float visibility = dioramaShadow(litPos, litN, u, shadowMap);
        float3 light = ambient * 0.78 + u.sunColor.rgb * sun * visibility;
        float3 pointLight = glow > 0.01 ? dioramaPointLights(litPos, litN, u, lights, lightTable, lightIndices) : float3(0.0);
        light += pointLight * glow;

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
            // Bay water in the Msasani light: a pale milky turquoise that turns sandy-green in the
            // shallows, with long slow swells rolling towards the beach and foam breaking on the sand.
            // The planar reflection is only a faint sheen so the water stays light.
            float shore = in.appearance.z;
            float shallow = 1.0 - smoothstep(2.0, 42.0, shore);
            float3 deepTint = float3(0.36, 0.68, 0.70);
            float3 shallowTint = float3(0.62, 0.84, 0.78);
            float3 sandTint = float3(0.80, 0.86, 0.74);
            float3 body = mix(deepTint, shallowTint, shallow);
            body = mix(body, sandTint, smoothstep(0.0, 1.0, 1.0 - smoothstep(0.0, 7.0, shore)) * 0.75);

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
            body *= 0.95 + 0.07 * (chop - 0.5) + 0.06 * swell * nearShoreWeight;

            // Foam: a crest line on each swell that grows as the wave reaches the sand, and a lacy
            // permanent fringe on the last couple of metres.
            float crest = smoothstep(0.78, 0.98, sin(phase + 0.3) * 0.5 + 0.5);
            float lace = dioramaNoise(wp * 1.4 + float2(time * 0.35, -time * 0.2));
            float foamBand = crest * (1.0 - smoothstep(4.0, 18.0, shore)) * smoothstep(0.45, 0.8, lace) * 0.18;
            float fringe = (1.0 - smoothstep(0.0, 2.6, shore)) * smoothstep(0.3, 0.6, lace + 0.15 * sin(time * 1.6 + shore * 2.0));
            float foam = saturate(foamBand + fringe * 0.22);

            float2 uv = in.position.xy / u.water.zw;
            float2 ripple = float2(dioramaNoise((wp + flow) * 0.3 + float2(3.1, 7.7)),
                                   dioramaNoise((wp + flow) * 0.3)) - 0.5;
            uv += ripple * 0.006;
            uv = clamp(uv, float2(0.001), float2(0.999));
            constexpr sampler s(address::clamp_to_edge, filter::linear);
            float4 refl = reflection.sample(s, uv);
            float3 skyRef = mix(u.skyColor.rgb, float3(1.0), 0.35);
            float3 reflected = mix(skyRef, refl.rgb, refl.a * 0.92);
            float fresnel = 0.18 + 0.50 * pow(1.0 - saturate(dot(n, view)), 3.0);
            fresnel = max(fresnel, refl.a * 0.42);

            float3 lit = body * (ambient * 0.55 + float3(0.62) + u.sunColor.rgb * 0.30);
            float3 glint = u.sunColor.rgb * pow(saturate(dot(reflect(-view, n), u.sunDirection.xyz)), 90.0) * 0.25 * (0.6 + 0.4 * chop);
            color = mix(lit, reflected, saturate(fresnel * (1.0 - shallow * 0.35))) + glint;
            color = mix(color, float3(0.97, 0.98, 0.96), foam * 0.85);
            color += pointLight * glow * 0.25;
            return float4(color, 1.0);
        }

        if (tex > 5.5 && tex < 6.5) {
            // Glass has a quiet sky reflection, unlike matte plaster; never a white plastic highlight.
            float fresnel = 0.08 + 0.32 * pow(1.0 - saturate(dot(n, view)), 4.0);
            color = mix(color, u.skyColor.rgb * 0.8, fresnel);
        }
        float rim = pow(1.0 - saturate(dot(n, view)), 4.0) * 0.035;
        color += u.skyColor.rgb * rim;
        return float4(color, 1.0);
    }
    """

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (device: ObjectIdentifier, library: MTLLibrary)?

    static func library(for device: MTLDevice) -> MTLLibrary? {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(device)
        if let cached, cached.device == key { return cached.library }
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            cached = (key, library)
            return library
        } catch {
            print("[Diorama] shader compile failed: \(error.localizedDescription)")
            return nil
        }
    }
}
