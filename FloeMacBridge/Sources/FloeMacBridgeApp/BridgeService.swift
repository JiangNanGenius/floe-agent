#if os(macOS)
import Foundation
import CryptoKit
import AppKit
import ApplicationServices
import FloeMacBridgeProtocol

actor BridgeService {
    struct Pair: Codable, Sendable { let key: Data; let name: String; let acceptedAt: Date; let verification: String?; let nonce: String? }
    struct Delivery: Sendable { let data: Data; let lease: BridgeUpdateActivity.Lease }
    struct Transfer: Sendable { let root: URL; let relativePath: String; let stage: URL; let expected: String?; let clientID: String; var expires: ContinuousClock.Instant; let updateLease: BridgeUpdateActivity.Lease }
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
    private var pending: [String: (name: String, key: Data, nonce: String, verification: String, updateLease: BridgeUpdateActivity.Lease)] = [:]
    private var rejected: [String: String] = [:]
    var skillPins: [String: Set<String>] = [:]
    var consent: (@MainActor @Sendable (String, String, String) -> Void)?
    // A caller-supplied key permits isolated synthetic contract fixtures without
    // accessing the user's Keychain. The application uses the existing default.
    init(paths: BridgePaths, updateActivity: BridgeUpdateActivity = BridgeUpdateActivity(),
         signingKey: Curve25519.Signing.PrivateKey? = nil, transferLifetime: Duration = .seconds(900),
         listingLifetime: Duration = .seconds(120)) throws {
        self.paths = paths; self.updateActivity = updateActivity
        self.transferLifetime = transferLifetime
        self.listingLifetime = listingLifetime
        self.jobs = BridgeJobs(paths: paths, updateActivity: updateActivity)
        self.signingKey = try signingKey ?? BridgeKeychain.signingKey(service: "org.floeagent.bridge.server")
        let pairURL = paths.root.appendingPathComponent("State/paired-clients.json")
        pairs = (try? BridgeWire.decode([String: Pair].self, from: Data(contentsOf: pairURL))) ?? [:]
        skillPins = (try? BridgeWire.decode([String: Set<String>].self, from: Data(contentsOf: paths.root.appendingPathComponent("State/skill-pins.json")))) ?? [:]
        accepted = (try? BridgeWire.decode([String: Int64].self, from: Data(contentsOf: paths.root.appendingPathComponent("State/request-ids.json")))) ?? [:]
    }
    func setConsent(_ callback: @escaping @MainActor @Sendable (String, String, String) -> Void) { consent = callback }
    func approve(_ clientID: String, verification: String, allow: Bool) throws {
        let operation = try updateActivity.begin(.maintenance)
        defer { updateActivity.finish(operation) }
        guard let proposal = pending[clientID], proposal.verification == verification else { return }
        pending.removeValue(forKey: clientID)
        defer { updateActivity.finish(proposal.updateLease) }
        if allow {
            pairs[clientID] = Pair(key: proposal.key, name: proposal.name, acceptedAt: Date(), verification: proposal.verification, nonce: proposal.nonce)
            try savePairs()
        } else { rejected[clientID] = proposal.nonce }
    }
    func pairedClients() -> [(String, String)] { pairs.map { ($0.key, $0.value.name + ($0.value.verification.map { " · " + $0 } ?? "")) } }
    func revoke(_ clientID: String) async throws {
        let operation = try updateActivity.begin(.maintenance)
        defer { updateActivity.finish(operation) }
        pairs.removeValue(forKey: clientID); try savePairs()
        listings = listings.filter { $0.key.client != clientID }
        for (id, transfer) in transfers where transfer.clientID == clientID {
            try? FileManager.default.removeItem(at: transfer.stage); transfers.removeValue(forKey: id)
            updateActivity.finish(transfer.updateLease)
        }
        await jobs.cancelAll(clientID: clientID)
    }
    private func savePairs() throws {
        try BridgeWire.encode(pairs).write(to: paths.root.appendingPathComponent("State/paired-clients.json"), options: .atomic)
    }
    /// HTTP owns this lease until the full signed reply finishes sending.
    func respondForDelivery(_ request: BridgeRequest) async throws -> Delivery {
        let lease = try updateActivity.begin(.request)
        do { return Delivery(data: try await respond(request), lease: lease) }
        catch { updateActivity.finish(lease); throw error }
    }
    nonisolated func finishDelivery(_ lease: BridgeUpdateActivity.Lease) { updateActivity.finish(lease) }
    nonisolated func reserveUpdateInstallationIfIdle() -> BridgeUpdateActivity.Installation? {
        updateActivity.reserveInstallationIfIdle()
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
                if let proposal = pending[clientID], proposal.nonce == nonce {
                    pending.removeValue(forKey: clientID)
                    updateActivity.finish(proposal.updateLease)
                }
                if rejected[clientID] == nonce { rejected.removeValue(forKey: clientID) }
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
                        pending[clientID] = (name, body.clientKey, nonce, verification, try updateActivity.begin(.consent))
                        if let consent { await consent(clientID, name, verification) }
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
