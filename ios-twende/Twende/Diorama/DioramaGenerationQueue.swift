import Foundation

/// Only one CPU-heavy mesh build may run at a time, even if a camera move cancels its caller.
/// This prevents overlapping city builds multiplying temporary geometry memory.
actor DioramaGenerationQueue {
    static let shared = DioramaGenerationQueue()

    func generateContext(_ data: DioramaTileData, config: DioramaConfig) throws -> DioramaTileArtifacts {
        try Task.checkCancellation()
        return try DioramaContextGenerator.generate(data, config: config)
    }

    func generate(_ data: DioramaTileData, config: DioramaConfig) throws -> DioramaTileArtifacts {
        try Task.checkCancellation()
        let library = DioramaPropLibrary(config: config)
        return try DioramaTileGenerator.generate(data, config: config, library: library, reduced: false)
    }
}
