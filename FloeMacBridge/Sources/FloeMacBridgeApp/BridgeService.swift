#if os(macOS)
import Foundation
import CryptoKit
import AppKit
import ApplicationServices
import FloeMacBridgeProtocol

actor BridgeService {
    struct Pair: Codable, Sendable { let key: Data; let name: String; let acceptedAt: Date; let verification: String?; let nonce: String? }
    struct Transfer: Sendable { let root: URL; let relativePath: String; let stage: URL; let expected: String?; let clientID: String; var updatedAt: Date }
    let paths: BridgePaths
    let jobs: BridgeJobs
    let signingKey: Curve25519.Signing.PrivateKey
    private var pairs: [String: Pair]
    private var accepted: [String: Int64] = [:]
    private var transfers: [String: Transfer] = [:]
    private var pending: [String: (name: String, key: Data, nonce: String, verification: String)] = [:]
    private var rejected = Set<String>()
    var skillPins: [String: Set<String>] = [:]
    var consent: (@MainActor @Sendable (String, String, String) -> Void)?
    init(paths: BridgePaths) throws {
        self.paths = paths; self.jobs = BridgeJobs(paths: paths)
        signingKey = try BridgeKeychain.signingKey(service: "org.floeagent.bridge.server")
        let pairURL = paths.root.appendingPathComponent("State/paired-clients.json")
        pairs = (try? BridgeWire.decode([String: Pair].self, from: Data(contentsOf: pairURL))) ?? [:]
        skillPins = (try? BridgeWire.decode([String: Set<String>].self, from: Data(contentsOf: paths.root.appendingPathComponent("State/skill-pins.json")))) ?? [:]
        accepted = (try? BridgeWire.decode([String: Int64].self, from: Data(contentsOf: paths.root.appendingPathComponent("State/request-ids.json")))) ?? [:]
    }
    func setConsent(_ callback: @escaping @MainActor @Sendable (String, String, String) -> Void) { consent = callback }
    func approve(_ clientID: String, allow: Bool) throws {
        guard let proposal = pending.removeValue(forKey: clientID) else { return }
        if allow {
            pairs[clientID] = Pair(key: proposal.key, name: proposal.name, acceptedAt: Date(), verification: proposal.verification, nonce: proposal.nonce)
            try savePairs()
        } else { rejected.insert(clientID) }
    }
    func pairedClients() -> [(String, String)] { pairs.map { ($0.key, $0.value.name + ($0.value.verification.map { " · " + $0 } ?? "")) } }
    func revoke(_ clientID: String) async throws {
        pairs.removeValue(forKey: clientID); try savePairs()
        for (id, transfer) in transfers where transfer.clientID == clientID {
            try? FileManager.default.removeItem(at: transfer.stage); transfers.removeValue(forKey: id)
        }
        await jobs.cancelAll(clientID: clientID)
    }
    private func savePairs() throws {
        try BridgeWire.encode(pairs).write(to: paths.root.appendingPathComponent("State/paired-clients.json"), options: .atomic)
    }
    func respond(_ request: BridgeRequest) async throws -> Data {
        try request.verify()
        let body = request.body; let clientID = BridgeWire.digest(body.clientKey)
        let result: [String: BridgeValue]
        do {
            if body.method == "pair" || body.method == "pairStatus" {
                guard let nonce = body.payload["nonce"]?.string, nonce.count >= 32, nonce.count <= 160 else { throw BridgeFailure.authentication }
                if let pair = pairs[clientID], pair.key == body.clientKey, pair.nonce == nonce {
                    result = ["paired": .bool(true), "host": .string(Host.current().localizedName ?? "Mac"),
                              "protocolVersion": .integer(Int64(BridgeWire.version)), "nonce": .string(nonce)]
                } else if rejected.contains(clientID) { throw BridgeFailure.remote("The Mac connection was declined.") }
                else {
                    guard pending.count < 4 || pending[clientID] != nil else { throw BridgeFailure.remote("Another connection request is waiting.") }
                    if pending[clientID] == nil {
                        let name = String(String.UnicodeScalarView((body.payload["name"]?.string ?? "Floe").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })).prefix(80).description
                        let verification = BridgeWire.pairingVerification(clientKey: body.clientKey, serverKey: signingKey.publicKey.rawRepresentation, nonce: nonce)
                        pending[clientID] = (name, body.clientKey, nonce, verification)
                        if let consent { await consent(clientID, name, verification) }
                    }
                    guard pending[clientID]?.nonce == nonce else { throw BridgeFailure.authentication }
                    result = ["paired": .bool(false), "nonce": .string(nonce)]
                }
            } else {
                guard pairs[clientID]?.key == body.clientKey else { throw BridgeFailure.authentication }
                if !["ping", "poll", "file.list", "file.read", "permissions", "skill.list", "storage"].contains(body.method) {
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
        for (id, transfer) in transfers where Date().timeIntervalSince(transfer.updatedAt) > 900 {
            try? FileManager.default.removeItem(at: transfer.stage); transfers.removeValue(forKey: id)
        }
        return transfers.isEmpty
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
        case "ping": return ["host": .string(Host.current().localizedName ?? "Mac"), "os": .string("macos"), "arch": .string("arm64"),
                            "capabilities": .array(["terminal", "pty", "files", "mcp", "originalSkills", "screenCapture", "accessibility"].map(BridgeValue.string))]
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
            return try await jobs.start(id: jobID, clientID: clientID,
                workspaceID: required(p, "workspaceID"), command: p["command"]?.string ?? "", commandFile: commandFile, cwd: cwd,
                environment: environment, columns: Int(p["columns"]?.integer ?? 100), rows: Int(p["rows"]?.integer ?? 30))
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
            let files = try BridgePaths.files(in: workspace(p)); let offset = max(0, Int(p["offset"]?.integer ?? 0))
            let page = Array(files.dropFirst(offset).prefix(100))
            return ["files": .array(page.map(BridgeValue.object)), "next": offset + page.count < files.count ? .integer(Int64(offset + page.count)) : .null]
        case "file.read":
            let file = try BridgePaths.safe(required(p, "path"), under: workspace(p))
            let reader = try FileHandle(forReadingFrom: file); defer { try? reader.close() }
            let offset = max(0, p["offset"]?.integer ?? 0); try reader.seek(toOffset: UInt64(offset))
            let data = try reader.read(upToCount: BridgeWire.pageBytes) ?? Data()
            return ["data": .string(data.base64EncodedString()), "offset": .integer(offset + Int64(data.count))]
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
            guard FileManager.default.createFile(atPath: stage.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw BridgeFailure.remote("Cannot prepare file transfer.") }
            transfers[id] = Transfer(root: transferRoot, relativePath: relativePath, stage: stage, expected: expected, clientID: clientID, updatedAt: Date())
            return ["transferID": .string(id)]
        case "file.chunk":
            let id = try required(p, "transferID")
            guard var transfer = transfers[id], transfer.clientID == clientID, let data = Data(base64Encoded: try required(p, "data")), data.count <= BridgeWire.pageBytes else { throw BridgeFailure.remote("Unknown transfer.") }
            let writer = try FileHandle(forWritingTo: transfer.stage); defer { try? writer.close() }
            guard try writer.seekToEnd() == UInt64(max(0, p["offset"]?.integer ?? 0)) else { throw BridgeFailure.remote("The transfer position changed.") }
            try writer.write(contentsOf: data)
            transfer.updatedAt = Date(); transfers[id] = transfer
            return [:]
        case "file.abort":
            let id = try required(p, "transferID")
            guard let transfer = transfers[id], transfer.clientID == clientID else { return [:] }
            try? FileManager.default.removeItem(at: transfer.stage); transfers.removeValue(forKey: id); return [:]
        case "file.commit":
            let id = try required(p, "transferID")
            guard let transfer = transfers[id], transfer.clientID == clientID else { throw BridgeFailure.remote("Unknown transfer.") }
            defer { transfers.removeValue(forKey: id); try? FileManager.default.removeItem(at: transfer.stage) }
            guard try digest(transfer.stage) == required(p, "sha256") else { throw BridgeFailure.remote("The transferred file did not match.") }
            try BridgeSafeFileSystem.commit(staged: transfer.stage, relativePath: transfer.relativePath,
                under: transfer.root, expectedSHA256: transfer.expected)
            return [:]
        case "revoke": try await revoke(clientID); return [:]
        case "permissions": return await permissions(request: nil)
        case "permissions.request":
            guard let capability = p["capability"]?.string, ["screenCapture", "accessibility"].contains(capability) else { throw BridgeFailure.remote("Choose the permission to request.") }
            return await permissions(request: capability)
        case "screen.capture": return try await captureScreen()
        case "accessibility.inspect": return try await inspectAccessibility()
        case "storage": return try await storage()
        case "cleanup": return try await cleanup(p)
        case "skill.list", "skill.activate", "skill.remove", "skill.pin", "skill.unpin": return try await skill(method, p)
        default: throw BridgeFailure.remote("This bridge operation is unavailable. Update both apps.")
        }
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
