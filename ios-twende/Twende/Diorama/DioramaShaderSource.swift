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
    /// x: emissive glow strength, y: unused, z: time-of-day index, w: reflection pass flag (1 = mirrored).
    var params: SIMD4<Float>
    /// x: grid min x, y: grid min y, z: cell size, w: cells per side.
    var lightGrid: SIMD4<Float>
    /// x: water surface height, y: clip plane enabled, z/w: reflection texture size.
    var water: SIMD4<Float>
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
            water: .zero
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
                                    texture2d<float> reflection [[texture(0)]]) {
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

        // Procedural ground textures (appearance.y): grass blades and tufts, sand ripples, asphalt grain,
        // paving slabs. Evaluated in world space so the pattern never swims as the camera moves.
        float tex = in.appearance.y;
        float2 wp = in.worldPosition.xy;
        if (tex > 0.5 && tex < 1.5) {
            float tuft = dioramaNoise(wp * 0.9) * 0.6 + dioramaNoise(wp * 3.1) * 0.4;
            float blade = dioramaNoise(wp * 14.0 + float2(tuft * 3.0, 0.0));
            float mottle = dioramaNoise(wp * 0.12);
            albedo *= 0.86 + 0.22 * tuft + 0.10 * (blade - 0.5) + 0.08 * (mottle - 0.5);
            albedo += float3(0.06, 0.08, 0.0) * smoothstep(0.62, 0.85, tuft);
        } else if (tex > 1.5 && tex < 2.5) {
            float ripple = sin((wp.x * 0.7 + wp.y * 0.25 + dioramaNoise(wp * 0.4) * 2.0) * 4.0) * 0.5 + 0.5;
            albedo *= 0.94 + 0.07 * ripple + 0.05 * (dioramaNoise(wp * 6.0) - 0.5);
        } else if (tex > 2.5 && tex < 3.5) {
            albedo *= 0.94 + 0.10 * dioramaNoise(wp * 5.0) + 0.04 * (dioramaNoise(wp * 0.3) - 0.5);
        } else if (tex > 3.5 && tex < 4.5) {
            float2 slab = fract(wp * 0.55);
            float joint = smoothstep(0.0, 0.05, slab.x) * smoothstep(0.0, 0.05, slab.y);
            albedo *= 0.90 + 0.08 * joint + 0.05 * (dioramaNoise(wp * 2.5) - 0.5);
        }

        float hemi = n.z * 0.5 + 0.5;
        float3 ambient = mix(u.groundColor.rgb, u.skyColor.rgb, hemi);
        float ndl = dot(n, u.sunDirection.xyz);
        float sun = saturate(ndl * 0.7 + 0.3);
        float3 light = ambient * 0.95 + u.sunColor.rgb * sun;

        // Point lights use the un-mirrored world position so reflections are lit like the originals.
        float3 litPos = in.worldPosition;
        float3 litN = n;
        if (mirrored) { litPos.z = 2.0 * u.water.x - litPos.z; litN.z = -litN.z; }
        float3 pointLight = dioramaPointLights(litPos, litN, u, lights, lightTable, lightIndices);
        light += pointLight * glow;

        float3 color = albedo * light;

        if (code > 0.5 && code < 1.5) {
            // Water: planar reflection distorted by gentle ripples, blended with a deep tint by fresnel.
            float2 uv = in.position.xy / u.water.zw;
            float2 ripple = float2(dioramaNoise(in.worldPosition.xy * 0.35 + float2(3.1, 7.7)),
                                   dioramaNoise(in.worldPosition.xy * 0.35)) - 0.5;
            uv += ripple * 0.012;
            uv = clamp(uv, float2(0.001), float2(0.999));
            constexpr sampler s(address::clamp_to_edge, filter::linear);
            float4 refl = reflection.sample(s, uv);
            float3 skyRef = mix(u.skyColor.rgb * 1.05, u.sunColor.rgb * 0.8 + u.skyColor.rgb, 0.35);
            float3 reflected = mix(skyRef, refl.rgb, refl.a);
            float fresnel = 0.18 + 0.72 * pow(1.0 - saturate(dot(n, view)), 2.5);
            float3 deep = albedo * (ambient * 0.9 + u.sunColor.rgb * 0.35);
            float3 glint = u.sunColor.rgb * pow(saturate(dot(reflect(-view, n), u.sunDirection.xyz)), 70.0) * 0.5;
            float shimmer = (dioramaNoise(in.worldPosition.xy * 1.6) - 0.5) * 0.05;
            color = mix(deep, reflected, fresnel) + glint + shimmer;
            color += pointLight * glow * 0.35;
            return float4(color, 1.0);
        }

        float rim = pow(1.0 - saturate(dot(n, view)), 4.0) * 0.08;
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
