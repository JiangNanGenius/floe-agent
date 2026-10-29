import Foundation
import CryptoKit
import FloeCore
import FloeTools
import FloeMacBridgeProtocol

/// Paired same-Mac transport. Requests are signed, responses are pinned, and
/// an interrupted mutation is never automatically retried.
private final class MacBridgeSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Signed request bytes must never be forwarded to another endpoint.
        completionHandler(nil)
    }
}

public actor MacBridgeClient {
    public static let shared = MacBridgeClient()
    private let keychainService = "org.floeagent.bridge.client"
    private var key: Curve25519.Signing.PrivateKey?
    private var serverKey: Data?
    public static let availabilityDidChange = Notification.Name("org.floeagent.macBridge.availabilityDidChange")
    private var connected = false {
        didSet {
            if oldValue != connected {
                NotificationCenter.default.post(name: Self.availabilityDidChange, object: nil, userInfo: ["connected": connected])
            }
        }
    }
    private var candidateKey: Data?
    private var pairingNonce: String?
    private var candidateApproved = false
    private var baseline: [String: [String: String]] = [:]
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil; config.httpCookieStorage = nil
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config, delegate: MacBridgeSessionDelegate(), delegateQueue: nil)
    }
    public func bootstrap() async throws {
        key = try BridgeKeychain.signingKey(service: keychainService)
        serverKey = try BridgeKeychain.read(service: keychainService, account: "server-public-key-v1")
        if let url = try? baselineURL(), let data = try? Data(contentsOf: url) {
            baseline = (try? BridgeWire.decode([String: [String: String]].self, from: data)) ?? [:]
        }
        guard serverKey != nil else { connected = false; return }
        _ = try await call("ping")
    }
    public func isConnected() -> Bool { connected && serverKey != nil }
    public func hasPairing() -> Bool { serverKey != nil }
    public func beginPairing(name: String = "Floe") async throws -> Bool {
        if key == nil { key = try BridgeKeychain.signingKey(service: keychainService) }
        if serverKey != nil {
            // Existing trust is never replaced by an unpinned response.
            _ = try await call("ping"); return true
        }
        if pairingNonce == nil { pairingNonce = UUID().uuidString + UUID().uuidString }
        guard let nonce = pairingNonce else { throw BridgeFailure.authentication }
        let (result, responseKey) = try await send("pair", ["name": .string(name), "nonce": .string(nonce)], paired: false)
        guard result["nonce"]?.string == nonce else { throw BridgeFailure.authentication }
        if let candidateKey, candidateKey != responseKey { throw BridgeFailure.authentication }
        candidateKey = responseKey
        candidateApproved = result["paired"]?.bool == true
        // The caller must explicitly match the companion's native fingerprint.
        return candidateApproved
    }
    public func pairingVerification() throws -> String? {
        guard serverKey == nil, let candidateKey, let key, let nonce = pairingNonce else { return nil }
        return BridgeWire.pairingVerification(clientKey: key.publicKey.rawRepresentation, serverKey: candidateKey, nonce: nonce)
    }
    public func confirmPairing(verification: String) throws {
        guard candidateApproved, let candidateKey, verification == (try pairingVerification()) else { throw BridgeFailure.authentication }
        try BridgeKeychain.save(candidateKey, service: keychainService, account: "server-public-key-v1")
        serverKey = candidateKey; connected = true
        cancelPairing()
    }
    public func cancelPairing() { candidateKey = nil; pairingNonce = nil; candidateApproved = false }
    public func disconnect(revoke: Bool = true) async throws {
        if revoke, serverKey != nil { _ = try await call("revoke") }
        try BridgeKeychain.remove(service: keychainService, account: "server-public-key-v1")
        serverKey = nil; cancelPairing(); connected = false
    }
    public func call(_ method: String, _ payload: [String: BridgeValue] = [:]) async throws -> [String: BridgeValue] {
        guard serverKey != nil else { throw BridgeFailure.disconnected }
        return try await send(method, payload, paired: true).0
    }
    private func send(_ method: String, _ payload: [String: BridgeValue], paired: Bool) async throws -> ([String: BridgeValue], Data) {
        guard let key else { throw BridgeFailure.disconnected }
        let body = BridgeRequestBody(clientKey: key.publicKey.rawRepresentation, method: method, payload: payload)
        let bytes = try BridgeWire.encode(BridgeRequest(body: body, key: key))
        guard bytes.count <= BridgeWire.maximumFrameBytes else { throw BridgeFailure.remote("The request is too large. Transfer the file in chunks.") }
        var request = URLRequest(url: BridgeWire.endpoint)
        request.httpMethod = "POST"; request.httpBody = bytes
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  data.count <= BridgeWire.maximumFrameBytes else { throw BridgeFailure.disconnected }
            let signed = try BridgeWire.decode(BridgeResponse.self, from: data)
            let result = try signed.verified(for: body, pinnedKey: paired ? serverKey : candidateKey)
            if paired { connected = true }
            return (result, signed.body.serverKey)
        } catch is CancellationError { throw CancellationError() }
        catch let error as BridgeFailure {
            if case .remote = error { if paired { connected = true } }
            else { connected = false }
            throw error
        }
        catch { connected = false; throw BridgeFailure.ambiguous }
    }
    public func workspaceID(for root: URL) -> String {
        BridgeWire.digest(Data(root.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
    }
    public func workspace(root: URL) async throws -> (id: String, path: String) {
        let id = workspaceID(for: root)
        let result = try await call("workspace", ["workspaceID": .string(id)])
        guard let path = result["root"]?.string else { throw BridgeFailure.incompatible }
        return (id, path)
    }
    public func files(workspaceID: String) async throws -> [[String: BridgeValue]] {
        var result: [[String: BridgeValue]] = []; var offset: Int64 = 0
        repeat {
            let page = try await call("file.list", ["workspaceID": .string(workspaceID), "offset": .integer(offset)])
            result += (page["files"]?.array ?? []).compactMap(\.object)
            guard let next = page["next"]?.integer, next > offset else { break }
            offset = next
        } while true
        return result
    }
    /// Shell script size is not a transport limit. Larger commands travel in
    /// bounded chunks to private, task-owned storage and never enter argv.
    public func stageCommand(_ command: String, jobID: String, cancellation: CancellationToken? = nil) async throws -> String {
        let bytes = Data(command.utf8)
        let digest = BridgeWire.digest(bytes)
        let transfer = try await call("file.begin", ["purpose": .string("command"), "jobID": .string(jobID)])
        guard let id = transfer["transferID"]?.string else { throw BridgeFailure.incompatible }
        defer { Task { [self] in _ = try? await call("file.abort", ["transferID": .string(id)]) } }
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation(); try cancellation?.throwIfCancelled()
            let end = min(offset + BridgeWire.pageBytes, bytes.count)
            _ = try await call("file.chunk", ["transferID": .string(id), "offset": .integer(Int64(offset)),
                "data": .string(bytes[offset..<end].base64EncodedString())])
            offset = end
        }
        try cancellation?.throwIfCancelled()
        _ = try await call("file.commit", ["transferID": .string(id), "sha256": .string(digest)])
        return digest
    }
    public func upload(_ file: URL, path: String, workspaceID: String, expected: String?) async throws {
        let digest = try Self.digest(file)
        let transfer = try await call("file.begin", ["workspaceID": .string(workspaceID), "path": .string(path),
            "expectedSHA256": expected.map(BridgeValue.string) ?? .null])
        guard let id = transfer["transferID"]?.string else { throw BridgeFailure.incompatible }
        defer {
            Task { [self] in _ = try? await call("file.abort", ["transferID": .string(id)]) }
        }
        let reader = try FileHandle(forReadingFrom: file); defer { try? reader.close() }
        var offset: Int64 = 0
        while let data = try reader.read(upToCount: BridgeWire.pageBytes), !data.isEmpty {
            try Task.checkCancellation()
            _ = try await call("file.chunk", ["transferID": .string(id), "offset": .integer(offset), "data": .string(data.base64EncodedString())])
            offset += Int64(data.count)
        }
        _ = try await call("file.commit", ["transferID": .string(id), "sha256": .string(digest)])
    }
    public func synchronizeBeforeExecution(root: URL) async throws -> String {
        let workspace = try await workspace(root: root)
        let local = try Self.localFiles(root: root)
        let remote = try await files(workspaceID: workspace.id)
        let remoteHashes = Dictionary(uniqueKeysWithValues: remote.compactMap { row -> (String, String)? in
            guard let path = row["path"]?.string, let hash = row["sha256"]?.string else { return nil }; return (path, hash)
        })
        let previous = baseline[workspace.id] ?? [:]
        for (path, hash) in local where remoteHashes[path] != hash {
            if let remoteHash = remoteHashes[path], previous[path] != remoteHash {
                // A remote-only change is downloaded; two simultaneous edits
                // require review rather than overwriting either copy.
                if previous[path] == hash { continue }
                throw BridgeFailure.remote("A workspace file changed on both devices: \(path). Review both copies before running.")
            }
            if remoteHashes[path] == nil, previous[path] == hash { continue }
            _ = try Self.safe(path, root: root)
            try await upload(root.appendingPathComponent(path), path: path, workspaceID: workspace.id, expected: remoteHashes[path])
        }
        // Files created/edited on Mac are reconciled before a new command as
        // well as after completion, so app tools see real current artifacts.
        baseline[workspace.id] = local
        try await synchronizeAfterExecution(root: root)
        return workspace.id
    }
    public func synchronizeAfterExecution(root: URL) async throws {
        let trustedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let id = workspaceID(for: root), previous = baseline[id] ?? [:]
        let remote = try await files(workspaceID: id)
        var current = try Self.localFiles(root: root)
        for row in remote {
            guard let path = row["path"]?.string, let hash = row["sha256"]?.string, let total = row["size"]?.integer else { throw BridgeFailure.incompatible }
            if current[path] == hash { continue }
            guard current[path] == previous[path] else { throw BridgeFailure.remote("The local file changed while the Mac was working: \(path). Both copies were retained.") }
            let target = try Self.safe(path, root: root)
            let privateTransfers = try baselineURL().deletingLastPathComponent().appendingPathComponent("Transfers", isDirectory: true)
            try FileManager.default.createDirectory(at: privateTransfers, withIntermediateDirectories: true)
            let stage = privateTransfers.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: stage) }
            guard FileManager.default.createFile(atPath: stage.path, contents: nil) else { throw BridgeFailure.unsafePath }
            let writer = try FileHandle(forWritingTo: stage)
            var offset: Int64 = 0
            do {
                while offset < total {
                    try Task.checkCancellation()
                    let page = try await call("file.read", ["workspaceID": .string(id), "path": .string(path), "offset": .integer(offset)])
                    guard let text = page["data"]?.string, let data = Data(base64Encoded: text), !data.isEmpty,
                          offset + Int64(data.count) <= total else { throw BridgeFailure.incompatible }
                    try writer.write(contentsOf: data); offset += Int64(data.count)
                }
                try writer.close()
            } catch { try? writer.close(); throw error }
            guard try Self.digest(stage) == hash else { throw BridgeFailure.remote("The Mac file changed during transfer. The original was kept.") }
            let latest = FileManager.default.fileExists(atPath: target.path) ? try Self.digest(target) : nil
            guard latest == current[path] else { throw BridgeFailure.remote("The local file changed during transfer. The original was kept.") }
            try BridgeSafeFileSystem.commit(staged: stage, relativePath: path,
                under: trustedRoot, expectedSHA256: current[path])
            current[path] = hash
        }
        let remotePaths = Set(remote.compactMap { $0["path"]?.string })
        for (path, oldHash) in previous where !remotePaths.contains(path) && current[path] != nil {
            guard current[path] == oldHash else {
                throw BridgeFailure.remote("A file removed on the Mac was also edited locally: \(path). Both states were retained.")
            }
            let recovery = try baselineURL().deletingLastPathComponent()
                .appendingPathComponent("Recovered Files/" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
            try BridgeSafeFileSystem.moveToRecovery(relativePath: path, under: trustedRoot,
                expectedSHA256: oldHash, recoveryRoot: recovery.resolvingSymlinksInPath().standardizedFileURL)
            current.removeValue(forKey: path)
        }
        baseline[id] = current
        try saveBaseline()
    }
    public struct SavedJob: Codable, Sendable, Identifiable {
        public let id: String
        public let rootPath: String
        public let sessionID: String
        public let submittedAt: Date
    }
    public func recordJobAttempt(id: String, root: URL, sessionID: String) throws {
        var rows = try savedJobs()
        guard !rows.contains(where: { $0.id == id }) else { throw BridgeFailure.ambiguous }
        rows.append(SavedJob(id: id, rootPath: root.path, sessionID: sessionID, submittedAt: Date()))
        try BridgeWire.encode(rows).write(to: baselineURL().deletingLastPathComponent().appendingPathComponent("submitted-jobs.json"), options: .atomic)
    }
    public func savedJobs() throws -> [SavedJob] {
        let url = try baselineURL().deletingLastPathComponent().appendingPathComponent("submitted-jobs.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try BridgeWire.decode([SavedJob].self, from: Data(contentsOf: url))
    }
    /// Retry delivery for the persisted job only. This never submits a command.
    public func synchronizeJobFiles(id: String) async throws {
        guard let job = try savedJobs().first(where: { $0.id == id }),
              FileManager.default.fileExists(atPath: job.rootPath) else { throw BridgeFailure.unsafePath }
        let status = try await call("poll", ["jobID": .string(id), "offset": .integer(0), "limit": .integer(1)])
        guard status["alive"]?.bool == false, status["outcomeUnknown"]?.bool != true else {
            throw BridgeFailure.remote("Wait for a confirmed command exit before syncing its files.")
        }
        try await synchronizeAfterExecution(root: URL(fileURLWithPath: job.rootPath, isDirectory: true))
    }
    public func saveJobOutput(id: String) async throws -> URL {
        guard UUID(uuidString: id) != nil else { throw BridgeFailure.unsafePath }
        let root = try baselineURL().deletingLastPathComponent().appendingPathComponent("Task Outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(id + ".log")
        let stage = root.appendingPathComponent(".transfer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        guard FileManager.default.createFile(atPath: stage.path, contents: nil) else { throw BridgeFailure.unsafePath }
        let writer = try FileHandle(forWritingTo: stage); defer { try? writer.close() }
        var offset: Int64 = 0; var snapshotBytes: Int64?
        repeat {
            let page = try await call("poll", ["jobID": .string(id), "offset": .integer(offset), "limit": .integer(Int64(BridgeWire.pageBytes))])
            guard let text = page["data"]?.string, let data = Data(base64Encoded: text), let total = page["totalBytes"]?.integer else { throw BridgeFailure.incompatible }
            if snapshotBytes == nil { snapshotBytes = total }
            let remaining = max(0, (snapshotBytes ?? 0) - offset)
            let bounded = data.prefix(Int(min(remaining, Int64(data.count))))
            try writer.write(contentsOf: bounded); offset += Int64(bounded.count)
            if data.isEmpty && offset < (snapshotBytes ?? 0) { throw BridgeFailure.disconnected }
        } while offset < (snapshotBytes ?? 0)
        try writer.close()
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: stage) }
        else { try FileManager.default.moveItem(at: stage, to: destination) }
        return destination
    }
    private func baselineURL() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FloeMacBridgeClient")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("workspace-baselines.json")
    }
    private func saveBaseline() throws { try BridgeWire.encode(baseline).write(to: baselineURL(), options: .atomic) }
    public static func digest(_ url: URL) throws -> String {
        let reader = try FileHandle(forReadingFrom: url); defer { try? reader.close() }; var hash = SHA256()
        while let data = try reader.read(upToCount: 256 * 1_024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func localFiles(root: URL) throws -> [String: String] {
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [:] }
        var result: [String: String] = [:]
        for case let file as URL in iterator {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            if BridgeWorkspaceTransferPolicy.excludes(relative) { iterator.skipDescendants(); continue }
            let value = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if value.isSymbolicLink == true { iterator.skipDescendants(); continue }
            if file.lastPathComponent.hasPrefix(".bridge-transfer-") { continue }
            if value.isRegularFile == true { result[String(file.path.dropFirst(root.path.count + 1))] = try digest(file) }
        }
        return result
    }
    private static func safe(_ path: String, root: URL) throws -> URL {
        guard !path.hasPrefix("/"), !path.contains("\0"), path.split(separator: "/").allSatisfy({ $0 != ".." && $0 != "." }) else { throw BridgeFailure.unsafePath }
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw BridgeFailure.unsafePath }
        return file
    }
}
