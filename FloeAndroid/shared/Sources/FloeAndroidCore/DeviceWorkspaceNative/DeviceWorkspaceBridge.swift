// SPDX-License-Identifier: MPL-2.0
//
// Device-workspace sync — trusted-host C ABI (`floe_device_workspace_*`).
//
// Bounded, epoch-fenced native entry for the App-owned paired-device
// workspace lane. Kotlin `com.floe.android.bridge.DeviceWorkspaceNative` is
// the ONLY JVM caller; nothing here is a V3 command and no model route
// reaches these functions. Per peer/task authorization is enforced by the
// trusted Kotlin transport (share map + UI consent) BEFORE any call; native
// admits only what the DURABLE stores certify for the fenced epoch:
//
//   * identity: the accepted root epoch is read back from the live
//     generation on EVERY call — a stale/foreign epoch is typed, never
//     trusted (`G02NativeRootEpoch.readback`, the same fact the runtime
//     status snapshot reports);
//   * binding: one ordinary, visible, currently-bound managed private-task
//     or managed-project root per task. Source resolution is strictly
//     read-only and NEVER materializes a missing path; the receive side
//     (`targetBinding`) is the one place a missing binding may be created,
//     through the SAME task-private `ensureWorkspace`/original
//     `LinuxWorkspaceAuthority.resolveWorkspace` materialization path as
//     `G04WorkspaceFacade.activate`, with the original owner re-read and
//     re-validated after creation. An existing binding is never re-pointed;
//     a missing project leaf fails closed (never recreated);
//   * authority: every store hop runs under the REAL G04 workspace
//     operation lease (`FacadeRunDomain.beginG04WorkspaceOperation`) with
//     cancellation + post-hop lease validation, on a bounded semaphore wait
//     (the JNI thread never blocks unboundedly);
//   * scope proof: a stable non-path opaque string of workspace ID plus the
//     pinned root device+inode, recomputed from the live binding on every
//     opening command and rechecked through the pinned descriptor identity
//     on every stream read/write;
//   * bytes: source bytes leave only through <= 64 KiB JNI pages from a
//     snapshot-validated descriptor read; target bytes arrive as <= 64 KiB
//     staged appends, are sealed by exact length + SHA-256, and commit with
//     a no-overwrite (linkat/unlinkat on Android, renameatx_np(RENAME_EXCL)
//     on Darwin) or an explicit-previous-digest comparison under the
//     ORIGINAL `ManagedFileMutationLock` — old bytes are never modified on
//     failure. Deterministic conflict storage is built HERE as
//     `Floe Sync Conflicts/<peer digest>/<original path>` from the original
//     wire path plus digest; a remote conflict directory/path is never
//     trusted. Authorization per peer/task stays with trusted Kotlin.
import Foundation
import FloeCore
import FloePersistence
import FloeAndroidWorkspaceTools
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

// MARK: - Status / limits vocabulary (frozen ABI)

enum DeviceWorkspaceBridgeStatus {
    static let ok: Int32 = 0
    static let invalid: Int32 = -105
    static let buffer: Int32 = -106
    static let unavailable: Int32 = -801     // no live root generation / no such conversation
    static let fenced: Int32 = -802          // epoch belongs to another/retired generation
    static let sessionUnknown: Int32 = -803
    static let notShared: Int32 = -805       // no eligible current root / binding mismatch
    static let conflict: Int32 = -806
    static let oversized: Int32 = -808
    static let busy: Int32 = -810            // live session table saturated
    static let ioFailure: Int32 = -812
}

enum DeviceWorkspaceBridgeLimits {
    /// Frozen JNI page bound (identical to every other binary bridge lane).
    static let maximumChunkBytes = 65_536
    /// Whole command document bound (paths <= 1 KiB + digests fit easily).
    static let maximumInputBytes = 16 * 1_024
    /// Whole reply bound (scope/ticket/kind documents are tiny; headroom for
    /// the manifest-size integer and future fields).
    static let maximumReplyBytes = 256 * 1_024
    /// One interactive sync at a time per direction; a receive holds target
    /// + stage, a serve holds one source.
    static let maximumLiveSessions = 8
    /// Idle sessions are swept (descriptor + staged bytes are real
    /// resources, so the sweep is lifecycle ownership, not a convenience).
    static let sessionIdleSeconds: TimeInterval = 900
    /// Bounded store hops; a late hop releases its own lease and never
    /// advertises a session.
    static let bindingHopSeconds: TimeInterval = 30
    static let sourceOpenHopSeconds: TimeInterval = 60   // scan hashes real bytes
    static let targetHopSeconds: TimeInterval = 30
}

// MARK: - Sessions

private final class DeviceWorkspaceSourceSession {
    let ticket: Int64
    let createdEpoch: UInt64
    let taskID: UUID
    let workspaceID: UUID
    let scope: String
    let directory: DeviceWorkspaceDirectory
    let entries: [DeviceWorkspaceDirectory.Scanned]
    let manifest: Data
    let createdAt: Date
    var closed = false

    init(ticket: Int64, createdEpoch: UInt64, taskID: UUID, workspaceID: UUID, scope: String,
         directory: DeviceWorkspaceDirectory,
         entries: [DeviceWorkspaceDirectory.Scanned], manifest: Data) {
        self.ticket = ticket
        self.createdEpoch = createdEpoch
        self.taskID = taskID
        self.workspaceID = workspaceID
        self.scope = scope
        self.directory = directory
        self.entries = entries
        self.manifest = manifest
        createdAt = Date()
    }
}

private final class DeviceWorkspaceTargetSession {
    let ticket: Int64
    let createdEpoch: UInt64
    let taskID: UUID
    let workspaceID: UUID
    let scope: String
    let directory: DeviceWorkspaceDirectory
    let createdAt: Date
    var closed = false

    init(ticket: Int64, createdEpoch: UInt64, taskID: UUID, workspaceID: UUID, scope: String,
         directory: DeviceWorkspaceDirectory) {
        self.ticket = ticket
        self.createdEpoch = createdEpoch
        self.taskID = taskID
        self.workspaceID = workspaceID
        self.scope = scope
        self.directory = directory
        createdAt = Date()
    }
}

private final class DeviceWorkspaceStageSession {
    let ticket: Int64
    let createdEpoch: UInt64
    let owner: DeviceWorkspaceTargetSession
    let staged: DeviceWorkspaceDirectory.StagedFile
    let createdAt: Date
    var closed = false

    init(ticket: Int64, createdEpoch: UInt64, owner: DeviceWorkspaceTargetSession,
         staged: DeviceWorkspaceDirectory.StagedFile) {
        self.ticket = ticket
        self.createdEpoch = createdEpoch
        self.owner = owner
        self.staged = staged
        createdAt = Date()
    }
}

// MARK: - Hop plumbing

/// Synchronous result box for one bounded store hop. The producer publishes
/// BEFORE signalling the gate (same idiom as the device-history lane).
private final class DeviceWorkspaceHopBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: Value?

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func publish(_ value: Value) {
        lock.lock()
        state = value
        lock.unlock()
    }
}

// MARK: - Facade

/// Process-lifecycle owner of the device-workspace native surface: one
/// lock, opaque positive Int64 tickets, epoch fencing against the native
/// root readback on EVERY stateful call, stale-generation + idle sweep,
/// exactly-once retire, counters-only stats.
final class DeviceWorkspaceBridgeFacade: @unchecked Sendable {
    static let shared = DeviceWorkspaceBridgeFacade()

    private let lock = NSLock()
    private var counter: Int64 = 0
    private var sources: [Int64: DeviceWorkspaceSourceSession] = [:]
    private var targets: [Int64: DeviceWorkspaceTargetSession] = [:]
    private var stages: [Int64: DeviceWorkspaceStageSession] = [:]
    private var retired: Set<Int64> = []
    private var retiredOrder: [Int64] = []
    private var counters = (commands: 0, reads: 0, writes: 0, fenced: 0,
                            refused: 0, swept: 0, hopsTimedOut: 0, conflicts: 0)

    // Trusted fixture seams (same-module only). Production never writes
    // these; no command/envelope/JSON field can reach this lane either way.
    var liveEpochOverrideForTesting: UInt64?

    // MARK: Epoch truth (never the caller's claim)

    private func liveEpoch() -> UInt64? {
        if let override = liveEpochOverrideForTesting { return override }
        return G02NativeRootEpoch.readback()
    }

    // MARK: Sweep / tickets

    private func sweepStaleLocked(live: UInt64?) {
        let now = Date()
        for (ticket, session) in sources
        where session.createdEpoch != live || now.timeIntervalSince(session.createdAt) > DeviceWorkspaceBridgeLimits.sessionIdleSeconds {
            session.closed = true
            sources.removeValue(forKey: ticket)
            retireLocked(ticket)
            counters.swept += 1
        }
        for (ticket, session) in targets
        where session.createdEpoch != live || now.timeIntervalSince(session.createdAt) > DeviceWorkspaceBridgeLimits.sessionIdleSeconds {
            session.closed = true
            targets.removeValue(forKey: ticket)
            retireLocked(ticket)
            counters.swept += 1
        }
        for (ticket, session) in stages
        where session.createdEpoch != live || now.timeIntervalSince(session.createdAt) > DeviceWorkspaceBridgeLimits.sessionIdleSeconds {
            session.closed = true
            stages.removeValue(forKey: ticket)
            retireLocked(ticket)
            counters.swept += 1
        }
    }

    private func newTicketLocked() -> Int64 {
        counter &+= 1
        return counter
    }

    private func retireLocked(_ ticket: Int64) {
        retired.insert(ticket)
        retiredOrder.append(ticket)
        while retiredOrder.count > 512 { retired.remove(retiredOrder.removeFirst()) }
    }

    private func liveSessionCountLocked() -> Int { sources.count + targets.count + stages.count }

    private func missingSessionStatusLocked(_ ticket: Int64) -> Int32 {
        retired.contains(ticket) ? DeviceWorkspaceBridgeStatus.fenced : DeviceWorkspaceBridgeStatus.sessionUnknown
    }

    /// Epoch admission shared by every stateful entry: 0/no-readback ->
    /// unavailable, anything else stale -> fenced (with a sweep so stale
    /// sessions never linger past the next call).
    private func admit(epoch: UInt64) -> Int32? {
        let live = liveEpoch()
        guard live == epoch else {
            lock.lock()
            counters.fenced += 1
            sweepStaleLocked(live: live)
            lock.unlock()
            return epoch == 0 ? DeviceWorkspaceBridgeStatus.unavailable : DeviceWorkspaceBridgeStatus.fenced
        }
        return nil
    }

    // MARK: - Store hops (G04 workspace operation lease, bounded)

    private struct Binding: Sendable {
        let workspaceID: UUID
        let rootPath: String
    }

    private enum ResolveOutcome: Sendable {
        case binding(Binding)
        case failure(Int32)
    }

    /// Runs `body` on a detached task under ONE bounded semaphore wait. The
    /// body is responsible for acquiring/ending its own G04 lease.
    private func hop<T: Sendable>(_ seconds: TimeInterval,
                                  _ body: @escaping @Sendable () async -> T) -> T? {
        let box = DeviceWorkspaceHopBox<T>()
        let gate = DispatchSemaphore(value: 0)
        let worker = Task.detached(priority: .userInitiated) {
            let outcome = await body()
            box.publish(outcome)
            gate.signal()
        }
        let deadline = DispatchTime.now() + .milliseconds(Int(seconds * 1000))
        var woke = gate.wait(timeout: deadline)
        while box.value == nil, woke != .timedOut {
            woke = gate.wait(timeout: deadline)
        }
        guard let value = box.value else {
            worker.cancel()
            lock.lock(); counters.hopsTimedOut += 1; lock.unlock()
            return nil
        }
        return value
    }

    /// Shared lease window for one resolution: begins the REAL G04 workspace
    /// operation, runs `body`, validates the lease afterwards and ends it.
    private func withLease(epoch: UInt64, taskID: UUID,
                           _ body: (G04WorkspaceOwnedOperation) async -> ResolveOutcome) async -> ResolveOutcome {
        guard let installed = G02RuntimeComposition.shared.installedComposition, installed.epoch == epoch,
              let (domain, _) = RunDomainFacade.current(epoch: epoch),
              let operation = await domain.beginG04WorkspaceOperation(conversationID: taskID,
                                                                      expectedEpoch: epoch) else {
            return .failure(DeviceWorkspaceBridgeStatus.fenced)
        }
        let outcome: ResolveOutcome
        do {
            try Task.checkCancellation()
            try operation.cancellation.throwIfCancelled()
            outcome = await body(operation)
        } catch {
            await domain.endG04WorkspaceOperation(operation)
            return .failure(DeviceWorkspaceBridgeStatus.fenced)
        }
        guard case .binding = outcome,
              await domain.validateG04WorkspaceOperation(operation) else {
            await domain.endG04WorkspaceOperation(operation)
            if case .failure(let status) = outcome { return .failure(status) }
            return .failure(DeviceWorkspaceBridgeStatus.fenced)
        }
        await domain.endG04WorkspaceOperation(operation)
        return outcome
    }

    /// SOURCE authority: strictly read-only. Never materializes a missing
    /// path; admits only an ordinary, visible, currently-bound managed
    /// private-task or managed-project root that exists as a real directory.
    private func resolveSource(epoch: UInt64, taskID: UUID) -> ResolveOutcome {
        hop(DeviceWorkspaceBridgeLimits.bindingHopSeconds) { [self] in
            await withLease(epoch: epoch, taskID: taskID) { operation in
                guard let installed = G02RuntimeComposition.shared.installedComposition,
                      installed.epoch == epoch else {
                    return .failure(DeviceWorkspaceBridgeStatus.unavailable)
                }
                do {
                    guard let conversation = try await installed.cluster.conversationStore
                        .conversation(id: taskID), conversation.isVisibleInOrdinaryList else {
                        return .failure(DeviceWorkspaceBridgeStatus.notShared)
                    }
                    try operation.cancellation.throwIfCancelled()
                    guard let workspaceID = try await installed.cluster.workspaceStore
                        .workspaceID(conversationID: taskID) else {
                        return .failure(DeviceWorkspaceBridgeStatus.notShared)
                    }
                    guard let record = try await installed.cluster.workspaceStore
                        .workspace(id: workspaceID) else {
                        return .failure(DeviceWorkspaceBridgeStatus.notShared)
                    }
                    let storagePath = installed.cluster.identity.root.path
                    let workspaceRoot = storagePath + "/Workspace"
                    let target: String
                    switch record.kind {
                    case .privateTask:
                        guard record.internalRelativePath == "PrivateTasks/\(taskID.uuidString)" else {
                            return .failure(DeviceWorkspaceBridgeStatus.notShared)
                        }
                        target = workspaceRoot + "/PrivateTasks/\(taskID.uuidString)"
                        guard target.hasPrefix(workspaceRoot + "/") else {
                            return .failure(DeviceWorkspaceBridgeStatus.notShared)
                        }
                    case .project:
                        guard record.id == workspaceID,
                              record.internalRelativePath == C01ProjectRootLayout.internalRelativePath(projectID: workspaceID),
                              C01ProjectRootLayout.isManagedProject(record),
                              C01ProjectRootLayout.inspectProjectDirectory(
                                  rootPath: storagePath, projectID: workspaceID) == .available else {
                            return .failure(DeviceWorkspaceBridgeStatus.notShared)
                        }
                        target = C01ProjectRootLayout.projectDirectory(rootPath: storagePath, projectID: workspaceID)
                    }
                    // Read-only admission: the root must ALREADY be a real
                    // directory. Nothing here creates it.
                    guard case .directory = WorkspaceNoFollow.kind(target) else {
                        return .failure(DeviceWorkspaceBridgeStatus.notShared)
                    }
                    return .binding(Binding(workspaceID: workspaceID, rootPath: target))
                } catch {
                    return .failure(DeviceWorkspaceBridgeStatus.ioFailure)
                }
            }
        } ?? .failure(DeviceWorkspaceBridgeStatus.ioFailure)
    }

    /// TARGET authority: the ORIGINAL `LinuxWorkspaceAuthority`
    /// resolver (which performs the original private-task materialization).
    /// The conversation is validated BEFORE the resolve so an ineligible
    /// task never materializes anything.
    private func resolveTarget(epoch: UInt64, taskID: UUID) -> ResolveOutcome {
        hop(DeviceWorkspaceBridgeLimits.targetHopSeconds) { [self] in
            await withLease(epoch: epoch, taskID: taskID) { operation in
                guard let installed = G02RuntimeComposition.shared.installedComposition,
                      installed.epoch == epoch else {
                    return .failure(DeviceWorkspaceBridgeStatus.unavailable)
                }
                do {
                    guard let conversation = try await installed.cluster.conversationStore
                        .conversation(id: taskID), conversation.isVisibleInOrdinaryList else {
                        return .failure(DeviceWorkspaceBridgeStatus.notShared)
                    }
                    try operation.cancellation.throwIfCancelled()
                    guard let resolved = await LinuxWorkspaceAuthority.resolveWorkspace(
                        conversationID: taskID) else {
                        // Missing project leaf / unresolved shape: fail
                        // closed (the original authority never recreates a
                        // project leaf).
                        return .failure(DeviceWorkspaceBridgeStatus.notShared)
                    }
                    return .binding(Binding(workspaceID: resolved.workspaceID,
                                            rootPath: resolved.rootURL.path))
                } catch {
                    return .failure(DeviceWorkspaceBridgeStatus.ioFailure)
                }
            }
        } ?? .failure(DeviceWorkspaceBridgeStatus.ioFailure)
    }

    /// RECEIVE binding authority (`targetBinding`): the ONE receive-only
    /// operation. A missing binding is created with the SAME task-private
    /// `ensureWorkspace` path as `G04WorkspaceFacade.activate`; the original
    /// owner is re-read and re-validated after creation; an existing binding
    /// is returned untouched (never re-pointed); a missing project leaf
    /// fails. The physical root is then materialized/validated through the
    /// ORIGINAL `LinuxWorkspaceAuthority.resolveWorkspace` so the returned
    /// scope names a real, present managed root.
    private func resolveTargetBinding(epoch: UInt64, taskID: UUID) -> ResolveOutcome {
        hop(DeviceWorkspaceBridgeLimits.bindingHopSeconds) { [self] in
            await withLease(epoch: epoch, taskID: taskID) { operation in
                guard let installed = G02RuntimeComposition.shared.installedComposition,
                      installed.epoch == epoch else {
                    return .failure(DeviceWorkspaceBridgeStatus.unavailable)
                }
                do {
                    guard let conversation = try await installed.cluster.conversationStore
                        .conversation(id: taskID), conversation.isVisibleInOrdinaryList else {
                        return .failure(DeviceWorkspaceBridgeStatus.notShared)
                    }
                    let store = installed.cluster.workspaceStore
                    var workspaceID = try await store.workspaceID(conversationID: taskID)
                    if workspaceID == nil {
                        try Task.checkCancellation()
                        try operation.cancellation.throwIfCancelled()
                        let ensured = try await store.ensureWorkspace(
                            conversationID: taskID, title: Self.activationTitle(conversation))
                        workspaceID = ensured.id
                    }
                    guard let bound = workspaceID,
                          let record = try await store.workspace(id: bound) else {
                        return .failure(DeviceWorkspaceBridgeStatus.notShared)
                    }
                    // Validate the ORIGINAL owner shape after creation —
                    // exactly the two accepted managed shapes; anything else
                    // (foreign bookmark, mismatched relative path) fails.
                    switch record.kind {
                    case .privateTask:
                        guard record.internalRelativePath == "PrivateTasks/\(taskID.uuidString)" else {
                            return .failure(DeviceWorkspaceBridgeStatus.notShared)
                        }
                    case .project:
                        guard record.id == bound,
                              record.internalRelativePath == C01ProjectRootLayout.internalRelativePath(projectID: bound),
                              C01ProjectRootLayout.isManagedProject(record) else {
                            return .failure(DeviceWorkspaceBridgeStatus.notShared)
                        }
                    }
                    try operation.cancellation.throwIfCancelled()
                    guard let resolved = await LinuxWorkspaceAuthority.resolveWorkspace(
                        conversationID: taskID) else {
                        return .failure(DeviceWorkspaceBridgeStatus.notShared)
                    }
                    guard resolved.workspaceID == bound else {
                        return .failure(DeviceWorkspaceBridgeStatus.notShared)
                    }
                    return .binding(Binding(workspaceID: resolved.workspaceID,
                                            rootPath: resolved.rootURL.path))
                } catch {
                    return .failure(DeviceWorkspaceBridgeStatus.ioFailure)
                }
            }
        } ?? .failure(DeviceWorkspaceBridgeStatus.ioFailure)
    }

    /// Same canonical bounded title projection the ORIGINAL launch
    /// ownership statement and `G04WorkspaceFacade.activate` apply.
    private static func activationTitle(_ conversation: ConversationRecord) -> String {
        let trimmed = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Chat" : String(trimmed.prefix(80))
    }

    // MARK: - Scope proof

    /// Stable non-path opaque string of workspace ID plus root device+inode.
    private static func makeScope(workspaceID: UUID, stamp: DeviceWorkspaceFileStamp) -> String {
        let material = "\(workspaceID.uuidString)\u{0}\(stamp.device)\u{0}\(stamp.inode)"
        return "floe.workspace.v1." + FloeDigest.sha256Hex(Data(material.utf8))
    }

    /// Non-following root stat used for scope computation (nil unless the
    /// root is a real directory right now).
    private static func rootStamp(_ path: String) -> DeviceWorkspaceFileStamp? {
        var info = stat()
        guard path.withCString({ lstat($0, &info) }) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return DeviceWorkspaceFileStamp(info)
    }

    /// Resolves + proves the CURRENT scope for a binding. A root that was
    /// swapped between resolution and pinning is a not-shared/conflict
    /// boundary, never a silent redirect.
    private func pinnedScope(binding: Binding) -> (scope: String, directory: DeviceWorkspaceDirectory)? {
        guard let stamp = Self.rootStamp(binding.rootPath) else { return nil }
        let directory: DeviceWorkspaceDirectory
        do {
            directory = try DeviceWorkspaceDirectory(rootPath: binding.rootPath)
        } catch {
            return nil
        }
        guard directory.pinnedIdentity == stamp else { return nil }
        return (Self.makeScope(workspaceID: binding.workspaceID, stamp: stamp), directory)
    }

    // MARK: - JSON helpers

    static func canonicalUUID(_ raw: Any?) -> UUID? {
        guard let raw = raw as? String, !raw.isEmpty,
              let value = UUID(uuidString: raw),
              value.uuidString.caseInsensitiveCompare(raw) == .orderedSame else { return nil }
        return value
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty, data.count <= DeviceWorkspaceBridgeLimits.maximumInputBytes,
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else { return nil }
        return object
    }

    private static func jsonString(_ value: Any?, limit: Int) -> String? {
        guard let string = value as? String, !string.isEmpty, string.utf8.count <= limit else { return nil }
        return string
    }

    /// Integral 64-bit numbers only, parsed through the decimal spelling so
    /// a boolean/double can never satisfy an integer field (the same
    /// `Int64(number.stringValue)` idiom as the voice bridge).
    private static func jsonInt64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              let parsed = Int64(number.stringValue) else { return nil }
        return parsed
    }

    private static func jsonUInt64(_ value: Any?) -> UInt64? {
        guard let parsed = jsonInt64(value), parsed > 0 else { return nil }
        return UInt64(parsed)
    }

    private static func jsonInt(_ value: Any?) -> Int? {
        guard let parsed = jsonInt64(value), parsed >= Int64(Int.min), parsed <= Int64(Int.max) else { return nil }
        return Int(parsed)
    }

    private static func jsonDigest(_ value: Any?) -> String? {
        guard let digest = jsonString(value, limit: 64), DeviceWorkspaceDigest.isValid(digest) else { return nil }
        return digest
    }

    static func jsonData(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return data
    }

    /// Maps a lane error onto the frozen ABI status.
    private static func status(for error: DeviceWorkspaceLaneError) -> Int32 {
        switch error {
        case .invalidArguments: return DeviceWorkspaceBridgeStatus.invalid
        case .bufferTooSmall: return DeviceWorkspaceBridgeStatus.buffer
        case .unavailable: return DeviceWorkspaceBridgeStatus.unavailable
        case .fenced: return DeviceWorkspaceBridgeStatus.fenced
        case .sessionUnknown: return DeviceWorkspaceBridgeStatus.sessionUnknown
        case .notShared: return DeviceWorkspaceBridgeStatus.notShared
        case .conflict: return DeviceWorkspaceBridgeStatus.conflict
        case .oversized: return DeviceWorkspaceBridgeStatus.oversized
        case .busy: return DeviceWorkspaceBridgeStatus.busy
        case .ioFailure: return DeviceWorkspaceBridgeStatus.ioFailure
        }
    }

    // MARK: - Command dispatch

    /// The ONE command entry. `input` is the bounded UTF-8 JSON document;
    /// the reply (when any) is returned with a >= 0 byte length. Typed
    /// failures are the negative statuses — never a silent null, never a
    /// path/title/byte inside an error text.
    func command(operation: String, input: Data, replyCapacity: Int) -> (status: Int32, reply: Data) {
        guard replyCapacity >= 0, replyCapacity <= DeviceWorkspaceBridgeLimits.maximumReplyBytes else {
            return (DeviceWorkspaceBridgeStatus.buffer, Data())
        }
        let respond = { (object: [String: Any]) -> (Int32, Data) in
            guard let body = Self.jsonData(object) else { return (DeviceWorkspaceBridgeStatus.ioFailure, Data()) }
            guard body.count <= replyCapacity else { return (DeviceWorkspaceBridgeStatus.buffer, Data()) }
            return (Int32(body.count), body)
        }
        let empty = { () -> (Int32, Data) in (0, Data()) }

        lock.lock(); sweepStaleLocked(live: liveEpoch()); lock.unlock()

        switch operation {
        case "binding":
            return runBinding(input: input, respond: respond, receiveOnly: false)
        case "targetBinding":
            return runBinding(input: input, respond: respond, receiveOnly: true)
        case "sourceOpen":
            return runSourceOpen(input: input, respond: respond)
        case "targetOpen":
            return runTargetOpen(input: input, respond: respond)
        case "check":
            return runCheck(input: input, empty: empty)
        case "sourceVerify":
            return runSourceVerify(input: input, empty: empty)
        case "targetInfo":
            return runTargetInfo(input: input, respond: respond)
        case "targetDirectory":
            return runTargetDirectory(input: input, empty: empty)
        case "targetStage":
            return runTargetStage(input: input, respond: respond)
        case "targetCommit":
            return runTargetCommit(input: input, empty: empty)
        case "close":
            return runClose(input: input, empty: empty)
        default:
            lock.lock(); counters.refused += 1; lock.unlock()
            return (DeviceWorkspaceBridgeStatus.invalid, Data())
        }
    }

    // MARK: binding / targetBinding {epoch, taskID} -> {scope}

    private func runBinding(input: Data,
                            respond: ([String: Any]) -> (Int32, Data),
                            receiveOnly: Bool) -> (Int32, Data) {
        guard let object = Self.jsonObject(input),
              let epoch = Self.jsonUInt64(object["epoch"]),
              let taskID = Self.canonicalUUID(object["taskID"]) else {
            return (DeviceWorkspaceBridgeStatus.invalid, Data())
        }
        if let refused = admit(epoch: epoch) { return (refused, Data()) }
        let outcome = receiveOnly ? resolveTargetBinding(epoch: epoch, taskID: taskID)
                                  : resolveSource(epoch: epoch, taskID: taskID)
        guard case .binding(let binding) = outcome else {
            if case .failure(let status) = outcome { return (status, Data()) }
            return (DeviceWorkspaceBridgeStatus.ioFailure, Data())
        }
        if let refused = admit(epoch: epoch) { return (refused, Data()) }
        guard let pinned = pinnedScope(binding: binding) else {
            return (receiveOnly ? DeviceWorkspaceBridgeStatus.ioFailure : DeviceWorkspaceBridgeStatus.notShared, Data())
        }
        lock.lock(); counters.commands += 1; lock.unlock()
        return respond(["scope": pinned.scope])
    }

    // MARK: sourceOpen {epoch, taskID, scope} -> {ticket, manifestSize}

    private func runSourceOpen(input: Data,
                               respond: ([String: Any]) -> (Int32, Data)) -> (Int32, Data) {
        guard let object = Self.jsonObject(input),
              let epoch = Self.jsonUInt64(object["epoch"]),
              let taskID = Self.canonicalUUID(object["taskID"]),
              let scope = Self.jsonString(object["scope"], limit: 256) else {
            return (DeviceWorkspaceBridgeStatus.invalid, Data())
        }
        if let refused = admit(epoch: epoch) { return (refused, Data()) }
        guard case .binding(let binding) = resolveSource(epoch: epoch, taskID: taskID) else {
            return (DeviceWorkspaceBridgeStatus.notShared, Data())
        }
        guard let pinned = pinnedScope(binding: binding), pinned.scope == scope else {
            return (DeviceWorkspaceBridgeStatus.notShared, Data())
        }
        if let refused = admit(epoch: epoch) { return (refused, Data()) }
        lock.lock()
        guard liveSessionCountLocked() < DeviceWorkspaceBridgeLimits.maximumLiveSessions else {
            counters.refused += 1
            lock.unlock()
            return (DeviceWorkspaceBridgeStatus.busy, Data())
        }
        lock.unlock()
        let entries: [DeviceWorkspaceDirectory.Scanned]
        do {
            entries = try pinned.directory.scan()
        } catch let error as DeviceWorkspaceLaneError {
            return (Self.status(for: error), Data())
        } catch {
            return (DeviceWorkspaceBridgeStatus.ioFailure, Data())
        }
        let manifest = encodeManifest(entries.map(\.entry))
        guard let manifest else { return (DeviceWorkspaceBridgeStatus.oversized, Data()) }
        lock.lock()
        sweepStaleLocked(live: epoch)
        guard liveSessionCountLocked() < DeviceWorkspaceBridgeLimits.maximumLiveSessions else {
            counters.refused += 1
            lock.unlock()
            return (DeviceWorkspaceBridgeStatus.busy, Data())
        }
        let ticket = newTicketLocked()
        sources[ticket] = DeviceWorkspaceSourceSession(
            ticket: ticket, createdEpoch: epoch, taskID: taskID, workspaceID: binding.workspaceID,
            scope: pinned.scope, directory: pinned.directory, entries: entries, manifest: manifest)
        counters.commands += 1
        lock.unlock()
        return respond(["ticket": ticket, "manifestSize": manifest.count])
    }

    // MARK: targetOpen {epoch, taskID, scope} -> {ticket}

    private func runTargetOpen(input: Data,
                               respond: ([String: Any]) -> (Int32, Data)) -> (Int32, Data) {
        guard let object = Self.jsonObject(input),
              let epoch = Self.jsonUInt64(object["epoch"]),
              let taskID = Self.canonicalUUID(object["taskID"]),
              let scope = Self.jsonString(object["scope"], limit: 256) else {
            return (DeviceWorkspaceBridgeStatus.invalid, Data())
        }
        if let refused = admit(epoch: epoch) { return (refused, Data()) }
        guard case .binding(let binding) = resolveTarget(epoch: epoch, taskID: taskID) else {
            return (DeviceWorkspaceBridgeStatus.notShared, Data())
        }
        guard let pinned = pinnedScope(binding: binding), pinned.scope == scope else {
            return (DeviceWorkspaceBridgeStatus.notShared, Data())
        }
        if let refused = admit(epoch: epoch) { return (refused, Data()) }
        lock.lock()
        sweepStaleLocked(live: epoch)
        guard liveSessionCountLocked() < DeviceWorkspaceBridgeLimits.maximumLiveSessions else {
            counters.refused += 1
            lock.unlock()
            return (DeviceWorkspaceBridgeStatus.busy, Data())
        }
        let ticket = newTicketLocked()
        targets[ticket] = DeviceWorkspaceTargetSession(
            ticket: ticket, createdEpoch: epoch, taskID: taskID, workspaceID: binding.workspaceID,
            scope: pinned.scope, directory: pinned.directory)
        counters.commands += 1
        lock.unlock()
        return respond(["ticket": ticket])
    }

    // MARK: Session lookup helpers (lock discipline: never hold across hops)

    private enum SessionRef {
        case source(DeviceWorkspaceSourceSession)
        case target(DeviceWorkspaceTargetSession)
        case stage(DeviceWorkspaceStageSession)
    }

    private enum SessionLookup {
        case found(SessionRef)
        case missing(Int32)
    }

    private func sessionLocked(_ ticket: Int64) -> SessionLookup {
        if let session = sources[ticket] { return .found(.source(session)) }
        if let session = targets[ticket] { return .found(.target(session)) }
        if let session = stages[ticket] { return .found(.stage(session)) }
        return .missing(missingSessionStatusLocked(ticket))
    }

    private func sessionTicket(_ object: [String: Any]) -> Int64? {
        Self.jsonInt64(object["ticket"]).flatMap { $0 > 0 ? $0 : nil }
    }

    // MARK: check {ticket} -> {}

    private func runCheck(input: Data,
                          empty: () -> (Int32, Data)) -> (Int32, Data) {
        guard let object = Self.jsonObject(input),
              let ticket = sessionTicket(object) else {
            return (DeviceWorkspaceBridgeStatus.invalid, Data())
        }
        lock.lock()
        switch sessionLocked(ticket) {
        case .missing(let status):
            lock.unlock()
            return (status, Data())
        case .found(let ref):
            lock.unlock()
            switch ref {
            case .source(let session):
                if let refused = admit(epoch: session.createdEpoch) { return (refused, Data()) }
                guard case .binding(let binding) = resolveSource(epoch: session.createdEpoch,
                                                                 taskID: session.taskID),
                      binding.workspaceID == session.workspaceID else {
                    return (DeviceWorkspaceBridgeStatus.conflict, Data())
                }
                guard let pinned = pinnedScope(binding: binding), pinned.scope == session.scope else {
                    return (DeviceWorkspaceBridgeStatus.conflict, Data())
                }
                do {
                    try session.directory.validateVisibleRoot()
                } catch let error as DeviceWorkspaceLaneError {
                    return (Self.status(for: error), Data())
                } catch {
                    return (DeviceWorkspaceBridgeStatus.ioFailure, Data())
                }
            case .target(let session):
                if let refused = admit(epoch: session.createdEpoch) { return (refused, Data()) }
                guard case .binding(let binding) = resolveTarget(epoch: session.createdEpoch,
                                                                 taskID: session.taskID),
                      binding.workspaceID == session.workspaceID else {
                    return (DeviceWorkspaceBridgeStatus.conflict, Data())
                }
                guard let pinned = pinnedScope(binding: binding), pinned.scope == session.scope else {
                    return (DeviceWorkspaceBridgeStatus.conflict, Data())
                }
                do {
                    try session.directory.validateVisibleRoot()
                } catch let error as DeviceWorkspaceLaneError {
                    return (Self.status(for: error), Data())
                } catch {
                    return (DeviceWorkspaceBridgeStatus.ioFailure, Data())
                }
            case .stage(let session):
                if let refused = admit(epoch: session.createdEpoch) { return (refused, Data()) }
                do {
                    try session.owner.directory.validateVisibleRoot()
                } catch let error as DeviceWorkspaceLaneError {
                    return (Self.status(for: error), Data())
                } catch {
                    return (DeviceWorkspaceBridgeStatus.ioFailure, Data())
                }
            }
            lock.lock(); counters.commands += 1; lock.unlock()
            return empty()
        }
    }

    // MARK: sourceVerify {ticket, index} -> {}

    private func runSourceVerify(input: Data,
                                 empty: () -> (Int32, Data)) -> (Int32, Data) {
        guard let object = Self.jsonObject(input),
              let ticket = sessionTicket(object),
              let index = Self.jsonInt(object["index"]), index >= 0 else {
            return (DeviceWorkspaceBridgeStatus.invalid, Data())
        }
        lock.lock()
        guard let source = sources[ticket] else {
            let status = missingSessionStatusLocked(ticket)
            lock.unlock()
            return (status, Data())
        }
        lock.unlock()
        if let refused = admit(epoch: source.createdEpoch) { return (refused, Data()) }
        guard index < source.entries.count else {
            return (DeviceWorkspaceBridgeStatus.invalid, Data())
        }
        do {
            try source.directory.validateVisibleRoot()
            try source.directory.verify(source.entries[index])
        } catch let error as DeviceWorkspaceLaneError {
            lock.lock(); counters.conflicts += 1; lock.unlock()
            return (Self.status(for: error), Data())
        } catch {
            return (DeviceWorkspaceBridgeStatus.ioFailure, Data())
        }
        lock.lock(); counters.commands += 1; lock.unlock()
        return empty()
    }

    // MARK: targetInfo {ticket, path, conflictDigest?} -> {kind, digest?}

    private func runTargetInfo(input: Data,
                               respond: ([String: Any]) -> (Int32, Data)) -> (Int32, Data) {
        guard let object = Self.jsonObject(input),
              let ticket = sessionTicket(object),
              let path = Self.jsonString(object["path"], limit: 1_024) else {
            return (DeviceWorkspaceBridgeStatus.invalid, Data())
        }
        let conflictDigest = Self.jsonDigest(object["conflictDigest"])
        lock.lock()
        guard let target = targets[ticket] else {
            let status = missingSessionStatusLocked(ticket)
            lock.unlock()
            return (status, Data())
        }
        lock.unlock()
        if let refused = admit(epoch: target.createdEpoch) { return (refused, Data()) }
        let kind: DeviceWorkspaceDirectory.TargetKind
        do {
            try target.directory.validateVisibleRoot()
            kind = try target.directory.targetKind(at: path, conflictDigest: conflictDigest)
        } catch let error as DeviceWorkspaceLaneError {
            lock.lock(); counters.conflicts += 1; lock.unlock()
            return (Self.status(for: error), Data())
        } catch {
            return (DeviceWorkspaceBridgeStatus.ioFailure, Data())
        }
        lock.lock(); counters.commands += 1; lock.unlock()
        switch kind {
        case .missing:
            return respond(["kind": "missing"])
        case .directory:
            return respond(["kind": "directory"])
        case .file(let digest):
            return respond(["kind": "file", "digest": digest])
        case .blocked:
            lock.lock(); counters.conflicts += 1; lock.unlock()
            return (DeviceWorkspaceBridgeStatus.conflict, Data())
        }
    }

    // MARK: targetDirectory {ticket, path} -> {}

    private func runTargetDirectory(input: Data,
                                    empty: () -> (Int32, Data)) -> (Int32, Data) {
        guard let object = Self.jsonObject(input),
              let ticket = sessionTicket(object),
              let path = Self.jsonString(object["path"], limit: 1_024) else {
            return (DeviceWorkspaceBridgeStatus.invalid, Data())
        }
        // Optional deterministic conflict copy (frozen donor parity): a
        // directory entry has no content digest, so the conflict location
        // is scoped by the SHA-256 of the raw UTF-8 original path and the
        // SAME chain is created under it. A digest that does not equal that
        // value is invalid — the remote never chooses the directory.
        let conflictDigest = Self.jsonDigest(object["conflictDigest"])
        lock.lock()
        guard let target = targets[ticket] else {
            let status = missingSessionStatusLocked(ticket)
            lock.unlock()
            return (status, Data())
        }
        lock.unlock()
        if let refused = admit(epoch: target.createdEpoch) { return (refused, Data()) }
        if let conflictDigest, conflictDigest != DeviceWorkspaceDigest.pathDigest(path) {
            return (DeviceWorkspaceBridgeStatus.invalid, Data())
        }
        guard case .binding(let binding) = resolveTarget(epoch: target.createdEpoch, taskID: target.taskID),
              binding.workspaceID == target.workspaceID,
              let pinned = pinnedScope(binding: binding), pinned.scope == target.scope else {
            return (DeviceWorkspaceBridgeStatus.conflict, Data())
        }
        do {
            try target.directory.createDirectory(at: path, conflictDigest: conflictDigest)
        } catch let error as DeviceWorkspaceLaneError {
            lock.lock(); counters.conflicts += 1; lock.unlock()
            return (Self.status(for: error), Data())
        } catch {
            return (DeviceWorkspaceBridgeStatus.ioFailure, Data())
        }
        lock.lock(); counters.commands += 1; lock.unlock()
        return empty()
    }

    // MARK: targetStage {ticket} -> {ticket}

    private func runTargetStage(input: Data,
                                respond: ([String: Any]) -> (Int32, Data)) -> (Int32, Data) {
        guard let object = Self.jsonObject(input),
              let ticket = sessionTicket(object) else {
            return (DeviceWorkspaceBridgeStatus.invalid, Data())
        }
        lock.lock()
        guard let target = targets[ticket] else {
            let status = missingSessionStatusLocked(ticket)
            lock.unlock()
            return (status, Data())
        }
        lock.unlock()
        if let refused = admit(epoch: target.createdEpoch) { return (refused, Data()) }
        // Validate the current binding again before appending staged bytes.
        guard case .binding(let binding) = resolveTarget(epoch: target.createdEpoch, taskID: target.taskID),
              binding.workspaceID == target.workspaceID else {
            return (DeviceWorkspaceBridgeStatus.conflict, Data())
        }
        guard let pinned = pinnedScope(binding: binding), pinned.scope == target.scope else {
            return (DeviceWorkspaceBridgeStatus.conflict, Data())
        }
        let staged: DeviceWorkspaceDirectory.StagedFile
        do {
            staged = try target.directory.stage()
        } catch let error as DeviceWorkspaceLaneError {
            return (Self.status(for: error), Data())
        } catch {
            return (DeviceWorkspaceBridgeStatus.ioFailure, Data())
        }
        lock.lock()
        sweepStaleLocked(live: target.createdEpoch)
        guard liveSessionCountLocked() < DeviceWorkspaceBridgeLimits.maximumLiveSessions else {
            counters.refused += 1
            lock.unlock()
            return (DeviceWorkspaceBridgeStatus.busy, Data())
        }
        let stageTicket = newTicketLocked()
        stages[stageTicket] = DeviceWorkspaceStageSession(
            ticket: stageTicket, createdEpoch: target.createdEpoch, owner: target, staged: staged)
        counters.commands += 1
        lock.unlock()
        return respond(["ticket": stageTicket])
    }

    // MARK: targetCommit {ticket, path, digest, size, expectedDigest?, conflictDigest?} -> {}

    private func runTargetCommit(input: Data,
                                 empty: () -> (Int32, Data)) -> (Int32, Data) {
        guard let object = Self.jsonObject(input),
              let ticket = sessionTicket(object),
              let path = Self.jsonString(object["path"], limit: 1_024),
              let digest = Self.jsonDigest(object["digest"]),
              let size = Self.jsonInt64(object["size"]), size >= 0 else {
            return (DeviceWorkspaceBridgeStatus.invalid, Data())
        }
        let expectedDigest = Self.jsonDigest(object["expectedDigest"])
        let conflictDigest = Self.jsonDigest(object["conflictDigest"])
        guard expectedDigest == nil || conflictDigest == nil else {
            // Exclusive-create and scoped-conflict commits are distinct
            // contracts; a document claiming both is invalid.
            return (DeviceWorkspaceBridgeStatus.invalid, Data())
        }
        lock.lock()
        guard let stage = stages[ticket] else {
            let status = missingSessionStatusLocked(ticket)
            lock.unlock()
            return (status, Data())
        }
        lock.unlock()
        if let refused = admit(epoch: stage.createdEpoch) { return (refused, Data()) }
        // Seal first: staged length + SHA must equal the declared wire
        // version exactly. Nothing is renamed on mismatch.
        do {
            try stage.staged.seal(size: size, digest: digest)
        } catch let error as DeviceWorkspaceLaneError {
            lock.lock(); counters.conflicts += 1; lock.unlock()
            return (Self.status(for: error), Data())
        } catch {
            return (DeviceWorkspaceBridgeStatus.ioFailure, Data())
        }
        // Validate the current binding again before the rename.
        guard case .binding(let binding) = resolveTarget(epoch: stage.createdEpoch,
                                                         taskID: stage.owner.taskID),
              binding.workspaceID == stage.owner.workspaceID else {
            return (DeviceWorkspaceBridgeStatus.conflict, Data())
        }
        guard let pinned = pinnedScope(binding: binding), pinned.scope == stage.owner.scope else {
            return (DeviceWorkspaceBridgeStatus.conflict, Data())
        }
        do {
            try stage.owner.directory.commit(stage.staged, path: path, replacingDigest: expectedDigest,
                                             conflictDigest: conflictDigest)
        } catch let error as DeviceWorkspaceLaneError {
            lock.lock(); counters.conflicts += 1; lock.unlock()
            return (Self.status(for: error), Data())
        } catch {
            return (DeviceWorkspaceBridgeStatus.ioFailure, Data())
        }
        lock.lock(); counters.commands += 1; lock.unlock()
        return empty()
    }

    // MARK: close {ticket} -> {} (idempotent for source/target/stage)

    private func runClose(input: Data,
                          empty: () -> (Int32, Data)) -> (Int32, Data) {
        guard let object = Self.jsonObject(input),
              let ticket = sessionTicket(object) else {
            return (DeviceWorkspaceBridgeStatus.invalid, Data())
        }
        lock.lock()
        if sources.removeValue(forKey: ticket) != nil
            || targets.removeValue(forKey: ticket) != nil
            || stages.removeValue(forKey: ticket) != nil {
            retireLocked(ticket)
            counters.commands += 1
            lock.unlock()
            return empty()
        }
        let status = missingSessionStatusLocked(ticket)
        counters.refused += 1
        lock.unlock()
        // Idempotent for an already-closed KNOWN ticket; unknown stays typed.
        return (status == DeviceWorkspaceBridgeStatus.fenced ? 0 : status, Data())
    }

    // MARK: - Streaming

    /// Source byte egress: index -1 is the manifest, >= 0 a prepared file
    /// entry. Returns bytes copied (0 = EOF at the exact end) or a typed
    /// negative status. Every call rechecks the epoch, the pinned root
    /// identity and the snapshot stamp around the read.
    func read(ticket: Int64, index: Int, offset: Int64, capacity: Int) -> (status: Int32, bytes: Data) {
        guard capacity > 0, capacity <= DeviceWorkspaceBridgeLimits.maximumChunkBytes, offset >= 0 else {
            return (DeviceWorkspaceBridgeStatus.invalid, Data())
        }
        lock.lock()
        guard let session = sources[ticket] else {
            let status = missingSessionStatusLocked(ticket)
            lock.unlock()
            return (status, Data())
        }
        lock.unlock()
        if let refused = admit(epoch: session.createdEpoch) { return (refused, Data()) }
        if index == -1 {
            let manifest = session.manifest
            guard offset <= manifest.count else { return (DeviceWorkspaceBridgeStatus.conflict, Data()) }
            let end = min(manifest.count, Int(offset) + capacity)
            guard end > Int(offset) else { return (0, Data()) }
            lock.lock(); counters.reads += 1; lock.unlock()
            return (Int32(end - Int(offset)), manifest.subdata(in: Int(offset)..<end))
        }
        guard index < session.entries.count,
              session.entries[index].entry.kind == .file else {
            return (DeviceWorkspaceBridgeStatus.invalid, Data())
        }
        let size = session.entries[index].entry.size ?? 0
        guard offset <= size else { return (DeviceWorkspaceBridgeStatus.conflict, Data()) }
        guard offset < size else { return (0, Data()) }
        let count = Int(min(Int64(capacity), size - offset))
        do {
            let bytes = try session.directory.read(session.entries[index], offset: offset, count: count)
            lock.lock(); counters.reads += 1; lock.unlock()
            return (Int32(bytes.count), bytes)
        } catch let error as DeviceWorkspaceLaneError {
            lock.lock(); counters.conflicts += 1; lock.unlock()
            return (Self.status(for: error), Data())
        } catch {
            return (DeviceWorkspaceBridgeStatus.ioFailure, Data())
        }
    }

    /// Target byte ingress: one bounded staged append. Returns 0 on
    /// success; the aggregate can never exceed the 1 GiB file ceiling.
    func write(ticket: Int64, bytes: Data) -> Int32 {
        lock.lock()
        guard let session = stages[ticket] else {
            let status = missingSessionStatusLocked(ticket)
            lock.unlock()
            return status
        }
        lock.unlock()
        guard !bytes.isEmpty, bytes.count <= DeviceWorkspaceBridgeLimits.maximumChunkBytes else {
            return DeviceWorkspaceBridgeStatus.invalid
        }
        if let refused = admit(epoch: session.createdEpoch) { return refused }
        do {
            try session.owner.directory.validateVisibleRoot()
            try session.staged.append(bytes)
        } catch let error as DeviceWorkspaceLaneError {
            return Self.status(for: error)
        } catch {
            return DeviceWorkspaceBridgeStatus.ioFailure
        }
        lock.lock(); counters.writes += 1; lock.unlock()
        return 0
    }

    // MARK: - Manifest encoding

    /// Exact wire shape `{"entries":[{path,kind,size?,digest?}]}`; Kotlin
    /// re-validates the document before it is sent.
    private func encodeManifest(_ entries: [DeviceWorkspaceEntry]) -> Data? {
        guard entries.count <= DeviceWorkspaceManifest.maximumEntries else { return nil }
        var total: Int64 = 0
        var rows: [[String: Any]] = []
        rows.reserveCapacity(entries.count)
        for entry in entries {
            var row: [String: Any] = ["path": entry.path, "kind": entry.kind.rawValue]
            if let size = entry.size {
                guard size >= 0, size <= DeviceWorkspaceManifest.maximumFileBytes,
                      size <= DeviceWorkspaceManifest.maximumTotalBytes - total else { return nil }
                total += size
                row["size"] = size
            }
            if let digest = entry.digest { row["digest"] = digest }
            rows.append(row)
        }
        guard let body = Self.jsonData(["entries": rows]),
              body.count <= DeviceWorkspaceManifest.maximumManifestBytes else { return nil }
        return body
    }
}

// MARK: - Trusted-host C ABI (`floe_device_workspace_*`; Kotlin JNI only)

private func deviceWorkspaceReadInput(_ pointer: UnsafePointer<UInt8>?, _ length: Int32) -> Data? {
    guard length > 0, length <= DeviceWorkspaceBridgeLimits.maximumInputBytes,
          let pointer else { return nil }
    return Data(bytes: pointer, count: Int(length))
}

/// Bounded UTF-8 JSON command. Non-negative = written reply length (0 for
/// empty success); negative = typed status. Never model-reachable.
@_cdecl("floe_device_workspace_command")
public func floeDeviceWorkspaceCommand(
    _ operation: UnsafePointer<CChar>?,
    _ input: UnsafePointer<UInt8>?, _ inputLength: Int32,
    _ reply: UnsafeMutablePointer<CChar>?, _ replyCapacity: Int32
) -> Int32 {
    guard let operation else { return DeviceWorkspaceBridgeStatus.invalid }
    let name = String(cString: operation)
    guard name.utf8.count <= 32 else { return DeviceWorkspaceBridgeStatus.invalid }
    let request: Data
    if inputLength == 0 {
        request = Data()
    } else {
        guard let data = deviceWorkspaceReadInput(input, inputLength) else {
            return DeviceWorkspaceBridgeStatus.invalid
        }
        request = data
    }
    let outcome = DeviceWorkspaceBridgeFacade.shared.command(
        operation: name, input: request, replyCapacity: Int(replyCapacity))
    guard outcome.status >= 0 else { return outcome.status }
    guard outcome.status > 0 else { return 0 }
    guard let reply, Int32(outcome.reply.count) <= replyCapacity else {
        return DeviceWorkspaceBridgeStatus.buffer
    }
    outcome.reply.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        memcpy(reply, base, outcome.reply.count)
    }
    reply[outcome.reply.count] = 0
    return Int32(outcome.reply.count)
}

/// Copies one <= 64 KiB page out of a prepared source session (index -1
/// manifest, >= 0 file). Returns copied length, 0 EOF, or a typed status.
@_cdecl("floe_device_workspace_read")
public func floeDeviceWorkspaceRead(
    _ ticket: Int64, _ index: Int32, _ offset: Int64,
    _ target: UnsafeMutablePointer<UInt8>?, _ capacity: Int32
) -> Int32 {
    guard capacity > 0 else { return DeviceWorkspaceBridgeStatus.invalid }
    let outcome = DeviceWorkspaceBridgeFacade.shared.read(
        ticket: ticket, index: Int(index), offset: offset, capacity: Int(capacity))
    guard outcome.status >= 0, outcome.status > 0 else { return outcome.status }
    guard let target else { return DeviceWorkspaceBridgeStatus.invalid }
    outcome.bytes.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        memcpy(target, base, outcome.bytes.count)
    }
    return outcome.status
}

/// Appends one bounded chunk to a target stage session; 0 ok, <0 typed.
@_cdecl("floe_device_workspace_write")
public func floeDeviceWorkspaceWrite(
    _ ticket: Int64, _ source: UnsafePointer<UInt8>?, _ length: Int32
) -> Int32 {
    guard length > 0, length <= DeviceWorkspaceBridgeLimits.maximumChunkBytes,
          let source else { return DeviceWorkspaceBridgeStatus.invalid }
    return DeviceWorkspaceBridgeFacade.shared.write(
        ticket: ticket, bytes: Data(bytes: source, count: Int(length)))
}
