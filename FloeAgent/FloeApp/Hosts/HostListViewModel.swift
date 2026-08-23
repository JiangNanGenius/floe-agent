// FloeApp — Host list view model.
//
// SPDX-License-Identifier: MPL-2.0
//
// Presentation state for the Hosts tab: host list, per-host session
// status, connect actions. Delegates all work to RemoteSessionCenter; the
// view never holds a connection handle.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeModels
import FloeSSH

/// View model for the host list.
@MainActor
final class HostListViewModel: ObservableObject {

    @Published private(set) var isLoading = false
    @Published var connectingHostID: UUID?
    @Published var updatingAgentHostID: UUID?
    @Published var pairingAgentHostID: UUID?
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    let center: RemoteSessionCenter

    init(center: RemoteSessionCenter) {
        self.center = center
    }

    var hosts: [RemoteHostProfile] {
        center.hosts
    }

    /// Active sessions for a host (for the status row).
    func sessions(for hostID: UUID) -> [RemoteSessionSnapshot] {
        center.sessions.values.filter { $0.hostID == hostID }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await center.loadHosts()
        await center.refreshSnapshots()
    }

    /// Opens an SSH terminal session to the host. Returns the session ID.
    @discardableResult
    func connectTerminal(to host: RemoteHostProfile) async -> UUID? {
        connectingHostID = host.id
        defer { connectingHostID = nil }
        do {
            return try await center.connectTerminal(to: host)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Opens a VNC session to the host. Returns the session ID.
    @discardableResult
    func connectVNC(to host: RemoteHostProfile) async -> UUID? {
        connectingHostID = host.id
        defer { connectingHostID = nil }
        do {
            return try await center.connectVNC(to: host)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func delete(_ host: RemoteHostProfile) async {
        try? await center.deleteHost(id: host.id)
        await load()
    }

    func updateRemoteAgent(on host: RemoteHostProfile) async {
        updatingAgentHostID = host.id
        errorMessage = nil
        statusMessage = nil
        defer { updatingAgentHostID = nil }
        do {
            let result = try await center.updateRemoteAgent(on: host)
            statusMessage = "Floe 守护程序已更新到 \(result.version)。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pairAdvancedLink(on host: RemoteHostProfile) async {
        pairingAgentHostID = host.id
        errorMessage = nil
        statusMessage = nil
        defer { pairingAgentHostID = nil }
        do {
            try await center.pairAdvancedLink(on: host)
            statusMessage = "已为本设备建立独立 mTLS 高级链路。"
        } catch { errorMessage = error.localizedDescription }
    }
}
#endif
