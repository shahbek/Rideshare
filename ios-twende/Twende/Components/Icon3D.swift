import SwiftUI

/// App iconography. Every meaningful object (places, payments, safety, settings, people) draws a soft
/// isometric 3D render (Airbnb-style matte clay, ink + restrained champagne). Utility glyphs (recent
/// searches, plus, back, set-on-map) stay plain ink line symbols. Vehicles render from the bundled fleet.
nonisolated enum Icon3D: String, Sendable {
    case cityCar = "hatchback_car"
    case sedan = "sedan_car_miniature"
    case minivan = "premium_minivan"
    case bajaji = "rickshaw_miniature"
    case boda = "boda_boda_motorcycle_2"
    case clock = "vintage_stopwatch"
    case star = "star_five_point_gold"
    case wallet = "bifold_wallet"
    case coins = "stacked_coins"
    case pin = "location_pin_2"
    case signpost = "signpost_dual_arrow"
    case logbook = "leather_travel_logbook"
    case gift = "gift_box_gold_ribbon"
    case shield = "shield_checkmark_2"
    case chat = "speech_bubble_dots"
    case gear = "gear_cog"
    case house = "modern_house_model"
    case briefcase = "briefcase_slim"
    case plane = "airliner_model"
    case shoppingBag = "shopping_bag_boutique"
    case cash = "money_stack"
    case phone = "smartphone_checkmark_2"
    case driver = "mannequin_driver_bust"
    case handshake = "handshake_sculpture"
    case receipt = "receipt_torn_2"
    case bell = "notification_bell_3"
    case lock = "padlock_closed_3"
    case siren = "emergency_beacon_lamp"
    case map = "folded_paper_map"
    case favourite = "heart_star_favorite"
    case school = "school_building_icon"
    case gym = "dumbbell"
    case sports = "soccer_ball_grass"
    case food = "pilau_rice_nyama_choma"
    case hospital = "hospital_building_icon"
    case cafe = "coffee_cup_icon"
    case hotel = "bed_with_champagne_blanket"
    case beach = "beach_umbrella_sand"
    case bus = "city_bus_isometric"
    case bank = "bank_building_coin"
    case worship = "place_of_worship"
    case fuel = "fuel_pump_icon"
    case bar = "glass_with_lime_drink"
    /// Utility glyph for recent searches; never rendered in 3D.
    case recent = "recent_search"

    /// Line symbol used at row/chip scale.
    var symbolName: String {
        switch self {
        case .cityCar, .sedan, .minivan: "car"
        case .bajaji: "car.side"
        case .boda: "scooter"
        case .clock: "clock"
        case .star: "star"
        case .wallet: "wallet.bifold"
        case .coins: "dollarsign.circle"
        case .pin: "mappin.and.ellipse"
        case .signpost: "signpost.right"
        case .logbook: "book.closed"
        case .gift: "gift"
        case .shield: "checkmark.shield"
        case .chat: "bubble.left.and.bubble.right"
        case .gear: "gearshape"
        case .house: "house"
        case .briefcase: "briefcase"
        case .plane: "airplane"
        case .shoppingBag: "bag"
        case .cash: "banknote"
        case .phone: "iphone"
        case .driver: "person"
        case .handshake: "hands.clap"
        case .receipt: "doc.text"
        case .bell: "bell"
        case .lock: "lock"
        case .siren: "light.beacon.max"
        case .map: "map"
        case .favourite: "heart"
        case .school: "graduationcap"
        case .gym: "dumbbell"
        case .sports: "soccerball"
        case .food: "fork.knife"
        case .hospital: "cross.case"
        case .cafe: "cup.and.saucer"
        case .hotel: "bed.double"
        case .beach: "beach.umbrella"
        case .bus: "bus"
        case .bank: "building.columns"
        case .worship: "building"
        case .fuel: "fuelpump"
        case .bar: "wineglass"
        case .recent: "clock.arrow.circlepath"
        }
    }

    /// Soft isometric 3D render; nil for utility glyphs that always stay line symbols.
    var heroAsset: String? {
        switch self {
        case .star: "star_rating_butter"
        case .receipt: "receipt_torn_3"
        case .logbook: "travel_journal"
        case .lock: "padlock_closed_4"
        case .shield: "shield_checkmark_3"
        case .phone: "smartphone_pin_pad"
        case .coins: "stacked_coins_2"
        case .wallet: "wallet_bifold_open"
        case .handshake: "hands_clasped_handshake"
        case .house: "cosy_house_icon"
        case .briefcase: "briefcase_work"
        case .pin: "map_push_pin"
        case .siren: "emergency_beacon_light"
        case .cash: "banknotes_stack_3"
        case .driver: "person_bust_cap_shirt"
        case .gift: "gift_box_with_bow"
        case .chat: "chat_bubbles_dots"
        case .gear: "settings_cog"
        case .bell: "notification_bell_4"
        case .map: "folded_paper_map_2"
        case .signpost: "signpost_arrows"
        case .plane: "airplane_banking"
        case .shoppingBag: "shopping_bag_tag"
        case .clock: "desk_clock_repeat"
        case .favourite: "heart_star_favorite"
        case .school, .gym, .sports, .food, .hospital, .cafe, .hotel, .beach, .bus, .bank, .worship, .fuel, .bar: rawValue
        default: nil
        }
    }

    var vehicleTier: RideTier? {
        switch self {
        case .cityCar: .economy
        case .sedan: .comfort
        case .minivan: .premium
        case .bajaji: .bajaji
        case .boda: .boda
        default: nil
        }
    }
}

/// Draws an icon at a fixed square size: vehicles from the fleet, 3D renders where one exists, otherwise
/// (or when `lineOnly`) an ink line symbol. No plates, no cast shadow.
struct Icon3DView: View {
    let icon: Icon3D
    var size: CGFloat = 40
    var hero: Bool = false
    var lineOnly: Bool = false
    var tint: Color = TwendeColor.ink

    private var usesHero: Bool { !lineOnly }

    var body: some View {
        Group {
            if icon.vehicleTier == nil, usesHero, let asset = icon.heroAsset {
                Image(asset)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if icon.vehicleTier == nil {
                Image(systemName: icon.symbolName)
                    .font(.system(size: size * 0.5, weight: .regular))
                    .foregroundStyle(tint)
            } else if let tier = icon.vehicleTier {
                if let image = VehicleSpriteStore.shared.preview(for: tier) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if tier == .premium {
                    // Premium has no archived image; do not temporarily show the restored sedan.
                    ProgressView().tint(TwendeColor.inkSecondary)
                } else {
                    // The archived illustration must not flash the retired turquoise fleet palette.
                    Image(icon.rawValue)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .saturation(0)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
