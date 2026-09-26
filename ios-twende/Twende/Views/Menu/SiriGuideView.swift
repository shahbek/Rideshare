import AppIntents
import SwiftUI
import UIKit

/// C10 — what Siri, Shortcuts and the widget can do, with the exact phrases to say. Plain sections with
/// inset hairlines; quoted phrases sit in white hairline chips so they read as things you can say.
struct SiriGuideView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        MenuScreen(title: L(.siriGuide)) {
            Text(L(.siriGuideIntro))
                .font(TwendeFont.body)
                .foregroundStyle(TwendeColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            SiriTipView(intent: GetFareQuoteIntent())
                .siriTipViewStyle(.light)

            RowDivider(leading: 0)

            GuideSection(icon: .signpost, title: L(.siriGuideBookTitle), body: L(.siriGuideBookBody)) {
                PhraseChip(L(.siriGuideBookPhrase1))
                PhraseChip(L(.siriGuideBookPhrase2))
                PhraseChip(L(.siriGuideBookPhrase3))
            }

            RowDivider(leading: 0)

            GuideSection(icon: .cityCar, title: L(.siriGuideRideTitle), body: L(.siriGuideRideBody)) {
                PhraseChip(L(.siriGuideRidePhrase1))
                PhraseChip(L(.siriGuideRidePhrase2))
                PhraseChip(L(.siriGuideRidePhrase3))
            }

            RowDivider(leading: 0)

            GuideSection(icon: .phone, title: L(.siriGuideScreenTitle), body: L(.siriGuideScreenBody)) {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenCase(title: L(.siriGuideScreen1), body: L(.siriGuideScreen1Body))
                    RowDivider(leading: 0)
                    ScreenCase(title: L(.siriGuideScreen2), body: L(.siriGuideScreen2Body))
                    RowDivider(leading: 0)
                    ScreenCase(title: L(.siriGuideScreen3), body: L(.siriGuideScreen3Body))
                    RowDivider(leading: 0)
                    ScreenCase(title: L(.siriGuideScreen4), body: L(.siriGuideScreen4Body))
                    RowDivider(leading: 0)
                    ScreenCase(title: L(.siriGuideScreen5), body: L(.siriGuideScreen5Body))
                }
            }

            RowDivider(leading: 0)

            GuideSection(icon: .gear, title: L(.siriGuideShortcutsTitle), body: L(.siriGuideShortcutsBody)) {
                ShortcutsLink()
                    .shortcutsLinkStyle(.light)
                Button {
                    Haptics.tap()
                    if let url = URL(string: "shortcuts://") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text(L(.siriGuideOpenShortcuts))
                }
                .buttonStyle(.twendeSecondary)
            }

            RowDivider(leading: 0)

            GuideSection(icon: .house, title: L(.siriGuideWidgetTitle), body: L(.siriGuideWidgetBody)) {
                VStack(alignment: .leading, spacing: 10) {
                    StepRow(number: 1, text: L(.siriGuideWidgetStep1))
                    StepRow(number: 2, text: L(.siriGuideWidgetStep2))
                    StepRow(number: 3, text: L(.siriGuideWidgetStep3))
                }
            }

            Text(L(.siriGuideAvailability))
                .font(TwendeFont.label)
                .foregroundStyle(TwendeColor.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }
}

/// 40pt 3D object, 18pt semibold heading, body copy, then the section's examples.
private struct GuideSection<Content: View>: View {
    let icon: Icon3D
    let title: String
    let text: String
    @ViewBuilder let content: () -> Content

    init(icon: Icon3D, title: String, body text: String, @ViewBuilder content: @escaping () -> Content) {
        self.icon = icon
        self.title = title
        self.text = text
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Icon3DView(icon: icon, size: 40)
                Text(title).sectionLabelStyle()
                Spacer(minLength: 0)
            }
            Text(text)
                .font(TwendeFont.caption)
                .foregroundStyle(TwendeColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
    }
}

/// A thing you can say: quoted, in a white hairline chip with a small waveform.
private struct PhraseChip: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TwendeColor.accentText)
            Text("“\(text)”")
                .font(TwendeFont.bodyMedium)
                .foregroundStyle(TwendeColor.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TwendeColor.surface, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(TwendeColor.border, lineWidth: 1))
    }
}

/// One on-screen situation and the phrases that work there.
private struct ScreenCase: View {
    let title: String
    let text: String

    init(title: String, body text: String) {
        self.title = title
        self.text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(TwendeFont.bodyMedium)
                .foregroundStyle(TwendeColor.ink)
            Text(text)
                .font(TwendeFont.caption)
                .foregroundStyle(TwendeColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
    }
}

/// Numbered step with an ink digit inside a hairline circle.
private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(TwendeFont.figtree(13, weight: .semibold).monospacedDigit())
                .foregroundStyle(TwendeColor.ink)
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(TwendeColor.border, lineWidth: 1))
            Text(text)
                .font(TwendeFont.caption)
                .foregroundStyle(TwendeColor.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
