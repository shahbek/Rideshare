import SwiftUI

/// Account and Activity navigation. On the phone it is a normal stack; on iPhone Duo's open inner display
/// the list stays left of the fold and the chosen page (plus anything pushed from it) opens on the right.
struct MenuSplitStack<ListContent: View>: View {
    @Environment(MenuNavigation.self) private var navigation
    @Environment(\.foldLayout) private var foldLayout
    let placeholder: Icon3D
    @ViewBuilder let list: () -> ListContent

    var body: some View {
        if foldLayout != nil {
            DuoSplitView {
                NavigationStack { list() }
            } secondary: {
                NavigationStack(path: detailPath) {
                    Group {
                        if let root = navigation.path.first {
                            MenuDestinationView(route: root)
                                .id(root)
                        } else {
                            DuoDetailPlaceholder(icon: placeholder)
                        }
                    }
                    .navigationDestination(for: MenuRoute.self) { MenuDestinationView(route: $0) }
                }
            }
        } else {
            NavigationStack(path: Bindable(navigation).path) {
                list()
                    .navigationDestination(for: MenuRoute.self) { MenuDestinationView(route: $0) }
            }
        }
    }

    /// Everything pushed on top of the detail pane's root page.
    private var detailPath: Binding<[MenuRoute]> {
        Binding(
            get: { Array(navigation.path.dropFirst()) },
            set: { tail in
                guard let root = navigation.path.first else { return }
                navigation.path = [root] + tail
            }
        )
    }
}

extension MenuNavigation {
    /// From a list pane: pushes on the phone, or replaces the detail pane when split around the fold.
    func open(_ route: MenuRoute, split: Bool) {
        if split {
            path = [route]
        } else {
            path.append(route)
        }
    }
}
