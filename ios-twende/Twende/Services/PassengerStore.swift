import Foundation
import Observation

/// Single owner of persisted passenger data. Every mutation goes through `mutate` and is saved immediately.
@Observable
final class PassengerStore {
    private(set) var data: PassengerData
    /// Called after every saved change so the signed-in account can be backed up to the server.
    @ObservationIgnored var didChange: ((PassengerData) -> Void)?

    init() {
        data = Persistence.load(PassengerData.self, key: Persistence.Key.passenger) ?? .empty
    }

    private func mutate(_ body: (inout PassengerData) -> Void) {
        var copy = data
        body(&copy)
        data = copy
        Persistence.save(copy, key: Persistence.Key.passenger)
        didChange?(copy)
    }

    /// Replaces local data with the copy restored from the passenger's account (no upload back).
    func restore(from remote: PassengerData) {
        data = remote
        Persistence.save(remote, key: Persistence.Key.passenger)
    }

    // MARK: Profile

    var profile: PassengerProfile? { data.profile }

    var firstName: String {
        guard let name = data.profile?.name else { return "" }
        return String(name.split(separator: " ").first ?? Substring(name))
    }

    func createProfile(name: String, phone: String, email: String) {
        mutate { $0.profile = PassengerProfile(name: name, phone: phone, email: email, joinedAt: Date()) }
        seedDemoDataIfNeeded()
    }

    func updateProfile(name: String, email: String) {
        mutate { data in
            data.profile?.name = name
            data.profile?.email = email
        }
    }

    // MARK: Saved places

    var savedPlaces: [SavedPlace] { data.savedPlaces }

    func savedPlace(kind: SavedPlaceKind) -> SavedPlace? {
        data.savedPlaces.first { $0.kind == kind }
    }

    func savedPlace(id: String) -> SavedPlace? {
        data.savedPlaces.first { $0.id == id }
    }

    func upsertSavedPlace(id: String? = nil, kind: SavedPlaceKind, label: String, place: Place) {
        mutate { data in
            if let id, let index = data.savedPlaces.firstIndex(where: { $0.id == id }) {
                data.savedPlaces[index] = SavedPlace(id: id, kind: kind, label: label, place: place)
            } else if kind != .other, let index = data.savedPlaces.firstIndex(where: { $0.kind == kind }) {
                let existing = data.savedPlaces[index]
                data.savedPlaces[index] = SavedPlace(id: existing.id, kind: kind, label: label, place: place)
            } else {
                data.savedPlaces.append(SavedPlace(kind: kind, label: label, place: place))
            }
        }
    }

    func removeSavedPlace(id: String) {
        mutate { $0.savedPlaces.removeAll { $0.id == id } }
    }

    // MARK: Recents

    var recents: [RecentPlace] {
        data.recents.sorted { $0.lastUsed > $1.lastUsed }
    }

    func addRecent(_ place: Place) {
        mutate { data in
            data.recents.removeAll { $0.place.name == place.name }
            data.recents.insert(RecentPlace(place: place, lastUsed: Date()), at: 0)
            if data.recents.count > 8 {
                data.recents = Array(data.recents.prefix(8))
            }
        }
    }

    // MARK: Favourite drivers

    var favouriteDriverIDs: [String] { data.favouriteDriverIDs }

    func isFavourite(_ id: String) -> Bool {
        data.favouriteDriverIDs.contains(id)
    }

    func addFavourite(_ id: String) {
        guard !isFavourite(id) else { return }
        mutate { $0.favouriteDriverIDs.append(id) }
    }

    func removeFavourite(_ id: String) {
        mutate { data in
            data.favouriteDriverIDs.removeAll { $0 == id }
            data.notifyWhenOnline.removeAll { $0 == id }
        }
    }

    func toggleFavourite(_ id: String) {
        isFavourite(id) ? removeFavourite(id) : addFavourite(id)
    }

    func notifiesWhenOnline(_ id: String) -> Bool {
        data.notifyWhenOnline.contains(id)
    }

    func setNotifyWhenOnline(_ id: String, enabled: Bool) {
        mutate { data in
            data.notifyWhenOnline.removeAll { $0 == id }
            if enabled { data.notifyWhenOnline.append(id) }
        }
    }

    // MARK: Payments

    var defaultPaymentMethod: PaymentMethod { data.defaultPaymentMethod }
    var mobileMoneyAccounts: [MobileMoneyAccount] { data.mobileMoneyAccounts }

    func account(for method: PaymentMethod) -> MobileMoneyAccount? {
        data.mobileMoneyAccounts.first { $0.method == method }
    }

    /// Methods the passenger can pick at checkout: cash, the Twende wallet, then linked mobile-money rails.
    var availablePaymentMethods: [PaymentMethod] {
        [.cash, .wallet] + PaymentMethod.allCases.filter { method in
            method.isMobileMoney && data.mobileMoneyAccounts.contains { $0.method == method }
        }
    }

    func setDefaultPayment(_ method: PaymentMethod) {
        mutate { $0.defaultPaymentMethod = method }
    }

    /// Links a wallet number. Call only after the server confirmed the SMS code for this number.
    func linkMobileMoney(_ method: PaymentMethod, phone: String, accountName: String? = nil) {
        mutate { data in
            data.mobileMoneyAccounts.removeAll { $0.method == method }
            data.mobileMoneyAccounts.append(
                MobileMoneyAccount(method: method, phone: phone, isEnabled: true, isVerified: true, accountName: accountName)
            )
        }
    }

    func unlinkMobileMoney(_ method: PaymentMethod) {
        mutate { data in
            data.mobileMoneyAccounts.removeAll { $0.method == method }
            if data.defaultPaymentMethod == method {
                data.defaultPaymentMethod = .cash
            }
            if data.autoTopUp.method == method {
                data.autoTopUp.isEnabled = false
                data.autoTopUp.method = nil
            }
        }
    }

    // MARK: Wallet

    var walletBalance: Int { data.walletBalance }

    var walletTransactions: [WalletTransaction] {
        data.walletTransactions.sorted { $0.at > $1.at }
    }

    func walletCanCover(_ amount: Int) -> Bool {
        data.walletBalance >= amount
    }

    /// Largest top-up accepted right now, bounded by the per-transaction cap and the balance ceiling.
    var walletTopUpHeadroom: Int {
        min(WalletRules.maximumTopUp, max(0, WalletRules.maximumBalance - data.walletBalance))
    }

    /// Credits the wallet from a linked mobile-money account. Returns false when the amount is outside
    /// the allowed range.
    @discardableResult
    func topUpWallet(_ amount: Int, from source: PaymentMethod) -> Bool {
        guard amount >= WalletRules.minimumTopUp, amount <= walletTopUpHeadroom else { return false }
        mutate { data in
            data.walletBalance += amount
            data.walletTransactions.insert(WalletTransaction(kind: .topUp, amount: amount, source: source), at: 0)
            data.walletTransactions = Array(data.walletTransactions.prefix(WalletRules.historyLimit))
        }
        return true
    }

    /// Credits a top-up the payment server has confirmed. Idempotent per order reference, so a replayed
    /// status poll or a relaunch can never add the same money twice.
    @discardableResult
    func creditConfirmedTopUp(reference: String, amount: Int, from source: PaymentMethod, automatic: Bool) -> Bool {
        guard amount > 0, !data.walletTransactions.contains(where: { $0.reference == reference }) else { return false }
        mutate { data in
            data.walletBalance += amount
            data.walletTransactions.insert(
                WalletTransaction(kind: .topUp, amount: amount, source: source, reference: reference, isAutomatic: automatic),
                at: 0
            )
            data.walletTransactions = Array(data.walletTransactions.prefix(WalletRules.historyLimit))
            data.pendingMobileMoney.removeAll { $0.reference == reference }
        }
        return true
    }

    // MARK: Mobile money requests

    var pendingMobileMoney: [PendingMobileMoney] { data.pendingMobileMoney }

    func addPendingMobileMoney(_ pending: PendingMobileMoney) {
        mutate { data in
            data.pendingMobileMoney.removeAll { $0.reference == pending.reference }
            data.pendingMobileMoney.append(pending)
        }
    }

    func removePendingMobileMoney(reference: String) {
        guard data.pendingMobileMoney.contains(where: { $0.reference == reference }) else { return }
        mutate { $0.pendingMobileMoney.removeAll { $0.reference == reference } }
    }

    var autoTopUp: AutoTopUpRule { data.autoTopUp }

    func setAutoTopUp(_ rule: AutoTopUpRule) {
        mutate { $0.autoTopUp = rule }
    }

    // MARK: Identity

    var identity: IdentityRecord? { data.identity }
    var isIdentityVerified: Bool { data.identity != nil }

    /// Saves confirmed ID details and optionally adopts the document name on the profile.
    func saveIdentity(_ record: IdentityRecord, adoptName: Bool) {
        mutate { data in
            data.identity = record
            if adoptName, !record.fullName.isEmpty {
                data.profile?.name = record.fullName.localizedCapitalized
            }
        }
    }

    func removeIdentity() {
        mutate { $0.identity = nil }
        ProfilePhotoStore.delete()
    }

    /// Debits a completed ride. Returns false when the balance is insufficient; the caller falls back.
    @discardableResult
    func chargeWallet(_ amount: Int, tripID: String, detail: String) -> Bool {
        guard amount >= 0, data.walletBalance >= amount else { return false }
        mutate { data in
            data.walletBalance -= amount
            data.walletTransactions.insert(
                WalletTransaction(kind: .ridePayment, amount: -amount, tripID: tripID, detail: detail),
                at: 0
            )
            data.walletTransactions = Array(data.walletTransactions.prefix(WalletRules.historyLimit))
        }
        return true
    }

    // MARK: Safety

    var emergencyContacts: [EmergencyContact] { data.emergencyContacts }
    var shareTripsWithContacts: Bool { data.shareTripsWithContacts }

    func addEmergencyContact(name: String, phone: String) {
        guard data.emergencyContacts.count < 3 else { return }
        mutate { $0.emergencyContacts.append(EmergencyContact(name: name, phone: phone)) }
    }

    func removeEmergencyContact(id: String) {
        mutate { $0.emergencyContacts.removeAll { $0.id == id } }
    }

    func setShareTripsWithContacts(_ enabled: Bool) {
        mutate { $0.shareTripsWithContacts = enabled }
    }

    // MARK: History

    var history: [Trip] {
        data.history.sorted { $0.createdAt > $1.createdAt }
    }

    func trip(id: String) -> Trip? {
        data.history.first { $0.id == id }
    }

    func archive(_ trip: Trip) {
        mutate { data in
            data.history.removeAll { $0.id == trip.id }
            data.history.append(trip)
        }
    }

    // MARK: Promotions & notifications

    var redeemedPromoCodes: [String] { data.redeemedPromoCodes }

    func markRedeemed(_ code: String) {
        guard !data.redeemedPromoCodes.contains(code) else { return }
        mutate { $0.redeemedPromoCodes.append(code) }
    }

    var notifyWhenDriversAvailable: Bool { data.notifyWhenDriversAvailable }

    func setNotifyWhenDriversAvailable(_ enabled: Bool) {
        mutate { $0.notifyWhenDriversAvailable = enabled }
    }

    func notifyWhenZoneOpens(_ areaName: String) {
        guard !data.notifyWhenZoneOpens.contains(areaName) else { return }
        mutate { $0.notifyWhenZoneOpens.append(areaName) }
    }

    func hasZoneNotification(_ areaName: String) -> Bool {
        data.notifyWhenZoneOpens.contains(areaName)
    }

    // MARK: Account

    func deleteAccount() {
        mutate { $0 = .empty }
        ProfilePhotoStore.delete()
        Persistence.remove(key: Persistence.Key.activeTrip)
    }

    // MARK: Demo seed

    /// Gives a brand-new account familiar favourites, saved places and a little history.
    private func seedDemoDataIfNeeded() {
        guard data.favouriteDriverIDs.isEmpty, data.history.isEmpty else { return }
        mutate { data in
            data.favouriteDriverIDs = MockDrivers.favouriteIDs
            data.notifyWhenOnline = [MockDrivers.hassanID]
            data.savedPlaces = [
                SavedPlace(kind: .home, label: L(.homeLabel), place: DemoPlaces.home),
                SavedPlace(kind: .work, label: L(.workLabel), place: DemoPlaces.work),
            ]
            data.recents = [
                RecentPlace(place: DemoPlaces.mlimaniCity, lastUsed: Date().addingTimeInterval(-86_400 * 2)),
                RecentPlace(place: DemoPlaces.kariakoo, lastUsed: Date().addingTimeInterval(-86_400 * 4)),
                RecentPlace(place: DemoPlaces.airport, lastUsed: Date().addingTimeInterval(-86_400 * 9)),
            ]
            data.history = DemoTrips.history()
            // A linked M-Pesa account and a small prepaid balance so the wallet can be tried straight away.
            if let phone = data.profile?.phone {
                data.mobileMoneyAccounts = [MobileMoneyAccount(method: .mpesa, phone: phone, isEnabled: true)]
            }
            data.walletBalance = 12_500
            data.walletTransactions = [
                WalletTransaction(
                    kind: .ridePayment,
                    amount: -2_500,
                    at: Date().addingTimeInterval(-86_400 * 3),
                    detail: DemoPlaces.kariakoo.name
                ),
                WalletTransaction(
                    kind: .topUp,
                    amount: 15_000,
                    at: Date().addingTimeInterval(-86_400 * 5),
                    source: .mpesa
                ),
            ]
        }
    }
}
