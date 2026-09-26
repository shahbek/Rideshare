import Foundation

/// Map building shaders, compiled on-device with `MTLDevice.makeLibrary(source:)` so the app build never
/// depends on the offline Metal toolchain. Shared by every `BuildingRenderLayer` through a cached library.
nonisolated enum BuildingMapShaderSource {
    static let source: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct BuildingMapInput {
        float4 position;
        float4 normal;
        float4 color;
        float4 appearance;
    };

    struct BuildingMapOutput {
        float4 position [[position]];
        float3 worldPosition;
        float3 normal;
        float4 color;
        float4 appearance;
    };

    vertex BuildingMapOutput buildingMapVertex(uint id [[vertex_id]],
                                              const device BuildingMapInput *vertices [[buffer(0)]],
                                              constant float4x4 &matrix [[buffer(1)]]) {
        BuildingMapInput v = vertices[id];
        BuildingMapOutput out;
        out.position = matrix * v.position;
        out.worldPosition = v.position.xyz;
        out.normal = v.normal.xyz;
        out.color = v.color;
        out.appearance = v.appearance;
        return out;
    }

    float cementHash(float3 p) {
        p = fract(p * 0.1031);
        p += dot(p, p.yzx + 33.33);
        return fract((p.x + p.y) * p.z);
    }
    float cementNoise(float3 p) {
        float3 i = floor(p), f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        return mix(mix(mix(cementHash(i), cementHash(i + float3(1,0,0)), f.x),
                       mix(cementHash(i + float3(0,1,0)), cementHash(i + float3(1,1,0)), f.x), f.y),
                   mix(mix(cementHash(i + float3(0,0,1)), cementHash(i + float3(1,0,1)), f.x),
                       mix(cementHash(i + float3(0,1,1)), cementHash(i + float3(1,1,1)), f.x), f.y), f.z);
    }

    fragment float4 buildingMapFragment(BuildingMapOutput in [[stage_in]], constant float4 &eyeAndDetail [[buffer(0)]]) {
        bool isWindow = in.appearance.w > 0.5 && in.appearance.w < 1.5;
        float3 view = normalize(eyeAndDetail.xyz - in.worldPosition);
        if (in.appearance.w > 3.5) {
            return float4(min(float3(1.0), in.color.rgb * 1.3 + float3(0.12, 0.025, 0.02)), 1.0);
        }
        if (in.appearance.w > 2.5) {
            float facing = dot(normalize(in.normal), view);
            if (facing <= 0.0) discard_fragment();
            float strength = in.appearance.z > 0.0 ? in.appearance.z : 0.24;
            return float4(in.color.rgb, strength * pow(facing, 3.0));
        }
        if (in.appearance.w > 1.5) {
            float facing = abs(dot(normalize(in.normal), view));
            float edgeLight = pow(1.0 - saturate(facing), 3.0);
            float3 luminous = in.color.rgb * 1.12 + float3(0.07, 0.09, 0.16);
            return float4(mix(luminous, float3(0.72, 0.81, 1.0), 0.22 * edgeLight), 1.0);
        }
        if (isWindow && eyeAndDetail.w <= 0.001) discard_fragment();
        float3 n = normalize(in.normal);
        float3 light = normalize(float3(-0.5, -0.35, 0.85));
        float daylight = 0.88 + 0.12 * max(0.0, dot(n, light));
        float3 color = in.color.rgb * daylight;
        if (in.appearance.w < -3.5) {
            float footprint = max(length(dfdx(in.worldPosition)), length(dfdy(in.worldPosition)));
            float broad = cementNoise(in.worldPosition * 0.65) - 0.5;
            float fine = cementNoise(in.worldPosition * 7.0) - 0.5;
            float broadFade = 1.0 - smoothstep(1.0, 3.0, footprint);
            float fineFade = 1.0 - smoothstep(0.025, 0.16, footprint);
            color *= 1.0 + 0.085 * broad * broadFade + 0.022 * fine * fineFade;
        }
        if (in.appearance.w < -0.5 && in.appearance.w > -3.5 && abs(n.z) < 0.8) {
            float u = abs(n.x) > abs(n.y) ? in.worldPosition.y : in.worldPosition.x;
            float v = in.worldPosition.z;
            float joint = 0.0;
            if (in.appearance.w > -1.5) {
                float row = floor(v / 0.38);
                float2 cell = float2((u + fmod(row, 2.0) * 0.45) / 0.9, v / 0.38);
                float2 edge = min(fract(cell), 1.0 - fract(cell));
                float2 aa = max(fwidth(cell), float2(0.004));
                joint = 1.0 - min(smoothstep(0.025, 0.025 + aa.x, edge.x), smoothstep(0.03, 0.03 + aa.y, edge.y));
                joint *= 1.0 - smoothstep(0.20, 0.6, max(aa.x, aa.y));
            } else {
                float scale = in.appearance.w > -2.5 ? 0.28 : 1.2;
                float cell = (in.appearance.w > -2.5 ? u : v) / scale;
                float aa = max(fwidth(cell), 0.003);
                joint = (1.0 - smoothstep(0.018, 0.018 + aa, min(fract(cell), 1.0 - fract(cell)))) * (1.0 - smoothstep(0.2, 0.6, aa));
            }
            color = mix(color, in.appearance.w > -1.5 ? float3(0.90, 0.87, 0.81) : color * 0.78, joint * 0.45);
        }
        if (isWindow) {
            float3 reflected = reflect(-view, n);
            float3 sky = mix(float3(0.65, 0.69, 0.74), float3(0.88, 0.91, 0.94), saturate(reflected.z * 0.5 + 0.5));
            float fresnel = 0.04 + 0.16 * pow(1.0 - saturate(abs(dot(n, view))), 5.0);
            float sheen = fresnel * (1.0 - in.appearance.x) + in.appearance.y * 0.2;
            color = mix(color, sky, sheen);
        }
        color = mix(color, in.color.rgb, saturate(in.appearance.z));
        return float4(color, 1.0);
    }

    struct BillboardVertexIn {
        float4 position;
        float4 uv;
    };

    struct BillboardVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex BillboardVertexOut billboardVertex(uint id [[vertex_id]],
                                             const device BillboardVertexIn *vertices [[buffer(0)]],
                                             constant float4x4 &matrix [[buffer(1)]]) {
        BillboardVertexOut out;
        out.position = matrix * vertices[id].position;
        out.uv = vertices[id].uv.xy;
        return out;
    }

    fragment float4 billboardFragment(BillboardVertexOut in [[stage_in]],
                                      texture2d<float> frame [[texture(0)]],
                                      constant float4 &tint [[buffer(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float3 rgb = frame.sample(s, in.uv).rgb;
        // LED panels read brighter than paper: lift and add a faint scan-line texture.
        float scan = 0.94 + 0.06 * step(0.5, fract(in.uv.y * 180.0));
        return float4(min(float3(1.0), rgb * 1.12 * scan * tint.rgb), 1.0);
    }
    """
}
