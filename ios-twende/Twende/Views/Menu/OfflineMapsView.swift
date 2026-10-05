import SwiftUI

/// Download management lives in Settings; saved maps are used automatically by every map screen.
struct OfflineMapsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var areaToRemove: OfflineMapArea?
    @State private var confirmsRemoval: Bool = false

    private var service: OfflineMapService { env.offlineMaps }

    var body: some View {
        MenuScreen(title: L(.offlineMaps)) {
            HStack(alignment: .top, spacing: 16) {
                Icon3DView(icon: .map, size: 56)
                Text(L(.offlineMapsBody))
                    .font(TwendeFont.body)
                    .foregroundStyle(TwendeColor.inkSecondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                Toggle(L(.offlineWiFiOnly), isOn: Bindable(service).wiFiOnly)
                    .frame(minHeight: 48)
                    .accessibilityIdentifier("offline.wifiOnly")
                RowDivider(leading: 0)
                Toggle(L(.offlineDownloadedOnly), isOn: Bindable(service).downloadedOnly)
                    .frame(minHeight: 48)
                    .accessibilityIdentifier("offline.downloadedOnly")
                Text(L(.offlineOnlyBody))
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
            }
            .font(TwendeFont.bodyMedium)
            .tint(TwendeColor.primary)

            if let restriction = service.restriction {
                Text(L(restriction))
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.accentText)
                    .accessibilityIdentifier("offline.restriction")
            }
            if service.inventoryError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L(.offlineInventoryFailed)).foregroundStyle(TwendeColor.danger)
                    Button(L(.tryAgain)) { service.refresh() }
                        .frame(minHeight: 48)
                }
                .font(TwendeFont.caption)
            }
            ForEach(OfflineMapArea.areas) { area in
                RowDivider(leading: 0)
                areaRow(area)
            }
            RowDivider(leading: 0)
            Text(L(.offlineBundled))
                .font(TwendeFont.bodyMedium)
                .foregroundStyle(TwendeColor.ink)
            Text(L(.offlineLimitations))
                .font(TwendeFont.caption)
                .foregroundStyle(TwendeColor.inkSecondary)
        }
        .onAppear { service.refresh() }
        .confirmationDialog(L(.offlineRemoveTitle), isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button(L(.remove), role: .destructive) {
                if let areaToRemove { service.remove(areaToRemove) }
                areaToRemove = nil
            }
            Button(L(.cancel), role: .cancel) { areaToRemove = nil }
        } message: { Text(L(.offlineRemoveBody)) }
    }

    private func areaRow(_ area: OfflineMapArea) -> some View {
        let ready = service.isReady(area)
        let active = service.activeID == area.id
        let saved = service.storedBytes[area.id]
        let message = service.messages[area.id]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(L(area.title)).font(TwendeFont.headline)
                Spacer(minLength: 12)
                if ready { Image(systemName: "checkmark").accessibilityLabel(L(.offlineReady)) }
            }
            Text(L(area.detail))
                .font(TwendeFont.caption)
                .foregroundStyle(TwendeColor.inkSecondary)
            if active {
                Text(L(message ?? .offlineDownloading)).font(TwendeFont.caption)
                ProgressView(value: service.progress)
                    .tint(TwendeColor.primary)
                Text(L(.offlineProgress, Int(service.progress * 100), size(service.downloadedBytes)))
                    .font(TwendeFont.caption)
                    .monospacedDigit()
                Button(L(.cancel)) { service.pause() }
                    .frame(minHeight: 48)
                    .accessibilityIdentifier("offline.cancel")
            } else {
                if let saved {
                    Text("\(L(ready ? .offlineReady : .offlinePartial)) · \(size(saved))")
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                }
                if let message {
                    Text(L(message))
                        .font(TwendeFont.caption)
                        .foregroundStyle(message == .offlineFailed || message == .offlineRemoveFailed ? TwendeColor.danger : TwendeColor.inkSecondary)
                }
                HStack(spacing: 20) {
                    Button {
                        Haptics.tap()
                        service.download(area, update: ready)
                    } label: {
                        Text(L(ready ? .offlineUpdate : (saved != nil || message != nil ? .offlineResume : .offlineDownload)))
                            .font(TwendeFont.bodyMedium)
                            .underline()
                            .frame(minHeight: 48)
                    }
                    .disabled(!service.canDownload || service.activeID != nil || !service.removingIDs.isEmpty)
                    .accessibilityIdentifier("offline.download.\(area.id)")
                    Spacer(minLength: 0)
                    if saved != nil {
                        if service.removingIDs.contains(area.id) {
                            ProgressView().frame(minWidth: 48, minHeight: 48)
                        } else {
                            Button(L(.remove), role: .destructive) {
                                areaToRemove = area; confirmsRemoval = true
                            }
                            .font(TwendeFont.caption)
                            .frame(minWidth: 48, minHeight: 48)
                            .disabled(service.activeID != nil)
                        }
                    }
                }
            }
        }
        .foregroundStyle(TwendeColor.ink)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
