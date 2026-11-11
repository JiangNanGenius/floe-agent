// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import FloeCore

/// A card exists only for a strict guide citation in an actual answer. It is
/// an anchor owned by the task host, never a second task presentation host.
struct HelpAnswerGuideCard: View {
    let center: HelpContentCenter
    let reference: HelpReference
    let sceneID: String
    let conversationID: UUID
    let answerRunID: UUID?
    @ObservedObject var coordinator = HelpPresentationCoordinator.shared
    @Environment(\.helpSettingsOpenAction) private var openSettings
    @StateObject private var anchor = HelpAnswerAnchorRegistration()
    @State private var document: HelpRelatedHelpDocument?
    @State private var failed = false
    @State private var pendingSettingsTarget: (presentationID: UUID, target: HelpSettingsTarget)?
    @State private var displayedPopoverID: UUID?

    private var copy: HelpCopy { .init(language: reference.language) }
    private var anchorKey: String { [sceneID, conversationID.uuidString, answerRunID?.uuidString ?? "", reference.id].joined(separator: ":") }

    var body: some View {
        Group {
            if let document {
                VStack(alignment: .leading, spacing: 10) {
                    Label(document.title, systemImage: "book")
                        .font(.subheadline.weight(.semibold))
                    ForEach(document.settingsTargets) { target in
                        Text(target.path.joined(separator: " › "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { cardActions(document) }
                        VStack(alignment: .leading, spacing: 8) { cardActions(document) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: 520, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .background { HelpAnswerAnchorProbe(registration: anchor) }
                .onAppear { registerAnchor() }
                .onDisappear { anchor.leave(); pendingSettingsTarget = nil }
                .popover(item: popoverBinding, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) { presentation in
                    HelpPresentedContent(center: center, presentation: presentation, coordinator: coordinator,
                        onOpenSettings: { pendingSettingsTarget = (presentation.id, $0) },
                        onDismissed: { finishSettingsNavigation(presentationID: presentation.id) })
                        .frame(minWidth: 320, idealWidth: 400, maxWidth: 440,
                               minHeight: 260, idealHeight: 420, maxHeight: 640)
                        .presentationCompactAdaptation(.none)
                        .onAppear { displayedPopoverID = presentation.id }
                }
            } else if failed {
                Label(copy.unavailable, systemImage: "book.closed")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onChange(of: anchorKey) { _, _ in
            pendingSettingsTarget = nil
            if document != nil { registerAnchor() }
        }
        .task(id: reference) {
            await center.prepare()
            guard !Task.isCancelled else { return }
            do { document = try HelpRelatedHelpDocument(center: center, reference: reference); failed = false }
            catch { document = nil; failed = true }
        }
        .accessibilityIdentifier("help.answerGuide.\(reference.id)")
    }

    @ViewBuilder
    private func cardActions(_ document: HelpRelatedHelpDocument) -> some View {
        if let target = document.settingsTargets.first {
            Button(copy.openSetting) { openSettings(target) }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("help.answerGuide.openSetting.\(target.id)")
        }
        Button(copy.readGuide) {
            coordinator.presentFromUser(reference: reference, sceneID: sceneID,
                currentConversationID: conversationID, preferredAnchorID: anchor.anchorID)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityIdentifier("help.answerGuide.read")
    }

    private var popoverBinding: Binding<HelpPresentation?> {
        Binding(get: { coordinator.presentation(forAnchor: anchor.anchorID) }, set: { next in
            guard next == nil, let current = coordinator.presentation(forAnchor: anchor.anchorID),
                  current.id == displayedPopoverID else { return }
            coordinator.dismiss(presentationID: current.id, hostID: current.hostID)
        })
    }

    private func registerAnchor() {
        anchor.appear(sceneID: sceneID, conversationID: conversationID, runID: answerRunID,
                      reference: reference, coordinator: coordinator)
    }

    private func finishSettingsNavigation(presentationID: UUID) {
        if displayedPopoverID == presentationID { displayedPopoverID = nil }
        guard let request = pendingSettingsTarget, request.presentationID == presentationID else { return }
        pendingSettingsTarget = nil
        guard coordinator.isCurrentAnswerAnchor(anchor.anchorID) else { return }
        openSettings(request.target)
    }
}

@MainActor
private final class HelpAnswerAnchorRegistration: ObservableObject {
    @Published private(set) var anchorID: UUID?
    private weak var view: HelpAnswerAnchorView?
    private var coordinator: HelpPresentationCoordinator?
    private var identity: String?
    private var sceneID = ""
    private var conversationID: UUID?
    private var runID: UUID?
    private var reference: HelpReference?
    private var isMounted = false

    func appear(sceneID: String, conversationID: UUID, runID: UUID?, reference: HelpReference,
                coordinator: HelpPresentationCoordinator) {
        let identity = [sceneID, conversationID.uuidString, runID?.uuidString ?? "", reference.id].joined(separator: ":")
        if self.identity != identity { unregister() }
        self.identity = identity; self.sceneID = sceneID; self.conversationID = conversationID
        self.runID = runID; self.reference = reference; self.coordinator = coordinator; isMounted = true
        registerIfReady()
    }

    func attach(_ view: HelpAnswerAnchorView) {
        guard isMounted else { self.view = view; return }
        if self.view !== view { unregister() }
        self.view = view
        registerIfReady()
    }

    func detach(_ view: HelpAnswerAnchorView) {
        guard self.view === view else { return }
        unregister(); self.view = nil
    }

    func leave() { isMounted = false; unregister() }

    private func registerIfReady() {
        guard anchorID == nil, isMounted, view != nil, let coordinator,
              let conversationID, let reference else { return }
        anchorID = coordinator.registerAnswerAnchor(sceneID: sceneID, conversationID: conversationID,
            runID: runID, reference: reference) { [weak self] in self?.view?.isActuallyVisible == true }
    }

    private func unregister() {
        if let anchorID { coordinator?.unregisterAnswerAnchor(anchorID) }
        anchorID = nil
    }
}

private struct HelpAnswerAnchorProbe: UIViewRepresentable {
    let registration: HelpAnswerAnchorRegistration
    func makeCoordinator() -> HelpAnswerAnchorRegistration { registration }
    func makeUIView(context: Context) -> HelpAnswerAnchorView {
        let view = HelpAnswerAnchorView()
        view.registration = registration
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: HelpAnswerAnchorView, context: Context) {}
    static func dismantleUIView(_ view: HelpAnswerAnchorView, coordinator: HelpAnswerAnchorRegistration) { coordinator.detach(view) }
}

private final class HelpAnswerAnchorView: UIView {
    weak var registration: HelpAnswerAnchorRegistration?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { registration?.detach(self); return }
        Task { @MainActor [weak self] in
            guard let self, self.window != nil else { return }
            self.registration?.attach(self)
        }
    }

    /// Inspect the actual registered view and all clipping ancestors at the
    /// instant of presentation; cached onAppear alone cannot prove visibility.
    var isActuallyVisible: Bool {
        guard let window, !window.isHidden, window.windowScene?.activationState == .foregroundActive,
              bounds.width > 8, bounds.height > 8 else { return false }
        let original = convert(bounds, to: window)
        var visible = original.intersection(window.bounds)
        var ancestor: UIView? = self
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01 else { return false }
            if view.clipsToBounds { visible = visible.intersection(view.convert(view.bounds, to: window)) }
            ancestor = view.superview
        }
        return !visible.isNull && visible.width * visible.height >= original.width * original.height * 0.95
    }
}
#endif
