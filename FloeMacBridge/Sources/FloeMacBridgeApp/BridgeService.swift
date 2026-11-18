#if os(macOS)
import Foundation
import CryptoKit
import Darwin
import AppKit
import ApplicationServices
import FloeMacBridgeProtocol

actor BridgeService {
    struct Pair: Codable, Sendable { let key: Data; let name: String; let acceptedAt: Date; let verification: String?; let nonce: String? }
    enum PairStoreIdentity: Equatable, Sendable {
        case missing
        case file(device: Int32, inode: UInt64, size: Int64, digest: String)
    }
    struct PairStoreSnapshot: Sendable {
        let pairs: [String: Pair]
        let identity: PairStoreIdentity
    }
    struct Delivery: Sendable { let data: Data; let lease: BridgeUpdateActivity.Lease }
    struct Transfer: Sendable { let root: URL; let relativePath: String; let stage: URL; let expected: String?; let clientID: String; var expires: ContinuousClock.Instant; let updateLease: BridgeUpdateActivity.Lease }
    struct PairingAttempt: Sendable, Equatable {
        let attemptID: String
        let clientID: String
        let displayName: String
        let verification: String
        let receivedAt: String
        let sequence: UInt64
    }
    struct PairingSnapshot: Sendable, Equatable {
        let revision: UInt64
        let pending: [PairingAttempt]
    }
    private struct PendingPairing {
        let attemptID: String
        let clientID: String
        let name: String
        let key: Data
        let nonce: String
        let verification: String
        let receivedAt: String
        let sequence: UInt64
        let updateLease: BridgeUpdateActivity.Lease
    }
    let paths: BridgePaths
    nonisolated let updateActivity: BridgeUpdateActivity
    let jobs: BridgeJobs
    let signingKey: Curve25519.Signing.PrivateKey
    private var pairs: [String: Pair]
    private var accepted: [String: Int64] = [:]
    private var transfers: [String: Transfer] = [:]
    private let transferLifetime: Duration
    private let listingLifetime: Duration
    private var expiryTask: Task<Void, Never>?
    private struct ListingKey: Hashable {
        let client: String
        let workspace: String
        let id: String?
    }
    private struct Listing {
        let files: [[String: BridgeValue]]
        var next: Int
        var expires: ContinuousClock.Instant
    }
    private var listings: [ListingKey: Listing] = [:]
    private var pending: [String: PendingPairing] = [:]
    private var pendingSequence: UInt64 = 0
    private var pairingRevision: UInt64 = 0
    private var pairingObserver: (@Sendable (PairingSnapshot) -> Void)?
    private var rejected: [String: String] = [:]
    var skillPins: [String: Set<String>] = [:]
    // Kept for the standalone app's modal promise presentation. The embedded
    // host uses the ordered snapshot observer instead.
    var consent: (@MainActor @Sendable (String, String, String, String) -> Void)?
    private let pairStoreWriter: (@Sendable (Data) throws -> Void)?
    // A caller-supplied key permits isolated synthetic contract fixtures without
    // accessing the user's Keychain. The application uses the existing default.
    init(paths: BridgePaths, updateActivity: BridgeUpdateActivity = BridgeUpdateActivity(),
         signingKey: Curve25519.Signing.PrivateKey? = nil, transferLifetime: Duration = .seconds(900),
         listingLifetime: Duration = .seconds(120), expectedPairStore: PairStoreIdentity? = nil,
         pairStoreWriter: (@Sendable (Data) throws -> Void)? = nil) throws {
        // Isolated storage must never fall back to the legacy Keychain. This
        // is intentionally before jobs, pair-store reads or key resolution.
        // A supplied key still needs host-verified isolated provenance.
        guard paths.namespace != .isolated || signingKey != nil else {
            throw BridgeFailure.remote("The separate Bridge requires an explicitly resolved identity.")
        }
        self.paths = paths; self.updateActivity = updateActivity
        self.transferLifetime = transferLifetime
        self.listingLifetime = listingLifetime
        self.pairStoreWriter = pairStoreWriter
        self.jobs = BridgeJobs(paths: paths, updateActivity: updateActivity)
        let pairURL = paths.root.appendingPathComponent("State/paired-clients.json")
        let snapshot = try Self.pairStoreSnapshot(at: pairURL)
        guard expectedPairStore == nil || expectedPairStore == snapshot.identity else {
            throw BridgeFailure.remote("The Bridge pairing store changed after preflight; it was not modified.")
        }
        self.signingKey = try signingKey ?? Self.legacySigningKey(hasPairings: !snapshot.pairs.isEmpty)
        pairs = snapshot.pairs
        skillPins = (try? BridgeWire.decode([String: Set<String>].self, from: Data(contentsOf: paths.root.appendingPathComponent("State/skill-pins.json")))) ?? [:]
        accepted = (try? BridgeWire.decode([String: Int64].self, from: Data(contentsOf: paths.root.appendingPathComponent("State/request-ids.json")))) ?? [:]
    }

    static func legacySigningKey(
        hasPairings: Bool,
        read: (String, String) throws -> Data? = BridgeKeychain.read,
        create: (String) throws -> Curve25519.Signing.PrivateKey = BridgeKeychain.signingKey
    ) throws -> Curve25519.Signing.PrivateKey {
        let service = "org.floeagent.bridge.server"
        if let bytes = try read(service, "identity-v1") {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
        }
        guard !hasPairings else {
            throw BridgeFailure.remote(String(localized:
                "The existing Floe Bridge key could not be found. Your pairings were kept."))
        }
        return try create(service)
    }
    /// Read and decode the exact file used by the running service. Only an
    /// absent file represents a first installation; an unreadable, damaged,
    /// symlinked or replaced file must never become an empty pairing store.
    static func loadPairs(at url: URL) throws -> [String: Pair] {
        try pairStoreSnapshot(at: url).pairs
    }

    static func pairStoreSnapshot(at url: URL) throws -> PairStoreSnapshot {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return PairStoreSnapshot(pairs: [:], identity: .missing) }
            throw BridgeFailure.remote("The existing Bridge pairing store cannot be opened; it was not modified.")
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
            throw BridgeFailure.remote("The Bridge pairing store is not a regular file; it was not modified.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data: Data
        do {
            guard let contents = try handle.readToEnd() else { throw BridgeFailure.authentication }
            data = contents
        } catch {
            throw BridgeFailure.remote("The existing Bridge pairing store cannot be read; it was not modified.")
        }
        var after = stat()
        var current = stat()
        guard fstat(descriptor, &after) == 0,
              lstat(url.path, &current) == 0,
              (current.st_mode & S_IFMT) == S_IFREG,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_dev == current.st_dev, before.st_ino == current.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              after.st_size == current.st_size,
              after.st_mtimespec.tv_sec == current.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == current.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == current.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == current.st_ctimespec.tv_nsec,
              Int64(data.count) == before.st_size else {
            throw BridgeFailure.remote("The Bridge pairing store changed while it was read; it was not modified.")
        }
        do {
            let pairs = try BridgeWire.decode([String: Pair].self, from: data)
            return PairStoreSnapshot(pairs: pairs, identity: .file(
                device: before.st_dev, inode: before.st_ino, size: before.st_size,
                digest: BridgeWire.digest(data)
            ))
        } catch {
            throw BridgeFailure.remote("The existing Bridge pairing store is invalid; it was not modified.")
        }
    }
    func setConsent(_ callback: @escaping @MainActor @Sendable (String, String, String, String) -> Void) { consent = callback }
    /// Install the ordered pending-request observer and return the current
    /// snapshot atomically. The callback is invoked from the actor after every
    /// change, before any consent callback suspends.
    func setPairingObserver(_ observer: @escaping @Sendable (PairingSnapshot) -> Void) -> PairingSnapshot {
        pairingObserver = observer
        return currentPairingSnapshot()
    }
    func pairingSnapshot() -> PairingSnapshot { currentPairingSnapshot() }

    private func currentPairingSnapshot() -> PairingSnapshot {
        PairingSnapshot(
            revision: pairingRevision,
            pending: pending.values
                .sorted { $0.sequence < $1.sequence }
                .map {
                    PairingAttempt(attemptID: $0.attemptID, clientID: $0.clientID,
                                   displayName: $0.name, verification: $0.verification,
                                   receivedAt: $0.receivedAt, sequence: $0.sequence)
                }
        )
    }

    private func pairingDidChange() {
        pairingRevision &+= 1
        pairingObserver?(currentPairingSnapshot())
    }

    /// Exact per-attempt decision. Returns false when the attempt is no longer
    /// current (cancelled, superseded or already decided) and performs no
    /// mutation in that case.
    @discardableResult
    func decide(attemptID: String, verification: String, allow: Bool) throws -> Bool {
        let operation = try updateActivity.begin(.maintenance)
        defer { updateActivity.finish(operation) }
        guard let proposal = pending.values.first(where: {
            $0.attemptID == attemptID && $0.verification == verification
        }) else { return false }
        return try decide(proposal: proposal, allow: allow)
    }

    /// A modal decision belongs to exactly the attempt that displayed it.
    /// Even a retry with the same client, nonce and verification must not
    /// accept a delayed response from the previous modal.
    @discardableResult
    func approve(_ clientID: String, attemptID: String, verification: String, allow: Bool) throws -> Bool {
        let operation = try updateActivity.begin(.maintenance)
        defer { updateActivity.finish(operation) }
        guard let proposal = pending.values.first(where: {
            !$0.attemptID.isEmpty && $0.attemptID == attemptID && $0.clientID == clientID && $0.verification == verification
        }) else { return false }
        return try decide(proposal: proposal, allow: allow)
    }

    private func decide(proposal: PendingPairing, allow: Bool) throws -> Bool {
        // Re-check under the actor: another decision or a pairCancel may have
        // removed this exact attempt between snapshot creation and this call.
        guard pending[proposal.clientID]?.attemptID == proposal.attemptID else { return false }
        if allow {
            var updated = pairs
            updated[proposal.clientID] = Pair(
                key: proposal.key, name: proposal.name, acceptedAt: Date(),
                verification: proposal.verification, nonce: proposal.nonce
            )
            // Persist before publishing the in-memory pair. A failed write
            // leaves the pending request, its consent lease and the UI intact.
            try savePairs(updated)
            pairs = updated
        } else {
            rejected[proposal.clientID] = proposal.nonce
        }
        pending.removeValue(forKey: proposal.clientID)
        updateActivity.finish(proposal.updateLease)
        pairingDidChange()
        return true
    }

    func pairedClients() -> [(String, String)] { pairs.map { ($0.key, $0.value.name + ($0.value.verification.map { " · " + $0 } ?? "")) } }
    func revoke(_ clientID: String) async throws {
        let operation = try updateActivity.begin(.maintenance)
        defer { updateActivity.finish(operation) }
        var updated = pairs
        updated.removeValue(forKey: clientID)
        // Do not drop a pending consent before the pairing store is durable;
        // a failed write leaves the exact request still actionable.
        try savePairs(updated)
        pairs = updated
        var changedPending = false
        if let proposal = pending.removeValue(forKey: clientID) {
            updateActivity.finish(proposal.updateLease)
            changedPending = true
        }
        rejected.removeValue(forKey: clientID)
        if changedPending { pairingDidChange() }
        listings = listings.filter { $0.key.client != clientID }
        for (id, transfer) in transfers where transfer.clientID == clientID {
            try? FileManager.default.removeItem(at: transfer.stage); transfers.removeValue(forKey: id)
            updateActivity.finish(transfer.updateLease)
        }
        await jobs.cancelAll(clientID: clientID)
    }
    private func savePairs(_ values: [String: Pair]) throws {
        let data = try BridgeWire.encode(values)
        if let pairStoreWriter {
            try pairStoreWriter(data)
        } else {
            try data.write(to: paths.root.appendingPathComponent("State/paired-clients.json"), options: .atomic)
        }
    }
    /// HTTP owns this lease until the full signed reply finishes sending.
    func respondForDelivery(_ request: BridgeRequest) async throws -> Delivery {
        let lease = try updateActivity.begin(.request)
        do { return Delivery(data: try await respond(request), lease: lease) }
        catch { updateActivity.finish(lease); throw error }
    }
    nonisolated func finishDelivery(_ lease: BridgeUpdateActivity.Lease) { updateActivity.finish(lease) }
    nonisolated func reserveUpdateInstallationIfIdle(
        reason: String = String(localized: "Floe Bridge is installing an update. Reconnect shortly.")
    ) -> BridgeUpdateActivity.Installation? {
        updateActivity.reserveInstallationIfIdle(reason: reason)
    }
    func respond(_ request: BridgeRequest) async throws -> Data {
        let operation = try updateActivity.begin(.request)
        defer { updateActivity.finish(operation) }
        try request.verify()
        // Native approval can complete while the consent callback is suspended.
        // One shared result keeps both admission paths identical.
        func approvedPair(nonce: String) -> [String: BridgeValue] {
            ["paired": .bool(true), "host": .string(Host.current().localizedName ?? "Mac"),
             "protocolVersion": .integer(Int64(BridgeWire.version)), "nonce": .string(nonce)]
        }
        let body = request.body; let clientID = BridgeWire.digest(body.clientKey)
        let result: [String: BridgeValue]
        do {
            if body.method == "pairCancel" {
                guard let nonce = body.payload["nonce"]?.string, nonce.count >= 32, nonce.count <= 160 else { throw BridgeFailure.authentication }
                var changed = false
                if let proposal = pending[clientID], proposal.nonce == nonce {
                    pending.removeValue(forKey: clientID)
                    updateActivity.finish(proposal.updateLease)
                    changed = true
                }
                if rejected[clientID] == nonce { rejected.removeValue(forKey: clientID) }
                if changed { pairingDidChange() }
                result = ["cancelled": .bool(true), "nonce": .string(nonce)]
            } else if body.method == "pair" || body.method == "pairStatus" {
                guard let nonce = body.payload["nonce"]?.string, nonce.count >= 32, nonce.count <= 160 else { throw BridgeFailure.authentication }
                if let pair = pairs[clientID], pair.key == body.clientKey, pair.nonce == nonce {
                    result = approvedPair(nonce: nonce)
                } else if rejected[clientID] == nonce { throw BridgeFailure.remote("The Mac connection was declined.") }
                else {
                    if let proposal = pending[clientID], proposal.nonce != nonce {
                        throw BridgeFailure.remote("A previous connection request is waiting in Bridge. Finish or cancel it, then try again.")
                    }
                    guard pending.count < 4 || pending[clientID] != nil else { throw BridgeFailure.remote("Another connection request is waiting.") }
                    if pending[clientID] == nil {
                        let name = String(String.UnicodeScalarView((body.payload["name"]?.string ?? "Floe").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })).prefix(80).description
                        let verification = BridgeWire.pairingVerification(clientKey: body.clientKey, serverKey: signingKey.publicKey.rawRepresentation, nonce: nonce)
                        // A new pending instance must never reuse the old
                        // identity, even if the client repeats its nonce.
                        let attemptID = UUID().uuidString.lowercased()
                        pendingSequence &+= 1
                        pending[clientID] = PendingPairing(
                            attemptID: attemptID,
                            clientID: clientID,
                            name: name,
                            key: body.clientKey,
                            nonce: nonce,
                            verification: verification,
                            receivedAt: ISO8601DateFormatter().string(from: Date()),
                            sequence: pendingSequence,
                            updateLease: try updateActivity.begin(.consent)
                        )
                        // Publish before the callback can suspend the actor. A
                        // later pairCancel/approve always produces a newer
                        // revision; the host never sees a ghost request.
                        pairingDidChange()
                        if let consent { await consent(clientID, name, verification, attemptID) }
                    }
                    // Re-read admission after the consent await: native approval
                    // removes `pending`, and a decline inserts `rejected`.
                    if let pair = pairs[clientID], pair.key == body.clientKey, pair.nonce == nonce {
                        result = approvedPair(nonce: nonce)
                    } else if rejected[clientID] == nonce {
                        throw BridgeFailure.remote("The Mac connection was declined.")
                    } else {
                        guard pending[clientID]?.nonce == nonce else { throw BridgeFailure.authentication }
                        result = ["paired": .bool(false), "nonce": .string(nonce)]
                    }
                }
            } else {
                guard pairs[clientID]?.key == body.clientKey else { throw BridgeFailure.authentication }
                // A file chunk is admitted by its private transfer and exact
                // append offset. The stage cannot rewind, and a restart
                // discards the transfer ID. A replay cannot append twice.
                if !["ping", "poll", "file.list", "file.read", "file.readAbsolute", "file.chunk", "file.confirmMissing", "permissions", "skill.list", "storage"].contains(body.method) {
                    // Persist mutation admission BEFORE side effects. An interrupted
                    // reply never becomes permission to execute a command twice.
                    let now = Int64(Date().timeIntervalSince1970 * 1_000)
                    accepted = accepted.filter { now - $0.value < 180_000 }
                    let key = clientID + ":" + body.id.uuidString
                    guard accepted[key] == nil, accepted.count < 4_096 else { throw BridgeFailure.ambiguous }
                    accepted[key] = now
                    try BridgeWire.encode(accepted).write(to: paths.root.appendingPathComponent("State/request-ids.json"), options: .atomic)
                }
                result = try await execute(body.method, body.payload, clientID: clientID)
            }
            return try BridgeWire.encode(BridgeResponse(body: BridgeResponseBody(id: body.id,
                serverKey: signingKey.publicKey.rawRepresentation, result: result), key: signingKey))
        } catch {
            return try BridgeWire.encode(BridgeResponse(body: BridgeResponseBody(id: body.id,
                serverKey: signingKey.publicKey.rawRepresentation, error: error.localizedDescription), key: signingKey))
        }
    }
    func transfersAreIdle() -> Bool {
        for (id, transfer) in transfers where transfer.expires <= .now {
            try? FileManager.default.removeItem(at: transfer.stage); transfers.removeValue(forKey: id)
            updateActivity.finish(transfer.updateLease)
        }
        return transfers.isEmpty
    }
    private func scheduleTransferExpiry() {
        guard expiryTask == nil, let deadline = transfers.values.map(\.expires).min() else { return }
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            await self?.expireTransfers()
        }
    }
    private func expireTransfers() {
        expiryTask = nil
        if !transfersAreIdle() { scheduleTransferExpiry() }
    }
    private func workspace(_ values: [String: BridgeValue]) throws -> URL {
        guard let id = values["workspaceID"]?.string else { throw BridgeFailure.unsafePath }
        let root = try paths.managed("Workspaces", id: id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func required(_ values: [String: BridgeValue], _ key: String) throws -> String {
        guard let text = values[key]?.string else { throw BridgeFailure.remote("Missing \(key).") }; return text
    }
    private func execute(_ method: String, _ p: [String: BridgeValue], clientID: String) async throws -> [String: BridgeValue] {
        switch method {
        case "ping":
            var value: [String: BridgeValue] = ["host": .string(Host.current().localizedName ?? "Mac"), "os": .string("macos"), "arch": .string("arm64"),
                "capabilities": .array(advertisedCapabilities().map(BridgeValue.string))]
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { value["appVersion"] = .string(version) }
            if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String { value["appBuild"] = .string(build) }
            if let url = Bundle.main.url(forResource: "source-commit", withExtension: "txt"),
               let source = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               source.count == 40, source.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                value["sourceCommit"] = .string(source)
            }
            return value
        case "workspace":
            let root = try workspace(p)
            return ["root": .string(root.path), "transferPolicyVersion": .integer(Int64(BridgeWorkspaceTransferPolicy.version)),
                    "hostDependencyDirectories": .array(BridgeWorkspaceTransferPolicy.hostDependencyDirectories.sorted().map(BridgeValue.string))]
        case "command.discard":
            let id = try required(p, "jobID")
            guard UUID(uuidString: id) != nil else { throw BridgeFailure.unsafePath }
            let task = try paths.managed("Tasks", id: id)
            guard !FileManager.default.fileExists(atPath: task.path) else { return [:] }
            let file = paths.root.appendingPathComponent("State/Commands/" + clientID + "/" + id)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return [:]
        case "start":
            let root = try workspace(p)
            let cwdText = p["cwd"]?.string ?? "."
            let cwd = cwdText == "." ? root : try BridgePaths.safe(cwdText, under: root)
            guard (try cwd.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw BridgeFailure.unsafePath }
            var environment: [String: String] = [:]
            for (key, value) in p["environment"]?.object ?? [:] {
                guard !key.isEmpty, !key.contains("="), !key.contains("\0"), let value = value.string, !value.contains("\0") else { continue }
                if !["HOME", "TMPDIR", "PATH", "PYTHONPATH", "NODE_PATH"].contains(key) { environment[key] = value }
            }
            let jobID = try required(p, "jobID")
            var commandFile: URL?
            if let fileID = p["commandFile"]?.string {
                guard fileID == jobID, UUID(uuidString: fileID) != nil,
                      let expected = p["commandDigest"]?.string else { throw BridgeFailure.unsafePath }
                let file = paths.root.appendingPathComponent("State/Commands/" + clientID + "/" + fileID)
                guard try digest(file) == expected else { throw BridgeFailure.remote("The staged command did not match.") }
                commandFile = file
            }
            let sensitiveNames = try sensitiveEnvironmentNames(from: p)
            return try await jobs.start(id: jobID, clientID: clientID,
                workspaceID: required(p, "workspaceID"), command: p["command"]?.string ?? "", commandFile: commandFile, cwd: cwd,
                environment: environment, sensitiveEnvironmentNames: sensitiveNames,
                columns: Int(p["columns"]?.integer ?? 100), rows: Int(p["rows"]?.integer ?? 30))
        case "poll": return try await jobs.poll(id: required(p, "jobID"), clientID: clientID,
                                              offset: p["offset"]?.integer ?? 0, limit: Int(p["limit"]?.integer ?? Int64(BridgeWire.pageBytes)))
        case "input":
            let job = try await jobs.owned(required(p, "jobID"), clientID: clientID)
            guard let bytes = Data(base64Encoded: try required(p, "data")), bytes.count <= BridgeWire.pageBytes else { throw BridgeFailure.remote("Invalid terminal input.") }
            try job.write(bytes); return [:]
        case "signal":
            let job = try await jobs.owned(required(p, "jobID"), clientID: clientID)
            let signal: Int32 = switch p["signal"]?.string { case "INT": SIGINT; case "KILL": SIGKILL; default: SIGTERM }
            job.signal(signal); return [:]
        case "resize":
            try await jobs.resize(id: required(p, "jobID"), clientID: clientID,
                                  columns: Int(p["columns"]?.integer ?? 80), rows: Int(p["rows"]?.integer ?? 24)); return [:]
        case "file.list":
            return try listWorkspaceFiles(p, client: clientID)
        case "file.confirmMissing":
            let root = try workspace(p)
            guard let values = p["paths"]?.array, values.count <= 100 else { throw BridgeFailure.invalidResponse }
            var missing: [BridgeValue] = []
            for value in values {
                guard let path = value.string, !BridgeWorkspaceTransferPolicy.excludes(path) else { throw BridgeFailure.unsafePath }
                let file = try BridgePaths.safe(path, under: root)
                var details = stat()
                if lstat(file.path, &details) == -1 {
                    guard errno == ENOENT else { throw BridgeFailure.remote("The Mac file could not be inspected.") }
                    missing.append(value)
                }
            }
            return ["missing": .array(missing)]
        case "file.read":
            let file = try BridgePaths.safe(required(p, "path"), under: workspace(p))
            let reader = try FileHandle(forReadingFrom: file); defer { try? reader.close() }
            let offset = max(0, p["offset"]?.integer ?? 0); try reader.seek(toOffset: UInt64(offset))
            let limit = p["limit"]?.integer ?? Int64(BridgeWire.pageBytes)
            guard limit > 0, limit <= Int64(BridgeWire.maximumFileChunkBytes) else { throw BridgeFailure.invalidResponse }
            let data = try reader.read(upToCount: Int(limit)) ?? Data()
            return ["data": .string(data.base64EncodedString()), "offset": .integer(offset + Int64(data.count))]
        case "file.readAbsolute":
            // Additive read-only method; the workspace-relative contract above
            // stays guarded and byte-compatible.
            return try await readAbsoluteFile(p)
        case "file.begin":
            let destination: URL
            let transferRoot: URL
            let relativePath: String
            if p["purpose"]?.string == "command" {
                let jobID = try required(p, "jobID")
                guard UUID(uuidString: jobID) != nil else { throw BridgeFailure.unsafePath }
                transferRoot = paths.root
                relativePath = "State/Commands/" + clientID + "/" + jobID
                destination = try BridgePaths.safe(relativePath, under: transferRoot)
            } else {
                transferRoot = try workspace(p)
                relativePath = try required(p, "path")
                destination = try BridgePaths.safe(relativePath, under: transferRoot)
            }
            let expected = p["expectedSHA256"]?.string
            try verifyExisting(destination, expected: expected)
            let id = UUID().uuidString
            let stage = paths.caches.appendingPathComponent("upload-" + id)
            let transferLease = try updateActivity.begin(.transfer)
            guard FileManager.default.createFile(atPath: stage.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                updateActivity.finish(transferLease)
                throw BridgeFailure.remote("Cannot prepare file transfer.")
            }
            transfers[id] = Transfer(root: transferRoot, relativePath: relativePath, stage: stage, expected: expected, clientID: clientID, expires: .now + transferLifetime, updateLease: transferLease)
            scheduleTransferExpiry()
            return ["transferID": .string(id), "maximumChunkBytes": .integer(Int64(BridgeWire.maximumFileChunkBytes))]
        case "file.chunk":
            let id = try required(p, "transferID")
            guard var transfer = transfers[id], transfer.clientID == clientID,
                  let encoded = p["data"]?.string, encoded.utf8.count <= ((BridgeWire.maximumFileChunkBytes + 2) / 3) * 4,
                  let data = Data(base64Encoded: encoded), data.count <= BridgeWire.maximumFileChunkBytes else { throw BridgeFailure.remote("Unknown transfer.") }
            let writer = try FileHandle(forWritingTo: transfer.stage); defer { try? writer.close() }
            guard transfer.expires > .now, let offset = p["offset"]?.integer, offset >= 0,
                  !data.isEmpty, try writer.seekToEnd() == UInt64(offset) else { throw BridgeFailure.remote("The transfer position changed.") }
            try writer.write(contentsOf: data)
            transfer.expires = .now + transferLifetime; transfers[id] = transfer
            return [:]
        case "file.abort":
            let id = try required(p, "transferID")
            guard let transfer = transfers[id], transfer.clientID == clientID else { return [:] }
            try? FileManager.default.removeItem(at: transfer.stage); transfers.removeValue(forKey: id)
            updateActivity.finish(transfer.updateLease); return [:]
        case "file.commit":
            let id = try required(p, "transferID")
            guard let transfer = transfers[id], transfer.clientID == clientID else { throw BridgeFailure.remote("Unknown transfer.") }
            defer {
                transfers.removeValue(forKey: id); try? FileManager.default.removeItem(at: transfer.stage)
                updateActivity.finish(transfer.updateLease)
            }
            guard transfer.expires > .now else { throw BridgeFailure.remote("The file transfer expired.") }
            guard try digest(transfer.stage) == required(p, "sha256") else { throw BridgeFailure.remote("The transferred file did not match.") }
            try BridgeSafeFileSystem.commit(staged: transfer.stage, relativePath: transfer.relativePath,
                under: transfer.root, expectedSHA256: transfer.expected)
            return [:]
        case "revoke": try await revoke(clientID); return [:]
        case "permissions": return try await permissions(request: nil)
        case "permissions.request":
            guard let capability = p["capability"]?.string, ["screenCapture", "accessibility"].contains(capability) else { throw BridgeFailure.remote("Choose the permission to request.") }
            return try await permissions(request: capability)
        case "screen.capture": return try await captureScreen()
        case "accessibility.inspect": return try await inspectAccessibility()
        case "storage": return try await storage()
        case "cleanup": return try await cleanup(p)
        case "skill.list", "skill.activate", "skill.remove", "skill.pin", "skill.unpin": return try await skill(method, p)
        default: throw BridgeFailure.remote("This bridge operation is unavailable. Update both apps.")
        }
    }
    private func listWorkspaceFiles(_ payload: [String: BridgeValue], client: String) throws -> [String: BridgeValue] {
        let root = try workspace(payload)
        let id = payload["listingID"]?.string
        if payload["listingID"] != nil {
            guard let id, UUID(uuidString: id) != nil else { throw BridgeFailure.invalidResponse }
        }
        let key = ListingKey(client: client, workspace: try required(payload, "workspaceID"), id: id)
        let offset = Int(payload["offset"]?.integer ?? 0)
        let now = ContinuousClock.now
        listings = listings.filter { $0.value.expires > now }
        let files: [[String: BridgeValue]]
        if offset == 0 {
            // Old clients have one cursor per client and workspace. Reject an
            // overlapping start instead of splicing two different listings.
            guard listings[key] == nil else { throw BridgeFailure.remote("A workspace file list is already in progress. Try again.") }
            files = try BridgePaths.files(in: root)
        } else {
            guard let listing = listings[key], listing.next == offset else {
                throw BridgeFailure.remote("The workspace file list expired or changed. Start it again.")
            }
            files = listing.files
        }
        let end = min(offset + 100, files.count)
        var reply: [String: BridgeValue] = ["files": .array(files[offset..<end].map(BridgeValue.object)), "next": .null]
        if let id { reply["listingID"] = .string(id) }
        if end < files.count {
            if offset == 0 {
                let retained = listings.values.reduce(0) { $0 + $1.files.count }
                guard listings.count < 8, retained + files.count <= BridgeResponseValidation.maximumListedFiles else {
                    throw BridgeFailure.remote("There are too many workspace file lists in progress. Try again.")
                }
            }
            listings[key] = Listing(files: files, next: end, expires: .now + listingLifetime)
            reply["next"] = .integer(Int64(end))
        } else {
            listings.removeValue(forKey: key)
        }
        return reply
    }
    private func digest(_ url: URL) throws -> String {
        let reader = try FileHandle(forReadingFrom: url); defer { try? reader.close() }
        var hash = SHA256()
        while let data = try reader.read(upToCount: 256 * 1_024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func verifyExisting(_ file: URL, expected: String?) throws {
        if FileManager.default.fileExists(atPath: file.path) {
            guard let expected, try digest(file) == expected else { throw BridgeFailure.remote("This file changed on the Mac. Review both versions before continuing.") }
        } else if expected != nil { throw BridgeFailure.remote("This file was removed on the Mac. Review before continuing.") }
    }
}
#endif
