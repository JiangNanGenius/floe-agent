// SPDX-License-Identifier: MPL-2.0
//
// G04-R1 NETWORK WORKSPACE OWNER — the REAL retained network source owner
// for WebDAV and SMB workspace mounts (lane job-20000d7c450d4353).
//
// This is the wiring the delivered archive/network mirror documented as the
// required composition: the adapters in `FloeWorkspace/NetworkWorkspaceMount
// .swift` are the ONLY protocol authority (PROPFIND/MKCOL/PUT+If-Match/MOVE/
// DELETE verbs, ETag propagation, status mapping, read-only fail-closed,
// SMB2-only dialects via pinned SMBClient, the honest "SMB entries carry no
// entity tag" limitation). This owner supplies exactly what that module left
// as injectable seams:
//   * a retained `G04NetworkSession` (Main's exact-origin / no-userinfo /
//     no-downgrade / method-preserving redirect delegate over the audited
//     system-CA FoundationNetworking surface) per WebDAV mount, injected at
//     adapter construction through the additive `adapterFactory` seam of
//     `NetworkWorkspaceMountRegistry` — never `URLSession.shared`, no second
//     transport, no permissive trust, no certificate fallback;
//   * durable mount CONFIG records (metadata-only JSON under the accepted
//     owned root; `credentialRef` is an opaque vault UUID. Endpoint
//     projections drop userinfo/query/fragment; secrets never enter config,
//     replies, labels or logs);
//   * the credential path through `G04NetworkCredentialLease` over the ONE
//     approved vault. Every adapter request re-consults the LIVE durable
//     config for the mount that currently names the requested ref (no
//     cached grant truth — revoked/edited/forgotten refs refuse on the very
//     next hop);
//   * import/export/save/reconcile ladders over the ORIGINAL journal-47
//     authority via `G04WorkspaceSourceCoordinator`'s file-backed overloads:
//     provider bytes STREAMED into native staging under the original 1 GiB
//     per-entry provider-copy budget (64 KiB Range pages — not the 4 MiB
//     editable-document ceiling), hashed BY NATIVE and verified from disk,
//     committed through the same `importUserFile` / `prepare -> ONE-TIME
//     claim -> write -> read-back -> settle` ladder with binding-revision
//     CAS. The durable `claimRecovery` row IS the single destructive permit
//     for the network write (mirrors the gateway receipt-permit exactly:
//     claimed once, replayed never); there is no Kotlin parallel journal and
//     no fabricated completion anywhere.
//
// Lifecycle: every mutating operation holds a REAL `.conversation`
// owned-work lease across the actual provider IO and releases it only after
// that IO settles — cancel is a REQUEST, and an outstanding hop keeps its
// token attached (the delivered mailbox/gateway rule). Operations are
// service-owned detached Tasks, never view lifetime. Retirement fences
// admissions and requests cancellation, but the leases detach through each
// operation's own settlement, so RB1's drain still proves real IO end.
import Foundation
import Crypto
import FloeCore
import FloePersistence
import FloeTools
import FloeWorkspace
import FloeAndroidWorkspaceTools

// MARK: - Retained session ownership

/// Opaque holder for the WebDAV sessions the adapter factory mints, so the
/// synchronous registry factory closure can hand ownership to the actor-side
/// lifecycle (disconnect/retire invalidate through this box).
final class G04NetworkSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [UUID: G04NetworkSession] = [:]

    /// Stores and returns any previously recorded session (the caller
    /// invalidates the superseded one — same-origin rebuild only).
    func record(mountID: UUID, session: G04NetworkSession) -> G04NetworkSession? {
        lock.lock(); defer { lock.unlock() }
        let previous = sessions[mountID]
        sessions[mountID] = session
        return previous
    }

    func take(mountID: UUID) -> G04NetworkSession? {
        lock.lock(); defer { lock.unlock() }
        return sessions.removeValue(forKey: mountID)
    }

    func takeAll() -> [G04NetworkSession] {
        lock.lock(); defer { lock.unlock() }
        let all = Array(sessions.values)
        sessions.removeAll()
        return all
    }
}

// MARK: - Trusted adapter construction

/// Produces the adapter (+ retained WebDAV session) for one mount over the
/// QUALIFIED transport surface. Component tests inject a synthetic provider
/// here; the production provider is exactly the delivered adapter types.
struct G04NetworkAdapterFactory: Sendable {
    typealias Producer = @Sendable (
        _ mount: NetworkWorkspaceMount,
        _ credentialResolver: @escaping NetworkCredentialResolver,
        _ sessions: G04NetworkSessionBox
    ) throws -> any WorkspaceMountAdapter

    let produce: Producer

    static let production = G04NetworkAdapterFactory(produce: { mount, resolver, sessions in
        switch mount.transport {
        case .webDAV:
            // The delivered G04NetworkSession is the ONLY qualified
            // transport surface: exact-origin redirect policy, ephemeral
            // config (no cache, no cookie store, no credential store),
            // system-CA verification untouched. The owner RETAINS the
            // session; disconnect and retirement invalidate it — never
            // while a hop it owns is unsettled (the operation keeps its own
            // cancellation discipline first; session cancel then forces
            // outstanding admission down honestly).
            let session = try G04NetworkSession(endpoint: mount.endpoint)
            if let superseded = sessions.record(mountID: mount.id, session: session) {
                superseded.cancel()   // rebuild path: old admission already replaced
            }
            return try WebDAVWorkspaceMountAdapter(mount: mount, credentialResolver: resolver,
                                                   session: session.session)
        case .smb:
            return try SMBWorkspaceMountAdapter(mount: mount, credentialResolver: resolver)
        }
    })
}

// MARK: - Public value surface (metadata-only views)

public struct G04NetworkMountDraft: Sendable, Equatable {
    public var mountID: UUID?                 // nil = create
    public var name: String
    public var transport: NetworkWorkspaceProtocol
    public var endpoint: URL
    public var rootPath: String
    public var username: String
    public var readOnly: Bool
    /// Credential ticket grammar (opaque Int64; a consumed ticket never
    /// yields bytes to any caller again):
    /// `> 0` staged secret (capture on create / rotate on update),
    /// `0` keep existing / none,
    /// `-1` clear the existing credential (anonymous) — update only.
    public var credentialTicket: Int64

    public init(mountID: UUID? = nil, name: String, transport: NetworkWorkspaceProtocol,
                endpoint: URL, rootPath: String, username: String, readOnly: Bool,
                credentialTicket: Int64) {
        self.mountID = mountID; self.name = name; self.transport = transport
        self.endpoint = endpoint; self.rootPath = rootPath; self.username = username
        self.readOnly = readOnly; self.credentialTicket = credentialTicket
    }
}

public struct G04NetworkMountView: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let transport: String
    public let endpoint: String          // REDACTED: scheme://host[:port]/path only
    public let rootPath: String
    public let username: String
    public let readOnly: Bool
    public let status: String
}

public struct G04NetworkBrowseEntry: Sendable, Equatable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let bytes: Int64
    public let modifiedAt: Date?
    public let entityTag: String?
}

public struct G04NetworkOperationView: Sendable, Equatable {
    public enum State: String, Sendable {
        case running, cancelRequested, completed, failed, cancelled
    }
    public let id: UInt64
    public let kind: String
    public let mountID: String?
    public let remotePath: String
    public let logicalPath: String
    public let state: State
    public let phase: String
    /// Actual physically transferred bytes (streamed pages, including fully
    /// downloaded-but-refused entries).
    public let bytesDone: Int
    /// Wire contract preserved: Int, serialized directly to the host's
    /// Long. The committed aggregate total is published ONLY when honestly
    /// knowable — invariant `totalBytes == 0 || totalBytes >= bytesDone`.
    /// 0 is the delivered UNKNOWN sentinel (Kotlin treats `> 0` as known);
    /// a total that cannot be trusted is 0, never a fabricated or clamped
    /// count and never below the actual bytesDone.
    public let totalBytes: Int
    public let entriesDone: Int
    public let entriesFailed: Int
    public let failures: [G04NetworkEntryFailure]
    public let errorCode: String?
    public let errorRetryable: Bool
    public let result: [String: String]
}

public struct G04NetworkEntryFailure: Sendable, Equatable {
    public let path: String
    public let code: String
}

// MARK: - Errors

public enum G04NetworkWorkspaceError: Error, Sendable, Equatable {
    case retired
    case identityRefused
    case mountUnknown
    case configurationRefused(String)     // closed token, never the URL
    case remotePathRefused(String)
    case credentialRefused(String)
    case provider(code: String, retryable: Bool)
    case tooLarge(limit: Int)
    case transitionRefused(String)
    case operationUnknown
    case diskFull
}

// MARK: - Live-operation state box (NSLock class; delivered host discipline)

final class G04NetworkOperationBox: @unchecked Sendable {
    private struct Mutable {
        var state: G04NetworkOperationView.State = .running
        var phase = "queued"
        var bytesDone = 0
        var totalBytes = 0
        var entriesDone = 0
        var entriesFailed = 0
        var failures: [G04NetworkEntryFailure] = []
        var errorCode: String?
        var errorRetryable = false
        var result: [String: String] = [:]
        var staging: [URL] = []
        var settled = false
    }

    let id: UInt64
    let kind: String
    let taskID: UUID
    let workspaceID: UUID
    let mountID: UUID?
    let sourceID: UUID?
    let recoveryID: UUID?
    let remotePath: String
    let logicalPath: String
    /// The ONE cancellation authority for this operation's physical IO. It is
    /// the SAME token the owned-work lease hands the coordinator
    /// (`G04WorkspaceOwnedOperation.cancellation`) and that the stream/walk/
    /// commit loops actually check — injected at construction. A private
    /// per-box token would make `requestCancel()` fire a token nobody reads,
    /// so a mid-stream cancel would still stream, commit and journal.
    let cancellation: CancellationToken

    private let lock = NSLock()
    private var m = Mutable()

    init(id: UInt64, kind: String, taskID: UUID, workspaceID: UUID, mountID: UUID?,
         sourceID: UUID?, recoveryID: UUID?, remotePath: String, logicalPath: String,
         cancellation: CancellationToken) {
        self.id = id; self.kind = kind; self.taskID = taskID; self.workspaceID = workspaceID
        self.mountID = mountID; self.sourceID = sourceID; self.recoveryID = recoveryID
        self.remotePath = remotePath; self.logicalPath = logicalPath
        self.cancellation = cancellation
    }

    var isTerminal: Bool { lock.lock(); defer { lock.unlock() }; return m.settled }

    func setPhase(_ phase: String) {
        lock.lock(); if !m.settled { m.phase = phase }; lock.unlock()
    }

    /// Physical progress under the lock: `count` is actually transferred
    /// bytes; `total` is the caller's COMMITTED aggregate restatement. A
    /// supplied total is kept only when it is >= the actual done bytes;
    /// otherwise (or when a known total is grown past) the total falls back
    /// to the delivered 0 UNKNOWN sentinel. Invariant: a published total is
    /// never a known value below `bytesDone` — honest progress, no
    /// fabrication, no clamping, and `bytesDone`/`result.bytes` stay
    /// independently exact.
    func addBytes(_ count: Int, total: Int?) {
        lock.lock()
        if !m.settled {
            m.bytesDone += count
            if let total, total >= m.bytesDone {
                m.totalBytes = total
            } else if m.totalBytes != 0, m.totalBytes < m.bytesDone {
                m.totalBytes = 0
            }
        }
        lock.unlock()
    }

    func entryDone() { lock.lock(); if !m.settled { m.entriesDone += 1 }; lock.unlock() }

    func entryFailed(path: String, code: String) {
        lock.lock()
        if !m.settled {
            m.entriesFailed += 1
            if m.failures.count < 64 { m.failures.append(G04NetworkEntryFailure(path: path, code: code)) }
        }
        lock.unlock()
    }

    func setResult(_ fields: [String: String]) {
        lock.lock(); if !m.settled { m.result = fields }; lock.unlock()
    }

    func addStaging(_ url: URL) { lock.lock(); m.staging.append(url); lock.unlock() }

    func drainStaging() -> [URL] {
        lock.lock(); defer { m.staging.removeAll(); lock.unlock() }
        return m.staging
    }

    /// Cancel is a REQUEST: a running op moves to `cancelRequested` and its
    /// token fires; a box that has NOT physically settled never claims
    /// `cancelled` by itself.
    func requestCancel() {
        lock.lock()
        let live = !m.settled
        if live, m.state == .running { m.state = .cancelRequested }
        lock.unlock()
        if live { cancellation.cancel() }
    }

    func settleFailed(phase: String, code: String, retryable: Bool, result: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        guard !m.settled else { return }
        m.settled = true
        m.state = code == "cancelled" ? .cancelled : .failed
        m.phase = phase
        m.errorCode = code
        m.errorRetryable = retryable
        if !result.isEmpty { m.result = result }
    }

    func settleCompleted(result: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        guard !m.settled else { return }
        m.settled = true
        m.state = .completed
        m.phase = "done"
        m.result = result
    }

    func snapshot() -> G04NetworkOperationView {
        lock.lock(); defer { lock.unlock() }
        return G04NetworkOperationView(
            id: id, kind: kind, mountID: mountID?.uuidString,
            remotePath: remotePath, logicalPath: logicalPath,
            state: m.state, phase: m.phase,
            bytesDone: m.bytesDone, totalBytes: m.totalBytes,
            entriesDone: m.entriesDone, entriesFailed: m.entriesFailed,
            failures: m.failures, errorCode: m.errorCode, errorRetryable: m.errorRetryable,
            result: m.result)
    }
}

// MARK: - The owner

public actor G04NetworkWorkspace {
    /// Page/walk ceilings. Directory walks stay bounded PER ENTRY by the
    /// ORIGINAL 1 GiB provider-copy budget; the walk itself and the
    /// aggregate streamed bytes add the second discipline (a partial failure
    /// keeps every committed entry durable — never an all-or-nothing lie).
    public static let maximumBrowseEntries = 200
    public static let maximumWalkEntries = 2_048
    public static let maximumOperationAggregateBytes = 4 * Int(Int64(1) << 30)
    public static let streamChunkBytes = 65_536

    public enum ImportConflict: String, Sendable { case refuse, copy }

    public let epoch: UInt64
    private let cluster: G02OwnedStoreCluster
    private let coordinator: G04WorkspaceSourceCoordinator
    private let store: AndroidWorkspaceSourceStore
    private let lease: G04NetworkCredentialLease
    private let adapterFactory: G04NetworkAdapterFactory
    private let sessions = G04NetworkSessionBox()

    /// workspaceID -> durable config records (loaded on demand; the JSON
    /// file is the durable authority across generations).
    private var configs: [UUID: [NetworkWorkspaceMount]] = [:]
    /// workspaceID -> the root URL the shared registry entry is keyed under.
    private var registeredRoots: [UUID: URL] = [:]
    /// mountID -> last ACTUAL verdict projection (never persisted as truth).
    private var statuses: [UUID: NetworkWorkspaceMountStatus] = [:]
    private var operations: [UInt64: G04NetworkOperationBox] = [:]
    private var operationCounter: UInt64 = 0
    private var retired = false

    /// Same-module component-test seams (the accepted source-host pattern):
    /// staging root + a per-phase async hook to hit the
    /// cancel-vs-physical-settlement windows deterministically.
    internal var stagingRootOverrideForTesting: URL?
    internal var ioHookForTesting: (@Sendable (_ phase: String) async -> Void)?

    init(epoch: UInt64, cluster: G02OwnedStoreCluster,
         coordinator: G04WorkspaceSourceCoordinator,
         secrets: any G04NetworkSecretAuthority,
         adapterFactory: G04NetworkAdapterFactory = .production) {
        self.epoch = epoch
        self.cluster = cluster
        self.coordinator = coordinator
        self.store = AndroidWorkspaceSourceStore(database: cluster.database)
        self.lease = G04NetworkCredentialLease(epoch: epoch, authority: secrets)
        self.adapterFactory = adapterFactory
        Self.sweepStaleGenerationStaging(root: cluster.identity.root, epoch: epoch)
    }

    var stats: (operations: Int, mounts: Int, registered: Int) {
        (operations.count, statuses.count, registeredRoots.count)
    }

    // MARK: admission (exact identity, re-validated before AND after awaits)

    private var generationIsLive: Bool {
        !retired && epoch == G02NativeRootEpoch.readback()
            && G02RuntimeComposition.shared.installedComposition?.epoch == epoch
            && RunDomainFacade.current(epoch: epoch) != nil
    }

    private func requireOrdinary(taskID: UUID, workspaceID: UUID) async throws {
        guard generationIsLive else { throw G04NetworkWorkspaceError.retired }
        guard let conversation = try await cluster.conversationStore.conversation(id: taskID),
              conversation.purpose == .ordinary else {
            throw G04NetworkWorkspaceError.identityRefused
        }
        guard try await cluster.workspaceStore.workspaceID(conversationID: taskID) == workspaceID,
              try await cluster.workspaceStore.workspace(id: workspaceID) != nil else {
            throw G04NetworkWorkspaceError.identityRefused
        }
        guard generationIsLive else { throw G04NetworkWorkspaceError.retired }
    }

    private func beginLease(taskID: UUID) async -> G04WorkspaceOwnedOperation? {
        guard let (domain, _) = RunDomainFacade.current(epoch: epoch) else { return nil }
        return await domain.beginG04WorkspaceOperation(conversationID: taskID, expectedEpoch: epoch)
    }

    private func endLease(_ operation: G04WorkspaceOwnedOperation) async {
        guard let (domain, _) = RunDomainFacade.current(epoch: epoch) else { return }
        await domain.endG04WorkspaceOperation(operation)
    }

    // MARK: durable mount config (metadata-only JSON; the delivered iOS
    // WorkspaceCenter NetworkWorkspaceMounts persistence shape)

    private func configURL(workspaceID: UUID) -> URL {
        URL(fileURLWithPath: cluster.identity.root.path, isDirectory: true)
            .appendingPathComponent("NetworkWorkspaceMounts", isDirectory: true)
            .appendingPathComponent("\(workspaceID.uuidString).json")
    }

    private func loadConfig(workspaceID: UUID) throws -> [NetworkWorkspaceMount] {
        if let cached = configs[workspaceID] { return cached }
        let url = configURL(workspaceID: workspaceID)
        guard let data = try? Data(contentsOf: url) else {
            configs[workspaceID] = []
            return []
        }
        let decoded = (try? JSONDecoder().decode([NetworkWorkspaceMount].self, from: data)) ?? []
        configs[workspaceID] = decoded
        return decoded
    }

    private func saveConfig(workspaceID: UUID, _ mounts: [NetworkWorkspaceMount]) throws {
        let url = configURL(workspaceID: workspaceID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(mounts).write(to: url, options: .atomic)
        configs[workspaceID] = mounts
    }

    // MARK: grammar

    private static func validateEndpoint(_ url: URL, transport: NetworkWorkspaceProtocol) throws {
        switch transport {
        case .webDAV:
            // The delivered origin type is the grammar authority: http/
            // https, host present, NO userinfo, effective port only.
            guard (try? G04NetworkOrigin(url)) != nil else {
                throw G04NetworkWorkspaceError.configurationRefused("endpoint")
            }
        case .smb:
            guard url.scheme?.lowercased() == "smb", url.host != nil,
                  url.user == nil, url.password == nil,
                  !(url.path.split(separator: "/").first.map(String.init) ?? "").isEmpty else {
                throw G04NetworkWorkspaceError.configurationRefused("endpoint")
            }
        }
    }

    /// Mount-relative remote path canon. Absolute/backslash/dot-segment
    /// spellings refuse; "." components collapse; the result is what the
    /// delivered adapters receive (they apply their own rootPath prefix).
    static func canonicalRemotePath(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 4096, !text.contains("\\"), !text.contains("\0") else {
            throw G04NetworkWorkspaceError.remotePathRefused("shape")
        }
        let components = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for component in components where component == ".." {
            throw G04NetworkWorkspaceError.remotePathRefused("escape")
        }
        return components.joined(separator: "/")
    }

    static func validLogicalPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("\\"), !path.contains("\0"),
              path == (path as NSString).standardizingPath else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func uniqueName(preferred: String, existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        let base = preferred.isEmpty ? "Network" : preferred
        if !taken.contains(base.lowercased()) { return base }
        var index = 2
        while taken.contains("\(base) (\(index))".lowercased()) { index += 1 }
        return "\(base) (\(index))"
    }

    /// Distinct display/conflict name for a copy that must NOT overwrite:
    /// inserts ` (network copy)` / ` (network copy 2)` … before the
    /// extension (workspace logical path or remote path alike), derived
    /// PURELY lexically for ONE requested index.
    ///
    /// The previous derivation ran the RELATIVE lane path through
    /// `URL(fileURLWithPath:)` and probed `FileManager.fileExists` inside
    /// the loop. Foundation rebases a relative path onto the PROCESS
    /// working directory, so the returned candidate was ABSOLUTE — the
    /// SAME `validLogicalPath` guard (no `/` prefix) then deterministically
    /// refused every derived name with `logicalPathRefused`, and the
    /// existence probe could never see the workspace root anyway.
    /// Availability is therefore decided exclusively by the verified commit
    /// ladder at the call site (its `workingCopyExists` refusal lands
    /// BEFORE any mutation): scan-and-land keeps the original meaning —
    /// the first candidate the authority accepts wins, a taken candidate
    /// advances the index, and nothing is ever overwritten.
    static func conflictCopyName(_ path: String, index: Int) -> String {
        let directory: String
        let name: String
        if let lastSlash = path.lastIndex(of: "/") {
            directory = String(path[..<lastSlash])
            name = String(path[path.index(after: lastSlash)...])
        } else {
            directory = ""
            name = path
        }
        let base: String
        let ext: String
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            base = String(name[..<dot])
            ext = String(name[name.index(after: dot)...])
        } else {
            base = name
            ext = ""
        }
        let marker = index == 1 ? " (network copy)" : " (network copy \(index))"
        let candidateName = ext.isEmpty ? base + marker : base + marker + "." + ext
        return directory.isEmpty ? candidateName : directory + "/" + candidateName
    }

    // MARK: registry activation — the shared routes stay the ONE adapter set

    /// The credential resolver handed to the delivered adapters: every
    /// request re-reads the LIVE durable config for the mount that currently
    /// names this ref, then goes through the lease/vault. A removed/edited/
    /// revoked ref refuses on the next hop — no cached grant truth.
    private func registryCredentialResolver(workspaceID: UUID) -> NetworkCredentialResolver {
        let workspace = workspaceID
        return { [weak self] ref in
            guard let self else {
                throw NetworkWorkspaceError(code: .credentialMissing, stage: "lease",
                                            retryable: false,
                                            safeDetail: "The mount owner is gone.")
            }
            let liveRef = await self.liveCredentialRef(workspaceID: workspace, ref: ref)
            do {
                return try await self.lease.resolve(credentialRef: ref,
                                                    liveConfigCredentialRef: liveRef)
            } catch let error as G04NetworkSecretFailure {
                throw NetworkWorkspaceError(code: .credentialMissing, stage: "credentials",
                                            retryable: false,
                                            safeDetail: "credential.\(Self.secretToken(error))")
            } catch let error as NetworkWorkspaceError {
                throw error
            } catch {
                throw NetworkWorkspaceError(code: .credentialMissing, stage: "credentials",
                                            retryable: false,
                                            safeDetail: "The saved credential is unavailable on this device.")
            }
        }
    }

    private func liveCredentialRef(workspaceID: UUID, ref: UUID) -> UUID? {
        (try? loadConfig(workspaceID: workspaceID))?.first { $0.credentialRef == ref }?.credentialRef
    }

    private func registryAdapterFactory() -> NetworkWorkspaceMountRegistry.AdapterFactory {
        let factory = adapterFactory
        let box = sessions
        return { mount, resolver in
            try factory.produce(mount, resolver, box)
        }
    }

    private func activate(workspaceID: UUID, rootURL: URL) async {
        let mounts = (try? loadConfig(workspaceID: workspaceID)) ?? []
        await NetworkWorkspaceMountRegistry.shared.register(
            rootURL: rootURL, mounts: mounts,
            credentialResolver: registryCredentialResolver(workspaceID: workspaceID),
            adapterFactory: registryAdapterFactory())
        registeredRoots[workspaceID] = rootURL
    }

    private func resolvedRootURL(taskID: UUID, workspaceID: UUID) async throws -> URL {
        let owner = G04WorkspaceOwner(epoch: epoch, taskID: taskID, workspaceID: workspaceID)
        let service = try await G04LiveWorkspaceAccess.privateTaskService(owner,
                                                                          cancellation: CancellationToken())
        return service.guardResolver.rootURL
    }

    /// Adapter + mount for live IO. Routes through the SAME registry cache
    /// the delivered agent tools use, so browse/import/export/save and tool
    /// reads of `Network/<name>` share ONE session-qualified transport.
    private func route(taskID: UUID, workspaceID: UUID, mountID: UUID) async throws
        -> (NetworkWorkspaceMount, any WorkspaceMountAdapter, URL) {
        try await requireOrdinary(taskID: taskID, workspaceID: workspaceID)
        let mounts = try loadConfig(workspaceID: workspaceID)
        guard let mount = mounts.first(where: { $0.id == mountID }) else {
            throw G04NetworkWorkspaceError.mountUnknown
        }
        let rootURL = try await resolvedRootURL(taskID: taskID, workspaceID: workspaceID)
        if registeredRoots[workspaceID] != rootURL {
            await activate(workspaceID: workspaceID, rootURL: rootURL)
        }
        guard let route = try await NetworkWorkspaceMountRegistry.shared.route(
            rootURL: rootURL, virtualPath: mount.virtualRoot) else {
            throw G04NetworkWorkspaceError.mountUnknown
        }
        return (route.mount, route.adapter, rootURL)
    }

    // MARK: - Mount configuration surface

    public func mounts(taskID: UUID, workspaceID: UUID) async throws -> [G04NetworkMountView] {
        try await requireOrdinary(taskID: taskID, workspaceID: workspaceID)
        let mounts = try loadConfig(workspaceID: workspaceID)
        return mounts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { Self.view(of: $0, status: effectiveStatus(mount: $0)) }
    }

    private func effectiveStatus(mount: NetworkWorkspaceMount) -> NetworkWorkspaceMountStatus {
        let live = statuses[mount.id] ?? .disconnected
        if mount.readOnly, live == .connected { return .readOnly }
        return live
    }

    private static func view(of mount: NetworkWorkspaceMount,
                             status: NetworkWorkspaceMountStatus) -> G04NetworkMountView {
        G04NetworkMountView(id: mount.id, name: mount.name, transport: mount.transport.rawValue,
                            endpoint: G04NetworkSecretRedaction.endpoint(mount.endpoint),
                            rootPath: mount.rootPath, username: mount.username,
                            readOnly: mount.readOnly, status: status.rawValue)
    }

    /// Creates or edits a mount. CREATE runs the delivered iOS
    /// `addNetworkMount` rule — persist, activate, probe with an ACTUAL
    /// `list("")` — and probe failure rolls the config back AND revokes the
    /// credential captured for it (no orphaned secret, no half mount).
    /// EDIT probe failure restores the PREVIOUS durable record (a refused
    /// edit never half-applies), while the rotated credential (if any) is
    /// revoked with its vault receipt.
    public func addMount(taskID: UUID, workspaceID: UUID, draft: G04NetworkMountDraft) async throws
        -> G04NetworkMountView {
        try await requireOrdinary(taskID: taskID, workspaceID: workspaceID)
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validateEndpoint(draft.endpoint, transport: draft.transport)
        let normalizedRoot = draft.rootPath.isEmpty ? "" : try Self.canonicalRemotePath(draft.rootPath)
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)

        let previous = try loadConfig(workspaceID: workspaceID)
        let isCreate = draft.mountID == nil
        let existingIndex = draft.mountID.flatMap { id in previous.firstIndex { $0.id == id } }
        if !isCreate, existingIndex == nil { throw G04NetworkWorkspaceError.mountUnknown }
        if draft.credentialTicket == -1, isCreate {
            throw G04NetworkWorkspaceError.configurationRefused("ticket")
        }
        let others = previous.enumerated()
            .filter { $0.offset != existingIndex ?? -1 }
            .map { $0.element.name }
        let name = Self.uniqueName(preferred: trimmedName.isEmpty
            ? (draft.endpoint.host ?? "Network") : trimmedName, existing: others)

        var credentialRef: UUID? = isCreate ? nil : previous[existingIndex!].credentialRef
        var capturedNewRef: UUID?
        var staleOldRef: UUID?
        let label = G04NetworkSecretRedaction.safeMountLabel(name: name, transport: draft.transport,
                                                             endpoint: draft.endpoint)
        if draft.credentialTicket > 0 {
            // Rotation ordering (honest availability): the NEW secret is
            // captured first and the OLD one is revoked only after the new
            // configuration PROBED successfully. If the edit is refused,
            // the old credential (still referenced by the restored record)
            // remains intact and the new capture is revoked instead — a
            // failed edit never leaves the working mount without a secret.
            let fresh = UUID()
            do {
                _ = try await lease.capture(ticket: draft.credentialTicket, credentialRef: fresh,
                                            label: label, workspaceID: workspaceID)
            } catch {
                _ = await lease.abortStage(draft.credentialTicket)
                throw G04NetworkWorkspaceError.credentialRefused(Self.secretToken(error))
            }
            capturedNewRef = fresh
            staleOldRef = credentialRef
            credentialRef = fresh
        } else if draft.credentialTicket == -1 {
            // Explicit CLEAR: the new record is probed with NO secret. The
            // old ref is revoked only after that probe succeeds; on a
            // refused edit the restored record keeps naming the (still
            // live) old ref — no half-state either way.
            staleOldRef = credentialRef
            capturedNewRef = nil
            credentialRef = nil
        } else if draft.credentialTicket < -1 {
            _ = await lease.abortStage(draft.credentialTicket)
            throw G04NetworkWorkspaceError.configurationRefused("ticket")
        }

        let changedTransport = existingIndex.map { previous[$0].transport != draft.transport } ?? true
        let changedEndpoint = existingIndex.map {
            Self.endpointIdentity(previous[$0].endpoint) != Self.endpointIdentity(draft.endpoint)
        } ?? true
        let mount = NetworkWorkspaceMount(
            id: isCreate ? UUID() : previous[existingIndex!].id,
            workspaceID: workspaceID, name: name, transport: draft.transport,
            endpoint: draft.endpoint, rootPath: normalizedRoot, username: username,
            credentialRef: credentialRef, readOnly: draft.readOnly,
            createdAt: isCreate ? Date() : previous[existingIndex!].createdAt,
            updatedAt: Date())
        var next = previous
        if let index = existingIndex { next[index] = mount } else { next.append(mount) }
        do {
            try saveConfig(workspaceID: workspaceID, next)
        } catch {
            if let fresh = capturedNewRef { _ = try? await lease.revoke(credentialRef: fresh) }
            throw error
        }

        if changedTransport || changedEndpoint { await retireMountRuntime(mountID: mount.id) }

        let rootURL: URL
        do {
            rootURL = try await resolvedRootURL(taskID: taskID, workspaceID: workspaceID)
        } catch {
            await failConfig(workspaceID: workspaceID, previous: previous, mount: mount,
                             capturedNewRef: capturedNewRef)
            throw error
        }
        await activate(workspaceID: workspaceID, rootURL: rootURL)

        do {
            let status = try await probeAdmitted(taskID: taskID, workspaceID: workspaceID,
                                                 mountID: mount.id)
            // The new/kept configuration PROBED: retire the superseded old
            // credential now (typed vault receipt; durable-pending cleanup
            // stays the vault's own honest state, never a silent re-grant).
            if let stale = staleOldRef {
                _ = try? await lease.revoke(credentialRef: stale)
            }
            return Self.view(of: mount, status: status)
        } catch let error as G04NetworkWorkspaceError {
            if isCreate {
                await failConfig(workspaceID: workspaceID, previous: previous, mount: mount,
                                 capturedNewRef: capturedNewRef)
                await activate(workspaceID: workspaceID, rootURL: rootURL)
            } else {
                // Refused edit: restore the PREVIOUS durable record. Its old
                // credential was never revoked (rotation ordering above),
                // so the restored mount stays exactly as usable as before;
                // only the NEW capture is revoked.
                try? saveConfig(workspaceID: workspaceID, previous)
                if let fresh = capturedNewRef { _ = try? await lease.revoke(credentialRef: fresh) }
                if let root = registeredRoots[workspaceID] {
                    await NetworkWorkspaceMountRegistry.shared.register(
                        rootURL: root, mounts: previous,
                        credentialResolver: registryCredentialResolver(workspaceID: workspaceID),
                        adapterFactory: registryAdapterFactory())
                }
                statuses[mount.id] = .failed
            }
            throw error
        } catch {
            if isCreate {
                await failConfig(workspaceID: workspaceID, previous: previous, mount: mount,
                                 capturedNewRef: capturedNewRef)
            } else {
                try? saveConfig(workspaceID: workspaceID, previous)
                if let fresh = capturedNewRef { _ = try? await lease.revoke(credentialRef: fresh) }
            }
            throw error
        }
    }

    private func failConfig(workspaceID: UUID, previous: [NetworkWorkspaceMount],
                            mount: NetworkWorkspaceMount, capturedNewRef: UUID?) async {
        try? saveConfig(workspaceID: workspaceID, previous)
        if let ref = capturedNewRef {
            _ = try? await lease.revoke(credentialRef: ref)
        }
        await retireMountRuntime(mountID: mount.id)
    }

    /// Probe = one ACTUAL `list("")` through the qualified adapter. The
    /// status is a live verdict projection only; nothing persists a grant.
    public func probeMount(taskID: UUID, workspaceID: UUID, mountID: UUID) async throws
        -> NetworkWorkspaceMountStatus {
        try await requireOrdinary(taskID: taskID, workspaceID: workspaceID)
        return try await probeAdmitted(taskID: taskID, workspaceID: workspaceID, mountID: mountID)
    }

    private func probeAdmitted(taskID: UUID, workspaceID: UUID, mountID: UUID) async throws
        -> NetworkWorkspaceMountStatus {
        let (mount, adapter, _) = try await route(taskID: taskID, workspaceID: workspaceID,
                                                  mountID: mountID)
        do {
            _ = try await adapter.list(path: "")
            await ioHookForTesting?("probe")
            let status: NetworkWorkspaceMountStatus = mount.readOnly ? .readOnly : .connected
            statuses[mountID] = status
            return status
        } catch let error as NetworkWorkspaceError {
            statuses[mountID] = Self.status(for: error)
            throw G04NetworkWorkspaceError.provider(code: error.code.rawValue,
                                                    retryable: error.retryable)
        }
    }

    /// Disconnect: REQUEST cancellation of this mount's operations, wait a
    /// bounded honest window for physical settlement, then invalidate the
    /// retained session and drop the shared-registry adapter cache. Config
    /// STAYS; a reconnect requires an explicit probe (no cached truth). An
    /// unsettled hop's session is cancelled only after the window expires —
    /// the operation then errors through its own settlement path, and any
    /// open journal ladder stays honestly pending for reconcile.
    @discardableResult
    public func disconnectMount(taskID: UUID, workspaceID: UUID, mountID: UUID) async
        -> (cancelled: [UInt64], outstanding: [UInt64]) {
        let mounted = operations.values.filter { $0.mountID == mountID && !$0.isTerminal }
        var cancelled: [UInt64] = []
        for box in mounted { box.requestCancel(); cancelled.append(box.id) }
        var outstanding = mounted.map { $0.id }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let stillOpen = mounted.filter { !$0.isTerminal }.map { $0.id }
            outstanding = stillOpen
            if stillOpen.isEmpty { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await retireMountRuntime(mountID: mountID)
        statuses[mountID] = .disconnected
        if let next = try? loadConfig(workspaceID: workspaceID),
           next.contains(where: { $0.id == mountID }),
           let root = registeredRoots[workspaceID] {
            // Re-registering DROPS the shared registry's adapter cache for
            // this workspace: the disconnected adapter is gone, and the next
            // actual use rebuilds a fresh qualified session (explicit probe
            // required to show `connected` again).
            await NetworkWorkspaceMountRegistry.shared.register(
                rootURL: root, mounts: next,
                credentialResolver: registryCredentialResolver(workspaceID: workspaceID),
                adapterFactory: registryAdapterFactory())
        }
        return (cancelled, outstanding)
    }

    /// Remove: disconnect semantics + durable config deletion + optional
    /// credential revocation with the vault's typed receipt reported
    /// verbatim (`deleted` / `durablePending` / `refused`). A save ladder
    /// with an open journal permit refuses removal first — the receipt must
    /// keep its durable owner reference.
    public func removeMount(taskID: UUID, workspaceID: UUID, mountID: UUID,
                            forgetCredential: Bool) async throws
        -> (credential: String, outstanding: [UInt64]) {
        try await requireOrdinary(taskID: taskID, workspaceID: workspaceID)
        let previous = try loadConfig(workspaceID: workspaceID)
        guard let mount = previous.first(where: { $0.id == mountID }) else {
            throw G04NetworkWorkspaceError.mountUnknown
        }
        let ladderOpen = operations.values.contains {
            $0.mountID == mountID && !$0.isTerminal && $0.kind == "save"
        }
        guard !ladderOpen else { throw G04NetworkWorkspaceError.transitionRefused("saveOutstanding") }
        let lifecycle = await disconnectMount(taskID: taskID, workspaceID: workspaceID,
                                              mountID: mountID)
        var next = previous
        next.removeAll { $0.id == mountID }
        try saveConfig(workspaceID: workspaceID, next)
        statuses[mountID] = nil
        var credential = "kept"
        if forgetCredential, let ref = mount.credentialRef {
            do {
                credential = (try await lease.revoke(credentialRef: ref)).rawValue
            } catch {
                credential = "refused"
            }
        }
        return (credential, lifecycle.outstanding)
    }

    private func retireMountRuntime(mountID: UUID) {
        sessions.take(mountID: mountID)?.cancel()
    }

    // MARK: - Browse / stat (bounded, ACTUAL provider IO)

    public func browse(taskID: UUID, workspaceID: UUID, mountID: UUID, path: String) async throws
        -> (entries: [G04NetworkBrowseEntry], truncated: Bool) {
        let (mount, adapter, _) = try await route(taskID: taskID, workspaceID: workspaceID,
                                                  mountID: mountID)
        let remote = try Self.canonicalRemotePath(path)
        do {
            let listed = try await adapter.list(path: remote)
            await ioHookForTesting?("browse")
            statuses[mountID] = effectiveStatus(mount: mount)
            let truncated = listed.count > Self.maximumBrowseEntries
            let page = listed.prefix(Self.maximumBrowseEntries).map {
                G04NetworkBrowseEntry(name: $0.name, path: $0.path, isDirectory: $0.isDirectory,
                                      bytes: $0.byteCount, modifiedAt: $0.modifiedAt,
                                      entityTag: $0.entityTag)
            }
            return (Array(page), truncated)
        } catch let error as NetworkWorkspaceError {
            statuses[mountID] = Self.status(for: error)
            throw G04NetworkWorkspaceError.provider(code: error.code.rawValue,
                                                    retryable: error.retryable)
        }
    }

    public func stat(taskID: UUID, workspaceID: UUID, mountID: UUID, path: String) async throws
        -> NetworkWorkspaceFileMetadata {
        let (mount, adapter, _) = try await route(taskID: taskID, workspaceID: workspaceID,
                                                  mountID: mountID)
        let remote = try Self.canonicalRemotePath(path)
        do {
            let meta = try await adapter.metadata(path: remote)
            await ioHookForTesting?("stat")
            statuses[mountID] = effectiveStatus(mount: mount)
            return meta
        } catch let error as NetworkWorkspaceError {
            statuses[mountID] = Self.status(for: error)
            throw G04NetworkWorkspaceError.provider(code: error.code.rawValue,
                                                    retryable: error.retryable)
        }
    }

    // MARK: - Staging (this lane's own scratch under the accepted root)

    private func stagingDirectory(operationID: UInt64) throws -> URL {
        let root: URL
        if let override = stagingRootOverrideForTesting {
            root = override
        } else {
            root = URL(fileURLWithPath: cluster.identity.root.path, isDirectory: true)
                .appendingPathComponent("NetworkStaging", isDirectory: true)
                .appendingPathComponent(String(epoch), isDirectory: true)
        }
        switch WorkspaceNoFollow.kind(root.path) {
        case .directory: break
        case .missing:
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch { throw G04NetworkWorkspaceError.diskFull }
        default: throw G04NetworkWorkspaceError.configurationRefused("stagingRoot")
        }
        let directory = root.appendingPathComponent(String(operationID), isDirectory: true)
        switch WorkspaceNoFollow.kind(directory.path) {
        case .directory: break
        case .missing:
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            } catch { throw G04NetworkWorkspaceError.diskFull }
        default: throw G04NetworkWorkspaceError.configurationRefused("stagingRoot")
        }
        return directory
    }

    /// Sweep ONLY superseded generations' staging: journaled ladder rows
    /// reference identities (paths under `Source Recovery/…`), never these
    /// scratch files; the reconcile path re-streams from the live provider.
    private func sweepStaleGenerationStaging() {
        guard stagingRootOverrideForTesting == nil else { return }
        Self.sweepStaleGenerationStaging(root: cluster.identity.root, epoch: epoch)
    }

    /// Swift 6: actor `init` is nonisolated; a freshly constructed actor
    /// cannot hold a test override, so init runs this exact sweep (same
    /// parent, same epoch-exclusion rule) through the static helper.
    private nonisolated static func sweepStaleGenerationStaging(root: RuntimeStorageRoot, epoch: UInt64) {
        let parent = URL(fileURLWithPath: root.path, isDirectory: true)
            .appendingPathComponent("NetworkStaging", isDirectory: true)
        guard WorkspaceNoFollow.kind(parent.path) == .directory else { return }
        let children = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in children where name != String(epoch) && !name.isEmpty
            && name.allSatisfy({ $0.isNumber }) {
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(name, isDirectory: true))
        }
    }

    // MARK: - Operation registry

    public func operation(_ ticket: UInt64) -> G04NetworkOperationView? {
        operations[ticket]?.snapshot()
    }

    public func operationList(workspaceID: UUID) -> [G04NetworkOperationView] {
        operations.values.filter { $0.workspaceID == workspaceID }
            .map { $0.snapshot() }
            .sorted { $0.id < $1.id }
    }

    @discardableResult
    public func cancelOperation(_ ticket: UInt64) -> Bool {
        guard let box = operations[ticket], !box.isTerminal else { return false }
        box.requestCancel()
        return true
    }

    /// Only terminal operations may be closed.
    @discardableResult
    public func closeOperation(_ ticket: UInt64) -> Bool {
        guard let box = operations[ticket], box.isTerminal else { return false }
        operations.removeValue(forKey: ticket)
        return true
    }

    /// Post-settlement cleanup: end the REAL owned-work lease ONLY after the
    /// operation's IO actually settled; delete this lane's scratch except
    /// while a journal permit is open (`keepScratch`), where the replacement
    /// bytes stay for the in-process reconcile the pending row requires.
    private func settle(_ box: G04NetworkOperationBox, _ operation: G04WorkspaceOwnedOperation,
                        keepScratch: Bool) async {
        await endLease(operation)
        if !keepScratch {
            for url in box.drainStaging() { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: - Streaming helpers

    /// Streams one full remote file body (or a window) into `file` with the
    /// incremental native digest, cancellation between 64 KiB Range pages,
    /// and the free-space reserve discipline of the original file service.
    /// A short window (server ignoring/clamping Range) is a typed protocol
    /// failure — PARTIAL bodies are never committed anywhere.
    static func streamProviderInto(_ adapter: any WorkspaceMountAdapter, remote: String,
                                   file: URL, size: Int, totalBudgetRemaining: Int,
                                   cancellation: CancellationToken,
                                   hook: (@Sendable (String) async -> Void)?,
                                   progress: (@Sendable (Int) -> Void)? = nil) async throws
        -> String {
        guard size > 0 else {
            throw G04NetworkWorkspaceError.provider(code: "emptyFile", retryable: false)
        }
        guard size <= G04WorkspaceSourceCoordinator.maximumProviderCopyBytes else {
            throw G04NetworkWorkspaceError.tooLarge(limit: G04WorkspaceSourceCoordinator.maximumProviderCopyBytes)
        }
        guard size <= totalBudgetRemaining else {
            throw G04NetworkWorkspaceError.tooLarge(limit: G04NetworkWorkspace.maximumOperationAggregateBytes)
        }
        if let available = try? FileManager.default
            .attributesOfFileSystem(forPath: file.deletingLastPathComponent().path)[.systemFreeSize] as? NSNumber,
           available.uint64Value < UInt64(size) + (32 * 1_048_576) {
            throw G04NetworkWorkspaceError.diskFull
        }
        guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: file) else {
            throw G04NetworkWorkspaceError.diskFull
        }
        defer { try? output.close() }
        var streamed = 0
        var digest = SHA256()
        while streamed < size {
            try cancellation.throwIfCancelled()
            await hook?("provider-read")
            let page = min(streamChunkBytes, size - streamed)
            let chunk = try await adapter.read(path: remote, offset: streamed, limit: page)
            guard chunk.count == page else {
                throw G04NetworkWorkspaceError.provider(code: "protocolFailure", retryable: false)
            }
            try output.write(contentsOf: chunk)
            digest.update(data: chunk)
            streamed += chunk.count
            // Physically-landed page progress (written + counted). The
            // operation view's bytesDone is live progress for the host
            // (Kotlin polls bytesDone+phase); a mid-stream cancel is only
            // observable if landed bytes surface as they land.
            progress?(chunk.count)
        }
        try output.synchronize()
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The delivered whole-body adapter write path under the same entry
    /// budget (provider READS stream above; provider writes ride the
    /// original adapter API — no second transport, no half-PUT).
    static func bodyForWrite(_ file: URL, cancellation: CancellationToken) throws -> Data {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? -1
        guard size > 0, size <= G04WorkspaceSourceCoordinator.maximumProviderCopyBytes else {
            throw G04NetworkWorkspaceError.tooLarge(limit: G04WorkspaceSourceCoordinator.maximumProviderCopyBytes)
        }
        try cancellation.throwIfCancelled()
        return try Data(contentsOf: file)
    }

    static func fileDigest(_ url: URL, cancellation: CancellationToken) throws -> String {
        try FloeDigest.sha256Hex(ofFileAt: url, isCancelled: { cancellation.isCancelled })
    }

    // MARK: - Import

    public func startImport(taskID: UUID, workspaceID: UUID, mountID: UUID,
                            remotePath: String, logicalPath: String,
                            recursive: Bool, conflict: ImportConflict) async throws -> UInt64 {
        try await requireOrdinary(taskID: taskID, workspaceID: workspaceID)
        guard Self.validLogicalPath(logicalPath) else {
            throw G04NetworkWorkspaceError.remotePathRefused("logicalPath")
        }
        let remote = try Self.canonicalRemotePath(remotePath)
        let (mount, adapter, _) = try await route(taskID: taskID, workspaceID: workspaceID,
                                                  mountID: mountID)
        guard !mount.readOnly else {
            throw G04NetworkWorkspaceError.provider(code: "readOnly", retryable: false)
        }
        operationCounter &+= 1
        let staging = try stagingDirectory(operationID: operationCounter)
        guard let operation = await beginLease(taskID: taskID) else {
            throw G04NetworkWorkspaceError.retired
        }
        let box = G04NetworkOperationBox(id: operationCounter, kind: "import", taskID: taskID,
                                         workspaceID: workspaceID, mountID: mountID,
                                         sourceID: nil, recoveryID: nil,
                                         remotePath: remote, logicalPath: logicalPath,
                                         cancellation: operation.cancellation)
        operations[box.id] = box
        let hook = ioHookForTesting
        let owner = self
        Task.detached(priority: .userInitiated) {
            await Self.runImport(box: box, owner: owner, adapter: adapter, mount: mount,
                                 coordinator: await owner.coordinatorHandle(),
                                 staging: staging, operation: operation,
                                 recursive: recursive, conflict: conflict, hook: hook)
        }
        return box.id
    }

    private nonisolated static func runImport(box: G04NetworkOperationBox,
                                              owner: G04NetworkWorkspace,
                                              adapter: any WorkspaceMountAdapter,
                                              mount: NetworkWorkspaceMount,
                                              coordinator: G04WorkspaceSourceCoordinator,
                                              staging: URL, operation: G04WorkspaceOwnedOperation,
                                              recursive: Bool, conflict: ImportConflict,
                                              hook: (@Sendable (String) async -> Void)?) async {
        var aggregate = 0
        var walk = 0
        var singleTarget = ""
        do {
            box.setPhase("stat")
            let rootMeta = try await adapter.metadata(path: box.remotePath)
            if rootMeta.isDirectory, !recursive {
                throw G04NetworkWorkspaceError.remotePathRefused("directoryNeedsRecursive")
            }
            if !rootMeta.isDirectory {
                // Single file: the caller supplied the exact workspace path.
                singleTarget = box.logicalPath
                if try await importOne(box: box, owner: owner, adapter: adapter,
                                       mount: mount, coordinator: coordinator,
                                       staging: staging, operation: operation,
                                       remote: box.remotePath, logicalPath: box.logicalPath,
                                       conflict: conflict,
                                       aggregate: &aggregate, hook: hook) == nil {
                    // Surface the SPECIFIC entry refusal as the operation's
                    // typed failure (never a generic "entryFailed" guess).
                    let code = box.snapshot().failures.last?.code ?? "entryFailed"
                    throw G04NetworkWorkspaceError.transitionRefused(code)
                }
            } else {
                // Bounded DFS over nested files; EVERY file rides the SAME
                // verified commit ladder, and an entry-level conflict is a
                // recorded per-entry failure that never aborts the rest and
                // NEVER overwrites. Empty remote directories are not
                // journaled (nothing durable to reference yet) — reported
                // honestly in `emptyDirsSkipped`.
                var queue: [(remote: String, base: String)] =
                    [(box.remotePath, box.logicalPath)]
                var emptyDirs = 0
                while let (dir, base) = queue.popLast() {
                    try operation.cancellation.throwIfCancelled()
                    await hook?("walk-list")
                    walk += 1
                    guard walk <= maximumWalkEntries else {
                        throw G04NetworkWorkspaceError.tooLarge(limit: maximumWalkEntries)
                    }
                    let entries = try await adapter.list(path: dir)
                    for entry in entries.prefix(maximumWalkEntries) {
                        if entry.isDirectory {
                            let childBase = base + "/" + entry.name
                            guard entry.name != "..", !entry.name.contains("/"),
                                  Self.validLogicalPath(childBase) else {
                                box.entryFailed(path: entry.path, code: "logicalPathRefused")
                                continue
                            }
                            queue.append((entry.path, childBase))
                            continue
                        }
                        guard entry.name != "..", !entry.name.contains("/") else {
                            box.entryFailed(path: entry.path, code: "pathShape")
                            continue
                        }
                        let target = base + "/" + entry.name
                        guard Self.validLogicalPath(target) else {
                            box.entryFailed(path: entry.path, code: "logicalPathRefused")
                            continue
                        }
                        if try await importOne(box: box, owner: owner, adapter: adapter,
                                              mount: mount, coordinator: coordinator,
                                              staging: staging, operation: operation,
                                              remote: entry.path, logicalPath: target,
                                              conflict: conflict, aggregate: &aggregate,
                                              hook: hook) == nil {
                            // Entry-level refusal (conflict/size/empty): the
                            // walk continues with the remaining recoverable
                            // data; the terminal reports `partialFailures`.
                            continue
                        }
                    }
                    if entries.isEmpty { emptyDirs += 1 }
                }
                if emptyDirs > 0 { box.setResult(["emptyDirsSkipped": String(emptyDirs)]) }
            }
            await owner.noteConnectedHandle(mountID: mount.id, readOnly: mount.readOnly)
            let view = box.snapshot()
            var result = view.result
            result["bytes"] = String(aggregate)
            result["files"] = String(view.entriesDone)
            if !singleTarget.isEmpty { result["logicalPath"] = singleTarget }
            if view.entriesFailed > 0 {
                // Honest partial terminal: committed bodies stay committed,
                // refused entries stay refused, never a full-success claim.
                box.settleFailed(phase: "partial", code: "partialFailures", retryable: false,
                                 result: result)
            } else {
                box.settleCompleted(result: result)
            }
            await owner.settleHandle(box, operation, keepScratch: false)
        } catch let error as G04NetworkWorkspaceError {
            let outcome = Self.classify(error)
            box.settleFailed(phase: box.snapshot().phase, code: outcome.code, retryable: outcome.retryable,
                             result: ["bytes": String(aggregate)])
            await owner.settleHandle(box, operation, keepScratch: false)
        } catch FloeError.cancelled {
            box.settleFailed(phase: "stream", code: "cancelled", retryable: true)
            await owner.settleHandle(box, operation, keepScratch: false)
        } catch is CancellationError {
            box.settleFailed(phase: "stream", code: "cancelled", retryable: true)
            await owner.settleHandle(box, operation, keepScratch: false)
        } catch let error as AndroidWorkspaceSourceError {
            let outcome = Self.classifyStore(error)
            box.settleFailed(phase: box.snapshot().phase, code: outcome.code, retryable: outcome.retryable,
                             result: ["bytes": String(aggregate)])
            await owner.settleHandle(box, operation, keepScratch: false)
        } catch let error as NetworkWorkspaceError {
            await owner.noteStatusHandle(mountID: mount.id, code: error.code.rawValue)
            box.settleFailed(phase: box.snapshot().phase, code: error.code.rawValue,
                             retryable: error.retryable, result: ["bytes": String(aggregate)])
            await owner.settleHandle(box, operation, keepScratch: false)
        } catch {
            box.settleFailed(phase: box.snapshot().phase, code: "internal", retryable: false,
                             result: ["bytes": String(aggregate)])
            await owner.settleHandle(box, operation, keepScratch: false)
        }
    }

    /// One streamed file through the coordinator's file-backed commit.
    /// Returns the actually-bound workspace path, or nil for an ENTRY-level
    /// refusal (empty/oversize/conflict under `.refuse`) — recorded in the
    /// operation's failure list so the walk continues with the remaining
    /// recoverable data and nothing is ever overwritten. Same-digest retry
    /// completes an interrupted attempt exactly like the delivered rule.
    /// Aggregate exhaustion still throws (fatal for this operation).
    private nonisolated static func importOne(box: G04NetworkOperationBox,
                                              owner: G04NetworkWorkspace,
                                              adapter: any WorkspaceMountAdapter,
                                              mount: NetworkWorkspaceMount,
                                              coordinator: G04WorkspaceSourceCoordinator,
                                              staging: URL, operation: G04WorkspaceOwnedOperation,
                                              remote: String, logicalPath: String,
                                              conflict: ImportConflict,
                                              aggregate: inout Int,
                                              hook: (@Sendable (String) async -> Void)?) async throws
        -> String? {
        let meta = try await adapter.metadata(path: remote)
        guard !meta.isDirectory else {
            box.entryFailed(path: remote, code: "isDirectory")
            return nil
        }
        guard meta.byteCount > 0 else {
            box.entryFailed(path: remote, code: "emptyFile")
            return nil
        }
        guard meta.byteCount <= Int(Int64(G04WorkspaceSourceCoordinator.maximumProviderCopyBytes)) else {
            box.entryFailed(path: remote, code: "sizeExceeded")
            return nil
        }
        // Count all physically staged bytes, including refused entries;
        // aggregate remains the separate committed-result byte count.
        let remaining = max(0, maximumOperationAggregateBytes - box.snapshot().bytesDone)
        guard meta.byteCount <= Int(Int64(remaining)) else {
            box.entryFailed(path: remote, code: "aggregateExceeded")
            throw G04NetworkWorkspaceError.tooLarge(limit: maximumOperationAggregateBytes)
        }
        let stagedURL = staging.appendingPathComponent(UUID().uuidString + ".bin")
        box.addStaging(stagedURL)
        box.setPhase("stream")
        let streamedDigest = try await streamProviderInto(adapter, remote: remote, file: stagedURL,
                                                          size: Int(meta.byteCount),
                                                          totalBudgetRemaining: remaining,
                                                          cancellation: operation.cancellation,
                                                          hook: hook,
                                                          progress: { landed in
                                                              box.addBytes(landed, total: nil)
                                                          })
        let diskDigest = try fileDigest(stagedURL, cancellation: operation.cancellation)
        guard diskDigest == streamedDigest else {
            throw G04NetworkWorkspaceError.provider(code: "digestMismatch", retryable: false)
        }
        box.setPhase("commit")
        var target = logicalPath
        do {
            _ = try await coordinator.importStagedSourceFile(
                sourceID: UUID(), taskID: box.taskID, workspaceID: box.workspaceID,
                logicalPath: target, kind: mount.kind(), sourceReference: mount.id.uuidString,
                sourceDocumentID: remote, stagedURL: stagedURL,
                stagedBytes: Int(meta.byteCount), entityTag: meta.entityTag)
        } catch let error as G04SourceCoordinatorError {
            guard case .transitionRefused("workingCopyExists") = error else { throw error }
            guard conflict == .copy else {
                box.entryFailed(path: remote, code: "workingCopyExists")
                return nil
            }
            // Scan-and-land through the SAME authority (Main corrections
            // 2026-10-24): every candidate index is attempted via the
            // verified commit ladder itself, whose workingCopyExists
            // refusal lands BEFORE any mutation. The first candidate the
            // ladder accepts is the landed copy; taken candidates advance
            // the index (later available copies are NOT lost) — there is
            // NO arbitrary candidate cap: the operation box's failure-list
            // storage limit is unrelated to filename availability. EVERY
            // attempted candidate first re-checks cancellation (a cancel
            // stays a cancel, never a success), exhaustion is only the
            // numeric-index overflow refusal of the typed conflictCopyTaken,
            // the staged body is reused (never re-downloaded per index),
            // availability is never judged outside the commit authority,
            // and nothing is ever overwritten.
            var index = 1
            while true {
                try operation.cancellation.throwIfCancelled()
                let candidate = Self.conflictCopyName(logicalPath, index: index)
                guard Self.validLogicalPath(candidate) else {
                    box.entryFailed(path: remote, code: "logicalPathRefused")
                    return nil
                }
                do {
                    _ = try await coordinator.importStagedSourceFile(
                        sourceID: UUID(), taskID: box.taskID, workspaceID: box.workspaceID,
                        logicalPath: candidate, kind: mount.kind(), sourceReference: mount.id.uuidString,
                        sourceDocumentID: remote, stagedURL: stagedURL,
                        stagedBytes: Int(meta.byteCount), entityTag: meta.entityTag)
                    target = candidate
                    break
                } catch let retryError as G04SourceCoordinatorError {
                    guard case .transitionRefused("workingCopyExists") = retryError else {
                        throw retryError
                    }
                    let (next, overflowed) = index.addingReportingOverflow(1)
                    guard !overflowed else {
                        box.entryFailed(path: remote, code: "conflictCopyTaken")
                        return nil
                    }
                    index = next
                }
            }
        }
        aggregate += Int(meta.byteCount)
        // Per-page progress already added the physically landed bytes;
        // the entry tail only restates the aggregate total, so a fully
        // streamed file still lands exactly meta.byteCount in bytesDone.
        box.addBytes(0, total: aggregate)
        box.entryDone()
        return target
    }

    // MARK: - Export (workspace file -> provider; non-destructive send)

    public func startExport(taskID: UUID, workspaceID: UUID, mountID: UUID,
                            logicalPath: String, remotePath: String,
                            conflictCopy: Bool) async throws -> UInt64 {
        try await requireOrdinary(taskID: taskID, workspaceID: workspaceID)
        guard Self.validLogicalPath(logicalPath) else {
            throw G04NetworkWorkspaceError.remotePathRefused("logicalPath")
        }
        let remote = try Self.canonicalRemotePath(remotePath)
        guard !remote.isEmpty else { throw G04NetworkWorkspaceError.remotePathRefused("empty") }
        let (mount, adapter, _) = try await route(taskID: taskID, workspaceID: workspaceID,
                                                  mountID: mountID)
        guard !mount.readOnly else {
            throw G04NetworkWorkspaceError.provider(code: "readOnly", retryable: false)
        }
        operationCounter &+= 1
        let staging = try stagingDirectory(operationID: operationCounter)
        guard let operation = await beginLease(taskID: taskID) else {
            throw G04NetworkWorkspaceError.retired
        }
        let box = G04NetworkOperationBox(id: operationCounter, kind: "export", taskID: taskID,
                                         workspaceID: workspaceID, mountID: mountID,
                                         sourceID: nil, recoveryID: nil,
                                         remotePath: remote, logicalPath: logicalPath,
                                         cancellation: operation.cancellation)
        operations[box.id] = box
        let hook = ioHookForTesting
        let owner = self
        Task.detached(priority: .userInitiated) {
            await Self.runExport(box: box, owner: owner, adapter: adapter, mount: mount,
                                 coordinator: await owner.coordinatorHandle(),
                                 staging: staging, operation: operation,
                                 conflictCopy: conflictCopy, hook: hook)
        }
        return box.id
    }

    private nonisolated static func runExport(box: G04NetworkOperationBox,
                                              owner: G04NetworkWorkspace,
                                              adapter: any WorkspaceMountAdapter,
                                              mount: NetworkWorkspaceMount,
                                              coordinator: G04WorkspaceSourceCoordinator,
                                              staging: URL, operation: G04WorkspaceOwnedOperation,
                                              conflictCopy: Bool,
                                              hook: (@Sendable (String) async -> Void)?) async {
        do {
            box.setPhase("snapshot")
            let snapshotURL = staging.appendingPathComponent(UUID().uuidString + ".snapshot")
            box.addStaging(snapshotURL)
            let snap = try await coordinator.snapshotWorkingCopy(
                taskID: box.taskID, workspaceID: box.workspaceID,
                logicalPath: box.logicalPath, snapshotURL: snapshotURL)
            await hook?("snapshot")
            box.addBytes(0, total: snap.bytes)
            // Conflict policy BEFORE any provider mutation: an existing
            // remote body is never overwritten by an export.
            box.setPhase("conflict-check")
            var target = box.remotePath
            let parts = target.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if parts.count >= 2, let name = parts.last {
                let parent = parts.dropLast().joined(separator: "/")
                let existing = (try? await adapter.list(path: parent)) ?? []
                if existing.contains(where: { $0.name == name && !$0.isDirectory }) {
                    guard conflictCopy else {
                        box.settleFailed(phase: "conflict-check", code: "conflict", retryable: false)
                        await owner.settleHandle(box, operation, keepScratch: false)
                        return
                    }
                    var index = 1
                    while existing.contains(where: { $0.name == Self.exportCopyName(name, index) }) {
                        index += 1
                    }
                    target = parent + "/" + Self.exportCopyName(name, index)
                }
            }
            box.setPhase("write")
            let body = try bodyForWrite(snapshotURL, cancellation: operation.cancellation)
            _ = try await adapter.write(path: target, data: body, expectedEntityTag: nil)
            await hook?("write")
            // ACTUAL read-back decides (a "success" write without matching
            // bytes is never export-complete).
            box.setPhase("readback")
            let readbackURL = staging.appendingPathComponent(UUID().uuidString + ".readback")
            box.addStaging(readbackURL)
            let observed = try await streamProviderInto(adapter, remote: target, file: readbackURL,
                                                        size: snap.bytes,
                                                        totalBudgetRemaining: maximumOperationAggregateBytes,
                                                        cancellation: operation.cancellation,
                                                        hook: hook)
            let readbackDigest = try fileDigest(readbackURL, cancellation: operation.cancellation)
            guard observed == snap.sha256, readbackDigest == snap.sha256 else {
                await owner.noteConnectedHandle(mountID: mount.id, readOnly: mount.readOnly)
                box.settleFailed(phase: "readback", code: "providerReadbackMismatch", retryable: false,
                                 result: ["remotePath": target, "snapshotSHA256": snap.sha256,
                                          "observedSHA256": observed])
                await owner.settleHandle(box, operation, keepScratch: false)
                return
            }
            await owner.noteConnectedHandle(mountID: mount.id, readOnly: mount.readOnly)
            box.addBytes(snap.bytes, total: snap.bytes)
            box.entryDone()
            box.settleCompleted(result: ["remotePath": target, "sha256": snap.sha256,
                                         "bytes": String(snap.bytes)])
            await owner.settleHandle(box, operation, keepScratch: false)
        } catch let error as G04NetworkWorkspaceError {
            let outcome = Self.classify(error)
            box.settleFailed(phase: box.snapshot().phase, code: outcome.code, retryable: outcome.retryable)
            await owner.settleHandle(box, operation, keepScratch: false)
        } catch FloeError.cancelled {
            box.settleFailed(phase: "stream", code: "cancelled", retryable: true)
            await owner.settleHandle(box, operation, keepScratch: false)
        } catch is CancellationError {
            box.settleFailed(phase: "stream", code: "cancelled", retryable: true)
            await owner.settleHandle(box, operation, keepScratch: false)
        } catch let error as G04SourceCoordinatorError {
            let outcome = Self.classifyCoordinator(error)
            box.settleFailed(phase: box.snapshot().phase, code: outcome.code, retryable: outcome.retryable)
            await owner.settleHandle(box, operation, keepScratch: false)
        } catch let error as AndroidWorkspaceSourceError {
            let outcome = Self.classifyStore(error)
            box.settleFailed(phase: box.snapshot().phase, code: outcome.code, retryable: outcome.retryable)
            await owner.settleHandle(box, operation, keepScratch: false)
        } catch let error as NetworkWorkspaceError {
            await owner.noteStatusHandle(mountID: mount.id, code: error.code.rawValue)
            box.settleFailed(phase: box.snapshot().phase, code: error.code.rawValue,
                             retryable: error.retryable)
            await owner.settleHandle(box, operation, keepScratch: false)
        } catch {
            box.settleFailed(phase: box.snapshot().phase, code: "internal", retryable: false)
            await owner.settleHandle(box, operation, keepScratch: false)
        }
    }

    static func exportCopyName(_ name: String, _ index: Int) -> String {
        let url = URL(fileURLWithPath: name)
        let marker = index == 1 ? " (conflict copy)" : " (conflict copy \(index))"
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent + marker
        return ext.isEmpty ? base : base + "." + ext
    }

    // MARK: - Save (durable network source -> provider replacement ladder)

    public func startSave(taskID: UUID, workspaceID: UUID, sourceID: UUID) async throws -> UInt64 {
        try await requireOrdinary(taskID: taskID, workspaceID: workspaceID)
        guard let source = try await store.source(id: sourceID),
              source.workspaceID == workspaceID,
              source.kind == .webdav || source.kind == .smb,
              let mountID = UUID(uuidString: source.sourceReference),
              let remote = source.sourceDocumentID, !remote.isEmpty else {
            throw G04NetworkWorkspaceError.transitionRefused("sourceNotNetwork")
        }
        let (mount, adapter, _) = try await route(taskID: taskID, workspaceID: workspaceID,
                                                  mountID: mountID)
        guard mount.transportKind == source.kind else {
            throw G04NetworkWorkspaceError.transitionRefused("kindDrift")
        }
        guard !mount.readOnly else {
            throw G04NetworkWorkspaceError.provider(code: "readOnly", retryable: false)
        }
        operationCounter &+= 1
        let staging = try stagingDirectory(operationID: operationCounter)
        guard let operation = await beginLease(taskID: taskID) else {
            throw G04NetworkWorkspaceError.retired
        }
        let box = G04NetworkOperationBox(id: operationCounter, kind: "save", taskID: taskID,
                                         workspaceID: workspaceID, mountID: mountID,
                                         sourceID: sourceID, recoveryID: nil,
                                         remotePath: remote, logicalPath: source.logicalPath,
                                         cancellation: operation.cancellation)
        operations[box.id] = box
        let hook = ioHookForTesting
        let owner = self
        Task.detached(priority: .userInitiated) {
            await Self.runSave(box: box, owner: owner, adapter: adapter, mount: mount,
                               source: source, coordinator: await owner.coordinatorHandle(),
                               staging: staging, operation: operation, hook: hook)
        }
        return box.id
    }

    private nonisolated static func runSave(box: G04NetworkOperationBox,
                                            owner: G04NetworkWorkspace,
                                            adapter: any WorkspaceMountAdapter,
                                            mount: NetworkWorkspaceMount,
                                            source: AndroidWorkspaceSource,
                                            coordinator: G04WorkspaceSourceCoordinator,
                                            staging: URL, operation: G04WorkspaceOwnedOperation,
                                            hook: (@Sendable (String) async -> Void)?) async {
        let recoveryID = UUID()
        var claimed = false
        do {
            guard source.sourceSHA256 != nil else {
                throw G04NetworkWorkspaceError.transitionRefused("unboundSource")
            }
            // Replacement bytes: freeze the EXACT working copy through the
            // original snapshot authority (native digest over the snapshot).
            box.setPhase("snapshot")
            let snapshotURL = staging.appendingPathComponent(UUID().uuidString + ".snapshot")
            box.addStaging(snapshotURL)
            let replacement = try await coordinator.snapshotWorkingCopy(
                taskID: box.taskID, workspaceID: box.workspaceID,
                logicalPath: box.logicalPath, snapshotURL: snapshotURL)
            // Fresh provider backup observation (streamed + hashed by
            // native). Drift against the recorded digest opens NO permit —
            // the ORIGINAL rule, byte for byte.
            box.setPhase("backup")
            let backupURL = staging.appendingPathComponent(UUID().uuidString + ".backup")
            box.addStaging(backupURL)
            let backupMeta = try await adapter.metadata(path: box.remotePath)
            let backupDigest = try await streamProviderInto(adapter, remote: box.remotePath,
                                                            file: backupURL,
                                                            size: Int(backupMeta.byteCount),
                                                            totalBudgetRemaining: maximumOperationAggregateBytes,
                                                            cancellation: operation.cancellation,
                                                            hook: hook)
            let backupDisk = try fileDigest(backupURL, cancellation: operation.cancellation)
            guard backupDisk == backupDigest else {
                throw G04NetworkWorkspaceError.provider(code: "digestMismatch", retryable: false)
            }
            box.setPhase("prepare")
            let prepared = try await coordinator.prepareReplacementStaged(
                sourceID: source.id, taskID: box.taskID, workspaceID: box.workspaceID,
                logicalPath: box.logicalPath, recoveryID: recoveryID,
                freshBackupSHA256: backupDigest,
                backupRelativePath: "Source Recovery/\(source.id.uuidString)/\(recoveryID.uuidString).bin",
                replacementSHA256: replacement.sha256)
            // Second fresh observation -> ONE-TIME durable claim. This claim
            // row IS the destructive permit for the network write: handed
            // once, replayed never (the store refuses a second claim).
            box.setPhase("claim")
            let freshURL = staging.appendingPathComponent(UUID().uuidString + ".fresh")
            box.addStaging(freshURL)
            let freshMeta = try await adapter.metadata(path: box.remotePath)
            let freshDigest = try await streamProviderInto(adapter, remote: box.remotePath,
                                                           file: freshURL,
                                                           size: Int(freshMeta.byteCount),
                                                           totalBudgetRemaining: maximumOperationAggregateBytes,
                                                           cancellation: operation.cancellation,
                                                           hook: hook)
            let freshDisk = try fileDigest(freshURL, cancellation: operation.cancellation)
            guard freshDisk == freshDigest else {
                throw G04NetworkWorkspaceError.provider(code: "digestMismatch", retryable: false)
            }
            let claim = try await coordinator.claimReplacementStaged(
                recoveryID: prepared.recovery.id, sourceID: source.id,
                taskID: box.taskID, workspaceID: box.workspaceID,
                logicalPath: box.logicalPath, freshSHA256: freshDigest)
            guard claim.state == .writing else {
                // The store durably recorded a conflict terminal at claim:
                // NO write may run. Nothing was touched.
                await owner.noteConnectedHandle(mountID: mount.id, readOnly: mount.readOnly)
                box.settleFailed(phase: "claim", code: "driftAtClaim", retryable: false,
                                 result: ["recoveryID": recoveryID.uuidString,
                                          "journalState": claim.state.rawValue])
                await owner.settleHandle(box, operation, keepScratch: false)
                return
            }
            claimed = true
            // The permitted destructive write: whole-body under the entry
            // budget through the delivered adapter. WebDAV carries the
            // journaled ETag (If-Match CAS); SMB has no entity tag — the
            // delivered limitation — so its ladder rests on the byte-level
            // fresh observations and the actual read-back instead.
            box.setPhase("write")
            await hook?("ladder-write")
            let body = try bodyForWrite(snapshotURL, cancellation: operation.cancellation)
            _ = try await adapter.write(path: box.remotePath, data: body,
                                        expectedEntityTag: mount.transport == .webDAV
                                            ? source.entityTag : nil)
            // ACTUAL read-back decides the journal terminal.
            box.setPhase("readback")
            let readbackURL = staging.appendingPathComponent(UUID().uuidString + ".readback")
            box.addStaging(readbackURL)
            let replacementMeta = try await adapter.metadata(path: box.remotePath)
            let observed = try await streamProviderInto(adapter, remote: box.remotePath,
                                                       file: readbackURL,
                                                       size: Int(replacementMeta.byteCount),
                                                       totalBudgetRemaining: maximumOperationAggregateBytes,
                                                       cancellation: operation.cancellation,
                                                       hook: hook)
            let observedDisk = try fileDigest(readbackURL, cancellation: operation.cancellation)
            guard observedDisk == observed else {
                // Read-back transport vs disk disagreement: the receipt
                // stays exactly where it is (writing); reconcile decides
                // from a later observation. Never a fabricated terminal.
                throw G04NetworkWorkspaceError.provider(code: "readbackUnproven", retryable: true)
            }
            box.setPhase("settle")
            let terminal = try await coordinator.settleReplacementStaged(
                recoveryID: prepared.recovery.id, sourceID: source.id,
                taskID: box.taskID, workspaceID: box.workspaceID,
                logicalPath: box.logicalPath, readbackSHA256: observed,
                entityTag: replacementMeta.entityTag)
            await owner.noteConnectedHandle(mountID: mount.id, readOnly: mount.readOnly)
            let fields = ["recoveryID": prepared.recovery.id.uuidString,
                          "journalState": terminal.state.rawValue,
                          "observedSHA256": observed,
                          "replacementSHA256": replacement.sha256]
            if terminal.state == .committed {
                box.addBytes(replacement.bytes, total: replacement.bytes)
                box.entryDone()
                box.settleCompleted(result: fields)
                await owner.settleHandle(box, operation, keepScratch: false)
            } else {
                box.settleFailed(phase: "settle", code: "providerReadbackMismatch",
                                 retryable: false, result: fields)
                await owner.settleHandle(box, operation, keepScratch: false)
            }
        } catch let error as G04NetworkWorkspaceError {
            let outcome = Self.classify(error)
            box.settleFailed(phase: box.snapshot().phase, code: outcome.code,
                             retryable: outcome.retryable,
                             result: ["recoveryID": recoveryID.uuidString,
                                      "reconcileRequired": claimed ? "yes" : "no"])
            await owner.settleHandle(box, operation, keepScratch: claimed)
        } catch FloeError.cancelled {
            box.settleFailed(phase: box.snapshot().phase, code: "cancelled", retryable: true,
                             result: ["recoveryID": recoveryID.uuidString,
                                      "reconcileRequired": claimed ? "yes" : "no"])
            await owner.settleHandle(box, operation, keepScratch: claimed)
        } catch is CancellationError {
            box.settleFailed(phase: box.snapshot().phase, code: "cancelled", retryable: true,
                             result: ["recoveryID": recoveryID.uuidString,
                                      "reconcileRequired": claimed ? "yes" : "no"])
            await owner.settleHandle(box, operation, keepScratch: claimed)
        } catch let error as G04SourceCoordinatorError {
            let outcome = Self.classifyCoordinator(error)
            box.settleFailed(phase: box.snapshot().phase, code: outcome.code,
                             retryable: outcome.retryable,
                             result: ["recoveryID": recoveryID.uuidString,
                                      "reconcileRequired": claimed ? "yes" : "no"])
            await owner.settleHandle(box, operation, keepScratch: claimed)
        } catch let error as AndroidWorkspaceSourceError {
            let outcome = Self.classifyStore(error)
            box.settleFailed(phase: box.snapshot().phase, code: outcome.code,
                             retryable: outcome.retryable,
                             result: ["recoveryID": recoveryID.uuidString,
                                      "reconcileRequired": claimed ? "yes" : "no"])
            await owner.settleHandle(box, operation, keepScratch: claimed)
        } catch let error as NetworkWorkspaceError {
            await owner.noteStatusHandle(mountID: mount.id, code: error.code.rawValue)
            box.settleFailed(phase: box.snapshot().phase, code: error.code.rawValue,
                             retryable: error.retryable,
                             result: ["recoveryID": recoveryID.uuidString,
                                      "reconcileRequired": claimed ? "yes" : "no"])
            await owner.settleHandle(box, operation, keepScratch: claimed)
        } catch {
            box.settleFailed(phase: box.snapshot().phase, code: "internal", retryable: false,
                             result: ["recoveryID": recoveryID.uuidString,
                                      "reconcileRequired": claimed ? "yes" : "no"])
            await owner.settleHandle(box, operation, keepScratch: claimed)
        }
    }

    // MARK: - Reconcile (interrupted receipt vs LIVE provider bytes)

    public func startReconcile(taskID: UUID, workspaceID: UUID, recoveryID: UUID) async throws -> UInt64 {
        try await requireOrdinary(taskID: taskID, workspaceID: workspaceID)
        let pending = try await store.pendingRecovery(workspaceID: workspaceID, limit: 200)
        guard let receipt = pending.first(where: { $0.id == recoveryID }),
              receipt.state == .prepared || receipt.state == .writing,
              let source = try await store.source(id: receipt.sourceID),
              source.kind == .webdav || source.kind == .smb,
              let mountID = UUID(uuidString: source.sourceReference),
              let remote = source.sourceDocumentID else {
            throw G04NetworkWorkspaceError.transitionRefused("notNetworkRecovery")
        }
        let (mount, adapter, _) = try await route(taskID: taskID, workspaceID: workspaceID,
                                                  mountID: mountID)
        operationCounter &+= 1
        let staging = try stagingDirectory(operationID: operationCounter)
        guard let operation = await beginLease(taskID: taskID) else {
            throw G04NetworkWorkspaceError.retired
        }
        let box = G04NetworkOperationBox(id: operationCounter, kind: "reconcile", taskID: taskID,
                                         workspaceID: workspaceID, mountID: mountID,
                                         sourceID: source.id, recoveryID: recoveryID,
                                         remotePath: remote, logicalPath: source.logicalPath,
                                         cancellation: operation.cancellation)
        operations[box.id] = box
        let hook = ioHookForTesting
        let owner = self
        Task.detached(priority: .userInitiated) {
            await Self.runReconcile(box: box, owner: owner, adapter: adapter,
                                    coordinator: await owner.coordinatorHandle(),
                                    staging: staging, operation: operation, hook: hook)
        }
        return box.id
    }

    private nonisolated static func runReconcile(box: G04NetworkOperationBox,
                                                 owner: G04NetworkWorkspace,
                                                 adapter: any WorkspaceMountAdapter,
                                                 coordinator: G04WorkspaceSourceCoordinator,
                                                 staging: URL, operation: G04WorkspaceOwnedOperation,
                                                 hook: (@Sendable (String) async -> Void)?) async {
        do {
            guard let recoveryID = box.recoveryID, let sourceID = box.sourceID else {
                throw G04NetworkWorkspaceError.transitionRefused("notNetworkRecovery")
            }
            box.setPhase("observe")
            let observeURL = staging.appendingPathComponent(UUID().uuidString + ".observe")
            box.addStaging(observeURL)
            let meta = try await adapter.metadata(path: box.remotePath)
            let observed = try await streamProviderInto(adapter, remote: box.remotePath,
                                                        file: observeURL,
                                                        size: Int(meta.byteCount),
                                                        totalBudgetRemaining: maximumOperationAggregateBytes,
                                                        cancellation: operation.cancellation,
                                                        hook: hook)
            let disk = try fileDigest(observeURL, cancellation: operation.cancellation)
            guard disk == observed else {
                throw G04NetworkWorkspaceError.provider(code: "digestMismatch", retryable: false)
            }
            box.setPhase("reconcile")
            let terminal = try await coordinator.reconcileReceiptStaged(
                recoveryID: recoveryID, taskID: box.taskID, workspaceID: box.workspaceID,
                observedSHA256: observed)
            box.setResult(["recoveryID": recoveryID.uuidString,
                           "sourceID": sourceID.uuidString,
                           "journalState": terminal.state.rawValue,
                           "observedSHA256": terminal.observedSHA256 ?? observed])
            box.entryDone()
            box.settleCompleted(result: box.snapshot().result)
            await owner.settleHandle(box, operation, keepScratch: false)
        } catch let error as G04NetworkWorkspaceError {
            let outcome = Self.classify(error)
            box.settleFailed(phase: box.snapshot().phase, code: outcome.code, retryable: outcome.retryable)
            await owner.settleHandle(box, operation, keepScratch: false)
        } catch FloeError.cancelled {
            box.settleFailed(phase: "observe", code: "cancelled", retryable: true)
            await owner.settleHandle(box, operation, keepScratch: false)
        } catch is CancellationError {
            box.settleFailed(phase: "observe", code: "cancelled", retryable: true)
            await owner.settleHandle(box, operation, keepScratch: false)
        } catch let error as G04SourceCoordinatorError {
            let outcome = Self.classifyCoordinator(error)
            box.settleFailed(phase: box.snapshot().phase, code: outcome.code, retryable: outcome.retryable)
            await owner.settleHandle(box, operation, keepScratch: false)
        } catch let error as AndroidWorkspaceSourceError {
            let outcome = Self.classifyStore(error)
            box.settleFailed(phase: box.snapshot().phase, code: outcome.code, retryable: outcome.retryable)
            await owner.settleHandle(box, operation, keepScratch: false)
        } catch let error as NetworkWorkspaceError {
            box.settleFailed(phase: box.snapshot().phase, code: error.code.rawValue,
                             retryable: error.retryable)
            await owner.settleHandle(box, operation, keepScratch: false)
        } catch {
            box.settleFailed(phase: box.snapshot().phase, code: "internal", retryable: false)
            await owner.settleHandle(box, operation, keepScratch: false)
        }
    }

    // MARK: - Error classification (byte-free tokens for replies)

    private nonisolated static func classify(_ error: G04NetworkWorkspaceError)
        -> (code: String, retryable: Bool) {
        switch error {
        case .retired: return ("retired", false)
        case .identityRefused: return ("identityRefused", false)
        case .mountUnknown: return ("mountUnknown", false)
        case let .configurationRefused(token): return ("config.\(token)", false)
        case let .remotePathRefused(token): return ("path.\(token)", false)
        case let .credentialRefused(token): return (token, false)
        case let .provider(code, retryable): return (code, retryable)
        case .tooLarge: return ("sizeExceeded", false)
        case let .transitionRefused(token): return (token, false)
        case .operationUnknown: return ("operationUnknown", false)
        case .diskFull: return ("diskFull", true)
        }
    }

    private nonisolated static func classifyCoordinator(_ error: G04SourceCoordinatorError)
        -> (code: String, retryable: Bool) {
        switch error {
        case .retired: return ("retired", false)
        case .conversationMissing, .purposeNotOrdinary, .workspaceUnbound, .ownerChanged:
            return ("identityRefused", false)
        case .invalidMetadata: return ("invalidMetadata", false)
        case .stagedBytesUnavailable: return ("emptyFile", false)
        case .digestMismatch: return ("sourceChangedSinceImport", false)
        case .transportNotBound: return ("transportNotBound", true)
        case .sourceMissing: return ("sourceMissing", false)
        case .staleRevision: return ("staleRevision", false)
        case let .transitionRefused(reason): return (String(reason.prefix(64)), false)
        case .readbackMismatch: return ("providerReadbackMismatch", false)
        case let .providerFailed(code): return (code, false)
        case .tooLarge: return ("sizeExceeded", false)
        case .diskFull: return ("diskFull", true)
        case let .invalidWorkingCopy(reason): return ("workingCopy.\(reason.prefix(48))", false)
        }
    }

    /// ORIGINAL journal-store refusals map onto the SAME closed tokens the
    /// gateway ladder reports (an open receipt never receives a second
    /// permit; replayed CAS is `transitionRefused`, never "internal").
    private nonisolated static func classifyStore(_ error: AndroidWorkspaceSourceError)
        -> (code: String, retryable: Bool) {
        switch error {
        case .invalidMetadata: return ("invalidMetadata", false)
        case .missingSource: return ("sourceMissing", false)
        case .staleRevision: return ("staleRevision", false)
        case .receiptMismatch: return ("receiptMismatch", false)
        case .invalidTransition: return ("transitionRefused", false)
        @unknown default: return ("transitionRefused", false)
        }
    }

    private static func secretToken(_ error: Error) -> String {
        if let typed = error as? G04NetworkSecretFailure {
            switch typed {
            case .notFound: return "credentialNotFound"
            case .cleanupPending: return "credentialCleanupPending"
            case .gatewayUnavailable: return "credentialGatewayUnavailable"
            case .gatewayRejected: return "credentialRejected"
            case .gatewayEffectUnknown: return "credentialEffectUnknown"
            case .invalidLabel: return "credentialLabelRefused"
            case .invalidTicket: return "credentialTicketRefused"
            case .leaseRetired: return "retired"
            }
        }
        return "credentialRejected"
    }

    private static func endpointIdentity(_ url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "")://\((url.host ?? "").lowercased()):\(url.port ?? -1)"
    }

    private static func status(for error: NetworkWorkspaceError) -> NetworkWorkspaceMountStatus {
        switch error.code {
        case .authenticationFailed: return .authenticationFailed
        case .networkUnreachable, .timedOut: return .unreachable
        default: return .failed
        }
    }

    // MARK: - Detached-ladder support (actor-hop helpers)

    func coordinatorHandle() -> G04WorkspaceSourceCoordinator { coordinator }

    /// RAM credential staging through the lease (bounded tickets; the only
    /// ingress for secret bytes, consumed by mount add/update below).
    func stageCredential(_ secret: Data) async -> Int64 {
        await lease.stage(secret)
    }

    func abortCredentialStage(_ ticket: Int64) async -> Bool {
        await lease.abortStage(ticket)
    }

    func settleHandle(_ box: G04NetworkOperationBox, _ operation: G04WorkspaceOwnedOperation,
                      keepScratch: Bool) async {
        await settle(box, operation, keepScratch: keepScratch)
    }

    func noteStatusHandle(mountID: UUID, code: String) {
        let mapped: NetworkWorkspaceMountStatus
        switch code {
        case "authenticationFailed": mapped = .authenticationFailed
        case "networkUnreachable", "timedOut": mapped = .unreachable
        case "credentialMissing": mapped = .failed
        default: mapped = .failed
        }
        statuses[mountID] = mapped
    }

    func noteConnectedHandle(mountID: UUID, readOnly: Bool) {
        statuses[mountID] = readOnly ? .readOnly : .connected
    }

    // MARK: - Network source rows (same journal, no second store)

    public func networkSourcesPage(workspaceID: UUID, afterID: String? = nil, limit: Int = 64) async throws
        -> [AndroidWorkspaceSource] {
        let rows = try await coordinator.sourcesPage(workspaceID: workspaceID, afterID: afterID,
                                                     limit: limit)
        return rows.filter { $0.kind != .saf }
    }

    /// Unfinished receipts whose SOURCE row is a network binding (the panel
    /// and Host API surface the same journal 47; no second store).
    public func pendingNetworkRecoveries(workspaceID: UUID) async throws
        -> [AndroidWorkspaceRecovery] {
        let rows = try await store.pendingRecovery(workspaceID: workspaceID, limit: 200)
        var network: [AndroidWorkspaceRecovery] = []
        for receipt in rows {
            guard let source = try await store.source(id: receipt.sourceID),
                  source.kind == .webdav || source.kind == .smb else { continue }
            network.append(receipt)
        }
        return network
    }

    // MARK: - Retirement

    /// Exact-epoch retirement. Fences admissions, requests every operation
    /// cancel, and gives settled work its lease release through the normal
    /// path. Unsettled operations KEEP their owned-work tokens (RB1's drain
    /// decides, exactly like the delivered mailbox/gateway rules); the
    /// retained sessions are invalidated last so outstanding URLSession
    /// admission errors out promptly instead of hanging the drain forever —
    /// each affected operation still settles through its own catch path.
    public func retire() {
        guard !retired else { return }
        retired = true
        for box in operations.values { box.requestCancel() }
    }

    /// Await the physical settlement of every requested cancellation.
    /// Phase 1 waits politely; phase 2 invalidates the retained transport
    /// admission (URLSession-level cancel makes outstanding WebDAV hops
    /// error out promptly through each operation's OWN catch/settlement path)
    /// and waits a final bounded grace; phase 3 reports the ids that are
    /// STILL non-terminal. Re-entrant: repeated calls re-request and
    /// re-probe; sessions/roots/lease retire are idempotent no-ops when
    /// already drained. The caller NEVER detaches an operation's owned-work
    /// token here — only its own settle path does.
    public func awaitSettledOperations(deadlineSeconds: TimeInterval = 10,
                                       graceSeconds: TimeInterval = 2) async -> [UInt64] {
        let mounted = operations.values.filter { !$0.isTerminal }
        mounted.forEach { $0.requestCancel() }
        var deadline = Date().addingTimeInterval(deadlineSeconds)
        while Date() < deadline {
            if mounted.allSatisfy({ $0.isTerminal }) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if !mounted.allSatisfy({ $0.isTerminal }) {
            for session in sessions.takeAll() { session.cancel() }
        }
        deadline = Date().addingTimeInterval(graceSeconds)
        while Date() < deadline {
            if mounted.allSatisfy({ $0.isTerminal }) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let outstanding = mounted.filter { !$0.isTerminal }.map { $0.id }
        let roots = Array(registeredRoots.values)
        for root in roots {
            await NetworkWorkspaceMountRegistry.shared.unregister(rootURL: root)
        }
        registeredRoots.removeAll()
        await lease.retire()
        return outstanding
    }

    var isRetired: Bool { retired }
}

// MARK: - Mount kind helpers

extension NetworkWorkspaceMount {
    var transportKind: AndroidWorkspaceSourceKind {
        transport == .smb ? .smb : .webdav
    }
    func kind() -> AndroidWorkspaceSourceKind { transportKind }
}

// MARK: - Live-generation registry (Main's attach seam)

/// Epoch-exact trusted registry for the ONE live network workspace owner.
/// Main's domain extension calls `attach(epoch:installed:coordinator:)`
/// inside installation with the EXPLICIT composition being installed (never
/// a re-read of an unpublished global) and the exact coordinator it just
/// registered; a mismatch or a second live generation refuses typed false.
/// `detach(epoch:)` is retirement-exact and can never clear a newer
/// generation's binding.
///
/// Lifecycle honesty (Main correction 2026-10-24): an exact-epoch detach
/// that cannot PROVE physical settlement of every owned operation KEEPS the
/// exact (epoch, owner) binding registered. The retained owner still holds
/// the original `.conversation` owned-work tokens (each operation's own
/// settlement path is the only thing that detaches them), and a new
/// generation can never install over unproven old IO — `attach` refuses
/// while a binding is live. Repeated exact-epoch detach is safe: it re-
/// requests cancellation, re-probes settlement, and clears only on the
/// proven-empty outstanding set; a detach after a clear is a no-op. The
/// deadline is a REPORTING bound, not a force-clear.
///
/// All locking is synchronous (`NSLock.withLock`) with no lock held across
/// an await, per the Swift 6 object-compilation requirement.
public final class G04NetworkWorkspaceHostRegistry: @unchecked Sendable {
    public static let shared = G04NetworkWorkspaceHostRegistry()

    private let lock = NSLock()
    private var live: (epoch: UInt64, owner: G04NetworkWorkspace)?

    private init() {}

    /// Installs the owner for the EXPLICIT composition being installed.
    /// Returns false (typed refusal, no side effects) when a generation is
    /// already live, the supplied composition/epoch pair disagrees, or the
    /// coordinator is not the exact one registered for that epoch.
    @discardableResult
    public func attach(epoch: UInt64, installed: G02InstalledComposition,
                       coordinator: G04WorkspaceSourceCoordinator) -> Bool {
        guard installed.epoch == epoch,
              G04WorkspaceHostRegistry.shared.coordinator(epoch: epoch) === coordinator else {
            return false
        }
        // Construct OUTSIDE the lock (actor init sweeps this lane's stale-
        // generation scratch); the lock only covers the one-slot swap.
        let owner = G04NetworkWorkspace(
            epoch: epoch, cluster: installed.cluster, coordinator: coordinator,
            secrets: G04VaultNetworkSecretAuthority(vault: installed.vault))
        return lock.withLock {
            guard live == nil else { return false }   // one live generation; refusal is honest
            live = (epoch, owner)
            return true
        }
    }

    public func owner(epoch: UInt64) -> G04NetworkWorkspace? {
        lock.withLock {
            guard let live, live.epoch == epoch else { return nil }
            return live.owner
        }
    }

    public var currentOwner: G04NetworkWorkspace? {
        lock.withLock { live?.owner }
    }

    /// Retirement-side detach (see type docs). Async: every lock section is
    /// a synchronous `withLock` and NO lock is held across an await.
    @discardableResult
    public func detach(epoch: UInt64) async -> (cleared: Bool, outstanding: [UInt64]) {
        let target: G04NetworkWorkspace? = lock.withLock {
            (live?.epoch == epoch) ? live?.owner : nil
        }
        guard let target else { return (true, []) }   // no-op: already clear or foreign epoch
        await target.retire()
        let unsettled = await target.awaitSettledOperations()
        guard unsettled.isEmpty else {
            // Physical settlement UNPROVEN: keep the exact binding. The old
            // operations keep their original tokens; a newer generation
            // cannot attach over them. Main's drain retries this call.
            return (false, unsettled)
        }
        let cleared = lock.withLock { () -> Bool in
            guard let live, live.epoch == epoch, live.owner === target else { return false }
            self.live = nil
            return true
        }
        return (cleared, [])
    }
}
