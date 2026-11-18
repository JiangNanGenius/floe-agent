// Floe Mac M00 — mode host interface.
//
// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

struct HostRootView: View {
    @ObservedObject var model: HostModel

    var body: some View {
        Group {
            if model.isFirstRun {
                FirstRunModeView(model: model)
            } else {
                ModeShellView(model: model, bridge: model.bridge)
            }
        }
        .frame(minWidth: 900, minHeight: 640)
        .alert(
            String(localized: "host.details.title"),
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("host.ok") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct FirstRunModeView: View {
    @ObservedObject var model: HostModel
    @State private var selection: AppMode = .agent

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("host.firstRun.title")
                .font(.largeTitle.weight(.semibold))
            Text("host.firstRun.body")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                ForEach(AppMode.allCases, id: \.self) { mode in
                    ModeChoiceCard(mode: mode, selected: selection == mode) {
                        selection = mode
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Text("host.mode.current")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(selection.displayName)
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("host.firstRun.continue") {
                    model.completeFirstRun(selection)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
        }
        .padding(36)
        .frame(maxWidth: 980, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ModeChoiceCard: View {
    let mode: AppMode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: mode == .agent ? "macbook" : "ipad.and.iphone")
                        .font(.title2)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                }
                Text(mode.displayName)
                    .font(.title3.weight(.semibold))
                Text(mode.modeDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.20), lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ModeShellView: View {
    @ObservedObject var model: HostModel
    @ObservedObject var bridge: BridgeComponentController
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.mode {
                    case .agent: agentPane
                    case .bridge: bridgePane
                    }
                    detailsPane
                }
                .padding(24)
                .frame(maxWidth: 1_080, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            RoleImageView(mode: model.mode)
                .frame(width: 42, height: 42)
            Text(model.mode.displayName)
                .font(.title2.weight(.semibold))
            Spacer()
            Picker("host.mode.switch", selection: Binding(
                get: { model.mode },
                set: { model.switchMode($0) }
            )) {
                ForEach(AppMode.allCases, id: \.self) { mode in
                    Text(mode.shortName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.regularMaterial)
    }

    private var agentPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let workspace = model.agentWorkspace {
                PaneCard(title: "host.chat.title", symbol: "bubble.left.and.bubble.right") {
                    HostAgentWorkspaceView(workspace: workspace)
                }
            }
            // This is the same controller the Bridge mode card uses. It is a
            // real service, not a shortcut or a disabled placeholder.
            BridgeStatusCard(
                bridge: bridge,
                context: .agent,
                showLog: $showLog,
                start: { model.startBridgeFromAgent() }
            )
        }
    }

    private var bridgePane: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneCard(title: "host.bridge.title", symbol: "ipad.and.iphone") {
                Text("host.bridge.isolated")
                    .foregroundStyle(.secondary)
                Text("host.bridge.singleOwner")
                    .foregroundStyle(.secondary)
                Text("host.bridge.independent")
                    .foregroundStyle(.secondary)
            }
            BridgeStatusCard(
                bridge: bridge,
                context: .bridge,
                showLog: $showLog,
                start: { bridge.start(origin: .bridge) }
            )
        }
    }

    private var detailsPane: some View {
        PaneCard(title: "host.details.title", symbol: "info.circle") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                detailRow("host.details.preference", model.store.preferenceURL.path)
                detailRow("host.details.bundle", Bundle.main.bundleURL.path)
                detailRow("host.details.source", sourceLabel)
                detailRow("host.details.firstRun", model.isFirstRun ? "yes" : "no")
            }
            Divider()
            Text("host.details.m00")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourceLabel: String {
        switch model.source {
        case .commandLine: String(localized: "host.details.source.commandLine")
        case .environment: String(localized: "host.details.source.environment")
        case .savedPreference: String(localized: "host.details.source.saved")
        case .inheritedBridge: String(localized: "host.details.source.inheritedBridge")
        case .firstRunDefault: String(localized: "host.details.source.firstRun")
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(LocalizedStringKey(title))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}

private struct PaneCard<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(LocalizedStringKey(title), systemImage: symbol)
                .font(.headline)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }
}

// Reuses the current mode's Bridge card without changing modes or starting it.
// First-run selection is completed before this view is presented.
struct BridgeConnectionInfoView: View {
    @ObservedObject var model: HostModel
    @ObservedObject var bridge: BridgeComponentController
    @State private var showLog = false

    init(model: HostModel, bridge: BridgeComponentController) {
        self.model = model
        self.bridge = bridge
    }

    var body: some View {
        ScrollView {
            BridgeStatusCard(
                bridge: bridge,
                context: model.mode == .bridge ? .bridge : .agent,
                showLog: $showLog,
                start: {
                    if model.mode == .bridge { bridge.start(origin: .bridge) }
                    else { model.startBridgeFromAgent() }
                }
            )
            .padding(24)
        }
    }
}

private struct BridgeStatusCard: View {
    enum Context {
        case agent
        case bridge

        var title: String {
            switch self {
            case .agent: String(localized: "host.bridge.shared.title")
            case .bridge: String(localized: "host.bridge.embedded")
            }
        }
    }

    @ObservedObject var bridge: BridgeComponentController
    let context: Context
    @Binding var showLog: Bool
    let start: () -> Void

    var body: some View {
        PaneCard(title: context.title, symbol: "point.3.connected.trianglepath.dotted") {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(statusText)
                    .font(.callout.weight(.medium))
                Spacer()
                if let origin = bridge.launchOrigin {
                    Text(String(format: String(localized: "host.bridge.startedFrom"), origin.label))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let status = bridge.state.status {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("host.bridge.endpoint", "127.0.0.1:\(status.port ?? 0) (\(status.listenerScope))")
                    row("host.bridge.version", "\(status.version ?? "?") (\(status.build ?? "?"))")
                    row("host.bridge.owner", "PID \(status.pid) · parent \(status.parentPID)")
                    row("host.bridge.storage", status.storageRoot)
                    row("host.bridge.workerHome", status.workerHome)
                    row("host.bridge.identity", status.identitySource)
                    row("host.bridge.fingerprint", String((status.identityFingerprintSHA256 ?? "none").prefix(24)))
                    row("host.bridge.activeTasks", taskSummary(status.activeTaskIDs, empty: String(localized: "host.bridge.none")))
                    row("host.bridge.unknownTasks", taskSummary(status.unknownTaskIDs, empty: String(localized: "host.bridge.none")))
                    row("host.bridge.capabilities", status.capabilities.joined(separator: ", "))
                    row("host.bridge.permissions", permissionSummary(status))
                    if status.orphaned {
                        row("host.bridge.orphaned", String(localized: "host.bridge.orphaned.value"))
                    }
                }
                .font(.caption.monospaced())
            }

            if case .conflict(let endpoint) = bridge.state {
                conflictView(endpoint)
            }

            ForEach(bridge.pendingConsents.indices, id: \.self) { index in
                consentView(bridge.pendingConsents[index])
            }

            HStack(spacing: 10) {
                if bridge.state.isRunning {
                    Button("host.bridge.stop") {
                        Task { await bridge.requestStop() }
                    }
                } else {
                    Button("host.bridge.start", action: start)
                }
                Button("host.bridge.refresh") {
                    Task { await bridge.refreshStatus() }
                }
                Button("host.bridge.ping") {
                    Task { await bridge.performPing() }
                }
                .disabled(bridge.state.status == nil || bridge.isPinging)
                if bridge.isPinging { ProgressView().controlSize(.small) }
                Spacer()
                Button(showLog ? String(localized: "host.bridge.hideLog") : String(localized: "host.bridge.showLog")) { showLog.toggle() }
                    .buttonStyle(.link)
            }

            if let ping = bridge.lastPing {
                Text(ping)
                    .font(.caption)
                    .foregroundStyle(ping.localizedCaseInsensitiveContains("OK") || ping.localizedCaseInsensitiveContains("verified") ? Color.green : Color.secondary)
                    .textSelection(.enabled)
            }
            if let blocked = bridge.stopBlockMessage {
                Text(blocked)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if let identityError = bridge.identityError {
                Text(identityError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if let status = bridge.state.status, !status.pairedClients.isEmpty {
                pairedView(status.pairedClients)
            }

            if showLog, !bridge.logTail.isEmpty {
                ScrollView {
                    Text(bridge.logTail)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Text("host.bridge.statusScope")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func pairedView(_ clients: [BridgeControlPairedClient]) -> some View {
        Divider()
        HStack {
            Label("host.bridge.pairedClients", systemImage: "person.badge.key")
                .font(.caption.weight(.semibold))
            Spacer()
        }
        ForEach(clients, id: \.clientID) { client in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(client.name)
                        .font(.caption)
                    Text(client.clientID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("host.bridge.revoke") {
                    Task { await bridge.revoke(clientID: client.clientID) }
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func consentView(_ consent: BridgeControlConsent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("host.bridge.consent.title", systemImage: "person.crop.circle.badge.questionmark")
                .font(.callout.weight(.semibold))
            Text(String(format: String(localized: "host.bridge.consent.body"), consent.displayName))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text(consent.verification)
                .font(.title3.monospaced().weight(.semibold))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("host.bridge.consent.connect") {
                    Task { await bridge.approveConsent(attemptID: consent.attemptID) }
                }
                Button("host.bridge.consent.decline") {
                    Task { await bridge.declineConsent(attemptID: consent.attemptID) }
                }
                Button("host.bridge.consent.cancel") {
                    Task { await bridge.cancelConsent(attemptID: consent.attemptID) }
                }
                .buttonStyle(.link)
                Spacer()
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func conflictView(_ endpoint: BridgeEndpointInventory) -> some View {
        Divider()
        Text("host.bridge.conflict.title")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            row("host.bridge.conflict.pid", endpoint.pid.map { String($0) } ?? String(localized: "host.bridge.unknown"))
            row("host.bridge.conflict.path", endpoint.executablePath ?? String(localized: "host.bridge.unknown"))
            row("host.bridge.conflict.bundle", "\(endpoint.bundleIdentifier ?? String(localized: "host.bridge.unknown")) · \(endpoint.version ?? "?") (\(endpoint.build ?? "?"))")
            row("host.bridge.conflict.data", String(format: String(localized: "host.bridge.conflict.counts"),
                                                    endpoint.data.pairedClientCount,
                                                    endpoint.data.taskCount,
                                                    endpoint.data.unconfirmedTaskCount))
            row("host.bridge.conflict.identity", endpoint.identityVerification)
        }
        .font(.caption.monospaced())
        Text(endpoint.note)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var statusColor: Color {
        switch bridge.state {
        case .ready: .green
        case .starting, .stopping: .orange
        case .conflict: .yellow
        case .failed: .red
        case .idle: .secondary
        }
    }

    private var statusText: String {
        switch bridge.state {
        case .idle: String(localized: "host.bridge.state.idle")
        case .starting: String(localized: "host.bridge.state.starting")
        case .ready(let status): String(format: String(localized: "host.bridge.state.ready"), "127.0.0.1:\(status.port ?? 0)")
        case .stopping: String(localized: "host.bridge.state.stopping")
        case .conflict: String(localized: "host.bridge.state.conflict")
        case .failed(let message): String(format: String(localized: "host.bridge.state.failed"), message)
        }
    }

    private func taskSummary(_ ids: [String], empty: String) -> String {
        ids.isEmpty ? empty : "\(ids.count) · " + ids.joined(separator: ", ")
    }

    private func permissionSummary(_ status: BridgeControlStatus) -> String {
        let allowed = String(localized: "host.bridge.permission.allowed")
        let denied = String(localized: "host.bridge.permission.denied")
        return String(
            format: String(localized: "host.bridge.permission.summary"),
            String(localized: "host.bridge.permission.screen"),
            status.screenCaptureAllowed ? allowed : denied,
            String(localized: "host.bridge.permission.accessibility"),
            status.accessibilityAllowed ? allowed : denied
        )
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(LocalizedStringKey(title))
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}

private struct RoleImageView: View {
    let mode: AppMode

    var body: some View {
        if let image = RolePresentation.loadIcon(mode: mode) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 9))
        } else {
            Image(systemName: "sparkles")
                .font(.title2)
        }
    }
}
