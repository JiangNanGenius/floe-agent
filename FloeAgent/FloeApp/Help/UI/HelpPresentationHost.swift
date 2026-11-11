// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import FloeCore

private struct HelpSceneIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private struct HelpContentCenterKey: EnvironmentKey {
    static let defaultValue: HelpContentCenter? = nil
}

private struct HelpPresentationDismissedAction: Sendable {
    var action: (@MainActor @Sendable (UUID) -> Void)?
    @MainActor func callAsFunction(_ id: UUID) { action?(id) }
}

private struct HelpPresentationDismissedKey: EnvironmentKey {
    static let defaultValue = HelpPresentationDismissedAction()
}

extension EnvironmentValues {
    fileprivate var helpPresentationDidDismiss: HelpPresentationDismissedAction {
        get { self[HelpPresentationDismissedKey.self] }
        set { self[HelpPresentationDismissedKey.self] = newValue }
    }
    var helpContentCenter: HelpContentCenter? {
        get { self[HelpContentCenterKey.self] }
        set { self[HelpContentCenterKey.self] = newValue }
    }
    var helpSceneID: String? {
        get { self[HelpSceneIDKey.self] }
        set { self[HelpSceneIDKey.self] = newValue }
    }
}

extension View {
    func helpPresentationHost(
        center: HelpContentCenter,
        sceneID: String,
        currentConversationID: UUID?,
        currentRunID: UUID? = nil,
        coordinator: HelpPresentationCoordinator = .shared,
        settingsDestination: (@MainActor (HelpSettingsTarget) -> AnyView)? = nil,
        onOpenSettings: @escaping (HelpSettingsTarget) -> Void
    ) -> some View {
        modifier(HelpPresentationHost(center: center, sceneID: sceneID,
            currentConversationID: currentConversationID, currentRunID: currentRunID,
            coordinator: coordinator, settingsDestination: settingsDestination,
            onOpenSettings: onOpenSettings))
    }
}

private struct HelpHostSettingsPresentation: Identifiable {
    let id = UUID()
    let target: HelpSettingsTarget
    let hostID: UUID
    let conversationID: UUID
}

private enum HelpHostModal: Identifiable {
    case guide(HelpPresentation)
    case settings(HelpHostSettingsPresentation)

    var id: String {
        switch self {
        case .guide(let presentation): "guide:" + presentation.id.uuidString
        case .settings(let presentation): "settings:" + presentation.id.uuidString
        }
    }
}

/// Install exactly once on a visible task surface. Scene/run identity is passed
/// by native owners; neither a URL nor model-authored parameters can supply it.
private struct HelpPresentationHost: ViewModifier {
    @ObservedObject var center: HelpContentCenter
    let sceneID: String
    let currentConversationID: UUID?
    let currentRunID: UUID?
    @ObservedObject var coordinator: HelpPresentationCoordinator
    let settingsDestination: (@MainActor (HelpSettingsTarget) -> AnyView)?
    let onOpenSettings: (HelpSettingsTarget) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var hostID: UUID?
    @State private var pendingSettingsTarget: (presentationID: UUID, target: HelpSettingsTarget)?
    @State private var displayedModalID: String?
    @State private var localSettings: HelpHostSettingsPresentation?
    @State private var settingsSessionID: UUID?
    @State private var availableWidth = 0.0

    func body(content: Content) -> some View {
        content
            .environment(\.helpContentCenter, center)
            .environment(\.helpSettingsOpenAction, HelpSettingsOpenAction { requestSettings($0) })
            .environment(\.helpPresentationDidDismiss, dismissedAction)
            .sheet(item: modalBinding) { modal in
                switch modal {
                case .guide(let presentation):
                    HelpPresentedContent(center: center, presentation: presentation,
                        coordinator: coordinator,
                        onOpenSettings: { stageSettings($0, after: presentation.id) })
                        .environment(\.helpPresentationDidDismiss, dismissedAction)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        .onAppear { displayedModalID = modal.id }
                case .settings(let presentation):
                    if let settingsDestination {
                        settingsDestination(presentation.target)
                            .presentationSizing(.page)
                            .onAppear { displayedModalID = modal.id }
                            .background {
                                HelpPresentationAppearanceProbe(onVisible: {}, onHidden: {
                                    finishLocalSettings(presentationID: presentation.id)
                                }).frame(width: 0, height: 0)
                            }
                    }
                }
            }
            .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { availableWidth = $0 }
            .onAppear { register() }
            .onDisappear {
                if let hostID { coordinator.unregisterHost(hostID) }
                hostID = nil
                pendingSettingsTarget = nil
                displayedModalID = nil
                localSettings = nil
                settingsSessionID = nil
            }
            .onChange(of: currentConversationID) { _, _ in
                pendingSettingsTarget = nil
                localSettings = nil
                settingsSessionID = nil
                update()
            }
            .onChange(of: currentRunID) { _, _ in update() }
            .onChange(of: scenePhase) { _, _ in update() }
            .onChange(of: availableWidth) { _, _ in update() }
            .onChange(of: horizontalSizeClass) { _, _ in update() }
            .onChange(of: center.isPrepared) { _, _ in update() }
            .task {
                await center.prepare()
                // isPrepared's observed change updates the latest host value;
                // an old async view capture must never restore an earlier run.
            }
    }

    private var modalBinding: Binding<HelpHostModal?> {
        Binding {
            if let localSettings, localSettings.hostID == hostID,
               localSettings.conversationID == currentConversationID {
                return .settings(localSettings)
            }
            let current = coordinator.presentation(for: hostID)
            return current.flatMap { $0.layout == .sheet ? .guide($0) : nil }
        } set: { next in
            guard next == nil else { return }
            if let current = localSettings, displayedModalID == HelpHostModal.settings(current).id {
                localSettings = nil
                // Keep the host unavailable until the actual native dismissal.
                update()
                return
            }
            guard let current = coordinator.presentation(for: hostID), current.layout == .sheet,
                  displayedModalID == HelpHostModal.guide(current).id else { return }
            coordinator.dismiss(presentationID: current.id, hostID: current.hostID)
        }
    }

    private func register() {
        guard hostID == nil, !sceneID.isEmpty else { update(); return }
        hostID = coordinator.registerHost(sceneID: sceneID,
            currentConversationID: currentConversationID, currentRunID: currentRunID,
            isActive: isInteractionReady,
            prefersPopover: prefersPopover) { reference in
                guard let snapshot = try? center.snapshot(for: reference),
                      snapshot.article(id: reference.articleID) != nil else { return false }
                return (try? snapshot.reference(articleID: reference.articleID,
                                                sectionID: reference.sectionID)) != nil
            }
    }

    private func update() {
        guard let hostID else { return }
        coordinator.updateHost(hostID, currentConversationID: currentConversationID,
                               currentRunID: currentRunID,
                               isActive: isInteractionReady,
                               prefersPopover: prefersPopover)
    }

    private var prefersPopover: Bool { horizontalSizeClass == .regular && availableWidth >= 600 }

    private var isInteractionReady: Bool {
        scenePhase == .active && center.isPrepared && availableWidth > 0
            && pendingSettingsTarget == nil && settingsSessionID == nil
    }

    private var dismissedAction: HelpPresentationDismissedAction {
        HelpPresentationDismissedAction { finishSettingsNavigation(presentationID: $0) }
    }

    private func requestSettings(_ target: HelpSettingsTarget) {
        guard hostID != nil, currentConversationID != nil, scenePhase == .active,
              settingsSessionID == nil else { return }
        if let current = coordinator.presentation(for: hostID) {
            stageSettings(target, after: current.id)
            return
        }
        openSettings(target)
    }

    private func stageSettings(_ target: HelpSettingsTarget, after presentationID: UUID) {
        guard let current = coordinator.presentation(for: hostID), current.id == presentationID,
              current.owner.conversationID == currentConversationID, scenePhase == .active else { return }
        pendingSettingsTarget = (presentationID, target)
        coordinator.dismiss(presentationID: current.id, hostID: current.hostID)
        update()
    }

    private func openSettings(_ target: HelpSettingsTarget) {
        guard let hostID, let conversationID = currentConversationID,
              scenePhase == .active, settingsSessionID == nil else { return }
        guard settingsDestination != nil else { update(); onOpenSettings(target); return }
        let presentation = HelpHostSettingsPresentation(target: target, hostID: hostID,
                                                       conversationID: conversationID)
        settingsSessionID = presentation.id
        localSettings = presentation
        update()
    }

    private func finishSettingsNavigation(presentationID: UUID) {
        if displayedModalID == "guide:" + presentationID.uuidString { displayedModalID = nil }
        guard let request = pendingSettingsTarget, request.presentationID == presentationID else { return }
        pendingSettingsTarget = nil
        guard hostID != nil, currentConversationID != nil, scenePhase == .active else { return }
        openSettings(request.target)
    }

    private func finishLocalSettings(presentationID: UUID) {
        guard settingsSessionID == presentationID else { return }
        settingsSessionID = nil
        if localSettings?.id == presentationID { localSettings = nil }
        if displayedModalID == "settings:" + presentationID.uuidString { displayedModalID = nil }
        update()
    }
}

struct HelpPresentedContent: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.helpPresentationDidDismiss) private var hostDidDismiss
    let center: HelpContentCenter
    let presentation: HelpPresentation
    let coordinator: HelpPresentationCoordinator
    let onOpenSettings: (HelpSettingsTarget) -> Void
    var onDismissed: () -> Void = {}

    private var copy: HelpCopy { .init(language: presentation.reference.language) }

    var body: some View {
        NavigationStack {
            HelpRelatedHelpView(center: center, reference: presentation.reference) { target in
                onOpenSettings(target)
                coordinator.dismiss(presentationID: presentation.id, hostID: presentation.hostID)
                dismiss()
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(copy.close) {
                    coordinator.dismiss(presentationID: presentation.id, hostID: presentation.hostID)
                    dismiss()
                }
                .accessibilityIdentifier("help.presentation.close")
            }
        }
        .background {
            HelpPresentationAppearanceProbe(onVisible: {
                coordinator.confirmVisible(presentationID: presentation.id, hostID: presentation.hostID)
            }, onHidden: {
                onDismissed()
                hostDidDismiss(presentation.id)
            })
            .frame(width: 0, height: 0)
        }
        .onDisappear {
            coordinator.dismiss(presentationID: presentation.id, hostID: presentation.hostID)
        }
    }
}

private struct HelpPresentationAppearanceProbe: UIViewControllerRepresentable {
    let onVisible: () -> Void
    var onHidden: () -> Void = {}

    func makeUIViewController(context: Context) -> ProbeController {
        let controller = ProbeController()
        controller.onVisible = onVisible
        controller.onHidden = onHidden
        return controller
    }

    func updateUIViewController(_ controller: ProbeController, context: Context) {
        controller.onVisible = onVisible
        controller.onHidden = onHidden
    }

    final class ProbeController: UIViewController {
        var onVisible: (() -> Void)?
        var onHidden: (() -> Void)?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let windowScene = view.window?.windowScene,
                  windowScene.activationState == .foregroundActive else { return }
            onVisible?()
        }
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            onHidden?()
        }
    }
}
#endif
