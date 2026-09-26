import AVFoundation
import SwiftUI

/// Opened by tapping a map billboard: the advert looping muted, the offer, the nearest branch and one
/// gold "Ride there" action that books straight to it.
struct BillboardAdSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let ad: BillboardAd

    private var branch: Place? { ad.nearestBranch(to: env.flow.pickup.point) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LoopingVideo(resource: ad.videoResource)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 8))
                        .overlay(alignment: .topLeading) {
                            Text(L(.adTestBadge))
                                .font(TwendeFont.label)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.55), in: .rect(cornerRadius: 4))
                                .padding(10)
                        }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(L(.adSponsored)) · \(ad.advertiser)")
                            .font(TwendeFont.captionMedium)
                            .foregroundStyle(TwendeColor.inkSecondary)
                        Text(L(ad.headline))
                            .font(TwendeFont.display)
                            .foregroundStyle(TwendeColor.ink)
                        Text(L(ad.offer))
                            .font(TwendeFont.body)
                            .foregroundStyle(TwendeColor.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let branch {
                        VStack(spacing: 0) {
                            RowDivider(leading: 0)
                            HStack(spacing: 14) {
                                Icon3DView(icon: .pin, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L(.adNearestBranch, branch.name))
                                        .font(TwendeFont.bodyMedium)
                                        .foregroundStyle(TwendeColor.ink)
                                    Text("\(branch.address) · \(Format.distance(branch.point.distanceKm(to: env.flow.pickup.point)))")
                                        .font(TwendeFont.caption)
                                        .foregroundStyle(TwendeColor.inkSecondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: 64)
                            RowDivider(leading: 0)
                        }
                    }

                    Text(L(.adDisclaimer))
                        .font(TwendeFont.label)
                        .foregroundStyle(TwendeColor.inkTertiary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)

            if let branch {
                Button(L(.adRideThere, branch.name)) {
                    Haptics.medium()
                    dismiss()
                    env.flow.activeSheet = nil
                    env.flow.choose(destination: branch)
                }
                .buttonStyle(.twendePrimary)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .accessibilityIdentifier("billboard.rideThere")
            }
        }
    }
}

/// Muted, looping bundled video in an AVPlayerLayer (no transport controls).
private struct LoopingVideo: UIViewRepresentable {
    let resource: String

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = UIColor(TwendeColor.ink)
        if let url = Bundle.main.url(forResource: resource, withExtension: "mp4") {
            let player = AVQueuePlayer()
            player.isMuted = true
            context.coordinator.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            view.playerLayer.player = player
            view.playerLayer.videoGravity = .resizeAspectFill
            player.play()
        }
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {}

    static func dismantleUIView(_ uiView: PlayerView, coordinator: Coordinator) {
        uiView.playerLayer.player?.pause()
        coordinator.looper = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var looper: AVPlayerLooper?
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
