import Foundation

/// Native tab identities are independent of translated titles and booking routes.
nonisolated enum MainTab: Hashable, Sendable {
    case home
    case activity
    case account
}
