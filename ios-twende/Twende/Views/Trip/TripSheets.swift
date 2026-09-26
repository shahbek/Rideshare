import SwiftUI
import UIKit

/// B7a — reason for cancelling, with the "driver asked me to cancel" flag that waives the fee.
struct CancelReasonSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var selected: CancelReason? = nil

    private var fee: Int {
        selected == .driverAskedToCancel ? 0 : env.trips.cancellationFeePreview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L(.cancelReasonTitle))
                .font(TwendeFont.display)
                .foregroundStyle(TwendeColor.ink)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
            Text(L(.cancelReasonBody))
                .font(TwendeFont.caption)
                .foregroundStyle(TwendeColor.inkSecondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(CancelReason.allCases) { reason in
                        ReasonRow(
                            title: L(reason.key),
                            isFlagged: reason == .driverAskedToCancel,
                            isSelected: selected == reason
                        ) {
                            Haptics.selection()
                            selected = reason
                        }
                    }
                }
            }

            if fee > 0 {
                Label(L(.cancellationFeeNotice, Format.tzs(fee)), systemImage: "info.circle.fill")
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.amberText)
            } else if selected == .driverAskedToCancel {
                Label(L(.driverAskedNotice), systemImage: "flag.fill")
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.badgeForeground)
            }

            Button(fee > 0 ? L(.cancelWithFee, Format.tzs(fee)) : L(.confirmCancel)) {
                guard let selected else { return }
                Haptics.warning()
                env.trips.cancel(reason: selected)
                dismiss()
            }
            .buttonStyle(.twendeSecondary)
            .disabled(selected == nil)

            Button(L(.keepRide)) { dismiss() }
                .buttonStyle(.twendePrimary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

struct ReasonRow: View {
    let title: String
    var isFlagged: Bool = false
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RadioDot(isSelected: isSelected)
                Text(title)
                    .font(TwendeFont.body)
                    .foregroundStyle(TwendeColor.ink)
                    .multilineTextAlignment(.leading)
                Spacer()
                if isFlagged {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(TwendeColor.inkSecondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 56)
            .background(TwendeColor.surface, in: .rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? TwendeColor.ink : TwendeColor.border, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.pressableCard)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// B7b — two-step SOS: pick who to reach, then confirm. Danger red lives only here.
struct SOSSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingCall: Bool = false
    @State private var didAlertContacts: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "sos.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(TwendeColor.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(.sosTitle))
                        .font(TwendeFont.display)
                        .foregroundStyle(TwendeColor.ink)
                    Text(L(.sosBody))
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                }
            }

            if let trip = env.trips.activeTrip, let driver = env.trips.assignedDriver {
                HStack(spacing: 10) {
                    PlateView(plate: driver.vehicle.plate, size: .small)
                    Text(driver.vehicle.description)
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                    Spacer()
                    Text(trip.id)
                        .font(TwendeFont.label)
                        .foregroundStyle(TwendeColor.inkSecondary)
                }
                .padding(12)
                .cardSurface(cornerRadius: 12)
            }

            if confirmingCall {
                VStack(spacing: 10) {
                    Text(L(.sosConfirmCall))
                        .font(TwendeFont.bodyMedium)
                        .foregroundStyle(TwendeColor.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        Haptics.error()
                        if let url = URL(string: "tel://112") { UIApplication.shared.open(url) }
                        dismiss()
                    } label: {
                        Label(L(.sosCallNow), systemImage: "phone.fill")
                    }
                    .buttonStyle(.twendeDanger)
                    Button(L(.back)) { confirmingCall = false }
                        .buttonStyle(.twendeGhost)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: 10) {
                    Button {
                        Haptics.warning()
                        withAnimation(.spring(duration: 0.3)) { confirmingCall = true }
                    } label: {
                        Label(L(.sosCallPolice), systemImage: "phone.fill")
                    }
                    .buttonStyle(.twendeDanger)

                    Button {
                        Haptics.success()
                        didAlertContacts = true
                    } label: {
                        Label(
                            didAlertContacts ? L(.sosContactsAlerted) : L(.sosAlertContacts, env.store.emergencyContacts.count),
                            systemImage: didAlertContacts ? "checkmark.circle.fill" : "person.2.wave.2.fill"
                        )
                    }
                    .buttonStyle(.twendeSecondary)
                    .disabled(env.store.emergencyContacts.isEmpty || didAlertContacts)

                    if env.store.emergencyContacts.isEmpty {
                        Button(L(.addEmergencyContacts)) {
                            dismiss()
                            env.flow.openMenuAfterSheet(at: .safety)
                        }
                        .font(TwendeFont.captionMedium)
                        .foregroundStyle(TwendeColor.badgeForeground)
                        .frame(minHeight: 44)
                    }

                    Button(L(.close)) { dismiss() }
                        .buttonStyle(.twendeGhost)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

extension CancelReason {
    var key: LKey {
        switch self {
        case .waitTooLong: .cancelWaitTooLong
        case .driverNotMoving: .cancelDriverNotMoving
        case .wrongPickup: .cancelWrongPickup
        case .changedPlans: .cancelChangedPlans
        case .driverAskedToCancel: .cancelDriverAsked
        case .other: .cancelOther
        }
    }
}

extension RatingReason {
    var key: LKey {
        switch self {
        case .route: .ratingReasonRoute
        case .driving: .ratingReasonDriving
        case .vehicle: .ratingReasonVehicle
        case .behaviour: .ratingReasonBehaviour
        case .late: .ratingReasonLate
        case .price: .ratingReasonPrice
        }
    }
}
