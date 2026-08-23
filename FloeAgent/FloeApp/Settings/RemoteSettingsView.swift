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
    @State private var showsHostManager = false

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
                Button { showsHostManager = true } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("管理主机")
                            Text(center.remoteHostCount == 0
                                 ? String(localized: "settings.remote.hosts.empty")
                                 : "\(center.remoteHostCount) 台已配置")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if center.activeRemoteSessionCount > 0 {
                            Text("\(center.activeRemoteSessionCount) 个活跃")
                                .font(FloeTheme.Typography.metadata)
                                .foregroundStyle(FloeTheme.success)
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(minHeight: FloeTheme.minimumTarget)
            } header: {
                Text("settings.remote.hosts")
            } footer: {
                Text("settings.remote.hosts.footer")
            }
        }
        .navigationTitle("settings.section.remote")
        .task { await center.load() }
        .sheet(isPresented: $showsHostManager) {
            NavigationStack {
                HostListView(center: center.environment.remoteSessionCenter)
            }
        }
    }
}
#endif
