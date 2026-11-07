// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeToolboxCore
import FloeToolboxClients
import FloeToolboxHost

/// Retains the exact accepted scalar payload, including null/type identity,
/// so the consumer derives the SAME digest as the real runtime issuer.
nonisolated enum ToolboxSessionScalar: Codable, Sendable {
    case text(String), integer(Int), flag(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .flag(value) }
        else if let value = try? c.decode(Int.self) { self = .integer(value) }
        else { self = .text(try c.decode(String.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .text(let v): try c.encode(v); case .integer(let v): try c.encode(v); case .flag(let v): try c.encode(v); case .null: try c.encodeNil() }
    }
}
nonisolated struct ToolboxSessionArguments: Decodable, Sendable {
    let fields: [String: ToolboxSessionScalar]
    init(from decoder: Decoder) throws { fields = try [String: ToolboxSessionScalar](from: decoder) }
    func payload() throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(fields) }
    func text(_ key: String) -> String? { if case .text(let v)? = fields[key] { return v }; return nil }
    func integer(_ key: String) -> Int? { if case .integer(let v)? = fields[key] { return v }; return nil }
    func flag(_ key: String) -> Bool? { if case .flag(let v)? = fields[key] { return v }; return nil }
    var action: String { text("action") ?? "" }
    func validate() throws {
        guard ["open", "status", "close"].contains(action) else { throw FloeError.validationFailed("toolbox.session action must be open, status or close.") }
        if action != "open" {
            guard Set(fields.keys) == ["action"] else { throw FloeError.validationFailed("status/close accept only action; targets belong to open.") }; return
        }
        let timeout = integer("timeoutSeconds") ?? 15
        guard (1...30).contains(timeout), fields["timeoutSeconds"] == nil || integer("timeoutSeconds") != nil else { throw FloeError.validationFailed("timeoutSeconds must be an integer 1...30.") }
        switch text("protocol") {
        case "websocket":
            guard Set(fields.keys).isSubset(of: ["action", "protocol", "url", "timeoutSeconds"]),
                  let raw = text("url"), raw.utf8.count <= 8192, let url = URL(string: raw),
                  ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false,
                  url.user == nil, url.password == nil, url.fragment == nil, url.query == nil else {
                throw FloeError.validationFailed("WebSocket open requires an explicit anonymous ws/wss URL without credentials, query, fragment or extra fields. Auth headers are not supported here; use the native configured connection assistant for authenticated targets.")
            }
        case "mqtt":
            guard Set(fields.keys).isSubset(of: ["action", "protocol", "host", "port", "tls", "mqttVersion", "timeoutSeconds"]),
                  let host = text("host"), !host.isEmpty, host.utf8.count <= 253, !host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" || $0 == "\0" }),
                  let port = integer("port"), (1...65535).contains(port), flag("tls") != nil,
                  ["3.1.1", "5"].contains(text("mqttVersion") ?? "") else {
                throw FloeError.validationFailed("Anonymous MQTT open needs host, port 1...65535, tls:boolean and mqttVersion 3.1.1|5. Credentials and extra fields are not accepted; authenticated brokers use the native configured connection assistant.")
            }
        default: throw FloeError.validationFailed("Only native websocket and anonymous mqtt sessions are available; USB host/serial drivers are not supplied by this tool.")
        }
    }
    func setup() throws -> (ToolboxTool, ToolboxConnectionSetup) {
        try validate()
        guard action == "open" else { throw ToolboxError.invalid("Only open has a target configuration") }
        var value = ToolboxConnectionSetup()
        value.networkTimeoutSeconds = TimeInterval(integer("timeoutSeconds") ?? 15)
        if text("protocol") == "websocket", let url = text("url") { value.address = url; return (.webSocket, value) }
        guard let host = text("host"), let port = integer("port"), let tls = flag("tls") else { throw ToolboxError.invalid("Incomplete MQTT target") }
        value.address = host; value.port = String(port); value.useTLS = tls
        value.mqttVersion = text("mqttVersion") == "5" ? .v5 : .v311
        return (.mqtt, value)
    }
}

struct ToolboxSessionTool: AgentTool {
    typealias Arguments = ToolboxSessionArguments
    static let name = "toolbox.session"
    static let toolDescription = "Open/status/close one real native WebSocket ws/wss or anonymous MQTT connection for THIS ordinary task/run. Native handshake/CONNACK must succeed; connection success proves no device action. First open {action:open,protocol:websocket,url:ws://host:port/path} or {action:open,protocol:mqtt,host,port,tls:boolean,mqttVersion:3.1.1|5}; optional timeoutSeconds integer 1...30. No credentials/headers/query or USB/PCAP support. Then use toolbox.websocket.send/receive, toolbox.mqtt.subscription/publish, and toolbox.capture.read to inspect actual redacted communication and analyze it yourself; capture is session traffic, not system packet capture. One immutable target per run, close before changing targets, at most eight active/pending runs. Existing runtime-approved call authority is required for open/close; temporary chat/children are refused. Sessions are released on cancellation/run end/task deletion; they do not persist into another run. Never guess a successful connection or replay an unconfirmed send."
    static let parametersJSON = #"{"type":"object","additionalProperties":false,"required":["action"],"properties":{"action":{"type":"string","enum":["open","status","close"]},"protocol":{"type":"string","enum":["websocket","mqtt"]},"url":{"type":"string","maxLength":8192},"host":{"type":"string","maxLength":253},"port":{"type":"integer","minimum":1,"maximum":65535},"tls":{"type":"boolean"},"mqttVersion":{"type":"string","enum":["3.1.1","5"]},"timeoutSeconds":{"type":"integer","minimum":1,"maximum":30}}}"#
    static let riskLabels: Set<RiskLabel> = [.networkAccess]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    static let requiresHostScope = false
    static let executionBoundary: ToolExecutionBoundary = .mainRunOnly
    let service: ToolboxTaskSessions
    func validate(_ args: Arguments) throws { try args.validate() }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try args.validate()
        guard context.executionToolName == Self.name, context.allowedToolNames?.contains(Self.name) == true,
              context.frozenEffectiveCatalogNames?.contains(Self.name) == true else { throw ToolboxError.denied }
        let result = try await service.perform(args, context: context)
        return ToolExecutionOutput(digesting: result, maximumSummaryCharacters: 4096, capturedOutput: result)
    }
}

/// Bounded run ownership over the existing ToolboxConnection; this registry
/// creates no transport, credential store, permission decision or UI session.
@MainActor final class ToolboxTaskSessions {
    static let toolNames: Set<String> = [ToolboxSessionTool.name, ToolboxWebSocketSendAction.name,
        ToolboxWebSocketReceiveAction.name, ToolboxMQTTPublishAction.name, ToolboxMQTTSubscriptionAction.name, ToolboxCaptureAction.name]
    @MainActor private final class Entry {
        let id = UUID()
        let context: ToolContext
        let authority: RuntimeTaskAuthority
        let binding: RuntimeAuthorityBinding
        let payload: Data
        let operation: Task<ToolboxConnection, Error>
        var connection: ToolboxConnection?
        var watcher: Task<Void, Never>?
        var closing: Task<Void, Never>?
        init(context: ToolContext, authority: RuntimeTaskAuthority, binding: RuntimeAuthorityBinding, payload: Data, operation: Task<ToolboxConnection, Error>) {
            self.context = context; self.authority = authority; self.binding = binding; self.payload = payload; self.operation = operation
        }
    }
    private weak var environment: AppEnvironment?
    private var entries: [UUID: Entry] = [:]
    private var unavailableOwners: Set<UUID> = []
    var activeSessionCount: Int { entries.count }
    init(environment: AppEnvironment) { self.environment = environment }
    private func current(_ context: ToolContext) async throws {
        try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
        guard let environment, let id = context.conversationID, !unavailableOwners.contains(id), context.scope == .local, !context.temporaryReadOnly, !context.publicWebOnly,
              context.childExecution == nil, let conversation = try await environment.conversationStore.conversation(id: id),
              conversation.purpose == .ordinary, let run = try await environment.runStore.run(id: context.runID),
              run.conversationID == id, run.endedAt == nil,
              !["completed", "failed", "cancelled", "canceled", "stopped"].contains(run.state) else { throw ToolboxError.staleSession }
        guard !unavailableOwners.contains(id) else { throw ToolboxError.staleSession }
        try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
    }
    private func binding(_ args: ToolboxSessionArguments, _ context: ToolContext) throws -> RuntimeAuthorityBinding {
        guard let callID = context.toolCallID, !callID.isEmpty, context.approvalGrantID != nil else { throw ToolboxError.denied }
        let payload = try args.payload()
        var call = try ToolCall(id: callID, toolName: ToolboxSessionTool.name, argumentsJSON: payload, scope: context.scope)
        call.idempotencyKey = context.toolIdempotencyKey
        return context.runtimeAuthorityBinding(toolName: ToolboxSessionTool.name, operation: "apply",
            canonicalTarget: RuntimeAuthorityDigest.canonicalTarget(for: call, descriptor: FloeTools.ToolCatalog.descriptor(named: ToolboxSessionTool.name),
                workspaceRootURL: context.workspaceRootURL, stagedDocument: context.canvasStagedDocument),
            baseRevision: nil, payloadDigest: RuntimeAuthorityDigest.payloadDigest(payload))
    }
    func perform(_ args: ToolboxSessionArguments, context: ToolContext) async throws -> String {
        try await current(context)
        if let entry = entries[context.runID] {
            guard entry.context.conversationID == context.conversationID, entry.context.environmentID == context.environmentID,
                  RuntimeAuthorityDigest.environmentBinding(workspaceRootURL: entry.context.workspaceRootURL, conversationID: entry.context.conversationID)
                    == RuntimeAuthorityDigest.environmentBinding(workspaceRootURL: context.workspaceRootURL, conversationID: context.conversationID) else { throw ToolboxError.staleSession }
        }
        if args.action == "status" { return try receipt(context.runID) }
        let approved = try binding(args, context), payload = try args.payload()
        if args.action == "open", let entry = entries[context.runID] {
            guard entry.closing == nil else { throw ClientError.busy }
            // Store.validate returns alreadyConsumed before comparing fields;
            // therefore reuse ALSO requires the exact stored native token AND
            // full binding/payload/config, never a model-supplied call ID.
            guard entry.authority == context.runtimeAuthority, entry.binding == approved, entry.payload == payload,
                  entry.context.environmentID == context.environmentID else { throw FloeError.validationFailed("This run already owns a different session/approved call. Close it before opening another target.") }
            let validation = await context.validatedRuntimeAuthority(binding: approved)
            guard validation == .valid || validation == .alreadyConsumed else { throw ToolboxError.denied }
            return try await complete(entry, runID: context.runID, context: context)
        }
        guard await context.consumeRuntimeAuthority(binding: approved) == .valid, let authority = context.runtimeAuthority else { throw ToolboxError.denied }
        try await current(context)
        if args.action == "close" { await closeRun(context.runID); return try receipt(context.runID) }
        // A second approved call may have completed its actor hops while
        // authority/current-run checks awaited. Never replace its target.
        guard entries[context.runID] == nil else { throw ClientError.busy }
        guard entries.count < 8, let environment else { throw ToolboxError.limit("active native toolbox runs") }
        let (tool, setup) = try args.setup()
        let operation = Task { try await ToolboxConnection.open(tool: tool, setup: setup, environment: environment, workbenchModels: false) }
        let entry = Entry(context: context, authority: authority, binding: approved, payload: payload, operation: operation)
        entries[context.runID] = entry
        entry.watcher = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.entries[context.runID]?.id == entry.id else { return }
                do { try await self.current(context) }
                catch { await self.closeRun(context.runID, expected: entry.id); return }
            }
        }
        return try await complete(entry, runID: context.runID, context: context)
    }
    private func complete(_ entry: Entry, runID: UUID, context: ToolContext) async throws -> String {
        do {
            let operation = entry.operation
            let connection = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            try await current(context)
            guard entries[runID]?.id == entry.id else { await connection.close(); throw ToolboxError.staleSession }
            entry.connection = connection
            return try receipt(runID)
        } catch { await closeRun(runID, expected: entry.id); throw error }
    }
    private func receipt(_ runID: UUID) throws -> String {
        var value: [String: Any] = ["state": "closed", "runID": runID.uuidString,
            "captureScope": "This run's redacted native session traffic, not system PCAP", "deviceStateConfirmed": false,
            "connectionEvidence": "connected reports the completed open handshake/CONNACK, not a new reachability test"]
        if let entry = entries[runID] {
            value["state"] = entry.closing != nil ? "closing" : entry.connection?.active == true ? "connected" : "connecting"
            value["environmentID"] = entry.context.environmentID.map { $0 as Any } ?? NSNull()
            value["executionSurface"] = "nativeDeviceNetwork"
            value["configurationSHA256"] = FloeDigest.sha256Hex(entry.payload)
            if let connection = entry.connection {
                value["sessionID"] = connection.lease.sessionID.uuidString
                value["protocol"] = connection.tool == .webSocket ? "websocket" : "mqtt"
                value["availableTools"] = try connection.frozenHost(runID: runID).availableToolNames.intersection(Self.toolNames).sorted()
            }
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
    func resolve(_ context: ToolContext) async throws -> ToolboxAIHostContext {
        try await current(context)
        guard let entry = entries[context.runID], entry.closing == nil, let connection = entry.connection, connection.active,
              entry.context.conversationID == context.conversationID, entry.context.environmentID == context.environmentID,
              RuntimeAuthorityDigest.environmentBinding(workspaceRootURL: entry.context.workspaceRootURL, conversationID: entry.context.conversationID)
                == RuntimeAuthorityDigest.environmentBinding(workspaceRootURL: context.workspaceRootURL, conversationID: context.conversationID) else { throw ToolboxError.staleSession }
        let entryID = entry.id
        return try ToolboxAIHostContext(runID: context.runID, lease: connection.lease, journal: connection.journal,
            serial: connection.serial, mqtt: connection.mqtt, redactor: connection.redactor, isCurrent: { [weak self, weak connection] in
                guard let self, let connection else { return false }
                return await self.isCurrent(context, entryID: entryID, connection: connection)
            })
    }
    private func isCurrent(_ context: ToolContext, entryID: UUID, connection: ToolboxConnection) async -> Bool {
        do { try await current(context); return entries[context.runID]?.id == entryID && connection.active } catch { return false }
    }
    private func closeRun(_ runID: UUID, expected: UUID? = nil) async {
        guard let entry = entries[runID], expected == nil || entry.id == expected else { return }
        if let closing = entry.closing { await closing.value; return }
        entry.watcher?.cancel(); entry.watcher = nil
        entry.connection?.invalidate(); entry.operation.cancel()
        let closing = Task {
            if let connection = try? await entry.operation.value { connection.invalidate(); await connection.close() }
        }
        entry.closing = closing
        await closing.value
        if entries[runID]?.id == entry.id { entries[runID] = nil }
    }
    func close(conversationIDs: Set<UUID>) async {
        unavailableOwners.formUnion(conversationIDs)
        for (runID, entry) in entries where entry.context.conversationID.map(conversationIDs.contains) == true { await closeRun(runID, expected: entry.id) }
    }
    func allow(conversationIDs: Set<UUID>) { unavailableOwners.subtract(conversationIDs) }
}
#endif
