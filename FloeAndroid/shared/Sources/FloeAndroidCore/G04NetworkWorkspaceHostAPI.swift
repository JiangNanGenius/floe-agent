// SPDX-License-Identifier: MPL-2.0
//
// G04-R1 trusted NETWORK WORKSPACE HOST — the narrow private C ABI the App's
// NetworkWorkspaceHostController calls to drive the REAL network source
// owner (`G04NetworkWorkspace`) over the ORIGINAL authorities. Like the
// accepted provider source host, model/tool/bridge payloads have NO route
// here: only the trusted JNI host lane, always epoch-exact.
//
// Owned here:
//   * epoch-exact owner resolution (`G04NetworkWorkspaceHostRegistry`);
//     a stale generation can never advance a newer owner or read its
//     tickets — every call re-answers from the CURRENT live root epoch;
//   * RAM credential staging hand-off into the owner's lease (opaque
//     positive tickets; bytes cross exactly once and never come back);
//   * bounded synchronous actor hops onto the owner with the SAME typed
//     outcomes (metadata/grammar: short budget; probe/browse/stat IO: IO
//     budget; a hop timeout is a typed answer, the physical IO keeps its
//     own settlement path — no fabricated detach);
//   * operation ticket mapping (opaque Int64 -> (epoch, native op id)) with
//     a stale-generation sweep; and
//   * JSON reply construction: metadata-only views, redacted endpoints,
//     closed errorCode tokens. No secret bytes, no vault internals, no
//     paths outside logical/remote views ever leave this file.
//
// Status space (JNI-visible; network-host-owned -6xx; additive and DISJOINT
// from the shared -105/-106 shape rules, gateway -1xx, runtime-owner -2xx,
// attachment -3xx, skills-folder -4xx and source-host -5xx).
import Foundation
import FloeCore
import FloePersistence
import FloeTools
import FloeWorkspace

public enum G04NetworkHostStatus {
    public static let ok: Int32 = 0
    public static let invalidArguments: Int32 = -105   // shared shape rule
    public static let bufferTooSmall: Int32 = -106     // shared ASCII-copy rule
    public static let notInstalled: Int32 = -601       // no live root generation
    public static let generationFenced: Int32 = -602   // epoch/op belongs to another generation
    public static let sessionUnknown: Int32 = -603     // op/credential ticket unknown or swept
    public static let stateConflict: Int32 = -604      // ladder/op grammar (close live op etc.)
    public static let identityRefused: Int32 = -605    // durable conversation/workspace revalidation failed
    public static let mountUnknown: Int32 = -606
    public static let pathRefused: Int32 = -607        // config/remote/logical path grammar
    public static let providerFailed: Int32 = -608     // typed provider verdict retained in the reply
    public static let credentialRefused: Int32 = -609  // lease/vault refusal token (no bytes)
    public static let saturated: Int32 = -610
    public static let hopTimeout: Int32 = -611
    public static let diskFull: Int32 = -612
    public static let sizeExceeded: Int32 = -613
    public static let transitionRefused: Int32 = -614
    public static let `internal`: Int32 = -699
}

public enum G04NetworkHostLimits {
    public static let maximumReplyBytes = 32 * 1024
    public static let maximumRowsPerPage = 32
    public static let maximumLiveOperationTickets = 64
    public static let shortHopSeconds = 30      // metadata / registration hops
    public static let ioHopSeconds = 120        // probe / browse / stat hops
}

// MARK: - Host

final class NetworkHostHopBox<Value>: @unchecked Sendable {
    var value: Result<Value, any Error>?
}

final class G04NetworkWorkspaceHost: @unchecked Sendable {
    static let shared = G04NetworkWorkspaceHost()

    private let lock = NSLock()
    private var counter: Int64 = 0
    private var opTickets: [Int64: (epoch: UInt64, id: UInt64)] = [:]
    private var retiredTickets: Set<Int64> = []
    private var retiredOrder: [Int64] = []
    private var counters = (hops: 0, hopsTimedOut: 0, refused: 0, fenced: 0, saturated: 0,
                            opsStarted: 0, opsSettled: 0, opsCancelled: 0,
                            credStaged: 0, credRefused: 0, browsePages: 0)

    /// Trusted fixture seams (same-module only; the accepted source-host
    /// pattern). Tests drive the exact ABI grammar without installing a
    /// full G02 generation; production never writes these.
    internal var liveEpochOverrideForTesting: UInt64?
    internal var ownerOverrideForTesting: G04NetworkWorkspace?

    private init() {}

    // MARK: epoch truth (never the caller's claim)

    private func liveEpoch() -> UInt64? {
        if let override = liveEpochOverrideForTesting { return override }
        return G02NativeRootEpoch.readback()
    }

    /// Owner/generation resolution ONLY. Entry points keep the documented
    /// refusal precedence as TWO guards (host cohort D5, accepted vocabulary
    /// table lines 36/39): generation first — `epoch == 0` answers
    /// notInstalled, a foreign live root answers generationFenced (-602);
    /// shared argument SHAPE answers invalidArguments (-105) — never the
    /// reverse. Compound `resolveOwner + canonicalUUID/boundedUTF8` guards
    /// previously collapsed the two classes on both sides of the family;
    /// every site now follows credStage's original split.
    private func resolveOwner(epoch: UInt64) -> G04NetworkWorkspace? {
        if let override = ownerOverrideForTesting {
            return liveEpoch() == epoch ? override : nil
        }
        guard liveEpoch() == epoch else { return nil }
        return G04NetworkWorkspaceHostRegistry.shared.owner(epoch: epoch)
    }

    // MARK: grammar

    static func canonicalUUID(_ raw: String?) -> UUID? {
        guard let raw, !raw.isEmpty, let value = UUID(uuidString: raw) else { return nil }
        return value.uuidString.caseInsensitiveCompare(raw) == .orderedSame ? value : nil
    }

    private func status(for error: any Error) -> Int32 {
        if let typed = error as? G04NetworkWorkspaceError {
            switch typed {
            case .retired: return G04NetworkHostStatus.generationFenced
            case .identityRefused: return G04NetworkHostStatus.identityRefused
            case .mountUnknown: return G04NetworkHostStatus.mountUnknown
            case .configurationRefused, .remotePathRefused: return G04NetworkHostStatus.pathRefused
            case .credentialRefused: return G04NetworkHostStatus.credentialRefused
            case .provider: return G04NetworkHostStatus.providerFailed
            case .tooLarge: return G04NetworkHostStatus.sizeExceeded
            case .transitionRefused: return G04NetworkHostStatus.transitionRefused
            case .operationUnknown: return G04NetworkHostStatus.sessionUnknown
            case .diskFull: return G04NetworkHostStatus.diskFull
            }
        }
        if error is CancellationError { return G04NetworkHostStatus.hopTimeout }
        return G04NetworkHostStatus.internal
    }

    private func errorCodeToken(_ error: any Error) -> String {
        if let typed = error as? G04NetworkWorkspaceError {
            switch typed {
            case .retired: return "retired"
            case .identityRefused: return "identityRefused"
            case .mountUnknown: return "mountUnknown"
            case let .configurationRefused(token): return "config.\(token)"
            case let .remotePathRefused(token): return "path.\(token)"
            case let .credentialRefused(token): return token
            case let .provider(code, _): return code
            case .tooLarge: return "sizeExceeded"
            case let .transitionRefused(token): return token
            case .operationUnknown: return "operationUnknown"
            case .diskFull: return "diskFull"
            }
        }
        return "internal"
    }

    private func errorRetryable(_ error: any Error) -> Bool {
        if let typed = error as? G04NetworkWorkspaceError, case .provider(_, let retryable) = typed {
            return retryable
        }
        return false
    }

    // MARK: bounded hop

    private enum HopOutcome<Value> { case success(Value), failure(any Error), timeout }

    private func hop<Value>(seconds: Int, owner: G04NetworkWorkspace,
                            after: @escaping @Sendable (G04NetworkWorkspace) async throws -> Value)
        -> HopOutcome<Value> {
        let box = NetworkHostHopBox<Value>()
        let gate = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do { box.value = .success(try await after(owner)) }
            catch { box.value = .failure(error) }
            gate.signal()
        }
        if gate.wait(timeout: .now() + .seconds(seconds)) == .timedOut {
            lock.lock(); counters.hopsTimedOut += 1; lock.unlock()
            return .timeout
        }
        lock.lock(); counters.hops += 1; lock.unlock()
        switch box.value {
        case .success(let value): return .success(value)
        case .failure(let error): return .failure(error)
        case .none: return .failure(G04NetworkWorkspaceError.transitionRefused("hop"))
        }
    }

    // MARK: ticket plumbing

    private func issueOpTicket(epoch: UInt64, id: UInt64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let swept = opTickets.values.filter { $0.epoch != epoch }.count
        if swept > 0 {
            for (ticket, value) in opTickets where value.epoch != epoch {
                opTickets.removeValue(forKey: ticket)
                retiredTickets.insert(ticket)
                retiredOrder.append(ticket)
                while retiredOrder.count > 512 { retiredTickets.remove(retiredOrder.removeFirst()) }
            }
        }
        guard opTickets.count < G04NetworkHostLimits.maximumLiveOperationTickets else {
            counters.saturated += 1
            return Int64(G04NetworkHostStatus.saturated)
        }
        counter &+= 1
        if counter <= 0 { counter = 1 }
        opTickets[counter] = (epoch, id)
        counters.opsStarted += 1
        return counter
    }

    private func lookupOp(_ ticket: Int64) -> (epoch: UInt64, id: UInt64)? {
        lock.lock(); defer { lock.unlock() }
        return opTickets[ticket]
    }

    private func isRetired(_ ticket: Int64) -> Bool {
        lock.withLock { retiredTickets.contains(ticket) }
    }

    private func releaseOp(_ ticket: Int64) {
        lock.lock(); defer { lock.unlock() }
        opTickets.removeValue(forKey: ticket)
    }

    // MARK: - Credential staging (RAM, one-shot)

    func credStage(epoch: UInt64, data: Data) -> Int64 {
        guard let owner = resolveOwner(epoch: epoch) else {
            lock.lock(); counters.credRefused += 1; lock.unlock()
            return epoch == 0 ? Int64(G04NetworkHostStatus.notInstalled)
                              : Int64(G04NetworkHostStatus.generationFenced)
        }
        guard !data.isEmpty, data.count <= SecretGatewayLimits.maximumSecretBytes else {
            lock.lock(); counters.credRefused += 1; lock.unlock()
            return Int64(G04NetworkHostStatus.invalidArguments)
        }
        switch hop(seconds: G04NetworkHostLimits.shortHopSeconds, owner: owner,
                   after: { await $0.stageCredential(data) }) {
        case .success(let ticket):
            lock.lock()
            if ticket > 0 { counters.credStaged += 1 } else { counters.credRefused += 1 }
            lock.unlock()
            if ticket > 0 { return ticket }
            return ticket == -1 ? Int64(G04NetworkHostStatus.generationFenced)
                                : Int64(G04NetworkHostStatus.invalidArguments)
        case .failure: return Int64(G04NetworkHostStatus.internal)
        case .timeout: return Int64(G04NetworkHostStatus.hopTimeout)
        }
    }

    func credAbort(ticket: Int64) -> Int32 {
        guard ticket > 0 else { return G04NetworkHostStatus.invalidArguments }
        guard let owner = G04NetworkWorkspaceHostRegistry.shared.currentOwner else {
            return G04NetworkHostStatus.notInstalled
        }
        switch hop(seconds: G04NetworkHostLimits.shortHopSeconds, owner: owner,
                   after: { await $0.abortCredentialStage(ticket) }) {
        case .success(let done): return done ? G04NetworkHostStatus.ok : G04NetworkHostStatus.sessionUnknown
        case .failure: return G04NetworkHostStatus.internal
        case .timeout: return G04NetworkHostStatus.hopTimeout
        }
    }

    // MARK: - Mount configuration

    func mountPage(epoch: UInt64, taskHex: String, workspaceHex: String,
                   buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        guard let owner = resolveOwner(epoch: epoch) else {
            return Int32(epoch == 0 ? G04NetworkHostStatus.notInstalled
                                    : G04NetworkHostStatus.generationFenced)
        }
        guard let taskID = Self.canonicalUUID(taskHex),
              let workspaceID = Self.canonicalUUID(workspaceHex) else {
            return Int32(G04NetworkHostStatus.invalidArguments)
        }
        switch hop(seconds: G04NetworkHostLimits.shortHopSeconds, owner: owner,
                   after: { try await $0.mounts(taskID: taskID, workspaceID: workspaceID) }) {
        case .success(let views):
            var objects: [[String: Any]] = []
            var used = 64
            for view in views {
                let object: [String: Any] = [
                    "id": view.id.uuidString, "name": view.name, "transport": view.transport,
                    "endpoint": view.endpoint, "rootPath": view.rootPath,
                    "username": view.username, "readOnly": view.readOnly ? 1 : 0,
                    "status": view.status,
                ]
                let size = Self.json(object).utf8.count + 2
                guard used + size <= min(Int(capacity), G04NetworkHostLimits.maximumReplyBytes) else {
                    return G04NetworkHostStatus.bufferTooSmall
                }
                used += size
                objects.append(object)
            }
            return Self.copy(Self.json(["ok": 1, "rows": objects]), buffer: buffer, capacity: capacity)
        case .failure(let error): return Int32(status(for: error))
        case .timeout: return Int32(G04NetworkHostStatus.hopTimeout)
        }
    }

    private func mountDraft(taskHex: String, workspaceHex: String, mountHex: String?,
                            name: String, transport: String, endpoint: String,
                            rootPath: String, username: String, readOnly: Int32,
                            credentialTicket: Int64) -> (UUID, UUID, G04NetworkMountDraft)? {
        guard let taskID = Self.canonicalUUID(taskHex),
              let workspaceID = Self.canonicalUUID(workspaceHex) else { return nil }
        guard transport == "webdav" || transport == "smb" else { return nil }
        guard !endpoint.isEmpty, let url = URL(string: endpoint) else { return nil }
        let mountID: UUID?
        if let mountHex, !mountHex.isEmpty {
            guard let parsed = Self.canonicalUUID(mountHex) else { return nil }
            mountID = parsed
        } else { mountID = nil }
        guard Self.boundedUTF8(name, limit: 128) != nil,
              Self.boundedUTF8(endpoint, limit: 4096) != nil,
              Self.boundedUTF8(rootPath, limit: 4096) != nil,
              Self.boundedUTF8(username, limit: 256) != nil else { return nil }
        return (taskID, workspaceID, G04NetworkMountDraft(
            mountID: mountID, name: name, transport: transport == "smb" ? .smb : .webDAV,
            endpoint: url, rootPath: rootPath, username: username,
            readOnly: readOnly != 0, credentialTicket: credentialTicket))
    }

    static func boundedUTF8(_ text: String, limit: Int) -> String? {
        text.utf8.count <= limit ? text : nil
    }

    func mountAdd(epoch: UInt64, taskHex: String, workspaceHex: String, mountHex: String?,
                  name: String, transport: String, endpoint: String, rootPath: String,
                  username: String, readOnly: Int32, credentialTicket: Int64,
                  buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        guard let owner = resolveOwner(epoch: epoch) else {
            if credentialTicket > 0 { _ = credAbort(ticket: credentialTicket) }
            return Int32(epoch == 0 ? G04NetworkHostStatus.notInstalled
                                    : G04NetworkHostStatus.generationFenced)
        }
        guard let (taskID, workspaceID, draft) = mountDraft(taskHex: taskHex,
                    workspaceHex: workspaceHex, mountHex: mountHex, name: name,
                    transport: transport, endpoint: endpoint, rootPath: rootPath,
                    username: username, readOnly: readOnly, credentialTicket: credentialTicket) else {
            if credentialTicket > 0 { _ = credAbort(ticket: credentialTicket) }
            return Int32(G04NetworkHostStatus.invalidArguments)
        }
        switch hop(seconds: G04NetworkHostLimits.ioHopSeconds, owner: owner,
                   after: { try await $0.addMount(taskID: taskID, workspaceID: workspaceID,
                                                  draft: draft) }) {
        case .success(let view):
            let object: [String: Any] = [
                "ok": 1, "mountID": view.id.uuidString, "name": view.name,
                "transport": view.transport, "endpoint": view.endpoint,
                "rootPath": view.rootPath, "username": view.username,
                "readOnly": view.readOnly ? 1 : 0, "status": view.status,
            ]
            return Self.copy(Self.json(object), buffer: buffer, capacity: capacity)
        case .failure(let error):
            // Every owner failure path already consumed/aborted/revoked the
            // staged ticket (capture-first ordering + failConfig rollback).
            // A residue abort is a typed no-op safety net: a live staged
            // secret must never outlive the attempt that owns it.
            let status = self.status(for: error)
            if credentialTicket > 0 {
                _ = hop(seconds: G04NetworkHostLimits.shortHopSeconds, owner: owner,
                        after: { await $0.abortCredentialStage(credentialTicket) })
            }
            if status == G04NetworkHostStatus.providerFailed
                || status == G04NetworkHostStatus.credentialRefused
                || status == G04NetworkHostStatus.transitionRefused
                || status == G04NetworkHostStatus.pathRefused {
                return Self.copy(Self.json(["ok": 0, "errorCode": errorCodeToken(error),
                                            "retryable": errorRetryable(error) ? 1 : 0]),
                                 buffer: buffer, capacity: capacity)
            }
            return Int32(status)
        case .timeout:
            return Int32(G04NetworkHostStatus.hopTimeout)
        }
    }

    func mountProbe(epoch: UInt64, taskHex: String, workspaceHex: String, mountHex: String,
                    buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        commonMountAction(epoch: epoch, taskHex: taskHex, workspaceHex: workspaceHex,
                          mountHex: mountHex,
                          action: { owner, taskID, workspaceID, mountID in
                              try await owner.probeMount(taskID: taskID, workspaceID: workspaceID,
                                                          mountID: mountID).rawValue
                          },
                          reply: { status in ["ok": 1, "status": status] },
                          failureReply: { code in ["ok": 0, "errorCode": code] },
                          io: true, buffer: buffer, capacity: capacity)
    }

    func mountDisconnect(epoch: UInt64, taskHex: String, workspaceHex: String, mountHex: String,
                         buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        guard let owner = resolveOwner(epoch: epoch) else {
            return Int32(epoch == 0 ? G04NetworkHostStatus.notInstalled
                                    : G04NetworkHostStatus.generationFenced)
        }
        guard let taskID = Self.canonicalUUID(taskHex),
              let workspaceID = Self.canonicalUUID(workspaceHex),
              let mountID = Self.canonicalUUID(mountHex) else {
            return Int32(G04NetworkHostStatus.invalidArguments)
        }
        switch hop(seconds: G04NetworkHostLimits.ioHopSeconds, owner: owner,
                   after: { owner in
                       let outcome = await owner.disconnectMount(taskID: taskID,
                                                                  workspaceID: workspaceID,
                                                                  mountID: mountID)
                       return outcome
                   }) {
        case .success(let outcome):
            return Self.copy(Self.json(["ok": 1,
                                        "cancelled": outcome.cancelled.map { $0 },
                                        "outstanding": outcome.outstanding.map { $0 }]),
                             buffer: buffer, capacity: capacity)
        case .failure(let error): return Int32(status(for: error))
        case .timeout: return Int32(G04NetworkHostStatus.hopTimeout)
        }
    }

    func mountRemove(epoch: UInt64, taskHex: String, workspaceHex: String, mountHex: String,
                     forgetCredential: Int32,
                     buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        guard let owner = resolveOwner(epoch: epoch) else {
            return Int32(epoch == 0 ? G04NetworkHostStatus.notInstalled
                                    : G04NetworkHostStatus.generationFenced)
        }
        guard let taskID = Self.canonicalUUID(taskHex),
              let workspaceID = Self.canonicalUUID(workspaceHex),
              let mountID = Self.canonicalUUID(mountHex) else {
            return Int32(G04NetworkHostStatus.invalidArguments)
        }
        switch hop(seconds: G04NetworkHostLimits.ioHopSeconds + 30, owner: owner,
                   after: { try await $0.removeMount(taskID: taskID, workspaceID: workspaceID,
                                                     mountID: mountID,
                                                     forgetCredential: forgetCredential != 0) }) {
        case .success(let outcome):
            return Self.copy(Self.json(["ok": 1, "credential": outcome.credential,
                                        "outstanding": outcome.outstanding.map { $0 }]),
                             buffer: buffer, capacity: capacity)
        case .failure(let error):
            return Self.copy(Self.json(["ok": 0, "errorCode": errorCodeToken(error)]),
                             buffer: buffer, capacity: capacity)
        case .timeout: return Int32(G04NetworkHostStatus.hopTimeout)
        }
    }

    private func commonMountAction<Reply>(
        epoch: UInt64, taskHex: String, workspaceHex: String, mountHex: String,
        action: @escaping @Sendable (G04NetworkWorkspace, UUID, UUID, UUID) async throws -> Reply,
        reply: @escaping @Sendable (Reply) -> [String: Any],
        failureReply: @Sendable (String) -> [String: Any],
        io: Bool,
        buffer: UnsafeMutablePointer<CChar>?, capacity: Int32
    ) -> Int32 {
        guard let owner = resolveOwner(epoch: epoch) else {
            return Int32(epoch == 0 ? G04NetworkHostStatus.notInstalled
                                    : G04NetworkHostStatus.generationFenced)
        }
        guard let taskID = Self.canonicalUUID(taskHex),
              let workspaceID = Self.canonicalUUID(workspaceHex),
              let mountID = Self.canonicalUUID(mountHex) else {
            return Int32(G04NetworkHostStatus.invalidArguments)
        }
        switch hop(seconds: io ? G04NetworkHostLimits.ioHopSeconds : G04NetworkHostLimits.shortHopSeconds,
                   owner: owner,
                   after: { try await action($0, taskID, workspaceID, mountID) }) {
        case .success(let value):
            return Self.copy(Self.json(reply(value)), buffer: buffer, capacity: capacity)
        case .failure(let error):
            let token = errorCodeToken(error)
            let status = self.status(for: error)
            if status == G04NetworkHostStatus.providerFailed
                || status == G04NetworkHostStatus.credentialRefused {
                return Self.copy(Self.json(failureReply(token)), buffer: buffer, capacity: capacity)
            }
            return Int32(status)
        case .timeout: return Int32(G04NetworkHostStatus.hopTimeout)
        }
    }

    // MARK: - Browse / stat

    func browse(epoch: UInt64, taskHex: String, workspaceHex: String, mountHex: String,
                path: String, buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        guard let owner = resolveOwner(epoch: epoch) else {
            return Int32(epoch == 0 ? G04NetworkHostStatus.notInstalled
                                    : G04NetworkHostStatus.generationFenced)
        }
        guard let taskID = Self.canonicalUUID(taskHex),
              let workspaceID = Self.canonicalUUID(workspaceHex),
              let mountID = Self.canonicalUUID(mountHex),
              Self.boundedUTF8(path, limit: 4096) != nil else {
            return Int32(G04NetworkHostStatus.invalidArguments)
        }
        switch hop(seconds: G04NetworkHostLimits.ioHopSeconds, owner: owner,
                   after: { try await $0.browse(taskID: taskID, workspaceID: workspaceID,
                                                mountID: mountID, path: path) }) {
        case .success(let page):
            var objects: [[String: Any]] = []
            var used = 96
            var truncated = page.truncated
            for entry in page.entries {
                var object: [String: Any] = [
                    "name": entry.name, "path": entry.path,
                    "isDirectory": entry.isDirectory ? 1 : 0, "bytes": entry.bytes,
                ]
                if let modifiedAt = entry.modifiedAt { object["modifiedAt"] = modifiedAt.timeIntervalSince1970 }
                if let entityTag = entry.entityTag { object["entityTag"] = String(entityTag.prefix(256)) }
                let size = Self.json(object).utf8.count + 2
                guard used + size <= min(Int(capacity), G04NetworkHostLimits.maximumReplyBytes) else {
                    truncated = true
                    break
                }
                used += size
                objects.append(object)
            }
            lock.lock(); counters.browsePages += 1; lock.unlock()
            return Self.copy(Self.json(["ok": 1, "entries": objects, "truncated": truncated ? 1 : 0]),
                             buffer: buffer, capacity: capacity)
        case .failure(let error):
            let status = self.status(for: error)
            if status == G04NetworkHostStatus.providerFailed {
                return Self.copy(Self.json(["ok": 0, "errorCode": errorCodeToken(error),
                                             "retryable": errorRetryable(error) ? 1 : 0]),
                                 buffer: buffer, capacity: capacity)
            }
            return Int32(status)
        case .timeout: return Int32(G04NetworkHostStatus.hopTimeout)
        }
    }

    func stat(epoch: UInt64, taskHex: String, workspaceHex: String, mountHex: String,
              path: String, buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        guard let owner = resolveOwner(epoch: epoch) else {
            return Int32(epoch == 0 ? G04NetworkHostStatus.notInstalled
                                    : G04NetworkHostStatus.generationFenced)
        }
        guard let taskID = Self.canonicalUUID(taskHex),
              let workspaceID = Self.canonicalUUID(workspaceHex),
              let mountID = Self.canonicalUUID(mountHex),
              Self.boundedUTF8(path, limit: 4096) != nil else {
            return Int32(G04NetworkHostStatus.invalidArguments)
        }
        switch hop(seconds: G04NetworkHostLimits.ioHopSeconds, owner: owner,
                   after: { try await $0.stat(taskID: taskID, workspaceID: workspaceID,
                                              mountID: mountID, path: path) }) {
        case .success(let meta):
            var object: [String: Any] = [
                "ok": 1, "path": meta.path, "isDirectory": meta.isDirectory ? 1 : 0,
                "bytes": meta.byteCount,
            ]
            if let modifiedAt = meta.modifiedAt { object["modifiedAt"] = modifiedAt.timeIntervalSince1970 }
            if let entityTag = meta.entityTag { object["entityTag"] = String(entityTag.prefix(256)) }
            return Self.copy(Self.json(object), buffer: buffer, capacity: capacity)
        case .failure(let error):
            let status = self.status(for: error)
            if status == G04NetworkHostStatus.providerFailed {
                return Self.copy(Self.json(["ok": 0, "errorCode": errorCodeToken(error),
                                             "retryable": errorRetryable(error) ? 1 : 0]),
                                 buffer: buffer, capacity: capacity)
            }
            return Int32(status)
        case .timeout: return Int32(G04NetworkHostStatus.hopTimeout)
        }
    }

    // MARK: - Operations

    func opImport(epoch: UInt64, taskHex: String, workspaceHex: String, mountHex: String,
                  remotePath: String, logicalPath: String, recursive: Int32,
                  conflict: String) -> Int64 {
        guard let owner = resolveOwner(epoch: epoch) else {
            return Int64(epoch == 0 ? G04NetworkHostStatus.notInstalled
                                    : G04NetworkHostStatus.generationFenced)
        }
        guard let taskID = Self.canonicalUUID(taskHex),
              let workspaceID = Self.canonicalUUID(workspaceHex),
              let mountID = Self.canonicalUUID(mountHex),
              conflict == "refuse" || conflict == "copy",
              Self.boundedUTF8(remotePath, limit: 4096) != nil,
              Self.boundedUTF8(logicalPath, limit: 4096) != nil else {
            return Int64(G04NetworkHostStatus.invalidArguments)
        }
        let policy: G04NetworkWorkspace.ImportConflict = conflict == "copy" ? .copy : .refuse
        switch hop(seconds: G04NetworkHostLimits.shortHopSeconds, owner: owner,
                   after: { try await $0.startImport(taskID: taskID, workspaceID: workspaceID,
                                                      mountID: mountID, remotePath: remotePath,
                                                      logicalPath: logicalPath,
                                                      recursive: recursive != 0, conflict: policy) }) {
        case .success(let id): return issueOpTicket(epoch: epoch, id: id)
        case .failure(let error): return Int64(status(for: error))
        case .timeout: return Int64(G04NetworkHostStatus.hopTimeout)
        }
    }

    func opExport(epoch: UInt64, taskHex: String, workspaceHex: String, mountHex: String,
                  logicalPath: String, remotePath: String, policy: String) -> Int64 {
        guard let owner = resolveOwner(epoch: epoch) else {
            return Int64(epoch == 0 ? G04NetworkHostStatus.notInstalled
                                    : G04NetworkHostStatus.generationFenced)
        }
        guard let taskID = Self.canonicalUUID(taskHex),
              let workspaceID = Self.canonicalUUID(workspaceHex),
              let mountID = Self.canonicalUUID(mountHex),
              policy == "refuse" || policy == "conflictCopy",
              Self.boundedUTF8(remotePath, limit: 4096) != nil,
              Self.boundedUTF8(logicalPath, limit: 4096) != nil else {
            return Int64(G04NetworkHostStatus.invalidArguments)
        }
        switch hop(seconds: G04NetworkHostLimits.shortHopSeconds, owner: owner,
                   after: { try await $0.startExport(taskID: taskID, workspaceID: workspaceID,
                                                      mountID: mountID, logicalPath: logicalPath,
                                                      remotePath: remotePath,
                                                      conflictCopy: policy == "conflictCopy") }) {
        case .success(let id): return issueOpTicket(epoch: epoch, id: id)
        case .failure(let error): return Int64(status(for: error))
        case .timeout: return Int64(G04NetworkHostStatus.hopTimeout)
        }
    }

    func opSave(epoch: UInt64, taskHex: String, workspaceHex: String, sourceHex: String) -> Int64 {
        guard let owner = resolveOwner(epoch: epoch) else {
            return Int64(epoch == 0 ? G04NetworkHostStatus.notInstalled
                                    : G04NetworkHostStatus.generationFenced)
        }
        guard let taskID = Self.canonicalUUID(taskHex),
              let workspaceID = Self.canonicalUUID(workspaceHex),
              let sourceID = Self.canonicalUUID(sourceHex) else {
            return Int64(G04NetworkHostStatus.invalidArguments)
        }
        switch hop(seconds: G04NetworkHostLimits.shortHopSeconds, owner: owner,
                   after: { try await $0.startSave(taskID: taskID, workspaceID: workspaceID,
                                                    sourceID: sourceID) }) {
        case .success(let id): return issueOpTicket(epoch: epoch, id: id)
        case .failure(let error): return Int64(status(for: error))
        case .timeout: return Int64(G04NetworkHostStatus.hopTimeout)
        }
    }

    func opReconcile(epoch: UInt64, taskHex: String, workspaceHex: String,
                     recoveryHex: String) -> Int64 {
        guard let owner = resolveOwner(epoch: epoch) else {
            return Int64(epoch == 0 ? G04NetworkHostStatus.notInstalled
                                    : G04NetworkHostStatus.generationFenced)
        }
        guard let taskID = Self.canonicalUUID(taskHex),
              let workspaceID = Self.canonicalUUID(workspaceHex),
              let recoveryID = Self.canonicalUUID(recoveryHex) else {
            return Int64(G04NetworkHostStatus.invalidArguments)
        }
        switch hop(seconds: G04NetworkHostLimits.shortHopSeconds, owner: owner,
                   after: { try await $0.startReconcile(taskID: taskID, workspaceID: workspaceID,
                                                         recoveryID: recoveryID) }) {
        case .success(let id): return issueOpTicket(epoch: epoch, id: id)
        case .failure(let error): return Int64(status(for: error))
        case .timeout: return Int64(G04NetworkHostStatus.hopTimeout)
        }
    }

    func opStatus(ticket: Int64, buffer: UnsafeMutablePointer<CChar>?,
                  capacity: Int32) -> Int32 {
        guard let binding = lookupOp(ticket), let owner = resolveOwner(epoch: binding.epoch) else {
            return Int32(isRetired(ticket) ? G04NetworkHostStatus.generationFenced
                                           : G04NetworkHostStatus.sessionUnknown)
        }
        switch hop(seconds: G04NetworkHostLimits.shortHopSeconds, owner: owner,
                   after: { await $0.operation(binding.id) }) {
        case .success(let view):
            guard let view else {
                releaseOp(ticket)
                return Int32(G04NetworkHostStatus.sessionUnknown)
            }
            var failuresJSON: [[String: Any]] = []
            for failure in view.failures.prefix(32) {
                failuresJSON.append(["path": failure.path, "code": failure.code])
            }
            let object: [String: Any] = [
                "ok": 1, "id": view.id, "kind": view.kind,
                "mountID": view.mountID ?? "", "remotePath": view.remotePath,
                "logicalPath": view.logicalPath, "state": view.state.rawValue,
                "phase": view.phase, "bytesDone": view.bytesDone, "totalBytes": view.totalBytes,
                "entriesDone": view.entriesDone, "entriesFailed": view.entriesFailed,
                "failures": failuresJSON,
                "errorCode": view.errorCode ?? "", "retryable": view.errorRetryable ? 1 : 0,
                "result": view.result,
            ]
            if view.state == .completed || view.state == .failed || view.state == .cancelled {
                lock.lock(); counters.opsSettled += 1; lock.unlock()
            }
            return Self.copy(Self.json(object), buffer: buffer, capacity: capacity)
        case .failure: return Int32(G04NetworkHostStatus.internal)
        case .timeout: return Int32(G04NetworkHostStatus.hopTimeout)
        }
    }

    func opCancel(ticket: Int64) -> Int32 {
        guard let binding = lookupOp(ticket), let owner = resolveOwner(epoch: binding.epoch) else {
            return Int32(isRetired(ticket) ? G04NetworkHostStatus.generationFenced
                                           : G04NetworkHostStatus.sessionUnknown)
        }
        switch hop(seconds: G04NetworkHostLimits.shortHopSeconds, owner: owner,
                   after: { await $0.cancelOperation(binding.id) }) {
        case .success(let requested):
            if requested { lock.lock(); counters.opsCancelled += 1; lock.unlock() }
            return requested ? G04NetworkHostStatus.ok : G04NetworkHostStatus.stateConflict
        case .failure: return Int32(G04NetworkHostStatus.internal)
        case .timeout: return Int32(G04NetworkHostStatus.hopTimeout)
        }
    }

    /// Close ONLY on a proven terminal state; a cancel REQUEST never closes
    /// an operation whose IO has not settled.
    func opClose(ticket: Int64) -> Int32 {
        guard let binding = lookupOp(ticket), let owner = resolveOwner(epoch: binding.epoch) else {
            return Int32(isRetired(ticket) ? G04NetworkHostStatus.generationFenced
                                           : G04NetworkHostStatus.sessionUnknown)
        }
        switch hop(seconds: G04NetworkHostLimits.shortHopSeconds, owner: owner,
                   after: { (owner: G04NetworkWorkspace) -> Bool in
                       guard let view = await owner.operation(binding.id) else { return true }
                       guard view.state == .completed || view.state == .failed
                               || view.state == .cancelled else { return false }
                       return await owner.closeOperation(binding.id)
                   }) {
        case .success(let closed):
            if closed {
                lock.lock()
                retiredTickets.insert(ticket)
                retiredOrder.append(ticket)
                while retiredOrder.count > 512 { retiredTickets.remove(retiredOrder.removeFirst()) }
                lock.unlock()
                releaseOp(ticket)
                return G04NetworkHostStatus.ok
            }
            return Int32(G04NetworkHostStatus.stateConflict)
        case .failure: return Int32(G04NetworkHostStatus.internal)
        case .timeout: return Int32(G04NetworkHostStatus.hopTimeout)
        }
    }

    // MARK: - Network source rows (same journal 47, metadata only)

    func sourcePage(epoch: UInt64, workspaceHex: String, afterID: String, limit: Int32,
                    buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        guard let owner = resolveOwner(epoch: epoch) else {
            return Int32(epoch == 0 ? G04NetworkHostStatus.notInstalled
                                    : G04NetworkHostStatus.generationFenced)
        }
        guard let workspaceID = Self.canonicalUUID(workspaceHex) else {
            return Int32(G04NetworkHostStatus.invalidArguments)
        }
        let cursor = afterID.isEmpty ? nil : afterID
        let bounded = Int(max(1, min(Int(limit), G04NetworkHostLimits.maximumRowsPerPage)))
        switch hop(seconds: G04NetworkHostLimits.shortHopSeconds, owner: owner,
                   after: { try await $0.networkSourcesPage(workspaceID: workspaceID,
                                                             afterID: cursor, limit: bounded) }) {
        case .success(let rows):
            var objects: [[String: Any]] = []
            var used = 64
            var next: String?
            for row in rows {
                let object: [String: Any] = [
                    "id": row.id.uuidString, "path": row.logicalPath, "kind": row.kind.rawValue,
                    "reference": row.sourceReference, "documentID": row.sourceDocumentID ?? "",
                    "sha256": row.sourceSHA256 ?? "", "entityTag": row.entityTag ?? "",
                    "revision": row.revision,
                ]
                let size = Self.json(object).utf8.count + 2
                guard used + size <= min(Int(capacity), G04NetworkHostLimits.maximumReplyBytes) else {
                    next = row.id.uuidString
                    break
                }
                used += size
                objects.append(object)
            }
            var reply: [String: Any] = ["ok": 1, "rows": objects]
            if let next { reply["nextAfterID"] = next }
            if objects.isEmpty && !rows.isEmpty { return G04NetworkHostStatus.bufferTooSmall }
            return Self.copy(Self.json(reply), buffer: buffer, capacity: capacity)
        case .failure(let error): return Int32(status(for: error))
        case .timeout: return Int32(G04NetworkHostStatus.hopTimeout)
        }
    }

    // MARK: - Stats (typed counters only)

    func statsJSON() -> String {
        lock.lock()
        let object: [String: Any] = [
            "liveOpTickets": opTickets.count,
            "retiredTickets": retiredTickets.count,
            "counters": [
                "hops": counters.hops, "hopsTimedOut": counters.hopsTimedOut,
                "refused": counters.refused, "fenced": counters.fenced,
                "opsStarted": counters.opsStarted, "opsSettled": counters.opsSettled,
                "opsCancelled": counters.opsCancelled, "credStaged": counters.credStaged,
                "credRefused": counters.credRefused, "browsePages": counters.browsePages,
                "saturated": counters.saturated,
            ],
        ]
        lock.unlock()
        return Self.json(object)
    }

    func stats(buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        Self.copy(statsJSON(), buffer: buffer, capacity: capacity)
    }

    static func json(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"ok\":0,\"errorCode\":\"internal\"}"
        }
        return text
    }

    static func copy(_ text: String, buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        let bytes = Array(text.utf8)
        guard bytes.count + 1 <= Int(capacity) else { return G04NetworkHostStatus.bufferTooSmall }
        guard let buffer else { return G04NetworkHostStatus.invalidArguments }
        for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
        buffer[bytes.count] = 0
        return Int32(bytes.count)
    }
}

// MARK: - Trusted host C ABI (`floe_g04_net_*`; Kotlin JNI only)

@_cdecl("floe_g04_net_cred_stage")
public func floeG04NetCredStage(_ epoch: UInt64, _ data: UnsafePointer<UInt8>?,
                                _ length: Int32) -> Int64 {
    guard length > 0, length <= Int32(SecretGatewayLimits.maximumSecretBytes),
          let data else {
            return Int64(G04NetworkHostStatus.invalidArguments)
    }
    return G04NetworkWorkspaceHost.shared.credStage(
        epoch: epoch, data: Data(bytes: data, count: Int(length)))
}

@_cdecl("floe_g04_net_cred_abort")
public func floeG04NetCredAbort(_ ticket: Int64) -> Int32 {
    G04NetworkWorkspaceHost.shared.credAbort(ticket: ticket)
}

@_cdecl("floe_g04_net_mount_page")
public func floeG04NetMountPage(_ epoch: UInt64, _ taskHex: UnsafeMutablePointer<CChar>?,
                               _ workspaceHex: UnsafeMutablePointer<CChar>?,
                               _ buffer: UnsafeMutablePointer<CChar>?,
                               _ capacity: Int32) -> Int32 {
    G04NetworkWorkspaceHost.shared.mountPage(
        epoch: epoch, taskHex: G04HostC.string(taskHex) ?? "",
        workspaceHex: G04HostC.string(workspaceHex) ?? "", buffer: buffer, capacity: capacity)
}

@_cdecl("floe_g04_net_mount_add")
public func floeG04NetMountAdd(_ epoch: UInt64, _ taskHex: UnsafeMutablePointer<CChar>?,
                               _ workspaceHex: UnsafeMutablePointer<CChar>?,
                               _ name: UnsafeMutablePointer<CChar>?,
                               _ transport: UnsafeMutablePointer<CChar>?,
                               _ endpoint: UnsafeMutablePointer<CChar>?,
                               _ rootPath: UnsafeMutablePointer<CChar>?,
                               _ username: UnsafeMutablePointer<CChar>?, _ readOnly: Int32,
                               _ credentialTicket: Int64,
                               _ buffer: UnsafeMutablePointer<CChar>?,
                               _ capacity: Int32) -> Int32 {
    G04NetworkWorkspaceHost.shared.mountAdd(
        epoch: epoch, taskHex: G04HostC.string(taskHex) ?? "",
        workspaceHex: G04HostC.string(workspaceHex) ?? "", mountHex: nil,
        name: G04HostC.string(name) ?? "", transport: G04HostC.string(transport) ?? "",
        endpoint: G04HostC.string(endpoint) ?? "", rootPath: G04HostC.string(rootPath) ?? "",
        username: G04HostC.string(username) ?? "", readOnly: readOnly,
        credentialTicket: credentialTicket, buffer: buffer, capacity: capacity)
}

@_cdecl("floe_g04_net_mount_update")
public func floeG04NetMountUpdate(_ epoch: UInt64, _ taskHex: UnsafeMutablePointer<CChar>?,
                                  _ workspaceHex: UnsafeMutablePointer<CChar>?,
                                  _ mountHex: UnsafeMutablePointer<CChar>?,
                                  _ name: UnsafeMutablePointer<CChar>?,
                                  _ transport: UnsafeMutablePointer<CChar>?,
                                  _ endpoint: UnsafeMutablePointer<CChar>?,
                                  _ rootPath: UnsafeMutablePointer<CChar>?,
                                  _ username: UnsafeMutablePointer<CChar>?, _ readOnly: Int32,
                                  _ credentialTicket: Int64,
                                  _ buffer: UnsafeMutablePointer<CChar>?,
                                  _ capacity: Int32) -> Int32 {
    G04NetworkWorkspaceHost.shared.mountAdd(
        epoch: epoch, taskHex: G04HostC.string(taskHex) ?? "",
        workspaceHex: G04HostC.string(workspaceHex) ?? "",
        mountHex: G04HostC.optionalString(mountHex),
        name: G04HostC.string(name) ?? "", transport: G04HostC.string(transport) ?? "",
        endpoint: G04HostC.string(endpoint) ?? "", rootPath: G04HostC.string(rootPath) ?? "",
        username: G04HostC.string(username) ?? "", readOnly: readOnly,
        credentialTicket: credentialTicket, buffer: buffer, capacity: capacity)
}

@_cdecl("floe_g04_net_mount_probe")
public func floeG04NetMountProbe(_ epoch: UInt64, _ taskHex: UnsafeMutablePointer<CChar>?,
                                 _ workspaceHex: UnsafeMutablePointer<CChar>?,
                                 _ mountHex: UnsafeMutablePointer<CChar>?,
                                 _ buffer: UnsafeMutablePointer<CChar>?,
                                 _ capacity: Int32) -> Int32 {
    G04NetworkWorkspaceHost.shared.mountProbe(
        epoch: epoch, taskHex: G04HostC.string(taskHex) ?? "",
        workspaceHex: G04HostC.string(workspaceHex) ?? "",
        mountHex: G04HostC.string(mountHex) ?? "", buffer: buffer, capacity: capacity)
}

@_cdecl("floe_g04_net_mount_disconnect")
public func floeG04NetMountDisconnect(_ epoch: UInt64, _ taskHex: UnsafeMutablePointer<CChar>?,
                                      _ workspaceHex: UnsafeMutablePointer<CChar>?,
                                      _ mountHex: UnsafeMutablePointer<CChar>?,
                                      _ buffer: UnsafeMutablePointer<CChar>?,
                                      _ capacity: Int32) -> Int32 {
    G04NetworkWorkspaceHost.shared.mountDisconnect(
        epoch: epoch, taskHex: G04HostC.string(taskHex) ?? "",
        workspaceHex: G04HostC.string(workspaceHex) ?? "",
        mountHex: G04HostC.string(mountHex) ?? "", buffer: buffer, capacity: capacity)
}

@_cdecl("floe_g04_net_mount_remove")
public func floeG04NetMountRemove(_ epoch: UInt64, _ taskHex: UnsafeMutablePointer<CChar>?,
                                  _ workspaceHex: UnsafeMutablePointer<CChar>?,
                                  _ mountHex: UnsafeMutablePointer<CChar>?,
                                  _ forgetCredential: Int32,
                                  _ buffer: UnsafeMutablePointer<CChar>?,
                                  _ capacity: Int32) -> Int32 {
    G04NetworkWorkspaceHost.shared.mountRemove(
        epoch: epoch, taskHex: G04HostC.string(taskHex) ?? "",
        workspaceHex: G04HostC.string(workspaceHex) ?? "",
        mountHex: G04HostC.string(mountHex) ?? "", forgetCredential: forgetCredential,
        buffer: buffer, capacity: capacity)
}

@_cdecl("floe_g04_net_browse")
public func floeG04NetBrowse(_ epoch: UInt64, _ taskHex: UnsafeMutablePointer<CChar>?,
                             _ workspaceHex: UnsafeMutablePointer<CChar>?,
                             _ mountHex: UnsafeMutablePointer<CChar>?,
                             _ path: UnsafeMutablePointer<CChar>?,
                             _ buffer: UnsafeMutablePointer<CChar>?,
                             _ capacity: Int32) -> Int32 {
    G04NetworkWorkspaceHost.shared.browse(
        epoch: epoch, taskHex: G04HostC.string(taskHex) ?? "",
        workspaceHex: G04HostC.string(workspaceHex) ?? "",
        mountHex: G04HostC.string(mountHex) ?? "", path: G04HostC.string(path) ?? "",
        buffer: buffer, capacity: capacity)
}

@_cdecl("floe_g04_net_stat")
public func floeG04NetStat(_ epoch: UInt64, _ taskHex: UnsafeMutablePointer<CChar>?,
                           _ workspaceHex: UnsafeMutablePointer<CChar>?,
                           _ mountHex: UnsafeMutablePointer<CChar>?,
                           _ path: UnsafeMutablePointer<CChar>?,
                           _ buffer: UnsafeMutablePointer<CChar>?,
                           _ capacity: Int32) -> Int32 {
    G04NetworkWorkspaceHost.shared.stat(
        epoch: epoch, taskHex: G04HostC.string(taskHex) ?? "",
        workspaceHex: G04HostC.string(workspaceHex) ?? "",
        mountHex: G04HostC.string(mountHex) ?? "", path: G04HostC.string(path) ?? "",
        buffer: buffer, capacity: capacity)
}

@_cdecl("floe_g04_net_op_import")
public func floeG04NetOpImport(_ epoch: UInt64, _ taskHex: UnsafeMutablePointer<CChar>?,
                               _ workspaceHex: UnsafeMutablePointer<CChar>?,
                               _ mountHex: UnsafeMutablePointer<CChar>?,
                               _ remotePath: UnsafeMutablePointer<CChar>?,
                               _ logicalPath: UnsafeMutablePointer<CChar>?,
                               _ recursive: Int32, _ conflict: UnsafeMutablePointer<CChar>?) -> Int64 {
    G04NetworkWorkspaceHost.shared.opImport(
        epoch: epoch, taskHex: G04HostC.string(taskHex) ?? "",
        workspaceHex: G04HostC.string(workspaceHex) ?? "",
        mountHex: G04HostC.string(mountHex) ?? "",
        remotePath: G04HostC.string(remotePath) ?? "",
        logicalPath: G04HostC.string(logicalPath) ?? "", recursive: recursive,
        conflict: G04HostC.string(conflict) ?? "refuse")
}

@_cdecl("floe_g04_net_op_export")
public func floeG04NetOpExport(_ epoch: UInt64, _ taskHex: UnsafeMutablePointer<CChar>?,
                               _ workspaceHex: UnsafeMutablePointer<CChar>?,
                               _ mountHex: UnsafeMutablePointer<CChar>?,
                               _ logicalPath: UnsafeMutablePointer<CChar>?,
                               _ remotePath: UnsafeMutablePointer<CChar>?,
                               _ policy: UnsafeMutablePointer<CChar>?) -> Int64 {
    G04NetworkWorkspaceHost.shared.opExport(
        epoch: epoch, taskHex: G04HostC.string(taskHex) ?? "",
        workspaceHex: G04HostC.string(workspaceHex) ?? "",
        mountHex: G04HostC.string(mountHex) ?? "",
        logicalPath: G04HostC.string(logicalPath) ?? "",
        remotePath: G04HostC.string(remotePath) ?? "",
        policy: G04HostC.string(policy) ?? "refuse")
}

@_cdecl("floe_g04_net_op_save")
public func floeG04NetOpSave(_ epoch: UInt64, _ taskHex: UnsafeMutablePointer<CChar>?,
                             _ workspaceHex: UnsafeMutablePointer<CChar>?,
                             _ sourceHex: UnsafeMutablePointer<CChar>?) -> Int64 {
    G04NetworkWorkspaceHost.shared.opSave(
        epoch: epoch, taskHex: G04HostC.string(taskHex) ?? "",
        workspaceHex: G04HostC.string(workspaceHex) ?? "",
        sourceHex: G04HostC.string(sourceHex) ?? "")
}

@_cdecl("floe_g04_net_op_reconcile")
public func floeG04NetOpReconcile(_ epoch: UInt64, _ taskHex: UnsafeMutablePointer<CChar>?,
                                  _ workspaceHex: UnsafeMutablePointer<CChar>?,
                                  _ recoveryHex: UnsafeMutablePointer<CChar>?) -> Int64 {
    G04NetworkWorkspaceHost.shared.opReconcile(
        epoch: epoch, taskHex: G04HostC.string(taskHex) ?? "",
        workspaceHex: G04HostC.string(workspaceHex) ?? "",
        recoveryHex: G04HostC.string(recoveryHex) ?? "")
}

@_cdecl("floe_g04_net_op_status")
public func floeG04NetOpStatus(_ ticket: Int64, _ buffer: UnsafeMutablePointer<CChar>?,
                               _ capacity: Int32) -> Int32 {
    G04NetworkWorkspaceHost.shared.opStatus(ticket: ticket, buffer: buffer, capacity: capacity)
}

@_cdecl("floe_g04_net_op_cancel")
public func floeG04NetOpCancel(_ ticket: Int64) -> Int32 {
    G04NetworkWorkspaceHost.shared.opCancel(ticket: ticket)
}

@_cdecl("floe_g04_net_op_close")
public func floeG04NetOpClose(_ ticket: Int64) -> Int32 {
    G04NetworkWorkspaceHost.shared.opClose(ticket: ticket)
}

@_cdecl("floe_g04_net_source_page")
public func floeG04NetSourcePage(_ epoch: UInt64, _ workspaceHex: UnsafeMutablePointer<CChar>?,
                                 _ afterID: UnsafeMutablePointer<CChar>?, _ limit: Int32,
                                 _ buffer: UnsafeMutablePointer<CChar>?,
                                 _ capacity: Int32) -> Int32 {
    G04NetworkWorkspaceHost.shared.sourcePage(
        epoch: epoch, workspaceHex: G04HostC.string(workspaceHex) ?? "",
        afterID: G04HostC.string(afterID) ?? "", limit: limit,
        buffer: buffer, capacity: capacity)
}

@_cdecl("floe_g04_net_stats")
public func floeG04NetStats(_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    G04NetworkWorkspaceHost.shared.stats(buffer: buffer, capacity: capacity)
}
