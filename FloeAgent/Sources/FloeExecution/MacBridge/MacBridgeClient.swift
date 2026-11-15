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
    private var trustGeneration = UUID()
    private var identityRestored = false
    public static let availabilityDidChange = Notification.Name("org.floeagent.macBridge.availabilityDidChange")
    private var connected = false {
        didSet {
            if oldValue != connected {
                NotificationCenter.default.post(name: Self.availabilityDidChange, object: nil, userInfo: ["connected": connected])
            }
        }
    }
    private var pairing = BridgePairingSession()
    private var baseline: [String: [String: String]] = [:]
    private var legacyBaseline: [String: [String: String]] = [:]
    private var workspaceWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private let storageRoot: URL?
    /// Authenticated capability names, cached for one trust generation.
    private var negotiatedCapabilities: (generation: UUID, names: Set<String>)?
    private let session: URLSession
    public init() {
        storageRoot = nil
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil; config.httpCookieStorage = nil
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config, delegate: MacBridgeSessionDelegate(), delegateQueue: nil)
    }
    /// Isolated signed peer for component hosts. The normal platform check,
    /// wire signature, response pin and file-commit checks still apply.
    init(session: URLSession, clientKey: Curve25519.Signing.PrivateKey, serverKey: Data, storageRoot: URL) {
        self.session = session; self.storageRoot = storageRoot
        self.key = clientKey; self.serverKey = serverKey; self.identityRestored = true
        baseline = Self.savedHashes(at: storageRoot.appendingPathComponent("workspace-common-v2.json"))
        legacyBaseline = Self.savedHashes(at: storageRoot.appendingPathComponent("workspace-baselines.json"))
    }
    public func bootstrap() async throws {
        try restorePairingIdentity()
        guard serverKey != nil else { connected = false; return }
        _ = try await call("ping")
    }
    /// Restore saved trust without a network request or an implicit new key.
    /// Target selection must distinguish a saved offline Mac from no pairing.
    public func restoredPairing() throws -> Bool {
        try restorePairingIdentity()
        return serverKey != nil
    }
    private func restorePairingIdentity() throws {
        try requireSupportedPlatform()
        guard !identityRestored else { return }
        let savedKey = try BridgeKeychain.read(service: keychainService, account: "server-public-key-v1")
        if savedKey != serverKey { trustGeneration = UUID() }
        serverKey = savedKey
        if let savedKey {
            _ = try Curve25519.Signing.PublicKey(rawRepresentation: savedKey)
            guard let identity = try BridgeKeychain.read(service: keychainService, account: "identity-v1") else {
                throw BridgeFailure.authentication
            }
            key = try Curve25519.Signing.PrivateKey(rawRepresentation: identity)
        }
        let url = try baselineURL()
        baseline = Self.savedHashes(at: url)
        legacyBaseline = Self.savedHashes(at: url.deletingLastPathComponent().appendingPathComponent("workspace-baselines.json"))
        identityRestored = true
    }
    public func isConnected() -> Bool { LocalBridgePlatform.current.supportsMacBridge && connected && serverKey != nil }
    public func hasPairing() -> Bool { LocalBridgePlatform.current.supportsMacBridge && serverKey != nil }
    public func beginPairing(name: String = "Floe") async throws -> Bool {
        try Task.checkCancellation()
        try restorePairingIdentity()
        if key == nil { key = try BridgeKeychain.signingKey(service: keychainService) }
        if serverKey != nil {
            // Existing trust is never replaced by an unpinned response.
            _ = try await call("ping"); return true
        }
        let attempt = pairing.begin()
        let (result, responseKey) = try await send("pair", ["name": .string(name), "nonce": .string(attempt.nonce)], paired: false)
        try pairing.accept(attempt, nonce: result["nonce"]?.string,
                           serverKey: responseKey, approved: result["paired"]?.bool == true)
        // The caller must explicitly match the companion's native fingerprint.
        return pairing.approved
    }
    public func pairingVerification() throws -> String? {
        guard serverKey == nil, let key else { return nil }
        return pairing.verification(clientKey: key.publicKey.rawRepresentation)
    }
    public func confirmPairing(verification: String) throws {
        try requireSupportedPlatform()
        guard let key else { throw BridgeFailure.authentication }
        let candidateKey = try pairing.approvedKey(clientKey: key.publicKey.rawRepresentation, verification: verification)
        try BridgeKeychain.save(candidateKey, service: keychainService, account: "server-public-key-v1")
        trustGeneration = UUID(); serverKey = candidateKey; connected = true
        pairing.cancel()
    }
    public func cancelPairing() async {
        let attempt = pairing.attempt
        pairing.cancel() // Fence before awaiting the companion's best-effort cleanup.
        if let attempt {
            _ = try? await send("pairCancel", ["nonce": .string(attempt.nonce)], paired: false)
        }
    }
    public func disconnect(revoke: Bool = true) async throws {
        try requireSupportedPlatform()
        trustGeneration = UUID()
        if revoke, serverKey != nil { _ = try await call("revoke") }
        try BridgeKeychain.remove(service: keychainService, account: "server-public-key-v1")
        trustGeneration = UUID(); serverKey = nil; identityRestored = true
        pairing.cancel(); connected = false
    }
    public func call(_ method: String, _ payload: [String: BridgeValue] = [:]) async throws -> [String: BridgeValue] {
        try requireSupportedPlatform()
        guard serverKey != nil else { throw BridgeFailure.disconnected }
        return try await send(method, payload, paired: true).0
    }
    private func call(_ method: String, _ payload: [String: BridgeValue], owner: UUID) async throws -> [String: BridgeValue] {
        guard trustGeneration == owner else { throw CancellationError() }
        let reply = try await call(method, payload)
        guard trustGeneration == owner else { throw CancellationError() }
        return reply
    }
    private func send(_ method: String, _ payload: [String: BridgeValue], paired: Bool) async throws -> ([String: BridgeValue], Data) {
        try requireSupportedPlatform()
        guard let key else { throw BridgeFailure.disconnected }
        let body = BridgeRequestBody(clientKey: key.publicKey.rawRepresentation, method: method, payload: payload)
        let bytes = try BridgeWire.encode(BridgeRequest(body: body, key: key))
        let pinnedKey = paired ? serverKey : pairing.candidateKey
        let generation = trustGeneration
        guard bytes.count <= BridgeWire.maximumFrameBytes else { throw BridgeFailure.remote("The request is too large. Transfer the file in chunks.") }
        var request = URLRequest(url: BridgeWire.endpoint)
        if method == "pairCancel" { request.timeoutInterval = 2 }
        request.httpMethod = "POST"; request.httpBody = bytes
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  data.count <= BridgeWire.maximumFrameBytes else { throw BridgeFailure.disconnected }
            let signed = try BridgeWire.decode(BridgeResponse.self, from: data)
            let result = try signed.verified(for: body, pinnedKey: pinnedKey)
            if paired {
                guard trustGeneration == generation, serverKey == pinnedKey else { throw CancellationError() }
                connected = true
            }
            return (result, signed.body.serverKey)
        } catch is CancellationError { throw CancellationError() }
        catch let error as BridgeFailure {
            if paired, trustGeneration == generation {
                if case .remote = error { connected = true }
                else { connected = false }
            }
            throw error
        }
        catch {
            if paired, trustGeneration == generation { connected = false }
            throw BridgeFailure.ambiguous
        }
    }
    public func workspaceID(for root: URL) -> String {
        BridgeWire.digest(Data(root.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
    }
    public func workspace(root: URL) async throws -> (id: String, path: String) {
        let id = workspaceID(for: root)
        let result = try await call("workspace", ["workspaceID": .string(id)])
        let path = try BridgeResponseValidation.workspaceRoot(result)
        return (id, path)
    }
    public func files(workspaceID: String) async throws -> [[String: BridgeValue]] {
        try await fileListing(workspaceID: workspaceID, cancellation: nil).rows
    }
    private func fileListing(workspaceID: String, cancellation: CancellationToken?, sessionCancellation: CancellationToken? = nil,
                             generation: UUID? = nil) async throws
        -> (rows: [[String: BridgeValue]], pinned: Bool, singlePage: Bool) {
        var result: [[String: BridgeValue]] = []; var offset: Int64 = 0
        var seenPaths = Set<String>()
        let listingID = UUID().uuidString
        let owner = generation ?? trustGeneration
        var pinned: Bool?
        repeat {
            try Self.checkCancellation(cancellation, sessionCancellation)
            let response = try await call("file.list", ["workspaceID": .string(workspaceID), "offset": .integer(offset), "listingID": .string(listingID)], owner: owner)
            let supportsListing = response["listingID"] != nil
            guard (!supportsListing || response["listingID"] == .string(listingID)),
                  pinned == nil || pinned == supportsListing else { throw BridgeFailure.invalidResponse }
            pinned = supportsListing
            let page = try BridgeResponseValidation.fileListPage(response, offset: offset, seenPaths: seenPaths)
            result += page.files
            seenPaths.formUnion(page.files.compactMap { $0["path"]?.string })
            guard let next = page.next else { break }
            offset = next
        } while true
        let rows = result.filter { row in
            guard let path = row["path"]?.string else { return false }
            return !BridgeWorkspaceTransferPolicy.excludes(path)
        }
        return (rows, pinned == true, offset == 0)
    }
    /// Additive capability of the paired companion. An old companion simply
    /// lacks the name; callers surface an explicit update message. Caching is
    /// tied to the trust generation so re-pairing or revocation cannot reuse
    /// a capability from a different trust epoch.
    public func supportsAbsoluteFileRead() async throws -> Bool {
        try requireSupportedPlatform()
        guard serverKey != nil else { throw BridgeFailure.disconnected }
        let generation = trustGeneration
        if let negotiatedCapabilities, negotiatedCapabilities.generation == generation {
            return negotiatedCapabilities.names.contains(BridgeAbsoluteFileRead.capability)
        }
        let response = try await call("ping")
        let names = Set(response["capabilities"]?.array?.compactMap(\.string) ?? [])
        if trustGeneration == generation {
            negotiatedCapabilities = (generation, names)
        }
        return names.contains(BridgeAbsoluteFileRead.capability)
    }
    public struct AbsoluteFileChunk: Sendable {
        public let data: Data
        public let offset: Int64
        public let totalBytes: Int64
        public let identity: String
        public let sha256: String?

        public init(data: Data, offset: Int64, totalBytes: Int64,
                    identity: String, sha256: String? = nil) {
            self.data = data
            self.offset = offset
            self.totalBytes = totalBytes
            self.identity = identity
            self.sha256 = sha256
        }
    }
    public struct AbsoluteFileData: Sendable {
        public let data: Data
        public let sha256: String

        public init(data: Data, sha256: String) {
            self.data = data
            self.sha256 = sha256
        }
    }
    /// One bounded authenticated chunk of an absolute Mac path. The path is
    /// transported as data only; it is never interpolated into a command.
    public func readAbsoluteFileChunk(
        path: String,
        offset: Int,
        limit: Int,
        expectedIdentity: String? = nil,
        verifySHA256: Bool = false,
        cancellation: CancellationToken? = nil
    ) async throws -> AbsoluteFileChunk {
        guard BridgeAbsoluteFileRead.validPath(path), offset >= 0,
              (1...BridgeAbsoluteFileRead.maximumChunkBytes).contains(limit) else {
            throw BridgeFailure.unsafePath
        }
        try Task.checkCancellation(); try cancellation?.throwIfCancelled()
        guard try await supportsAbsoluteFileRead() else {
            throw BridgeFailure.unsupportedAbsoluteRead
        }
        var payload: [String: BridgeValue] = [
            "path": .string(path), "offset": .integer(Int64(offset)),
            "limit": .integer(Int64(limit)),
        ]
        if let expectedIdentity { payload["expectedIdentity"] = .string(expectedIdentity) }
        if verifySHA256 { payload["sha256"] = .bool(true) }
        let response = try await call("file.readAbsolute", payload)
        let chunk = try BridgeAbsoluteFileRead.validateChunk(
            response, requestedOffset: Int64(offset), requestedLimit: limit,
            expectedIdentity: expectedIdentity)
        return AbsoluteFileChunk(data: chunk.data, offset: chunk.offset,
            totalBytes: chunk.totalBytes, identity: chunk.identity, sha256: chunk.sha256)
    }
    /// Assemble a bounded whole file, reject replacement between chunks, and
    /// verify the companion's whole-file receipt against the local digest.
    public func readAbsoluteFileWhole(
        path: String,
        maximumBytes: Int,
        cancellation: CancellationToken? = nil
    ) async throws -> AbsoluteFileData {
        guard BridgeAbsoluteFileRead.validPath(path), maximumBytes > 0,
              maximumBytes <= BridgeAbsoluteFileRead.maximumReceiptBytes else {
            throw BridgeFailure.unsafePath
        }
        var assembled = Data()
        var identity: String?
        var total: Int64?
        let limit = BridgeAbsoluteFileRead.maximumChunkBytes
        while true {
            try Task.checkCancellation(); try cancellation?.throwIfCancelled()
            let chunk = try await readAbsoluteFileChunk(
                path: path, offset: assembled.count, limit: limit,
                expectedIdentity: identity, cancellation: cancellation)
            if let total, total != chunk.totalBytes {
                throw BridgeFailure.remote("The Mac file changed during the read. Read it again.")
            }
            if total == nil {
                total = chunk.totalBytes
                guard chunk.totalBytes <= Int64(maximumBytes) else {
                    throw BridgeFailure.remote(
                        "This Mac file is \((chunk.totalBytes)) bytes; the supported limit for one visual read is \(maximumBytes) bytes.")
                }
            }
            identity = chunk.identity
            assembled.append(chunk.data)
            if chunk.offset >= chunk.totalBytes { break }
            guard !chunk.data.isEmpty else { throw BridgeFailure.invalidResponse }
        }
        let receipt = try await readAbsoluteFileChunk(
            path: path, offset: assembled.count, limit: 1,
            expectedIdentity: identity, verifySHA256: true, cancellation: cancellation)
        guard receipt.data.isEmpty, receipt.totalBytes == total,
              receipt.identity == identity, let expected = receipt.sha256 else {
            throw BridgeFailure.remote("The Mac file changed during the read. Read it again.")
        }
        let actual = SHA256.hash(data: assembled).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw BridgeFailure.remote("The Mac file changed during the read. Read it again.")
        }
        return AbsoluteFileData(data: assembled, sha256: actual)
    }
    /// Shell script size is not a transport limit. Larger commands travel in
    /// bounded chunks to private, task-owned storage and never enter argv.
    public func stageCommand(_ command: String, jobID: String, cancellation: CancellationToken? = nil) async throws -> String {
        let owner = trustGeneration
        try Self.checkCancellation(cancellation)
        let bytes = Data(command.utf8)
        let digest = BridgeWire.digest(bytes)
        try Self.checkCancellation(cancellation)
        let transfer = try await call("file.begin", ["purpose": .string("command"), "jobID": .string(jobID)], owner: owner)
        let id = try BridgeResponseValidation.transferID(transfer)
        var committed = false
        defer { if !committed { Task { [self] in _ = try? await call("file.abort", ["transferID": .string(id)], owner: owner) } } }
        let limit = try BridgeResponseValidation.uploadChunkLimit(transfer)
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation(); try cancellation?.throwIfCancelled()
            let end = min(offset + limit, bytes.count)
            _ = try await call("file.chunk", ["transferID": .string(id), "offset": .integer(Int64(offset)),
                "data": .string(bytes[offset..<end].base64EncodedString())], owner: owner)
            offset = end
        }
        try Self.checkCancellation(cancellation)
        _ = try await call("file.commit", ["transferID": .string(id), "sha256": .string(digest)], owner: owner)
        committed = true
        return digest
    }
    public func upload(_ file: URL, path: String, workspaceID: String, expected: String?) async throws {
        try await upload(file, path: path, workspaceID: workspaceID, expected: expected, digest: Self.digest(file), cancellation: nil, owner: trustGeneration)
    }
    private func upload(_ file: URL, path: String, workspaceID: String, expected: String?,
                        digest: String, cancellation: CancellationToken?, owner: UUID) async throws {
        try Self.checkCancellation(cancellation)
        let transfer = try await call("file.begin", ["workspaceID": .string(workspaceID), "path": .string(path),
            "expectedSHA256": expected.map(BridgeValue.string) ?? .null], owner: owner)
        let id = try BridgeResponseValidation.transferID(transfer)
        var committed = false
        defer { if !committed { Task { [self] in _ = try? await call("file.abort", ["transferID": .string(id)], owner: owner) } } }
        let limit = try BridgeResponseValidation.uploadChunkLimit(transfer)
        let reader = try FileHandle(forReadingFrom: file); defer { try? reader.close() }
        var offset: Int64 = 0
        while let data = try reader.read(upToCount: limit), !data.isEmpty {
            try Self.checkCancellation(cancellation)
            _ = try await call("file.chunk", ["transferID": .string(id), "offset": .integer(offset), "data": .string(data.base64EncodedString())], owner: owner)
            offset += Int64(data.count)
        }
        try Self.checkCancellation(cancellation)
        _ = try await call("file.commit", ["transferID": .string(id), "sha256": .string(digest)], owner: owner)
        committed = true
    }
    private func enterWorkspace(_ id: String) async {
        guard workspaceWaiters[id] != nil else { workspaceWaiters[id] = []; return }
        await withCheckedContinuation { workspaceWaiters[id, default: []].append($0) }
    }
    private func leaveWorkspace(_ id: String) {
        if workspaceWaiters[id]?.isEmpty == false { workspaceWaiters[id]?.removeFirst().resume() }
        else { workspaceWaiters[id] = nil }
    }
    private func commonKey(for id: String) throws -> String {
        guard let serverKey else { throw BridgeFailure.disconnected }
        return BridgeWire.digest(serverKey) + "/" + id
    }
    public func synchronizeBeforeExecution(root: URL, cancellation: CancellationToken? = nil) async throws -> String {
        try Self.checkCancellation(cancellation)
        let id = workspaceID(for: root)
        let owner = trustGeneration, key = try commonKey(for: id)
        await enterWorkspace(id); defer { leaveWorkspace(id) }
        guard owner == trustGeneration else { throw CancellationError() }
        try Self.checkCancellation(cancellation)
        let workspace = try await workspace(root: root)
        let local = try Self.localFiles(root: root) { try Self.checkCancellation(cancellation) }
        let remote = try await fileListing(workspaceID: id, cancellation: cancellation, generation: owner).rows
        let remoteHashes = Dictionary(uniqueKeysWithValues: remote.compactMap { row -> (String, String)? in
            guard let path = row["path"]?.string, let hash = row["sha256"]?.string else { return nil }; return (path, hash)
        })
        var confirmed = baseline[key] ?? [:]
        var previous = baseline[key] ?? legacyBaseline[id] ?? [:]
        for (path, hash) in local where remoteHashes[path] != hash {
            try Self.checkCancellation(cancellation)
            if let remoteHash = remoteHashes[path], previous[path] != remoteHash {
                // A remote-only change is downloaded; two simultaneous edits
                // require review rather than overwriting either copy.
                if previous[path] == hash { continue }
                throw BridgeFailure.remote("A workspace file changed on both devices: \(path). Review both copies before running.")
            }
            if remoteHashes[path] == nil, let shared = confirmed[path] {
                guard shared == hash else { throw BridgeFailure.remote("A file removed on the Mac was also edited locally: \(path). Both states were retained.") }
                continue
            }
            _ = try Self.safe(path, root: root)
            try await upload(root.appendingPathComponent(path), path: path, workspaceID: id,
                             expected: remoteHashes[path], digest: hash, cancellation: cancellation, owner: owner)
            confirmed[path] = hash; previous[path] = hash
        }
        // Files created/edited on Mac are reconciled before a new command as
        // well as after completion, so app tools see real current artifacts.
        for (path, hash) in local where hash == remoteHashes[path] {
            confirmed[path] = hash; previous[path] = hash
        }
        try await reconcile(root: root, id: id, key: key, owner: owner, previous: previous, confirmed: confirmed, cancellation: cancellation)
        return workspace.id
    }
    public func synchronizeAfterExecution(root: URL, cancellation: CancellationToken? = nil, sessionCancellation: CancellationToken? = nil) async throws {
        try Self.checkCancellation(cancellation, sessionCancellation)
        let id = workspaceID(for: root)
        let owner = trustGeneration, key = try commonKey(for: id)
        await enterWorkspace(id); defer { leaveWorkspace(id) }
        try await reconcile(root: root, id: id, key: key, owner: owner, previous: baseline[key] ?? legacyBaseline[id] ?? [:],
                            confirmed: baseline[key] ?? [:], cancellation: cancellation, sessionCancellation: sessionCancellation)
    }
    private func reconcile(root: URL, id: String, key: String, owner: UUID, previous: [String: String], confirmed: [String: String],
                           cancellation: CancellationToken?, sessionCancellation: CancellationToken? = nil) async throws {
        let check: @Sendable () throws -> Void = { try Self.checkCancellation(cancellation, sessionCancellation) }
        let trustedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let listing = try await fileListing(workspaceID: id, cancellation: cancellation, sessionCancellation: sessionCancellation, generation: owner)
        guard trustGeneration == owner else { throw CancellationError() }
        let remote = listing.rows
        let current = try Self.localFiles(root: root, check: check)
        var common: [String: String] = [:]
        for row in remote {
            try check()
            guard let path = row["path"]?.string, let hash = row["sha256"]?.string, let total = row["size"]?.integer else { throw BridgeFailure.invalidResponse }
            if current[path] == hash || (current[path] != nil && previous[path] == hash) {
                common[path] = hash
                continue
            }
            guard current[path] == previous[path] else { throw BridgeFailure.remote("The local file changed while the Mac was working: \(path). Both copies were retained.") }
            _ = try Self.safe(path, root: root)
            let privateTransfers = try baselineURL().deletingLastPathComponent().appendingPathComponent("Transfers", isDirectory: true)
            try FileManager.default.createDirectory(at: privateTransfers, withIntermediateDirectories: true)
            let stage = privateTransfers.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: stage) }
            guard FileManager.default.createFile(atPath: stage.path, contents: nil) else { throw BridgeFailure.unsafePath }
            let writer = try FileHandle(forWritingTo: stage)
            var offset: Int64 = 0
            do {
                while offset < total {
                    try check()
                    let limit = Int(min(Int64(BridgeWire.maximumFileChunkBytes), total - offset))
                    let page = try await call("file.read", ["workspaceID": .string(id), "path": .string(path), "offset": .integer(offset), "limit": .integer(Int64(limit))], owner: owner)
                    let data = try BridgeResponseValidation.fileChunk(page, offset: offset, totalBytes: total, limit: limit)
                    try writer.write(contentsOf: data); offset += Int64(data.count)
                }
                try writer.close()
            } catch { try? writer.close(); throw error }
            guard try Self.digest(stage, check: check) == hash else { throw BridgeFailure.remote("The Mac file changed during transfer. The original was kept.") }
            guard trustGeneration == owner else { throw CancellationError() }
            try check()
            try BridgeSafeFileSystem.commit(staged: stage, relativePath: path,
                under: trustedRoot, expectedSHA256: current[path], checkCancellation: check)
            common[path] = hash
        }
        let remotePaths = Set(remote.compactMap { $0["path"]?.string })
        let absent = confirmed.keys.filter { !remotePaths.contains($0) && current[$0] != nil }.sorted()
        var missing = Set<String>()
        if listing.pinned {
            for start in stride(from: 0, to: absent.count, by: 100) {
                try check()
                let candidates = Array(absent[start..<min(start + 100, absent.count)])
                let reply = try await call("file.confirmMissing", ["workspaceID": .string(id), "paths": .array(candidates.map(BridgeValue.string))], owner: owner)
                guard let values = reply["missing"]?.array else { throw BridgeFailure.invalidResponse }
                let verified = Set(values.compactMap(\.string))
                guard verified.count == values.count, verified.isSubset(of: candidates) else { throw BridgeFailure.invalidResponse }
                missing.formUnion(verified)
            }
        } else if listing.singlePage {
            missing = Set(absent)
        }
        for path in absent {
            guard trustGeneration == owner else { throw CancellationError() }
            guard let oldHash = confirmed[path] else { continue }
            // An old companion's multipage response can drift, or a path can
            // reappear after a snapshot. Retain the last common version.
            guard missing.contains(path) else { common[path] = oldHash; continue }
            try check()
            guard current[path] == oldHash else {
                throw BridgeFailure.remote("A file removed on the Mac was also edited locally: \(path). Both states were retained.")
            }
            let recovery = try baselineURL().deletingLastPathComponent()
                .appendingPathComponent("Recovered Files/" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
            try BridgeSafeFileSystem.moveToRecovery(relativePath: path, under: trustedRoot,
                expectedSHA256: oldHash, recoveryRoot: recovery.resolvingSymlinksInPath().standardizedFileURL, checkCancellation: check)
        }
        try check()
        guard trustGeneration == owner else { throw CancellationError() }
        var updated = baseline
        updated[key] = common
        try BridgeWire.encode(updated).write(to: baselineURL(), options: .atomic)
        baseline = updated
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
        guard LocalBridgePlatform.current.supportsMacBridge else { return [] }
        let url = try baselineURL().deletingLastPathComponent().appendingPathComponent("submitted-jobs.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try BridgeWire.decode([SavedJob].self, from: Data(contentsOf: url))
    }
    /// Retry delivery for the persisted job only. This never submits a command.
    public func synchronizeJobFiles(id: String) async throws {
        guard let job = try savedJobs().first(where: { $0.id == id }),
              FileManager.default.fileExists(atPath: job.rootPath) else { throw BridgeFailure.unsafePath }
        let response = try await call("poll", ["jobID": .string(id), "offset": .integer(0), "limit": .integer(1)])
        let status = try BridgeResponseValidation.poll(response, offset: 0, limit: 1)
        guard !status.alive, !status.outcomeUnknown else {
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
            let status = try BridgeResponseValidation.poll(page, offset: offset)
            let data = status.data, total = status.totalBytes
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
    private func requireSupportedPlatform() throws {
        guard LocalBridgePlatform.current.supportsMacBridge else {
            throw FloeError.invalidConfiguration(String(localized: "execution.location.unavailable_on_device"))
        }
    }
    private func baselineURL() throws -> URL {
        try requireSupportedPlatform()
        let root = storageRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FloeMacBridgeClient")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("workspace-common-v2.json")
    }
    private static func savedHashes(at url: URL) -> [String: [String: String]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? BridgeWire.decode([String: [String: String]].self, from: data)) ?? [:]
    }
    private static func checkCancellation(_ token: CancellationToken?, _ session: CancellationToken? = nil) throws {
        try Task.checkCancellation(); try token?.throwIfCancelled(); try session?.throwIfCancelled()
    }
    public static func digest(_ url: URL) throws -> String {
        try digest(url, check: { try Task.checkCancellation() })
    }
    private static func digest(_ url: URL, check: () throws -> Void) throws -> String {
        let reader = try FileHandle(forReadingFrom: url); defer { try? reader.close() }; var hash = SHA256()
        while let data = try reader.read(upToCount: 256 * 1_024), !data.isEmpty { try check(); hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func localFiles(root: URL, check: () throws -> Void) throws -> [String: String] {
        try check()
        var readError: Error?
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            errorHandler: { _, error in readError = error; return false }) else { throw BridgeFailure.unsafePath }
        var result: [String: String] = [:]
        for case let file as URL in iterator {
            try check()
            guard iterator.level > 0 else { throw BridgeFailure.unsafePath }
            let relative = file.pathComponents.suffix(iterator.level).joined(separator: "/")
            if BridgeWorkspaceTransferPolicy.excludes(relative) { iterator.skipDescendants(); continue }
            let value = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if value.isSymbolicLink == true { iterator.skipDescendants(); continue }
            if file.lastPathComponent.hasPrefix(".bridge-transfer-") { continue }
            if value.isRegularFile == true { result[relative] = try digest(file, check: check) }
        }
        if let readError { throw readError }
        return result
    }
    private static func safe(_ path: String, root: URL) throws -> URL {
        guard !path.hasPrefix("/"), !path.contains("\0"), path.split(separator: "/").allSatisfy({ $0 != ".." && $0 != "." }) else { throw BridgeFailure.unsafePath }
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw BridgeFailure.unsafePath }
        return file
    }
}
