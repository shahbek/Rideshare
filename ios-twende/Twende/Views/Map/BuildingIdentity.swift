@_spi(Experimental) import MapboxMaps
import SceneKit

/// Stable procedural identity, independent of camera, ring winding and process-randomised hashing.
struct BuildingIdentity {
    enum Order: Int, CaseIterable { case doric, ionic, corinthian, roman, domed, gallery, vaulted, terraced }
    let seed: UInt64
    var order: Order { Order(rawValue: Int(seed % 8)) ?? .roman }
    var paletteIndex: Int { Int((seed >> 8) % UInt64(Self.colors.count)) }
    var rhythm: Double { 0.88 + Double((seed >> 20) % 25) / 100 }
    static let colors = ["#FAF9F4", "#ECE6D8", "#F3E5D2", "#BE735C", "#E1E3DF", "#E0C9A8", "#EBC9B5", "#CFD4D0", "#F2EEDF", "#F0D2B9", "#D4B18E", "#BD8069", "#A56753", "#989B96", "#E0D1BA", "#EFEBE1"]
    static let pitchedRoofs = ["#AD583D", "#BC6C49", "#7B493A"]
    static let metalRoofs = ["#81847E", "#68796D", "#4C504F"]
    static let glassColors = ["#52646A", "#64736E", "#53605D"]
    static let shutterColors = ["#536455", "#6B4E3A", "#4A555A"]
    var detailVariant: Int { Int((seed >> 36) % 4) }
    var trimHex: String { ["#F5F8FA", "#EEE9DF", "#F4F5F1"][paletteIndex % 3] }
    var tileHex: String { Self.pitchedRoofs[Int((seed >> 16) % 3)] }
    var metalHex: String { Self.metalRoofs[Int((seed >> 18) % 3)] }

    /// Independent, repeatable channels: changing the roof choice does not reshuffle colours.
    func variant(channel: UInt64, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var value = (seed & ~UInt64(7)) &+ (channel &* 0x9E3779B97F4A7C15)
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return Int((value ^ (value >> 31)) % UInt64(count))
    }

    func withOrder(_ order: Order) -> BuildingIdentity {
        BuildingIdentity(seed: (seed & ~UInt64(7)) | UInt64(order.rawValue))
    }

    init(seed: UInt64) { self.seed = seed }
    init(geometry: Geometry) {
        let points: [LocationCoordinate2D]
        switch geometry {
        case .polygon(let p): points = p.coordinates.first ?? []
        case .multiPolygon(let p): points = p.coordinates.flatMap { $0.first ?? [] }
        default: points = []
        }
        let valid = points.filter { $0.latitude.isFinite && $0.longitude.isFinite && abs($0.latitude) <= 90 && abs($0.longitude) <= 180 }
        let x = ((valid.map(\.longitude).min() ?? 0) + (valid.map(\.longitude).max() ?? 0)) / 2
        let y = ((valid.map(\.latitude).min() ?? 0) + (valid.map(\.latitude).max() ?? 0)) / 2
        self.seed = Self.hash("\(Int64((x * 100_000).rounded())):\(Int64((y * 100_000).rounded()))")
    }
    static func hash(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
    var wallHex: String { Self.colors[paletteIndex] }
    var roofHex: String {
        switch order {
        case .doric, .ionic, .corinthian: tileHex
        case .domed, .vaulted: metalHex
        default: "#B7B0A2"
        }
    }
    func material(_ role: String) -> SCNMaterial {
        let hex: String
        switch role {
        case "roof": hex = roofHex
        case "tile": hex = tileHex
        case "metal": hex = metalHex
        case "terrace": hex = "#B7B0A2"
        case "slate": hex = "#4C504F"
        case "base": hex = ["#AAA394", "#B5A38D", "#AAA69B", "#B49E8A"][variant(channel: 4, count: 4)]
        case "recess": hex = ["#847E73", "#8B8274", "#777A74"][variant(channel: 5, count: 3)]
        case "trim": hex = trimHex
        case "shutter": hex = Self.shutterColors[Int((seed >> 24) % 3)]
        case "iron": hex = "#3E4441"
        case "glass": hex = Self.glassColors[Int((seed >> 22) % 3)]
        case "curtainGlass": hex = ["#7DBADD", "#93CEDF", "#B2DDE5"][variant(channel: 11, count: 3)]
        case "lawn": hex = "#75A957"
        case "timber": hex = "#9B7453"
        default: hex = wallHex
        }
        let material = BuildingSurfaces.make("identity.\(role)", color: hex, roughness: role == "glass" ? 0.40 : 0.85, metalness: role == "glass" ? 0.08 : 0)
        if role == "wall" {
            if [3, 10, 11, 12].contains(paletteIndex) { material.name = "surface.brick" }
            else if [1, 5, 7, 14].contains(paletteIndex) { material.name = "surface.stone" }
        } else if role == "timber" || role == "shutter" { material.name = "surface.timber" }
        return material
    }
}
