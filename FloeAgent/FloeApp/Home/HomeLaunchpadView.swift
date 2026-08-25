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
    @State private var showsDraftPermissions = false

    init(center: ConversationCenter, workspaceID: UUID? = nil) {
        self.center = center
        _viewModel = StateObject(wrappedValue: HomeLaunchpadViewModel(
            center: center,
            selectedProjectID: workspaceID
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
        }
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
        .navigationTitle("新建任务")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load()
            if AppleCapabilityPreferences.isEnabled(.shortcuts),
               let pending = FloeShortcutInbox.consume() {
                viewModel.draft = pending
            }
        }
        .refreshable { await viewModel.load() }
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

            Text("home.welcome")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Composer (centered, prominent)

    private var composer: some View {
        VStack(spacing: 0) {
            if !viewModel.pendingApprovals.isEmpty {
                approvalsStrip
            }
            if !viewModel.hasConfiguredProvider {
                providerBar
            }
            if let error = viewModel.actionError {
                errorBar(error)
            }
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
                onPermissions: { showsDraftPermissions = true },
                approvalMode: viewModel.draftPolicy.approvalMode
            )
        }
    }

    // MARK: - Status strips

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

    /// Sends the draft and opens the new thread on Home's own stack.
    private func sendTask() {
        Task {
            if let conversationID = await viewModel.sendNewTask() {
                router.openThreadFromHome(conversationID)
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
