// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Supplied only by the existing phone shell, never by the iPad split,
/// sidebar drawer, inspector or app-root modal presenters.
typealias PhoneSidebarAction = @MainActor @Sendable () -> Void
private struct PhoneSidebarActionKey: EnvironmentKey {
    static let defaultValue: PhoneSidebarAction? = nil
}
extension EnvironmentValues {
    var phoneSidebarAction: PhoneSidebarAction? {
        get { self[PhoneSidebarActionKey.self] }
        set { self[PhoneSidebarActionKey.self] = newValue }
    }
}

struct PhoneSidebarButton: View {
    @Environment(\.phoneSidebarAction) private var openSidebar
    var body: some View {
        if let openSidebar {
            Button(action: openSidebar) {
                Label("app.floe_agent_app.open_task_list", systemImage: "sidebar.left")
                    .labelStyle(.iconOnly)
            }
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel("app.floe_agent_app.open_task_list")
            .accessibilityIdentifier("phone.sidebar.open")
        }
    }
}

/// Attach INSIDE a destination's existing navigation container. Native bar
/// layout owns Back/Cancel, title truncation and trailing actions; no
/// floating control or extra safe-area row competes with those items.
struct PhoneRootNavigationToolbar: ViewModifier {
    @Environment(\.phoneSidebarAction) private var openSidebar
    @ViewBuilder func body(content: Content) -> some View {
        if openSidebar != nil {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbarBackground(FloeTheme.readingSurface, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { PhoneSidebarButton() }
                }
        } else {
            content
        }
    }
}

/// Only formerly bare phone destinations use this per-feature container.
/// The iPad branch returns the same content to its existing split; routes
/// already owning a stack use the toolbar modifier inside that stack.
struct PhoneRootNavigationContainer<Content: View>: View {
    @Environment(\.phoneSidebarAction) private var openSidebar
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    @ViewBuilder var body: some View {
        if openSidebar != nil {
            NavigationStack { content.modifier(PhoneRootNavigationToolbar()) }
        } else {
            content
        }
    }
}
#endif
