import Foundation

/// Where a map screen wants its camera. Screens describe intent (a centred region, or a set of points that
/// must stay visible above a bottom panel); the map view turns that into a Google Maps camera update.
nonisolated enum MapCameraTarget: Equatable, Sendable {
    /// Leave the camera where it is.
    case automatic
    /// Centre on a point with a given width in kilometres.
    case region(MapRegion)
    /// Fit every point, keeping them clear of a bottom panel.
    case rect(MapBounds)
}

/// A centre and the approximate width of the visible map in kilometres.
nonisolated struct MapRegion: Equatable, Sendable {
    var centre: GeoPoint
    var spanKm: Double
}

/// Points to fit on screen with padding, optionally above a panel covering `bottomFraction` of the height.
nonisolated struct MapBounds: Equatable, Sendable {
    var points: [GeoPoint]
    var bottomFraction: Double
    var paddingFraction: Double
}

/// Camera maths shared by every map screen.
nonisolated enum MapCameraHelper {
    /// Region centred on `centre` spanning roughly `spanKm` kilometres.
    static func region(centre: GeoPoint, spanKm: Double) -> MapRegion {
        MapRegion(centre: centre, spanKm: spanKm)
    }

    /// Home framing: the pickup sits in the upper half so the sheet never covers it.
    static func homeRegion(around point: GeoPoint) -> MapRegion {
        region(centre: point.offset(eastMetres: 0, northMetres: -380), spanKm: 1.9)
    }

    /// Bounds that fit all points with breathing room.
    static func rect(fitting points: [GeoPoint], paddingFraction: Double = 0.28) -> MapBounds {
        MapBounds(points: points, bottomFraction: 0, paddingFraction: paddingFraction)
    }

    /// Fits `points` into the visible part of the screen above a bottom panel that covers `bottomFraction` of the height.
    static func rect(fitting points: [GeoPoint], bottomFraction: Double, paddingFraction: Double = 0.25) -> MapBounds {
        MapBounds(points: points, bottomFraction: min(max(bottomFraction, 0), 0.85), paddingFraction: paddingFraction)
    }
}
