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
import FloeSSH

struct ExecutionEnvironmentView: View {
    @ObservedObject var center: SettingsCenter
    @State private var environments: [FloePlatformServices.EnvironmentReport] = []
    @State private var environmentError: String?
    @State private var loadingEnvironments = false

    var body: some View {
        Form {
            Section("settings.exec.runtimes") {
                capabilityRow(
                    name: String(localized: "settings.exec.js"),
                    state: center.jsCapability
                )
                capabilityRow(
                    name: String(localized: "settings.exec.python_local"),
                    state: center.localPythonCapability
                )
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

            Section("环境与已安装依赖") {
                if loadingEnvironments { ProgressView("读取环境…") }
                if let environmentError { Text(environmentError).foregroundStyle(.red) }
                ForEach(environments) { report in
                    DisclosureGroup {
                        Text(report.id).font(.caption).textSelection(.enabled)
                        Text(report.record.requiresRebuild ? "依赖需要重建；数据已保留" : report.record.state.rawValue)
                        Text(ByteCountFormatter.string(fromByteCount: report.bytes, countStyle: .file))
                        if report.packages.isEmpty { Text("此层尚未安装软件包").foregroundStyle(.secondary) }
                        ForEach(report.packages, id: \.name) { package in
                            LabeledContent(package.name, value: package.version)
                        }
                    } label: {
                        Text((report.record.name ?? report.record.kind.rawValue) + " · " + String(report.id.prefix(8)))
                    }
                }
                Button("刷新环境与依赖") { Task { await reloadEnvironments() } }.disabled(loadingEnvironments)
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
            await reloadEnvironments()
        }
    }

    @MainActor private func reloadEnvironments() async {
        guard !loadingEnvironments else { return }
        loadingEnvironments = true
        defer { loadingEnvironments = false }
        do {
            environments = try await FloePlatformServices.shared.environmentReports()
            environmentError = nil
        } catch { environmentError = error.localizedDescription }
    }

    private func capabilityRow(name: String, state: CapabilityState) -> some View {
        HStack {
            Text(name)
            Spacer()
            switch state {
            case .available(let version):
                Label(version, systemImage: "checkmark.circle.fill")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(FloeTheme.success)
            case .unavailable(let reason):
                Label(reason, systemImage: "minus.circle")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            case .unknown:
                Text("settings.capability.unknown")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(FloeTheme.unknown)
            }
        }
        .frame(minHeight: FloeTheme.minimumTarget)
        .accessibilityElement(children: .combine)
    }
}
#endif
