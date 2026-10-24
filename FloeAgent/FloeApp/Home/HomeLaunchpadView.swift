// FloeApp — Home launchpad: the quiet start-work surface.
//
// SPDX-License-Identifier: MPL-2.0
//
// Home is where work STARTS — a calm, input-first surface — not a
// conversation-history page (that is Chat). The launchpad centers a large
// composer under the app icon and welcome line, with real quick entries
// into existing surfaces (workspace files, documents via the composer,
// hosts, providers). Entries that have no backing feature yet are shown
// disabled and honest — nothing simulates success.
//
// The thread only exists after the first message is sent; Home then
// pushes it on Home's own navigation stack without touching Chat's
// selection.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeModels
import FloePersistence

/// The Home root: start-work launchpad.
struct HomeLaunchpadView: View {
    @ObservedObject private var center: ConversationCenter
    @StateObject private var viewModel: HomeLaunchpadViewModel
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.continuousVoiceWindowID) private var voiceWindowID
    @State private var showsDraftPermissions = false
    private let designStart: Bool
    private let onTaskCreated: (@MainActor (UUID) -> Void)?

    init(center: ConversationCenter, workspaceID: UUID? = nil,
         draftStorageID: UUID = ComposerDraftStore.homeDraftID,
         initialDraft: String? = nil, designStart: Bool = false,
         designLaunchBindingProvider: (@MainActor () -> DesignLaunchBinding?)? = nil,
         onTaskCreated: (@MainActor (UUID) -> Void)? = nil) {
        self.center = center
        self.designStart = designStart
        self.onTaskCreated = onTaskCreated
        // Only the canonical Home composer may take Shortcuts drafts.
        // Creative design entry (designStart) and any foreign draft identity
        // never consume the queue, so a wrong route cannot take over.
        let acceptsShortcutInbox = draftStorageID == ComposerDraftStore.homeDraftID
            && !designStart
        _viewModel = StateObject(wrappedValue: HomeLaunchpadViewModel(
            center: center,
            selectedProjectID: workspaceID,
            draftStorageID: draftStorageID,
            initialDraft: initialDraft,
            designLaunchBindingProvider: designLaunchBindingProvider,
            acceptsShortcutInbox: acceptsShortcutInbox
        ))
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack {
                    Spacer(minLength: 24)
                    header
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 720)
                .frame(
                    maxWidth: .infinity,
                    minHeight: max(proxy.size.height, 320)
                )
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    composer
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .background(FloeTheme.readingSurface.opacity(0.98))
            }
            .background(FloeTheme.readingSurface)
            // The composer input caps at one third of the actually
            // available height (rotation, split, dynamic type).
            .environment(\.composerHeightBudget, proxy.size.height)
        }
        .navigationTitle(LocalizedStringKey(launchTitleKey))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load()
            // Durable FIFO delivery: the view model only accepts into an
            // empty, idle composer, acknowledges only while the entry-
            // specific handoff receipt is verified on disk beside the placed
            // text, and keeps every other entry safely queued.
            await viewModel.acceptShortcutInbox()
            // Only an already confirmed New Task choice is consumed here.
            await center.environment.shareIntakeCenter.refresh()
            if acceptsExternalTaskImports {
                await environment.importDestinationCenter
                    .applyConfirmedNewTaskEnvelopes(to: viewModel)
            }
        }
        .onReceive(environment.importDestinationCenter.$confirmedNewTaskRevision) { revision in
            guard revision > 0, acceptsExternalTaskImports else { return }
            Task {
                await environment.importDestinationCenter
                    .applyConfirmedNewTaskEnvelopes(to: viewModel)
            }
        }
        .onReceive(environment.shareIntakeCenter.$pending) { _ in
            guard acceptsExternalTaskImports else { return }
            Task {
                await environment.importDestinationCenter
                    .applyConfirmedNewTaskEnvelopes(to: viewModel)
            }
        }
        .onReceive(environment.continuousVoicePresentation.$returnedDraft) { returned in
            guard let returned, returned.windowID == voiceWindowID,
                  returned.ownerID == viewModel.draftStorageID else { return }
            viewModel.draft = returned.text
            viewModel.attachments = returned.attachments
            Task { @MainActor in environment.continuousVoicePresentation.consumeReturnedDraft(returned.id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: FloeShortcutInbox.didEnqueue)) { _ in
            // A Shortcuts run just placed a draft while Home is open: update
            // the count and, if the composer is free, deliver it now.
            Task { await viewModel.acceptShortcutInbox() }
        }
        // A Settings change reloads the center asynchronously; both the stored
        // default and the offered model list can change under an open Home
        // screen. Re-validate against the fixed fallback order instead of
        // leaving a disabled/deleted model selected (which used to disable
        // send and show "no model configured").
        .onChange(of: center.modelPreferences) { _, _ in
            viewModel.reconcileModelSelection()
        }
        .onChange(of: center.availableAgentModels.map(\.id)) { _, _ in
            viewModel.reconcileModelSelection()
        }
        .refreshable { await viewModel.load() }
        .toolbar {
            if !designStart {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: startTemporaryChatEntry) {
                        Label("chat.temporary.toggle", systemImage: "bubble.left")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(Color.secondary)
                    }
                    .disabled(!viewModel.canStartTemporaryChat)
                    .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                    .accessibilityLabel("chat.temporary.toggle")
                    .accessibilityIdentifier("home.temporary.toggle")
                    .accessibilityHint("chat.temporary.toggle.hint")
                    .help(String(localized: "chat.temporary.toggle.hint"))
                }
            }
        }
        .sheet(isPresented: $showsDraftPermissions) {
            DraftTaskPermissionsSheet(
                policy: $viewModel.draftPolicy,
                isLocalModel: viewModel.usesLocalModel
            )
        }
    }

    // MARK: - Header: brand mark + welcome

    private var header: some View {
        VStack(spacing: 16) {
            // The existing brand asset — no mascot, no third-party art.
            Image(uiImage: AppIconImage.current ?? UIImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: FloeTheme.primary.opacity(0.18), radius: 18, y: 8)
                .accessibilityHidden(true)

            Text(LocalizedStringKey(launchPromptKey))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Composer (centered, prominent)

    private var acceptsExternalTaskImports: Bool {
        !designStart && viewModel.draftStorageID == ComposerDraftStore.homeDraftID
    }

    private var launchTitleKey: String {
        if designStart { return "design.conversation.start_title" }
        return viewModel.agentMode == .chat ? "chat.new.title" : "workbench.new_task"
    }

    private var launchPromptKey: String {
        if designStart { return "design.conversation.start_prompt" }
        return viewModel.agentMode == .chat ? "chat.new.prompt" : "home.welcome"
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if !designStart {
                ShareIntakeCard(
                    center: center.environment.shareIntakeCenter,
                    destination: viewModel
                )
            }
            if viewModel.showsShortcutInboxBanner {
                shortcutInboxBar
            }
            if !viewModel.pendingApprovals.isEmpty {
                approvalsStrip
            }
            if !viewModel.hasConfiguredProvider {
                providerBar
            }
            if let error = viewModel.actionError {
                errorBar(error)
            }
            taskComposer
        }
    }

    private var continuousVoiceAction: (() -> Void)? {
        guard !designStart else { return nil }
        return { openContinuousVoice() }
    }

    private var taskComposer: some View {
        ThreadComposerView(
            draft: $viewModel.draft,
            selectedModelID: $viewModel.selectedModelID,
            models: viewModel.availableModels,
            modelName: viewModel.activeModelName,
            providerConfigured: viewModel.hasConfiguredProvider,
            isRunning: false,
            canSend: viewModel.canSend,
            projects: viewModel.availableProjects,
            selectedProjectID: $viewModel.selectedProjectID,
            executionTarget: $viewModel.executionTarget,
            agentMode: $viewModel.agentMode,
            attachments: $viewModel.attachments,
            onSend: sendTask,
            onStop: {},
            onContinuousVoice: continuousVoiceAction,
            onPermissions: { showsDraftPermissions = true },
            approvalMode: viewModel.draftPolicy.approvalMode,
            draftIdentity: viewModel.draftStorageID,
            isDraftConsumedBySend: viewModel.isConsumingDraft,
            notesDraftID: viewModel.draftConversationID
        )
    }

    // MARK: - Status strips

    private func openContinuousVoice() {
        guard let voiceWindowID,
              let (_, model) = center.providerAndModel(modelID: viewModel.selectedModelID) else { return }
        // Keep the Home selection for the conversation after voice exits.
        // The voice driver applies Chat only to its own turns.
        // CARRY THE ACTUAL TEMPORARY IDENTITY: while a RAM-only 临时聊天
        // session exists, voice continues THAT conversation — a first
        // utterance must never defer-create a persisted thread. Temporary
        // sessions own a text-only ceiling: Home's staged attachments are
        // never granted to a temporary voice round.
        let temporaryConversationID = center.temporarySession?.conversation.id
        let request = ContinuousVoiceRequest(
            windowID: voiceWindowID, conversationID: temporaryConversationID, modelID: model.id,
            workspaceID: viewModel.selectedProjectID,
            attachments: temporaryConversationID == nil ? viewModel.attachments : [],
            onConversationCreated: { id in router.openThreadFromHome(id) },
            draftOwnerID: viewModel.draftStorageID,
            onAttachmentsConsumed: { files in
                let ids = Set(files.map(\.id))
                viewModel.attachments.removeAll { ids.contains($0.id) }
            },
            reasoningDraftOwnerID: viewModel.draftConversationID,
            preferredModeForNewConversation: viewModel.agentMode
        )
        if environment.continuousVoicePresentation.present(request) {
            environment.voiceInput.stop()
            environment.speechService.stop()
        }
    }

    /// Compact actionable notice for queued Shortcuts drafts. It only shows
    /// when entries are actually waiting; taking a draft is explicit when
    /// the composer is busy and automatic once it is free again.
    private var shortcutInboxBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .foregroundStyle(FloeTheme.primary)
                .accessibilityHidden(true)
            Text(FloeL10n.plural("shortcuts.inbox.waiting", count: viewModel.shortcutInboxCount))
                .font(FloeTheme.Typography.metadata)
            Spacer()
            Button("shortcuts.inbox.take") {
                Task { await viewModel.acceptShortcutInbox() }
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.canAcceptShortcutDraft)
            .frame(minHeight: FloeTheme.minimumTarget)
            .accessibilityIdentifier("home.shortcuts.inbox.take")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(FloeTheme.primary.opacity(0.08))
    }

    private var approvalsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.pendingApprovals) { approval in
                    Button {
                        router.openConversation(approval.conversationID, runID: approval.runID)
                    } label: {
                        Label(
                            approval.toolCall.toolName,
                            systemImage: "exclamationmark.shield.fill"
                        )
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.pending)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(FloeTheme.pending.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: FloeTheme.minimumTarget)
                    .accessibilityLabel(
                        String(localized: "approval.required")
                            + " " + approval.toolCall.toolName
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    private var providerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(FloeTheme.pending)
                .accessibilityHidden(true)
            Text("chat.add_provider.hint")
                .font(FloeTheme.Typography.metadata)
            Spacer()
            Button("setup.launcher.open") { router.presentedSetup = .manual }
                .buttonStyle(.bordered)
                .frame(minHeight: FloeTheme.minimumTarget)
                .accessibilityIdentifier("setup.open")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(FloeTheme.pending.opacity(0.08))
    }

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.octagon")
                .foregroundStyle(FloeTheme.destructive)
                .accessibilityHidden(true)
            Text(message)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(FloeTheme.destructive)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(FloeTheme.destructive.opacity(0.08))
    }

    // MARK: - Actions

    /// New Task remains ordinary by default. Temporary chat is an explicit
    /// header action on the already-open launchpad, with no extra chooser.
    private func startTemporaryChatEntry() {
        Task {
            if let conversationID = await viewModel.startTemporaryChat() {
                router.openConversation(conversationID)
            }
        }
    }

    /// Sends the draft and opens the new thread on Home's own stack.
    private func sendTask() {
        Task {
            if let conversationID = await viewModel.sendNewTask() {
                if let onTaskCreated {
                    onTaskCreated(conversationID)
                } else {
                    router.openThreadFromHome(conversationID)
                }
            }
        }
    }
}

/// Reads the built app icon (the flowing cyan-blue-violet loop brand
/// mark) so Home uses the real asset instead of any drawn mascot.
enum AppIconImage {
    static var current: UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last else {
            return UIImage(named: "AppIcon")
        }
        return UIImage(named: name)
    }
}
#endif
