import Foundation

/// Pairing, envelope authentication and stream-ticket authority for the
/// localhost-first Bridge service.
///
/// This is deliberately not a singleton. The host owns one instance and shares
/// it across the loopback and optional LAN listeners. Nothing here reads app
/// globals, UIKit or headers: the peer identity is supplied by the transport
/// from the accepted socket.
///
/// Durability rules:
/// - a request nonce is written to the injected store BEFORE the request is
///   accepted; a failed nonce write rejects the request (fail closed);
/// - revoke/grant writes the store before changing the in-memory authorization;
///   a failed write leaves the previous state and reports failure;
/// - all mutations are serialized under one lock, so a late pairing upsert can
///   never resurrect a key revoked by a concurrent caller.
public final class BridgeRPCAuthority: @unchecked Sendable {
    public struct StreamTicket: Sendable, Equatable {
        public let ticket: String
        public let expiresIn: Int

        public init(ticket: String, expiresIn: Int) {
            self.ticket = ticket
            self.expiresIn = expiresIn
        }
    }

    public struct ConsumedTicket: Sendable, Equatable {
        public let clientID: String
        public let authEpoch: UInt64
        public let clientRevision: UInt64

        public init(clientID: String, authEpoch: UInt64, clientRevision: UInt64) {
            self.clientID = clientID
            self.authEpoch = authEpoch
            self.clientRevision = clientRevision
        }
    }

    public struct OpenedRequest: Sendable {
        public let clientID: String
        public let clientRevision: UInt64
        public let authEpoch: UInt64
        public let sensitiveInputGranted: Bool
        public let nonce: Data
        public let nonceHex: String
        public let plaintext: Data

        private let authority: BridgeRPCAuthority
        private let key: Data

        init(clientID: String,
             clientRevision: UInt64,
             authEpoch: UInt64,
             sensitiveInputGranted: Bool,
             nonce: Data,
             nonceHex: String,
             plaintext: Data,
             authority: BridgeRPCAuthority,
             key: Data) {
            self.clientID = clientID
            self.clientRevision = clientRevision
            self.authEpoch = authEpoch
            self.sensitiveInputGranted = sensitiveInputGranted
            self.nonce = nonce
            self.nonceHex = nonceHex
            self.plaintext = plaintext
            self.authority = authority
            self.key = key
        }

        public func isCurrent() -> Bool {
            authority.isCurrent(clientID: clientID,
                                revision: clientRevision,
                                authEpoch: authEpoch)
        }

        /// Seals a response under the request nonce. Returns nil when the
        /// client was revoked, its revision changed, or the service epoch no
        /// longer matches: a stale response is dropped rather than delivered.
        public func sealResponse(_ plaintext: Data) -> Data? {
            guard isCurrent() else { return nil }
            return BridgeRPCEnvelope.sealResponse(plaintext,
                                                  key: key,
                                                  nonce: nonce,
                                                  nonceHex: nonceHex)
        }
    }

    private struct InternalClient {
        var stored: BridgeRPCStoredClient
        var revision: UInt64
    }

    private struct PairSlot {
        var pending = false
        var cooldownUntil = Date.distantPast
    }

    private struct TicketRecord {
        var clientID: String
        var expiresAt: Date
        var authEpoch: UInt64
        var clientRevision: UInt64
    }

    private let store: any BridgeRPCClientStore
    private let limits: BridgeRPCLimits
    private let now: @Sendable () -> Date
    private let random: @Sendable (Int) -> Data?
    private let lock = BridgeRPCLock()

    private var clients: [String: InternalClient] = [:]
    private var nonces: [String: [String: Int]] = [:]
    private var tickets: [String: TicketRecord] = [:]
    private var pairSlots: [Bool: PairSlot] = [:]
    private var lastPersistedUse: [String: Date] = [:]
    private var authEpoch: UInt64 = 0
    private var approvalHandler: BridgeRPCApprovalHandler?
    private var clientRevokedObserver: (@Sendable (String) -> Void)?
    private var allRevokedObserver: (@Sendable () -> Void)?
    private var clientStateObserver: (@Sendable () -> Void)?
    private var loadFailure: String?
    private var noncePersistenceAvailable = true

    public init(store: any BridgeRPCClientStore,
                limits: BridgeRPCLimits = .default,
                approvalHandler: BridgeRPCApprovalHandler? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                random: @escaping @Sendable (Int) -> Data? = { BridgeRPCEnvelope.randomBytes($0) }) {
        self.store = store
        self.limits = limits
        self.now = now
        self.random = random
        self.approvalHandler = approvalHandler

        let current = now()
        var loadedClients: [BridgeRPCStoredClient] = []
        do {
            loadedClients = try store.loadClients()
        } catch {
            loadFailure = "client store unavailable"
        }
        var restored: [String: InternalClient] = [:]
        for item in loadedClients {
            guard let key = item.key,
                  key.count == BridgeRPCEnvelope.keyByteCount,
                  item.clientID == BridgeRPCEnvelope.tokenID(for: key) else {
                continue
            }
            guard current.timeIntervalSince(item.lastActiveAt) < limits.inactivityWindow else {
                // Expired records are left in the store; they are unusable and
                // cannot authorize. A later prune may remove them.
                continue
            }
            restored[item.clientID] = InternalClient(stored: item, revision: 1)
        }
        self.clients = restored

        do {
            let persisted = try store.loadNonces()
            let cutoff = Int(current.timeIntervalSince1970 - limits.timestampWindow)
            var filtered: [String: [String: Int]] = [:]
            for (clientID, values) in persisted where restored[clientID] != nil {
                let recent = values.filter { $0.value >= cutoff }
                if !recent.isEmpty {
                    filtered[clientID] = Dictionary(uniqueKeysWithValues:
                        recent.sorted { $0.value < $1.value }
                            .suffix(limits.nonceCapacityPerClient)
                            .map { ($0.key, $0.value) }
                    )
                }
            }
            self.nonces = filtered
        } catch {
            self.nonces = [:]
            noncePersistenceAvailable = false
            loadFailure = "nonce store unavailable"
        }
    }

    public var storeFailure: String? {
        lock.lock()
        defer { lock.unlock() }
        return loadFailure
    }

    public var nonceStoreAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return noncePersistenceAvailable
    }

    public func setApprovalHandler(_ handler: BridgeRPCApprovalHandler?) {
        lock.lock()
        approvalHandler = handler
        lock.unlock()
    }

    public func setClientRevokedObserver(_ observer: (@Sendable (String) -> Void)?) {
        lock.lock()
        clientRevokedObserver = observer
        lock.unlock()
    }

    public func setAllRevokedObserver(_ observer: (@Sendable () -> Void)?) {
        lock.lock()
        allRevokedObserver = observer
        lock.unlock()
    }

    /// Called after a durable client-list or permission change, never while
    /// the authority lock is held. The host uses it to refresh its observable
    /// snapshot without polling Keychain state.
    public func setClientStateObserver(_ observer: (@Sendable () -> Void)?) {
        lock.lock()
        clientStateObserver = observer
        lock.unlock()
    }

    private func notifyClientState() {
        lock.lock()
        let observer = clientStateObserver
        lock.unlock()
        observer?()
    }

    public var currentAuthEpoch: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return authEpoch
    }

    public func clientMetadata() -> [BridgeRPCClientRecord] {
        let current = now()
        lock.lock()
        let records = clients.values
            .filter { current.timeIntervalSince($0.stored.lastActiveAt) < limits.inactivityWindow }
            .map { $0.stored.record }
        lock.unlock()
        return records.sorted { $0.grantedAt > $1.grantedAt }
    }

    // MARK: - Pairing

    public func requestPairing(clientName rawName: String,
                               peer: BridgeRPCPeerInfo,
                               fingerprint: String?) async -> BridgeRPCPairOutcome {
        guard peer.isAcceptedTransport else {
            return .unavailable(code: "transport_denied",
                                message: "This connection type is not accepted by Bridge.")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...128).contains(name.utf8.count),
              !name.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F }) else {
            return .unavailable(code: "bad_request",
                                message: "client_name must be 1...128 printable UTF-8 bytes.")
        }

        let isLocalSlot = peer.isLoopback
        let current = now()
        lock.lock()
        var slot = pairSlots[isLocalSlot] ?? PairSlot()
        if slot.pending {
            lock.unlock()
            return .busy(retryAfter: max(1, Int(limits.approvalTimeout.rounded(.up))))
        }
        if current < slot.cooldownUntil {
            let wait = Int(slot.cooldownUntil.timeIntervalSince(current).rounded(.up))
            lock.unlock()
            return .coolingDown(retryAfter: max(1, wait))
        }
        slot.pending = true
        pairSlots[isLocalSlot] = slot
        let handler = approvalHandler
        lock.unlock()

        // Every fresh pairing, including loopback, requires a fresh owner
        // decision. There is no auto-approval path.
        guard let handler else {
            finishPairing(slotKey: isLocalSlot, grant: nil)
            return .denied
        }

        let request = BridgeRPCApprovalRequest(
            requestID: "pair-\(UUID().uuidString)",
            clientName: name,
            isLoopback: peer.isLoopback,
            via: peer.via,
            fingerprint: fingerprint,
            timeout: limits.approvalTimeout
        )
        let waiter = ApprovalWaiter()
        let timeout = DispatchWorkItem { _ = waiter.finish(nil) }
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + limits.approvalTimeout, execute: timeout)
        let handlerTask = Task {
            let decision = await handler(request)
            _ = waiter.finish(decision)
        }
        let decision = await withTaskCancellationHandler(operation: {
            await waiter.wait()
        }, onCancel: {
            _ = waiter.finish(nil)
        })
        timeout.cancel()
        handlerTask.cancel()

        guard decision == .approve else {
            finishPairing(slotKey: isLocalSlot, grant: nil)
            return .denied
        }
        guard let grant = mintGrant(clientName: name, peer: peer) else {
            finishPairing(slotKey: isLocalSlot, grant: nil)
            return .unavailable(code: "storage_unavailable",
                                message: "The client key could not be stored securely.")
        }
        finishPairing(slotKey: isLocalSlot, grant: grant)
        return .approved(grant)
    }

    private func mintGrant(clientName: String,
                           peer: BridgeRPCPeerInfo) -> BridgeRPCPairGrant? {
        for _ in 0..<4 {
            guard let key = random(BridgeRPCEnvelope.keyByteCount),
                  key.count == BridgeRPCEnvelope.keyByteCount else {
                return nil
            }
            let clientID = BridgeRPCEnvelope.tokenID(for: key)
            let current = now()
            var stored = BridgeRPCStoredClient(
                clientID: clientID,
                key: key,
                clientName: clientName,
                grantedAt: current,
                lastActiveAt: current,
                lastAddress: peer.address,
                lastVia: peer.via
            )
            stored.sensitiveInputGranted = false

            lock.lock()
            if clients[clientID] != nil {
                lock.unlock()
                continue
            }
            do {
                // Durable key write happens before the in-memory authorization
                // is published. All mutations share this lock, so a revoke
                // cannot interleave and be undone by this upsert.
                try store.upsertClient(stored)
            } catch {
                lock.unlock()
                return nil
            }
            clients[clientID] = InternalClient(stored: stored, revision: 1)
            var evicted: [String] = []
            if clients.count > limits.maxClients {
                let keep = clients.values
                    .sorted { $0.stored.lastActiveAt > $1.stored.lastActiveAt }
                    .prefix(limits.maxClients)
                let keepIDs = Set(keep.map(\.stored.clientID))
                let candidates = clients.keys.filter { !keepIDs.contains($0) }
                for id in candidates {
                    if (try? store.removeClient(clientID: id)) != nil {
                        clients.removeValue(forKey: id)
                        nonces.removeValue(forKey: id)
                        tickets = tickets.filter { $0.value.clientID != id }
                        evicted.append(id)
                    }
                }
            }
            let grant = BridgeRPCPairGrant(
                clientID: clientID,
                key: key,
                clientName: clientName,
                expiresAt: current.addingTimeInterval(limits.inactivityWindow),
                revision: 1
            )
            lock.unlock()
            for id in evicted { clientRevokedObserver?(id) }
            notifyClientState()
            return grant
        }
        return nil
    }

    private func finishPairing(slotKey: Bool, grant: BridgeRPCPairGrant?) {
        lock.lock()
        var slot = pairSlots[slotKey] ?? PairSlot()
        slot.pending = false
        if grant == nil {
            slot.cooldownUntil = now().addingTimeInterval(limits.pairCooldown)
        }
        pairSlots[slotKey] = slot
        lock.unlock()
    }

    // MARK: - Envelope authentication

    public func openEnvelope(_ envelope: BridgeRPCJSONValue,
                             peer: BridgeRPCPeerInfo) throws -> OpenedRequest {
        let parsed = try BridgeRPCEnvelope.parse(envelope, limits: limits)
        let current = now()

        lock.lock()
        guard noncePersistenceAvailable else {
            lock.unlock()
            throw BridgeRPCEnvelope.Failure(
                code: "auth_unavailable",
                message: "Authentication state could not be stored safely; nothing was executed."
            )
        }
        let snapshot = clients[parsed.tokenID]
        lock.unlock()

        guard let client = snapshot,
              current.timeIntervalSince(client.stored.lastActiveAt) < limits.inactivityWindow,
              let key = client.stored.key else {
            let dummy = random(BridgeRPCEnvelope.keyByteCount) ?? Data(repeating: 0, count: 32)
            _ = try? BridgeRPCEnvelope.open(parsed, key: dummy)
            throw BridgeRPCEnvelope.Failure(code: "auth_failed",
                                            message: BridgeRPCEnvelope.authFailureMessage)
        }

        // Tag verification precedes timestamp and replay checks. A caller that
        // cannot produce a valid tag cannot learn whether its token exists or
        // whether its clock is skewed.
        let plaintext = try BridgeRPCEnvelope.open(parsed, key: key)
        guard abs(current.timeIntervalSince1970 - Double(parsed.timestamp))
                <= limits.timestampWindow else {
            throw BridgeRPCEnvelope.Failure(code: "ts_skew",
                                            message: "Timestamp outside the +/-120s window.")
        }

        lock.lock()
        guard noncePersistenceAvailable,
              var live = clients[parsed.tokenID],
              live.revision == client.revision,
              live.stored.keyHex == client.stored.keyHex else {
            lock.unlock()
            throw BridgeRPCEnvelope.Failure(code: "auth_failed",
                                            message: BridgeRPCEnvelope.authFailureMessage)
        }
        let cutoff = Int(current.timeIntervalSince1970 - limits.timestampWindow)
        var seen = (nonces[parsed.tokenID] ?? [:]).filter { $0.value >= cutoff }
        if seen[parsed.nonceHex] != nil {
            lock.unlock()
            throw BridgeRPCEnvelope.Failure(code: "nonce_replayed", message: "Duplicate nonce.")
        }
        guard seen.count < limits.nonceCapacityPerClient else {
            lock.unlock()
            throw BridgeRPCEnvelope.Failure(code: "nonce_flood",
                                            message: "Too many in-flight nonces; slow down.")
        }
        seen[parsed.nonceHex] = parsed.timestamp
        var updatedNonces = nonces
        updatedNonces[parsed.tokenID] = seen
        updatedNonces = updatedNonces.mapValues { values in
            values.filter { $0.value >= cutoff }
        }

        // Persist BEFORE acceptance. A failure leaves the in-memory nonce store
        // untouched and rejects; a ciphertext can never be accepted without a
        // durable replay tombstone.
        do {
            try store.saveNonces(updatedNonces)
        } catch {
            noncePersistenceAvailable = false
            loadFailure = "nonce store unavailable"
            lock.unlock()
            throw BridgeRPCEnvelope.Failure(
                code: "auth_unavailable",
                message: "Authentication state could not be stored safely; nothing was executed."
            )
        }
        nonces = updatedNonces

        live.stored.lastActiveAt = current
        if peer.address != live.stored.lastAddress || peer.via.rawValue != live.stored.lastVia {
            live.stored.lastAddress = peer.address
            live.stored.lastVia = peer.via.rawValue
        }
        clients[parsed.tokenID] = live
        let shouldPersistClient = lastPersistedUse[parsed.tokenID].map {
            current.timeIntervalSince($0) >= 300
        } ?? true
        if shouldPersistClient {
            lastPersistedUse[parsed.tokenID] = current
            // Best-effort idle metadata; done under the same lock so a revoke
            // cannot be followed by this older write.
            try? store.upsertClient(live.stored)
        }
        let epoch = authEpoch
        lock.unlock()

        return OpenedRequest(
            clientID: parsed.tokenID,
            clientRevision: live.revision,
            authEpoch: epoch,
            sensitiveInputGranted: live.stored.sensitiveInputGranted,
            nonce: parsed.nonce,
            nonceHex: parsed.nonceHex,
            plaintext: plaintext,
            authority: self,
            key: key
        )
    }

    /// Linearizes a final response commit against revocation and revokeAll.
    /// The store is not touched; `body` performs the first socket send. If the
    /// client disappears or its revision/epoch changes, `body` never runs.
    func withCurrentClientCommit<T>(clientID: String,
                                    revision: UInt64,
                                    authEpoch epoch: UInt64,
                                    _ body: () -> T) -> T? {
        lock.lock()
        guard authEpoch == epoch,
              let client = clients[clientID],
              client.revision == revision,
              now().timeIntervalSince(client.stored.lastActiveAt) < limits.inactivityWindow else {
            lock.unlock()
            return nil
        }
        defer { lock.unlock() }
        return body()
    }

    public func isCurrent(clientID: String, revision: UInt64, authEpoch epoch: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard authEpoch == epoch,
              let client = clients[clientID],
              client.revision == revision else {
            return false
        }
        return now().timeIntervalSince(client.stored.lastActiveAt) < limits.inactivityWindow
    }

    // MARK: - Stream tickets

    public func issueStreamTicket(clientID: String) -> StreamTicket? {
        let current = now()
        lock.lock()
        guard let client = clients[clientID],
              current.timeIntervalSince(client.stored.lastActiveAt) < limits.inactivityWindow else {
            lock.unlock()
            return nil
        }
        tickets = tickets.filter { $0.value.expiresAt > current }
        if tickets.count >= limits.maxStreamTickets,
           let oldest = tickets.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            tickets.removeValue(forKey: oldest)
        }
        guard let raw = random(24) else {
            lock.unlock()
            return nil
        }
        let ticket = BridgeRPCEnvelope.hexLowercase(raw)
        tickets[ticket] = TicketRecord(
            clientID: clientID,
            expiresAt: current.addingTimeInterval(limits.streamTicketTTL),
            authEpoch: authEpoch,
            clientRevision: client.revision
        )
        lock.unlock()
        return StreamTicket(ticket: ticket, expiresIn: max(1, Int(limits.streamTicketTTL.rounded(.down))))
    }

    public func consumeStreamTicket(_ ticket: String) -> ConsumedTicket? {
        let current = now()
        lock.lock()
        guard let record = tickets.removeValue(forKey: ticket) else {
            lock.unlock()
            return nil
        }
        guard record.expiresAt > current,
              record.authEpoch == authEpoch,
              let client = clients[record.clientID],
              client.revision == record.clientRevision,
              current.timeIntervalSince(client.stored.lastActiveAt) < limits.inactivityWindow else {
            lock.unlock()
            return nil
        }
        lock.unlock()
        return ConsumedTicket(clientID: record.clientID,
                              authEpoch: record.authEpoch,
                              clientRevision: record.clientRevision)
    }

    public func clearStreamTickets() {
        lock.lock()
        tickets.removeAll()
        lock.unlock()
    }

    // MARK: - Durable management

    @discardableResult
    public func revoke(clientID: String) -> Bool {
        lock.lock()
        guard clients[clientID] != nil else {
            lock.unlock()
            return false
        }
        do {
            try store.removeClient(clientID: clientID)
        } catch {
            lock.unlock()
            return false
        }
        clients.removeValue(forKey: clientID)
        nonces.removeValue(forKey: clientID)
        tickets = tickets.filter { $0.value.clientID != clientID }
        lastPersistedUse.removeValue(forKey: clientID)
        let remainingNonces = nonces
        try? store.saveNonces(remainingNonces)
        let observer = clientRevokedObserver
        lock.unlock()
        observer?(clientID)
        notifyClientState()
        return true
    }

    @discardableResult
    public func revokeAll() -> Bool {
        lock.lock()
        do {
            try store.removeAllClients()
        } catch {
            lock.unlock()
            return false
        }
        clients.removeAll()
        nonces.removeAll()
        tickets.removeAll()
        lastPersistedUse.removeAll()
        authEpoch &+= 1
        let observer = allRevokedObserver
        try? store.saveNonces([:])
        lock.unlock()
        observer?()
        notifyClientState()
        return true
    }

    @discardableResult
    public func setSensitiveInput(clientID: String, granted: Bool) -> Bool {
        lock.lock()
        guard var client = clients[clientID] else {
            lock.unlock()
            return false
        }
        guard client.stored.sensitiveInputGranted != granted else {
            lock.unlock()
            return true
        }
        var updated = client.stored
        updated.sensitiveInputGranted = granted
        do {
            // Durable write precedes the in-memory grant. A failed write must
            // not leave a usable new permission behind.
            try store.upsertClient(updated)
        } catch {
            lock.unlock()
            return false
        }
        client.stored = updated
        client.revision &+= 1
        clients[clientID] = client
        lock.unlock()
        notifyClientState()
        return true
    }

    public func sensitiveInputGranted(clientID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return clients[clientID]?.stored.sensitiveInputGranted ?? false
    }

    /// Removes expired clients only when the durable deletion succeeds. If the
    /// store refuses, the record remains (and remains unusable by age).
    @discardableResult
    public func pruneExpired() -> Int {
        let current = now()
        lock.lock()
        let expired = clients.filter {
            current.timeIntervalSince($0.value.stored.lastActiveAt) >= limits.inactivityWindow
        }.map(\.key)
        var removedIDs: [String] = []
        for id in expired {
            guard (try? store.removeClient(clientID: id)) != nil else { continue }
            clients.removeValue(forKey: id)
            nonces.removeValue(forKey: id)
            tickets = tickets.filter { $0.value.clientID != id }
            lastPersistedUse.removeValue(forKey: id)
            removedIDs.append(id)
        }
        lock.unlock()
        for id in removedIDs { clientRevokedObserver?(id) }
        if !removedIDs.isEmpty { notifyClientState() }
        return removedIDs.count
    }

    /// Test-only inspection of the in-memory replay map size.
    public var inMemoryNonceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return nonces.values.reduce(0) { $0 + $1.count }
    }
}

private final class ApprovalWaiter: @unchecked Sendable {
    private let lock = BridgeRPCLock()
    private var finished = false
    private var value: BridgeRPCApprovalDecision?
    private var continuation: CheckedContinuation<BridgeRPCApprovalDecision?, Never>?

    @discardableResult
    func finish(_ decision: BridgeRPCApprovalDecision?) -> Bool {
        lock.lock()
        if finished {
            lock.unlock()
            return false
        }
        finished = true
        value = decision
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: decision)
        return true
    }

    func wait() async -> BridgeRPCApprovalDecision? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                let value = self.value
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
