import Foundation

/// Demo drivers around Upanga with bundled sample portraits for the pickup panel.
nonisolated enum MockDrivers {
    static let jumaID = "drv-juma"
    static let aminaID = "drv-amina"
    static let barakaID = "drv-baraka"
    static let neemaID = "drv-neema"
    static let hassanID = "drv-hassan"

    static let favouriteIDs: [String] = [jumaID, aminaID, barakaID, neemaID, hassanID]

    static var all: [Driver] {
        let base = DarEsSalaam.upanga
        return [
            Driver(
                id: jumaID,
                name: "Juma Mwakasege",
                phone: "+255754123456",
                rating: 4.9,
                trips: 1_240,
                tier: .economy,
                vehicle: Vehicle(colour: "White", make: "Toyota", model: "Vitz", plate: "T 123 ABC"),
                portraitName: "driver_portrait_tanzanian",
                status: .online,
                position: base.offset(eastMetres: -900, northMetres: 700),
                memberSince: 2022
            ),
            Driver(
                id: aminaID,
                name: "Amina Salehe",
                phone: "+255715234567",
                rating: 4.8,
                trips: 860,
                tier: .comfort,
                vehicle: Vehicle(colour: "Silver", make: "Toyota", model: "Premio", plate: "T 478 DKM"),
                portraitName: "warm_natural_head",
                status: .online,
                position: base.offset(eastMetres: 600, northMetres: 1_800),
                memberSince: 2023
            ),
            Driver(
                id: barakaID,
                name: "Baraka Komba",
                phone: "+255689345678",
                rating: 4.7,
                trips: 2_105,
                tier: .bajaji,
                vehicle: Vehicle(colour: "Gold", make: "Bajaj", model: "RE", plate: "MC 552 BYT"),
                portraitName: "tanzanian_man_portrait",
                status: .online,
                position: base.offset(eastMetres: -400, northMetres: -650),
                memberSince: 2021
            ),
            Driver(
                id: neemaID,
                name: "Neema Lyimo",
                phone: "+255622456789",
                rating: 5.0,
                trips: 431,
                tier: .boda,
                vehicle: Vehicle(colour: "Black", make: "TVS", model: "HLX 150", plate: "MC 908 CRA"),
                portraitName: "woman_boda_rider_portrait",
                status: .online,
                position: base.offset(eastMetres: 350, northMetres: -300),
                memberSince: 2024
            ),
            Driver(
                id: hassanID,
                name: "Hassan Mrisho",
                phone: "+255765567890",
                rating: 4.6,
                trips: 3_310,
                tier: .economy,
                vehicle: Vehicle(colour: "White", make: "Toyota", model: "Passo", plate: "T 331 EHK"),
                portraitName: "man_portrait_taxi_driver",
                status: .offline,
                position: base.offset(eastMetres: -300, northMetres: -2_400),
                memberSince: 2020
            ),
            Driver(
                id: "drv-salim",
                name: "Salim Ng'wandu",
                phone: "+255713678901",
                rating: 4.7,
                trips: 980,
                tier: .economy,
                vehicle: Vehicle(colour: "Grey", make: "Toyota", model: "Vitz", plate: "T 610 FJP"),
                portraitName: nil,
                status: .online,
                position: base.offset(eastMetres: 1_400, northMetres: 300),
                memberSince: 2023
            ),
            Driver(
                id: "drv-rehema",
                name: "Rehema Kileo",
                phone: "+255652789012",
                rating: 4.8,
                trips: 1_520,
                tier: .comfort,
                vehicle: Vehicle(colour: "Black", make: "Toyota", model: "Mark X", plate: "T 244 GLR"),
                portraitName: nil,
                status: .online,
                position: base.offset(eastMetres: -1_900, northMetres: 1_200),
                memberSince: 2022
            ),
            Driver(
                id: "drv-frank",
                name: "Frank Mushi",
                phone: "+255784890123",
                rating: 4.5,
                trips: 640,
                tier: .bajaji,
                vehicle: Vehicle(colour: "Gold", make: "Piaggio", model: "Ape", plate: "MC 118 DNQ"),
                portraitName: nil,
                status: .online,
                position: base.offset(eastMetres: 900, northMetres: -1_100),
                memberSince: 2023
            ),
            Driver(
                id: "drv-zawadi",
                name: "Zawadi Msoffe",
                phone: "+255743901234",
                rating: 4.9,
                trips: 275,
                tier: .boda,
                vehicle: Vehicle(colour: "Silver", make: "Boxer", model: "BM 150", plate: "MC 771 EGS"),
                portraitName: nil,
                status: .busy,
                position: base.offset(eastMetres: -1_100, northMetres: -200),
                memberSince: 2024
            ),
            Driver(
                id: "drv-ibrahim",
                name: "Ibrahim Mfinanga",
                phone: "+255677012345",
                rating: 4.6,
                trips: 1_890,
                tier: .economy,
                vehicle: Vehicle(colour: "White", make: "Toyota", model: "IST", plate: "T 905 HKT"),
                portraitName: nil,
                status: .online,
                position: base.offset(eastMetres: 2_300, northMetres: -1_600),
                memberSince: 2021
            ),
            Driver(
                id: "drv-godfrey",
                name: "Godfrey Lema",
                phone: "+255759123450",
                rating: 4.4,
                trips: 512,
                tier: .comfort,
                vehicle: Vehicle(colour: "White", make: "Nissan", model: "Teana", plate: "T 388 JMV"),
                portraitName: nil,
                status: .offline,
                position: base.offset(eastMetres: -2_600, northMetres: -900),
                memberSince: 2023
            ),
            Driver(
                id: "drv-mwajuma",
                name: "Mwajuma Said",
                phone: "+255621234501",
                rating: 4.8,
                trips: 733,
                tier: .bajaji,
                vehicle: Vehicle(colour: "Gold", make: "Bajaj", model: "RE", plate: "MC 265 FPW"),
                portraitName: nil,
                status: .online,
                position: base.offset(eastMetres: -700, northMetres: 2_600),
                memberSince: 2022
            ),
            Driver(
                id: "drv-premium-daniel",
                name: "Daniel Mallya",
                phone: "+255700000001",
                rating: 4.9,
                trips: 920,
                tier: .premium,
                vehicle: Vehicle(colour: "Black", make: "Toyota", model: "Alphard", plate: "T 412 KLA"),
                portraitName: nil,
                status: .online,
                position: base.offset(eastMetres: 750, northMetres: 900),
                memberSince: 2023
            ),
            Driver(
                id: "drv-premium-grace",
                name: "Grace Mrema",
                phone: "+255700000002",
                rating: 4.8,
                trips: 640,
                tier: .premium,
                vehicle: Vehicle(colour: "Black", make: "Toyota", model: "Vellfire", plate: "T 628 KMB"),
                portraitName: nil,
                status: .online,
                position: base.offset(eastMetres: -650, northMetres: 1_450),
                memberSince: 2024
            ),
        ].map { driver in
            var sample = driver
            if sample.portraitName == nil {
                // Sample imagery belongs only to this demo directory, never a fallback for real accounts.
                switch sample.id {
                case "drv-rehema", "drv-mwajuma", "drv-premium-grace":
                    sample.portraitName = "warm_natural_head"
                case "drv-zawadi":
                    sample.portraitName = "woman_boda_rider_portrait"
                case "drv-frank", "drv-godfrey":
                    sample.portraitName = "tanzanian_man_portrait"
                default:
                    sample.portraitName = "driver_portrait_tanzanian"
                }
            }
            return sample
        }
    }
}
