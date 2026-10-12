import SwiftUI

/// On-map status for harbour 3D streaming, shown only near the harbour while something is happening
/// or blocked, so a missing harbour is never silent. Offers the one-tap fix when the user's
/// "Downloaded maps only" switch is what stops it.
struct HarbourStreamPill: View {
    let offlineMaps: OfflineMapService
    private var streamer: DioramaSceneryStreamer { DioramaSceneryStreamer.shared }
    private var pieces: DioramaPieceStreamer { DioramaPieceStreamer.shared }
    /// Finished pieces (movie-style streaming) take over from whole-package streaming once published.
    private var usesPieces: Bool { pieces.isPublished && pieces.isNearby }

    private var isVisible: Bool {
        if usesPieces {
            // Pieces built into the app load from disk; the pill only speaks up if one fails.
            if pieces.isBundled, pieces.failureSummary == nil { return false }
            guard !pieces.status.isEmpty else { return false }
            if pieces.status.hasPrefix("Harbour pieces ready") && !pieces.isStreaming { return false }
            return true
        }
        guard streamer.isNearby, !streamer.status.isEmpty else { return false }
        if streamer.status.hasPrefix("Streamed") && !streamer.isStreaming { return false }
        return true
    }
    private var isStreaming: Bool { usesPieces ? pieces.isStreaming : streamer.isStreaming }
    private var isBlocked: Bool { usesPieces ? pieces.isBlockedByDownloadedOnly : streamer.isBlockedByDownloadedOnly }
    private var statusText: String { usesPieces ? pieces.status : streamer.status }

    var body: some View {
        if isVisible {
            HStack(spacing: 10) {
                if isStreaming {
                    ProgressView().controlSize(.small).tint(TwendeColor.ink)
                } else {
                    Image(systemName: isBlocked ? "icloud.slash" : "building.2.crop.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TwendeColor.ink)
                }
                Text(statusText)
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if isBlocked {
                    Button {
                        Haptics.tap()
                        offlineMaps.downloadedOnly = false
                        if usesPieces { pieces.retryLast() } else { streamer.retryLast() }
                    } label: {
                        Text("Stream")
                            .font(TwendeFont.caption.weight(.semibold))
                            .foregroundStyle(TwendeColor.surface)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 32)
                            .background(Capsule().fill(TwendeColor.ink))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Turns off Downloaded maps only so harbour 3D can download")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(TwendeColor.border.opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("map.harbourStream")
        }
    }
}
