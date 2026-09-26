import SwiftUI

/// C7 — emergency contacts (max 3), auto-share toggle, safety tips. Plain rows with inset hairlines.
struct SafetyCentreView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var isAdding: Bool = false

    var body: some View {
        MenuScreen(title: L(.safetyCentre)) {
            IconRow(
                icon: .siren,
                title: L(.sosDuringTrip),
                subtitle: L(.sosDuringTripBody)
            ) {
                EmptyView()
            }
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: L(.emergencyContacts, env.store.emergencyContacts.count))
                    .padding(.bottom, 4)
                ForEach(Array(env.store.emergencyContacts.enumerated()), id: \.element.id) { index, contact in
                    if index > 0 {
                        RowDivider(leading: 56)
                    }
                    IconRow(icon: .phone, title: contact.name, subtitle: Format.phone(contact.phone)) {
                        Button {
                            Haptics.warning()
                            env.store.removeEmergencyContact(id: contact.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(TwendeColor.inkSecondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(L(.delete))
                    }
                }
                if !env.store.emergencyContacts.isEmpty {
                    RowDivider(leading: 56)
                }
                if env.store.emergencyContacts.count < 3 {
                    AddRow(title: L(.addContact), systemImage: "person.badge.plus") {
                        isAdding = true
                    }
                } else {
                    Text(L(.maxContacts))
                        .font(TwendeFont.label)
                        .foregroundStyle(TwendeColor.inkSecondary)
                        .padding(.vertical, 12)
                }
            }

            RowDivider(leading: 0)

            Toggle(isOn: Binding(
                get: { env.store.shareTripsWithContacts },
                set: { env.store.setShareTripsWithContacts($0) }
            )) {
                IconRow(icon: .map, title: L(.autoShareTrips), subtitle: L(.autoShareTripsBody)) {
                    EmptyView()
                }
            }
            .tint(TwendeColor.primary)
            .disabled(env.store.emergencyContacts.isEmpty)
            .opacity(env.store.emergencyContacts.isEmpty ? 0.5 : 1)

            RowDivider(leading: 0)

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: L(.safetyTips))
                    .padding(.bottom, 4)
                SafetyTipRow(symbol: "rectangle.and.text.magnifyingglass", text: L(.safetyTip1))
                RowDivider(leading: 56)
                SafetyTipRow(symbol: "person.crop.circle.badge.checkmark", text: L(.safetyTip2))
                RowDivider(leading: 56)
                SafetyTipRow(symbol: "square.and.arrow.up", text: L(.safetyTip3))
                RowDivider(leading: 56)
                SafetyTipRow(symbol: "phone.fill", text: L(.safetyTip4))
            }
        }
        .sheet(isPresented: $isAdding) {
            AddEmergencyContactSheet()
                .appSheet(detents: [.medium])
        }
    }
}

private struct SafetyTipRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(TwendeColor.ink)
                .frame(width: 40, height: 40)
                .background(TwendeColor.surfaceAlt, in: .circle)
            Text(text)
                .font(TwendeFont.caption)
                .foregroundStyle(TwendeColor.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 56)
    }
}

struct AddEmergencyContactSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var digits: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L(.addContact))
                .font(TwendeFont.display)
                .foregroundStyle(TwendeColor.ink)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
            TwendeTextField(title: L(.fullName), text: $name, placeholder: L(.contactNamePlaceholder), contentType: .name)
            TwendeTextField(title: L(.phoneLabel), text: $digits, placeholder: "7XX XXX XXX", keyboard: .numberPad, contentType: .telephoneNumber, prefix: "+255")
                .onChange(of: digits) { _, newValue in
                    let cleaned = String(newValue.filter(\.isNumber).prefix(9))
                    if cleaned != newValue { digits = cleaned }
                }
            Spacer(minLength: 0)
            Button(L(.saveContact)) {
                Haptics.success()
                env.store.addEmergencyContact(name: name.trimmingCharacters(in: .whitespaces), phone: "+255" + digits)
                dismiss()
            }
            .buttonStyle(.twendePrimary)
            .disabled(name.trimmingCharacters(in: .whitespaces).count < 2 || digits.count < 9)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}
