import Foundation
import Testing
@testable import FloeExecution
#if os(macOS)
import FloeCore
import FloeMacBridgeProtocol
import FloeTools
#endif

@Suite("Mac bridge unbounded command transport")
struct MacBridgeCommandTransferTests {
    @Test("Commands larger than an RPC frame select private chunked scripts")
    func multiMegabyteCommand() {
        let command = String(repeating: "printf '完整一句话\\n'\n", count: 350_000)
        #expect(command.utf8.count > 4 * 1_024 * 1_024)
        #expect(MacBridgeCommandTransfer.requiresStaging(utf8Bytes: command.utf8.count))
        #expect(!MacBridgeCommandTransfer.requiresStaging(utf8Bytes: 0))
    }
}

#if os(macOS)
@Suite("Mac shell file transfer cancellation")
struct MacBridgeShellCancellationTests {
    @Test(arguments: [false, true])
    func preparationStopsAfterFirstUploadChunk(interactive: Bool) async throws {
        let token = CancellationToken()
        let peer = ShellTransferPeer(cancel: token, on: "file.chunk")
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let input = workspace.appendingPathComponent("input.bin")
        try peer.bytes.write(to: input)
        let fixture = try MacBridgeSyncFixture(storage: root.appendingPathComponent("bridge"), responder: peer.reply)
        defer { withExtendedLifetime(fixture) {} }
        let backend = MacBridgeShellBackend(client: fixture.client)

        if interactive {
            do {
                _ = try await backend.openSession(.init(rootURL: workspace, sessionID: "shell"), cancellation: token)
                Issue.record("A cancelled preparation opened an interactive shell")
            } catch {
                #expect((error as? FloeError) == .cancelled || error is CancellationError)
            }
        } else {
            let request = ShellRunRequest(command: "pwd", cwd: ".", rootURL: workspace, sessionID: "shell")
            #expect(await backend.run(request, cancellation: token) == .cancelled)
        }
        #expect(peer.count("file.chunk") == 1)
        #expect(peer.count("file.commit") == 0)
        #expect(peer.count("start") == 0)
        #expect(try Data(contentsOf: input) == peer.bytes)
    }

    @Test func cancelledDownloadCanBeRetriedFromTheSameFinishedJob() async throws {
        let token = CancellationToken()
        let peer = ShellTransferPeer(cancel: token, on: "file.read")
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let output = workspace.appendingPathComponent("output.bin")
        let fixture = try MacBridgeSyncFixture(storage: root.appendingPathComponent("bridge"), responder: peer.reply)
        defer { withExtendedLifetime(fixture) {} }
        let backend = MacBridgeShellBackend(client: fixture.client)
        let request = ShellRunRequest(command: "pwd", cwd: ".", rootURL: workspace, sessionID: "shell")

        #expect(await backend.run(request, cancellation: token) == .cancelled)
        #expect(peer.count("file.read") == 1)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let jobs = try await fixture.client.savedJobs()
        let job = try #require(jobs.first)
        #expect(jobs.count == 1)
        try await fixture.client.synchronizeJobFiles(id: job.id)
        #expect(try Data(contentsOf: output) == peer.bytes)
        #expect(peer.count("start") == 1)
    }

    @Test(arguments: [false, true])
    func terminalExitUsesBothTokensAndTeardownDoesNotRestartDelivery(cancelOwner: Bool) async throws {
        let owner = CancellationToken()
        let poll = CancellationToken()
        let peer = ShellTransferPeer(cancel: cancelOwner ? owner : poll, on: "file.read")
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let fixture = try MacBridgeSyncFixture(storage: root.appendingPathComponent("bridge"), responder: peer.reply)
        defer { withExtendedLifetime(fixture) {} }
        let backend = MacBridgeShellBackend(client: fixture.client)
        let session = try await backend.openSession(.init(rootURL: workspace, sessionID: "shell"), cancellation: owner)

        let reply = try await backend.exchangeSession(.init(sessionID: session.sessionID, input: nil, waitMs: 50, maxBytes: 2), cancellation: poll)
        #expect(!reply.alive && reply.exitCode == 0)
        #expect(reply.output == "do" && reply.failure != nil)
        let tail = try await backend.exchangeSession(.init(sessionID: session.sessionID, input: nil, waitMs: 50, maxBytes: 2), cancellation: nil)
        #expect(tail.output == "ne" && tail.exitCode == 0)
        await backend.closeSession(sessionID: session.sessionID)
        #expect(peer.count("file.read") == 1)
        #expect(peer.count("signal") == 0)
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent("output.bin").path))
    }

    @Test func explicitCloseDrainsTheJobAndHonorsTheOwnerDuringDownload() async throws {
        let owner = CancellationToken()
        let peer = ShellTransferPeer(cancel: owner, on: "file.read")
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let fixture = try MacBridgeSyncFixture(storage: root.appendingPathComponent("bridge"), responder: peer.reply)
        defer { withExtendedLifetime(fixture) {} }
        let backend = MacBridgeShellBackend(client: fixture.client)
        let session = try await backend.openSession(.init(rootURL: workspace, sessionID: "shell"), cancellation: owner)

        await backend.closeSession(sessionID: session.sessionID)
        await backend.closeSession(sessionID: session.sessionID)
        #expect(owner.isCancelled)
        #expect(peer.count("signal") == 1 && peer.count("poll") == 1)
        #expect(peer.count("file.read") == 1)
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent("output.bin").path))
    }

    @Test func overlappingExitPollsDeliverOutputAndClaimTheTransferOnce() async throws {
        let token = CancellationToken()
        let peer = ShellTransferPeer(cancel: token, on: "file.read")
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let fixture = try MacBridgeSyncFixture(storage: root.appendingPathComponent("bridge"), responder: peer.reply)
        defer { withExtendedLifetime(fixture) {} }
        let backend = MacBridgeShellBackend(client: fixture.client)
        let session = try await backend.openSession(.init(rootURL: workspace, sessionID: "shell"), cancellation: token)
        let request = ShellExchangeRequest(sessionID: session.sessionID, input: nil, waitMs: 50, maxBytes: 64)
        let results = try await withThrowingTaskGroup(of: ShellExchangeResult.self) { group in
            for _ in 0..<4 {
                group.addTask { try await backend.exchangeSession(request, cancellation: nil) }
            }
            var results: [ShellExchangeResult] = []
            for try await result in group { results.append(result) }
            return results
        }
        #expect(results.allSatisfy { !$0.alive && $0.exitCode == 0 })
        #expect(results.filter { $0.failure != nil }.count == 1)
        #expect(results.map(\.output).filter { !$0.isEmpty } == ["done"])
        await backend.closeSession(sessionID: session.sessionID)
        #expect(peer.count("file.read") == 1 && peer.count("signal") == 0)
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("workspace"), withIntermediateDirectories: true)
        return root
    }
}

/// Cancels only the business token inside an authenticated chunk response.
/// The calling Swift task and the connection stay live throughout each test.
private final class ShellTransferPeer: @unchecked Sendable {
    let bytes = Data(repeating: 0x61, count: BridgeWire.pageBytes * 2 + 1)
    private let token: CancellationToken
    private let cancelMethod: String
    private let lock = NSLock()
    private var calls: [String: Int] = [:]

    init(cancel token: CancellationToken, on method: String) {
        self.token = token
        self.cancelMethod = method
    }
    func count(_ method: String) -> Int { lock.withLock { calls[method, default: 0] } }
    func reply(_ method: String, _ payload: [String: BridgeValue]) throws -> [String: BridgeValue] {
        try lock.withLock {
            calls[method, default: 0] += 1
            if method == cancelMethod, calls[method] == 1 { token.cancel() }
            switch method {
            case "workspace":
                return ["root": .string("/test-workspace")]
            case "file.list":
                let files: [BridgeValue] = calls["start"] == nil ? [] : [
                    .object(["path": .string("output.bin"), "size": .integer(Int64(bytes.count)),
                             "sha256": .string(BridgeWire.digest(bytes))])
                ]
                var result: [String: BridgeValue] = ["files": .array(files), "next": .null]
                result["listingID"] = payload["listingID"]
                return result
            case "file.begin":
                return ["transferID": .string(UUID().uuidString)]
            case "file.read":
                let offset = Int(payload["offset"]?.integer ?? 0)
                let end = min(bytes.count, offset + BridgeWire.pageBytes)
                return ["data": .string(bytes[offset..<end].base64EncodedString()), "offset": .integer(Int64(end))]
            case "poll":
                let bytes = Data("done".utf8)
                let offset = Int(payload["offset"]?.integer ?? 0)
                let end = min(bytes.count, offset + Int(payload["limit"]?.integer ?? 1))
                return ["alive": .bool(false), "exitCode": .integer(0), "offset": .integer(Int64(end)),
                        "totalBytes": .integer(Int64(bytes.count)), "data": .string(bytes[offset..<end].base64EncodedString())]
            case "file.chunk", "file.abort", "file.commit", "command.discard", "start", "signal":
                return [:]
            default:
                throw BridgeFailure.invalidResponse
            }
        }
    }
}
#endif
