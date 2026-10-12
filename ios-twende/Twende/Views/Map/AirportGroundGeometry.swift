import Foundation
import CoreLocation
import CoreGraphics

/// One painted airfield surface. Unmapped widths/bay layouts/paint are explicitly illustrative.
nonisolated enum AirportGroundGeometry {
    static let imageSize: Int = 2048

    static func image(_ data: AirportMapData, origin: CLLocationCoordinate2D, rect requestedRect: DioramaRect? = nil, size: Int = imageSize, analyticFinishes: Bool = true) -> DioramaGroundImage? {
        let rect = requestedRect ?? data.groundRect(origin: origin)
        guard let painter = DioramaGroundPainter(rect: rect, size: size, config: .slipway, analyticFinishes: analyticFinishes) else { return nil }
        painter.fillAll(.grass)
        let outlines = data.features.filter { $0.tags["building"] != nil && $0.id != 1237792404 }.map { $0.local(origin: origin) }
        let roads = data.features.filter { $0.tags["highway"] != nil && $0.tags["aeroway"] == nil }.map { $0.local(origin: origin) }
        for f in data.features where f.isClosed && f.tags["aeroway"] == "apron" {
            painter.fill(f.local(origin: origin), .concrete)
        }
        for f in data.features where f.isClosed && f.tags["amenity"] == "parking" {
            let ring = f.local(origin: origin)
            painter.fill(ring, .asphalt)
            parking(ring, roads: roads, occupied: outlines, painter: painter)
        }
        if let terminal = data.features.first(where: { $0.id == 597787841 }) {
            let ring = terminal.local(origin: origin)
            if ring.count > 5 {
                let a = ring[2], b = ring[5], along = (b - a).normalized
                var out = along.left
                if out.dot(DioramaPolygon.centroid(ring) - a) > 0 { out = -out }
                // User-authored frontage hardscape, painted into the same surface as access roads.
                painter.fill([a - out * 0.4, b - out * 0.4, b + out * 18, a + out * 18], .paving)
                for i in ring.indices {
                    let p = ring[i], q = ring[(i + 1) % ring.count]
                    if abs((q - p).normalized.dot(along)) < 0.35 && min(p.dot(out), q.dot(out)) > min(a.dot(out), b.dot(out)) - 95 {
                        painter.stroke([p, q], width: 6, .paving)
                    }
                }
            }
        }
        for f in data.features where f.tags["highway"] != nil && f.tags["aeroway"] == nil {
            let footway = ["footway", "path", "pedestrian", "steps"].contains(f.tags["highway"] ?? "")
            let width = Double(f.tags["width"] ?? "") ?? (footway ? 2.2 : f.tags["highway"] == "service" ? 5.5 : 8)
            var line = f.local(origin: origin)
            if f.isClosed && (f.tags["area"] == "yes" || f.tags["highway"] == "pedestrian") {
                painter.fill(line, footway ? .paving : .asphalt)
            } else {
                if f.isClosed, let first = line.first { line.append(first) }
                painter.stroke(line, width: width, footway ? .paving : .asphalt)
            }
        }
        if let connector = data.features.first(where: { $0.id == 1237792404 }) {
            painter.fill(connector.local(origin: origin), .paving)
        }
        for f in data.features where f.tags["aeroway"] == "taxiway" {
            let line = f.local(origin: origin)
            painter.stroke(line, width: Double(f.tags["width"] ?? "") ?? 23, .asphalt)
        }
        for f in data.features where f.tags["aeroway"] == "stopway" {
            let points = f.local(origin: origin)
            if f.isClosed { painter.fill(points, .asphalt) }
            else { painter.stroke(points, width: Double(f.tags["width"] ?? "") ?? 30, .asphalt, cap: .butt) }
        }
        for f in data.features where f.tags["aeroway"] == "runway" {
            runway(f, origin: origin, painter: painter)
        }
        for f in data.features where ["taxiway", "parking_position"].contains(f.tags["aeroway"] ?? "") {
            painter.stroke(f.local(origin: origin), width: 0.22, .signYellow)
        }
        let streetData = streets(data, origin: origin, rect: rect)
        let layout = DioramaStreetLayout(data: streetData, config: .slipway)
        DioramaRoadMarkings(config: .slipway, data: streetData, roads: DioramaRoadIndex(roads: streetData.roads), layout: layout, painter: painter).paint()
        return painter.image()
    }

    private static func streets(_ data: AirportMapData, origin: CLLocationCoordinate2D, rect: DioramaRect) -> DioramaTileData {
        let roads = data.features.compactMap { f -> DioramaRoadFeature? in
            guard let kind = f.tags["highway"], !["footway", "path", "pedestrian", "steps", "cycleway"].contains(kind), f.tags["aeroway"] == nil, f.tags["area"] != "yes" else { return nil }
            var line = f.local(origin: origin)
            if f.isClosed, let first = line.first { line.append(first) }
            let width = Double(f.tags["width"] ?? "") ?? (kind == "service" ? 5.5 : 8)
            let oneWay = f.tags["oneway"] == "-1" ? -1 : (["yes", "1", "true"].contains(f.tags["oneway"] ?? "") || f.tags["junction"] == "roundabout" ? 1 : 0)
            return DioramaRoadFeature(id: UInt64(f.id), line: line, roadClass: kind, isPaved: !["unpaved", "dirt", "gravel", "ground"].contains(f.tags["surface"] ?? ""), width: width, name: f.tags["name"], oneWay: oneWay)
        }
        let paths = data.features.compactMap { f -> DioramaPathFeature? in
            guard let kind = f.tags["highway"], ["footway", "path", "pedestrian", "steps"].contains(kind) else { return nil }
            return DioramaPathFeature(id: UInt64(f.id), line: f.local(origin: origin), kind: kind, isLit: f.tags["lit"] == "yes")
        }
        return DioramaTileData(tile: .init(latitude: origin.latitude, longitude: origin.longitude, zoom: 16), projection: DioramaProjection(origin: origin), rect: rect, buildings: [], roads: roads, water: [], landuse: [], paths: paths)
    }

    private static func runway(_ feature: AirportMapData.Feature, origin: CLLocationCoordinate2D, painter: DioramaGroundPainter) {
        let line = feature.local(origin: origin)
        guard let first = line.first, let last = line.last else { return }
        let axis = (last - first).normalized
        let width = Double(feature.tags["width"] ?? "") ?? 30
        painter.stroke(line, width: width, .asphalt, cap: .butt)
        painter.stroke([first + axis * 85, last - axis * 85], width: 0.9, .marking, dashes: [30, 30], cap: .butt)
        for side in [-1.0, 1.0] {
            let offset = axis.left * (side * (width / 2 - 0.6))
            painter.stroke(line.map { $0 + offset }, width: 0.35, .marking, cap: .butt)
        }
        for (end, direction) in [(first, axis), (last, -axis)] {
            for side in [-1.0, 1.0] {
                for stripe in 0..<4 {
                    let p = end + direction * 20 + direction.left * (side * (4.5 + Double(stripe) * 3.1))
                    painter.stroke([p, p + direction * 30], width: 1.8, .marking, cap: .butt)
                }
                let p = end + direction * 300 + direction.left * (side * width * 0.25)
                painter.stroke([p, p + direction * 35], width: 5, .marking, cap: .butt)
            }
        }
    }

    private static func parking(_ ring: [DV2], roads: [[DV2]], occupied: [[DV2]], painter: DioramaGroundPainter) {
        for bay in parkingBays(ring, roads: roads, occupied: occupied) {
            painter.stroke([bay.corners[0], bay.corners[1], bay.corners[2], bay.corners[3]], width: 0.12, .marking, cap: .butt)
        }
    }

    static func parkingBays(_ ring: [DV2], roads: [[DV2]], occupied: [[DV2]]) -> [(centre: DV2, axis: DV2, corners: [DV2])] {
        var bays: [(centre: DV2, axis: DV2, corners: [DV2])] = []
        guard ring.count >= 3, let edge = ring.indices.max(by: {
            ring[$0].distance(to: ring[($0 + 1) % ring.count]) < ring[$1].distance(to: ring[($1 + 1) % ring.count])
        }) else { return [] }
        let axis = (ring[(edge + 1) % ring.count] - ring[edge]).normalized, across = axis.left
        let xs = ring.map { $0.dot(axis) }, ys = ring.map { $0.dot(across) }
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return [] }
        for row in stride(from: y0 + 3, through: y1 - 3, by: 16.0) {
            for x in stride(from: x0 + 2, through: x1 - 2, by: 2.6) {
                for side in [-1.0, 1.0] {
                    let centre = axis * x + across * (row + side * 5.5)
                    let corners = DioramaOrientedRect(centre: centre, axis: across, halfLength: 2.5, halfWidth: 1.3).corners
                    guard corners.allSatisfy({ DioramaPolygon.contains(ring, $0) }),
                          !occupied.contains(where: { polygon in corners.contains { DioramaPolygon.contains(polygon, $0) } }),
                          !roads.contains(where: { line in zip(line, line.dropFirst()).contains { DioramaPolygon.distanceToSegment(centre, $0.0, $0.1) < 5.8 } }) else { continue }
                    bays.append((centre, across * side, corners))
                }
            }
        }
        return bays
    }
}
