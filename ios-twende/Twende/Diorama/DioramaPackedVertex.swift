import Foundation
import simd

/// 32-byte GPU vertex (half of `BuildingRenderVertex`). Mirrors `DioramaPackedInput` in Metal.
/// position.w carries appearance.z (full float: wall height / shore distance / coverage);
/// normal.w carries appearance.w and color.w appearance.y (small integer codes, exact in half).
/// appearance.x is not read by the diorama shaders and is dropped.
nonisolated struct DioramaPackedVertex: Sendable {
    var position: SIMD4<Float>
    var normal: SIMD4<UInt16>
    var color: SIMD4<UInt16>

    init(_ v: BuildingRenderVertex) {
        position = SIMD4(v.position.x, v.position.y, v.position.z, v.appearance.z)
        normal = SIMD4(DioramaHalf.bits(v.normal.x), DioramaHalf.bits(v.normal.y), DioramaHalf.bits(v.normal.z), DioramaHalf.bits(v.appearance.w))
        color = SIMD4(DioramaHalf.bits(v.color.x), DioramaHalf.bits(v.color.y), DioramaHalf.bits(v.color.z), DioramaHalf.bits(v.appearance.y))
    }

    static let empty = DioramaPackedVertex(BuildingRenderVertex(position: SIMD4(0, 0, 0, 1), normal: SIMD4(0, 0, 1, 0), color: SIMD4(1, 1, 1, 1), appearance: .zero))
}

/// IEEE 754 binary16 conversion without relying on `Float16` (unavailable on x86_64 simulators).
nonisolated enum DioramaHalf {
    static func float(_ h: UInt16) -> Float {
        let negative = h & 0x8000 != 0
        let exponent = Int((h >> 10) & 0x1F)
        let mantissa = UInt32(h & 0x3FF)
        let value: Float
        if exponent == 0 { value = Float(mantissa) * 0x1p-24 }
        else if exponent == 31 { value = mantissa == 0 ? .infinity : .nan }
        else { value = Float(bitPattern: (UInt32(exponent - 15 + 127) << 23) | (mantissa << 13)) }
        return negative ? -value : value
    }
    static func bits(_ f: Float) -> UInt16 {
        let x = f.bitPattern
        let sign = UInt16((x >> 16) & 0x8000)
        if (x & 0x7FFF_FFFF) > 0x7F80_0000 { return sign | 0x7E00 }
        let exponent = Int((x >> 23) & 0xFF) - 127 + 15
        var mantissa = x & 0x7F_FFFF
        if exponent >= 31 { return sign | 0x7C00 }
        if exponent <= 0 {
            if exponent < -10 { return sign }
            mantissa |= 0x80_0000
            let shift = UInt32(14 - exponent)
            var h = mantissa >> shift
            let remainder = mantissa & ((1 << shift) - 1), halfway = UInt32(1) << (shift - 1)
            if remainder > halfway || (remainder == halfway && (h & 1) != 0) { h += 1 }
            return sign | UInt16(h)
        }
        var h = (UInt32(exponent) << 10) | (mantissa >> 13)
        let remainder = mantissa & 0x1FFF
        if remainder > 0x1000 || (remainder == 0x1000 && (h & 1) != 0) { h += 1 }
        return sign | UInt16(min(h, 0x7C00))
    }
}
