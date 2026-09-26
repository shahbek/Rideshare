import Foundation

/// Localised wording for mobile money outcomes, shared by the top-up screen and the ride completion sheet.
enum MobileMoneyCopy {
    static func failureTitle(_ reason: MobileMoneyFailure?) -> String {
        switch reason {
        case .declined: L(.mmFailDeclined)
        case .wrongPin: L(.mmFailWrongPin)
        case .timeout: L(.mmFailTimeout)
        case .insufficientFunds: L(.mmFailFunds)
        case .network, .rejected, .none: L(.mmFailOther)
        }
    }

    static func failureBody(_ reason: MobileMoneyFailure?, method: PaymentMethod) -> String {
        switch reason {
        case .declined: L(.mmFailDeclinedBody)
        case .wrongPin: L(.mmFailWrongPinBody)
        case .timeout: L(.mmFailTimeoutBody)
        case .insufficientFunds: L(.mmFailFundsBody, method.displayName)
        case .network, .rejected, .none: L(.mmFailOtherBody)
        }
    }

    static func startFailure(_ error: Error) -> String {
        if case let PaymentGatewayError.rejected(message) = error { return message }
        return L(.mmStartFailed)
    }
}
