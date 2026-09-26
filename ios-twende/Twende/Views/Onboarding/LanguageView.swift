import SwiftUI

/// A2 — pick Kiswahili or English. Plain rows with a radio on the right; copy updates live.
struct LanguageView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        OnboardingScaffold(
            step: 1,
            title: L(.languageTitle),
            subtitle: L(.languageSubtitle)
        ) {
            VStack(spacing: 0) {
                ForEach(Array(AppLanguage.allCases.enumerated()), id: \.element.id) { index, language in
                    if index > 0 {
                        RowDivider(leading: 0)
                    }
                    LanguageRow(
                        language: language,
                        isSelected: env.settings.language == language
                    ) {
                        Haptics.selection()
                        withAnimation(.spring(duration: 0.3)) {
                            env.settings.language = language
                        }
                    }
                }
            }
        } footer: {
            Button(L(.continueAction)) {
                Haptics.medium()
                env.settings.onboardingStage = .signIn
            }
            .buttonStyle(.twendePrimary)
            .accessibilityIdentifier("onboarding.language.continue")
        }
    }
}

private struct LanguageRow: View {
    let language: AppLanguage
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.nativeName)
                        .font(TwendeFont.headline)
                        .foregroundStyle(TwendeColor.ink)
                    Text(language.subtitle)
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                }
                Spacer()
                RadioDot(isSelected: isSelected)
            }
            .frame(minHeight: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 22pt radio: hairline ring when idle, solid ink ring with a dot when selected.
struct RadioDot: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isSelected ? TwendeColor.ink : TwendeColor.grabber, lineWidth: isSelected ? 7 : 1.5)
        }
        .frame(width: 22, height: 22)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .accessibilityHidden(true)
    }
}
