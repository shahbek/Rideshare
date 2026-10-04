import Foundation

/// Every colour the diorama may use. The palette atlas holds each swatch twice: the base colour and a
/// darker "ambient occlusion" copy used on the lowest band of walls.
nonisolated enum DioramaSwatch: Int, CaseIterable, Sendable {
    // Plaster walls
    case whitewash, cream, ochre, sunflower, coral, skyBlue, mint, terracottaWall
    // Roofs
    case roofTeal, roofRust, roofSlate, roofGreen, roofTerracotta, roofConcrete
    // Trim, caps and openings
    case trimWhite, capTerracotta, capCharcoal, glass, frame, shutterGreen, shutterBlue, doorWood, carvedWood
    case metalCharcoal, gateGreen, gateBlue
    // Roof furniture
    case tankBlack, tankBlue, dishWhite, solarNavy
    // Ground
    case grass, courtyard, deck
    // Vegetation
    case leafDark, leafMid, leafLight, flamboyant, trunk, palmTrunk, bougainvilleaMagenta, bougainvilleaOrange, coconut
    // Vehicles, boats and stalls
    case bajajiBlue, bajajiRed, bajajiYellow, tyre, dalaWhite, signRed, signYellow, signGreen, signBlue, signOrange
    case carSilver, carRed, carWhite, hullWood, deckWood, sailCream
    case canopyRed, canopyYellow, canopyBlue, canopyGreen, lampPole
    // Emissive (night) colours
    case windowGlow, lampGlow, kioskGlow, shopGlow

    /// Fixed Masaki palette. Never random RGB.
    static let defaultPalette: [DioramaSwatch: UInt32] = [
        .whitewash: 0xF3EFE6, .cream: 0xF0E0BC, .ochre: 0xD69A4E, .sunflower: 0xF0BE45,
        .coral: 0xEE8668, .skyBlue: 0x86BFE0, .mint: 0x98D3B8, .terracottaWall: 0xC76C48,
        .roofTeal: 0x2F8C88, .roofRust: 0xA9472E, .roofSlate: 0x4F6B8C, .roofGreen: 0x3F7D4A,
        .roofTerracotta: 0xC0603C, .roofConcrete: 0xD8CDB8,
        .trimWhite: 0xFAF7F0, .capTerracotta: 0xB5573A, .capCharcoal: 0x3B3A3D, .glass: 0x2C3440,
        .frame: 0xE9E4DA, .shutterGreen: 0x3E7A5A, .shutterBlue: 0x3C6E9E, .doorWood: 0x6B4126,
        .carvedWood: 0x4E2E1A, .metalCharcoal: 0x2E2F33, .gateGreen: 0x2F5E46, .gateBlue: 0x2D5785,
        .tankBlack: 0x232427, .tankBlue: 0x2B5FA8, .dishWhite: 0xECECEC, .solarNavy: 0x1F2E4E,
        .grass: 0x6E9E4B, .courtyard: 0xE2D6C0, .deck: 0xB98E62,
        .leafDark: 0x2F5E2E, .leafMid: 0x4C8A3A, .leafLight: 0x7DAF4A, .flamboyant: 0xE2502A,
        .trunk: 0x6D4C35, .palmTrunk: 0x8C7458, .bougainvilleaMagenta: 0xC8337E,
        .bougainvilleaOrange: 0xF07C3A, .coconut: 0x7A5A2C,
        .bajajiBlue: 0x2E6FBF, .bajajiRed: 0xC83A32, .bajajiYellow: 0xF2C230, .tyre: 0x1E1E20,
        .dalaWhite: 0xF4F2EC, .signRed: 0xD8392B, .signYellow: 0xF4C430, .signGreen: 0x2E9B57,
        .signBlue: 0x2D6CC0, .signOrange: 0xF08A24, .carSilver: 0xB8BEC6, .carRed: 0xB93A33,
        .carWhite: 0xEDEDE8, .hullWood: 0x7A4E2C, .deckWood: 0xB48A5E, .sailCream: 0xF2E8D2,
        .canopyRed: 0xD9443A, .canopyYellow: 0xF2B630, .canopyBlue: 0x2F7EC4, .canopyGreen: 0x3E9A5C,
        .lampPole: 0x3A3B40,
        .windowGlow: 0xFFB548, .lampGlow: 0xFFE3A6, .kioskGlow: 0xFFC870, .shopGlow: 0xFFD08A,
    ]
}

/// The separately toggleable models each tile is split into.
nonisolated enum DioramaCategory: String, CaseIterable, Codable, Sendable {
    case buildings, walls, ground, vegetation, props, windowGlow, propGlow

    /// Emissive categories use their own glTF material and glow by the layer's emissive strength.
    var isEmissive: Bool { self == .windowGlow || self == .propGlow }
}

nonisolated enum DioramaTimeOfDay: String, CaseIterable, Identifiable, Sendable {
    case day, dusk, night
    var id: String { rawValue }
    /// Mapbox Standard `lightPreset` value.
    var lightPreset: String { rawValue }
    var emissiveStrength: Double {
        switch self {
        case .day: 0
        case .dusk: 0.85
        case .night: 1
        }
    }
    var showsLights: Bool { self != .day }
}

/// One place to tune the whole look without touching generation code.
nonisolated struct DioramaConfig: Sendable {
    /// Bump to invalidate every cached .glb.
    var generatorVersion: Int = 2

    // MARK: Tiles
    var tileZoom: Int = 16
    var minimumZoom: Double = 16
    /// North Masaki: residential streets with the Sea Cliff shoreline in the tile's north-east corner.
    var seedLatitude: Double = -6.7440
    var seedLongitude: Double = 39.2850
    /// The diorama is deliberately tiny: one z16 tile (about 600 m across) around the seed.
    var maxLoadedTiles: Int = 1
    var bufferTiles: Int = 0
    /// Tiles may only be generated within this many z16 tiles of the seed; outside it the map is plain Standard.
    var areaRadiusTiles: Int = 0
    /// The seed tile stays loaded while the camera centre is within this many tiles of it.
    var visibilityRadiusTiles: Int = 2
    /// How many tiles may generate geometry at the same time.
    var maxConcurrentGenerations: Int = 1
    /// Upper bounds that keep one tile's query, conversion and mesh size predictable.
    var maxQueriedFeatures: Int = 6_000
    var maxBuildingsPerTile: Int = 450
    var maxRoadsPerTile: Int = 160

    // MARK: Camera
    var cameraZoom: Double = 16.8
    var cameraPitch: Double = 58
    /// Looks north-east so the shoreline sits in the upper part of the frame.
    var cameraBearing: Double = 52

    // MARK: Buildings
    var floorHeight: Double = 3.2
    /// Mapbox fills unknown heights with ~3 m; anything at or below this counts as missing.
    var placeholderHeight: Double = 3.1
    var bevel: Double = 0.22
    var aoBandHeight: Double = 0.55
    var aoDarkening: Double = 0.7
    var roofOverhang: Double = 0.7
    var roofPitchDegrees: Double = 24
    var hipRoofShare: Double = 0.78
    var terracottaRoofShare: Double = 0.3
    var windowSpacing: Double = 3.1
    var maxWindowsPerBuilding: Int = 40
    var litWindowRatio: Double = 0.7
    var verandaChance: Double = 0.6
    var swahiliTouchChance: Double = 0.3
    var standTankChance: Double = 0.55
    var dishChance: Double = 0.3
    var solarChance: Double = 0.25

    // MARK: Compound walls
    var wallOffset: ClosedRange<Double> = 5...10
    var wallHeight: Double = 2.2
    var wallThickness: Double = 0.25
    var capThickness: Double = 0.12
    var gateWidth: Double = 3.2
    var guardHutChance: Double = 0.25
    var bougainvilleaChancePerMetre: Double = 0.07

    // MARK: Vegetation
    var treesPer1000m2: Double = 7
    var parkTreesPer1000m2: Double = 10
    var coastPalmSpacing: Double = 13

    // MARK: Props
    var vehiclesPerKm: Double = 16
    var lampSpacing: Double = 38
    var kioskChance: Double = 0.45
    var dhowsPerTile: Int = 4

    // MARK: Palette
    var palette: [DioramaSwatch: UInt32] = DioramaSwatch.defaultPalette
    var wallColors: [DioramaSwatch] = [.whitewash, .cream, .ochre, .sunflower, .coral, .skyBlue, .mint, .terracottaWall]
    var apartmentWallColors: [DioramaSwatch] = [.whitewash, .whitewash, .cream]
    var apartmentAccents: [DioramaSwatch] = [.terracottaWall, .skyBlue, .mint, .sunflower, .coral]
    var metalRoofColors: [DioramaSwatch] = [.roofTeal, .roofRust, .roofSlate, .roofGreen]
    var signColors: [DioramaSwatch] = [.signRed, .signYellow, .signGreen, .signBlue, .signOrange]
    var canopyColors: [DioramaSwatch] = [.canopyRed, .canopyYellow, .canopyBlue, .canopyGreen]

    // MARK: Map styling (Mapbox layers)
    var sandColor: String = "#E8D5AE"
    var waterDeepColor: String = "#17707A"
    var waterShallowColor: String = "#3CC4C0"
    var shoreSandColor: String = "#F3E4C2"
    var parkColor: String = "#7FA65A"
    var asphaltColor: String = "#4B3E4A"
    var shoulderColor: String = "#D9BD8A"
    var earthRoadColor: String = "#B9653A"
    var roadLabelColor: String = "#4A2F1F"
    var roadLabelHalo: String = "#FFF4DE"

    static let masaki = DioramaConfig()
}
