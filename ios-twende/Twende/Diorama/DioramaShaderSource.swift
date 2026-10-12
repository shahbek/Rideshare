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
    var airportDetailImage: SIMD4<Float> = .zero
    var airportDetailBounds: SIMD4<Float> = .zero
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
    var focusEdges: SIMD4<Float>
    /// x active, y cell count, z inward offset (metres), w shape revision.
    var unionState: SIMD4<Float>
    var unionShapes: (simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
                      simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4)
    /// x: ambient strength, y: cast-shadow strength (fraction of sun removed in shadow),
    /// z: grade saturation, w: foliage light wrap.
    var look: SIMD4<Float> = SIMD4(0.62, 1, 1.10, 0.18)
    /// rgb: grade tint, w: water body lift.
    var tint: SIMD4<Float> = SIMD4(1.025, 1, 0.985, 0.58)
    /// rgb: distance haze colour, w: haze amount.
    var hazeTone: SIMD4<Float> = SIMD4(0.89, 0.91, 0.89, 0.65)
    /// x: contrast, y: exposure, z: clay rendering (1 = no stored images are sampled; procedural
    /// ground, soft wrapped light, rounded rim), w: reserved.
    var style: SIMD4<Float> = SIMD4(1, 1, 0, 0)
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

/// Twende's stylised, high-saturation lighting rig (Fortnite / Apple Maps park look), shared by the
/// diorama, landmarks, fleet and the Mapbox basemap's 3D lights so every layer is lit by one sky.
///  - Day: strong warm sun against a cool blue sky fill, so shadows read as coloured (blue-green)
///    rather than grey; crisp cast shadows, vivid vibrance, gentle S-curve contrast, thin blue haze.
///  - Dusk: low tangerine sun under a magenta-violet sky, long warm shadows, windows and lamps on.
///  - Night: moonlit cobalt with warm window/lamp pools (lamps stay outside the grade).
nonisolated struct DioramaLightingPreset: Sendable {
    var sun: SIMD3<Float>
    var sunColor: SIMD3<Float>
    var sky: SIMD3<Float>
    var ground: SIMD3<Float>
    var glow: Float
    var ambientStrength: Float
    var shadowStrength: Float
    /// Vibrance: >1 boosts muted colours more than already-saturated ones; <1 desaturates.
    var saturation: Float
    var foliageWrap: Float
    var tint: SIMD3<Float>
    var waterLift: Float
    var haze: SIMD3<Float>
    var hazeAmount: Float
    /// Contrast around a mid-grey pivot and overall exposure, applied in the shared grade.
    var contrast: Float
    var exposure: Float
    /// Mapbox basemap light values: ambient colour/intensity, directional colour/intensity, shadow intensity.
    var nativeAmbient: SIMD3<Float>
    var nativeAmbientIntensity: Double
    var nativeDirectional: SIMD3<Float>
    var nativeDirectionalIntensity: Double
    var nativeShadowIntensity: Double

    static func preset(for time: DioramaTimeOfDay) -> DioramaLightingPreset {
        switch time {
        case .day:
            return DioramaLightingPreset(
                sun: simd_normalize(SIMD3<Float>(-0.46, -0.42, 0.78)),
                sunColor: SIMD3<Float>(1.0, 0.93, 0.80) * 0.80,
                sky: SIMD3<Float>(0.70, 0.83, 1.0), ground: SIMD3<Float>(0.72, 0.76, 0.46),
                glow: 0, ambientStrength: 0.64, shadowStrength: 0.82, saturation: 1.45, foliageWrap: 0.26,
                tint: SIMD3<Float>(1.03, 1.0, 0.95), waterLift: 0.72,
                haze: SIMD3<Float>(0.76, 0.87, 1.0), hazeAmount: 0.16,
                contrast: 1.10, exposure: 1.04,
                nativeAmbient: SIMD3<Float>(0.74, 0.85, 1.0), nativeAmbientIntensity: 0.62,
                nativeDirectional: SIMD3<Float>(1.0, 0.93, 0.80), nativeDirectionalIntensity: 0.66,
                nativeShadowIntensity: 0.78)
        case .dusk:
            return DioramaLightingPreset(
                sun: simd_normalize(SIMD3<Float>(-0.82, -0.42, 0.27)),
                sunColor: SIMD3<Float>(1.0, 0.56, 0.30) * 0.82,
                sky: SIMD3<Float>(0.56, 0.44, 0.86), ground: SIMD3<Float>(0.46, 0.30, 0.36),
                glow: 0.95, ambientStrength: 0.62, shadowStrength: 0.76, saturation: 1.36, foliageWrap: 0.14,
                tint: SIMD3<Float>(1.05, 0.97, 1.0), waterLift: 0.36,
                haze: SIMD3<Float>(0.86, 0.56, 0.62), hazeAmount: 0.34,
                contrast: 1.08, exposure: 1.02,
                nativeAmbient: SIMD3<Float>(0.60, 0.50, 0.86), nativeAmbientIntensity: 0.56,
                nativeDirectional: SIMD3<Float>(1.0, 0.58, 0.32), nativeDirectionalIntensity: 0.62,
                nativeShadowIntensity: 0.70)
        case .night:
            return DioramaLightingPreset(
                sun: simd_normalize(SIMD3<Float>(0.30, 0.45, 0.84)),
                sunColor: SIMD3<Float>(0.55, 0.68, 1.0) * 0.26,
                sky: SIMD3<Float>(0.22, 0.30, 0.60), ground: SIMD3<Float>(0.10, 0.12, 0.24),
                glow: 1.35, ambientStrength: 0.95, shadowStrength: 0.50, saturation: 1.0, foliageWrap: 0.0,
                tint: SIMD3<Float>(0.90, 0.96, 1.12), waterLift: 0.16,
                haze: SIMD3<Float>(0.08, 0.12, 0.26), hazeAmount: 0.40,
                contrast: 1.06, exposure: 1.0,
                nativeAmbient: SIMD3<Float>(0.30, 0.38, 0.66), nativeAmbientIntensity: 0.78,
                nativeDirectional: SIMD3<Float>(0.60, 0.70, 1.0), nativeDirectionalIntensity: 0.26,
                nativeShadowIntensity: 0.40)
        }
    }

    /// Mapbox direction: azimuth clockwise from north and polar angle from the zenith, in degrees.
    var nativeDirection: [Double] {
        let azimuth = atan2(Double(sun.x), Double(sun.y)) * 180 / .pi
        let polar = acos(Double(max(-1, min(1, sun.z)))) * 180 / .pi
        return [(azimuth + 360).truncatingRemainder(dividingBy: 360), min(90, max(0, polar))]
    }
}

nonisolated enum DioramaLighting {
    static func uniforms(for time: DioramaTimeOfDay, eye: SIMD3<Float>) -> DioramaShaderUniforms {
        let preset = DioramaLightingPreset.preset(for: time)
        let sun = preset.sun, sunColor = preset.sunColor, sky = preset.sky, ground = preset.ground, glow = preset.glow
        var uniforms = DioramaShaderUniforms(
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
            tileState: SIMD4(1, 0, 0, 0),
            focusEdges: .zero,
            unionState: .zero,
            unionShapes: (simd_float4x4(), simd_float4x4(), simd_float4x4(), simd_float4x4(), simd_float4x4(),
                          simd_float4x4(), simd_float4x4(), simd_float4x4(), simd_float4x4())
        )
        uniforms.look = SIMD4(preset.ambientStrength, preset.shadowStrength, preset.saturation, preset.foliageWrap)
        uniforms.tint = SIMD4(preset.tint, preset.waterLift)
        uniforms.hazeTone = SIMD4(preset.haze, preset.hazeAmount)
        uniforms.style = SIMD4(preset.contrast, preset.exposure, 0, 0)
        return uniforms
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
    // Resident tile vertices: 32 bytes. position.w = appearance.z, normal.w = appearance.w,
    // color.w = appearance.y. appearance.x is unused by these shaders.
    struct DioramaPackedInput {
        float4 position;
        half4 normal;
        half4 color;
    };
    DioramaInput dioramaUnpack(DioramaPackedInput p) {
        DioramaInput v;
        v.position = float4(p.position.xyz, 1.0);
        v.normal = float4(float3(p.normal.xyz), 0.0);
        v.color = float4(float3(p.color.xyz), 1.0);
        v.appearance = float4(0.85, float(p.color.w), p.position.w, float(p.normal.w));
        return v;
    }

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
        float4 airportDetailImage;
        float4 airportDetailBounds;
        float4 materialFrame;
        float4 post;
        float4 reveal;
        float4 lifecycleReveal;
        float4 tileBounds;
        float4 tileEdges;
        float4 tileState;
        float4 focusEdges;
        float4 unionState;
        float4x4 unionShapes[9];
        float4 look;
        float4 tint;
        float4 hazeTone;
        float4 style;
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
    float3 dioramaPointLights(float3 p, float3 n, constant DioramaUniforms &u,
        const device DioramaLight *lights, const device uint2 *table, const device uint *indices);

    float dioramaFieldDistance(float3 p, float4 reveal, float4 bounds) {
        float ripple = \(DioramaRevealStyle.variation) * (0.6 * sin(p.x * 0.025 + p.y * 0.011)
            + 0.4 * sin(p.y * 0.037 - p.x * 0.009));
        if (reveal.w > 3.5) {
            uint mask = uint(reveal.x);
            float2 a = bounds.xy, b = bounds.zw;
            float2 starts[4] = { a, a, float2(b.x, a.y), float2(a.x, b.y) };
            float2 ends[4] = { float2(a.x, b.y), float2(b.x, a.y), b, b };
            float nearest = 1.0e20;
            for (uint i = 0; i < 4; ++i) {
                if ((mask & (1u << i)) == 0u) continue;
                float2 delta = ends[i] - starts[i];
                float t = clamp(dot(p.xy - starts[i], delta) / max(dot(delta, delta), 0.0001), 0.0, 1.0);
                nearest = min(nearest, length(p.xy - starts[i] - t * delta));
            }
            return nearest - reveal.z + ripple;
        }
        if (reveal.w > 1.5) {
            float d = dot(p.xy, reveal.xy) - reveal.z + ripple;
            return reveal.w > 2.5 ? -d : d;
        }
        float radius = min(12.0, max(0.0, reveal.z) * 0.08);
        float2 q = abs(p.xy - reveal.xy) - (reveal.z - radius);
        return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius + ripple;
    }
    float dioramaFieldCoverage(float3 p, float4 field, float4 bounds) {
        if (field.w < 0.5) return 1.0;
        return 1.0 - smoothstep(-\(DioramaRevealStyle.feather), \(DioramaRevealStyle.feather), dioramaFieldDistance(p, field, bounds));
    }
    float dioramaEdgeCoverage(float3 p, float4 edges, constant DioramaUniforms &u) {
        if (all(edges <= float4(0.0))) return 1.0;
        float4 d = float4(p.xy - u.tileBounds.xy, u.tileBounds.zw - p.xy);
        if (all((d >= float4(\(DioramaRevealStyle.edgeWidth))) | (edges <= float4(0.0)))) return 1.0;
        float4 c = 1.0 - edges * (1.0 - smoothstep(float4(0.0), float4(\(DioramaRevealStyle.edgeWidth)), d));
        return c.x * c.y * c.z * c.w;
    }
    float dioramaSegmentDistanceSquared(float2 p, float2 a, float2 b) {
        float2 v = b - a;
        float t = clamp(dot(p - a, v) / max(dot(v, v), 0.0001), 0.0, 1.0);
        float2 d = p - (a + t * v);
        return dot(d, d);
    }
    float dioramaUnionCoverage(float3 local, constant DioramaUniforms &u) {
        if (u.unionState.x < 0.5) return 1.0;
        float2 p = local.xy * u.materialFrame.z + u.materialFrame.xy;
        bool inside = false;
        float squared = 1.0e20;
        for (uint i = 0; i < min(uint(u.unionState.y), 9u); ++i) {
            float4 b = u.unionShapes[i][0], e = u.unionShapes[i][1];
            inside = inside || (all(p >= b.xy) && all(p <= b.zw));
            if (e.x > 0.5) squared = min(squared, dioramaSegmentDistanceSquared(p, b.xy, float2(b.x, b.w)));
            if (e.y > 0.5) squared = min(squared, dioramaSegmentDistanceSquared(p, b.xy, float2(b.z, b.y)));
            if (e.z > 0.5) squared = min(squared, dioramaSegmentDistanceSquared(p, float2(b.z, b.y), b.zw));
            if (e.w > 0.5) squared = min(squared, dioramaSegmentDistanceSquared(p, float2(b.x, b.w), b.zw));
        }
        float distance = sqrt(squared) * (inside ? -1.0 : 1.0) + u.unionState.z;
        return 1.0 - smoothstep(-\(DioramaRevealStyle.feather), \(DioramaRevealStyle.feather), distance);
    }
    float dioramaFocusCoverage(float3 p, constant DioramaUniforms &u) {
        return dioramaFieldCoverage(p, u.reveal, u.tileBounds) * dioramaEdgeCoverage(p, u.focusEdges, u) * dioramaUnionCoverage(p, u);
    }
    float dioramaRevealCoverage(float3 p, constant DioramaUniforms &u) {
        float focus = u.tileState.y > 1.5 ? 1.0 - dioramaFocusCoverage(p, u)
            : (u.tileState.y > 0.5 ? dioramaFocusCoverage(p, u) : dioramaFieldCoverage(p, u.reveal, u.tileBounds) * dioramaUnionCoverage(p, u));
        return focus * dioramaEdgeCoverage(p, u.tileEdges, u) * dioramaFieldCoverage(p, u.lifecycleReveal, u.tileBounds) * u.tileState.x;
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
            return u.tileState.y > 1.5 ? dioramaEdgeCoverage(p, u.tileEdges, u) * dioramaFieldCoverage(p, u.lifecycleReveal, u.tileBounds) * u.tileState.x : u.tileState.x;
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
                                        const device DioramaPackedInput *vertices [[buffer(0)]],
                                        constant float4x4 &matrix [[buffer(1)]],
                                        constant DioramaUniforms &u [[buffer(2)]]) {
        DioramaInput v = dioramaUnpack(vertices[id]);
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
                                                 const device DioramaPackedInput *vertices [[buffer(0)]],
                                                 constant float4x4 &matrix [[buffer(1)]],
                                                 constant DioramaUniforms &u [[buffer(2)]],
                                                 const device DioramaInstance *instances [[buffer(3)]]) {
        DioramaInput v = dioramaUnpack(vertices[id]);
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
                                      const device DioramaPackedInput *vertices [[buffer(0)]],
                                      constant float4x4 &matrix [[buffer(1)]]) {
        return matrix * float4(vertices[id].position.xyz, 1.0);
    }

    vertex float4 dioramaInstancedShadowVertex(uint id [[vertex_id]], uint instanceID [[instance_id]],
                                               const device DioramaPackedInput *vertices [[buffer(0)]],
                                               constant float4x4 &matrix [[buffer(1)]],
                                               const device DioramaInstance *instances [[buffer(3)]]) {
        return matrix * float4(dioramaPlace(vertices[id].position.xyz, instances[instanceID]), 1.0);
    }

    float dioramaShadow(float3 p, float3 n, constant DioramaUniforms &u, depth2d<float> shadowMap, bool needed = true) {
        if (u.shadowParams.x < 0.5) return 1.0;
        // Normal offset scaled to the shadow texel (and more at grazing light), so a surface never
        // tests against its own depth sample: removes the striped acne on walls and decks.
        float2 uvPerMetre = 0.5 * float2(
            length(float3(u.shadowMatrix[0].x, u.shadowMatrix[1].x, u.shadowMatrix[2].x)),
            length(float3(u.shadowMatrix[0].y, u.shadowMatrix[1].y, u.shadowMatrix[2].y)));
        float texelMetres = u.shadowParams.y / max(min(uvPerMetre.x, uvPerMetre.y), 1e-6);
        float facing = saturate(dot(n, u.sunDirection.xyz));
        float normalOffset = min(0.06 + texelMetres * (0.7 + 1.5 * (1.0 - facing)), 0.6);
        float4 projected = u.shadowMatrix * float4(p + n * normalOffset, 1.0);
        float3 q = projected.xyz / projected.w;
        float2 uv = float2(q.x * 0.5 + 0.5, 0.5 - q.y * 0.5);
        if (any(uv < float2(0.002)) || any(uv > float2(0.998)) || q.z <= 0.0 || q.z >= 1.0) return 1.0;
        constexpr sampler shadowSampler(coord::normalized, address::clamp_to_edge, filter::linear, compare_func::less_equal);
        float bias = u.shadowParams.z * (1.0 + 2.0 * (1.0 - saturate(dot(n, u.sunDirection.xyz))));
        // Compare each PCF tap against the receiver plane at that tap, not the centre depth.
        // A constant centre depth self-shadows flat ground/roofs in diagonal texel-sized bands.
        float2 dx = dfdx(uv), dy = dfdy(uv);
        float dzdx = dfdx(q.z), dzdy = dfdy(q.z);
        // Derivatives above stay quad-uniform; skip only the nine comparisons nobody will use.
        if (!needed) return 1.0;
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
        // Far away one screen pixel already spans the whole filter disk: the nine taps would only
        // alias, so the hardware 2x2 comparison (one tap) or a five-tap cross gives the same result.
        float pixelUV = max(length(dx), length(dy));
        int count = pixelUV > stepSize.x * 2.5 ? 1 : (pixelUV > stepSize.x * 1.2 ? 5 : 9);
        float visibility = 0.0;
        for (int i = 0; i < count; i++) {
            float2 offset = taps[i] * stepSize;
            float receiverDepth = q.z + dot(gradient, offset) - bias - footprintBias;
            visibility += shadowMap.sample_compare(shadowSampler, uv + offset, receiverDepth);
        }
        return visibility / float(count);
    }

    // Fleet shading deliberately has no ground/reflection/AO/paint dependencies. It must render
    // before any saved scenery is loaded, and keep its own LED emission in every light preset.
    fragment float4 dioramaFleetFragment(DioramaVarying in [[stage_in]], bool isFront [[front_facing]],
        constant DioramaUniforms &u [[buffer(0)]], const device DioramaLight *lights [[buffer(1)]],
        const device uint2 *lightTable [[buffer(2)]], const device uint *lightIndices [[buffer(3)]],
        depth2d<float> shadowMap [[texture(0)]]) {
        if (in.appearance.w > 3.5) return float4(min(in.color.rgb * 1.35, float3(1.0)), 1.0);
        float3 n = normalize(in.normal) * (isFront ? 1.0 : -1.0);
        float3 view = normalize(u.eye.xyz - in.worldPosition);
        float hemi = saturate(n.z * 0.5 + 0.5);
        float3 ambient = max(mix(u.groundColor.rgb, u.skyColor.rgb, hemi) * u.look.x * 0.9, u.skyColor.rgb * 0.36);
        float shadow = mix(1.0, dioramaShadow(in.worldPosition, n, u, shadowMap), u.look.y);
        float diffuse = saturate(dot(n, u.sunDirection.xyz));
        float3 local = dioramaPointLights(in.worldPosition, n, u, lights, lightTable, lightIndices);
        float3 lit = in.color.rgb * (ambient + u.sunColor.rgb * diffuse * shadow + local);
        float3 halfVector = normalize(view + u.sunDirection.xyz);
        float roughness = clamp(in.appearance.z, 0.14, 0.90);
        float spec = pow(saturate(dot(n, halfVector)), mix(90.0, 12.0, roughness));
        float fresnel = pow(1.0 - saturate(dot(n, view)), 4.0);
        lit += u.sunColor.rgb * spec * shadow * 0.42 + u.skyColor.rgb * fresnel * 0.12;
        return float4(min(lit, float3(1.0)), 1.0);
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

    /// High-pressure sodium: warm fixtures shift to the deep orange seen in night satellite imagery
    /// (luminance kept). Cool/white/blue sources (airfield, signage) are left alone.
    float3 dioramaSodium(float3 c) {
        float l = dot(c, float3(0.30, 0.59, 0.11));
        float warm = saturate((c.r - c.b) / max(c.r, 1e-3) * 2.0);
        // Saturated sodium amber (2026-10-12 vibrancy pass): lamp pools read orange, not cream.
        return mix(c, float3(1.0, 0.45, 0.09) * (l * 1.6), warm * 0.92);
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
    // Material 5 is mown golf turf: grass for every grading purpose, plus mower stripes.
    float4 dioramaFinishCoverage(float material) {
        return float4((material == 1.0 || material == 5.0) ? 1.0 : 0.0, material == 6.0 ? 1.0 : 0.0,
                      material == 3.0 ? 1.0 : 0.0, material == 2.0 ? 1.0 : 0.0);
    }
    float2 dioramaNaturalMown(float material) {
        bool natural = material == 1.0 || material == 2.0 || material == 5.0 || material == 6.0;
        return float2(natural ? 1.0 : 0.0, material == 5.0 ? 1.0 : 0.0);
    }
    /// Pushes a soft 0…1 transition through stable noise so blended boundaries become organic
    /// (irregular, interlocking) instead of straight or texel-shaped. 0 and 1 stay exact.
    float dioramaOrganic(float coverage, float noise, float amount) {
        float edge = coverage * (1.0 - coverage) * 4.0;
        return saturate(coverage + (noise - 0.5) * amount * edge);
    }
    struct DioramaFinishLookup { float owner; float4 coverage; float natural; float mown; float4 epochs; float2 f; };
    DioramaFinishLookup dioramaGroundFinish(texture2d<float> image, float2 uv) {
        int2 size = int2(image.get_width(), image.get_height());
        float2 pixel = uv * float2(size) - 0.5;
        int2 origin = int2(floor(pixel));
        float2 f = fract(pixel);
        // One gather fetches the same clamped base-level 2x2 footprint the four reads did.
        // Gather order is (0,1), (1,1), (1,0), (0,0) relative to the footprint origin.
        constexpr sampler finishSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
        float2 centre = (float2(origin) + 1.0) / float2(size);
        float4 g = image.gather(finishSampler, centre, int2(0), component::w);
        float4 alpha = float4(g.w, g.z, g.x, g.y);
        // Material code in the top 3 bits; compact tiles keep their raster epoch in the low 5 bits.
        float4 bytes = floor(alpha * 255.0 + 0.5);
        float4 ids = floor(bytes / 32.0);
        DioramaFinishLookup result;
        result.epochs = bytes - ids * 32.0;
        result.f = f;
        result.owner = f.y < 0.5 ? (f.x < 0.5 ? ids.x : ids.y) : (f.x < 0.5 ? ids.z : ids.w);
        result.coverage = mix(mix(dioramaFinishCoverage(ids.x), dioramaFinishCoverage(ids.y), f.x),
                              mix(dioramaFinishCoverage(ids.z), dioramaFinishCoverage(ids.w), f.x), f.y);
        // Bilinear (continuous) natural/mown coverage: drives the boundary warp and mower stripes.
        float2 nm = mix(mix(dioramaNaturalMown(ids.x), dioramaNaturalMown(ids.y), f.x),
                        mix(dioramaNaturalMown(ids.z), dioramaNaturalMown(ids.w), f.x), f.y);
        result.natural = nm.x;
        result.mown = nm.y;
        return result;
    }
    /// Compact tiles: one analytic finish layer (asphalt, paving, clay) composited over the state so far.
    void dioramaHybridApply(thread float3 &albedo, thread float3 &pigment, thread float4 &finish, thread float &tex,
                            thread float &mown, float4 layer, float weight) {
        if (weight <= 0.0) return;
        float code = -layer.w - 100.0;
        albedo = mix(albedo, layer.rgb, weight);
        pigment = mix(pigment, layer.rgb, weight);
        finish = mix(finish, dioramaFinishCoverage(code), weight);
        mown = mix(mown, 0.0, weight);
        if (weight > 0.5) tex = code;
    }
    /// Topmost finish code at a point: the raster code unless a later vector finish covers it.
    float dioramaHybridCode(const device DioramaPaintTriangle *paint, const device uint2 *paintTable,
                            const device uint *paintIndices, float2 wp, float4 frame, float rasterByte) {
        float code = floor(rasterByte / 32.0);
        float epoch = rasterByte - code * 32.0;
        int2 cell = clamp(int2((wp - frame.xy) * frame.zw * 64.0), int2(0), int2(63));
        uint2 entry = paintTable[cell.y * 64 + cell.x];
        float3 p = float3(wp, 1.0);
        for (uint k = 0; k < entry.y; k++) {
            DioramaPaintTriangle t = paint[paintIndices[entry.x + k]];
            if (t.color.w > -99.5 || t.edge1.w < epoch - 0.5) continue;
            if (min(dot(t.edge0.xyz, p), min(dot(t.edge1.xyz, p), dot(t.edge2.xyz, p))) >= 0.0) code = -t.color.w - 100.0;
        }
        return code;
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

    /// fwidth of three linear phases, from position derivatives taken outside any per-pixel branch.
    float3 dioramaLinearWidth(float2 px, float2 py, float2 a, float2 b, float2 c) {
        return abs(float3(dot(px, a), dot(px, b), dot(px, c))) + abs(float3(dot(py, a), dot(py, b), dot(py, c)));
    }

    float dioramaWaterField(float2 p, float time, float2 px, float2 py) {
        float3 phase = float3(dot(p, float2(0.83, 0.56)) - time * 0.71,
                              dot(p, float2(-0.47, 0.91)) + time * 0.53,
                              dot(p, float2(0.29, -1.13)) - time * 0.39);
        float3 width = dioramaLinearWidth(px, py, float2(0.83, 0.56), float2(-0.47, 0.91), float2(0.29, -1.13));
        float3 resolved = 1.0 - smoothstep(float3(0.7), float3(2.5), width);
        return 0.5 + dot(sin(phase) * resolved, float3(0.22, 0.17, 0.11));
    }

    float dioramaWaterCaustic(float2 p, float time, float2 px, float2 py) {
        float3 phase = float3(dot(p, float2(1.7, 0.8)) + time * 0.61,
                              dot(p, float2(-0.9, 1.9)) - time * 0.47,
                              dot(p, float2(1.1, -1.4)) + time * 0.38);
        float3 width = dioramaLinearWidth(px, py, float2(1.7, 0.8), float2(-0.9, 1.9), float2(1.1, -1.4));
        float3 resolved = 1.0 - smoothstep(float3(0.6), float3(2.0), width);
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

    /// Height above the building base from a wall's height attribute; shader-facade walls add
    /// 1000 per decimetre of ground-floor height on top (see DioramaFacade.swift).
    float dioramaWallHeight(float raw) { return raw - 100.0 - 1000.0 * floor(raw / 1000.0); }
    /// Signed box distance in wall space (negative inside), for antialiased openings.
    float dioramaWallBox(float2 p, float2 lo, float2 hi) {
        float2 d = max(lo - p, p - hi);
        return max(d.x, d.y);
    }

    struct DioramaFacadeSample {
        float3 albedo;
        float3 normal;
        float3 emissive;
        float glass;
        float sunMask;
        float occlusion;
    };

    /// Shader facade on a single wall quad: openings, doors, shopfronts, galleries, curtain grids,
    /// slab lines, sills, hoods, plinth and rounded vertical corners, drawn from the wall's own
    /// coordinates. The along-wall position comes from the encoded fraction f and the wall length
    /// from the ratio of screen derivatives (along-wall metres per f). Recesses are parallax: the
    /// view ray is stepped to the pane plane, so reveals, sills and sun shadows inside openings move
    /// with the camera without any geometry. Detail fades to the facade's mean tone below a pixel.
    DioramaFacadeSample dioramaFacade(float3 p, float3 n, float tex, float raw, float code, float3 wall,
                                      float3 view, float3 sun, float glow) {
        DioramaFacadeSample s;
        s.albedo = wall; s.normal = n; s.emissive = float3(0.0); s.glass = 0.0; s.sunMask = 1.0; s.occlusion = 1.0;
        float F = floor(tex + 0.5);
        float f = saturate((tex - (F - 0.375)) / 0.75);
        float styleIndex = floor((F - 32.0) / 32.0);
        int style = int(styleIndex);
        float S = 2.6 + 0.05 * (F - 32.0 - 32.0 * styleIndex);
        float g = floor(raw / 1000.0);
        float h = raw - 100.0 - 1000.0 * g;
        float G = g > 0.5 ? g * 0.1 : S;
        int flags = int(floor(code * 16.0 + 0.5));
        float2 out2 = normalize(n.xy + float2(1e-6, 0.0));
        float2 t2 = float2(-out2.y, out2.x);
        float along = dot(p.xy, t2);
        float2 dA = float2(dfdx(along), dfdy(along));
        float2 dF = float2(dfdx(f), dfdy(f));
        float L = sqrt(dot(dA, dA) / max(dot(dF, dF), 1e-14));
        L = isfinite(L) ? clamp(L, 0.1, 400.0) : 10.0;
        float u = f * L;
        float px = max(max(length(dA), length(float2(dfdx(h), dfdy(h)))), 1e-4);
        float aa = px * 0.75;

        // Rounded vertical corners: over the last r metres both walls bend to the corner bisector,
        // so a square corner shades as a quarter cylinder with no chamfer geometry.
        float r = min(0.9, L * 0.2);
        float kStart = (flags & 1) != 0 ? 0.0 : 1.0 - smoothstep(0.0, r, u);
        float kEnd = (flags & 2) != 0 ? 0.0 : 1.0 - smoothstep(0.0, r, L - u);
        float bend = 0.78539816 * (kEnd - kStart);
        s.normal = normalize(float3(out2 * cos(bend) + t2 * sin(bend), 0.0));

        // Cement plinth and contact darkening where the wall meets the ground.
        float plinth = 1.0 - smoothstep(0.45 - aa, 0.45 + aa, h);
        s.albedo = mix(s.albedo, float3(0.55, 0.54, 0.51), plinth * 0.7);
        s.occlusion = mix(0.60, 1.0, smoothstep(-0.25, 1.7, h));
        if (style <= 0) return s;

        bool groundStorey = h < G;
        bool tall = G > S + 0.05;
        bool front = (flags & 4) != 0;
        float storeyLevel = groundStorey ? 0.0 : 1.0 + floor((h - G) / S);
        float storeyH = groundStorey ? G : S;
        float z = h - (groundStorey ? 0.0 : G + (storeyLevel - 1.0) * S);

        float pitch = 3.0, share = 0.52, width = 0.0, sill = 0.9, lintel = 0.55, depth = 0.24;
        float3 frame = float3(0.94, 0.93, 0.89);
        float3 glassTint = float3(0.16, 0.22, 0.26);
        bool hood = false, ledge = true, slab = false, balustrade = false, curtain = false;
        if (style == 1) { pitch = 2.9; width = 1.15; sill = 0.95; lintel = 0.45; depth = 0.18; hood = true; }
        else if (style == 2) { slab = true; depth = 0.26; }
        else if (style == 3) { pitch = 3.6; share = 0.58; sill = 1.05; lintel = 0.6; depth = 0.18; slab = true; }
        else if (style == 4) { pitch = 3.4; share = 0.86; sill = 0.1; lintel = 0.3; depth = 1.15; slab = true; balustrade = true; ledge = false; }
        else if (style == 5) { pitch = 1.7; share = 0.95; sill = 0.82; lintel = 0.3; depth = 0.14; slab = true; ledge = false; frame = float3(0.30, 0.33, 0.35); }
        else { pitch = 1.5; share = 1.0; sill = 0.0; lintel = 0.0; depth = 0.03; curtain = true; ledge = false; frame = float3(0.74, 0.78, 0.80); glassTint = wall * 0.58; }

        bool solid = false, door = false;
        if (groundStorey) {
            if (front && (style == 3 || style >= 5 || tall)) {
                // Shopfront / lobby: broad dark glazing in slim charcoal frames.
                pitch = max(pitch, 3.0); share = 0.84; sill = tall ? 0.1 : 0.35; lintel = tall ? 0.55 : 0.7;
                depth = 0.3; balustrade = false; curtain = false; ledge = false; hood = false;
                frame = float3(0.28, 0.30, 0.32); glassTint = float3(0.14, 0.19, 0.23);
            } else if (tall && style < 5) {
                solid = true;
            } else if (front && style != 3) {
                door = true;
            }
        }

        float margin = min(0.55, L * 0.1);
        float usable = L - 2.0 * margin;
        float bays = max(1.0, floor(usable / pitch + 0.25));
        // Odd bay count on the entrance wall, every storey, so the door sits on the centre line.
        if (front && fmod(bays, 2.0) < 0.5 && bays > 1.5) bays -= 1.0;
        float cell = usable / bays;
        float x = u - margin;
        float bay = clamp(floor(x / cell), 0.0, bays - 1.0);
        float cx = x - (bay + 0.5) * cell;
        float halfW = width > 0.0 ? min(width * 0.5, cell * 0.5 - 0.35) : cell * share * 0.5;
        float z0 = sill, z1 = storeyH - lintel;
        bool isDoor = door && bay == floor(bays * 0.5);
        if (isDoor) {
            halfW = min(style == 1 ? 0.62 : 0.85, cell * 0.5 - 0.3);
            z0 = 0.5; z1 = min(2.6, storeyH - 0.35);
            frame = style == 1 ? float3(0.36, 0.24, 0.16) : float3(0.28, 0.30, 0.32);
            ledge = false; hood = false; balustrade = false;
        }
        if (curtain) { halfW = cell * 0.5; z0 = 0.45; z1 = storeyH; }
        bool open = !solid && usable > 0.9 && halfW > 0.2 && z1 > z0 + 0.3 && x > -0.01 && x < usable + 0.01;
        float2 lo = float2(-halfW, z0), hi = float2(halfW, z1);
        float d = open ? dioramaWallBox(float2(cx, z), lo, hi) : 1.0e3;
        float cover = 1.0 - smoothstep(-aa, aa, d);

        float3 wallTone = s.albedo;
        // Curtain walls: the vertex colour tints the glass; spandrels are the same glass, darker.
        float3 detailed = curtain ? wallTone * 0.72 : wallTone;
        float paneMask = 0.0;
        // Slab line at every upper floor, with its soft shadow on the storey below.
        if (slab && !groundStorey) {
            float band = 1.0 - smoothstep(0.16 - aa, 0.16 + aa, z);
            detailed *= 1.0 + 0.07 * band;
        }
        if (slab && z > storeyH - 0.12) detailed *= 0.93;
        if (ledge && open) {
            // Projecting sill under the opening and its shadow line.
            float sillMask = (1.0 - smoothstep(halfW + 0.12 - aa, halfW + 0.12 + aa, abs(cx)))
                * (1.0 - smoothstep(-aa, aa, abs(z - (z0 - 0.05)) - 0.05));
            float under = (1.0 - smoothstep(halfW + 0.12, halfW + 0.12 + aa, abs(cx)))
                * step(z0 - 0.26, z) * step(z, z0 - 0.1);
            detailed = mix(detailed * (1.0 - 0.12 * under), frame, sillMask);
        }
        if (hood && open) {
            float hoodMask = (1.0 - smoothstep(halfW + 0.25 - aa, halfW + 0.25 + aa, abs(cx)))
                * (1.0 - smoothstep(-aa, aa, abs(z - (z1 + 0.27)) - 0.05));
            float shade = (1.0 - smoothstep(halfW + 0.25, halfW + 0.25 + aa, abs(cx))) * step(z1, z) * step(z, z1 + 0.22);
            detailed = mix(detailed * (1.0 - 0.18 * shade), frame, hoodMask);
        }
        if (cover > 0.0) {
            // Parallax recess: step the view ray to the pane plane `depth` behind the wall.
            float vN = max(dot(view.xy, out2), 0.15);
            float2 q = float2(cx, z) - depth * float2(dot(view.xy, t2), view.z) / vN;
            float dq = dioramaWallBox(q, lo, hi);
            float onPane = 1.0 - smoothstep(-aa, aa, dq);
            float sN = dot(sun.xy, out2);
            float lit = 0.0;
            if (sN > 0.02) {
                float2 qs = q + depth * float2(dot(sun.xy, t2), sun.z) / sN;
                lit = 1.0 - smoothstep(-aa, aa, dioramaWallBox(qs, lo, hi));
            }
            float vertical = saturate((q.y - z0) / max(z1 - z0, 0.1));
            float3 glassColor = isDoor && style == 1 ? float3(0.42, 0.28, 0.18) : glassTint * (0.85 + 0.3 * vertical);
            float frameMask = onPane * (1.0 - smoothstep(-0.075 - aa, -0.075 + aa, dq));
            if (!curtain && halfW > 0.6) frameMask = max(frameMask, onPane * (1.0 - smoothstep(0.03 - aa, 0.03 + aa, abs(q.x))));
            if (curtain) {
                frameMask = max(frameMask, 1.0 - smoothstep(0.035 - aa, 0.035 + aa, abs(abs(cx) - cell * 0.5)));
                frameMask = max(frameMask, 1.0 - smoothstep(0.04 - aa, 0.04 + aa, abs(z - z0)));
            }
            // Reveal surfaces: the sill catches light, jambs are mid tone, the head is in shade.
            float3 reveal = wallTone * (q.y < z0 ? 0.92 : (q.y > z1 ? 0.5 : 0.7));
            float3 inside = mix(reveal, mix(glassColor, frame, frameMask), onPane);
            paneMask = onPane * (1.0 - frameMask) * (isDoor && style == 1 ? 0.0 : 1.0);
            if (balustrade) {
                // Solid gallery balustrade in the facade plane, over a deep shaded loggia.
                float rail = 1.0 - smoothstep(z0 + 1.0 - aa, z0 + 1.0 + aa, z);
                inside = mix(inside * 0.8, mix(wallTone * 1.04, frame, 1.0 - smoothstep(0.07 - aa, 0.07 + aa, z0 + 1.0 - z)), rail);
                paneMask *= 1.0 - rail;
            }
            detailed = mix(detailed, inside, cover);
            paneMask *= cover;
            s.sunMask = mix(1.0, mix(0.0, 1.0, lit), cover * (balustrade ? 0.7 : 1.0) * step(0.08, depth));
            if (glow > 0.01) {
                float seed = dot(floor((p.xy - t2 * u) * 0.25), float2(1.0, 57.0));
                float chance = fract(sin(dot(float2(bay * 7.0 + storeyLevel * 13.0, seed), float2(12.9898, 78.233))) * 43758.5453);
                float on = step(chance, isDoor ? 0.9 : 0.3);
                s.emissive = float3(1.0, 0.74, 0.42) * (glow * 0.85 * on * paneMask);
            }
        }
        // Below about a pixel per opening the pattern fades to the facade's mean tone (no shimmer).
        float detail = 1.0 - smoothstep(0.22, 0.7, px);
        float openShare = open || curtain ? saturate(2.0 * halfW / max(cell, 0.1)) * saturate((z1 - z0) / max(storeyH, 0.1)) : 0.0;
        float3 mean = mix(wallTone, glassTint * 1.2, (solid ? 0.0 : openShare) * 0.75);
        s.albedo = mix(mean, detailed, detail);
        s.glass = mix(openShare * 0.6, paneMask, detail);
        if (glow > 0.01) s.emissive = mix(float3(1.0, 0.74, 0.42) * (glow * 0.85 * 0.3 * openShare), s.emissive, detail);
        return s;
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
                                    const device DioramaPaintTriangle *detailPaint [[buffer(7)]],
                                    const device uint2 *detailPaintTable [[buffer(8)]],
                                    const device uint *detailPaintIndices [[buffer(9)]],
                                    texture2d<float> reflection [[texture(0)]],
                                    depth2d<float> shadowMap [[texture(1)]],
                                    texture2d<float> groundImage [[texture(2)]],
                                    texture2d<float> occlusion [[texture(3)]],
                                    texture2d<float> microdetail [[texture(4)]],
                                    texture2d<float> airportDetail [[texture(5)]],
                                    texture2d<float> gradeField [[texture(6)]],
                                    texture2d_array<float> buildingMaterials [[texture(7)]]) {
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
            return dioramaRevealColor(dioramaSodium(in.color.rgb) * glow, a * min(glow, 1.0), revealAlpha, u);
        }
        if (code > 5.5) { return dioramaRevealColor(in.color.rgb, 1.0, revealAlpha, u); }
        if (code > 3.5) {
            // Hue-preserving clamp: brightening never bleaches amber windows and lanterns to cream.
            float3 c = in.color.rgb * (0.6 + 0.85 * glow);
            c /= max(1.0, max(c.r, max(c.g, c.b)));
            return dioramaRevealColor(c, 1.0, revealAlpha, u);
        }

        float3 n = normalize(in.normal);
        // Thin double-sided sheets (fronds, sails, canopies) light their back as a real surface.
        if (!isFront) n = -n;
        float3 view = normalize(u.eye.xyz - in.worldPosition);
        if (in.appearance.y > 14.5 && in.appearance.y < 15.5) {
            // Clear architectural glazing: no sky mix, Fresnel, specular or reflected scene.
            return dioramaRevealColor(in.color.rgb, clamp(in.color.a, 0.025, 0.08), revealAlpha, u);
        }
        // Clay: the scene is coloured by its vertices and shaped by its smooth normals; no texture
        // (ground raster, material layers, grain, grade field, occlusion) is read anywhere below.
        bool clay = u.style.z > 0.5;
        int debugOff = int(u.style.w + 0.5);
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
            float h = dioramaWallHeight(in.appearance.z);
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
        // Pixel footprint in metres, taken outside the material branches. Where one pixel covers more
        // than one pre-baked grade texel, the baked low-frequency fields replace live evaluation.
        float footprint = max(length(fwidth(wp)), 1e-4);
        float gradeSize = clay ? 0.0 : float(gradeField.get_width());
        bool bakedGrade = gradeSize >= 64.0 && footprint * u.groundImage.z * gradeSize > 1.0;
        float2 gradeUV = (wp - u.groundImage.xy) * u.groundImage.zw;
        constexpr sampler gradeSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        bool airportHD = !clay && paintedGround && u.airportDetailBounds.z > u.airportDetailBounds.x
            && all(wp >= u.airportDetailBounds.xy) && all(wp < u.airportDetailBounds.zw);
        float4 paintFrame = airportHD ? u.airportDetailImage : u.groundImage;
        float2 vegetationPosition = wp * u.materialFrame.z + u.materialFrame.xy;
        bool analyticAirport = paintedGround && u.materialFrame.w > 0.5 && u.materialFrame.w < 1.5;
        // Clay ground never reads the raster: everything not covered by a vector finish is natural
        // ground, and the vector layers (asphalt, pavements, paving, clay courts) composite over it.
        bool clayGround = clay && paintedGround && !analyticAirport;
        bool hybridFinish = paintedGround && (u.materialFrame.w > 1.5 || clayGround) && !airportHD && (debugOff & 2) == 0;
        float4 rasterEpochs = float4(0.0);
        float2 rasterF = float2(0.0);
        // Organic breakup is only evaluated where a pixel is small enough to see it (no far aliasing).
        float organicDetail = clay ? 0.0 : 1.0 - smoothstep(0.6, 2.5, footprint);
        float breakup = 0.5, breakupFine = 0.5;
        if (paintedGround && organicDetail > 0.0) {
            breakup = mix(0.5, dioramaNoise(vegetationPosition * 0.21 + float2(2.3, -6.1)), organicDetail);
            breakupFine = mix(0.5, dioramaNoise(vegetationPosition * 0.83 + float2(-9.4, 4.2)), organicDetail);
        }
        float coastCoverage = paintedGround
            ? dioramaOrganic(saturate(in.appearance.z), breakup * 0.65 + breakupFine * 0.35, 1.1) : 0.0;
        float3 paintedPigment = albedo;
        float mown = 0.0;
        if (clayGround) {
            // Source lawn swatch as the pigment the procedural turf grades from; the vertex colour
            // (coast sand) still feathers in through `coastCoverage` like the painted path.
            float3 lawn = float3(131.0, 173.0, 50.0) / 255.0;
            albedo = mix(lawn, in.color.rgb, coastCoverage);
            paintedPigment = lawn;
            tex = 1.0;
            finish = dioramaFinishCoverage(1.0);
        } else if (paintedGround && !analyticAirport) {
            // Painted ground: albedo from the tile image, grain code from its alpha (×32).
            constexpr sampler groundSampler(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear, max_anisotropy(8));
            float2 guv = (wp - paintFrame.xy) * paintFrame.zw;
            guv.y = 1.0 - guv.y;
            DioramaFinishLookup material = airportHD ? dioramaGroundFinish(airportDetail, guv) : dioramaGroundFinish(groundImage, guv);
            // Seamless natural boundaries: inside grass/sand/dirt the raster is read through a small,
            // stable two-octave domain warp, so magnified texel edges become irregular and interlocking
            // instead of square steps. The warp weight is the continuous bilinear natural coverage, so
            // it fades to zero at roads and paving, which keep their exact edges. It is skipped wherever
            // one pixel already spans a texel (no extra reads at map distance).
            float texSize = float(airportHD ? airportDetail.get_width() : groundImage.get_width());
            float texelMetres = 1.0 / max(paintFrame.z * texSize, 1e-6);
            float warpWeight = material.natural * (1.0 - smoothstep(0.5, 1.0, footprint / texelMetres));
            if (warpWeight > 0.001) {
                float2 q = wp / (texelMetres * 2.4);
                float2 warp = float2(dioramaNoise(q + float2(3.1, 7.7)), dioramaNoise(q.yx + float2(-5.3, 1.9))) - 0.5;
                warp += (float2(dioramaNoise(q * 2.9 + float2(11.0, -2.0)), dioramaNoise(q.yx * 2.9 + float2(-7.0, 13.0))) - 0.5) * 0.45;
                guv += float2(warp.x, -warp.y) * (1.7 * texelMetres * warpWeight) * paintFrame.zw;
                material = airportHD ? dioramaGroundFinish(airportDetail, guv) : dioramaGroundFinish(groundImage, guv);
            }
            float4 painted = airportHD ? airportDetail.sample(groundSampler, guv) : groundImage.sample(groundSampler, guv);
            albedo = painted.rgb;
            paintedPigment = painted.rgb;
            tex = material.owner;
            finish = material.coverage;
            mown = material.mown;
            rasterEpochs = material.epochs;
            rasterF = material.f;
            if (finish.x > 0.0001) {
                // Coast pigment stays on the same surface; hard finishes keep their ownership.
                albedo = mix(albedo, in.color.rgb, coastCoverage * finish.x);
            }
        }
        if (hybridFinish) {
            // Compact tiles: roads, pavements, paving and clay are exact vector layers over the natural
            // raster, in painter's order. A layer is hidden where a later raster op (newer epoch) painted.
            int2 cell = clamp(int2((wp - u.groundImage.xy) * u.groundImage.zw * 64.0), int2(0), int2(63));
            uint2 entry = paintTable[cell.y * 64 + cell.x];
            float aa = max(0.003, min(0.5, footprint * 0.65));
            float layer = -1.0, coverage = 0.0, visible = 0.0;
            float4 pigment = float4(0.0);
            float3 p = float3(wp, 1.0);
            for (uint k = 0; k < entry.y; k++) {
                DioramaPaintTriangle t = paint[paintIndices[entry.x + k]];
                if (t.color.w > -99.5) continue;
                if (layer != t.edge0.w) {
                    dioramaHybridApply(albedo, paintedPigment, finish, tex, mown, pigment, saturate(coverage) * visible);
                    layer = t.edge0.w; pigment = t.color; coverage = 0.0;
                    float4 shown = step(rasterEpochs, float4(t.edge1.w + 0.5));
                    visible = mix(mix(shown.x, shown.y, rasterF.x), mix(shown.z, shown.w, rasterF.x), rasterF.y);
                }
                float distance = min(dot(t.edge0.xyz, p), min(dot(t.edge1.xyz, p), dot(t.edge2.xyz, p)));
                coverage += smoothstep(-aa, aa, distance);
            }
            dioramaHybridApply(albedo, paintedPigment, finish, tex, mown, pigment, saturate(coverage) * visible);
        }
        if (analyticAirport) {
            // The saved OSM finish operations own exact boundaries. Pigment/detail below reuse
            // the existing grass/asphalt material system; the campus raster is not magnified.
            albedo = in.color.rgb;
            tex = 1.0;
            finish = dioramaFinishCoverage(tex);
            int2 cell = clamp(int2((wp - u.groundImage.xy) * u.groundImage.zw * 64.0), int2(0), int2(63));
            uint2 entry = paintTable[cell.y * 64 + cell.x];
            float aa = max(0.003, min(0.5, length(fwidth(wp)) * 0.65));
            float layer = -1.0, coverage = 0.0;
            float4 pigment = float4(0.0);
            for (uint k = 0; k < entry.y; k++) {
                DioramaPaintTriangle t = paint[paintIndices[entry.x + k]];
                if (t.color.w >= 0.0) continue;
                if (layer != t.edge0.w) {
                    float weight = saturate(coverage);
                    albedo = mix(albedo, pigment.rgb, weight);
                    finish = mix(finish, dioramaFinishCoverage(-pigment.w - 1.0), weight);
                    if (weight > 0.5) tex = -pigment.w - 1.0;
                    layer = t.edge0.w; pigment = t.color; coverage = 0.0;
                }
                float3 p = float3(wp, 1.0);
                float distance = min(dot(t.edge0.xyz, p), min(dot(t.edge1.xyz, p), dot(t.edge2.xyz, p)));
                coverage += smoothstep(-aa, aa, distance);
            }
            float weight = saturate(coverage);
            albedo = mix(albedo, pigment.rgb, weight);
            finish = mix(finish, dioramaFinishCoverage(-pigment.w - 1.0), weight);
            if (weight > 0.5) tex = -pigment.w - 1.0;
        }
        float sandArea = paintedGround && !analyticAirport ? finish.w : 0.0;
        float naturalArea = finish.x + finish.y + sandArea;
        float naturalCoverage = coastCoverage;
        float soilFraction = 0.0;
        grassDetailWeight = 0.0;
        if (naturalArea > 0.0001 && clay) {
            // Skill ground (style-spec §4/§6): flat palette polygons, grass graded between two
            // vivid greens by one broad noise. No tufts, dryness, worn patches, clods or ripples.
            if (paintedGround && finish.y > 0.0001) {
                soilFraction = smoothstep(0.08, 0.94, dioramaEarthFraction(albedo));
            }
            float broad = dioramaNoise(vegetationPosition * 0.03 + float2(11.4, -7.2));
            float3 grass = mix(float3(96.0, 150.0, 30.0), float3(150.0, 196.0, 52.0), smoothstep(0.22, 0.78, broad)) / 255.0;
            float3 turfRatio = clamp(paintedPigment / float3(131.0, 173.0, 50.0) * 255.0, float3(0.80), float3(1.25));
            grass = mix(grass, grass * turfRatio, (1.0 - soilFraction) * 0.85);
            if (mown > 0.001) {
                float phase = dot(vegetationPosition, float2(0.7071, 0.7071)) / 6.0;
                float stripeAA = saturate(1.0 - fwidth(phase) * 2.0);
                float stripe = smoothstep(-0.18, 0.18, sin(phase * 3.14159265)) * 2.0 - 1.0;
                grass *= 1.0 + stripe * 0.075 * stripeAA * mown;
            }
            float3 ground = mix(grass, float3(184.0, 140.0, 88.0) / 255.0, soilFraction);
            float sandShare = sandArea / naturalArea;
            if (sandShare > 0.0001) {
                ground = mix(ground, paintedPigment * float3(1.06, 0.99, 0.88), smoothstep(0.2, 0.8, sandShare));
            }
            albedo = mix(albedo, ground, naturalArea * (1.0 - naturalCoverage));
        } else if (naturalArea > 0.0001) {
            if (paintedGround && finish.y > 0.0001) {
                soilFraction = smoothstep(0.08, 0.94, dioramaEarthFraction(albedo));
            }
            // Stable moisture/dryness fields at landscape, lawn and tuft scales. No moving noise.
            // All fields use the original material coordinates, including mirrored reflections.
            float2 patchPosition = float2(dot(vegetationPosition, float2(0.80, -0.60)),
                                          dot(vegetationPosition, float2(0.60, 0.80)));
            float broad, patches;
            if (bakedGrade) {
                float2 baked = gradeField.sample(gradeSampler, gradeUV).rg;
                broad = baked.x; patches = baked.y;
            } else {
                broad = dioramaNoise(vegetationPosition * 0.027 + float2(11.4, -7.2));
                patches = dioramaNoise(patchPosition * 0.105 + float2(-4.1, 19.7));
            }
            float tufts = dioramaNoise(patchPosition * 0.73);
            // Park-turf palette sampled from the reference: broad soft swathes of vivid yellow-green
            // and deeper green, with sunlit chartreuse highlights; no straw or grey patches.
            float tone = smoothstep(0.28, 0.72, broad * 0.64 + patches * 0.30 + tufts * 0.06);
            float3 deepGrass = float3(70.0, 112.0, 26.0) / 255.0;
            float3 livingGrass = float3(116.0, 154.0, 36.0) / 255.0;
            float3 sunGrass = float3(168.0, 184.0, 60.0) / 255.0;
            float3 grass = tone < 0.5 ? mix(deepGrass, livingGrass, tone / 0.5)
                                      : mix(livingGrass, sunGrass, (tone - 0.5) / 0.5);
            float dry = smoothstep(0.42, 0.74, patches) * smoothstep(0.40, 0.68, broad);
            grass = mix(grass, float3(184.0, 178.0, 74.0) / 255.0, dry * 0.5);
            grass *= 0.96 + 0.08 * tufts;
            // Keep the painted distinction between rough, lawns, pitches, fairways and greens.
            float3 turfRatio = clamp(paintedPigment / float3(131.0, 173.0, 50.0) * 255.0, float3(0.80), float3(1.25));
            grass = mix(grass, grass * turfRatio, (1.0 - soilFraction) * 0.85);
            if (mown > 0.001) {
                // Golf mower stripes: alternating 6 m light/dark bands, faded before they alias.
                float phase = dot(vegetationPosition, float2(0.7071, 0.7071)) / 6.0;
                float stripeAA = saturate(1.0 - fwidth(phase) * 2.0);
                float stripe = smoothstep(-0.18, 0.18, sin(phase * 3.14159265)) * 2.0 - 1.0;
                grass *= 1.0 + stripe * 0.075 * stripeAA * mown;
                grass = mix(grass, grass * float3(0.94, 1.04, 0.92), mown * 0.5);
            }
            // Worn ground: grass thins to olive, then warm soil, through interlocking organic patches,
            // never a hard grass-to-mud line.
            float soil = dioramaOrganic(soilFraction, breakup * 0.6 + breakupFine * 0.4, 1.3);
            float3 worn = float3(152.0, 146.0, 72.0) / 255.0;
            float3 earth = float3(170.0, 136.0, 94.0) / 255.0;
            float3 ground = mix(mix(grass, worn, smoothstep(0.0, 0.55, soil)), earth, smoothstep(0.45, 1.0, soil));
            // Mapped sand/beach: keep the painted sand pigment (soil beds stay brown), warm it toward
            // a sunny peach, add faint wind ripples, and feather it into turf with organic tongues.
            float sandShare = sandArea / naturalArea;
            if (sandShare > 0.0001) {
                float sandEdge = smoothstep(0.2, 0.8, dioramaOrganic(sandShare, breakup * 0.5 + breakupFine * 0.5, 1.4));
                float3 sand = paintedPigment * float3(1.05, 0.99, 0.90) * (0.97 + 0.06 * tufts);
                float ripplePhase = dot(vegetationPosition, float2(0.92, 0.38)) * 2.4 + tufts * 3.0;
                sand *= 1.0 + 0.025 * sin(ripplePhase) * saturate(1.0 - fwidth(ripplePhase) * 0.5);
                ground = mix(ground, sand, sandEdge);
                soil = max(soil, sandEdge);
            }
            float vegetation = naturalArea * (1.0 - naturalCoverage);
            albedo = mix(albedo, ground, vegetation);
            grassDetailWeight = vegetation * (1.0 - soil);
            soilFraction = soil;
            if (soil > 0.001) {
                float clods = dioramaNoise(wp * 1.7) * 0.65 + dioramaNoise(wp * 0.18) * 0.35;
                albedo *= 1.0 + (clods - 0.5) * 0.08 * vegetation * soil;
            }
        }
        if (tex > 1.5 && tex < 2.5) {
            albedo *= 0.98 + 0.04 * (dioramaNoise(wp * 0.5) - 0.5);
        } else if (finish.z > 0.0001) {
            // Quiet rosy warm-grey; mask out white/yellow paint and red-earth road finishes.
            float coolAsphalt = smoothstep(-0.015, 0.045, albedo.b - albedo.g)
                * (1.0 - smoothstep(0.60, 0.80, min(albedo.r, min(albedo.g, albedo.b))));
            float weather = bakedGrade ? gradeField.sample(gradeSampler, gradeUV).b
                                       : dioramaNoise(vegetationPosition * 0.055 + float2(8.2, 13.9));
            // Clay: the skill's lavender-grey road, one broad weathering field, no aggregate grain.
            float aggregate = clay ? 0.5 : dioramaNoise(vegetationPosition * 0.85);
            float3 asphalt = clay ? mix(float3(112.0, 104.0, 126.0), float3(138.0, 130.0, 152.0), smoothstep(0.25, 0.76, weather)) / 255.0
                                  : mix(float3(119.0, 116.0, 111.0), float3(169.0, 156.0, 151.0), smoothstep(0.25, 0.76, weather)) / 255.0;
            asphalt *= 0.94 + 0.12 * aggregate;
            albedo = mix(albedo, asphalt, coolAsphalt * finish.z);
        } else if (tex > 3.5 && tex < 4.5) {
            albedo *= 0.98 + 0.04 * (dioramaNoise(wp * 0.6) - 0.5);
        }

        if (tex > 9.5 && tex < 10.5) {
            // Skill puff canopies: the vertex gradient (dark foot to bright crown) is the colour; a
            // fine painterly grain (±6 %) is the only texture, faded once a pixel spans it.
            float grainFade = 1.0 - smoothstep(0.25, 1.2, footprint);
            if (grainFade > 0.0) {
                float2 g = surfacePosition.xy * 1.9 + float2(surfacePosition.z * 1.3, -surfacePosition.z * 0.7);
                float grain = dioramaNoise(g) * 0.6 + dioramaNoise(g * 2.7 + float2(5.1, -3.3)) * 0.4;
                albedo *= 1.0 + (grain - 0.5) * 0.12 * grainFade;
            }
            albedo *= mix(float3(1.0), float3(0.93, 1.03, 0.90), smoothstep(0.54, 0.90, in.treeVariation) * 0.6);
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
        if (textured && !clay && u.shoreline.z < 0.5 && u.groundColor.w > 0.5) {
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
            // Fully faded detail (most map-distance pixels) contributes exactly nothing: skip it.
            if (resolved > 0.0) {
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
                    // Quads straddling the fade edge may hold undefined neighbour derivatives.
                    if (all(isfinite(reliefNormal))) detailNormal = normalize(mix(surfaceNormal, reliefNormal, reliefWeight));
                }
                albedo *= 1.0 + relief * (foliage ? 0.018 : (grassSurface ? 0.025 : 0.012)) * reliefWeight;
            }
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

        // Building material library (texture 7, 64 px layers, 1.2/2.4/4.8 m repeats): roofs and walls pick a material per
        // building from a stable hash of its own source colour, so neighbours differ but each house is
        // consistent. RGB is a tint ratio (x2) that keeps the source pigment; A is relief height.
        bool materialLibrary = !clay && u.groundColor.w > 0.5 && (roofSurface || plasterSurface);
        float3 seedColor = floor(in.color.rgb * 40.0);
        float materialSeed = dioramaHash(seedColor.xy + seedColor.z * float2(7.13, 3.71));
        float materialSeed2 = dioramaHash(seedColor.yz * 1.7 + float2(11.3, 4.9));
        constexpr sampler materialSampler(coord::normalized, address::repeat, filter::linear, mip_filter::linear, max_anisotropy(8));
        float luminance = dot(albedo, float3(0.2126, 0.7152, 0.0722));
        float chroma = max(albedo.r, max(albedo.g, albedo.b)) - min(albedo.r, min(albedo.g, albedo.b));
        if (roofSurface) {
            float slopeZ = abs(surfaceNormal.z);
            bool flatRoof = slopeZ > 0.97;
            // Sloped roofs: u runs along the eave, v down the slope in true (slant) metres.
            float2 down = flatRoof ? float2(0.0, 1.0) : normalize(surfaceNormal.xy + float2(0.0001, 0.0));
            float2 across = float2(-down.y, down.x);
            float2 roofUV = float2(dot(vegetationPosition, across), dot(vegetationPosition, down) / max(slopeZ, 0.35));
            float weather = dioramaNoise(roofUV * 0.12 + float2(3.1, 9.2));
            bool clay = albedo.r > albedo.g * 1.25 && albedo.r > albedo.b * 1.35;
            bool concreteRoof = albedo.r >= albedo.g && albedo.g >= albedo.b
                && albedo.r - albedo.b < 0.12 && luminance > 0.62;
            // Flat decks and pale concrete roofs stay a plain, even material (user direction): no
            // weathering, stain field or slab texture. Only sheet and tile roofs carry a material.
            bool plainRoof = flatRoof || (concreteRoof && !clay);
            if (!plainRoof) albedo *= 0.89 + 0.18 * weather;
            if (materialLibrary && !plainRoof) {
                // 0 mabati, 1 rusted mabati, 2 clay Roman, 3 concrete step tile, 4 box-rib.
                uint layer = clay ? (materialSeed < 0.62 ? 2u : 3u)
                    : chroma > 0.10 ? (materialSeed < 0.55 ? 4u : 0u)
                    : (materialSeed < 0.50 ? 0u : (materialSeed < 0.82 ? 1u : 4u));
                float repeatMetres = 1.2;
                float2 uv = roofUV / repeatMetres;
                float4 m = buildingMaterials.sample(materialSampler, uv, layer);
                albedo *= m.rgb * 2.0;
                float uvFootprint = max(length(dfdx(uv)), length(dfdy(uv)));
                float resolved = 1.0 - smoothstep(1.0 / 64.0, 5.0 / 64.0, uvFootprint);
                if (resolved > 0.0) {
                    // Texture-space finite differences (continuous per fragment) tilt the normal across
                    // corrugations/tile barrels so ridges catch sun glints and darken their troughs.
                    float stepUV = max(1.0 / 64.0, uvFootprint);
                    float hx = buildingMaterials.sample(materialSampler, uv + float2(stepUV, 0.0), layer).a;
                    float hy = buildingMaterials.sample(materialSampler, uv + float2(0.0, stepUV), layer).a;
                    float amplitude = layer == 2u ? 0.05 : (layer == 3u ? 0.03 : 0.018);
                    float2 dh = float2(hx - m.a, hy - m.a) * (amplitude / (stepUV * repeatMetres));
                    float3 tangentA = float3(across, 0.0);
                    float3 tangentB = normalize(cross(surfaceNormal, tangentA));
                    float3 slope = tangentA * dh.x - tangentB * dh.y;
                    slope *= min(1.0, 0.6 / max(length(slope), 1e-6));
                    float3 reliefNormal = normalize(surfaceNormal - slope);
                    if (all(isfinite(reliefNormal))) detailNormal = normalize(mix(detailNormal, reliefNormal, resolved));
                }
            }
        }
        if (plasterSurface) {
            float2 tangent = normalize(float2(-surfaceNormal.y, surfaceNormal.x) + float2(0.0001, 0.0));
            float2 wallUV = float2(dot(vegetationPosition, tangent), surfacePosition.z);
            float weather = dioramaNoise(wallUV * float2(0.16, 0.34));
            float h = in.appearance.z > 50.0 ? max(0.0, dioramaWallHeight(in.appearance.z)) : 9.0;
            float foot = (1.0 - smoothstep(0.0, 1.4, h)) * (0.04 + 0.07 * weather);
            albedo *= 0.97 + 0.06 * weather - foot;
            // Cement plinth: most Dar houses stand on a grey 0.45 m rendered base (crisp at its edge).
            if (in.appearance.z > 50.0) {
                float plinthEdge = max(fwidth(h), 0.01);
                float plinth = (1.0 - smoothstep(0.45 - plinthEdge, 0.45 + plinthEdge, h)) * step(materialSeed2, 0.8);
                albedo = mix(albedo, float3(0.50, 0.49, 0.46) * (0.92 + 0.16 * weather), plinth * 0.85);
            }
            if (materialLibrary) {
                // 6 painted plaster, 7 cement block, 8 coral rag, 9 rough-cast, 10 brick, 11 scored render.
                bool grey = chroma < 0.06 && luminance > 0.25 && luminance < 0.66;
                bool brickLike = albedo.r > albedo.g * 1.22 && albedo.r > albedo.b * 1.4 && luminance < 0.5;
                uint layer = grey ? (materialSeed < 0.6 ? 7u : 9u)
                    : brickLike ? 10u
                    : materialSeed < 0.05 ? 8u
                    : materialSeed < 0.58 ? 6u
                    : materialSeed < 0.80 ? 9u : 11u;
                float2 uv = wallUV / (layer == 6u || layer == 9u ? 2.4 : 1.2);
                float4 m = buildingMaterials.sample(materialSampler, uv, layer);
                albedo *= m.rgb * 2.0;
                // Painted houses often carry a darker skirting band to ~0.9 m (dado), crisp at its edge.
                if (layer == 6u || layer == 9u || layer == 11u) {
                    float edge = max(fwidth(h), 0.01);
                    float dado = (1.0 - smoothstep(0.9 - edge, 0.9 + edge, h)) * step(0.45, materialSeed2);
                    albedo *= 1.0 - dado * 0.22;
                }
                float uvFootprint = max(length(dfdx(uv)), length(dfdy(uv)));
                float resolved = 1.0 - smoothstep(1.0 / 64.0, 5.0 / 64.0, uvFootprint);
                // Mortar joints and stone gaps read as soft recesses without extra samples.
                albedo *= 1.0 - (1.0 - m.a) * 0.10 * resolved * float(layer == 7u || layer == 8u || layer == 10u);
            }
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

        // Shader facades (material codes 32-255 on building walls): openings, corners and reveals.
        DioramaFacadeSample facade;
        facade.albedo = albedo; facade.normal = detailNormal; facade.emissive = float3(0.0);
        facade.glass = 0.0; facade.sunMask = 1.0; facade.occlusion = 1.0;
        bool facadeWall = in.appearance.y > 31.5 && code < 0.5 && in.appearance.z > 50.0 && (debugOff & 1) == 0;
        if (facadeWall) {
            facade = dioramaFacade(surfacePosition, surfaceNormal, in.appearance.y, in.appearance.z, code,
                                   albedo, view, u.sunDirection.xyz, glow);
            albedo = facade.albedo;
            detailNormal = facade.normal;
        }

        // Apply analytic lane paint after natural recolouring/detail so boundary coverages cannot
        // tint its white/yellow pigment. Nearest asphalt ownership still excludes coast and paving.
        if (paintedGround && tex > 2.5 && tex < 3.5) {
            float4 lineFrame = analyticAirport ? u.groundImage : paintFrame;
            bool detailLines = airportHD && !analyticAirport;
            int2 cell = clamp(int2((wp - lineFrame.xy) * lineFrame.zw * 64.0), int2(0), int2(63));
            uint2 entry = detailLines ? detailPaintTable[cell.y * 64 + cell.x] : paintTable[cell.y * 64 + cell.x];
            float aa = max(0.003, min(0.5, length(fwidth(wp)) * 0.65));
            float white = 0.0, yellow = 0.0;
            float3 whiteColor = float3(0.98, 0.96, 0.92), yellowColor = float3(0.96, 0.77, 0.19);
            // Shader kerbs (color.w 3/4): coverage-weighted distance from the road edge and the
            // direction into the road, averaged where neighbouring spans overlap.
            float kerbCover = 0.0, kerbDistance = 0.0;
            float2 kerbInward = float2(0.0);
            float3 kerbColor = float3(0.95, 0.92, 0.88);
            for (uint k = 0; k < entry.y; k++) {
                DioramaPaintTriangle t = detailLines ? detailPaint[detailPaintIndices[entry.x + k]] : paint[paintIndices[entry.x + k]];
                if (t.color.w < 0.0) continue;
                float3 p = float3(wp, 1.0);
                float distance = min(dot(t.edge0.xyz, p), min(dot(t.edge1.xyz, p), dot(t.edge2.xyz, p)));
                float coverage = smoothstep(-aa, aa, distance);
                if (t.color.w > 2.5) {
                    if (coverage <= 0.0) continue;
                    bool farSide = t.color.w > 3.5;
                    float s = dot(t.edge0.xyz, p);
                    kerbDistance += coverage * (farSide ? 0.7 - s : s);
                    kerbInward += coverage * (farSide ? -t.edge0.xy : t.edge0.xy);
                    kerbCover += coverage;
                    kerbColor = t.color.rgb;
                    continue;
                }
                if (t.color.b < 0.5) { yellow += coverage; yellowColor = t.color.rgb; }
                else { white += coverage; whiteColor = t.color.rgb; }
            }
            if (kerbCover > 0.001) {
                // Pale 17 cm kerb top, an 8 cm face turned toward the road (lit by the real sun
                // through the normal), then a soft gutter shadow fading over 45 cm of asphalt.
                float s = kerbDistance / kerbCover;
                float w = saturate(kerbCover);
                float ka = max(aa, 0.012);
                float top = 1.0 - smoothstep(0.17 - ka, 0.17 + ka, s);
                float face = (1.0 - smoothstep(0.25 - ka, 0.25 + ka, s)) - top;
                float gutter = smoothstep(0.25 - ka, 0.25 + ka, s) * (1.0 - smoothstep(0.25, 0.7, s));
                float2 inward = kerbInward / max(length(kerbInward), 1e-5);
                albedo = mix(albedo, kerbColor * mix(1.0, 0.86, face / max(top + face, 1e-4)), w * (top + face));
                albedo *= 1.0 - w * gutter * 0.34;
                float3 faceNormal = normalize(float3(inward, 0.4));
                float3 lipNormal = normalize(float3(inward * 0.5, 1.0));
                float lip = smoothstep(0.08, 0.17, s) * top;
                detailNormal = normalize(mix(detailNormal, faceNormal, w * face));
                detailNormal = normalize(mix(detailNormal, lipNormal, w * lip));
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
        // Clay uses the skill's wrap (0.45) so rounded forms shade as continuous curves; the
        // cast-shadow lookup below must cover every face that wrapped sun still reaches.
        float wrap = clay ? 0.45 : (foliage ? u.look.w : 0.0);
        float sun = saturate((ndl + wrap) / (1.0 + wrap)) * facade.sunMask;
        // Faces turned from the sun only use visibility for specular materials.
        float visibility = dioramaShadow(litPos, litN, u, shadowMap,
            sun > 0.0 || roofSurface || roadSurface || (tex > 13.5 && tex < 14.5));
        // Near the terminator the shadow map compares a surface with itself at a grazing angle and
        // stripes (acne). Such faces are already dark from N·L, so the cast-shadow test fades out.
        visibility = mix(1.0, visibility, smoothstep(0.0, 0.12, dot(litN, u.sunDirection.xyz)));
        // Soft, Apple Maps-like cast shadows: the preset decides how much sun a shadow removes.
        float3 light = ambient * u.look.x * ao * facade.occlusion + u.sunColor.rgb * sun * mix(1.0, visibility, u.look.y) * (0.75 + 0.25 * ao);
        if (clay) {
            // Skill `stylize`: wrapped soft diffuse (wrap 0.45, smooth ramp) pulled toward a
            // purple-blue shadow tint, plus hemisphere fill. Shadows stay coloured, never grey, so
            // every surface keeps its own saturated hue on the shaded side.
            float diff = smoothstep(0.02, 0.98, saturate((ndl + 0.45) / 1.45)) * facade.sunMask;
            float lit = diff * mix(1.0, visibility, u.look.y);
            float3 shadowTint = u.skyColor.rgb * float3(0.62, 0.55, 0.66);
            float3 direct = mix(shadowTint, u.sunColor.rgb * 1.25, lit);
            light = (direct * 0.78 + ambient * (0.30 * u.look.x / 0.64)) * ao * facade.occlusion;
        }
        float3 pointLight = glow > 0.01 ? dioramaSodium(dioramaPointLights(litPos, litN, u, lights, lightTable, lightIndices)) : float3(0.0);
        // City glow: the orange wash of night satellite imagery comes from thousands of overlapping
        // sodium pools along every street, not from individual fixtures. A road-density field baked
        // once into the grade texture (alpha) lights ground and facades near streets, with gentle
        // pooling; roofs catch only a little of it.
        float3 cityGlow = float3(0.0);
        float street = 0.0;
        if (glow > 0.01 && (gradeSize >= 64.0 || clay)) {
            // Clay has no baked road-density field: an even, slightly pooled sodium wash stands in.
            street = clay ? 0.42 : gradeField.sample(gradeSampler, gradeUV).a;
            if (street > 0.001) {
                float pooling = 0.72 + 0.28 * dioramaNoise(wp * 0.085 + float2(3.7, -1.3));
                float facing = roofSurface ? 0.28 : (0.55 + 0.45 * saturate(litN.z));
                cityGlow = float3(1.0, 0.42, 0.07) * (street * pooling * facing * glow * 0.52 * (0.7 + 0.3 * ao));
            }
        }
        // Floodlit facades (Apple Maps-style material glow): every wall carries its height above
        // its own base, so towers and landmarks light themselves without per-building keying.
        // A sodium uplight pool at street level fades upward in soft floodlight scallops; tall
        // bodies get an even warm-white wash brightening toward the crown.
        float3 facadeGlow = float3(0.0);
        if (glow > 0.01 && code < 0.5 && in.appearance.z > 50.0 && abs(litN.z) < 0.45) {
            float h = max(0.0, dioramaWallHeight(in.appearance.z));
            float2 tangent = normalize(float2(-litN.y, litN.x) + float2(0.0001, 0.0));
            float along = dot(wp, tangent);
            float scallopFade = exp(-h / 9.0);
            float scallop = 1.0 - scallopFade * 0.55 * (0.5 - 0.5 * cos(along * 1.0471976));
            float uplight = exp(-h / 6.5) * (0.45 + 0.55 * street) * scallop;
            float body = smoothstep(7.0, 26.0, h) * (0.55 + 0.45 * smoothstep(26.0, 90.0, h));
            float3 sodium = float3(1.0, 0.45, 0.10);
            float3 warmWhite = float3(1.0, 0.66, 0.32);
            facadeGlow = (sodium * uplight * 0.85 + warmWhite * body * 0.42) * glow * (0.75 + 0.25 * ao);
        }
        float3 lampLight = pointLight * glow * (0.6 + 0.4 * ao) + cityGlow + facadeGlow;
        light += lampLight;

        float3 color = albedo * light;
        if (facadeWall && facade.glass > 0.001) {
            // Window glass: a cool sky reflection that strengthens at grazing angles, and a sun glint.
            float fresnel = 0.22 + 0.55 * pow(1.0 - saturate(dot(surfaceNormal, view)), 3.0);
            float glint = pow(saturate(dot(facade.normal, normalize(view + u.sunDirection.xyz))), 60.0) * visibility;
            color = mix(color, u.skyColor.rgb * 0.82, facade.glass * fresnel) + u.sunColor.rgb * glint * facade.glass * 0.35;
        }
        float time = u.params.y;

        if (tex > 4.5 && tex < 5.5) {
            // Pool water: bright turquoise with slow caustic shimmer and a soft sky sheen.
            float2 poolPosition = vegetationPosition;
            float caustic = dioramaWaterCaustic(poolPosition, time, dfdx(poolPosition), dfdy(poolPosition));
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
            float2 waterDX = dfdx(waterPosition), waterDY = dfdy(waterPosition);
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
            float breath = sin(time * 1.10 + along) * 0.5 + 0.5;
            float washWidth = max(0.3, u.shoreline.y) * (0.55 + 2.4 * breath);
            float shoreAA = max(0.12, min(1.0, fwidth(shore)));
            float contact = (1.0 - smoothstep(washWidth - shoreAA, washWidth + shoreAA, shore))
                * smoothstep(0.12, 0.80, breath);
            float breaker = smoothstep(0.70, 0.98, swell) * (1.0 - smoothstep(0.8, 9.0, shore));
            // Open water has no wash, breaker or shallows: skip the lace and caustic fields there.
            float foamWeight = (contact * 0.52 + breaker * 0.42) * (1.0 - u.shoreline.z);
            float lace = foamWeight > 0.0 ? dioramaWaterField(waterPosition * 0.62, time * 0.45, waterDX * 0.62, waterDY * 0.62) : 0.0;
            float foam = foamWeight * smoothstep(0.26, 0.74, lace);
            float caustic = shallow > 0.0 && u.shoreline.z < 0.5
                ? dioramaWaterCaustic(waterPosition, time, waterDX, waterDY) * shallow * (1.0 - u.shoreline.z) : 0.0;
            color = body * (ambient * 0.35 + float3(u.tint.w) + u.sunColor.rgb * 0.32);
            color += u.sunColor.rgb * caustic * 0.11;
            color *= 1.0 + dot(slope, float2(0.65, -0.45)) * 0.45;
            color = mix(color, float3(0.78, 0.87, 0.83), foam);
            float fresnelSky = 0.05 + 0.28 * pow(1.0 - saturate(dot(waveNormal, view)), 4.0);
            color = mix(color, u.skyColor.rgb * 0.80, fresnelSky);
            color += pointLight * glow * 0.15 + cityGlow * 0.4 + u.sunColor.rgb * glint * 0.32;
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
        // Rounded clay rim: a soft sky lift on grazing faces reads every form as a smooth solid.
        float rim = pow(1.0 - saturate(dot(n, view)), clay ? 3.0 : 4.0) * (clay ? 0.04 : 0.035);
        color += u.skyColor.rgb * rim;
        // Lamp pools stay warm: the moonlit night grade applies to sky and sun light only.
        float3 lampColor = albedo * lampLight;
        float3 graded = dioramaGrade(max(color - lampColor, float3(0.0)), in.worldPosition, u) + lampColor + facade.emissive;
        return dioramaRevealColor(graded, 1.0, revealAlpha, u);
    }

    /// Stylised (Fenn-style) scenes: every light is already in the vertex colours and the ground
    /// image, so a fragment only samples. No point-light, paint, shadow or occlusion loops; the
    /// preset's sun and sky recolour the baked daylight for dusk and night.
    fragment float4 dioramaStylisedFragment(DioramaVarying in [[stage_in]],
                                            bool isFront [[front_facing]],
                                            constant DioramaUniforms &u [[buffer(0)]],
                                            texture2d<float> groundImage [[texture(2)]]) {
        if (u.shoreline.w > 0.5) {
            float2 uv = (in.worldPosition.xy - u.groundImage.xy) * u.groundImage.zw;
            if (any(uv < float2(0.0)) || any(uv >= float2(1.0))) discard_fragment();
        }
        float code = in.appearance.w;
        float glow = u.params.x;
        float revealCoverage = dioramaRevealCoverage(in.worldPosition, u);
        if (revealCoverage < 0.001) discard_fragment();
        float revealAlpha = dioramaRevealAlpha(in.worldPosition, in.position.xy, revealCoverage, u);
        // The bake stores the day preset; this ratio turns it into the current preset's light.
        float3 scene = (u.sunColor.rgb + u.skyColor.rgb * u.look.x) / float3(1.248, 1.275, 1.28);

        if (code > 4.5 && code < 5.5) {
            float r = length(in.normal.xy);
            if (r > 1.0) discard_fragment();
            float a = pow(1.0 - r, 2.2) * 0.7 + pow(max(0.0, 1.0 - r * 3.0), 2.0) * 0.5;
            return dioramaRevealColor(dioramaSodium(in.color.rgb) * glow, a * min(glow, 1.0), revealAlpha, u);
        }
        if (code > 5.5) { return dioramaRevealColor(in.color.rgb, 1.0, revealAlpha, u); }
        if (code > 3.5) {
            float3 c = in.color.rgb * (0.55 + 0.8 * glow) + float3(0.12, 0.05, 0.0) * glow;
            return dioramaRevealColor(min(c, float3(1.0)), 1.0, revealAlpha, u);
        }
        if (in.appearance.y > 14.5 && in.appearance.y < 15.5) {
            return dioramaRevealColor(in.color.rgb * scene, clamp(in.color.a, 0.025, 0.08), revealAlpha, u);
        }
        float3 albedo = in.color.rgb;
        float tex = in.appearance.y;
        if (tex > 8.5 && tex < 9.5) {
            constexpr sampler groundSampler(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear, max_anisotropy(8));
            float2 guv = (in.worldPosition.xy - u.groundImage.xy) * u.groundImage.zw;
            guv.y = 1.0 - guv.y;
            albedo = groundImage.sample(groundSampler, guv).rgb;
        }
        float3 view = normalize(u.eye.xyz - in.worldPosition);
        if (code > 0.5 && code < 1.5) {
            float shore = max(0.0, in.appearance.z);
            float shallow = 1.0 - smoothstep(0.0, max(1.0, u.shoreline.x), shore);
            float3 body = mix(u.waterDeep.rgb, u.waterShallow.rgb, shallow);
            float ripple = sin(dot(in.worldPosition.xy, float2(0.31, 0.19)) + u.params.y * 1.1) * sin(dot(in.worldPosition.xy, float2(-0.13, 0.27)) - u.params.y * 0.7);
            float3 color = body * (0.55 + u.tint.w) * scene * (1.0 + 0.05 * ripple);
            float fresnel = 0.05 + 0.25 * pow(1.0 - saturate(view.z), 4.0);
            color = mix(color, u.skyColor.rgb * 0.8, fresnel);
            return dioramaRevealColor(dioramaGrade(color, in.worldPosition, u), mix(1.0, 0.6, shallow), revealAlpha, u);
        }
        float3 n = normalize(in.normal);
        if (!isFront) n = -n;
        float3 color = albedo * scene;
        if (tex > 5.5 && tex < 6.5) {
            float fresnel = 0.08 + 0.3 * pow(1.0 - saturate(dot(n, view)), 4.0);
            color = mix(color, u.skyColor.rgb * 0.8, fresnel);
        }
        color += u.skyColor.rgb * pow(1.0 - saturate(dot(n, view)), 4.0) * 0.03;
        return dioramaRevealColor(dioramaGrade(color, in.worldPosition, u), 1.0, revealAlpha, u);
    }
    """

    /// Shared colour grade: a unifying warm-violet tint plus light distance haze towards the sky colour.
    static let gradeSource: String = """
    float3 dioramaGrade(float3 color, float3 worldPosition, constant DioramaUniforms &u) {
        // Stylised grade: vibrance (muted colours gain most, saturated ones do not clip), a gentle
        // S-curve around mid-grey, then the preset tint/exposure. Night uses vibrance < 1.
        float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
        float chroma = max(color.r, max(color.g, color.b)) - min(color.r, min(color.g, color.b));
        float vibrance = u.look.z > 1.0 ? 1.0 + (u.look.z - 1.0) * (1.25 - chroma) : u.look.z;
        color = max(float3(0.0), mix(float3(luminance), color, vibrance));
        float3 curved = color * color * (3.0 - 2.0 * min(color, float3(1.0)));
        color = max(float3(0.0), mix(color, mix(color, curved, 0.5), saturate(u.style.x - 1.0) * 4.0));
        color *= u.tint.rgb * max(u.style.y, 0.5);
        float d = length(u.eye.xyz - worldPosition);
        float haze = 1.0 - exp(-d * u.post.w);
        return mix(color, u.hazeTone.rgb, haze * u.hazeTone.w);
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

    /// Bloom sources are selective: street lamps, lanterns, halos and landmark signage always glow;
    /// window light only blooms on bespoke landmarks (appearance.y 1), on about a third of skyline
    /// towers (2) and on one ordinary building in ten, chosen per ~24 m block so a lit building glows
    /// as a whole. Everything else keeps its emissive colour in the main pass without a halo.
    fragment DioramaGBuffer dioramaEmissiveFragment(DioramaVarying in [[stage_in]], constant DioramaUniforms &u [[buffer(0)]],
                                                    constant float &windowSelection [[buffer(1)]]) {
        DioramaGBuffer out;
        dioramaRevealClip(in.worldPosition, u);
        float code = in.appearance.w;
        float glow = u.params.x;
        float3 c = in.color.rgb;
        float a = 1.0;
        float energy = 1.7;
        if (code > 4.5 && code < 5.5) {
            float r = length(in.normal.xy);
            if (r > 1.0) discard_fragment();
            a = pow(1.0 - r, 2.2) * 0.9;
            c = dioramaSodium(c) * 1.2;
        } else if (windowSelection > 0.5) {
            float kind = in.appearance.y;
            float2 block = floor(in.worldPosition.xy / 24.0);
            float pick = fract(sin(dot(block, float2(12.9898, 78.233))) * 43758.5453);
            float share = kind > 1.5 ? 0.34 : (kind > 0.5 ? 1.0 : 0.10);
            if (pick >= share) discard_fragment();
            energy = kind > 0.5 && kind < 1.5 ? 1.5 : 1.1;
        }
        out.position = float4(0.0);
        out.normal = float4(0.0);
        // HDR radiance survives the blur; a soft knee keeps dim surfaces from haloing at all.
        float3 radiance = c * glow * a * energy;
        float peak = max(radiance.r, max(radiance.g, radiance.b));
        radiance *= saturate((peak - 0.35) / max(peak, 1e-4) * 1.6);
        out.emissive = float4(radiance * dioramaRevealCoverage(in.worldPosition, u), 1.0);
        return out;
    }

    struct DioramaScreen {
        float4 position [[position]];
        float2 uv;
    };

    /// Low-frequency ground grade fields over the renderer's ground rectangle (texel centres), using
    /// exactly the live expressions in dioramaFragment: broad moisture, lawn patches, asphalt weathering.
    /// Alpha: street-light density, the weighted share of painted asphalt (grain code 3) within ~22 m,
    /// read from the level-0 categorical alpha (never a mip, which would average IDs).
    fragment float4 dioramaGradeBakeFragment(DioramaScreen in [[stage_in]], constant DioramaUniforms &u [[buffer(0)]],
                                             const device DioramaPaintTriangle *paint [[buffer(1)]],
                                             const device uint2 *paintTable [[buffer(2)]],
                                             const device uint *paintIndices [[buffer(3)]],
                                             texture2d<float> groundImage [[texture(0)]]) {
        float2 wp = u.groundImage.xy + in.uv / u.groundImage.zw;
        float2 v = wp * u.materialFrame.z + u.materialFrame.xy;
        float2 patchPosition = float2(dot(v, float2(0.80, -0.60)), dot(v, float2(0.60, 0.80)));
        float street = 0.0;
        if (groundImage.get_width() > 64) {
            constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
            float total = 0.0;
            const float radii[4] = { 0.0, 6.0, 13.0, 22.0 };
            const float weights[4] = { 2.0, 1.2, 0.8, 0.4 };
            for (int ring = 0; ring < 4; ++ring) {
                int taps = ring == 0 ? 1 : 8;
                for (int k = 0; k < taps; ++k) {
                    float angle = (float(k) + 0.5 * float(ring & 1)) * 0.78539816;
                    float2 q = wp + radii[ring] * float2(cos(angle), sin(angle));
                    float2 guv = (q - u.groundImage.xy) * u.groundImage.zw;
                    guv.y = 1.0 - guv.y;
                    float rasterByte = floor(groundImage.sample(nearestSampler, guv, level(0.0)).a * 255.0 + 0.5);
                    float id = u.materialFrame.w > 1.5
                        ? dioramaHybridCode(paint, paintTable, paintIndices, q, u.groundImage, rasterByte)
                        : floor(rasterByte / 32.0);
                    street += (id == 3.0 ? 1.0 : 0.0) * weights[ring];
                    total += weights[ring];
                }
            }
            street = smoothstep(0.04, 0.42, street / total);
        }
        return float4(dioramaNoise(v * 0.027 + float2(11.4, -7.2)),
                      dioramaNoise(patchPosition * 0.105 + float2(-4.1, 19.7)),
                      dioramaNoise(v * 0.055 + float2(8.2, 13.9)), street);
    }

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
        // Where the occlusion radius projects under ~0.6 of this target's texels the contact shadow
        // cannot be resolved: skip the twelve dependent samples.
        float4 c0 = p.matrix * float4(P.xyz, 1.0);
        float4 c1 = p.matrix * float4(P.xyz + t * radius, 1.0);
        if (c0.w > 0.0001 && c1.w > 0.0001) {
            float2 reach = (c1.xy / c1.w - c0.xy / c0.w) * 0.5 * p.params.zw;
            if (dot(reach, reach) < 0.36) return float4(1.0);
        }
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
    static var fullSource: String { source + gradeSource + postSource + DioramaProjectedShadow.source }

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
