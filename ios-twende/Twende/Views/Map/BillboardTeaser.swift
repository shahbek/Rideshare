@_spi(Experimental) import MapboxMaps
import SwiftUI
import UIKit

/// Uber-style sponsored place marker that hints at a billboard before it is close enough to render.
/// From the neighbourhood zoom a small brand tile sits at the site like any POI icon; closer in it
/// unfolds into a floating card beside the tile ("KFC · 2 pieces + chips · Sponsored"). It fades out
/// once the 3D billboard itself is big enough to see.
@MainActor
final class BillboardTeaser {
    enum Stage: Equatable { case hidden, tile, card }

    let ad: BillboardAd
    private var hosted: HostedMarker?
    private var stage: Stage = .hidden

    static let visibleZooms: ClosedRange<Double> = 12.8...16.2
    static let cardZoom: Double = 14.0

    init(ad: BillboardAd) {
        self.ad = ad
    }

    func update(on mapView: MapView) {
        let zoom = mapView.mapboxMap.cameraState.zoom
        let next: Stage = !Self.visibleZooms.contains(zoom) ? .hidden : (zoom >= Self.cardZoom ? .card : .tile)
        guard next != stage else { return }
        stage = next
        guard next != .hidden else {
            hosted?.setVisible(false)
            return
        }
        let root = AnyView(BillboardTeaserView(ad: ad, expanded: next == .card).padding(10).fixedSize())
        if let hosted {
            hosted.update(rootView: root)
            hosted.setVisible(true)
        } else {
            let marker = HostedMarker(rootView: root, anchor: .left)
            // Centre the tile on the site: 10pt padding plus half the 30pt tile.
            marker.offsetX = -(10 + BillboardTeaserView.tileSize / 2)
            marker.attach(to: mapView, at: ad.site)
            hosted = marker
        }
    }

    /// True when a tap lands on the tile or card.
    func hitTest(_ point: CGPoint, in mapView: MapView) -> Bool {
        guard stage != .hidden, let frame = hosted?.frame(in: mapView) else { return false }
        return frame.insetBy(dx: 4, dy: 4).contains(point)
    }

    func remove() {
        hosted?.remove()
        hosted = nil
        stage = .hidden
    }
}

/// Brand tile plus an optional white card. Advertiser colour lives only in the tile, so the marker
/// reads as a place on the map, not a banner.
struct BillboardTeaserView: View {
    let ad: BillboardAd
    let expanded: Bool

    static let tileSize: CGFloat = 30

    var body: some View {
        HStack(spacing: 0) {
            tile
                .zIndex(1)
            if expanded {
                card
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: expanded)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ad.advertiser), \(L(ad.headline)), \(L(.adSponsored))")
    }

    private var tile: some View {
        Text(ad.advertiser)
            .font(.custom("Figtree-Bold", size: ad.advertiser.count > 3 ? 8 : 10))
            .foregroundStyle(.white)
            .kerning(-0.2)
            .frame(width: Self.tileSize, height: Self.tileSize)
            .background(ad.brandColor, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(L(ad.headline))
                .font(.custom("Figtree-SemiBold", size: 13))
                .foregroundStyle(TwendeColor.ink)
            Text("\(ad.advertiser) · \(L(.adSponsored))")
                .font(.custom("Figtree-Medium", size: 11))
                .foregroundStyle(TwendeColor.inkSecondary)
        }
        .lineLimit(1)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(TwendeColor.surface, in: .rect(cornerRadius: 8))
        .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
        .padding(.leading, -4)
    }
}
