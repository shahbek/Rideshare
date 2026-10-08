import Foundation

/// Every colour the diorama may use. The palette atlas holds each swatch twice: the base colour and a
/// darker "ambient occlusion" copy used on the lowest band of walls.
nonisolated enum DioramaSwatch: Int, CaseIterable, Sendable {
    // Plaster walls
    case whitewash, cream, ochre, sunflower, coral, skyBlue, mint, terracottaWall
    case brick, sage, dustyRose, slateWall, paleYellow, slipwayBlue
    case hotelTeal, deltaStone, muralBlue, tileClay, coralStone
    // Roofs
    case roofTeal, roofRust, roofSlate, roofGreen, roofTerracotta, roofConcrete
    // Trim, caps and openings
    case trimWhite, capTerracotta, capCharcoal, glass, frame, shutterGreen, shutterBlue, doorWood, carvedWood
    case metalCharcoal, gateGreen, gateBlue
    // Roof furniture
    case tankBlack, tankBlue, dishWhite, solarNavy
    // Ground, roads and water (`painted` samples the tile's ground image instead of a palette colour)
    case grass, courtyard, deck, earth, seabed, sea, painted
    case wetSand, dampStone, algaeStone, rockWarm, rockGrey, rockPale, seaweed
    case asphalt, roadEarth, pavement, kerb, marking, crossing, parkEdge
    case stopRed, signPost
    // Landscaping
    case hedge, leafOlive, leafBright, cypress, flowerPink, flowerYellow, flowerRed, flowerWhite, soil
    // Amenities: lawns, pitches, paving, courts, pools, piers, play equipment
    case lawn, pitchGreen, paving, concrete, courtBlue, courtLine, poolBlue, poolCoping, pierWood, glassPale
    case goalWhite, mastGrey, rubberRed, bronze, domeGreen
    // Vegetation
    case leafDark, leafMid, leafLight, flamboyant, trunk, palmTrunk, bougainvilleaMagenta, bougainvilleaOrange, coconut
    // Vehicles, boats and stalls
    case bajajiBlue, bajajiRed, bajajiYellow, tyre, dalaWhite, signRed, signYellow, signGreen, signBlue, signOrange
    case carSilver, carRed, carWhite, hullWood, deckWood, sailCream
    case canopyRed, canopyYellow, canopyBlue, canopyGreen, lampPole
    // Emissive (night) colours
    case windowGlow, lampGlow, kioskGlow, shopGlow
    case naturalEarth, seaCliffRoof

    /// Fixed palette. Never random RGB.
    static let defaultPalette: [DioramaSwatch: UInt32] = [
        .whitewash: 0xF4EFE7, .cream: 0xF1E2C4, .ochre: 0xD8A46A, .sunflower: 0xF0C46A,
        .coral: 0xE8A08C, .skyBlue: 0x9FC4DD, .mint: 0xA9D4BC, .terracottaWall: 0xB9674C,
        .brick: 0xB4624A, .sage: 0xB9C7A6, .dustyRose: 0xE2B4A6, .slateWall: 0x8E9BB3, .paleYellow: 0xF2DDA4, .slipwayBlue: 0x8DBFD6,
        .hotelTeal: 0x418D98, .deltaStone: 0xB7B6AC, .muralBlue: 0x216391,
        .tileClay: 0x7E2F2B, .coralStone: 0xB6A485,
        .roofTeal: 0x3A7F8C, .roofRust: 0xA9472E, .roofSlate: 0x4A5E8E, .roofGreen: 0x3F7D4A,
        .roofTerracotta: 0xC0603C, .roofConcrete: 0xC9C2B6,
        .trimWhite: 0xFAF7F0, .capTerracotta: 0xB5573A, .capCharcoal: 0x3B3A3D, .glass: 0x2C3440,
        .frame: 0xE9E4DA, .shutterGreen: 0x3E7A5A, .shutterBlue: 0x3C6E9E, .doorWood: 0x6B4126,
        .carvedWood: 0x4E2E1A, .metalCharcoal: 0x2E2F33, .gateGreen: 0x2F5E46, .gateBlue: 0x2D5785,
        .tankBlack: 0x232427, .tankBlue: 0x2B5FA8, .dishWhite: 0xECECEC, .solarNavy: 0x1F2E4E,
        .grass: 0x83AD32, .courtyard: 0xE7D9C6, .deck: 0xB98E62, .earth: 0xE3D3B2, .seabed: 0xB7A77F, .sea: 0x2E8FA3, .painted: 0xFFFFFF,
        .naturalEarth: 0xB3987A, .seaCliffRoof: 0x665A55,
        .wetSand: 0xB7A77F, .dampStone: 0x817866, .algaeStone: 0x667B62,
        .rockWarm: 0xB6A485, .rockGrey: 0x8E9188, .rockPale: 0xC9C2B6, .seaweed: 0x6B7352,
        .asphalt: 0x5C4A58, .roadEarth: 0xC19466, .pavement: 0xEBDCD2, .kerb: 0xF6EFE8, .marking: 0xFAF4E8, .crossing: 0xFFFBF2, .parkEdge: 0xD9CBB4,
        .stopRed: 0xC8352E, .signPost: 0x8A8F96,
        .hedge: 0x608D2D, .leafOlive: 0x728C32, .leafBright: 0xA0C143, .cypress: 0x3B7042,
        .flowerPink: 0xE86FA8, .flowerYellow: 0xF4CC45, .flowerRed: 0xE0453A, .flowerWhite: 0xFBF6EC, .soil: 0x7A5A42,
        .lawn: 0x94BC3B, .pitchGreen: 0x5FA24A, .paving: 0xD9CFC0, .concrete: 0xC9C2B6, .courtBlue: 0x2F6FB5, .courtLine: 0xF7F7F2,
        .poolBlue: 0x4FC3D9, .poolCoping: 0xF2EEE6, .pierWood: 0xA67B4F, .glassPale: 0xBFD9E6,
        .goalWhite: 0xFAFAFA, .mastGrey: 0x9DA3AA, .rubberRed: 0xC8584A, .bronze: 0x7A5A33, .domeGreen: 0x2F8F5B,
        .leafDark: 0x426522, .leafMid: 0x79A42E, .leafLight: 0xA8CA49, .flamboyant: 0xE2502A,
        .trunk: 0x805033, .palmTrunk: 0x8C7458, .bougainvilleaMagenta: 0xC8337E,
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
    case ground, water, roads, buildings, walls, vegetation, props, windowGlow, propGlow, shorelineDebug

    /// Emissive categories are drawn unlit and only at dusk/night.
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
    /// Index used by the shader to pick its sky/sun preset.
    var shaderIndex: Float {
        switch self {
        case .day: 0
        case .dusk: 1
        case .night: 2
        }
    }
}

/// A real light source the shader evaluates per pixel: a lamp head, a lit kiosk, a doorway.
nonisolated struct DioramaLight: Sendable {
    var position: DV3
    var color: SIMD3<Float>
    var radius: Double
    var intensity: Float
}

/// Hand-tuned materials for secondary mapped buildings. Bespoke hotels bypass these generic rules.
/// Keyed by OSM way id.
nonisolated struct DioramaBuildingOverride: Sendable {
    var wallColor: DioramaSwatch? = nil
    var roofColor: DioramaSwatch? = nil
    /// nil keeps the generator's own choice.
    var flatRoof: Bool? = nil
}

/// One place to tune the whole look without touching generation code.
nonisolated struct DioramaConfig: Sendable {
    /// Bump to invalidate every cached tile.
    var generatorVersion: Int = 36
    /// Reuse full-detail architectural primitives without changing their tessellation.
    var instancesArchitecture: Bool = true
    /// Drape the plate/ground overlays over the bundled height snapshot used by roads and foundations.
    var usesElevation: Bool = true
    /// Vertical scale of the bundled snapshot (1 = real metres). The basemap's own terrain is switched
    /// off while the diorama is shown, so this relief is the only landform on screen.
    var terrainRelief: Double = 0.75
    /// Band inside the tile edge over which land eases down to the flat basemap.
    var terrainEdgeEase: Double = 36
    /// Side of the painted ground image (pixels). 4096 over a ~600 m tile is about 15 cm per pixel.
    var groundImageSize: Int = 4096
    var reducedGroundImageSize: Int = 2048

    // MARK: Tile
    var tileZoom: Int = 16
    var minimumZoom: Double = 15.5
    var fullDetailMinimumZoom: Double = 17.5
    /// The Slipway, Msasani peninsula: one z16 tile (about 600 m across) holding the Slipway complex,
    /// the DoubleTree, Slipway Villas and the bay. Data comes from the bundled `slipway_tile.json`.
    var seedLatitude: Double = -6.7546
    var seedLongitude: Double = 39.2734
    /// The tile stays loaded while the camera centre is within this many tiles of it.
    var visibilityRadiusTiles: Int = 2
    /// Upper bounds that keep the mesh size predictable.
    var maxBuildingsPerTile: Int = 450
    var maxRoadsPerTile: Int = 160

    // MARK: Camera
    var cameraZoom: Double = 16.6
    var cameraPitch: Double = 58
    /// Looks north-west over the Slipway towards Msasani Bay.
    var cameraBearing: Double = 318

    // MARK: Buildings
    var floorHeight: Double = 3.2
    /// Mapbox fills unknown heights with ~3 m; anything at or below this counts as missing.
    var placeholderHeight: Double = 3.1
    var bevel: Double = 0.22
    /// Corner radius for the rounded footprint silhouette. Toy-town rounding reads from the map
    /// camera only at this scale; 0.18 m was invisible.
    var cornerRadius: Double = 1.0
    /// Soft roof-edge bevel (metres) on flat roofs.
    var roofBevel: Double = 0.8
    /// Scale exaggeration for designed details (windows, cornices, chimneys, rails) so they read from
    /// the map camera. 1 is metric-accurate.
    var detailExaggeration: Double = 1.35
    /// Scale exaggeration for vegetation and street props.
    var propExaggeration: Double = 1.2
    var aoBandHeight: Double = 0.55
    /// Darker swatch copy for undersides; soft contact shadow now comes from screen-space occlusion.
    var aoDarkening: Double = 0.86
    /// Per-building hue shift amplitude applied to the wall tint.
    var hueShift: Float = 0.035

    // MARK: Post-processing
    var ambientOcclusionStrength: Float = 0.8
    var ambientOcclusionRadius: Float = 1.6
    var bloomStrength: Float = 0.55
    /// Fraction of the final colour pulled towards the warm-violet grade.
    var gradeStrength: Float = 0.035
    /// Haze per metre of distance from the eye (exponential).
    var hazeDensity: Float = 0.00012
    var roofOverhang: Double = 0.9
    var roofPitchDegrees: Double = 24
    var hipRoofShare: Double = 0.85
    /// Maximum rise of a hip roof above its eave.
    var hipRoofMaxRise: Double = 3.4
    /// Dar roofs are mostly terracotta tile and rust-red or green corrugated iron, so most pitched roofs
    /// are warm.
    var terracottaRoofShare: Double = 0.45
    /// Secondary complex blocks only. The two hotels and courtyard galleries bypass this generic
    /// palette override entirely through DioramaHotelGenerator.
    var buildingOverrides: [UInt64: DioramaBuildingOverride] = [
        142_262_992: DioramaBuildingOverride(wallColor: .whitewash, roofColor: .roofConcrete, flatRoof: false),
        688_369_154: DioramaBuildingOverride(wallColor: .whitewash, roofColor: .roofRust, flatRoof: false),
        180_607_949: DioramaBuildingOverride(wallColor: .cream, roofColor: .roofConcrete, flatRoof: true),
    ]
    var windowSpacing: Double = 3.1
    var maxWindowsPerBuilding: Int = 40
    var litWindowRatio: Double = 0.68
    var verandaChance: Double = 0.85
    var swahiliTouchChance: Double = 0.3
    var standTankChance: Double = 0.55
    var dishChance: Double = 0.3
    var solarChance: Double = 0.25

    // MARK: Compound walls
    var wallOffset: ClosedRange<Double> = 3.5...6.5
    var wallHeight: Double = 1.7
    /// Share of compounds bounded by a clipped hedge instead of a plaster wall.
    var hedgeFenceShare: Double = 0.4
    var wallThickness: Double = 0.25
    var capThickness: Double = 0.12
    var gateWidth: Double = 3.2
    var guardHutChance: Double = 0.25
    var bougainvilleaChancePerMetre: Double = 0.07

    // MARK: Vegetation
    var treesPer1000m2: Double = 4
    var parkTreesPer1000m2: Double = 8
    var coastPalmSpacing: Double = 14
    var streetTreeSpacing: Double = 17

    // MARK: Roads
    var pavementWidth: Double = 1.7
    var kerbHeight: Double = 0.22
    var dashLength: Double = 2.2
    var dashGap: Double = 3.0

    // MARK: Props and lights
    var vehiclesPerKm: Double = 16
    var lampSpacing: Double = 30
    var lampLightRadius: Double = 16
    /// Lights are binned into a 2D grid on the CPU so the shader only visits the few that reach a pixel.
    var maxLights: Int = 420
    var lightGridCells: Int = 24
    var lightsPerCell: Int = 16
    /// Facade lights: one warm source per facade with lit windows.
    var facadeLightIntensity: Float = 0.42

    // MARK: Landscaping
    var hedgeChancePerStretch: Double = 0.45
    var bushesPer1000m2: Double = 9
    var kioskChance: Double = 0.45
    var dhowsPerTile: Int = 4

    // MARK: Shoreline (metres, illustrative mid-tide datum, not a tidal prediction)
    /// The sea surface is the flat basemap plane, so the bay continues seamlessly past the tile edge.
    var waterLevel: Double = 0
    var beachWidth: Double = 12
    var beachSlope: Double = 0.12
    var seawallHeight: Double = 2.4
    var seawallSubmergedDepth: Double = 0.5
    var seawallBatter: Double = 0.12
    var copingWidth: Double = 0.65
    var copingHeight: Double = 0.18
    var copingRadius: Double = 0.08
    var rockSizeRange: ClosedRange<Double> = 0.4...1.5
    /// Rocks per square metre on the slope; also controls row spacing.
    var rockDensity: Double = 1.6
    var revetmentWidth: Double = 4.5
    var deckPostSpacing: Double = 3
    var deckThickness: Double = 0.16
    var foamWidth: Double = 0.65
    var shallowWaterDistance: Double = 28
    var shorelineSampleSpacing: Double = 2
    var shorelineFallbackDistance: Double = 15

    // MARK: Palette
    var palette: [DioramaSwatch: UInt32] = DioramaSwatch.defaultPalette
    var wallColors: [DioramaSwatch] = [.whitewash, .cream, .whitewash, .paleYellow, .sage, .cream]
    var apartmentWallColors: [DioramaSwatch] = [.cream, .whitewash, .paleYellow, .whitewash, .sage]
    var commercialWallColors: [DioramaSwatch] = [.brick, .whitewash, .cream, .ochre]
    var apartmentAccents: [DioramaSwatch] = [.trimWhite, .trimWhite, .skyBlue, .sage]
    var metalRoofColors: [DioramaSwatch] = [.roofRust, .roofGreen, .roofRust, .roofTeal, .roofSlate]
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

    static let slipway = DioramaConfig()
}
