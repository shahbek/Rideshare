import Foundation

nonisolated struct DarLandmarkCatalog: Decodable {
    let sites: [DarLandmarkSite]
}
