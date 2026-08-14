// FloeApp — Remote session coordinator (app-level seam).
//
// SPDX-License-Identifier: MPL-2.0
//
// Owns SSH/VNC session objects INDEPENDENT of any view and reconciles the
// in-memory handle with the durable remote_sessions row so a backgrounded
// or relaunched app reports connected/suspended/unknown honestly. The
// single most important correctness fix over the view-bound M0 model:
// dismissing a view no longer kills the connection.
//
// Hard rules (Part D.2): an unmanaged disconnect surfaces `unknown`, never
// `paused`. On backgrounding the center requests only legitimate short
// completion time, marks sessions suspended, and permits iOS suspension;
// on resume it reconciles. Host-key changes hard-stop; TOFU shows a
// fingerprint sheet via the pending trust prompt. Never promises a socket
// survives suspension.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeSSH
import FloeSync
import FloeVNC

/// Coordinates SSH terminal and VNC sessions for the UI layer. Owns the
/// session owner objects (handles) so views render snapshots only.
@MainActor
final class RemoteSessionCenter: ObservableObject {

    /// UI-facing snapshots keyed by session ID.
    @Published private(set) var sessions: [UUID: RemoteSessionSnapshot] = [:]
    /// Hosts, for the list. Loaded from RemoteHostStore.
    @Published private(set) var hosts: [RemoteHostProfile] = []
    /// A pending TOFU host-key trust prompt the UI must resolve before
    /// the connection proceeds.
    @Published var pendingTrust: PendingHostKeyTrust?

    let environment: AppEnvironment

    private let hostStore: RemoteHostStore
    private let sshService: SSHConnectionService
    private let secretStore = KeychainSecretStore()
    private var sshOwners: [UUID: SSHSessionOwner] = [:]
    private var vncOwners: [UUID: VNCSessionOwner] = [:]
    /// Continuations for pending TOFU decisions, keyed by challenge id.
    private var trustContinuations: [String: CheckedContinuation<Bool, Never>] = [:]

    init(environment: AppEnvironment) {
        self.environment = environment
        let hostStore = RemoteHostStore(database: environment.database)
        self.hostStore = hostStore
        self.sshService = SSHConnectionService(hostStore: hostStore)
    }

    /// A host-key trust prompt the UI shows before connecting proceeds.
    struct PendingHostKeyTrust: Identifiable, Sendable {
        let challenge: HostKeyChallenge
        var id: String { challenge.id }
    }

    // MARK: - Hosts

    func loadHosts() async {
        let stored = (try? await hostStore.hosts()) ?? []
        hosts = stored.compactMap { try? RemoteHostProfile(stored: $0) }
    }

    func saveHost(_ profile: RemoteHostProfile) async throws {
        try profile.validate()
        let encoder = JSONEncoder()
        let policyString: String
        switch profile.hostKeyPolicy {
        case .trustOnFirstUse: policyString = "trustOnFirstUse"
        case .pinned(let fingerprint): policyString = "pinned:\(fingerprint)"
        }
        try await hostStore.saveHost(
            id: profile.id,
            displayName: profile.displayName,
            address: profile.address,
            port: profile.port,
            user: profile.user,
            authJSON: String(decoding: try encoder.encode(profile.auth), as: UTF8.self),
            jumpChainJSON: String(decoding: try encoder.encode(profile.jumpChain), as: UTF8.self),
            hostKeyPolicy: policyString,
            allowsLegacyAlgorithms: profile.allowsLegacyAlgorithms,
            vncEndpointJSON: try profile.vncEndpoint.map {
                String(decoding: try encoder.encode($0), as: UTF8.self)
            }
        )
        await loadHosts()
    }

    func deleteHost(id: UUID) async throws {
        try await hostStore.deleteHost(id: id)
        try? await secretStore.deleteSecret(scope: .host(id))
        await loadHosts()
    }

    // MARK: - Credential + trust handlers

    /// TOFU handler: surfaces the challenge as a pending trust prompt and
    /// awaits the user's decision. Never auto-trusts.
    private func hostKeyDecision(_ challenge: HostKeyChallenge) async -> Bool {
        await withCheckedContinuation { continuation in
            trustContinuations[challenge.id] = continuation
            pendingTrust = PendingHostKeyTrust(challenge: challenge)
        }
    }

    /// Resolves the pending trust prompt (user approved or rejected).
    func resolveTrust(_ trusted: Bool) {
        guard let pending = pendingTrust else { return }
        trustContinuations.removeValue(forKey: pending.id)?.resume(returning: trusted)
        pendingTrust = nil
    }

    // MARK: - SSH terminal

    /// Connects an SSH terminal to a host, returns the session ID.
    @discardableResult
    func connectTerminal(to host: RemoteHostProfile) async throws -> UUID {
        let sessionID = UUID()
        let record = RemoteSessionRecord(
            id: sessionID, hostID: host.id, kind: .sshTerminal, state: .connecting
        )
        try await environment.remoteSessionRegistry.upsert(record)
        sessions[sessionID] = RemoteSessionSnapshot.derive(record: record)

        let handle = try await sshService.connect(
            profile: host,
            credentialResolver: { [weak self] ref in
                guard let self else { throw SSHConnectionError.invalidCredential }
                return try await self.resolveSecret(ref)
            },
            hostKeyDecision: { [weak self] challenge in
                guard let self else { return false }
                return await self.hostKeyDecision(challenge)
            }
        )
        let pty = try await handle.openPTY()
        let owner = SSHSessionOwner(
            sessionID: sessionID,
            hostID: host.id,
            registry: environment.remoteSessionRegistry
        )
        owner.attach(handle: handle, pty: pty)
        owner.onDisconnect = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.refreshSnapshots()
            }
        }
        sshOwners[sessionID] = owner
        try await environment.remoteSessionRegistry.updateState(
            id: sessionID, state: .connected, lastHeartbeatAt: Date()
        )
        await refreshSnapshots()
        return sessionID
    }

    func send(_ data: Data, to sessionID: UUID) async throws {
        try await sshOwners[sessionID]?.send(data)
    }

    func resize(sessionID: UUID, columns: Int, rows: Int) async throws {
        try await sshOwners[sessionID]?.resize(columns: columns, rows: rows)
    }

    func disconnectTerminal(sessionID: UUID) async {
        await sshOwners[sessionID]?.disconnect()
        sshOwners[sessionID] = nil
        await refreshSnapshots()
    }

    /// The terminal output buffer for a session (for the view).
    func terminalOutput(for sessionID: UUID) -> Data {
        sshOwners[sessionID]?.output ?? Data()
    }

    /// The live VNC session for the viewer, if this center owns one.
    func vncSession(for sessionID: UUID) -> VNCSession? {
        vncOwners[sessionID]?.session
    }

    /// Current FPS for a VNC session.
    func vncFPS(for sessionID: UUID) -> Double {
        vncOwners[sessionID]?.framesPerSecond ?? 0
    }

    // MARK: - VNC over SSH (always through the loopback forwarder)

    /// Connects VNC to a host through the SSH loopback forwarder.
    @discardableResult
    func connectVNC(to host: RemoteHostProfile) async throws -> UUID {
        guard let endpoint = host.vncEndpoint else {
            throw FloeError.invalidConfiguration("Host has no VNC endpoint")
        }
        let sessionID = UUID()
        let record = RemoteSessionRecord(
            id: sessionID, hostID: host.id, kind: .vnc, state: .connecting
        )
        try await environment.remoteSessionRegistry.upsert(record)
        sessions[sessionID] = RemoteSessionSnapshot.derive(record: record)

        let handle = try await sshService.connect(
            profile: host,
            credentialResolver: { [weak self] ref in
                guard let self else { throw SSHConnectionError.invalidCredential }
                return try await self.resolveSecret(ref)
            },
            hostKeyDecision: { [weak self] challenge in
                guard let self else { return false }
                return await self.hostKeyDecision(challenge)
            }
        )
        let forwarder = try await LoopbackSSHForwarder.start(
            session: handle,
            targetHost: endpoint.host,
            targetPort: endpoint.port
        )
        guard let local = forwarder.endpoint else {
            throw FloeError.internalError("Loopback forwarder has no endpoint")
        }
        let password = try await resolveOptionalSecret(endpoint.passwordRef)
            .flatMap { String(data: $0, encoding: .utf8) }
        let vncSession = VNCSession(host: local.host, port: local.port, password: password)
        let owner = VNCSessionOwner(
            sessionID: sessionID,
            hostID: host.id,
            registry: environment.remoteSessionRegistry
        )
        owner.attach(forwarder: forwarder, session: vncSession)
        owner.onStateChange = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.refreshSnapshots()
            }
        }
        vncOwners[sessionID] = owner
        vncSession.connect()
        try await environment.remoteSessionRegistry.updateState(
            id: sessionID, state: .connected, lastHeartbeatAt: Date()
        )
        await refreshSnapshots()
        return sessionID
    }

    func sendVNC(_ action: VNCAction, to sessionID: UUID) async throws {
        try await vncOwners[sessionID]?.send(action)
    }

    func disconnectVNC(sessionID: UUID) async {
        await vncOwners[sessionID]?.disconnect()
        vncOwners[sessionID] = nil
        await refreshSnapshots()
    }

    /// Emergency stop: immediately tears down the VNC session.
    func emergencyStop(sessionID: UUID) async {
        await vncOwners[sessionID]?.emergencyStop()
        vncOwners[sessionID] = nil
        await refreshSnapshots()
    }

    // MARK: - Reconciliation / honest state

    /// On launch: reconcile durable session rows with reality. No live
    /// handles exist after relaunch, so any session not explicitly
    /// disconnected is marked `unknown` (never `paused`).
    func reconcileOnLaunch() async {
        let active = (try? await environment.remoteSessionRegistry.activeSessions()) ?? []
        for session in active {
            // After relaunch there is no live handle; an unmanaged session
            // that was connected/suspended is now honestly unknown.
            try? await environment.remoteSessionRegistry.updateState(
                id: session.id, state: .unknown, lastHeartbeatAt: nil
            )
        }
        await refreshSnapshots()
    }

    /// On backgrounding: mark live sessions suspended and permit iOS
    /// suspension (only legitimate short completion time is requested).
    /// On resume: reconcile.
    func handleScenePhase(_ phase: ScenePhaseShim) async {
        switch phase {
        case .background:
            for owner in sshOwners.values { await owner.suspend() }
            for owner in vncOwners.values { await owner.suspend() }
            await refreshSnapshots()
        case .active:
            await refreshSnapshots()
        case .inactive:
            break
        }
    }

    /// Refreshes the published snapshots from the registry + live owners.
    func refreshSnapshots() async {
        let records = (try? await environment.remoteSessionRegistry.activeSessions()) ?? []
        var map: [UUID: RemoteSessionSnapshot] = [:]
        for record in records {
            let fps = record.kind == .vnc ? (vncOwners[record.id]?.framesPerSecond ?? 0) : 0
            map[record.id] = RemoteSessionSnapshot.derive(record: record, framesPerSecond: fps)
        }
        sessions = map
    }

    // MARK: - Secret helpers

    private func resolveSecret(_ reference: SecretReference) async throws -> Data {
        // The reference's keychainAccount encodes the scope (host.<uuid> or
        // provider.<uuid>). Resolve through the Keychain at the call site.
        let store = KeychainStore(
            service: "org.floeagent.ios.secrets",
            synchronizable: reference.synchronizable
        )
        return try store.read(account: reference.keychainAccount)
    }

    private func resolveOptionalSecret(_ reference: SecretReference?) async throws -> Data? {
        guard let reference else { return nil }
        return try? await resolveSecret(reference)
    }
}

/// Scene-phase shim so the center stays UIKit-free at the API boundary.
enum ScenePhaseShim: Sendable {
    case active, inactive, background
}
#endif
