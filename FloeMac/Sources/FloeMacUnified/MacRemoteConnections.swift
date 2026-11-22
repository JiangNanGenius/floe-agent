// SPDX-License-Identifier: MPL-2.0
//
// MacRemoteConnections — task-owned saved SSH / VNC connection glue.
//
// Mirrors the shipping iPad contracts (v1.8.72 FloePersistence.RemoteHostStore,
// FloeSSH.RemoteHostProfile, FloePersistence.RemoteSessionRegistry) with the
// portable, Foundation-only subset the native Mac workbench needs:
//
//   * Host metadata is displayName + SSH address/port/user + named VNC
//     endpoints. Secrets NEVER enter this store: SSH authentication and
//     host-key confirmation stay in the on-screen terminal via the system
//     OpenSSH client, and a VNC password is typed per connect and lives only
//     in memory inside MacVNCSessionOwner. There is deliberately no auth
//     JSON, no key material and no password field here.
//   * The session registry keeps one durable row per live connection so a
//     relaunched workbench can render connected/disconnected honestly, same
//     as the iPad remote_sessions table.
//   * Persistence is injected: the coordinator owns the SQLite runtime and
//     supplies adapters for ``MacRemoteHostStore`` and
//     ``MacRemoteSessionRegistry`` (same method vocabulary as the iPad
//     stores). This package ships in-memory defaults so the feature is
//     usable and testable without the coordinator's adapter.
//
// Ownership contract (coordinator integration contract):
// - One ``MacTaskRemoteConnectionsOwner`` per task ID, created through
//   ``MacTaskRemoteConnectionsStore``. SSH is delegated to the task's
//   existing ``MacTaskTerminalOwner`` so the PTY, the OTA/Bridge lease and
//   the system host-key prompts behave exactly like the hand-typed path.
// - VNC is owned by a per-task ``MacVNCSessionOwner``; only the user's
//   Connect press opens a connection, and disconnect/reconnect are explicit.
// - Nothing starts on navigation or on appear; every connect is a user
//   action. Switching tasks never kills the previous task's sessions.

import Combine
import FloeMacTerminal
import FloeMacVNC
import Foundation

// MARK: - Host metadata (portable RemoteHostProfile subset)

/// One named VNC endpoint on a saved host. A password is never part of the
/// record; the user enters it per connection and it stays in memory only.
public struct MacRemoteVNCEndpoint: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var host: String
    public var port: Int

    public init(id: UUID = UUID(), displayName: String = "VNC", host: String, port: Int = 5900) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
    }

    /// Applies the same host/port safety rules as the toolbox
    /// ``MacVNCConfiguration``: whitespace, URL schemes and credential or
    /// path separators are rejected, never repaired.
    public func validated() throws -> MacRemoteVNCEndpoint {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { throw MacRemoteConnectionsError.emptyVNCHost }
        guard !trimmedHost.contains("://") else { throw MacRemoteConnectionsError.invalidVNCHost(trimmedHost) }
        guard trimmedHost.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw MacRemoteConnectionsError.invalidVNCHost(trimmedHost)
        }
        guard !trimmedHost.contains("/"), !trimmedHost.contains("?"), !trimmedHost.contains("#"),
              !trimmedHost.contains("@") else {
            throw MacRemoteConnectionsError.invalidVNCHost(trimmedHost)
        }
        guard (1...65_535).contains(port) else { throw MacRemoteConnectionsError.invalidVNCPort(port) }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return MacRemoteVNCEndpoint(
            id: id,
            displayName: trimmedName.isEmpty ? "VNC" : trimmedName,
            host: trimmedHost,
            port: port
        )
    }

    /// In-memory connection configuration; the password argument is never
    /// persisted by the caller.
    public func configuration(password: String?) -> MacVNCConfiguration {
        MacVNCConfiguration(host: host, port: port, password: password)
    }
}

/// A user-saved remote host. SSH fields may be empty for a VNC-only host.
/// This is metadata only: it grants no access and carries no secrets.
public struct MacRemoteHostProfile: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var displayName: String
    /// SSH host name, IPv4 or bracketed IPv6 address. Empty = VNC-only host.
    public var address: String
    public var port: Int
    public var user: String
    public var vncEndpoints: [MacRemoteVNCEndpoint]

    public var hasSSHConnection: Bool { !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public init(
        id: UUID = UUID(),
        displayName: String,
        address: String = "",
        port: Int = 22,
        user: String = "",
        vncEndpoints: [MacRemoteVNCEndpoint] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.address = address
        self.port = port
        self.user = user
        self.vncEndpoints = vncEndpoints
    }

    /// Same validation discipline as the iPad profile: reject rather than
    /// repair, so a pasted value can never smuggle in extra behaviour.
    public func validated() throws -> MacRemoteHostProfile {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw MacRemoteConnectionsError.emptyDisplayName }
        guard trimmedName.count <= 64 else { throw MacRemoteConnectionsError.invalidDisplayName(trimmedName) }

        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAddress.isEmpty {
            // Reuse the strict SSH destination grammar so a saved host is
            // exactly as safe as the hand-typed inspector path.
            _ = try MacSSHHost.validated(host: trimmedAddress, user: trimmedUser.isEmpty ? nil : trimmedUser, port: port)
        } else {
            guard !vncEndpoints.isEmpty else { throw MacRemoteConnectionsError.hostNeedsSSHorVNC }
        }
        var endpoints: [MacRemoteVNCEndpoint] = []
        for endpoint in vncEndpoints {
            endpoints.append(try endpoint.validated())
        }
        // Endpoint display names must be unique within a host so the picker
        // and reconnect path can address them unambiguously.
        guard Set(endpoints.map(\.id)).count == endpoints.count else {
            throw MacRemoteConnectionsError.duplicateVNCEndpoint
        }
        return MacRemoteHostProfile(
            id: id,
            displayName: trimmedName,
            address: trimmedAddress,
            port: port,
            user: trimmedUser,
            vncEndpoints: endpoints
        )
    }

    /// Converts to the validated interactive SSH destination used by the
    /// terminal owner. Never construct a destination from raw strings
    /// outside this conversion.
    public func sshHost() throws -> MacSSHHost {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else { throw MacRemoteConnectionsError.hostNeedsSSHorVNC }
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        return try MacSSHHost.validated(
            host: trimmedAddress,
            user: trimmedUser.isEmpty ? nil : trimmedUser,
            port: port
        )
    }

    public func vncEndpoint(id: UUID) throws -> MacRemoteVNCEndpoint {
        guard let endpoint = vncEndpoints.first(where: { $0.id == id }) else {
            throw MacRemoteConnectionsError.endpointNotFound(id)
        }
        return endpoint
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, address, port, user, vncEndpoints
    }

    /// Older fixtures may omit endpoint arrays; decode to an empty list so
    /// stored rows stay readable across shape additions.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        address = try values.decodeIfPresent(String.self, forKey: .address) ?? ""
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 22
        user = try values.decodeIfPresent(String.self, forKey: .user) ?? ""
        vncEndpoints = try values.decodeIfPresent([MacRemoteVNCEndpoint].self, forKey: .vncEndpoints) ?? []
    }
}

public enum MacRemoteConnectionsError: Error, Equatable, Sendable {
    case emptyDisplayName
    case invalidDisplayName(String)
    case hostNeedsSSHorVNC
    case duplicateVNCEndpoint
    case endpointNotFound(UUID)
    case hostNotFound(UUID)
    case emptyVNCHost
    case invalidVNCHost(String)
    case invalidVNCPort(Int)
    case noPreviousConnection
    case connectionAlreadyActive
    case ownerRetired

    public var message: String {
        switch self {
        case .emptyDisplayName:
            return MacRemoteConnectionsCopy.t("请填写主机名称。", "Enter a display name for this host.")
        case .invalidDisplayName(let name):
            return MacRemoteConnectionsCopy.t("主机名称无效：\(name)", "Invalid display name: \(name)")
        case .hostNeedsSSHorVNC:
            return MacRemoteConnectionsCopy.t(
                "请填写 SSH 地址，或至少添加一个 VNC 端点。",
                "Enter an SSH address or add at least one VNC endpoint."
            )
        case .duplicateVNCEndpoint:
            return MacRemoteConnectionsCopy.t("VNC 端点 ID 重复。", "Duplicate VNC endpoint ID.")
        case .endpointNotFound(let id):
            return MacRemoteConnectionsCopy.t("找不到 VNC 端点：\(id.uuidString)", "VNC endpoint not found: \(id.uuidString)")
        case .hostNotFound(let id):
            return MacRemoteConnectionsCopy.t("找不到已保存的主机：\(id.uuidString)", "Saved host not found: \(id.uuidString)")
        case .emptyVNCHost:
            return MacRemoteConnectionsCopy.t("VNC 主机地址不能为空。", "VNC host address cannot be empty.")
        case .invalidVNCHost(let host):
            return MacRemoteConnectionsCopy.t("VNC 主机地址无效：\(host)", "Invalid VNC host address: \(host)")
        case .invalidVNCPort(let port):
            return MacRemoteConnectionsCopy.t("VNC 端口无效：\(port)", "Invalid VNC port: \(port)")
        case .noPreviousConnection:
            return MacRemoteConnectionsCopy.t("此任务还没有连接过远端。", "This task has not connected to a remote endpoint yet.")
        case .connectionAlreadyActive:
            return MacRemoteConnectionsCopy.t("连接仍在进行中；请先断开。", "A connection is still active; disconnect it first.")
        case .ownerRetired:
            return MacRemoteConnectionsCopy.t(
                "此任务的连接会话已结束，请重新打开。",
                "This task's connection session has ended. Reopen it."
            )
        }
    }
}

// MARK: - Session records (portable RemoteSessionRecord)

/// Durable state of one SSH/VNC connection, same vocabulary as the iPad
/// `remote_sessions` row so the coordinator's SQLite adapter can persist it
/// without translation.
public struct MacRemoteSessionRecord: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case sshTerminal
        case vnc
    }

    public enum State: String, Sendable, Codable, Hashable {
        case connecting
        case connected
        case suspended
        case disconnected
        case unknown
    }

    public var id: UUID
    public var hostID: UUID
    public var kind: Kind
    public var state: State
    public var remoteSessionRef: String?
    public var lastHeartbeatAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        hostID: UUID,
        kind: Kind,
        state: State,
        remoteSessionRef: String? = nil,
        lastHeartbeatAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.hostID = hostID
        self.kind = kind
        self.state = state
        self.remoteSessionRef = remoteSessionRef
        self.lastHeartbeatAt = lastHeartbeatAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Persistence seams (coordinator injects the SQLite runtime)

/// Host-metadata persistence boundary. Same contract shape as the iPad
/// `RemoteHostStore` profile reads/writes; the coordinator owns the SQLite
/// adapter and injects it at integration time.
public protocol MacRemoteHostStore: Sendable {
    func hosts() async throws -> [MacRemoteHostProfile]
    func saveHost(_ host: MacRemoteHostProfile) async throws
    func deleteHost(id: UUID) async throws
}

/// Durable live-session registry. Same contract shape as the iPad
/// `RemoteSessionRegistry`.
public protocol MacRemoteSessionRegistry: Sendable {
    func upsert(_ session: MacRemoteSessionRecord) async throws
    func session(id: UUID) async throws -> MacRemoteSessionRecord?
    func sessions(hostID: UUID) async throws -> [MacRemoteSessionRecord]
    func activeSessions() async throws -> [MacRemoteSessionRecord]
    func updateState(id: UUID, state: MacRemoteSessionRecord.State, lastHeartbeatAt: Date?) async throws
    func removeSession(id: UUID) async throws
}

/// Default host store used until the coordinator injects the SQLite-backed
/// adapter. Hosts live in memory only; restarting the workbench starts with
/// an empty catalog.
public actor MacInMemoryRemoteHostStore: MacRemoteHostStore {
    public private(set) var storedHosts: [MacRemoteHostProfile] = []

    public init() {}

    public func hosts() async throws -> [MacRemoteHostProfile] {
        storedHosts.sorted {
            ($0.displayName, $0.id.uuidString) < ($1.displayName, $1.id.uuidString)
        }
    }

    public func saveHost(_ host: MacRemoteHostProfile) async throws {
        let validated = try host.validated()
        storedHosts.removeAll { $0.id == validated.id }
        storedHosts.append(validated)
    }

    public func deleteHost(id: UUID) async throws {
        storedHosts.removeAll { $0.id == id }
    }
}

/// Default registry used until the coordinator injects the SQLite-backed
/// adapter.
public actor MacInMemoryRemoteSessionRegistry: MacRemoteSessionRegistry {
    public private(set) var records: [MacRemoteSessionRecord] = []

    public init() {}

    public func upsert(_ session: MacRemoteSessionRecord) async throws {
        records.removeAll { $0.id == session.id }
        var stored = session
        stored.updatedAt = Date()
        records.append(stored)
    }

    public func session(id: UUID) async throws -> MacRemoteSessionRecord? {
        records.first(where: { $0.id == id })
    }

    public func sessions(hostID: UUID) async throws -> [MacRemoteSessionRecord] {
        records.filter { $0.hostID == hostID }
            .sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }
    }

    public func activeSessions() async throws -> [MacRemoteSessionRecord] {
        records.filter {
            switch $0.state {
            case .connecting, .connected, .suspended: true
            case .disconnected, .unknown: false
            }
        }
    }

    public func updateState(id: UUID, state: MacRemoteSessionRecord.State, lastHeartbeatAt: Date?) async throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].state = state
        records[index].lastHeartbeatAt = lastHeartbeatAt
        records[index].updatedAt = Date()
    }

    public func removeSession(id: UUID) async throws {
        records.removeAll { $0.id == id }
    }
}

// MARK: - Catalog

/// Observable saved-host catalog for the workbench. Task-independent: the
/// same catalog is shared by every task's connection owner.
@MainActor
public final class MacRemoteConnectionsCatalog: ObservableObject {
    @Published public private(set) var hosts: [MacRemoteHostProfile] = []
    @Published public private(set) var loadError: String?

    private let store: any MacRemoteHostStore

    public init(store: any MacRemoteHostStore = MacInMemoryRemoteHostStore()) {
        self.store = store
    }

    public func host(id: UUID) -> MacRemoteHostProfile? {
        hosts.first(where: { $0.id == id })
    }

    public func reload() async {
        do {
            hosts = try await store.hosts()
            loadError = nil
        } catch {
            loadError = MacRemoteConnectionsCopy.t(
                "无法读取已保存的主机。",
                "Could not read the saved hosts."
            )
        }
    }

    @discardableResult
    public func addHost(_ profile: MacRemoteHostProfile) async throws -> MacRemoteHostProfile {
        let validated = try profile.validated()
        try await store.saveHost(validated)
        await reload()
        return validated
    }

    public func updateHost(_ profile: MacRemoteHostProfile) async throws {
        try await store.saveHost(try profile.validated())
        await reload()
    }

    public func deleteHost(id: UUID) async throws {
        try await store.deleteHost(id: id)
        await reload()
    }
}

// MARK: - VNC admission lease

/// Per-task VNC admission lease. The coordinator injects the existing
/// Workbench OTA activity ledger through this seam so an open VNC session
/// participates in App lifecycle exactly like an open terminal.
///
/// Contract:
/// - `acquire` runs on the MainActor before a connection opens and may
///   throw to refuse (OTA in progress, workbench closing). Nothing launches
///   when it throws.
/// - `release` runs on the MainActor exactly once per successful acquire:
///   when the transport settles (`.closed`/`.failed`), when the start
///   throws, or when the owner is drained — never on a timeout.
public struct MacTaskRemoteVNCAdmission: Sendable {
    public var acquire: @MainActor (UUID) async throws -> Void
    public var release: @MainActor (UUID) async -> Void

    public init(
        acquire: @escaping @MainActor (UUID) async throws -> Void,
        release: @escaping @MainActor (UUID) async -> Void
    ) {
        self.acquire = acquire
        self.release = release
    }
}

// MARK: - Task connection owner

/// Owns the saved-endpoint connection state for exactly one task.
///
/// SSH is delegated to the task's existing ``MacTaskTerminalOwner`` so the
/// child PTY, the OTA/Bridge admission lease and the system OpenSSH host-key
/// prompts behave exactly like the hand-typed inspector path; the existing
/// terminal store remains the only thing that starts or stops that PTY.
/// VNC is owned here through a per-task ``MacVNCSessionOwner``; only the
/// user's explicit Connect press opens a connection and the password stays
/// in memory inside the VNC package.
@MainActor
public final class MacTaskRemoteConnectionsOwner: ObservableObject {

    /// Identity of the task these connections belong to.
    public let taskID: UUID

    /// The task's terminal owner; owns the SSH PTY and its lease.
    public let terminalOwner: MacTaskTerminalOwner

    /// The task's VNC session owner (one live VNC session per task).
    public let vncOwner: MacVNCSessionOwner

    /// Saved-host catalog used to resolve endpoint IDs at connect time.
    public let catalog: MacRemoteConnectionsCatalog

    /// Live SSH terminal state, mirrored from the terminal owner's session.
    @Published public private(set) var sshState: MacTerminalSessionState = .idle
    /// Saved host behind the current or most recent SSH connection.
    @Published public private(set) var activeSSHHostID: UUID?
    /// Saved host the task last connected to (reconnect target).
    @Published public private(set) var lastSSHHostID: UUID?
    /// Saved VNC endpoint behind the current or most recent VNC connection.
    @Published public private(set) var activeVNCEndpointID: UUID?
    /// Saved VNC endpoint the task last connected to (reconnect target).
    @Published public private(set) var lastVNCEndpointID: UUID?

    /// Optional per-task VNC admission lease injected by integration (the
    /// Workbench OTA activity ledger).
    public var vncAdmission: MacTaskRemoteVNCAdmission?

    private let registry: (any MacRemoteSessionRegistry)?
    private var cancellables = Set<AnyCancellable>()
    private var sshRecordID: UUID?
    private var vncRecordID: UUID?
    private var vncLeaseHeld = false
    private var isRetiring = false

    /// Fixture-only launch seams. The defaults run the real owner methods
    /// (interactive OpenSSH in the terminal / RoyalVNCKit owner); tests
    /// substitute deterministic fakes here. Never set from production code.
    var sshLaunchOverride: ((MacSSHHost) async throws -> Void)?
    var vncLaunchOverride: ((MacVNCConfiguration) throws -> Void)?

    public init(
        taskID: UUID,
        terminalOwner: MacTaskTerminalOwner,
        catalog: MacRemoteConnectionsCatalog,
        vncOwner: MacVNCSessionOwner = MacVNCSessionOwner(),
        registry: (any MacRemoteSessionRegistry)? = nil
    ) {
        self.taskID = taskID
        self.terminalOwner = terminalOwner
        self.catalog = catalog
        self.vncOwner = vncOwner
        self.registry = registry

        terminalOwner.sshSession.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.sshStateDidChange(state)
            }
            .store(in: &cancellables)
        vncOwner.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.vncStateDidChange(state)
            }
            .store(in: &cancellables)
    }

    // No custom deinit: AnyCancellable cancels its subscription on release,
    // the sinks hold weak references, and the sessions themselves are owned
    // by the terminal owner / VNC owner, which outlive this glue object.

    /// True while either connection slot is live; the store keeps owners
    /// alive until launches and stops have settled.
    public var hasLiveConnection: Bool {
        if case .running = sshState { return true }
        if vncOwner.state.isActive { return true }
        return false
    }

    // MARK: SSH

    /// Connects this task's SSH terminal to a saved host. Explicit user
    /// action only; runs through the terminal owner's admission lease, and
    /// the destination is converted with the same strict validation as the
    /// hand-typed path.
    public func connectSSH(hostID: UUID) async throws {
        guard !isRetiring else { throw MacRemoteConnectionsError.ownerRetired }
        guard let profile = catalog.host(id: hostID) else {
            throw MacRemoteConnectionsError.hostNotFound(hostID)
        }
        let host = try profile.sshHost()
        let record = MacRemoteSessionRecord(hostID: hostID, kind: .sshTerminal, state: .connecting)
        try await registry?.upsert(record)
        sshRecordID = record.id
        do {
            if let override = sshLaunchOverride {
                try await override(host)
            } else {
                try await terminalOwner.startSSH(host)
            }
        } catch {
            enqueueRegistryWrite { try? await $0.updateState(id: record.id, state: .unknown, lastHeartbeatAt: nil) }
            sshRecordID = nil
            throw error
        }
        activeSSHHostID = hostID
        lastSSHHostID = hostID
    }

    /// Explicit user disconnect of the SSH terminal.
    @discardableResult
    public func disconnectSSH(timeout: Duration = .seconds(3)) async -> Bool {
        await terminalOwner.stopSSH(timeout: timeout)
    }

    /// Reconnects the host this task last used. Throws when a connection is
    /// still live or no previous connection exists.
    public func reconnectSSH() async throws {
        guard sshState != .running else { throw MacRemoteConnectionsError.connectionAlreadyActive }
        guard let hostID = lastSSHHostID ?? activeSSHHostID else {
            throw MacRemoteConnectionsError.noPreviousConnection
        }
        try await connectSSH(hostID: hostID)
    }

    // MARK: VNC

    /// Opens this task's VNC session to a saved endpoint. Explicit user
    /// action only; the password argument lives in memory and is dropped by
    /// the owner on close.
    public func connectVNC(endpointID: UUID, password: String?) async throws {
        guard !isRetiring else { throw MacRemoteConnectionsError.ownerRetired }
        guard !vncOwner.state.isActive else { throw MacRemoteConnectionsError.connectionAlreadyActive }
        let resolved = try resolveEndpoint(endpointID)
        let configuration = resolved.endpoint.configuration(password: password)
        // The fixture launch seam never produces transport settlement, so no
        // lease is paired for it; the real path always acquires before open.
        let leaseAcquired: Bool
        if vncLaunchOverride != nil {
            leaseAcquired = false
        } else {
            leaseAcquired = try await acquireVNCLease()
        }
        let record = MacRemoteSessionRecord(hostID: resolved.hostID, kind: .vnc, state: .connecting)
        upsertVNCRecord(record)
        do {
            if let override = vncLaunchOverride {
                try override(configuration)
            } else {
                try vncOwner.connect(using: configuration)
            }
        } catch {
            // Only release a lease this call actually acquired; a lease
            // already held by the live connection stays paired with it.
            if leaseAcquired { releaseVNCLease() }
            updateVNCRecordState(id: record.id, state: .unknown)
            vncRecordID = nil
            throw error
        }
        activeVNCEndpointID = endpointID
        lastVNCEndpointID = endpointID
    }

    /// Explicit user disconnect of the VNC session.
    public func disconnectVNC() {
        vncOwner.close()
    }

    /// Reconnects the VNC endpoint this task last used. The caller must
    /// supply the password again; a saved password never exists.
    public func reconnectVNC(password: String?) async throws {
        guard !isRetiring else { throw MacRemoteConnectionsError.ownerRetired }
        guard !vncOwner.state.isActive else { throw MacRemoteConnectionsError.connectionAlreadyActive }
        guard let endpointID = lastVNCEndpointID ?? activeVNCEndpointID else {
            throw MacRemoteConnectionsError.noPreviousConnection
        }
        try await connectVNC(endpointID: endpointID, password: password)
    }

    // MARK: Teardown

    /// Ends this task's ownership: refuses new starts, drains the VNC
    /// session, releases any held VNC lease, and forgets selection state.
    /// The SSH PTY is drained by the terminal store, which owns the child
    /// process and its lease.
    @discardableResult
    public func retire(timeout: Duration = .seconds(8)) async -> Bool {
        guard !isRetiring else { return false }
        isRetiring = true
        let drained = await vncOwner.drain()
        releaseVNCLease()
        activeSSHHostID = nil
        activeVNCEndpointID = nil
        return drained
    }

    // MARK: Private

    private struct ResolvedEndpoint {
        let hostID: UUID
        let endpoint: MacRemoteVNCEndpoint
    }

    private func resolveEndpoint(_ endpointID: UUID) throws -> ResolvedEndpoint {
        for host in catalog.hosts {
            if let endpoint = host.vncEndpoints.first(where: { $0.id == endpointID }) {
                return ResolvedEndpoint(hostID: host.id, endpoint: endpoint)
            }
        }
        throw MacRemoteConnectionsError.endpointNotFound(endpointID)
    }

    private func sshStateDidChange(_ state: MacTerminalSessionState) {
        sshState = state
        guard let recordID = sshRecordID else { return }
        switch state {
        case .running:
            // An interactive OpenSSH PTY running means the terminal process
            // started — the user may still be at the host-key/password
            // prompt. The durable record still mirrors the session live.
            enqueueRegistryWrite { try? await $0.updateState(id: recordID, state: .connected, lastHeartbeatAt: Date()) }
        case .stopping:
            break
        case .exited:
            enqueueRegistryWrite { try? await $0.updateState(id: recordID, state: .disconnected, lastHeartbeatAt: Date()) }
        case .idle:
            enqueueRegistryWrite { try? await $0.updateState(id: recordID, state: .disconnected, lastHeartbeatAt: Date()) }
        }
    }

    private func vncStateDidChange(_ state: MacVNCConnectionState) {
        guard let recordID = vncRecordID else { return }
        switch state {
        case .connecting:
            break
        case .connected:
            enqueueRegistryWrite { try? await $0.updateState(id: recordID, state: .connected, lastHeartbeatAt: Date()) }
        case .closing:
            break
        case .closed, .failed:
            // Transport settled: the admission lease is paired with the
            // actual connection lifetime, not with any timeout.
            releaseVNCLease()
            enqueueRegistryWrite { try? await $0.updateState(id: recordID, state: .disconnected, lastHeartbeatAt: Date()) }
        case .idle:
            break
        }
    }

    /// Serializes durable state writes so transitions always land in order
    /// (connecting -> connected -> disconnected) no matter how fast the
    /// transport settles; a slow writer never inverts the final state.
    private func enqueueRegistryWrite(_ write: @escaping @Sendable (any MacRemoteSessionRegistry) async -> Void) {
        guard let registry else { return }
        let previous = registryChain
        registryChain = Task {
            await previous?.value
            await write(registry)
        }
    }
    private var registryChain: Task<Void, Never>?

    // MARK: VNC admission lease

    /// Returns true when this call acquired a new lease; false when a lease
    /// was already held (so the caller must not release it on failure).
    /// A refused acquire throws and nothing launches.
    @discardableResult
    private func acquireVNCLease() async throws -> Bool {
        guard !vncLeaseHeld else { return false }
        try await vncAdmission?.acquire(taskID)
        vncLeaseHeld = true
        return true
    }

    private func releaseVNCLease() {
        guard vncLeaseHeld else { return }
        vncLeaseHeld = false
        let admission = self.vncAdmission
        let taskID = self.taskID
        Task { @MainActor in
            await admission?.release(taskID)
        }
    }

    // Registry write helpers for the throwing VNC connect path, so it can
    // record state without becoming async. Writes ride the same ordered
    // chain; a failed write never blocks a connection.
    private func upsertVNCRecord(_ record: MacRemoteSessionRecord) {
        vncRecordID = record.id
        enqueueRegistryWrite { try? await $0.upsert(record) }
    }

    private func updateVNCRecordState(id: UUID, state: MacRemoteSessionRecord.State) {
        enqueueRegistryWrite { try? await $0.updateState(id: id, state: state, lastHeartbeatAt: nil) }
    }
}

// MARK: - Task connection store

/// Workbench-level registry of per-task connection owners, keyed by task ID
/// exactly like ``MacTaskTerminalStore``. Two tasks never share a connection
/// owner; owners survive navigation and are drained explicitly.
@MainActor
public final class MacTaskRemoteConnectionsStore {
    public enum StoreError: Error, Equatable, Sendable {
        case ownerMissing(UUID)

        public var message: String {
            switch self {
            case .ownerMissing(let id):
                return MacRemoteConnectionsCopy.t(
                    "任务 \(id.uuidString) 没有连接会话。",
                    "Task \(id.uuidString) has no connection session."
                )
            }
        }
    }

    private var owners: [UUID: MacTaskRemoteConnectionsOwner] = [:]

    public init() {}

    public var activeTaskIDs: [UUID] { Array(owners.keys) }

    /// Returns the existing owner for `taskID`, or creates one bound to the
    /// task's terminal owner and the shared catalog.
    public func owner(
        taskID: UUID,
        terminalOwner: MacTaskTerminalOwner,
        catalog: MacRemoteConnectionsCatalog,
        vncOwner: MacVNCSessionOwner = MacVNCSessionOwner(),
        registry: (any MacRemoteSessionRegistry)? = nil
    ) -> MacTaskRemoteConnectionsOwner {
        if let existing = owners[taskID] { return existing }
        let owner = MacTaskRemoteConnectionsOwner(
            taskID: taskID,
            terminalOwner: terminalOwner,
            catalog: catalog,
            vncOwner: vncOwner,
            registry: registry
        )
        owners[taskID] = owner
        return owner
    }

    public func owner(for taskID: UUID) -> MacTaskRemoteConnectionsOwner? {
        owners[taskID]
    }

    /// Drains and forgets the owner for a finished task. Returns true only
    /// after the VNC session has fully settled; a timed-out owner is kept.
    @discardableResult
    public func stopAndRemove(taskID: UUID) async -> Bool {
        guard let owner = owners[taskID] else { return true }
        guard await owner.retire() else { return false }
        owners[taskID] = nil
        return true
    }

    /// Drains every owned connection. Timed-out owners stay in the store.
    @discardableResult
    public func stopAll() async -> Bool {
        var allDrained = true
        for (id, owner) in owners {
            if await owner.retire() {
                owners[id] = nil
            } else {
                allDrained = false
            }
        }
        return allDrained
    }
}

// MARK: - Copy

enum MacRemoteConnectionsCopy {
    static func t(_ zh: String, _ en: String) -> String {
        Locale.current.language.languageCode?.identifier == "zh" ? zh : en
    }
}
