import Foundation
import SwiftUI

/// One digital billboard slot on the map and the advert currently booked on it. Swapping the
/// advertiser is a data change: new video resource, copy and branch list.
nonisolated struct BillboardAd: Identifiable, Hashable, Sendable {
    let id: String
    let advertiser: String
    let headline: LKey
    let offer: LKey
    /// Bundled MP4 resource name (no extension).
    let videoResource: String
    let branches: [Place]
    /// Map site of the billboard structure.
    let site: GeoPoint
    /// Direction the front screen faces, in degrees clockwise from north.
    let facingDegrees: Double
    /// Advertiser brand colour (24-bit hex) for the map marker tile.
    var brandHex: UInt32 = 0x222222

    var brandColor: Color { Color(hex: brandHex) }

    /// Branch closest to `point`.
    func nearestBranch(to point: GeoPoint) -> Place? {
        branches.min { $0.point.distanceKm(to: point) < $1.point.distanceKm(to: point) }
    }
}

/// Booked inventory. Morocco junction (Ali Hassan Mwinyi × Kawawa × New Bagamoyo), north-east corner,
/// screen facing south-west over the traffic lights. Signal nodes from OSM 252496840 / 282890751.
nonisolated enum BillboardCatalogue {
    static let moroccoKFC = BillboardAd(
        id: "kfc-morocco",
        advertiser: "KFC",
        headline: .adKfcHeadline,
        offer: .adKfcOffer,
        videoResource: "kfc_crispy_chicken_deal",
        branches: [
            Place(id: "kfc-haile-selassie", name: "KFC Haile Selassie", address: "Haile Selassie Road, Msasani", point: GeoPoint(latitude: -6.7643773, longitude: 39.2749616)),
            Place(id: "kfc-kiko", name: "KFC Msasani", address: "Kiko Avenue, Msasani", point: GeoPoint(latitude: -6.7632044, longitude: 39.2567593)),
            Place(id: "kfc-mwai-kibaki", name: "KFC Mikocheni", address: "Mwai Kibaki Road, Mikocheni", point: GeoPoint(latitude: -6.7552275, longitude: 39.2455469)),
            Place(id: "kfc-samora", name: "KFC Posta", address: "Samora Avenue, Posta Mpya", point: GeoPoint(latitude: -6.8139923, longitude: 39.2923554)),
            Place(id: "kfc-livingstone", name: "KFC Kariakoo", address: "Livingstone Street, Jangwani", point: GeoPoint(latitude: -6.8142842, longitude: 39.2757168)),
        ],
        site: GeoPoint(latitude: -6.776905, longitude: 39.264085),
        facingDegrees: 205,
        brandHex: 0xE4002B
    )

    static let all: [BillboardAd] = [moroccoKFC]

    static func ad(id: String) -> BillboardAd? { all.first { $0.id == id } }
}
