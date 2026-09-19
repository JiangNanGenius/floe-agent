// FloeApp — Execution environment settings section.
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_SETTINGS.md §5 row 5: JS probe (real), local and
// remote Python (honest unavailable until P3), remote terminal counts,
// and the persisted execution preferences (target / timeout / max output /
// save artifacts). Unavailable capabilities are greyed out, never faked.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeEnvironments
import FloeExecution
import FloeSSH

struct ExecutionEnvironmentView: View {
    @ObservedObject var center: SettingsCenter

    var body: some View {
        Form {
            Section("settings.exec.runtimes") {
                if center.runtimeInventory.isEmpty {
                    Text("settings.exec.runtimes.empty")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(center.runtimeInventory) { entry in
                    runtimeRow(entry)
                }
                LabeledContent("settings.exec.remote_terminal") {
                    Text(String.localizedStringWithFormat(
                        String(localized: "settings.exec.remote_terminal.value"),
                        center.remoteHostCount,
                        center.activeRemoteSessionCount
                    ))
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: FloeTheme.minimumTarget)
            }

            Section("settings.exec.packages") {
                NavigationLink {
                    EnvironmentManagerView(ownerTitles: Dictionary(uniqueKeysWithValues:
                        center.environment.conversationCenter.conversations.map { ($0.id.uuidString, $0.title) }
                    ))
                } label: {
                    Label("environment.manager.entry", systemImage: "shippingbox")
                }
                Text("查看每层依赖与容量，安装或卸载软件包，停止、恢复环境和保存模板。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            Section("settings.exec.defaults") {
                Picker("settings.exec.target", selection: Binding(
                    get: { center.execution.target },
                    set: { newValue in
                        Task { await center.setExecutionTarget(newValue) }
                    }
                )) {
                    Text("settings.exec.target.local").tag(ExecutionTargetPreference.local)
                    ForEach(center.environment.remoteSessionCenter.hosts.filter {
                        $0.isRemoteExecutionEnvironment && $0.hasSSHConnection
                    }) { host in
                        Text(host.displayName).tag(ExecutionTargetPreference.host(host.id))
                    }
                }
                .frame(minHeight: FloeTheme.minimumTarget)

                // Hidden: timeout / maxOutputBytes / savesArtifacts are
                // persisted but not yet consumed by any execution path, so
                // the controls are removed until they take real effect.
            }
        }
        .navigationTitle("settings.section.execution")
        .task {
            async let settings: Void = center.load()
            async let hosts: Void = center.environment.remoteSessionCenter.loadHosts()
            _ = await (settings, hosts)
        }
    }

    private func runtimeRow(_ entry: RuntimeInventoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.displayName)
                Spacer()
                Text(sourceLabel(entry.source))
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(FloeTheme.primary)
            }
            HStack(spacing: 8) {
                availabilityLabel(entry)
                Spacer()
                updateLabel(entry)
            }
            if let detail = entry.detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: FloeTheme.minimumTarget)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func availabilityLabel(_ entry: RuntimeInventoryEntry) -> some View {
        switch entry.availability {
        case .available(let version):
            Label(version, systemImage: "checkmark.circle.fill")
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(FloeTheme.success)
        case .notInstalled:
            Label("settings.exec.runtime.not_installed", systemImage: "circle.dashed")
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(FloeTheme.pending)
        case .unavailable(let reason):
            Label(reason, systemImage: "minus.circle")
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func updateLabel(_ entry: RuntimeInventoryEntry) -> some View {
        switch entry.update {
        case .current:
            Text("settings.exec.runtime.update.current")
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
        case .installable(let version):
            Text(String.localizedStringWithFormat(
                String(localized: "settings.exec.runtime.update.installable"), version
            ))
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(FloeTheme.primary)
        case .updatable(_, let available):
            Text(String.localizedStringWithFormat(
                String(localized: "settings.exec.runtime.update.updatable"), available
            ))
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(FloeTheme.pending)
        case .unavailable:
            EmptyView()
        }
    }

    private func sourceLabel(_ source: RuntimeInventoryEntry.Source) -> String {
        switch source {
        case .bundled: return String(localized: "settings.exec.runtime.source.bundled")
        case .user: return String(localized: "settings.exec.runtime.source.user")
        case .project: return String(localized: "settings.exec.runtime.source.project")
        case .remote: return String(localized: "settings.exec.runtime.source.remote")
        }
    }
}
#endif
