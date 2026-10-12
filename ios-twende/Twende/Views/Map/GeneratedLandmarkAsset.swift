import Foundation
import simd

/// Authoring-calibrated bundled assets; unverified placements never replace a native building.
nonisolated struct GeneratedLandmarkAsset: Decodable, Identifiable {
    let id: String
    let resource: String
    let modelID: String
    let conceptURL: String
    let localFrontAxis: String?
    let localUpAxis: String
    let frontBearing: Double
    let targetHeight: Double
    let placementApproved: Bool

    @MainActor static let all: [GeneratedLandmarkAsset] = {
        guard let url = Bundle.main.url(forResource: "generated_landmarks", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([GeneratedLandmarkAsset].self, from: data) else { return [] }
        return records.filter { !$0.id.isEmpty && !$0.resource.contains("/")
            && $0.frontBearing.isFinite && $0.targetHeight.isFinite
            && $0.targetHeight > 0 && $0.targetHeight < 500 }
    }()

    static func axis(_ value: String) -> SIMD3<Float>? {
        switch value {
        case "positiveX": SIMD3(1, 0, 0)
        case "negativeX": SIMD3(-1, 0, 0)
        case "positiveY": SIMD3(0, 1, 0)
        case "negativeY": SIMD3(0, -1, 0)
        case "positiveZ": SIMD3(0, 0, 1)
        case "negativeZ": SIMD3(0, 0, -1)
        default: nil
        }
    }
}
