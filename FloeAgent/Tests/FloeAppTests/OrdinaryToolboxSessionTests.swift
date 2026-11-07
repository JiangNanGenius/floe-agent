// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
@preconcurrency import Network
import FloeCore
import FloeModels
import FloeTools
import FloePersistence
import FloeToolboxCore
@testable import FloeAgentRuntime
@testable import FloeApp

/// Actual loopback WebSocket framing and minimal MQTT 3.1.1 broker protocol.
/// No external broker, hardware, host interpreter or fabricated client result.
private nonisolated final class OrdinaryToolboxServer: @unchecked Sendable {
    enum Mode: Sendable, Equatable { case websocket, mqtt, delayedMQTT }
    let mode: Mode
    private let listener: NWListener
    private let queue = DispatchQueue(label: "c52.native.loopback")
    private var connections: [NWConnection] = []
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var pendingConnacks: [NWConnection] = []
    var hasDelayedConnect: Bool { queue.sync { !pendingConnacks.isEmpty } }
    func deliverLateConnack() { queue.sync { for connection in pendingConnacks { connection.send(content: Data([0x20, 2, 0, 0]), completion: .contentProcessed { _ in }) }; pendingConnacks.removeAll() } }
    init(_ mode: Mode) throws {
        self.mode = mode
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .init("127.0.0.1"), port: .any)
        if mode == .websocket {
            let options = NWProtocolWebSocket.Options(.version13); options.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        }
        listener = try NWListener(using: parameters, on: .any)
    }
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection); connection.start(queue: self.queue)
            if self.mode == .websocket { self.websocket(connection) } else { self.mqtt(connection) }
        }
        return try await withCheckedThrowingContinuation { completion in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port?.rawValue { completion.resume(returning: port) }
                    else { completion.resume(throwing: FloeError.validationFailed("Loopback listener has no port")) }
                case .failed(let error): listener.stateUpdateHandler = nil; completion.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    private func websocket(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] bytes, context, _, error in
            guard let self, let bytes, error == nil else { connection.cancel(); return }
            let original = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            let metadata = NWProtocolWebSocket.Metadata(opcode: original?.opcode ?? .binary)
            let context = NWConnection.ContentContext(identifier: UUID().uuidString, metadata: [metadata])
            connection.send(content: bytes, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
            self.websocket(connection)
        }
    }
    private func mqtt(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] bytes, _, complete, error in
            guard let self, error == nil, let bytes, !bytes.isEmpty else { connection.cancel(); return }
            let key = ObjectIdentifier(connection)
            self.buffers[key, default: Data()].append(bytes)
            while let packet = self.packet(&self.buffers[key, default: Data()]) {
                let type = packet.0[0] >> 4, body = packet.1
                let reply: Data?
                switch type {
                case 1:
                    if self.mode == .delayedMQTT { self.pendingConnacks.append(connection); reply = nil }
                    else { reply = Data([0x20, 2, 0, 0]) } // accepted MQTT 3.1.1 CONNACK
                case 8:
                    reply = body.count >= 2 ? Data([0x90, 3, body[0], body[1], 0]) : nil
                case 3: reply = packet.0 // actual broker echo of this QoS0 publish
                case 12: reply = Data([0xD0, 0])
                case 14: connection.cancel(); reply = nil
                default: reply = nil
                }
                if let reply { connection.send(content: reply, completion: .contentProcessed { _ in }) }
            }
            if !complete { self.mqtt(connection) }
        }
    }
    private func packet(_ buffer: inout Data) -> (Data, Data)? {
        let bytes = [UInt8](buffer); guard bytes.count >= 2 else { return nil }
        var index = 1, remaining = 0, multiplier = 1
        for _ in 0..<4 {
            guard index < bytes.count else { return nil }
            let b = Int(bytes[index]); index += 1; remaining += (b & 127) * multiplier
            if b & 128 == 0 {
                guard remaining <= 65_536, bytes.count >= index + remaining else { return nil }
                let packet = Data(bytes[..<(index + remaining)]), body = Data(bytes[index..<(index + remaining)])
                buffer.removeFirst(index + remaining); return (packet, body)
            }
            multiplier *= 128
        }
        return nil
    }
    func stop() { listener.cancel(); queue.sync { for connection in connections { connection.cancel() }; connections.removeAll(); buffers.removeAll() } }
}

@Suite("Ordinary task native toolbox sessions", .serialized)
@MainActor struct OrdinaryToolboxSessionTests {
    private func invoke(_ name: String, _ fields: [String: Any], context base: ToolContext, approved: Bool = false) async throws -> (ToolContext, [String: Any]) {
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: name))
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        var context = base
        if approved {
            let id = UUID().uuidString, grant = UUID()
            var call = try ToolCall(id: id, toolName: name, argumentsJSON: data, scope: base.scope)
            call.idempotencyKey = "fixture-" + id
            context.toolCallID = id; context.toolIdempotencyKey = call.idempotencyKey; context.approvalGrantID = grant
            context.approvalOrigin = .policy("native-contract-fixture")
            context.runtimeAuthority = await RuntimeAuthorityStore.shared.issue(.init(runID: base.runID, taskID: base.conversationID,
                environmentBinding: RuntimeAuthorityDigest.environmentBinding(workspaceRootURL: base.workspaceRootURL, conversationID: base.conversationID),
                canonicalTarget: RuntimeAuthorityDigest.canonicalTarget(for: call, descriptor: runner.descriptor, workspaceRootURL: base.workspaceRootURL),
                toolName: name, operation: "apply", operationID: id, idempotencyKey: call.idempotencyKey,
                baseRevision: nil, payloadDigest: RuntimeAuthorityDigest.payloadDigest(data), approvalGrantID: grant))
        }
        let output = try await runner.execute(argumentsJSON: data, context: context)
        let text = output.capturedOutput ?? output.summary
        #expect(FloeDigest.sha256Hex(Data(text.utf8)) == output.fullOutputSHA256)
        return (context, try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]))
    }
    private func withContext(_ body: @MainActor (ToolContext) async throws -> Void) async throws {
        let environment = FloeAgentApp.liveEnvironment; try await environment.ensureDurableAutomationReady()
        let id = UUID(), runID = UUID(), now = Date()
        try await environment.conversationStore.saveConversation(.init(id: id, title: "C52 native communication", createdAt: now, updatedAt: now))
        try await environment.conversationStore.setArchived(id: id, archived: true)
        try await environment.runStore.saveRun(.init(id: runID, conversationID: id, state: "executing", goal: "Native loopback communication", startedAt: now))
        let names = try await environment.toolboxCenter.freeze(runID: runID, conversationID: id)
        #expect(names == ToolboxTaskSessions.toolNames)
        var context = ToolContext(runID: runID, allowedToolNames: names, cancellation: CancellationToken(), conversationID: id)
        #expect(context.workspaceRootURL == nil && context.environmentID == nil)
        context.frozenEffectiveCatalogNames = names
        do { try await body(context) }
        catch {
            await environment.toolboxCenter.closeOrdinarySessions(conversationIDs: [id]); environment.toolboxCenter.allowOrdinarySessions(conversationIDs: [id])
            try? await environment.conversationStore.deleteConversation(id: id); throw error
        }
        await environment.toolboxCenter.closeOrdinarySessions(conversationIDs: [id]); environment.toolboxCenter.allowOrdinarySessions(conversationIDs: [id])
        try await environment.conversationStore.deleteConversation(id: id)
    }
    @Test(.timeLimit(.minutes(1))) func registeredWebSocketHandshakeSendReceiveCaptureAndExactAuthorityReplay() async throws {
        let server = try OrdinaryToolboxServer(.websocket), port = try await server.start(); defer { server.stop() }
        try await withContext { context in
            let request: [String: Any] = ["action": "open", "protocol": "websocket", "url": "ws://127.0.0.1:\(port)/echo", "timeoutSeconds": 3]
            let (approved, receipt) = try await invoke("toolbox.session", request, context: context, approved: true)
            #expect(receipt["state"] as? String == "connected")
            #expect(receipt["url"] == nil && receipt["host"] == nil)
            let (_, replay) = try await invoke("toolbox.session", request, context: approved)
            #expect(replay["sessionID"] as? String == receipt["sessionID"] as? String)
            var changed = request; changed["url"] = "ws://127.0.0.1:\(port)/different"
            await #expect(throws: (any Error).self) { _ = try await invoke("toolbox.session", changed, context: approved) }
            _ = try await invoke("toolbox.websocket.send", ["data": "c52-actual-websocket"], context: context, approved: true)
            let (_, received) = try await invoke("toolbox.websocket.receive", [:], context: context)
            #expect(received["messageType"] as? String == "text" && received["text"] as? String == "c52-actual-websocket")
            let (_, capture) = try await invoke("toolbox.capture.read", [:], context: context)
            let rows = try #require(capture["records"] as? [[String: Any]])
            #expect(rows.contains { $0["direction"] as? String == "sent" } && rows.contains { $0["direction"] as? String == "received" })
            let boundary = String(repeating: "x", count: 4094) + "token=synthetic-boundary-only"
            _ = try await invoke("toolbox.websocket.send", ["data": boundary], context: context, approved: true)
            let (_, redacted) = try await invoke("toolbox.websocket.receive", [:], context: context)
            #expect(redacted["byteCount"] as? Int == boundary.utf8.count)
            #expect(redacted["redacted"] as? Bool == true && redacted["returnedByteCount"] as? Int == 0)
            #expect(redacted["dataBase64"] as? String == "")
            let (_, closed) = try await invoke("toolbox.session", ["action": "close"], context: context, approved: true)
            #expect(closed["state"] as? String == "closed")
            await #expect(throws: ToolboxError.staleSession) { _ = try await invoke("toolbox.capture.read", [:], context: context) }
        }
    }
    @Test(.timeLimit(.minutes(1))) func registeredAnonymousMQTTConnackSubscribePublishAndRealCapture() async throws {
        let server = try OrdinaryToolboxServer(.mqtt), port = try await server.start(); defer { server.stop() }
        try await withContext { context in
            let (_, opened) = try await invoke("toolbox.session", ["action": "open", "protocol": "mqtt", "host": "127.0.0.1", "port": Int(port), "tls": false, "mqttVersion": "3.1.1", "timeoutSeconds": 3], context: context, approved: true)
            #expect(opened["state"] as? String == "connected")
            let (_, subscribed) = try await invoke("toolbox.mqtt.subscription", ["filter": "qa/c52", "qos": 0], context: context, approved: true)
            #expect(subscribed["grantedQoS"] as? Int == 0)
            let (_, sent) = try await invoke("toolbox.mqtt.publish", ["topic": "qa/c52", "data": "c52-mqtt-payload", "qos": 0], context: context, approved: true)
            #expect(sent["state"] as? String == "sent" && sent["deviceStateConfirmed"] as? Bool == false)
            var observed = false
            for _ in 0..<100 {
                let (_, capture) = try await invoke("toolbox.capture.read", ["maximumRecords": 100], context: context)
                let rows = try #require(capture["records"] as? [[String: Any]])
                observed = rows.contains { row in
                    guard row["direction"] as? String == "received", let encoded = row["bytes"] as? String, let bytes = Data(base64Encoded: encoded) else { return false }
                    return String(decoding: bytes, as: UTF8.self).contains("c52-mqtt-payload")
                }
                if observed { break }; try await Task.sleep(for: .milliseconds(20))
            }
            #expect(observed)
            _ = try await invoke("toolbox.session", ["action": "close"], context: context, approved: true)
        }
    }
    @Test(.timeLimit(.minutes(1))) func temporaryForeignEnvironmentAndRunEndAreFencedAndDescriptorsAreDiscoverable() async throws {
        let server = try OrdinaryToolboxServer(.websocket), port = try await server.start(); defer { server.stop() }
        try await withContext { context in
            let request: [String: Any] = ["action": "open", "protocol": "websocket", "url": "ws://127.0.0.1:\(port)/echo"]
            var temporary = context; temporary.temporaryReadOnly = true
            await #expect(throws: ToolboxError.staleSession) { _ = try await invoke("toolbox.session", request, context: temporary, approved: true) }
            await #expect(throws: ToolboxError.denied) { _ = try await invoke("toolbox.session", request, context: context) }
            _ = try await invoke("toolbox.session", request, context: context, approved: true)
            var foreign = context; foreign.conversationID = UUID()
            await #expect(throws: ToolboxError.staleSession) { _ = try await invoke("toolbox.capture.read", [:], context: foreign) }
            var otherEnvironment = context; otherEnvironment.environmentID = "foreign-environment"
            await #expect(throws: ToolboxError.staleSession) { _ = try await invoke("toolbox.capture.read", [:], context: otherEnvironment) }
            let descriptor = try #require(ToolRunnerRegistry.shared.runner(named: "toolbox.session")).descriptor
            for query in ["websocket", "MQTT", "通信捕获"] { #expect(ToolDiscovery.matches(query: query, descriptors: [descriptor]).map(\.name) == ["toolbox.session"]) }
            var password = request; password["password"] = "synthetic-not-a-credential"
            let runner = try #require(ToolRunnerRegistry.shared.runner(named: "toolbox.session"))
            #expect(throws: (any Error).self) { try runner.validateArguments(JSONSerialization.data(withJSONObject: password)) }
            for url in ["ws://user:synthetic@127.0.0.1:\(port)/echo", "ws://127.0.0.1:\(port)/echo?access_token=synthetic"] {
                var unsafe = request; unsafe["url"] = url
                #expect(throws: (any Error).self) { try runner.validateArguments(JSONSerialization.data(withJSONObject: unsafe)) }
            }
            let environment = FloeAgentApp.liveEnvironment
            try await environment.runStore.updateRunState(id: context.runID, state: "completed", endedAt: Date())
            let until = Date().addingTimeInterval(3)
            while environment.toolboxCenter.taskSessions.activeSessionCount != 0 && Date() < until { try await Task.sleep(for: .milliseconds(20)) }
            #expect(environment.toolboxCenter.taskSessions.activeSessionCount == 0)
        }
    }
    @Test(.timeLimit(.minutes(1))) func cancellationDuringActualMQTTConnectFencesALateConnackAndReleasesTheRun() async throws {
        let server = try OrdinaryToolboxServer(.delayedMQTT), port = try await server.start(); defer { server.stop() }
        try await withContext { context in
            let request: [String: Any] = ["action": "open", "protocol": "mqtt", "host": "127.0.0.1", "port": Int(port), "tls": false, "mqttVersion": "3.1.1", "timeoutSeconds": 3]
            let opening = Task { _ = try await invoke("toolbox.session", request, context: context, approved: true) }
            let until = Date().addingTimeInterval(3)
            while !server.hasDelayedConnect && Date() < until { try await Task.sleep(for: .milliseconds(10)) }
            try #require(server.hasDelayedConnect, "The real broker must receive CONNECT before cancellation")
            context.cancellation.cancel()
            let environment = FloeAgentApp.liveEnvironment
            let firstClose = Task { await environment.toolboxCenter.closeOrdinarySessions(conversationIDs: [context.conversationID!]) }
            let secondClose = Task { await environment.toolboxCenter.closeOrdinarySessions(conversationIDs: [context.conversationID!]) }
            await firstClose.value; await secondClose.value
            do { _ = try await opening.value; Issue.record("A cancelled connection was reported as connected") } catch {}
            #expect(environment.toolboxCenter.taskSessions.activeSessionCount == 0)
            server.deliverLateConnack()
            await Task.yield(); await Task.yield()
            #expect(environment.toolboxCenter.taskSessions.activeSessionCount == 0)
        }
    }
}
#endif
