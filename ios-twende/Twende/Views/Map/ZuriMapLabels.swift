import MapboxMaps
import UIKit
import simd

/// Zuri's own map typography: country, sea, city, neighbourhood and street names drawn from the
/// bundled offline Dar atlas in Figtree, with greedy priority collision and hysteresis. Replaces every
/// Mapbox place/road label. Lives above the map surface (below pins/banners) and costs one batched
/// projection per camera change; labels are pooled, never reallocated per frame.
@MainActor
final class ZuriMapLabels {
    nonisolated private enum Style: Int, Sendable { case country, sea, city, town, suburb, quarter, village, majorRoad, road }

    nonisolated private struct Candidate: Sendable {
        let id: Int
        let text: String
        let style: Style
        let point: SIMD2<Double>
        let coordinate: CLLocationCoordinate2D
        /// Road direction in local metres (unit), nil for point labels.
        let direction: SIMD2<Double>?
        let minZoom: Double
        let maxZoom: Double
        let priority: Int
    }

    private let container = UIView()
    private var pool: [UILabel] = []
    private var shown: [Int: UILabel] = [:]
    private var candidates: [Candidate] = []
    /// 1 km buckets of candidate indices for cheap camera-radius culling.
    private var buckets: [SIMD2<Int32>: [Int]] = [:]
    private var isNight: Bool = false
    private var prepared = false
    private var preparing = false
    private weak var mapView: MapView?

    func attach(to mapView: MapView) {
        self.mapView = mapView
        guard container.superview !== mapView else { return }
        container.isUserInteractionEnabled = false
        container.frame = mapView.bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.accessibilityElementsHidden = true
        // Directly above the map surface; pins/banners/ornaments added later stay on top.
        mapView.insertSubview(container, at: min(1, mapView.subviews.count))
        prepare()
    }

    func setNight(_ night: Bool) {
        guard night != isNight else { return }
        isNight = night
        for label in shown.values { label.removeFromSuperview(); pool.append(label) }
        shown.removeAll()
        if let mapView { layout(on: mapView) }
    }

    private func prepare() {
        guard !prepared, !preparing else { return }
        preparing = true
        Task.detached(priority: .utility) { [weak self] in
            let built = Self.buildCandidates(DarAtlas.shared)
            await MainActor.run {
                guard let self else { return }
                self.candidates = built
                var buckets: [SIMD2<Int32>: [Int]] = [:]
                for (index, candidate) in built.enumerated() {
                    buckets[SIMD2(Int32(floor(candidate.point.x / 1000)), Int32(floor(candidate.point.y / 1000))), default: []].append(index)
                }
                self.buckets = buckets
                self.prepared = true
                self.preparing = false
                if let mapView = self.mapView { self.layout(on: mapView) }
            }
        }
    }

    private nonisolated static func buildCandidates(_ atlas: DarAtlas) -> [Candidate] {
        var out: [Candidate] = []
        for place in atlas.places {
            let style: Style, minZoom: Double, maxZoom: Double, priority: Int
            switch place.kind {
            case .country: (style, minZoom, maxZoom, priority) = (.country, 0, 9.5, 0)
            case .sea: (style, minZoom, maxZoom, priority) = (.sea, 7, 13.5, 1)
            case .city: (style, minZoom, maxZoom, priority) = (.city, 7, 12.8, 2)
            case .town: (style, minZoom, maxZoom, priority) = (.town, 9, 14.5, 3)
            case .suburb: (style, minZoom, maxZoom, priority) = (.suburb, 11.3, 16.8, 4)
            case .bay: (style, minZoom, maxZoom, priority) = (.sea, 11.5, 16.5, 5)
            case .quarter: (style, minZoom, maxZoom, priority) = (.quarter, 13.8, 18.5, 8)
            case .village: (style, minZoom, maxZoom, priority) = (.village, 12.3, 16.5, 9)
            case .hamlet: (style, minZoom, maxZoom, priority) = (.village, 14, 17, 10)
            }
            let text = [.suburb, .quarter, .country, .sea].contains(style) ? place.name.uppercased() : place.name
            out.append(Candidate(id: out.count, text: text, style: style, point: DarAtlas.local(place.point),
                                 coordinate: place.point.coordinate, direction: nil,
                                 minZoom: minZoom, maxZoom: maxZoom, priority: priority))
        }
        // Street names repeat along long streets so a name is always in view.
        for street in atlas.streets {
            let minZoom: Double = [12.3, 12.8, 13.6, 14.4, 15.4, 16.3][min(street.rank, 5)]
            let spacing = street.rank <= 1 ? 900.0 : 600.0
            guard street.length > 40 else { continue }
            var station = min(street.length / 2, spacing / 2)
            var segment = 0
            while station < street.length {
                while segment < street.points.count - 2 && street.distances[segment + 1] < station { segment += 1 }
                let a = street.points[segment], b = street.points[segment + 1]
                let span = max(1e-6, street.distances[segment + 1] - street.distances[segment])
                let t = (station - street.distances[segment]) / span
                let point = a + (b - a) * t
                let direction = simd_normalize(b - a + SIMD2(1e-9, 0))
                out.append(Candidate(id: out.count, text: street.name, style: street.rank <= 1 ? .majorRoad : .road,
                                     point: point, coordinate: DarAtlas.geo(point).coordinate, direction: direction,
                                     minZoom: minZoom, maxZoom: 24, priority: 6 + street.rank))
                station += spacing
            }
        }
        return out
    }

    // MARK: - Layout

    func layout(on mapView: MapView) {
        guard prepared, mapView.bounds.width > 1 else { return }
        container.frame = mapView.bounds
        let camera = mapView.mapboxMap.cameraState
        let zoom = Double(camera.zoom)
        let centre = DarAtlas.local(GeoPoint(camera.center))
        let latitude = camera.center.latitude * .pi / 180
        let metresPerPoint = 40_075_016.686 * cos(latitude) / (512 * pow(2, zoom))
        let diagonal = Double(hypot(mapView.bounds.width, mapView.bounds.height)) / 2
        let radius = diagonal * metresPerPoint * (camera.pitch > 30 ? 3.2 : 1.4)
        let c0 = SIMD2<Int32>(Int32(floor((centre.x - radius) / 1000)), Int32(floor((centre.y - radius) / 1000)))
        let c1 = SIMD2<Int32>(Int32(floor((centre.x + radius) / 1000)), Int32(floor((centre.y + radius) / 1000)))
        var live: [Candidate] = []
        if (c1.x - c0.x + 1) * (c1.y - c0.y + 1) < 4_000 {
            for cx in c0.x...c1.x {
                for cy in c0.y...c1.y {
                    for index in buckets[SIMD2(cx, cy)] ?? [] {
                        let candidate = candidates[index]
                        if zoom >= candidate.minZoom && zoom < candidate.maxZoom { live.append(candidate) }
                    }
                }
            }
        } else {
            live = candidates.filter { zoom >= $0.minZoom && zoom < $0.maxZoom }
        }
        // Keep labels that are already visible ahead of equal-priority newcomers (no flicker on pans).
        live.sort { lhs, rhs in
            let l = lhs.priority * 2 - (shown[lhs.id] != nil ? 1 : 0)
            let r = rhs.priority * 2 - (shown[rhs.id] != nil ? 1 : 0)
            return l != r ? l < r : lhs.id < rhs.id
        }
        if live.count > 400 { live = Array(live.prefix(400)) }
        // Two batched projections: anchors first, then direction probes only for on-screen streets.
        let projected = mapView.mapboxMap.points(for: live.map(\.coordinate))
        let bounds = mapView.bounds.insetBy(dx: -20, dy: -20)
        let topLimit = mapView.safeAreaInsets.top + 4
        var onScreen: [Int] = []
        onScreen.reserveCapacity(live.count)
        for (i, point) in projected.enumerated() where point.x >= 0 && point.y >= topLimit && bounds.contains(point) { onScreen.append(i) }
        let streets = onScreen.filter { live[$0].direction != nil }
        let probes = mapView.mapboxMap.points(for: streets.map { i in
            DarAtlas.geo(live[i].point + (live[i].direction ?? .zero) * 12 * metresPerPoint).coordinate
        })
        var probeOf: [Int: CGPoint] = [:]
        for (k, i) in streets.enumerated() { probeOf[i] = probes[k] }
        var occupied: [CGRect] = []
        var placedText: [String: [CGPoint]] = [:]
        var keep = Set<Int>()
        for i in onScreen {
            let candidate = live[i]
            let point = projected[i]
            var angle: CGFloat = 0
            if candidate.direction != nil {
                guard let ahead = probeOf[i], ahead.x >= 0 else { continue }
                angle = atan2(ahead.y - point.y, ahead.x - point.x)
                if angle > .pi / 2 { angle -= .pi } else if angle < -.pi / 2 { angle += .pi }
            }
            // Collision uses a cached text size, so rejected names never touch UIKit or CoreText.
            let size = measuredSize(candidate)
            let rotated = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
                .applying(CGAffineTransform(rotationAngle: angle))
            let frame = rotated.offsetBy(dx: point.x, dy: point.y).insetBy(dx: -6, dy: -3)
            let repeatGap: CGFloat = candidate.direction == nil ? 0 : 220
            let tooClose = placedText[candidate.text]?.contains { hypot($0.x - point.x, $0.y - point.y) < repeatGap } ?? false
            if tooClose || occupied.contains(where: { $0.intersects(frame) }) { continue }
            occupied.append(frame)
            placedText[candidate.text, default: []].append(point)
            let label = shown[candidate.id] ?? dequeue(for: candidate)
            label.center = point
            label.transform = CGAffineTransform(rotationAngle: angle)
            if shown[candidate.id] == nil {
                shown[candidate.id] = label
                container.addSubview(label)
                label.alpha = 0
                UIView.animate(withDuration: 0.22) { label.alpha = 1 }
            }
            keep.insert(candidate.id)
        }
        for (id, label) in shown where !keep.contains(id) {
            shown[id] = nil
            recycle(label)
        }
    }

    private var sizes: [Int: CGSize] = [:]
    private func measuredSize(_ candidate: Candidate) -> CGSize {
        if let size = sizes[candidate.id] { return size }
        let bounds = Self.text(candidate.text, style: candidate.style, night: false).size()
        let size = CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
        sizes[candidate.id] = size
        return size
    }

    private func recycle(_ label: UILabel) {
        label.layer.removeAllAnimations()
        label.removeFromSuperview()
        label.transform = .identity
        if pool.count < 120 { pool.append(label) }
    }

    private func dequeue(for candidate: Candidate) -> UILabel {
        let label = pool.popLast() ?? UILabel()
        label.transform = .identity
        label.numberOfLines = 1
        label.attributedText = Self.text(candidate.text, style: candidate.style, night: isNight)
        label.sizeToFit()
        let layer = label.layer
        layer.shadowColor = (isNight ? UIColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1) : UIColor.white).cgColor
        layer.shadowOpacity = candidate.style == .sea ? 0.55 : 0.95
        layer.shadowRadius = 2.2
        layer.shadowOffset = .zero
        layer.shouldRasterize = true
        layer.rasterizationScale = UIScreen.main.scale
        return label
    }

    private static func font(_ name: String, _ size: CGFloat, oblique: Bool = false) -> UIFont {
        let base = UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: .medium)
        guard oblique else { return base }
        let matrix = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
        return UIFont(descriptor: base.fontDescriptor.withMatrix(matrix), size: size)
    }

    private static func text(_ string: String, style: Style, night: Bool) -> NSAttributedString {
        func hex(_ v: UInt32) -> UIColor {
            UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        let font: UIFont, color: UIColor, kern: CGFloat
        switch style {
        case .country: (font, color, kern) = (Self.font("Figtree-Bold", 15), hex(night ? 0xE6C89E : 0x745523), 4.5)
        case .sea: (font, color, kern) = (Self.font("Figtree-Medium", 13, oblique: true), hex(night ? 0x8FC3D0 : 0x3B7C8E), 2.4)
        case .city: (font, color, kern) = (Self.font("Figtree-Bold", 19), hex(night ? 0xF6F1E8 : 0x222222), 0.2)
        case .town: (font, color, kern) = (Self.font("Figtree-SemiBold", 14), hex(night ? 0xEDE6DA : 0x2E2A26), 0.1)
        case .suburb: (font, color, kern) = (Self.font("Figtree-SemiBold", 11.5), hex(night ? 0xD9CFBF : 0x5C554D), 1.8)
        case .quarter: (font, color, kern) = (Self.font("Figtree-Medium", 10.5), hex(night ? 0xC9BFAF : 0x77706A), 1.4)
        case .village: (font, color, kern) = (Self.font("Figtree-Medium", 11), hex(night ? 0xCFC6B8 : 0x6A645D), 0.3)
        case .majorRoad: (font, color, kern) = (Self.font("Figtree-SemiBold", 11.5), hex(night ? 0xF1E2C4 : 0x3D372F), 0.2)
        case .road: (font, color, kern) = (Self.font("Figtree-Medium", 10.5), hex(night ? 0xDCD3C5 : 0x4E4840), 0.15)
        }
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .kern: kern])
    }
}
