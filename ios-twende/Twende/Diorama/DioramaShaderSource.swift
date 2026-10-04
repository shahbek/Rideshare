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
    /// x: emissive glow strength, y: point-light count, z: time-of-day index, w: unused.
    var params: SIMD4<Float>
}

/// One point light as the GPU sees it: xyz position in local metres + radius, rgb colour + intensity.
nonisolated struct DioramaShaderLight {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
}

/// Lighting presets per time of day: a warm low sun and violet sky at dusk (the default), a cool
/// moonlit night, a plain bright day.
nonisolated enum DioramaLighting {
    static func uniforms(for time: DioramaTimeOfDay, eye: SIMD3<Float>, lightCount: Int) -> DioramaShaderUniforms {
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
            sunColor = SIMD3<Float>(1.0, 0.64, 0.46) * 0.7
            sky = SIMD3<Float>(0.52, 0.44, 0.70)
            ground = SIMD3<Float>(0.30, 0.22, 0.32)
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
            params: SIMD4<Float>(glow, Float(lightCount), time.shaderIndex, 0)
        )
    }
}

/// Diorama shaders, compiled on-device (no offline Metal toolchain needed). One vertex/fragment pair
/// handles every category through `appearance.w`:
///   0 solid lit surface · 1 water · 4 emissive (lit windows, lanterns) · 5 camera-facing halo sprite.
/// Lighting is a hemisphere sky term, one directional sun and up to `maxLights` point lights, so
/// street lamps really pool light on the pavement and the facades beside them.
nonisolated enum DioramaShaderSource {
    static let maxLights = 64

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
    };

    vertex DioramaVarying dioramaVertex(uint id [[vertex_id]],
                                        const device DioramaInput *vertices [[buffer(0)]],
                                        constant float4x4 &matrix [[buffer(1)]],
                                        constant DioramaUniforms &u [[buffer(2)]]) {
        DioramaInput v = vertices[id];
        DioramaVarying out;
        float3 world = v.position.xyz;
        float3 normal = v.normal.xyz;
        if (v.appearance.w > 4.5) {
            // Halo sprite: the normal carries the corner offset (x, y) and radius (z). Rebuild the quad
            // in world space facing the camera so it always reads as a round glow.
            float3 toEye = normalize(u.eye.xyz - world);
            float3 right = normalize(cross(float3(0.0, 0.0, 1.0), toEye));
            if (length(right) < 0.001) right = float3(1.0, 0.0, 0.0);
            float3 up = cross(toEye, right);
            world += (right * v.normal.x + up * v.normal.y) * v.normal.z;
            normal = float3(v.normal.x, v.normal.y, 0.0);
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

    fragment float4 dioramaFragment(DioramaVarying in [[stage_in]],
                                    constant DioramaUniforms &u [[buffer(0)]],
                                    const device DioramaLight *lights [[buffer(1)]]) {
        float code = in.appearance.w;
        float glow = u.params.x;

        if (code > 4.5) {
            // Soft radial halo; brighter core, long faint tail.
            float r = length(in.normal.xy);
            if (r > 1.0) discard_fragment();
            float a = pow(1.0 - r, 2.2) * 0.75 + pow(max(0.0, 1.0 - r * 3.0), 2.0) * 0.5;
            return float4(in.color.rgb * glow, a * min(glow, 1.0));
        }
        if (code > 3.5) {
            // Emissive: lit windows and lanterns. Slightly over-bright so they bloom against dusk walls.
            float3 c = in.color.rgb * (0.55 + 0.75 * glow) + float3(0.10, 0.04, 0.0) * glow;
            return float4(min(c, float3(1.0)), 1.0);
        }

        float3 n = normalize(in.normal);
        float3 view = normalize(u.eye.xyz - in.worldPosition);
        float3 albedo = in.color.rgb;

        // Hemisphere ambient + sun with a soft wrap so vertical walls never go fully black.
        float hemi = n.z * 0.5 + 0.5;
        float3 ambient = mix(u.groundColor.rgb, u.skyColor.rgb, hemi);
        float ndl = dot(n, u.sunDirection.xyz);
        float sun = saturate(ndl * 0.7 + 0.3);
        float3 light = ambient * 0.95 + u.sunColor.rgb * sun;

        // Point lights: lamps, porch lights, kiosks.
        int count = int(u.params.y);
        float3 pointLight = float3(0.0);
        for (int i = 0; i < count; i++) {
            DioramaLight l = lights[i];
            float3 d = l.position.xyz - in.worldPosition;
            float dist2 = dot(d, d);
            float radius = l.position.w;
            if (dist2 > radius * radius) continue;
            float dist = sqrt(dist2);
            float3 L = d / max(dist, 0.01);
            float att = 1.0 - dist / radius;
            att = att * att * (1.0 / (1.0 + dist2 * 0.08));
            float wrap = saturate(dot(n, L) * 0.8 + 0.2);
            pointLight += l.color.rgb * (l.color.w * att * wrap * 3.0);
        }
        light += pointLight * glow;

        float3 color = albedo * light;

        if (code > 0.5 && code < 1.5) {
            // Water: sky reflection with fresnel, a sun glint and a faint ripple of brightness.
            float fresnel = 0.08 + 0.6 * pow(1.0 - saturate(dot(n, view)), 3.0);
            float3 reflected = reflect(-view, n);
            float3 skyRef = mix(u.skyColor.rgb * 1.1, u.sunColor.rgb + u.skyColor.rgb, saturate(reflected.z * 0.6));
            float ripple = dioramaHash(floor(in.worldPosition.xy * 0.7)) * 0.06;
            float glint = pow(saturate(dot(reflected, u.sunDirection.xyz)), 60.0) * 0.6;
            color = mix(albedo * (ambient + u.sunColor.rgb * 0.6), skyRef, fresnel) + ripple + glint * u.sunColor.rgb;
            color += pointLight * glow * 0.4;
            return float4(color, 1.0);
        }

        // Gentle rim light so rounded corners and roof bevels read as soft forms.
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
