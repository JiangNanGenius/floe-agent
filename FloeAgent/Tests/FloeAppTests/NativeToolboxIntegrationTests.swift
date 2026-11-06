// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
@preconcurrency import Network
import FloePersistence
import FloeTools
import FloeToolboxCore
import FloeToolboxClients
@testable import FloeApp

private nonisolated final class NativeToolboxHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "floe.qualification.toolbox.http")
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        listener = try NWListener(using: parameters, on: .any)
    }
    func start() async throws -> URL {
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { bytes, _, _, _ in
                let method = String(decoding: bytes ?? Data(), as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
                let body = Data(("native-toolbox-" + method).utf8)
                var reply = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                reply.append(body)
                connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port?.rawValue { continuation.resume(returning: port) }
                    else { continuation.resume(throwing: ClientError.networkFailure) }
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return try #require(URL(string: "http://127.0.0.1:\(port)/capture"))
    }
    func stop() { listener.cancel() }
}

@Suite("Native toolbox App integration", .serialized)
@MainActor struct NativeToolboxIntegrationTests {
    @Test func sqliteCapturePreservesConcurrentEventsAndRejectsStaleOrForeignWrites() async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ToolboxQualification-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ToolboxCaptureStore(database: environment.database, exportRoot: root)
        let ownerID = UUID(), captureID = UUID()
        let journal = try await CaptureJournal(ownerID: ownerID, captureID: captureID, repository: repository, limits: CaptureLimits())
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<4 { group.addTask { try await journal.append([CaptureEvent(bytes: Data("event-\(index)".utf8), direction: .received)]) } }
            try await group.waitForAll()
        }
        let snapshot = await journal.snapshot()
        #expect(snapshot.revision == 4); #expect(snapshot.records.map(\.sequence) == [1, 2, 3, 4])
        let reopened = try await CaptureJournal(ownerID: ownerID, captureID: captureID, repository: repository, limits: CaptureLimits())
        #expect(await reopened.snapshot() == snapshot)
        await #expect(throws: ToolboxError.revisionConflict) { try await repository.commit(snapshot, expectedRevision: snapshot.revision - 1) }
        await #expect(throws: ToolboxError.denied) { _ = try await repository.load(captureID: captureID, ownerID: UUID()) }
    }
    @Test func registeredNativeHTTPUsesExactTaskAndConnectionGeneration() async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let server = try NativeToolboxHTTPFixture(), url = try await server.start()
        defer { server.stop() }
        let center = environment.toolboxCenter
        center.connect(.http, setup: .init(address: url.absoluteString))
        let deadline = Date().addingTimeInterval(10)
        while center.connecting.contains(.http), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let connection = try #require(center.connections[.http])
        let conversationID = try await center.assistant(for: connection), runID = UUID()
        try await environment.runStore.saveRun(.init(id: runID, conversationID: conversationID, state: "executing", goal: "Native HTTP qualification", startedAt: Date()))
        let names = try await center.freeze(runID: runID, conversationID: conversationID)
        #expect(names == ["toolbox.capture.read", "toolbox.http.read", "toolbox.http.write"])
        var context = ToolContext(runID: runID, allowedToolNames: names, cancellation: CancellationToken(), conversationID: conversationID)
        context.frozenEffectiveCatalogNames = names
        do {
            let runner = try #require(ToolRunnerRegistry.shared.runner(named: "toolbox.http.read"))
            let bytes = try JSONSerialization.data(withJSONObject: ["url": url.absoluteString])
            let output = try await runner.execute(argumentsJSON: bytes, context: context)
            let reply = try #require(JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
            #expect(reply["status"] as? Int == 200)
            #expect(reply["bytes"] as? String == Data("native-toolbox-GET".utf8).base64EncodedString())
            var foreign = context; foreign.conversationID = UUID()
            await #expect(throws: ToolboxError.staleSession) { _ = try await runner.execute(argumentsJSON: bytes, context: foreign) }
            let writer = try #require(ToolRunnerRegistry.shared.runner(named: "toolbox.http.write"))
            await #expect(throws: ToolboxError.denied) { _ = try await writer.execute(argumentsJSON: bytes, context: context) }
            let capture = await connection.journal.snapshot()
            #expect(!capture.records.isEmpty)
            await center.disconnect(.http)
            await #expect(throws: ToolboxError.staleSession) { _ = try await runner.execute(argumentsJSON: bytes, context: context) }
        } catch {
            await center.disconnect(.http)
            try? await environment.conversationStore.deleteConversation(id: conversationID)
            throw error
        }
        try await environment.conversationStore.deleteConversation(id: conversationID)
    }
}
#endif
