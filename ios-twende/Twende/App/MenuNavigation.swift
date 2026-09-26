import Observation

/// Scoped to one navigation stack: Account, Activity and contextual modal visits never share a path.
@Observable
final class MenuNavigation {
    var path: [MenuRoute] = []

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }
}
