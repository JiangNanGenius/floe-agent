// FloeApp — Hosts & remote session settings section.
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_SETTINGS.md §5 row 7: SSH/VNC default behaviour,
// keep-alive, idle disconnect timeout (RemoteSessionDefaults via
// app_settings), and the trusted-host fingerprint list. Fingerprints are
// evidence text — read-only here.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

struct RemoteSettingsView: View {
    @ObservedObject var center: SettingsCenter

    var body: some View {
        Form {
            Section("settings.remote.ssh") {
                Toggle("settings.remote.auto_reconnect", isOn: Binding(
                    get: { center.sshDefaults.autoReconnect },
                    set: { var d = center.sshDefaults; d.autoReconnect = $0
                           Task { await center.setSSHDefaults(d) } }
                ))
                .frame(minHeight: FloeTheme.minimumTarget)
                Toggle("settings.remote.keep_alive", isOn: Binding(
                    get: { center.sshDefaults.keepAlive },
                    set: { var d = center.sshDefaults; d.keepAlive = $0
                           Task { await center.setSSHDefaults(d) } }
                ))
                .frame(minHeight: FloeTheme.minimumTarget)
            }

            Section("settings.remote.vnc") {
                Toggle("settings.remote.auto_reconnect", isOn: Binding(
                    get: { center.vncDefaults.autoReconnect },
                    set: { var d = center.vncDefaults; d.autoReconnect = $0
                           Task { await center.setVNCDefaults(d) } }
                ))
                .frame(minHeight: FloeTheme.minimumTarget)
                Toggle("settings.remote.keep_alive", isOn: Binding(
                    get: { center.vncDefaults.keepAlive },
                    set: { var d = center.vncDefaults; d.keepAlive = $0
                           Task { await center.setVNCDefaults(d) } }
                ))
                .frame(minHeight: FloeTheme.minimumTarget)
            }

            Section {
                Stepper(
                    "settings.remote.idle_disconnect \(center.idleDisconnectMinutes)",
                    value: Binding(
                        get: { center.idleDisconnectMinutes },
                        set: { newValue in
                            Task { await center.setIdleDisconnectMinutes(newValue) }
                        }
                    ),
                    in: 1...240
                )
                .frame(minHeight: FloeTheme.minimumTarget)
            } header: {
                Text("settings.remote.session")
            } footer: {
                Text("settings.remote.idle_disconnect.footer")
            }

            Section {
                if center.remoteHostCount == 0 {
                    Text("settings.remote.hosts.empty")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("settings.remote.hosts.count") {
                        Text("\(center.remoteHostCount)")
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: FloeTheme.minimumTarget)
                    LabeledContent("settings.remote.sessions.active") {
                        Text("\(center.activeRemoteSessionCount)")
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: FloeTheme.minimumTarget)
                }
            } header: {
                Text("settings.remote.hosts")
            } footer: {
                Text("settings.remote.hosts.footer")
            }
        }
        .navigationTitle("settings.section.remote")
        .task { await center.load() }
    }
}
#endif
