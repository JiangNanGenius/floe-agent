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

struct ExecutionEnvironmentView: View {
    @ObservedObject var center: SettingsCenter

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
                capabilityRow(
                    name: String(localized: "settings.exec.python_remote"),
                    state: center.remotePythonCapability
                )
                LabeledContent("settings.exec.remote_terminal") {
                    Text("settings.exec.remote_terminal.value \(center.remoteHostCount) \(center.activeRemoteSessionCount)")
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: FloeTheme.minimumTarget)
            }

            Section("settings.exec.defaults") {
                Picker("settings.exec.target", selection: Binding(
                    get: { center.execution.target },
                    set: { Task { await center.setExecutionTarget($0) } }
                )) {
                    Text("settings.exec.target.local").tag(ExecutionTargetPreference.local)
                }
                .frame(minHeight: FloeTheme.minimumTarget)

                Stepper(
                    "settings.exec.timeout \(center.execution.timeoutSeconds)",
                    value: Binding(
                        get: { center.execution.timeoutSeconds },
                        set: { Task { await center.setExecutionTimeout(seconds: $0) } }
                    ),
                    in: 30...3600,
                    step: 30
                )
                .frame(minHeight: FloeTheme.minimumTarget)

                Picker("settings.exec.max_output", selection: Binding(
                    get: { center.execution.maxOutputBytes },
                    set: { Task { await center.setMaxOutputBytes($0) } }
                )) {
                    Text("32 KB").tag(32 * 1024)
                    Text("64 KB").tag(64 * 1024)
                    Text("128 KB").tag(128 * 1024)
                    Text("256 KB").tag(256 * 1024)
                }
                .frame(minHeight: FloeTheme.minimumTarget)

                Toggle("settings.exec.save_artifacts", isOn: Binding(
                    get: { center.execution.savesArtifacts },
                    set: { Task { await center.setSavesArtifacts($0) } }
                ))
                .frame(minHeight: FloeTheme.minimumTarget)
            }
        }
        .navigationTitle("settings.section.execution")
        .task { await center.load() }
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
