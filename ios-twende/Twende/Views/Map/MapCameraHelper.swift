import Foundation

/// Where a map screen wants its camera. Screens describe intent (a centred region, or a set of points that
/// must stay visible above a bottom panel); the map view turns that into a native Mapbox camera update.
nonisolated enum MapCameraTarget: Equatable, Sendable {
    /// Leave the camera where it is.
    case automatic
    /// Centre on a point with a given width in kilometres.
    case region(MapRegion)
    /// Fit every point, keeping them clear of a bottom panel.
    case rect(MapBounds)
    /// One-shot bird’s-eye intent; preserve centre, zoom, bearing and padding, change only pitch.
    case topDown(requestID: UUID)
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
    /// Share of the width covered on the left (the panel pane on iPhone Duo's open inner display).
    var leadingFraction: Double = 0
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

    /// Same as `rect(fitting:bottomFraction:)`, but on the open inner display the panel sits left of the fold,
    /// so the points are fitted into the right-hand pane instead of above the panel.
    static func rect(fitting points: [GeoPoint], bottomFraction: Double, paddingFraction: Double = 0.25, fold: FoldLayout?) -> MapBounds {
        guard let fold else { return rect(fitting: points, bottomFraction: bottomFraction, paddingFraction: paddingFraction) }
        return MapBounds(points: points, bottomFraction: 0, paddingFraction: paddingFraction, leadingFraction: fold.mapLeadingFraction)
    }

    /// Region whose `focus` lands in the middle of the map pane right of the fold (or the usual centre on a phone).
    static func region(focus: GeoPoint, spanKm: Double, fold: FoldLayout?) -> MapRegion {
        guard let fold else { return region(centre: focus, spanKm: spanKm) }
        return region(centre: focus.offset(eastMetres: -spanKm * 1000 * fold.mapPaneShift, northMetres: 0), spanKm: spanKm)
    }

    /// Home framing, fold-aware: on the open inner display the pickup sits centred in the right pane.
    static func homeRegion(around point: GeoPoint, fold: FoldLayout?) -> MapRegion {
        guard fold != nil else { return homeRegion(around: point) }
        return region(focus: point, spanKm: 2.4, fold: fold)
    }
}
