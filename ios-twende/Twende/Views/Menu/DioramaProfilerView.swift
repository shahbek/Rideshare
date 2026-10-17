import SwiftUI

/// Controls for the zoom-in performance log: record, run the scripted test, share the files.
struct DioramaProfilerView: View {
    @Bindable private var session: DioramaProfileSession = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Performance log").font(TwendeFont.label).foregroundStyle(TwendeColor.inkSecondary)
            Text("Tap Start, go back to the map and zoom into the city centre. When you hold still, the app switches each effect and layer off in turn for 3 seconds and measures the saving. Come back here and tap Stop to get the report.")
                .font(TwendeFont.caption)
                .foregroundStyle(TwendeColor.inkSecondary)
            Toggle("Run the switch-off test when I hold still", isOn: $session.ablationPending)
                .font(TwendeFont.label)
                .tint(TwendeColor.primary)
                .disabled(session.isRecording)
            Button {
                Haptics.tap()
                if session.isRecording { session.stop() } else { session.start() }
            } label: {
                Label(session.isRecording ? "Stop and write report" : "Start recording",
                      systemImage: session.isRecording ? "stop.circle.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.twendeSecondary)
            Text(session.phase)
                .font(TwendeFont.label)
                .foregroundStyle(TwendeColor.ink)
                .fixedSize(horizontal: false, vertical: true)
            if session.isRecording, !session.liveLine.isEmpty {
                Text(session.liveLine)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(TwendeColor.inkSecondary)
            }
            if !session.files.isEmpty {
                ShareLink(items: session.files) {
                    Label("Share report and frame data", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.twendeSecondary)
            }
        }
    }
}
