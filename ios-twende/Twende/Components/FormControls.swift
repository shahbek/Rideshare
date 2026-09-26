import SwiftUI
import UIKit

/// 56pt text field: white with a hairline, black 2pt edge when focused.
struct TwendeTextField: View {
    let title: String
    @Binding var text: String
    var placeholder: String = ""
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType? = nil
    var autocapitalization: TextInputAutocapitalization = .words
    var prefix: String? = nil
    var autoFocus: Bool = false

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(TwendeFont.captionMedium)
                .foregroundStyle(TwendeColor.inkSecondary)
            HStack(spacing: 10) {
                if let prefix {
                    Text(prefix)
                        .font(TwendeFont.bodySemibold)
                        .foregroundStyle(TwendeColor.ink)
                }
                TextField(placeholder, text: $text)
                    .font(TwendeFont.body)
                    .foregroundStyle(TwendeColor.ink)
                    .keyboardType(keyboard)
                    .textContentType(contentType)
                    .textInputAutocapitalization(autocapitalization)
                    .autocorrectionDisabled()
                    .focused($isFocused)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(TwendeColor.surface, in: .rect(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isFocused ? TwendeColor.ink : TwendeColor.border, lineWidth: isFocused ? 2 : 1)
            )
            .animation(.easeOut(duration: 0.15), value: isFocused)
        }
        .onAppear {
            if autoFocus { isFocused = true }
        }
    }
}

/// Leading slot for rows: a rendered 3D icon, or a plain ink SF Symbol where no render exists.
struct RowLeadingIcon: View {
    var icon: Icon3D? = nil
    var systemImage: String? = nil
    var tint: Color = TwendeColor.ink
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let icon {
                Icon3DView(icon: icon, size: size, tint: tint)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Plain list row: leading 3D icon, title, optional subtitle / value / badge and a chevron.
struct MenuRow: View {
    var icon: Icon3D? = nil
    var systemImage: String? = nil
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var badge: String? = nil
    var iconTint: Color = TwendeColor.ink
    var showsChevron: Bool = true
    /// Zero when the row sits inside an already-inset page such as `MenuScreen`.
    var horizontalPadding: CGFloat = 16
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                RowLeadingIcon(icon: icon, systemImage: systemImage, tint: iconTint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(TwendeFont.bodyMedium)
                        .foregroundStyle(TwendeColor.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(TwendeFont.caption)
                            .foregroundStyle(TwendeColor.inkSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let badge {
                    Text(badge)
                        .font(TwendeFont.label)
                        .foregroundStyle(TwendeColor.inkSecondary)
                }
                if let value {
                    Text(value)
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                }
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TwendeColor.inkTertiary)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
    }
}

/// Plain "add" row that closes an editable list: a plus inside a hairline circle, then an underlined title.
struct AddRow: View {
    let title: String
    var systemImage: String = "plus"
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TwendeColor.ink)
                    .frame(width: 40, height: 40)
                    .overlay(Circle().strokeBorder(TwendeColor.border, lineWidth: 1))
                Text(title)
                    .font(TwendeFont.bodySemibold)
                    .foregroundStyle(TwendeColor.ink)
                    .underline()
                Spacer(minLength: 0)
            }
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
    }
}

/// Row with a 40pt 3D icon, title/subtitle and a trailing accessory. Hairlines between these rows inset
/// by 56pt.
struct IconRow<Accessory: View>: View {
    var icon: Icon3D? = nil
    var systemImage: String? = nil
    let title: String
    var subtitle: String? = nil
    var iconTint: Color = TwendeColor.ink
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            RowLeadingIcon(icon: icon, systemImage: systemImage, tint: iconTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TwendeFont.bodyMedium)
                    .foregroundStyle(TwendeColor.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.vertical, 10)
        .frame(minHeight: 60)
    }
}

/// Airbnb filter chip: white with a hairline; selected = ink fill with white text. Optional 3D icon.
struct ChipButton: View {
    let title: String
    var systemImage: String? = nil
    var icon: Icon3D? = nil
    var isSelected: Bool = false
    var minimumHeight: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 8) {
                if let icon {
                    Icon3DView(icon: icon, size: 24, tint: isSelected ? .white : TwendeColor.ink)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(TwendeFont.captionMedium)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? .white : TwendeColor.ink)
            .padding(.leading, icon == nil ? 14 : 8)
            .padding(.trailing, 14)
            .frame(minHeight: minimumHeight)
            .background(isSelected ? TwendeColor.ink : TwendeColor.surface, in: .capsule)
            .overlay(Capsule().strokeBorder(isSelected ? .clear : TwendeColor.border, lineWidth: 1))
        }
        .buttonStyle(.pressableCard)
    }
}

/// Section heading with optional trailing action.
struct SectionHeader: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(title).sectionLabelStyle()
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(TwendeFont.captionMedium)
                    .foregroundStyle(TwendeColor.ink)
                    .underline()
            }
        }
    }
}

/// Grabber shown at the top of every sheet.
struct SheetGrabber: View {
    var body: some View {
        Capsule()
            .fill(TwendeColor.grabber)
            .frame(width: 36, height: 4)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
    }
}

/// Inset hairline between rows.
struct RowDivider: View {
    var leading: CGFloat = 16

    var body: some View {
        Rectangle()
            .fill(TwendeColor.border)
            .frame(height: 1)
            .padding(.leading, leading)
    }
}

/// Simple key/value line used in fare breakdowns and receipts.
struct BreakdownRow: View {
    let title: String
    let value: String
    var emphasis: Bool = false
    var tint: Color? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(emphasis ? TwendeFont.bodySemibold : TwendeFont.body)
                .foregroundStyle(emphasis ? TwendeColor.ink : TwendeColor.inkSecondary)
            Spacer()
            Text(value)
                .font(emphasis ? TwendeFont.fareLarge : TwendeFont.fare)
                .foregroundStyle(tint ?? TwendeColor.ink)
        }
    }
}
