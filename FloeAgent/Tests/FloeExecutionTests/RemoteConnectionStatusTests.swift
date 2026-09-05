import Foundation
import Network
import Testing
import FloeCore
import FloeTools
import FloePersistence
@testable import FloeExecution

@Suite("Remote connection inventory")
struct RemoteConnectionStatusTests {
    @Test("Status is registered, read only and rejects foreign session IDs")
    func statusContract() async throws {
        let registry = ToolRunnerRegistry()
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        registerExecutionTools(registry: registry, remoteHostStore: RemoteHostStore(database: database))
        let runner = try #require(registry.runner(named: "remote.connection.status"))
        #expect(RemoteConnectionStatusTool.toolEffect == .readOnly)
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        let empty = try await runner.execute(argumentsJSON: Data("{}".utf8), context: context)
        #expect(empty.summary == "[]")
        await #expect(throws: FloeError.self) {
            _ = try await runner.execute(argumentsJSON: Data("{\"sessionID\":\"\(UUID())\"}".utf8), context: context)
        }
    }

    @Test("Inventory preserves unread bytes and isolates real TCP sessions by run")
    func realSessionInventory() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "floe.test.tcp.inventory")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.send(content: Data("hello".utf8), completion: .contentProcessed { _ in
                // Keep the socket alive for the client's independent reads.
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in connection.cancel() }
            })
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        for _ in 0..<100 {
            if let port = listener.port, port.rawValue != 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let port = try #require(listener.port)
        let service = RawRemoteConnectionService()
        let runID = UUID()
        let sessionID = try await service.open(runID: runID, host: "127.0.0.1", port: Int(port.rawValue), kind: .tcp)
        let snapshots = try await service.snapshots(runID: runID)
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.sessionID == sessionID)
        #expect(snapshots.first?.transportState == "connected")
        #expect(try await service.snapshots(runID: UUID()).isEmpty)
        await #expect(throws: FloeError.self) { _ = try await service.snapshots(runID: UUID(), sessionID: sessionID) }
        let data = try await service.exchange(runID: runID, sessionID: sessionID, data: nil, wait: 1, maxBytes: 32)
        #expect(String(decoding: data, as: UTF8.self) == "hello")
        await service.close(runID: runID, sessionID: sessionID)
        #expect(try await service.snapshots(runID: runID).isEmpty)
    }
}
