import Foundation

/// Deterministic pseudo-random source so mock routes and IDs are stable across launches.
nonisolated struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    /// Uniform value in `-1...1`.
    mutating func signedUnit() -> Double {
        Double(next() % 20_001) / 10_000.0 - 1.0
    }
}
