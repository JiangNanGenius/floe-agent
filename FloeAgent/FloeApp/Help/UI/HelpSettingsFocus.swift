// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

private struct HelpSettingsControlKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

struct HelpSettingsOpenAction: Sendable {
    let action: (@MainActor @Sendable (HelpSettingsTarget) -> Void)?

    init(_ action: (@MainActor @Sendable (HelpSettingsTarget) -> Void)? = nil) {
        self.action = action
    }

    @MainActor
    func callAsFunction(_ target: HelpSettingsTarget) { action?(target) }
}

private struct HelpSettingsOpenActionKey: EnvironmentKey {
    static let defaultValue = HelpSettingsOpenAction()
}

extension EnvironmentValues {
    var helpSettingsOpenAction: HelpSettingsOpenAction {
        get { self[HelpSettingsOpenActionKey.self] }
        set { self[HelpSettingsOpenActionKey.self] = newValue }
    }

    var helpSettingsControlID: String? {
        get { self[HelpSettingsControlKey.self] }
        set { self[HelpSettingsControlKey.self] = newValue }
    }
}

private struct HelpSettingsAnchorsKey: PreferenceKey {
    static let defaultValue: Set<String> = []
    static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) {
        value.formUnion(nextValue())
    }
}

private struct HelpSettingsControlAnchor: ViewModifier {
    @Environment(\.helpSettingsControlID) private var selectedControlID
    let controlID: String

    func body(content: Content) -> some View {
        content
            .id(controlID)
            .preference(key: HelpSettingsAnchorsKey.self, value: [controlID])
            .listRowBackground(selectedControlID == controlID ? Color.accentColor.opacity(0.10) : nil)
    }
}

extension View {
    /// Attach only to a real native control. This does not mutate its value.
    func helpSettingsControlAnchor(_ controlID: String) -> some View {
        modifier(HelpSettingsControlAnchor(controlID: controlID))
    }
}

struct HelpSettingsFocusContainer<Content: View>: View {
    let target: HelpSettingsTarget?
    @ViewBuilder let content: () -> Content
    @State private var locatedControlID: String?

    var body: some View {
        ScrollViewReader { proxy in
            content()
                .environment(\.helpSettingsControlID, target?.controlID)
                .task(id: target?.controlID) {
                    guard let id = target?.controlID else { return }
                    // Form rows are lazy: issue the native id-based scroll
                    // before waiting for an offscreen row's preference.
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
                .onPreferenceChange(HelpSettingsAnchorsKey.self) { anchors in
                    guard let id = target?.controlID, anchors.contains(id), locatedControlID != id else { return }
                    locatedControlID = id
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: target?.id) { _, _ in locatedControlID = nil }
        }
    }
}

enum HelpSettingsNestedPage: Hashable {
    case voiceOutput
}

struct HelpSettingsRoutePlan: Equatable {
    let target: HelpSettingsTarget
    let categoryID: String
    let nestedPage: HelpSettingsNestedPage?

    init?(target: HelpSettingsTarget, language: HelpLanguage) {
        // Native ids are the authority; remote paths/titles never become routes.
        guard let native = HelpSettingsCatalog.target(id: target.id, language: language),
              native.category == "general" || native.category == "execution" else { return nil }
        self.target = native
        categoryID = native.category
        nestedPage = native.nestedPage == "voiceOutput" ? .voiceOutput : nil
    }
}
#endif
