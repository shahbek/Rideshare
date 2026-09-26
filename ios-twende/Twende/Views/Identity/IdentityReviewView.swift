import SwiftUI

/// Every detail exactly as the scan read it. Nothing is typed: if a required detail is missing,
/// unclear, expired or under-age, the only way forward is to scan again.
struct IdentityReviewView: View {
    @Environment(AppEnvironment.self) private var env
    let result: IDScanResult
    let faceImage: UIImage?
    let onRescan: () -> Void
    let onConfirmed: () -> Void

    @State private var usesCardPhoto: Bool = true
    @State private var adoptsName: Bool = true

    private var givenNames: String { (result.givenNames ?? "").localizedCapitalized.trimmed }
    private var surname: String { (result.surname ?? "").localizedCapitalized.trimmed }
    private var documentNumber: String { (result.documentNumber ?? "").trimmed.uppercased() }

    private var blockingError: String? {
        if (givenNames.isEmpty && surname.isEmpty) || documentNumber.count < 4 || result.dateOfBirth == nil {
            return L(.idMissingError)
        }
        if let birth = result.dateOfBirth, IdentityRules.age(bornOn: birth) < IdentityRules.minimumAge { return L(.idUnderageError) }
        if let expiry = result.expiryDate, IdentityRules.isExpired(expiry) { return L(.idExpiredError) }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if result.verifiedByChecksum {
                        Label(L(.idChecksumOK), systemImage: "checkmark.seal")
                            .font(TwendeFont.captionMedium)
                            .foregroundStyle(TwendeColor.ink)
                    }
                    VStack(spacing: 0) {
                        RowDivider(leading: 0)
                        row(.givenNames, L(.idGivenNames), givenNames)
                        row(.surname, L(.idSurname), surname)
                        row(.documentNumber, L(.idDocumentNumber), documentNumber)
                        row(.nationality, L(.idNationality), result.nationality ?? "")
                        row(.sex, L(.idSex), result.sex.map(IdentityCopy.sexName) ?? "")
                        row(.dateOfBirth, L(.idDateOfBirth), result.dateOfBirth.map(Self.format) ?? "")
                        row(.expiryDate, L(.idExpiry), result.expiryDate.map(Self.format) ?? "")
                    }

                    VStack(spacing: 0) {
                        if faceImage != nil {
                            Toggle(isOn: $usesCardPhoto) {
                                Text(L(.idUseCardPhoto)).font(TwendeFont.bodyMedium).foregroundStyle(TwendeColor.ink)
                            }
                            .tint(TwendeColor.primary)
                            .frame(minHeight: 56)
                            RowDivider(leading: 0)
                        }
                        Toggle(isOn: $adoptsName) {
                            Text(L(.idUseName)).font(TwendeFont.bodyMedium).foregroundStyle(TwendeColor.ink)
                        }
                        .tint(TwendeColor.primary)
                        .frame(minHeight: 56)
                        RowDivider(leading: 0)
                    }

                    Text(L(.idPrimerBullet2))
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 16)
            }

            VStack(spacing: 4) {
                if let blockingError {
                    Text(blockingError)
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.amberText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                    Button(L(.idRescan), action: onRescan)
                        .buttonStyle(.twendePrimary)
                        .accessibilityIdentifier("id.review.rescan")
                } else {
                    Button(L(.idConfirm)) { confirm() }
                        .buttonStyle(.twendePrimary)
                        .accessibilityIdentifier("id.review.confirm")
                    Button(L(.idRescan), action: onRescan)
                        .buttonStyle(.twendeGhost)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(TwendeColor.surface)
        }
        .background(TwendeColor.surface.ignoresSafeArea())
        .onAppear { usesCardPhoto = faceImage != nil }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L(.idReviewTitle))
                    .font(TwendeFont.display)
                    .foregroundStyle(TwendeColor.ink)
                Text(IdentityCopy.kindName(result.kind))
                    .font(TwendeFont.captionMedium)
                    .foregroundStyle(TwendeColor.accentText)
                Text(L(.idReviewSubtitle))
                    .font(TwendeFont.body)
                    .foregroundStyle(TwendeColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let faceImage, usesCardPhoto {
                Color(TwendeColor.surfaceAlt)
                    .frame(width: 72, height: 88)
                    .overlay {
                        Image(uiImage: faceImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .allowsHitTesting(false)
                    }
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TwendeColor.border, lineWidth: 1))
                    .accessibilityHidden(true)
            }
        }
    }

    private func row(_ id: IDField, _ title: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(value.isEmpty ? "—" : value)
                        .font(TwendeFont.bodyMedium)
                        .foregroundStyle(TwendeColor.ink)
                        .multilineTextAlignment(.trailing)
                    if result.uncertain.contains(id) {
                        Text(L(.idCheckField))
                            .font(TwendeFont.label)
                            .foregroundStyle(TwendeColor.amberText)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .padding(.vertical, 14)
            .frame(minHeight: 52)
            RowDivider(leading: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private static func format(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: TimeZone(identifier: "UTC") ?? .current))
    }

    private func confirm() {
        guard blockingError == nil else { return }
        let keepPhoto = usesCardPhoto && faceImage != nil
        if keepPhoto, let faceImage { ProfilePhotoStore.save(faceImage) } else { ProfilePhotoStore.delete() }
        let record = IdentityRecord(
            kind: result.kind,
            givenNames: givenNames,
            surname: surname,
            documentNumber: documentNumber,
            nationality: (result.nationality ?? "").uppercased(),
            sex: result.sex ?? .unspecified,
            dateOfBirth: result.dateOfBirth,
            expiryDate: result.expiryDate,
            verifiedAt: Date(),
            usesCardPhoto: keepPhoto
        )
        env.store.saveIdentity(record, adoptName: adoptsName)
        Haptics.success()
        env.flow.showToast(L(.idSaved), symbol: "checkmark.seal.fill")
        onConfirmed()
    }
}

/// Localised names for document kinds and sex.
enum IdentityCopy {
    static func kindName(_ kind: IdentityDocumentKind) -> String {
        switch kind {
        case .nida: L(.idKindNida)
        case .passport: L(.idKindPassport)
        case .nationalID: L(.idKindNationalID)
        case .drivingLicence: L(.idKindDriving)
        case .residencePermit: L(.idKindResidence)
        case .other: L(.idKindOther)
        }
    }

    static func sexName(_ sex: IdentitySex) -> String {
        switch sex {
        case .female: L(.idSexFemale)
        case .male: L(.idSexMale)
        case .unspecified: L(.idSexUnspecified)
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
