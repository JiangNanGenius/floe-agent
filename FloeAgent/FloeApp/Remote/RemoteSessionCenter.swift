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
import UIKit
import FloeCore
import FloeExecution
import FloeModels
import FloePersistence
import FloeSecurity
import FloeSSH
import FloeSync
import FloeTools
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
    private var sshOwners: [UUID: SSHSessionOwner] = [:]
    private var vncOwners: [UUID: VNCSessionOwner] = [:]
    private var vncEndpointBySessionID: [UUID: UUID] = [:]
    private var toolManagedVNCSessionIDs: Set<UUID> = []
    /// Most recent tool-managed connection. Observation/input tools prefer it
    /// so an explicit `vnc.connect(hostID, connectionID)` is not silently
    /// shadowed by an unrelated connected viewer session.
    private var preferredVNCSessionID: UUID?
    private var vncIdleDisconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var latestVNCFailureByEndpointID: [UUID: VNCConnectionFailure] = [:]
    private let toolManagedVNCIdleTimeout: TimeInterval = 5 * 60
    /// Continuations for pending TOFU decisions, keyed by challenge id.
    private var trustContinuations: [String: CheckedContinuation<Bool, Never>] = [:]

    init(environment: AppEnvironment) {
        self.environment = environment
        // Use the same store instance that model tools and configuration sync
        // use. Constructing a second store here let SSH succeed through the
        // tool path while the Settings host list observed an empty snapshot.
        let hostStore = environment.remoteHostStore
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
        for host in hosts {
            let authMetadata: (SecretReference, CredentialKind, Bool)? = switch host.auth {
            case .none: nil
            case .password(let ref): (ref, .sshPassword, false)
            case .importedKey(let ref, _): (ref, .sshPrivateKey, false)
            case .deviceGeneratedKey(let ref, _): (ref, .sshPrivateKey, true)
            }
            if let (reference, kind, deviceBound) = authMetadata {
                try? await environment.credentialVault.registerExisting(
                    account: reference.keychainAccount, kind: kind,
                    label: host.displayName, hostID: host.id,
                    synchronizable: reference.synchronizable, deviceBound: deviceBound
                )
            }
            for endpoint in host.vncEndpoints {
                if let vnc = endpoint.passwordRef {
                    try? await environment.credentialVault.registerExisting(
                        account: vnc.keychainAccount, kind: .vncPassword,
                        label: "\(host.displayName) \(endpoint.displayName)", hostID: host.id,
                        synchronizable: vnc.synchronizable
                    )
                }
            }
        }
    }

    func saveHost(_ profile: RemoteHostProfile) async throws {
        try profile.validate()
        let previousStored: RemoteHostStore.StoredHost?
        do {
            previousStored = try await hostStore.host(id: profile.id)
        } catch {
            previousStored = nil
        }
        let previousProfile = previousStored.flatMap { try? RemoteHostProfile(stored: $0) }
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
            },
            deviceKind: profile.deviceKind.rawValue,
            isRemoteExecutionEnvironment: profile.isRemoteExecutionEnvironment,
            vncEndpointsJSON: String(decoding: try encoder.encode(profile.vncEndpoints), as: UTF8.self),
            auxiliaryConnectionsJSON: String(decoding: try encoder.encode(profile.auxiliaryConnections), as: UTF8.self)
        )
        if let stored = try await hostStore.host(id: profile.id) {
            try await environment.configurationSync.saveRemoteHost(stored)
        }
        await reconcileCredentialReferences(previous: previousProfile, current: profile)
        // Saving the host is the explicit signal that endpoint settings or
        // credentials may have changed. Only then may an agent retry a prior
        // non-retryable authentication failure.
        for endpoint in profile.vncEndpoints {
            latestVNCFailureByEndpointID[endpoint.id] = nil
        }
        await loadHosts()
    }

    /// Model-side `ssh.updateHost` writes through the shared persistence
    /// store, bypassing this center's Settings save path. Invalidate stale
    /// endpoint failures and live sessions immediately so the next
    /// vnc.status/connect observes the newly saved endpoint and credential.
    func agentDidUpdateHost(
        hostID: UUID,
        vncEndpointIDs: Set<UUID>
    ) async {
        let staleSessionIDs = vncEndpointBySessionID.compactMap { sessionID, endpointID in
            vncEndpointIDs.contains(endpointID) ? sessionID : nil
        }
        for sessionID in staleSessionIDs {
            await disconnectVNC(sessionID: sessionID)
        }
        for endpointID in vncEndpointIDs {
            latestVNCFailureByEndpointID[endpointID] = nil
        }
        await loadHosts()
        FloeLogger(category: .vnc).info(
            "vncConfigurationReloaded source=ssh.updateHost host=\(hostID.uuidString) endpoints=\(vncEndpointIDs.count)"
        )
    }

    /// Deletes ONE saved local profile. Ordering is deliberate: close this
    /// host's sessions, remove the local host row/config metadata, and only
    /// then delete credential revisions owned solely by this host. A metadata
    /// failure aborts before any secret cleanup; shared references and other
    /// hosts are retained. Nothing is deleted on the remote system.
    @discardableResult
    func deleteHost(id: UUID) async throws -> SSHHostDeletionReceipt {
        guard let stored = try await hostStore.host(id: id) else {
            throw FloeError.notFound("saved host \(id.uuidString)")
        }
        // Deletion must not be blocked by a corrupted profile: recover the
        // auth/endpoint references best-effort so the local row, fixed
        // accounts and unique revisions can still be cleaned.
        let fallbackAuth = (try? JSONDecoder().decode(
            SSHAuthMethod.self,
            from: Data(stored.authJSON.utf8)
        )) ?? .none
        let fallbackEndpoints = (try? JSONDecoder().decode(
            [VNCEndpoint].self,
            from: Data((stored.vncEndpointsJSON ?? "[]").utf8)
        )) ?? []
        let profile = (try? RemoteHostProfile(stored: stored)) ?? RemoteHostProfile(
            id: stored.id,
            displayName: stored.displayName,
            address: stored.address,
            port: stored.port,
            user: stored.user,
            auth: fallbackAuth,
            isRemoteExecutionEnvironment: false,
            vncEndpoints: fallbackEndpoints
        )
        guard let storedHosts = try? await hostStore.hosts(),
              let records = try? await environment.credentialStore.records(owner: nil)
        else {
            throw FloeError.storageCorrupted(
                "Could not read hosts/credentials before deleting the saved profile"
            )
        }
        let allHosts = storedHosts.compactMap { try? RemoteHostProfile(stored: $0) }
        let otherHosts = allHosts.filter { $0.id != id }
        let ownedAccounts = Set(
            SSHHostCredentialReferences.owned(by: profile).map(\.keychainAccount)
        )
        let decodedAllHosts = allHosts.count == storedHosts.count
        let sharedAccounts = decodedAllHosts
            ? Set(
                records.filter {
                    ownedAccounts.contains($0.keychainAccount)
                        && ($0.hostID == nil || $0.hostID != id)
                }.map(\.keychainAccount)
            )
            // A corrupt other profile could still own this reference. Keep
            // every host-owned revision rather than risking a shared delete.
            : ownedAccounts

        let hooks = SSHHostDeletionHooks(
            shutdownSessions: { [weak self] hostID in
                guard let self else { return 0 }
                return await self.shutdownHostSessions(hostID)
            },
            removeMetadata: { [weak self] hostID in
                guard let self else {
                    throw FloeError.invalidConfiguration("Host deletion is unavailable")
                }
                return try await self.removeHostMetadata(hostID)
            },
            cleanupCredentials: { [weak self] hostID, profile, deletable, retained in
                guard let self else {
                    return SSHHostCredentialCleanupResult(deleted: 0, pending: true)
                }
                return await self.cleanupHostCredentials(
                    hostID: hostID,
                    profile: profile,
                    deletable: deletable,
                    retained: retained
                )
            }
        )
        let receipt = try await SSHHostDeletionCoordinator.delete(
            host: profile,
            otherHosts: otherHosts,
            sharedAccounts: sharedAccounts,
            hooks: hooks
        )
        await loadHosts()
        FloeLogger(category: .ssh).info(
            "hostDeleted host=\(id.uuidString) sessions=\(receipt.sessionsClosed) credentials=\(receipt.credentialsDeleted) retained=\(receipt.credentialsRetained)"
        )
        return receipt
    }

    /// Updates exactly to the helper version paired with this app build. The
    /// operation uses verified SSH, performs an atomic replacement, and rolls
    /// back when the loopback health check fails.
    func updateRemoteAgent(on host: RemoteHostProfile) async throws -> RemoteAgentInstaller.Result {
        let installer = RemoteAgentInstaller(service: environment.sshCommandService)
        let result = try await installer.installOrUpdate(hostID: host.id)
        guard result.succeeded else {
            throw FloeError.internalError(result.output)
        }
        return result
    }

    func pairAdvancedLink(on host: RemoteHostProfile) async throws {
        let installer = RemoteAgentInstaller(service: environment.sshCommandService)
        let enrollment = try await installer.enrollDevice(
            hostID: host.id, endpoint: host.address, deviceName: UIDevice.current.name
        )
        try await AdvancedRemoteLinkStore.shared.save(enrollment)
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

    /// Reuses the same visible host-key decision surface for a native
    /// Toolbox connection. Cancellation affects only this exact challenge.
    func decideToolboxHostKey(_ challenge: HostKeyChallenge) async -> Bool {
        guard !Task.isCancelled else { return false }
        return await withTaskCancellationHandler {
            let trusted = await hostKeyDecision(challenge)
            return trusted && !Task.isCancelled
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.pendingTrust?.challenge.id == challenge.id else { return }
                self.resolveTrust(false)
            }
        }
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
        // Inject a tmux/screen bootstrap so the remote session survives
        // disconnects. The command falls back to a plain shell if neither is
        // installed. Session name is per-host so multiple hosts don't collide.
        let sessionName = "floe-\(host.id.uuidString.prefix(8))"
        let bootstrap = "command -v tmux >/dev/null && exec tmux new-session -A -s \(sessionName) || (command -v screen >/dev/null && exec screen -xRR \(sessionName) || exec $SHELL)\n"
        try await pty.write(Data(bootstrap.utf8))
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
    func terminalPresentation(for sessionID: UUID) -> TerminalPresentation? { sshOwners[sessionID]?.presentation }
    /// Opens an additional channel on this already verified native connection.
    func toolboxSSHHandle(for sessionID: UUID) -> SSHSessionHandle? { sshOwners[sessionID]?.handle }

    func terminalOutputEnd(for sessionID: UUID) -> Int { sshOwners[sessionID]?.outputEnd ?? 0 }

    func terminalOutput(for sessionID: UUID) -> Data {
        sshOwners[sessionID]?.output ?? Data()
    }

    /// The live VNC session for the viewer, if this center owns one.
    func vncSession(for sessionID: UUID) -> VNCSession? {
        vncOwners[sessionID]?.session
    }

    /// The first genuinely connected VNC session the agent can drive.
    /// A session still negotiating credentials is never exposed to tools.
    /// A tool-managed session selected by an explicit connect wins over an
    /// unrelated connected viewer so observe/input address the requested
    /// endpoint.
    func activeVNCSession() -> VNCSessionHandle? {
        if let preferred = preferredVNCSessionID,
           let owner = vncOwners[preferred],
           case .connected = owner.connectionState,
           let session = owner.session,
           session.isConnected {
            return VNCSessionHandle(id: preferred, session: session)
        }
        return vncOwners.first(where: { _, owner in
            guard case .connected = owner.connectionState else { return false }
            return owner.session?.isConnected == true
        }).flatMap { id, owner in
            owner.session.map { VNCSessionHandle(id: id, session: $0) }
        }
    }

    /// Returns a reusable live VNC session for agent tools. When no viewer or
    /// prior tool session is active, a single unambiguous configured endpoint
    /// is connected on demand. Tool-created sessions stay alive across calls
    /// and are reclaimed only after an idle grace period.
    func activeOrConnectVNCSession() async throws -> VNCSessionHandle? {
        if let active = activeVNCSession() {
            preferredVNCSessionID = active.id
            armToolManagedVNCIdleDisconnect(sessionID: active.id)
            return active
        }
        if hosts.isEmpty { await loadHosts() }
        let candidates = hosts.flatMap { host in
            host.vncEndpoints.map { (host: host, endpoint: $0) }
        }
        guard !candidates.isEmpty else {
            throw FloeError.invalidConfiguration(
                "No VNC connection is configured. Add a direct or SSH-tunnel VNC endpoint first."
            )
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            let names = candidates.prefix(6).map { "\($0.host.displayName)/\($0.endpoint.displayName)" }
                .joined(separator: ", ")
            throw FloeError.invalidConfiguration(
                "Multiple VNC endpoints are configured (\(names)). Call ssh.listHosts and pass hostID plus connectionID to vnc.connect instead of relying on a viewer preselection."
            )
        }

        if let failure = latestVNCFailureByEndpointID[candidate.endpoint.id],
           failure.category == .authenticationFailed || failure.category == .credentialMissing {
            throw failure
        }

        if let existing = vncEndpointBySessionID.first(where: { $0.value == candidate.endpoint.id })?.key,
           let owner = vncOwners[existing] {
            switch owner.connectionState {
            case .connected:
                preferredVNCSessionID = existing
                armToolManagedVNCIdleDisconnect(sessionID: existing)
                return owner.session.map { VNCSessionHandle(id: existing, session: $0) }
            case .connecting:
                preferredVNCSessionID = existing
                return try await waitForVNCConnection(sessionID: existing, endpoint: candidate.endpoint)
            case .failed, .disconnected:
                await disconnectVNC(sessionID: existing)
            }
        }

        let sessionID = try await connectVNC(
            to: candidate.host,
            endpoint: candidate.endpoint,
            toolManaged: true
        )
        return try await waitForVNCConnection(sessionID: sessionID, endpoint: candidate.endpoint)
    }

    /// Secret-free state for the model-facing lifecycle tools. Reading this
    /// value never opens a socket or extends a session's idle lifetime.
    func toolVNCStatus() async -> VNCToolConnectionStatus {
        if hosts.isEmpty { await loadHosts() }
        let candidates = hosts.flatMap { host in
            host.vncEndpoints.map { (host: host, endpoint: $0) }
        }
        guard !candidates.isEmpty else {
            return VNCToolConnectionStatus(state: .unconfigured, configuredEndpointCount: 0)
        }

        func endpoint(for sessionID: UUID?) -> (host: RemoteHostProfile, endpoint: VNCEndpoint)? {
            guard let sessionID, let endpointID = vncEndpointBySessionID[sessionID] else { return nil }
            return candidates.first(where: { $0.endpoint.id == endpointID })
        }

        func status(
            _ state: VNCToolConnectionStatus.State,
            sessionID: UUID? = nil,
            endpoint: VNCEndpoint? = nil,
            failure: VNCConnectionFailure? = nil
        ) -> VNCToolConnectionStatus {
            let match = endpoint.flatMap { value in
                candidates.first(where: { $0.endpoint.id == value.id })
            }
            let managed = sessionID.map { toolManagedVNCSessionIDs.contains($0) } ?? false
            return VNCToolConnectionStatus(
                state: state,
                configuredEndpointCount: candidates.count,
                sessionID: sessionID,
                target: endpoint.map { "\($0.host):\($0.port)" },
                hostID: match?.host.id,
                connectionID: endpoint?.id,
                connectionName: endpoint?.displayName,
                transport: endpoint?.transport.rawValue,
                toolManaged: managed,
                idleTimeoutSeconds: managed ? Int(toolManagedVNCIdleTimeout) : nil,
                failure: failure
            )
        }

        let connectedIDs = vncOwners.compactMap { sessionID, owner -> UUID? in
            if case .connected = owner.connectionState { return sessionID }
            return nil
        }
        if let sessionID = preferredVNCSessionID.flatMap({
            connectedIDs.contains($0) ? $0 : nil
        }) ?? connectedIDs.first,
           let match = endpoint(for: sessionID) {
            return status(.connected, sessionID: sessionID, endpoint: match.endpoint)
        }
        if let (sessionID, _) = vncOwners.first(where: {
            if case .connecting = $0.value.connectionState { return true }
            return false
        }), let match = endpoint(for: sessionID) {
            return status(.connecting, sessionID: sessionID, endpoint: match.endpoint)
        }
        if let (sessionID, owner) = vncOwners.first(where: {
            if case .failed = $0.value.connectionState { return true }
            return false
        }), case .failed(let failure) = owner.connectionState,
           let match = endpoint(for: sessionID) {
            return status(.failed, sessionID: sessionID, endpoint: match.endpoint, failure: failure)
        }
        if let candidate = candidates.first(where: {
            latestVNCFailureByEndpointID[$0.endpoint.id] != nil
        }), let failure = latestVNCFailureByEndpointID[candidate.endpoint.id] {
            return status(.failed, endpoint: candidate.endpoint, failure: failure)
        }
        return status(
            .disconnected,
            endpoint: candidates.count == 1 ? candidates[0].endpoint : nil
        )
    }

    /// Performs a fresh handshake for tool-owned sessions. A saved
    /// authentication failure remains blocked until the endpoint is edited,
    /// preventing an accidental retry storm with the same password.
    func reconnectToolVNCSession() async throws -> VNCSessionHandle? {
        let toolSessions = Array(toolManagedVNCSessionIDs)
        for sessionID in toolSessions { await disconnectVNC(sessionID: sessionID) }
        return try await activeOrConnectVNCSession()
    }

    // MARK: - Explicit VNC endpoint selection

    private struct ResolvedVNCTarget {
        let host: RemoteHostProfile
        let endpoint: VNCEndpoint
    }

    /// Resolves saved UUIDs instead of relying on a viewer preselection.
    /// Supplying only one identifier is refused: a VNC connection id is stable
    /// but its owning host must be explicit when more than one host exists.
    private func resolveVNCTarget(
        hostID: UUID?,
        connectionID: UUID?
    ) async throws -> ResolvedVNCTarget {
        if hosts.isEmpty { await loadHosts() }
        switch (hostID, connectionID) {
        case let (rawHost?, rawConnection?):
            guard let host = hosts.first(where: { $0.id == rawHost }) else {
                throw FloeError.validationFailed("Saved host \(rawHost.uuidString) was not found.")
            }
            guard let endpoint = host.vncEndpoints.first(where: { $0.id == rawConnection }) else {
                throw FloeError.validationFailed(
                    "VNC connection \(rawConnection.uuidString) is not configured on \(host.displayName)."
                )
            }
            return ResolvedVNCTarget(host: host, endpoint: endpoint)
        case (nil, nil):
            let candidates = hosts.flatMap { host in
                host.vncEndpoints.map { ResolvedVNCTarget(host: host, endpoint: $0) }
            }
            guard !candidates.isEmpty else {
                throw FloeError.invalidConfiguration("No VNC endpoint is saved.")
            }
            guard candidates.count == 1, let target = candidates.first else {
                throw FloeError.invalidConfiguration(
                    "Multiple VNC endpoints are saved. Pass hostID and connectionID."
                )
            }
            return target
        default:
            throw FloeError.validationFailed(
                "hostID and connectionID must be provided together."
            )
        }
    }

    /// Connects one exact saved endpoint, reusing a live session for it.
    /// This is the app adapter behind `vnc.connect(hostID, connectionID)`.
    /// `approvalContext` carries the task's canonical nested-approval seam so
    /// a first-use SSH host key is decided by the user in the same call; a
    /// background call without that seam fails closed instead of parking on
    /// an invisible UI sheet.
    @discardableResult
    func connectVNCSession(
        hostID: UUID?,
        connectionID: UUID?,
        approvalContext: ToolContext? = nil
    ) async throws -> VNCSessionHandle? {
        let target = try await resolveVNCTarget(hostID: hostID, connectionID: connectionID)
        if let failure = latestVNCFailureByEndpointID[target.endpoint.id],
           failure.category == .authenticationFailed || failure.category == .credentialMissing {
            throw failure
        }
        if let existing = vncEndpointBySessionID.first(where: { $0.value == target.endpoint.id })?.key,
           let owner = vncOwners[existing] {
            switch owner.connectionState {
            case .connected:
                // An explicit agent connect may reuse a user-opened viewer,
                // but only a session this center already owns becomes
                // tool-managed (and therefore closable by vnc.disconnect).
                preferredVNCSessionID = existing
                armToolManagedVNCIdleDisconnect(sessionID: existing)
                return owner.session.map { VNCSessionHandle(id: existing, session: $0) }
            case .connecting:
                preferredVNCSessionID = existing
                armToolManagedVNCIdleDisconnect(sessionID: existing)
                return try await waitForVNCConnection(sessionID: existing, endpoint: target.endpoint)
            case .failed, .disconnected:
                await disconnectVNC(sessionID: existing)
            }
        }
        let sessionID: UUID
        do {
            sessionID = try await connectVNC(
                to: target.host,
                endpoint: target.endpoint,
                toolManaged: true,
                approvalContext: approvalContext
            )
        } catch let error as SSHConnectionError {
            let failure = Self.vncFailure(from: error, endpoint: target.endpoint)
            latestVNCFailureByEndpointID[target.endpoint.id] = failure
            throw failure
        }
        return try await waitForVNCConnection(sessionID: sessionID, endpoint: target.endpoint)
    }

    /// Discards only the tool-managed session for the requested endpoint and
    /// performs a fresh handshake. A user-opened viewer is never interrupted.
    @discardableResult
    func reconnectVNCSession(
        hostID: UUID?,
        connectionID: UUID?,
        approvalContext: ToolContext? = nil
    ) async throws -> VNCSessionHandle? {
        if hostID == nil, connectionID == nil {
            return try await reconnectToolVNCSession()
        }
        let target = try await resolveVNCTarget(hostID: hostID, connectionID: connectionID)
        let stale = vncEndpointBySessionID.compactMap { pair -> UUID? in
            let (sessionID, endpointID) = pair
            guard endpointID == target.endpoint.id,
                  toolManagedVNCSessionIDs.contains(sessionID) else { return nil }
            return sessionID
        }
        for sessionID in stale { await disconnectVNC(sessionID: sessionID) }
        return try await connectVNCSession(
            hostID: hostID,
            connectionID: connectionID,
            approvalContext: approvalContext
        )
    }

    /// Closes only model-created sessions. A viewer opened by the user is not
    /// interrupted by a model lifecycle command.
    func disconnectToolVNCSessions() async -> VNCToolConnectionStatus {
        let toolSessions = Array(toolManagedVNCSessionIDs)
        for sessionID in toolSessions { await disconnectVNC(sessionID: sessionID) }
        return await toolVNCStatus()
    }

    func vncConnectionState(for sessionID: UUID) -> VNCSessionState {
        vncOwners[sessionID]?.connectionState ?? .disconnected
    }

    /// Current FPS for a VNC session.
    func vncFPS(for sessionID: UUID) -> Double {
        vncOwners[sessionID]?.framesPerSecond ?? 0
    }

    // MARK: - VNC direct or over verified SSH

    /// Connects one selected VNC profile directly or through SSH.
    @discardableResult
    func connectVNC(
        to host: RemoteHostProfile,
        endpoint selected: VNCEndpoint? = nil,
        toolManaged: Bool = false,
        approvalContext: ToolContext? = nil
    ) async throws -> UUID {
        guard let endpoint = selected ?? host.vncEndpoint else {
            throw FloeError.invalidConfiguration("Host has no VNC endpoint")
        }
        if let reusable = vncEndpointBySessionID.first(where: { $0.value == endpoint.id })?.key,
           let owner = vncOwners[reusable] {
            switch owner.connectionState {
            case .connecting, .connected:
                if toolManaged { toolManagedVNCSessionIDs.insert(reusable) }
                armToolManagedVNCIdleDisconnect(sessionID: reusable)
                return reusable
            case .failed, .disconnected:
                await disconnectVNC(sessionID: reusable)
            }
        }
        let sessionID = UUID()
        let record = RemoteSessionRecord(
            id: sessionID, hostID: host.id, kind: .vnc, state: .connecting
        )
        try await environment.remoteSessionRegistry.upsert(record)
        sessions[sessionID] = RemoteSessionSnapshot.derive(record: record)

        let password = try await resolveOptionalSecret(endpoint.passwordRef)
            .flatMap { String(data: $0, encoding: .utf8) }
        let owner = VNCSessionOwner(
            sessionID: sessionID,
            hostID: host.id,
            endpointHost: endpoint.host,
            endpointPort: endpoint.port,
            registry: environment.remoteSessionRegistry
        )
        let vncSession: VNCSession
        switch endpoint.transport {
        case .direct:
            guard let remotePort = UInt16(exactly: endpoint.port) else {
                throw FloeError.validationFailed("VNC port must be 1-65535")
            }
            vncSession = VNCSession(host: endpoint.host, port: remotePort, password: password)
            owner.attach(session: vncSession)
        case .sshTunnel:
            let handle = try await sshService.connect(
                profile: host,
                credentialResolver: { [weak self] ref in
                    guard let self else { throw SSHConnectionError.invalidCredential }
                    return try await self.resolveSecret(ref)
                },
                hostKeyDecision: { [weak self] challenge in
                    if let approvalContext {
                        return await Self.requestTaskHostKeyApproval(
                            challenge,
                            host: host,
                            context: approvalContext
                        )
                    }
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
            vncSession = VNCSession(host: local.host, port: local.port, password: password)
            owner.attach(forwarder: forwarder, session: vncSession)
        }
        owner.onStateChange = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .failed(let failure) = owner.connectionState {
                    self.latestVNCFailureByEndpointID[endpoint.id] = failure
                }
                await self.refreshSnapshots()
            }
        }
        vncOwners[sessionID] = owner
        vncEndpointBySessionID[sessionID] = endpoint.id
        if toolManaged {
            toolManagedVNCSessionIDs.insert(sessionID)
            preferredVNCSessionID = sessionID
        }
        vncSession.connect()
        armToolManagedVNCIdleDisconnect(sessionID: sessionID)
        await refreshSnapshots()
        return sessionID
    }

    func sendVNC(_ action: VNCAction, to sessionID: UUID) async throws {
        guard let owner = vncOwners[sessionID] else {
            throw VNCConnectionFailure(
                category: .configurationMissing,
                stage: .configuration,
                retryable: true,
                host: "unknown",
                port: 0,
                message: "The selected VNC session no longer exists. Reconnect before sending input."
            )
        }
        try await owner.send(action)
        armToolManagedVNCIdleDisconnect(sessionID: sessionID)
    }

    func disconnectVNC(sessionID: UUID) async {
        vncIdleDisconnectTasks.removeValue(forKey: sessionID)?.cancel()
        await vncOwners[sessionID]?.disconnect()
        vncOwners[sessionID] = nil
        vncEndpointBySessionID[sessionID] = nil
        toolManagedVNCSessionIDs.remove(sessionID)
        if preferredVNCSessionID == sessionID { preferredVNCSessionID = nil }
        await refreshSnapshots()
    }

    /// Emergency stop: immediately tears down the VNC session.
    func emergencyStop(sessionID: UUID) async {
        vncIdleDisconnectTasks.removeValue(forKey: sessionID)?.cancel()
        await vncOwners[sessionID]?.emergencyStop()
        vncOwners[sessionID] = nil
        vncEndpointBySessionID[sessionID] = nil
        toolManagedVNCSessionIDs.remove(sessionID)
        if preferredVNCSessionID == sessionID { preferredVNCSessionID = nil }
        await refreshSnapshots()
    }

    private func waitForVNCConnection(
        sessionID: UUID,
        endpoint: VNCEndpoint
    ) async throws -> VNCSessionHandle? {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            guard let owner = vncOwners[sessionID] else { break }
            switch owner.connectionState {
            case .connected:
                latestVNCFailureByEndpointID[endpoint.id] = nil
                armToolManagedVNCIdleDisconnect(sessionID: sessionID)
                return owner.session.map { VNCSessionHandle(id: sessionID, session: $0) }
            case .failed(let failure):
                latestVNCFailureByEndpointID[endpoint.id] = failure
                throw failure
            case .connecting, .disconnected:
                try await Task.sleep(for: .milliseconds(150))
            }
        }
        if let previous = latestVNCFailureByEndpointID[endpoint.id] {
            throw previous
        }
        throw VNCConnectionFailure(
            category: .timedOut,
            stage: .framebuffer,
            retryable: true,
            host: endpoint.host,
            port: endpoint.port,
            message: "VNC connection timed out after 15 seconds while waiting for authentication and the first framebuffer."
        )
    }

    private func armToolManagedVNCIdleDisconnect(sessionID: UUID) {
        guard toolManagedVNCSessionIDs.contains(sessionID) else { return }
        vncIdleDisconnectTasks.removeValue(forKey: sessionID)?.cancel()
        let timeout = toolManagedVNCIdleTimeout
        vncIdleDisconnectTasks[sessionID] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.disconnectVNC(sessionID: sessionID)
        }
    }

    /// First-use SSH host-key decision for a model-initiated VNC connection.
    /// Uses the ONE task-scoped nested-approval card. Without that seam
    /// (background/detached job) the decision fails closed instead of
    /// presenting an invisible viewer sheet.
    private static func requestTaskHostKeyApproval(
        _ challenge: HostKeyChallenge,
        host: RemoteHostProfile,
        context: ToolContext
    ) async -> Bool {
        guard let approval = context.nestedApproval else { return false }
        let reason: String
        if FloeL10n.isChinese {
            reason = """
            信任这台 SSH 主机吗？
            主机：\(host.displayName)（\(challenge.address):\(challenge.port)）
            密钥：\(challenge.keyType) \(challenge.fingerprintSHA256)
            这是首次连接。只有在你确认该指纹属于目标设备时才允许。以后指纹变化会直接拒绝连接。
            """
        } else {
            reason = """
            Trust this SSH host?
            Host: \(host.displayName) (\(challenge.address):\(challenge.port))
            Key: \(challenge.keyType) \(challenge.fingerprintSHA256)
            This is the first connection. Approve only if you recognize this fingerprint. A later change is always rejected.
            """
        }
        return await approval.request(reason: reason) == .allowed
    }

    /// Converts an SSH transport/identity failure into the bounded VNC
    /// failure shape the model tools already understand. No credential bytes
    /// or connection objects cross this boundary.
    private static func vncFailure(
        from error: SSHConnectionError,
        endpoint: VNCEndpoint
    ) -> VNCConnectionFailure {
        switch error {
        case .hostKeyRejected, .hostKeyChanged:
            return VNCConnectionFailure(
                category: .handshakeFailed,
                stage: .handshake,
                retryable: false,
                host: endpoint.host,
                port: endpoint.port,
                message: error.localizedDescription
            )
        case .invalidCredential:
            return VNCConnectionFailure(
                category: .credentialMissing,
                stage: .credentialResolution,
                retryable: false,
                host: endpoint.host,
                port: endpoint.port,
                message: error.localizedDescription
            )
        case .authenticationFailed:
            return VNCConnectionFailure(
                category: .authenticationFailed,
                stage: .authentication,
                retryable: false,
                host: endpoint.host,
                port: endpoint.port,
                message: error.localizedDescription
            )
        case .connectionRefused:
            return VNCConnectionFailure(
                category: .connectionRefused,
                stage: .transport,
                retryable: true,
                host: endpoint.host,
                port: endpoint.port,
                message: error.localizedDescription
            )
        case .timedOut:
            return VNCConnectionFailure(
                category: .timedOut,
                stage: .transport,
                retryable: true,
                host: endpoint.host,
                port: endpoint.port,
                message: error.localizedDescription
            )
        case .hostNotFound, .networkUnreachable:
            return VNCConnectionFailure(
                category: .networkUnreachable,
                stage: .transport,
                retryable: true,
                host: endpoint.host,
                port: endpoint.port,
                message: error.localizedDescription
            )
        case .sshNotConfigured, .invalidHostKey, .unsupportedKeyType, .transport:
            return VNCConnectionFailure(
                category: .handshakeFailed,
                stage: .handshake,
                retryable: false,
                host: endpoint.host,
                port: endpoint.port,
                message: error.localizedDescription
            )
        }
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

    // MARK: - Credential reference reconciliation

    /// After an editor save, delete only the previous auth/endpoint
    /// references that are no longer referenced, and align the metadata kind
    /// with the actual authentication method. A shared reference is never
    /// deleted here because it remains referenced by another host record.
    private func reconcileCredentialReferences(
        previous: RemoteHostProfile?,
        current: RemoteHostProfile
    ) async {
        guard let previous else {
            await syncAuthMetadata(current: current)
            return
        }
        let currentAuth = Self.reference(of: current.auth)
        let currentEndpointAccounts = Set(
            current.vncEndpoints.compactMap { $0.passwordRef?.keychainAccount }
        )
        guard let storedHosts = try? await hostStore.hosts(),
              let records = try? await environment.credentialStore.records(owner: nil)
        else {
            await syncAuthMetadata(current: current)
            return
        }
        let allHosts = storedHosts.compactMap { try? RemoteHostProfile(stored: $0) }
        guard allHosts.count == storedHosts.count else {
            await syncAuthMetadata(current: current)
            return
        }
        let otherHostAccounts = Set(
            allHosts
                .filter { $0.id != current.id }
                .flatMap { SSHHostCredentialReferences.owned(by: $0) }
                .map(\.keychainAccount)
        )
        let sharedAccounts = Set(
            records.filter { $0.hostID == nil || $0.hostID != current.id }
                .map(\.keychainAccount)
        )
        var oldReferences: [SecretReference] = []
        if let previousAuth = Self.reference(of: previous.auth),
           previousAuth.keychainAccount != currentAuth?.keychainAccount {
            oldReferences.append(previousAuth)
        }
        for endpoint in previous.vncEndpoints {
            if let reference = endpoint.passwordRef,
               !currentEndpointAccounts.contains(reference.keychainAccount) {
                oldReferences.append(reference)
            }
        }
        var seen: Set<String> = []
        for reference in oldReferences
        where seen.insert(reference.keychainAccount).inserted
            && !otherHostAccounts.contains(reference.keychainAccount)
            && !sharedAccounts.contains(reference.keychainAccount) {
            do {
                try deleteKeychainAccount(reference.keychainAccount)
                await deleteCredentialMetadata(account: reference.keychainAccount)
            } catch {
                FloeLogger(category: .security).warning(
                    "hostCredentialReferenceCleanupFailed host=\(current.id.uuidString)"
                )
            }
        }
        await syncAuthMetadata(current: current)
    }

    private func syncAuthMetadata(current: RemoteHostProfile) async {
        guard let reference = Self.reference(of: current.auth) else { return }
        let kind: CredentialKind
        let deviceBound: Bool
        switch current.auth {
        case .none:
            return
        case .password:
            kind = .sshPassword
            deviceBound = false
        case .importedKey:
            kind = .sshPrivateKey
            deviceBound = false
        case .deviceGeneratedKey:
            kind = .sshPrivateKey
            deviceBound = true
        }
        let records = (try? await environment.credentialStore.records(owner: nil)) ?? []
        if var record = records.first(where: {
            $0.keychainAccount == reference.keychainAccount
        }) {
            record.kind = kind
            record.owner = .vault
            record.hostID = current.id
            record.label = current.displayName
            record.synchronizable = reference.synchronizable
            record.deviceBound = deviceBound
            record.updatedAt = Date()
            try? await environment.credentialStore.save(record)
            return
        }
        try? await environment.credentialVault.registerExisting(
            account: reference.keychainAccount,
            kind: kind,
            label: current.displayName,
            hostID: current.id,
            synchronizable: reference.synchronizable,
            deviceBound: deviceBound
        )
    }

    private static func reference(of auth: SSHAuthMethod) -> SecretReference? {
        switch auth {
        case .none: nil
        case .password(let reference): reference
        case .importedKey(let reference, _): reference
        case .deviceGeneratedKey(let reference, _): reference
        }
    }

    // MARK: - Deletion helpers

    private func shutdownHostSessions(_ hostID: UUID) async -> Int {
        let terminalIDs = sshOwners
            .filter { $0.value.hostID == hostID }
            .map(\.key)
        let vncIDs = vncOwners
            .filter { $0.value.hostID == hostID }
            .map(\.key)
        for sessionID in terminalIDs {
            await disconnectTerminal(sessionID: sessionID)
        }
        for sessionID in vncIDs {
            await disconnectVNC(sessionID: sessionID)
        }
        return terminalIDs.count + vncIDs.count
    }

    /// Removes the local host row/config metadata. Returns true when only the
    /// outbound sync enqueue failed after the local row was already gone.
    private func removeHostMetadata(_ hostID: UUID) async throws -> Bool {
        do {
            try await environment.configurationSync.deleteRemoteHost(id: hostID)
            return false
        } catch let removalError {
            do {
                let remaining = try await hostStore.host(id: hostID)
                if remaining == nil { return true }
            } catch {
                // The read failed; treat the metadata removal as failed too.
            }
            throw removalError
        }
    }

    private func cleanupHostCredentials(
        hostID: UUID,
        profile: RemoteHostProfile,
        deletable: [SecretReference],
        retained: Set<String>
    ) async -> SSHHostCredentialCleanupResult {
        var deleted = 0
        var pending = false
        for reference in deletable {
            do {
                try deleteKeychainAccount(reference.keychainAccount)
                await deleteCredentialMetadata(account: reference.keychainAccount)
                deleted += 1
            } catch {
                pending = true
                FloeLogger(category: .security).warning(
                    "hostCredentialCleanupFailed host=\(hostID.uuidString)"
                )
            }
        }
        var fixedAccounts: Set<String> = [
            "host.ssh.\(hostID.uuidString)",
            "host.vnc.\(hostID.uuidString)"
        ]
        for endpoint in profile.vncEndpoints {
            fixedAccounts.insert(
                "host.vnc.\(hostID.uuidString).\(endpoint.id.uuidString)"
            )
        }
        for account in fixedAccounts where !retained.contains(account) {
            do {
                try deleteKeychainAccount(account)
                await deleteCredentialMetadata(account: account)
            } catch {
                pending = true
            }
        }
        await environment.credentialVault.drainDeletionQueue()
        return SSHHostCredentialCleanupResult(deleted: deleted, pending: pending)
    }


    /// Deletes one exact account from both Keychain namespaces. Missing items
    /// are treated as already deleted; the first real failure is returned.
    private func deleteKeychainAccount(_ account: String) throws {
        var firstError: Error?
        for synchronizable in [true, false] {
            do {
                try KeychainStore(
                    service: KeychainSecretStore.defaultService,
                    synchronizable: synchronizable
                ).delete(account: account)
            } catch KeychainStoreError.itemNotFound {
                continue
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private func deleteCredentialMetadata(account: String) async {
        guard let records = try? await environment.credentialStore.records(owner: nil)
        else { return }
        for record in records where record.keychainAccount == account {
            try? await environment.credentialStore.delete(id: record.id)
        }
    }

    // MARK: - Secret helpers

    private func resolveSecret(_ reference: SecretReference) async throws -> Data {
        // The reference's keychainAccount encodes the scope (host.<uuid> or
        // provider.<uuid>). Credentials may have been saved before the user
        // changed the iCloud Keychain preference, so read both namespaces.
        let preferredStore = KeychainStore(
            service: "org.floeagent.ios.secrets",
            synchronizable: reference.synchronizable
        )
        do {
            return try preferredStore.read(account: reference.keychainAccount)
        } catch KeychainStoreError.itemNotFound {
            let fallbackStore = KeychainStore(
                service: "org.floeagent.ios.secrets",
                synchronizable: !reference.synchronizable
            )
            return try fallbackStore.read(account: reference.keychainAccount)
        }
    }

    private func resolveOptionalSecret(_ reference: SecretReference?) async throws -> Data? {
        guard let reference else { return nil }
        return try await resolveSecret(reference)
    }
}

/// Scene-phase shim so the center stays UIKit-free at the API boundary.
enum ScenePhaseShim: Sendable {
    case active, inactive, background
}
#endif
