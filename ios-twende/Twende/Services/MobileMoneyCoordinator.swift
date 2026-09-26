import Foundation
import Observation

/// Owns every in-flight mobile money request: starts the PIN prompt through the payment server, polls
/// until a final answer, credits the wallet exactly once, and tells the trip coordinator about ride
/// payments. Pending requests are persisted, so a relaunch resumes polling instead of losing money.
@Observable
final class MobileMoneyCoordinator {
    /// Latest server view of each payment this session, keyed by order reference.
    private(set) var payments: [String: MobileMoneyPayment] = [:]
    /// Nil until the server has answered; false while it runs the simulated network.
    private(set) var isLive: Bool? = nil

    /// Called when a ride payment reaches a final state: (trip ID, payment).
    var onRideSettled: ((String, MobileMoneyPayment) -> Void)?
    /// Short confirmations surfaced as toasts (auto top-ups finish without any screen open).
    var announce: ((String) -> Void)?

    private let store: PassengerStore
    private let gateway = PaymentGateway()
    private var pollers: [String: Task<Void, Never>] = [:]
    private static let pollInterval: Duration = .seconds(2)
    /// A prompt that never resolves is abandoned client-side after this long; no money is credited.
    private static let abandonAfter: TimeInterval = 180

    init(store: PassengerStore) {
        self.store = store
    }

    /// Re-attaches pollers to requests that were pending when the app last closed.
    func resume() {
        for pending in store.pendingMobileMoney where pollers[pending.reference] == nil {
            if Date().timeIntervalSince(pending.createdAt) > Self.abandonAfter * 4 {
                store.removePendingMobileMoney(reference: pending.reference)
                continue
            }
            poll(pending)
        }
        Task { [weak self] in
            guard let self else { return }
            if let config = try? await self.gateway.config() { self.isLive = config.live }
        }
    }

    func payment(_ reference: String?) -> MobileMoneyPayment? {
        guard let reference else { return nil }
        return payments[reference]
    }

    /// Most recent request made for a trip, if any.
    func latestPayment(forTrip tripID: String) -> MobileMoneyPayment? {
        let references = store.pendingMobileMoney.filter { $0.tripID == tripID }.map(\.reference) + rideReferences[tripID, default: []]
        return references.compactMap { payments[$0] }.last
    }

    private var rideReferences: [String: [String]] = [:]

    /// Sends the PIN prompt and returns the order reference. Throws a user-presentable error.
    @discardableResult
    func start(amount: Int, method: PaymentMethod, purpose: MobileMoneyPurpose, tripID: String? = nil) async throws -> String {
        guard method.isMobileMoney, let account = store.account(for: method) else {
            throw PaymentGatewayError.rejected(L(.topUpNoRails))
        }
        let payment = try await gateway.collect(amount: amount, phone: account.phone, method: method, purpose: purpose)
        payments[payment.orderReference] = payment
        isLive = payment.live
        let pending = PendingMobileMoney(
            reference: payment.orderReference,
            amount: amount,
            method: method,
            purpose: purpose,
            tripID: tripID,
            createdAt: Date()
        )
        store.addPendingMobileMoney(pending)
        if let tripID { rideReferences[tripID, default: []].append(payment.orderReference) }
        poll(pending)
        return payment.orderReference
    }

    /// Test mode: approve with a PIN, decline, or report insufficient funds on the simulated prompt.
    func simulate(reference: String, action: String, pin: String? = nil) async {
        do {
            let updated = try await gateway.simulate(reference: reference, action: action, pin: pin)
            apply(updated)
        } catch {
            print("[MobileMoney] Simulated action failed")
        }
    }

    /// Fires a single auto top-up when the rule is on and the balance has dropped below the threshold.
    func checkAutoTopUp() {
        let rule = store.autoTopUp
        guard rule.isEnabled, let method = rule.method, store.account(for: method) != nil,
              store.walletBalance < rule.threshold,
              !store.pendingMobileMoney.contains(where: { $0.purpose == .autoTopUp }) else { return }
        let amount = min(rule.amount, store.walletTopUpHeadroom)
        guard amount >= WalletRules.minimumTopUp else { return }
        Task { [weak self] in
            do {
                try await self?.start(amount: amount, method: method, purpose: .autoTopUp)
            } catch {
                print("[MobileMoney] Auto top-up could not start")
            }
        }
    }

    // MARK: Polling

    private func poll(_ pending: PendingMobileMoney) {
        pollers[pending.reference]?.cancel()
        pollers[pending.reference] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled else { return }
                do {
                    let payment = try await self.gateway.status(reference: pending.reference)
                    self.apply(payment)
                    if payment.isTerminal { return }
                } catch PaymentGatewayError.rejected {
                    // The server no longer knows this reference: drop it without crediting.
                    self.store.removePendingMobileMoney(reference: pending.reference)
                    self.pollers[pending.reference] = nil
                    return
                } catch {
                    // Offline or transient: keep polling until the abandon window closes.
                }
                if Date().timeIntervalSince(pending.createdAt) > Self.abandonAfter, self.payments[pending.reference]?.isTerminal != true {
                    var expired = self.payments[pending.reference] ?? MobileMoneyPayment(
                        orderReference: pending.reference, status: .pending, reason: nil, message: nil,
                        amount: pending.amount, method: pending.method, purpose: pending.purpose, live: self.isLive ?? false, expiresAt: nil
                    )
                    expired.status = .failed
                    expired.reason = .timeout
                    self.apply(expired)
                    return
                }
            }
        }
    }

    private func apply(_ payment: MobileMoneyPayment) {
        let previous = payments[payment.orderReference]
        payments[payment.orderReference] = payment
        guard payment.isTerminal, previous?.isTerminal != true else { return }
        pollers[payment.orderReference]?.cancel()
        pollers[payment.orderReference] = nil
        let pending = store.pendingMobileMoney.first { $0.reference == payment.orderReference }

        switch payment.purpose {
        case .topUp, .autoTopUp:
            if payment.status == .success {
                let automatic = payment.purpose == .autoTopUp
                let credited = store.creditConfirmedTopUp(
                    reference: payment.orderReference,
                    amount: payment.amount,
                    from: payment.method,
                    automatic: automatic
                )
                if credited {
                    Haptics.success()
                    if automatic { announce?(L(.autoTopUpDone, Format.tzs(payment.amount))) }
                }
            } else {
                store.removePendingMobileMoney(reference: payment.orderReference)
            }
        case .ride:
            store.removePendingMobileMoney(reference: payment.orderReference)
            if let tripID = pending?.tripID ?? rideReferences.first(where: { $0.value.contains(payment.orderReference) })?.key {
                onRideSettled?(tripID, payment)
            }
        }
    }
}
