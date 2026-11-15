import Foundation
import CryptoKit
import Testing
import FloeMacBridgeProtocol
@testable import FloeExecution

final class MacBridgeSyncFixture: Sendable {
    typealias Responder = @Sendable (String, [String: BridgeValue]) throws -> [String: BridgeValue]
    private let identity: Data
    let client: MacBridgeClient

    init(storage: URL, responder: @escaping Responder) throws {
        let key = Curve25519.Signing.PrivateKey()
        let server = Curve25519.Signing.PrivateKey()
        identity = key.publicKey.rawRepresentation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MacBridgeFixtureProtocol.self]
        client = MacBridgeClient(session: URLSession(configuration: configuration), clientKey: key,
                                 serverKey: server.publicKey.rawRepresentation, storageRoot: storage)
        MacBridgeFixtureProtocol.peers.set(identity) { request in
            var body = BridgeResponseBody(id: request.body.id, serverKey: server.publicKey.rawRepresentation)
            do { body.result = try responder(request.body.method, request.body.payload) }
            catch { body.error = error.localizedDescription }
            return try BridgeWire.encode(BridgeResponse(body: body, key: server))
        }
    }
    deinit { MacBridgeFixtureProtocol.peers.set(identity, nil) }
}

private final class MacBridgeFixtureProtocol: URLProtocol, @unchecked Sendable {
    final class Peers: @unchecked Sendable {
        typealias Handler = @Sendable (BridgeRequest) throws -> Data
        private let lock = NSLock()
        private var byKey: [Data: Handler] = [:]
        func set(_ key: Data, _ value: Handler?) { lock.withLock { byKey[key] = value } }
        func handler(_ key: Data) -> Handler? { lock.withLock { byKey[key] } }
    }
    static let peers = Peers()
    override class func canInit(with request: URLRequest) -> Bool { request.url == BridgeWire.endpoint }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty, let input = request.httpBodyStream {
                input.open(); defer { input.close() }
                var buffer = [UInt8](repeating: 0, count: 32 * 1_024)
                while true {
                    let n = input.read(&buffer, maxLength: buffer.count)
                    guard n >= 0 else { throw BridgeFailure.invalidResponse }
                    if n == 0 { break }
                    bytes.append(contentsOf: buffer.prefix(n))
                }
            }
            let packet = try BridgeWire.decode(BridgeRequest.self, from: bytes)
            try packet.verify()
            guard let handler = Self.peers.handler(packet.body.clientKey),
                  let response = HTTPURLResponse(url: BridgeWire.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]) else {
                throw BridgeFailure.authentication
            }
            let reply = try handler(packet)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

#if os(macOS)
@Suite("Paired Mac workspace reconciliation")
struct MacBridgeWorkspaceSyncTests {
    private final class Peer: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [String: Data]
        private var staged = Data()
        private var destination = ""
        let legacy: Bool
        let beforeRead: @Sendable () throws -> Void
        init(files: [String: Data] = [:], legacy: Bool = false, beforeRead: @escaping @Sendable () throws -> Void = {}) {
            self.files = files; self.legacy = legacy; self.beforeRead = beforeRead
        }
        func value(_ path: String) -> Data? { lock.withLock { files[path] } }
        func remove(_ path: String) { lock.withLock { _ = files.removeValue(forKey: path) } }
        func set(_ path: String, _ data: Data) { lock.withLock { files[path] = data } }
        func respond(_ method: String, _ p: [String: BridgeValue]) throws -> [String: BridgeValue] {
            try lock.withLock {
                switch method {
                case "workspace": return ["root": .string("/fixture")]
                case "file.list":
                    let rows = files.keys.sorted().map { path in
                        let data = files[path]!
                        return BridgeValue.object(["path": .string(path), "size": .integer(Int64(data.count)), "sha256": .string(BridgeWire.digest(data))])
                    }
                    let offset = Int(p["offset"]?.integer ?? 0)
                    let end = min(rows.count, offset + 1)
                    var reply: [String: BridgeValue] = ["files": .array(Array(rows[offset..<end])), "next": end < rows.count ? .integer(Int64(end)) : .null]
                    if !legacy { reply["listingID"] = p["listingID"] }
                    return reply
                case "file.confirmMissing":
                    return ["missing": .array((p["paths"]?.array ?? []).filter { files[$0.string ?? ""] == nil })]
                case "file.begin":
                    destination = try #require(p["path"]?.string)
                    staged = Data()
                    if let old = files[destination] { try #require(p["expectedSHA256"] == .string(BridgeWire.digest(old))) }
                    var reply: [String: BridgeValue] = ["transferID": .string("fixture")]
                    if !legacy { reply["maximumChunkBytes"] = .integer(Int64(BridgeWire.maximumFileChunkBytes)) }
                    return reply
                case "file.chunk":
                    let data = try #require(p["data"]?.string.flatMap { Data(base64Encoded: $0) })
                    try #require(data.count <= (legacy ? BridgeWire.pageBytes : BridgeWire.maximumFileChunkBytes))
                    try #require(p["offset"]?.integer == Int64(staged.count))
                    staged.append(data); return [:]
                case "file.commit":
                    try #require(p["sha256"] == .string(BridgeWire.digest(staged)))
                    files[destination] = staged; return [:]
                case "file.abort": return [:]
                case "file.read":
                    try beforeRead()
                    let data = try #require(files[p["path"]?.string ?? ""])
                    let offset = Int(try #require(p["offset"]?.integer))
                    let size = legacy ? BridgeWire.pageBytes : Int(try #require(p["limit"]?.integer))
                    let end = min(data.count, offset + size)
                    return ["data": .string(data[offset..<end].base64EncodedString()), "offset": .integer(Int64(end))]
                default: throw BridgeFailure.invalidResponse
                }
            }
        }
    }
    private func directories() throws -> (base: URL, workspace: URL, storage: URL) {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let workspace = base.appendingPathComponent("workspace"), storage = base.appendingPathComponent("private")
        for url in [workspace, storage] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return (base, workspace, storage)
    }

    @Test("A new local file survives post-sync, uploads on the next command, and an actual remote deletion is recoverable")
    func newlyLocalFile() async throws {
        let (base, root, storage) = try directories(); defer { try? FileManager.default.removeItem(at: base) }
        let peer = Peer(), fixture = try MacBridgeSyncFixture(storage: storage, responder: peer.respond)
        let local = root.appendingPathComponent("new.bin"), data = Data(repeating: 17, count: 130_000)
        try data.write(to: local)
        try await fixture.client.synchronizeAfterExecution(root: root)
        #expect(try Data(contentsOf: local) == data)
        _ = try await fixture.client.synchronizeBeforeExecution(root: root)
        #expect(peer.value("new.bin") == data)
        peer.remove("new.bin")
        try await fixture.client.synchronizeAfterExecution(root: root)
        #expect(!FileManager.default.fileExists(atPath: local.path))
        let recovered = try #require(FileManager.default.enumerator(at: storage.appendingPathComponent("Recovered Files"), includingPropertiesForKeys: nil))
        let copy = try #require(recovered.allObjects.compactMap { $0 as? URL }.first { $0.lastPathComponent == "new.bin" })
        #expect(try Data(contentsOf: copy) == data)
    }

    @Test("An old unverified baseline and an old companion's moving page cannot move a local file")
    func historicalAndLegacyLists() async throws {
        let (base, root, storage) = try directories(); defer { try? FileManager.default.removeItem(at: base) }
        let data = Data(repeating: 39, count: 133_333), old = root.appendingPathComponent("orphan")
        try data.write(to: old)
        let id = BridgeWire.digest(Data(root.standardizedFileURL.path.utf8))
        let hashes = [id: ["orphan": BridgeWire.digest(data)]]
        try BridgeWire.encode(hashes).write(to: storage.appendingPathComponent("workspace-baselines.json"))
        let peer = Peer(files: ["a": Data(), "z": Data()], legacy: true)
        let fixture = try MacBridgeSyncFixture(storage: storage, responder: peer.respond)
        try await fixture.client.synchronizeAfterExecution(root: root)
        #expect(try Data(contentsOf: old) == data)
        _ = try await fixture.client.synchronizeBeforeExecution(root: root)
        #expect(peer.value("orphan") == data)
        peer.remove("orphan")
        try await fixture.client.synchronizeAfterExecution(root: root)
        #expect(try Data(contentsOf: old) == data)
    }

    @Test("A simultaneous local edit wins over a downloaded snapshot at commit")
    func changedDestinationIsPreserved() async throws {
        let (base, root, storage) = try directories(); defer { try? FileManager.default.removeItem(at: base) }
        let file = root.appendingPathComponent("document")
        let original = Data("before".utf8), edit = Data("edited during transfer".utf8)
        try original.write(to: file)
        let peer = Peer(files: ["document": original], beforeRead: { try edit.write(to: file) })
        let fixture = try MacBridgeSyncFixture(storage: storage, responder: peer.respond)
        try await fixture.client.synchronizeAfterExecution(root: root)
        peer.set("document", Data("Mac edit".utf8))
        await #expect(throws: (any Error).self) { try await fixture.client.synchronizeAfterExecution(root: root) }
        #expect(try Data(contentsOf: file) == edit)
    }

    @Test("A different paired Mac cannot use the previous peer's baseline to remove a local file")
    func rePairingKeepsOtherPeersFiles() async throws {
        let (base, root, storage) = try directories(); defer { try? FileManager.default.removeItem(at: base) }
        let data = Data("shared only with the first peer".utf8), file = root.appendingPathComponent("document")
        try data.write(to: file)
        let first = try MacBridgeSyncFixture(storage: storage, responder: Peer(files: ["document": data]).respond)
        try await first.client.synchronizeAfterExecution(root: root)
        let second = try MacBridgeSyncFixture(storage: storage, responder: Peer().respond)
        try await second.client.synchronizeAfterExecution(root: root)
        #expect(try Data(contentsOf: file) == data)
    }
}
#endif
