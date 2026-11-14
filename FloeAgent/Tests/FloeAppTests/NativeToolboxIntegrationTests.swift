// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
@preconcurrency import Network
import FloePersistence
import FloeTools
import FloeToolboxCore
import FloeToolboxClients
import FloeToolboxHost
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

@MainActor private final class InertTerminalFixture {
    private(set) var bytes = Data("fixture-ready\n".utf8)
    private let generation = UUID()
    private(set) var inputs: [Data] = []
    func snapshot() -> ToolboxTerminalOutput { .init(bytes: bytes, byteEnd: bytes.count, generation: generation) }
    func receive(_ data: Data) {
        inputs.append(data)
        bytes.append(Data(("ran:" + String(decoding: data, as: UTF8.self)).utf8))
    }
}

@Suite("Native toolbox App integration", .serialized)
@MainActor struct NativeToolboxIntegrationTests {
    private func makeTerminalSession(_ environment: AppEnvironment, title: String) async throws
        -> (ToolboxTerminalSession, InertTerminalFixture) {
        let fixture = InertTerminalFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ToolboxTerminal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = try await ToolboxTerminalSession.open(environment: environment,
            machine: .temporary(connectionID: UUID()), title: title, workingRoot: root,
            output: { fixture.snapshot() }, input: { data in fixture.receive(data) })
        return (session, fixture)
    }
    private func terminalRun(_ command: String, context: ToolContext, approved: Bool = false) async throws -> String {
        var context = context
        context.executionToolName = ToolboxTerminalRunAction.name
        context.toolCallID = UUID().uuidString
        if approved { context.approvalGrantID = UUID() }
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: ToolboxTerminalRunAction.name))
        let data = try JSONSerialization.data(withJSONObject: ["command": command], options: [.sortedKeys])
        return try await runner.execute(argumentsJSON: data, context: context).summary
    }
    private func captureRead(context: ToolContext) async throws -> String {
        var context = context
        context.executionToolName = ToolboxCaptureAction.name
        context.toolCallID = UUID().uuidString
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: ToolboxCaptureAction.name))
        return try await runner.execute(argumentsJSON: Data("{}".utf8), context: context).summary
    }
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
            #expect(try await environment.conversationStore.conversation(id: conversationID) != nil)
            await center.disposeAssistantsNow(for: .http).value
            #expect(try await environment.conversationStore.conversation(id: conversationID) == nil)
        } catch {
            await center.disconnect(.http)
            await center.disposeAssistantsNow(for: .http).value
            try? await environment.conversationStore.deleteConversation(id: conversationID)
            throw error
        }
    }
    @Test func terminalAssistantWritesOnlyToTheBoundSessionAndPurgesOnLeave() async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let marker = "terminal-fixture-" + UUID().uuidString
        let (session, fixture) = try await makeTerminalSession(environment, title: marker)
        do {
            let conversation = try await environment.toolboxCenter.assistant(for: session)
            #expect(try await environment.toolboxCenter.assistant(for: session) == conversation)
            #expect(session.active)
            let runID = UUID()
            try await environment.runStore.saveRun(.init(id: runID, conversationID: conversation,
                state: "executing", goal: "terminal fixture", startedAt: Date()))
            let names = try await environment.toolboxCenter.freeze(runID: runID, conversationID: conversation)
            #expect(names == Set([ToolboxCaptureAction.name, ToolboxTerminalRunAction.name]))
            var context = ToolContext(runID: runID, allowedToolNames: names,
                cancellation: CancellationToken(), conversationID: conversation)
            context.frozenEffectiveCatalogNames = names
            await #expect(throws: ToolboxError.denied) {
                _ = try await terminalRun("printf denied", context: context)
            }
            #expect(fixture.inputs.isEmpty)
            _ = try await terminalRun("printf accepted", context: context, approved: true)
            #expect(fixture.inputs == [Data("printf accepted\n".utf8)])
            await session.flush()
            let capture = try await captureRead(context: context)
            let captureJSON = try #require(JSONSerialization.jsonObject(with: Data(capture.utf8)) as? [String: Any])
            let rows = try #require(captureJSON["records"] as? [[String: Any]])
            let observed = rows.first { ($0["text"] as? String)?.contains("ran:printf accepted") == true }
            let observedRow = try #require(observed)
            let base64 = try #require(observedRow["bytes"] as? String)
            let decoded = try #require(Data(base64Encoded: base64))
            #expect(String(decoding: decoded, as: UTF8.self).contains("ran:printf accepted"))
            #expect(observedRow["sequence"] as? Int != nil)
            #expect(observedRow["truncated"] as? Bool == false)
            await environment.toolboxCenter.disposeAssistantsNow(for: .terminal).value
            #expect(try await environment.conversationStore.conversation(id: conversation) == nil)
            #expect(try await environment.toolboxCenter.freeze(runID: runID, conversationID: conversation).isEmpty)
            await #expect(throws: (any Error).self) {
                _ = try await terminalRun("printf late", context: context, approved: true)
            }
            #expect(fixture.inputs.count == 1)
        } catch {
            await session.close(); throw error
        }
        await session.close()
    }
    @Test func terminalDisconnectFencesDialogueAndANewSessionGetsANewAssistant() async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let marker = "terminal-disconnect-" + UUID().uuidString
        let (firstSession, firstFixture) = try await makeTerminalSession(environment, title: marker)
        let first = try await environment.toolboxCenter.assistant(for: firstSession)
        let firstRun = UUID()
        try await environment.runStore.saveRun(.init(id: firstRun, conversationID: first,
            state: "executing", goal: "terminal disconnect", startedAt: Date()))
        var context = ToolContext(runID: firstRun,
            allowedToolNames: try await environment.toolboxCenter.freeze(runID: firstRun, conversationID: first),
            cancellation: CancellationToken(), conversationID: first)
        context.frozenEffectiveCatalogNames = context.allowedToolNames
        firstSession.invalidate()
        environment.toolboxCenter.releaseTerminal(firstSession)
        #expect(try await environment.conversationStore.conversation(id: first) != nil)
        #expect(try await environment.toolboxCenter.freeze(runID: firstRun, conversationID: first).isEmpty)
        await #expect(throws: (any Error).self) { _ = try await terminalRun("printf fenced", context: context, approved: true) }
        #expect(firstFixture.inputs.isEmpty)
        let (secondSession, secondFixture) = try await makeTerminalSession(environment, title: marker)
        let second = try await environment.toolboxCenter.assistant(for: secondSession)
        #expect(second != first)
        #expect(try await environment.conversationStore.conversation(id: first) != nil)
        #expect(try await environment.conversationStore.conversation(id: second) != nil)
        await environment.toolboxCenter.disposeAssistantsNow(for: .terminal).value
        #expect(try await environment.conversationStore.conversation(id: first) == nil)
        #expect(try await environment.conversationStore.conversation(id: second) == nil)
        #expect(secondFixture.inputs.isEmpty)
        await firstSession.close(); await secondSession.close()
    }
    @Test func rapidLeaveAndImmediateReopenNeverDeletesTheNewAssistant() async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let marker = "terminal-reopen-" + UUID().uuidString
        let (session, _) = try await makeTerminalSession(environment, title: marker)
        let pending = Task { try await environment.toolboxCenter.assistant(for: session) }
        try await Task.sleep(for: .milliseconds(20))
        let deletion = environment.toolboxCenter.disposeAssistantsNow(for: .terminal)
        let reopened = try await environment.toolboxCenter.assistant(for: session)
        await deletion.value
        let old = try? await pending.value
        if let old, old != reopened {
            #expect(try await environment.conversationStore.conversation(id: old) == nil)
        }
        let rows = try await environment.conversationStore.conversations(includeArchived: true)
            .filter { $0.title.contains(marker) }
        #expect(rows.count == 1)
        #expect(rows.first?.id == reopened)
        await environment.toolboxCenter.disposeAssistantsNow(for: .terminal).value
        await session.close()
    }
    @Test func terminalAndProtocolActionsKeepStandardApprovalAndRiskLabels() {
        #expect(ToolboxNativeTool<ToolboxTerminalRunAction>.riskLabels
            == [.networkAccess, .modifiesRemoteSystem, .executesRemoteCommand])
        #expect(ToolboxNativeTool<ToolboxTerminalRunAction>.isSideEffecting)
        #expect(ToolboxNativeTool<ToolboxTerminalRunAction>.toolEffect == .mutating)
        #expect(ToolboxNativeTool<ToolboxHTTPWriteAction>.riskLabels
            == [.networkAccess, .modifiesRemoteSystem])
        #expect(ToolboxNativeTool<ToolboxHTTPWriteAction>.isSideEffecting)
        #expect(ToolboxNativeTool<ToolboxHTTPReadAction>.toolEffect == .readOnly)
    }
}
#endif
