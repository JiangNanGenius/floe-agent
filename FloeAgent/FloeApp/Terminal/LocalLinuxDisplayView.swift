// FloeApp — on-demand local Linux screen viewer.
//
// SPDX-License-Identifier: MPL-2.0
//
// A thin presentation over LocalLinuxDisplayOwner: the view only renders
// state and hosts the shared VNCViewer. Demand is bound to the view's task:
// leaving this view ends viewer demand and drops client transport, while the
// guest service, the terminal and all compute keep running. Qualification
// details (software framebuffer) stay out of product copy.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeVNC

struct LocalLinuxDisplayView: View {
    let owner: LocalLinuxDisplayOwner
    @Environment(\.dismiss) private var dismiss
    @State private var showsUpgradeConfirmation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                Divider()
                content
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(IDELanguageRunText.t("屏幕", "Screen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .confirmationDialog(
            IDELanguageRunText.t("升级 Linux 环境", "Upgrade Linux environment"),
            isPresented: $showsUpgradeConfirmation,
            titleVisibility: .visible
        ) {
            Button(IDELanguageRunText.t("升级并打开屏幕", "Upgrade and open screen")) {
                Task { await owner.upgradeComponentAndRetry() }
            }
            Button("action.cancel", role: .cancel) { }
        } message: {
            Text("execution.runtime_rebuild.confirm")
        }
        .task {
            await owner.beginViewerDemand()
            // Viewer demand lasts exactly as long as this view is alive.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            owner.endViewerDemand()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let session = owner.clientSession {
            VNCViewer(session: session)
                .background(.black)
        } else {
            ContentUnavailableView {
                Label(statusTitle, systemImage: statusImage)
            } description: {
                if owner.upgradingComponent {
                    LinuxRuntimeUpgradeProgress()
                        .frame(maxWidth: 360)
                } else {
                    Text(statusDetail)
                }
            } actions: {
                if owner.canStart {
                    Button(IDELanguageRunText.t("打开屏幕", "Open screen")) {
                        Task { await owner.startDisplay() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                if owner.requiresComponentUpgrade && !owner.upgradingComponent {
                    Button(IDELanguageRunText.t("升级 Linux 环境", "Upgrade Linux environment")) {
                        showsUpgradeConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                if !owner.upgradingComponent, case .failed(let message) = owner.state {
                    DisclosureGroup(IDELanguageRunText.t("详情", "Details")) {
                        Text(message).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    .frame(maxWidth: 480, alignment: .leading)
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(statusTitle)
                .font(FloeTheme.Typography.metadata)
                .lineLimit(1)
            Spacer()
            if case .ready = owner.state {
                Label(IDELanguageRunText.t("本地 Linux 屏幕", "Local Linux screen"), systemImage: "display")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(FloeTheme.chromeMaterial)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Ends ONLY viewer demand: the guest service, terminal and compute
        // keep running, and the model's sticky tool demand (if any) is
        // unaffected.
        ToolbarItem(placement: .cancellationAction) {
            Button(IDELanguageRunText.t("返回终端", "Back to terminal")) { dismiss() }
                .accessibilityIdentifier("display.close")
        }
        // The one explicit teardown affordance.
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive) {
                Task {
                    await owner.stopDisplay()
                    dismiss()
                }
            } label: {
                Label(IDELanguageRunText.t("停止屏幕", "Stop screen"), systemImage: "stop.circle")
            }
            .disabled(!owner.canStop)
            .accessibilityIdentifier("display.stop")
        }
    }

    private var statusColor: Color {
        if owner.upgradingComponent { return .orange }
        switch owner.state {
        case .ready: return .green
        case .starting, .connecting, .stopping, .resolving: return .orange
        case .failed, .ended: return .red
        case .idle, .unavailable: return .secondary
        }
    }

    private var statusImage: String {
        if owner.upgradingComponent { return "arrow.triangle.2.circlepath" }
        switch owner.state {
        case .failed, .ended: return "display.trianglebadge.exclamationmark"
        case .unavailable: return "display.slash"
        default: return "display"
        }
    }

    private var statusTitle: String {
        if owner.upgradingComponent { return IDELanguageRunText.t("正在升级 Linux 环境…", "Upgrading Linux environment…") }
        switch owner.state {
        case .resolving: return IDELanguageRunText.t("正在解析环境…", "Resolving environment…")
        case .unavailable: return IDELanguageRunText.t("此环境不支持屏幕", "Screen unavailable for this environment")
        case .idle: return IDELanguageRunText.t("屏幕未启动", "Screen not started")
        case .starting: return IDELanguageRunText.t("正在启动屏幕…", "Starting screen…")
        case .connecting: return IDELanguageRunText.t("正在连接屏幕…", "Connecting to screen…")
        case .ready:
            return owner.clientSession == nil
                ? IDELanguageRunText.t("屏幕运行中", "Screen running")
                : IDELanguageRunText.t("已连接", "Connected")
        case .stopping: return IDELanguageRunText.t("正在关闭屏幕…", "Stopping screen…")
        case .ended: return IDELanguageRunText.t("屏幕已退出", "The screen ended")
        case .failed: return IDELanguageRunText.t("屏幕暂不可用", "Screen unavailable")
        }
    }

    /// Bounded, non-secret failure detail; actionable copy stays generic.
    private var statusDetail: String {
        switch owner.state {
        case .failed:
            if owner.requiresComponentUpgrade {
                return IDELanguageRunText.t("升级后可打开屏幕。旧运行盘会保留。", "Upgrade to open the screen. The old runtime disk will be retained.")
            }
            if owner.canStop {
                return IDELanguageRunText.t("请重试连接或停止屏幕。", "Retry the connection or stop the screen.")
            }
            return IDELanguageRunText.t("请重试，或检查执行环境。", "Try again, or check Execution Environment.")
        case .ended(let message):
            return message
        case .unavailable:
            return IDELanguageRunText.t("只有本地 Linux 环境可以打开屏幕。", "Only a local Linux environment can open a screen.")
        default:
            return ""
        }
    }
}
#endif
