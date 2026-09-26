@_spi(Experimental) import MapboxMaps
import UIKit

/// Picker candidates can change; a confirmed destination stays illuminated across camera movement
/// and map-screen replacement. Cached features carry actual geometry, not a guessed nearby footprint.
@MainActor
final class MapBuildingHighlight {
    private static var destinationCache: [GeoPoint: [StandardBuildingsFeature]] = [:]
    private var selected: StandardBuildingsFeature? = nil
    private var fragments: [StandardBuildingsFeature] = []
    private var needsGeometryRefresh: Bool = false
    private var target: GeoPoint? = nil
    private var pending: Task<Void, Never>? = nil
    private var query: Cancelable? = nil
    private var revision: UInt = 0
    private var hasLoggedQueryError: Bool = false
    private let illumination = BuildingIllumination()

    func schedule(at point: CGPoint?, coordinate: GeoPoint?, isPicking: Bool, on map: MapboxMap, immediately: Bool = false) {
        // Once confirmed, do not reselect whatever roof happens to cross the pin as the camera rotates.
        if !isPicking, target == coordinate, let selected {
            if immediately { illumination.refreshNeighbours(on: map) }
            if !immediately { needsGeometryRefresh = true }
            if immediately, needsGeometryRefresh, let coordinate, point != nil {
                needsGeometryRefresh = false
                cancelPending()
                collectFragments(of: selected, at: coordinate, on: map, revision: revision)
            }
            return
        }
        cancelPending()
        guard let coordinate else {
            target = nil
            select(nil, at: nil, on: map)
            return
        }
        if !isPicking, coordinate != target {
            target = coordinate
            select(nil, at: nil, on: map)
            if let saved = Self.destinationCache[coordinate], let first = saved.first {
                select(first, at: coordinate, on: map)
                fragments = saved
                Self.destinationCache[coordinate] = saved
                illumination.show(saved, on: map)
                needsGeometryRefresh = true
                return
            }
        }
        target = coordinate
        // An offscreen/unloaded destination is not a deselection. Re-query when it returns to view.
        guard let point else { return }
        let requestedRevision = revision
        if immediately {
            queryBuilding(at: point, coordinate: coordinate, isPicking: isPicking, on: map, revision: requestedRevision)
        } else {
            pending = Task { [weak self, weak map] in
                do { try await Task.sleep(for: .milliseconds(120)) }
                catch { return }
                guard let self, let map, self.revision == requestedRevision else { return }
                self.pending = nil
                self.queryBuilding(at: point, coordinate: coordinate, isPicking: isPicking, on: map, revision: requestedRevision)
            }
        }
    }

    func clear(on map: MapboxMap) {
        cancelPending()
        target = nil
        select(nil, at: nil, on: map)
    }

    func styleDidReload() {
        cancelPending()
        selected = nil
        fragments = []
        needsGeometryRefresh = false
        target = nil
        illumination.styleDidReload()
        hasLoggedQueryError = false
    }

    private func cancelPending() {
        revision &+= 1
        pending?.cancel()
        pending = nil
        query?.cancel()
        query = nil
    }

    private func queryBuilding(at point: CGPoint, coordinate: GeoPoint, isPicking: Bool, on map: MapboxMap, revision requestedRevision: UInt) {
        query = map.queryRenderedFeatures(with: point, featureset: .standardBuildings) { [weak self, weak map] result in
            guard let self, let map, self.revision == requestedRevision else { return }
            self.query = nil
            switch result {
            case .success(let buildings):
                // Building parts frequently arrive without an id. The architectural facade is our own overlay and
                // needs only geometry, so never skip the body under the pin in favour of an id-bearing sliver.
                let building = buildings.first
                if building != nil || isPicking {
                    self.select(building, at: coordinate, on: map)
                    if let building, building.id != nil {
                        self.collectFragments(of: building, at: coordinate, on: map, revision: requestedRevision)
                    }
                }
            case .failure:
                if !self.hasLoggedQueryError {
                    self.hasLoggedQueryError = true
                    print("[MapBuildingHighlight] Building lookup unavailable; location selection remains active")
                }
            }
        }
    }

    /// Point queries may return one tile fragment. Collect all visible fragments with the SAME
    /// namespaced identity, never adjacent buildings, and retain them when tiles leave the viewport.
    private func collectFragments(of building: StandardBuildingsFeature, at coordinate: GeoPoint, on map: MapboxMap, revision requestedRevision: UInt) {
        // Id-less parts are not a shared identity: nil == nil would collect every unrelated building.
        guard building.id != nil else { return }
        query = map.queryRenderedFeatures(featureset: .standardBuildings) { [weak self, weak map] result in
            guard let self, let map, self.revision == requestedRevision, self.selected?.id == building.id else { return }
            self.query = nil
            guard case .success(let buildings) = result else { return }
            var combined = self.fragments
            for part in buildings where part.id == building.id {
                if !combined.contains(where: { $0.geometry == part.geometry && $0.properties == part.properties }) {
                    combined.append(part)
                }
            }
            guard combined.count != self.fragments.count else { return }
            self.fragments = combined
            Self.destinationCache[coordinate] = combined
            self.illumination.show(combined, on: map)
        }
    }

    private func select(_ building: StandardBuildingsFeature?, at coordinate: GeoPoint?, on map: MapboxMap) {
        if let coordinate, let building {
            // Bounded session cache bridges booking, matching and navigation without saving map SDK state.
            if Self.destinationCache.count >= 128 { Self.destinationCache.removeAll(keepingCapacity: true) }
            Self.destinationCache[coordinate] = Self.isSame(selected, building) && !fragments.isEmpty ? fragments : [building]
        } else if let coordinate {
            Self.destinationCache[coordinate] = nil
        }
        guard !Self.isSame(selected, building) else { return }
        if let selected, selected.id != nil { map.setFeatureState(selected, state: .init(select: false)) }
        selected = building
        fragments = building.map { [$0] } ?? []
        if let building {
            // The mesh and perimeter carry selection; do not tint the native building gold beneath them.
            if building.id != nil { map.setFeatureState(building, state: .init(select: false)) }
            illumination.show(fragments, on: map)
        } else {
            illumination.remove(from: map)
        }
    }

    /// Identity by namespaced id when available; id-less building parts compare by footprint.
    private static func isSame(_ lhs: StandardBuildingsFeature?, _ rhs: StandardBuildingsFeature?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?):
            if l.id != nil || r.id != nil { return l.id == r.id }
            return l.geometry == r.geometry
        default: return false
        }
    }
}
