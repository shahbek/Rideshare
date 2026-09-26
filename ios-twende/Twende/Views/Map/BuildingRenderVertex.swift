import simd

/// Aligned GPU layout shared with BuildingMap.metal. Appearance.w marks optional window detail.
nonisolated struct BuildingRenderVertex {
    let position: SIMD4<Float>
    let normal: SIMD4<Float>
    let color: SIMD4<Float>
    let appearance: SIMD4<Float>
}
