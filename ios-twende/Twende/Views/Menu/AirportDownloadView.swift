import SwiftUI

/// Separate airport preparation/download controls alongside the existing Masaki installation.
struct AirportDownloadView: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable private var airport: AirportPreparationState = .shared
    @State private var downloadMessage: String?

    private var area: OfflineMapArea { .airport }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Julius Nyerere Airport · HD").font(TwendeFont.headline)
            Text("Save the airport in smaller 240 m tiles. Viewing loads nearby detail into one shared lighting renderer, with sharp road markings, shaded parking and the photo-led control tower.")
                .font(TwendeFont.caption).foregroundStyle(TwendeColor.inkSecondary)
            Text(airport.message).font(TwendeFont.caption).foregroundStyle(TwendeColor.inkSecondary)
            if airport.storedBytes > 0 {
                Text(ByteCountFormatter.string(fromByteCount: Int64(airport.storedBytes), countStyle: .file)).font(TwendeFont.caption)
            }
            if airport.isPreparing {
                if airport.totalPages > 0 { ProgressView(value: Double(airport.completedPages), total: Double(airport.totalPages)) }
                else { ProgressView() }
                Button("Pause airport preparation") { airport.pause() }.frame(minHeight: 48)
            } else if !airport.isReady || !airport.hasSharpGround || !airport.hasSpatialTiles {
                Button(airport.isReady ? "Prepare smaller airport tiles" : "Save airport 3D on this phone") { airport.prepare() }
                    .frame(minHeight: 48).accessibilityIdentifier("offline.airport.prepare")
            } else {
                Button("Verify / repair airport HD") { airport.prepare(repair: true) }
                    .frame(minHeight: 48).accessibilityIdentifier("offline.airport.repair")
            }
            Text("3D is saved locally from the bundled airport; no remote 3D download is needed. Once saved, viewing reads checked Metal buffers instead of rebuilding terminals. Existing airport HD tiles and Masaki downloads are preserved.")
                .font(TwendeFont.caption).foregroundStyle(TwendeColor.inkSecondary)
            if env.offlineMaps.activeID == area.id {
                ProgressView(value: env.offlineMaps.progress)
                Button("Pause airport basemap download") { env.offlineMaps.pause() }.frame(minHeight: 48)
            } else if env.offlineMaps.isReady(area) {
                Text("Airport basemap saved for offline use").font(TwendeFont.caption)
            } else {
                Button("Download airport map for offline use") {
                    if let restriction = env.offlineMaps.restriction { downloadMessage = L(restriction) }
                    else if env.offlineMaps.activeID != nil { downloadMessage = "Wait for the current map download to finish." }
                    else { downloadMessage = nil; env.offlineMaps.download(area) }
                }.frame(minHeight: 48).accessibilityIdentifier("offline.airport.basemap")
            }
            if let key = env.offlineMaps.messages[area.id] { Text(L(key)).font(TwendeFont.caption) }
            if let downloadMessage { Text(downloadMessage).font(TwendeFont.caption).foregroundStyle(TwendeColor.danger) }
        }
        .tint(TwendeColor.primary)
        .onAppear { airport.refresh() }
    }
}
