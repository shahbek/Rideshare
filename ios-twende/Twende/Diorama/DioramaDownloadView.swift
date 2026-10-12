import SwiftUI

/// Shared download-first controls in Offline maps and the map's diorama panel.
struct DioramaDownloadView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var confirmsRemoval: Bool = false
    @State private var confirmsMobileData: Bool = false
    @State private var publishKey: String = ""
    @State private var showsPublisher: Bool = false
    @State private var localSizes: [(tile: DioramaTileID, coarse: Int64, full: Int64, compact: Bool)] = []
    let region: DioramaRegion
    private var download: DioramaDownloadService { .service(for: region) }
    init(region: DioramaRegion = .masaki) { self.region = region }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(download.regionName) · offline 3D").font(TwendeFont.headline)
            Text("Save the full addressed tile basemap, elevation and all \(download.total) detailed tiles before entering. One-time preparation can take a long time and several GB; use Wi-Fi and preferably connect power. Keep the app open. It can be paused and resumed.")
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
                    Button("View \(download.regionName) offline") { download.viewOffline() }.buttonStyle(.twendePrimary)
                    if download.joined < download.total {
                        Text("Architectural detail, terrain & roads · \(download.joined) / \(download.total) rebuilt").font(TwendeFont.label)
                        Text("Repaints the ground with mapped beaches and sand and golf greens, fairways and bunkers, and updates ordinary buildings with distinct designs, roads and trees. Uses saved sources offline; resumable, with your current scenery kept until it finishes. Lighting and grass blending already apply without rebuilding. Requires time and extra storage.")
                            .font(TwendeFont.caption).foregroundStyle(TwendeColor.inkSecondary)
                        Button(download.joined > 0 ? "Resume rebuilding scenery" : "Rebuild architectural detail") {
                            Haptics.tap(); download.repairJoins()
                        }.buttonStyle(.twendeSecondary)
                    }
                    optimizeSection
                } else {
                    Button(download.completed > 0 ? "Resume \(download.regionName) preparation" : "Download & prepare all \(download.regionName)") {
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
                    Button("Remove \(download.regionName) 3D download", role: .destructive) { confirmsRemoval = true }
                        .frame(minHeight: 48)
                }
            }
            if region == .harbour {
                pieceSection
                streamingSection
            }
            if region != .golf && download.isPrepared && !download.isRunning {
                publisherSection
            }
            Text("Offline viewing disables map downloads, not bookings or payments. Water is still; the scene redraws for camera changes and finite reveals, not on a looping timer.")
                .font(TwendeFont.caption).foregroundStyle(TwendeColor.inkSecondary)
        }
        .foregroundStyle(TwendeColor.ink)
        .onAppear { download.configure(maps: env.offlineMaps) }
        .task(id: download.bytes) {
            guard region == .harbour else { return }
            DioramaSceneryStreamer.shared.loadCatalogSizes()
            DioramaPieceStreamer.shared.refreshCatalog(force: true)
            localSizes = await DioramaOfflineStore.store(for: region).packageSizes()
        }
        .alert("\(download.regionName) preparation", isPresented: Binding(
            get: { download.failureMessage != nil },
            set: { if !$0 { download.failureMessage = nil } }
        )) {
            Button("OK", role: .cancel) { download.failureMessage = nil }
        } message: {
            Text(download.failureMessage ?? "")
        }
        .confirmationDialog("Allow downloads on this connection?", isPresented: $confirmsMobileData, titleVisibility: .visible) {
            Button("Allow & prepare \(download.regionName)") {
                env.offlineMaps.wiFiOnly = false
                download.start()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This turns off Wi-Fi-only map downloads and may use mobile data. \(download.regionName) preparation can require a large download. Your carrier may charge for data.")
        }
        .confirmationDialog("Remove saved \(download.regionName) 3D?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove download", role: .destructive) { download.remove() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("You will need to prepare \(download.regionName) again before viewing. Shared basemap downloads stay saved.") }
    }

    @ViewBuilder private var optimizeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pixel-accurate detail · \(download.optimized) / \(download.total) tiles optimized")
                .font(TwendeFont.label).monospacedDigit()
            Text("Prepares lighter versions of each tile once, on this device. Distant scenery then draws only detail larger than a pixel; close-ups are unchanged. Original files stay untouched.")
                .font(TwendeFont.caption).foregroundStyle(TwendeColor.inkSecondary)
            if !download.isFullyOptimized {
                Button(download.optimized > 0 ? "Resume optimizing scenery" : "Optimize scenery") {
                    Haptics.tap()
                    download.optimizeOnly()
                }
                .buttonStyle(.twendeSecondary)
            }
        }
    }

    private func mb(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// Movie-style streaming: finished pieces baked once on this phone, streamed view by view.
    @ViewBuilder private var pieceSection: some View {
        let baker = DioramaPieceBaker.shared
        let pieces = DioramaPieceStreamer.shared
        VStack(alignment: .leading, spacing: 6) {
            Text(pieces.isBundled ? "Finished harbour · built into the app" : "Streaming pieces · nothing built while viewing").font(TwendeFont.label)
            Text(pieces.isBundled
                 ? "The harbour ships inside the app and is read from the phone, never downloaded. Bake and upload a new version here; it goes into the next app update."
                 : "Bake once on this phone, upload, and every phone streams only the pieces under its camera.")
                .font(TwendeFont.caption).foregroundStyle(TwendeColor.inkSecondary)
            if pieces.isPublished {
                Text("\(pieces.isBundled ? "In this app" : "Published set") · revision \(pieces.catalogRevision) · \(pieces.catalogFiles) pieces · \(mb(pieces.catalogBytes))")
                    .font(TwendeFont.caption.weight(.semibold)).monospacedDigit()
                ForEach(pieces.catalogSummary, id: \.ring) { entry in
                    Text("\(entry.count) \(entry.ring.displayName) · \(mb(entry.bytes)) total · largest \(mb(entry.largest))")
                        .font(TwendeFont.caption).monospacedDigit().foregroundStyle(TwendeColor.inkSecondary)
                }
            } else if pieces.catalogChecked {
                Text("Server: no piece set published yet · whole-package streaming is used until one is")
                    .font(TwendeFont.caption).foregroundStyle(TwendeColor.inkSecondary)
            }
            if let report = baker.report, !baker.isRunning {
                Text("On this phone · \(report.pieces.count) pieces · \(mb(Int64(report.pieces.reduce(0) { $0 + $1.bytes })))\(report.published ? " · uploaded" : baker.missingPieceCount == 0 ? " · baked, not uploaded yet" : " · \(baker.missingPieceCount) piece files missing, bake again")")
                    .font(TwendeFont.caption.weight(.semibold)).monospacedDigit()
                ForEach(baker.ringSummary, id: \.ring) { entry in
                    Text("\(entry.count) \(entry.ring.displayName) · \(mb(Int64(entry.bytes))) · largest \(mb(Int64(entry.largest)))")
                        .font(TwendeFont.caption).monospacedDigit().foregroundStyle(TwendeColor.inkSecondary)
                }
                ForEach(baker.tileReports.keys.sorted(), id: \.self) { key in
                    Text("\(key) · \(baker.tileReports[key]?.joined(separator: " · ") ?? "")")
                        .font(TwendeFont.caption).monospacedDigit().foregroundStyle(TwendeColor.inkSecondary)
                }
            }
            if baker.isRunning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(baker.stage).font(TwendeFont.label)
                }
                if baker.total > 0 {
                    ProgressView(value: Double(baker.done), total: Double(max(baker.total, 1))).tint(TwendeColor.primary)
                }
                Button("Stop") { baker.cancel() }.buttonStyle(.twendeSecondary)
            } else if baker.hasUploadablePieces, baker.report?.published != true {
                Button("Upload baked pieces") { Haptics.tap(); baker.upload() }
                    .buttonStyle(.twendePrimary)
                Button("Bake again") { Haptics.tap(); baker.start() }
                    .buttonStyle(.twendeSecondary)
                    .disabled(baker.blocker != nil)
            } else {
                Button(baker.report?.published == true ? "Bake and upload again" : "Bake and upload harbour") {
                    Haptics.tap(); baker.start()
                }
                .buttonStyle(.twendePrimary)
                .disabled(baker.blocker != nil)
                if let blocker = baker.blocker {
                    Text(blocker).font(TwendeFont.caption).foregroundStyle(TwendeColor.accentText)
                }
            }
            if !baker.message.isEmpty { Text(baker.message).font(TwendeFont.caption.weight(.semibold)).foregroundStyle(TwendeColor.accentText) }
            if !pieces.status.isEmpty { Text(pieces.status).font(TwendeFont.caption) }
            HStack(spacing: 12) {
                Text("Recent pieces on this phone: \(mb(pieces.cacheBytes)) of \(mb(DioramaPieceStreamer.cacheCap))")
                    .font(TwendeFont.caption).monospacedDigit().foregroundStyle(TwendeColor.inkSecondary)
                if pieces.cacheBytes > 0 {
                    Button("Clear") { Haptics.tap(); pieces.clearCache() }.font(TwendeFont.caption.weight(.semibold))
                }
            }
            if pieces.bytesStreamed > 0 {
                Text("Streamed this session: \(mb(pieces.bytesStreamed))").font(TwendeFont.caption).monospacedDigit()
            }
        }
    }

    @ViewBuilder private var streamingSection: some View {
        let streamer = DioramaSceneryStreamer.shared
        VStack(alignment: .leading, spacing: 6) {
            Text("Streaming · download size per tile").font(TwendeFont.label)
            Text("Harbour tiles stream when you look at them: surroundings first, then full detail, nearest tile first. Nothing downloads in advance, and each piece is kept once it arrives.")
                .font(TwendeFont.caption).foregroundStyle(TwendeColor.inkSecondary)
            if !streamer.status.isEmpty { Text(streamer.status).font(TwendeFont.caption) }
            if env.offlineMaps.downloadedOnly {
                Text("Offline viewing is on, so nothing streams. Turn it off in Offline maps to stream.")
                    .font(TwendeFont.caption).foregroundStyle(TwendeColor.accentText)
            }
            ForEach(region.tiles, id: \.key) { tile in
                VStack(alignment: .leading, spacing: 2) {
                    Text(tile.key).font(TwendeFont.caption.weight(.semibold)).monospacedDigit()
                    if let size = streamer.catalogSizes[tile], size.total > 0 {
                        Text("Server: \(mb(size.coarse)) surroundings + \(mb(size.full)) full detail = \(mb(size.total))")
                            .font(TwendeFont.caption).monospacedDigit()
                    } else if streamer.catalogRevision == 0 {
                        Text("Server: not published yet").font(TwendeFont.caption).foregroundStyle(TwendeColor.inkSecondary)
                    }
                    if let local = localSizes.first(where: { $0.tile == tile }), local.coarse + local.full > 0 {
                        Text("On this phone: \(mb(local.coarse)) + \(mb(local.full)) = \(mb(local.coarse + local.full))\(local.compact ? " · compact" : " · older large format, Rebuild for compact size")")
                            .font(TwendeFont.caption).monospacedDigit().foregroundStyle(TwendeColor.inkSecondary)
                    }
                    if let got = streamer.downloaded[tile], got > 0 {
                        Text("Streamed this session: \(mb(got))").font(TwendeFont.caption).monospacedDigit()
                    }
                }
            }
        }
    }

    @ViewBuilder private var publisherSection: some View {
        if region != .masaki {
            VStack(alignment: .leading, spacing: 8) {
                Text("Upload this phone's \(download.regionName) scenery to Zuri's streaming server so every phone streams it. No key needed while the server is empty.")
                    .font(TwendeFont.caption).foregroundStyle(TwendeColor.inkSecondary)
                Button(download.isPublishing ? "Uploading…" : "Upload to streaming server") { download.publish() }
                    .buttonStyle(.twendePrimary)
                    .disabled(download.isPublishing || !download.isPrepared)
                if !download.publishMessage.isEmpty {
                    Text(download.publishMessage).font(TwendeFont.caption)
                }
            }
        } else {
            keyedPublisher
        }
    }

    @ViewBuilder private var keyedPublisher: some View {
        DisclosureGroup(isExpanded: $showsPublisher) {
            VStack(alignment: .leading, spacing: 8) {
                Text(region == .masaki
                     ? "Upload this device's prepared and optimized scenery so new installs download it instead of preparing it themselves. Requires the project's scenery publish key."
                     : "Upload this device's compact \(download.regionName) packages so every phone streams them on demand. Only compact (rebuilt) packages are uploaded. Requires the project's scenery publish key.")
                    .font(TwendeFont.caption).foregroundStyle(TwendeColor.inkSecondary)
                SecureField("Scenery publish key", text: $publishKey)
                    .textContentType(.password)
                    .font(TwendeFont.label)
                    .padding(10)
                    .background(TwendeColor.ink.opacity(0.06), in: .rect(cornerRadius: 10))
                Button(download.isPublishing ? "Publishing…" : "Publish pre-baked scenery") {
                    if !publishKey.isEmpty { DioramaPrebakedScenery.publishKey = publishKey }
                    download.publish()
                }
                .buttonStyle(.twendeSecondary)
                .disabled(download.isPublishing || (publishKey.isEmpty && DioramaPrebakedScenery.publishKey == nil))
                if !download.publishMessage.isEmpty {
                    Text(download.publishMessage).font(TwendeFont.caption)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Publisher tools").font(TwendeFont.label)
        }
        .tint(TwendeColor.ink)
    }
}
