import SwiftUI

/// Shared download-first controls in Offline maps and the map's diorama panel.
struct DioramaDownloadView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var confirmsRemoval: Bool = false
    @State private var confirmsMobileData: Bool = false
    private var download: DioramaDownloadService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Masaki · offline 3D").font(TwendeFont.headline)
            Text("Save the peninsula basemap, elevation and all \(download.total) detailed tiles before entering. One-time preparation can take a long time and several GB; use Wi-Fi and preferably connect power. Keep the app open. It can be paused and resumed.")
                .font(TwendeFont.caption).foregroundStyle(TwendeColor.inkSecondary)
            Text(download.message).font(TwendeFont.caption)
            if download.isRunning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(download.stage).font(TwendeFont.label)
                }
                if download.isDownloadingBasemap {
                    ProgressView(value: env.offlineMaps.progress).tint(TwendeColor.primary)
                    Text("Basemap \(Int(env.offlineMaps.progress * 100))% · \(ByteCountFormatter.string(fromByteCount: env.offlineMaps.downloadedBytes, countStyle: .file)) downloaded")
                        .font(TwendeFont.caption).monospacedDigit()
                } else {
                    ProgressView(value: download.progress).tint(TwendeColor.primary)
                }
                Text("\(download.completed) / \(download.total) tiles · \(ByteCountFormatter.string(fromByteCount: download.bytes, countStyle: .file)) saved")
                    .font(TwendeFont.caption).monospacedDigit()
                Button(download.isPausing ? "Pausing…" : "Pause preparation") { download.pause() }
                    .buttonStyle(.twendeSecondary)
                    .disabled(download.isPausing)
            } else {
                if download.isPrepared && download.basemapReady {
                    Button("View Masaki offline") { download.viewOffline() }.buttonStyle(.twendePrimary)
                } else {
                    Button(download.completed > 0 ? "Resume Masaki preparation" : "Download & prepare all Masaki") {
                        Haptics.tap()
                        download.start()
                    }
                    .buttonStyle(.twendePrimary)
                    .accessibilityIdentifier("masaki.download.start")
                }
                if env.offlineMaps.downloadedOnly && (!download.isPrepared || !download.basemapReady) {
                    Button("Allow map downloads & prepare") {
                        env.offlineMaps.downloadedOnly = false
                        download.start()
                    }
                        .buttonStyle(.twendeSecondary)
                }
                if let restriction = env.offlineMaps.restriction, (!download.isPrepared || !download.basemapReady) {
                    Text(L(restriction)).font(TwendeFont.caption).foregroundStyle(TwendeColor.accentText)
                }
                if env.offlineMaps.restriction == .offlineNeedWiFi {
                    Button("Use this connection instead…") { confirmsMobileData = true }
                        .buttonStyle(.twendeSecondary)
                }
                if download.bytes > 0 {
                    Text("\(ByteCountFormatter.string(fromByteCount: download.bytes, countStyle: .file)) stored on this device")
                        .font(TwendeFont.caption).foregroundStyle(TwendeColor.inkSecondary)
                    Button("Remove Masaki 3D download", role: .destructive) { confirmsRemoval = true }
                        .frame(minHeight: 48)
                }
            }
            Text("Offline viewing disables map downloads, not bookings or payments. Water is still; the scene redraws for camera changes and finite reveals, not on a looping timer.")
                .font(TwendeFont.caption).foregroundStyle(TwendeColor.inkSecondary)
        }
        .foregroundStyle(TwendeColor.ink)
        .onAppear { download.configure(maps: env.offlineMaps) }
        .alert("Masaki preparation", isPresented: Binding(
            get: { download.failureMessage != nil },
            set: { if !$0 { download.failureMessage = nil } }
        )) {
            Button("OK", role: .cancel) { download.failureMessage = nil }
        } message: {
            Text(download.failureMessage ?? "")
        }
        .confirmationDialog("Allow downloads on this connection?", isPresented: $confirmsMobileData, titleVisibility: .visible) {
            Button("Allow & prepare Masaki") {
                env.offlineMaps.wiFiOnly = false
                download.start()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This turns off Wi-Fi-only map downloads and may use mobile data. Masaki preparation can require a large download. Your carrier may charge for data.")
        }
        .confirmationDialog("Remove saved Masaki 3D?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove download", role: .destructive) { download.remove() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("You will need to prepare Masaki again before viewing. Shared basemap downloads stay saved.") }
    }
}
