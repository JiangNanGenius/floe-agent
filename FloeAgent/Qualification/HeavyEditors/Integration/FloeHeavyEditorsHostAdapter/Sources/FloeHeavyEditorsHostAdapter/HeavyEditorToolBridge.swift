// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeHeavyEditorSupport

public struct HeavyEditorTaskGrant: Sendable {
    public let enabledKinds: Set<HeavyEditorKind>
    public let projects: Set<UUID>
    public let canCreate: Bool
    public let readOnly: Bool
    public init(enabledKinds: Set<HeavyEditorKind>, projects: Set<UUID>, canCreate: Bool, readOnly: Bool) {
        self.enabledKinds = enabledKinds; self.projects = projects; self.canCreate = canCreate; self.readOnly = readOnly
    }
}
public struct HeavyEditorCreationRequest: Sendable {
    public let kind: HeavyEditorKind
    public let title: String
    public let requestID: String
}
public enum HeavyEditorToolAction: String, Sendable, CaseIterable {
    case create, describe, query, invoke, importFile = "import", export
    public var isReadOnly: Bool { self == .describe || self == .query }
}
public typealias HeavyEditorCallAuthorization = @Sendable () async throws -> Void

/// Domain output resolution/publication runs before the actual controller/file
/// lease is released. A JSON fileID alone is never a tool attachment.
public struct HeavyEditorToolLease: Sendable {
    public let model: HeavyEditorModelLease
    public let complete: @Sendable (EditorJSON, ToolContext) async throws -> ToolExecutionOutput
    public init(model: HeavyEditorModelLease,
                complete: (@Sendable (EditorJSON, ToolContext) async throws -> ToolExecutionOutput)? = nil) {
        self.model = model
        self.complete = complete ?? { result, _ in
            guard result["exports"].array.isEmpty else { throw HeavyEditorError.invalidDocument }
            let text = try result.text()
            return .init(digesting: text, exitStatus: 0, capturedOutput: text)
        }
    }
}

/// This actor delegates permission decisions to the real task host and the
/// existing runtime token store. Only its own successful claim permits later
/// checks to accept alreadyConsumed; revocation and expiry still reject.
actor HeavyEditorInvocationGate {
    private let context: ToolContext
    private let cancellation: CancellationToken
    private let kind: HeavyEditorKind
    private let action: HeavyEditorToolAction
    private var projectID: UUID?
    private let binding: RuntimeAuthorityBinding
    private let grant: @Sendable (ToolContext) async throws -> HeavyEditorTaskGrant
    private var claimed = false
    init(context: ToolContext, kind: HeavyEditorKind, action: HeavyEditorToolAction,
         projectID: UUID?, binding: RuntimeAuthorityBinding, cancellation: CancellationToken,
         grant: @escaping @Sendable (ToolContext) async throws -> HeavyEditorTaskGrant) {
        self.context = context; self.kind = kind; self.action = action; self.cancellation = cancellation
        self.projectID = projectID; self.binding = binding; self.grant = grant
    }
    func bindCreated(_ id: UUID) async throws { projectID = id; try await check() }
    func check(effect: Bool = false) async throws {
        try Task.checkCancellation(); try cancellation.throwIfCancelled(); try context.cancellation.throwIfCancelled()
        let name = kind.rawValue + "." + action.rawValue
        guard !context.temporaryReadOnly, !context.publicWebOnly, context.childExecution == nil,
              context.conversationID != nil, context.executionToolName == name,
              context.allowedToolNames?.contains(name) != false,
              context.frozenEffectiveCatalogNames?.contains(name) != false else { throw HeavyEditorError.invalidCommand }
        let current = try await grant(context)
        guard current.enabledKinds.contains(kind), !current.readOnly || action.isReadOnly,
              action != .create || current.canCreate else { throw HeavyEditorError.invalidCommand }
        if let projectID { guard current.projects.contains(projectID) else { throw HeavyEditorError.wrongDocument } }
        if let authority = context.runtimeAuthority {
            let validation = await RuntimeAuthorityStore.shared.validate(authority, binding: binding)
            guard validation == .valid || (claimed && validation == .alreadyConsumed) else { throw HeavyEditorError.invalidCommand }
            if effect && !claimed {
                guard await context.consumeRuntimeAuthority(binding: binding) == .valid else { throw HeavyEditorError.invalidCommand }
                claimed = true
            }
        } else if !action.isReadOnly {
            throw HeavyEditorError.invalidCommand
        }
        try Task.checkCancellation(); try cancellation.throwIfCancelled(); try context.cancellation.throwIfCancelled()
    }
    func authorize(_ request: HeavyEditorAccessRequest) async throws {
        guard request.documentID == projectID else { throw HeavyEditorError.wrongDocument }
        switch action {
        case .describe, .query, .create: guard request.access == .read else { throw HeavyEditorError.invalidCommand }
        case .invoke: guard request.access == .read || request.access == .edit else { throw HeavyEditorError.invalidCommand }
        case .importFile: guard request.access == .read || request.access == .importFile else { throw HeavyEditorError.invalidCommand }
        case .export: guard request.access == .read || request.access == .exportFile else { throw HeavyEditorError.invalidCommand }
        }
        try await check(effect: !action.isReadOnly)
    }
}

public final class HeavyEditorToolBridge: Sendable {
    private let grant: @Sendable (ToolContext) async throws -> HeavyEditorTaskGrant
    private let open: @Sendable (UUID, HeavyEditorToolAction, ToolContext, @escaping HeavyEditorCallAuthorization) async throws -> HeavyEditorToolLease
    private let create: @Sendable (HeavyEditorCreationRequest, ToolContext, @escaping HeavyEditorCallAuthorization) async throws -> UUID
    private let source: @Sendable (String, ToolContext) async throws -> HeavyEditorArtifact
    public init(grant: @escaping @Sendable (ToolContext) async throws -> HeavyEditorTaskGrant,
                open: @escaping @Sendable (UUID, HeavyEditorToolAction, ToolContext, @escaping HeavyEditorCallAuthorization) async throws -> HeavyEditorToolLease,
                create: @escaping @Sendable (HeavyEditorCreationRequest, ToolContext, @escaping HeavyEditorCallAuthorization) async throws -> UUID,
                resolveFile: @escaping @Sendable (String, ToolContext) async throws -> HeavyEditorArtifact) {
        self.grant = grant; self.open = open; self.create = create; self.source = resolveFile
    }
    public func descriptors(for context: ToolContext) async throws -> [ToolCatalog.Descriptor] {
        guard !context.temporaryReadOnly, !context.publicWebOnly, context.childExecution == nil, context.conversationID != nil else { return [] }
        let current = try await grant(context)
        return try current.enabledKinds.sorted { $0.rawValue < $1.rawValue }.flatMap { kind in
            try HeavyEditorToolAction.allCases.filter { (!current.readOnly || $0.isReadOnly) && ($0 != .create || current.canCreate) }
                .map { try Self.descriptor(kind, action: $0) }
        }.filter { context.allowedToolNames?.contains($0.name) != false && context.frozenEffectiveCatalogNames?.contains($0.name) != false }
    }
    /// Three domain hosts register their own six names without overwriting one
    /// another's closures. The implementation and schemas are shared.
    public func register(in registry: ToolRunnerRegistry = .shared, kinds: Set<HeavyEditorKind> = Set(HeavyEditorKind.allCases)) throws {
        for kind in kinds { for action in HeavyEditorToolAction.allCases {
            let descriptor = try Self.descriptor(kind, action: action)
            registry.register(AnyAgentTool(descriptor: descriptor, run: { [self] data, context in
                try await execute(kind, action: action, data: data, context: context)
            }, validateArguments: { data in _ = try Self.arguments(data, action: action) }))
        }}
    }
    private struct Arguments: Decodable {
        var projectID: UUID?
        var baseRevision: UInt64?
        var title: String?
        var command: String?
        var arguments: EditorJSON?
        var fileID: String?
        var discovery: HeavyEditorDiscoveryPage?
    }
    private static func arguments(_ data: Data, action: HeavyEditorToolAction) throws -> Arguments {
        guard data.count <= 1_048_576, case .object(let object) = try EditorJSON.decode(data) else { throw HeavyEditorError.invalidDocument }
        let keys: Set<String>
        switch action {
        case .create: keys = ["title"]
        case .describe: keys = ["projectID", "baseRevision", "command", "arguments", "discovery"]
        case .importFile: keys = ["projectID", "baseRevision", "fileID", "arguments"]
        default: keys = ["projectID", "baseRevision", "command", "arguments"]
        }
        guard Set(object.keys).isSubset(of: keys) else { throw HeavyEditorError.invalidCommand }
        let args = try JSONDecoder().decode(Arguments.self, from: data)
        if action == .create {
            guard let title = args.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200 else { throw HeavyEditorError.invalidDocument }
        } else if action != .describe { guard args.projectID != nil else { throw HeavyEditorError.invalidDocument } }
        if ![HeavyEditorToolAction.create, .describe].contains(action) { guard args.baseRevision != nil else { throw HeavyEditorError.revisionConflict } }
        if [.query, .invoke, .export].contains(action) { guard let command = args.command, !command.isEmpty else { throw HeavyEditorError.invalidCommand } }
        if action == .importFile { guard let file = args.fileID, !file.isEmpty, file.count <= 512 else { throw HeavyEditorError.invalidDocument } }
        if action == .describe, args.projectID == nil { guard args.command == nil, args.baseRevision == nil, args.arguments == nil else { throw HeavyEditorError.invalidCommand } }
        if let arguments = args.arguments { guard case .object = arguments else { throw HeavyEditorError.invalidCommand } }
        if let page = args.discovery {
            guard Set(object["discovery"]!.object.keys).isSubset(of: ["query", "offset", "limit"]),
                  page.query.count <= 200, page.offset >= 0, (1...100).contains(page.limit) else { throw HeavyEditorError.invalidCommand }
        }
        return args
    }
    public static func descriptor(_ kind: HeavyEditorKind, action: HeavyEditorToolAction) throws -> ToolCatalog.Descriptor {
        let string: EditorJSON = .object(["type": .string("string")])
        let revision: EditorJSON = .object(["type": .string("integer"), "minimum": .number(0)])
        var properties: [String: EditorJSON] = [:], required: [String] = []
        if action == .create { properties = ["title": string]; required = ["title"] }
        else { properties = ["projectID": .object(["type": .string("string"), "format": .string("uuid")])]; required = action == .describe ? [] : ["projectID"] }
        if ![HeavyEditorToolAction.create, .describe].contains(action) { properties["baseRevision"] = revision; required.append("baseRevision") }
        if [.query, .invoke, .export, .describe].contains(action) {
            properties["command"] = string; properties["arguments"] = .object(["type": .string("object")])
            if action != .describe { required.append("command") }
        }
        if action == .describe {
            properties["baseRevision"] = revision
            properties["discovery"] = .object(["type": .string("object"), "additionalProperties": .bool(false), "properties": .object([
                "query": .object(["type": .string("string"), "maxLength": .number(200)]),
                "offset": revision, "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(100)])])])
        }
        if action == .importFile { properties["fileID"] = string; properties["arguments"] = .object(["type": .string("object")]); required.append("fileID") }
        let schema: EditorJSON = .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(EditorJSON.string)), "additionalProperties": .bool(false)])
        let description: String
        switch action {
        case .create: description = "Create a durable task-bound \(kind.rawValue) original. Its owner and library are fixed by the native host."
        case .describe: description = "Without projectID, page/search this task's authorized project IDs. With projectID, read a compact command index and revision. Optional command/arguments return one live schema; discovery pages and searches its options."
        case .query: description = "Run a pure read command against the exact authorized original and revision."
        case .invoke: description = "Run an editing or analysis command from describe against the same authorized original and expected revision."
        case .importFile: description = "Import an authorized opaque fileID; optional arguments contain only bundled import options, never name/base64/path/owner."
        case .export: description = "Export from this original and return verified managed receipts plus actual task file attachments. Font export does not install fonts."
        }
        return .init(name: kind.rawValue + "." + action.rawValue, toolDescription: description, parametersJSON: try schema.text(),
            riskLabels: action.isReadOnly ? [.readsFiles] : [.readsFiles, .writesFiles], isSideEffecting: !action.isReadOnly,
            effect: action.isReadOnly ? .readOnly : .mutating, executionBoundary: .mainRunOnly)
    }
    private func execute(_ kind: HeavyEditorKind, action: HeavyEditorToolAction, data: Data, context: ToolContext) async throws -> ToolExecutionOutput {
        let cancellation = context.cancellation.derived()
        let worker = Task { try await executeBound(kind, action: action, data: data, context: context, cancellation: cancellation) }
        let monitor = Task {
            while !Task.isCancelled {
                if context.cancellation.isCancelled { cancellation.cancel(); worker.cancel(); return }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
        defer { monitor.cancel() }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { cancellation.cancel(); worker.cancel() }
    }
    private func executeBound(_ kind: HeavyEditorKind, action: HeavyEditorToolAction, data: Data, context: ToolContext, cancellation: CancellationToken) async throws -> ToolExecutionOutput {
        let args = try Self.arguments(data, action: action)
        guard let callID = context.toolCallID, !callID.isEmpty else { throw HeavyEditorError.invalidCommand }
        let name = kind.rawValue + "." + action.rawValue
        var call = try ToolCall(id: callID, toolName: name, argumentsJSON: data, scope: context.scope)
        call.idempotencyKey = context.toolIdempotencyKey
        let descriptor = try Self.descriptor(kind, action: action)
        let binding = context.runtimeAuthorityBinding(toolName: name, operation: "apply",
            canonicalTarget: RuntimeAuthorityDigest.canonicalTarget(for: call, descriptor: descriptor,
                workspaceRootURL: context.workspaceRootURL, stagedDocument: context.canvasStagedDocument, serviceStorePaths: context.serviceStorePaths),
            baseRevision: RuntimeAuthorityDigest.baseRevision(in: data), payloadDigest: RuntimeAuthorityDigest.payloadDigest(data))
        let gate = HeavyEditorInvocationGate(context: context, kind: kind, action: action, projectID: args.projectID, binding: binding, cancellation: cancellation, grant: grant)
        try await gate.check()
        if action == .describe, args.projectID == nil {
            let current = try await grant(context), page = args.discovery ?? .init()
            let values = current.projects.map(\.uuidString).sorted()
            let filtered = values.filter { page.query.isEmpty || $0.localizedCaseInsensitiveContains(page.query) }
            let items = filtered.dropFirst(min(page.offset, filtered.count)).prefix(page.limit)
            try await gate.check()
            let value: EditorJSON = .object(["kind": .string(kind.rawValue), "projects": .array(items.map { .object(["projectID": .string($0)]) }),
                "total": .number(Double(values.count)), "matched": .number(Double(filtered.count)), "offset": .number(Double(page.offset)), "limit": .number(Double(page.limit)),
                "hasMore": .bool(page.offset < filtered.count && items.count < filtered.count - page.offset)])
            let text = try value.text(); return .init(digesting: text, capturedOutput: text)
        }
        let hostAuthorization: HeavyEditorCallAuthorization = { try await gate.check(effect: action == .create) }
        let id: UUID
        if action == .create {
            id = try await create(.init(kind: kind, title: args.title!, requestID: context.toolIdempotencyKey.isEmpty ? callID : context.toolIdempotencyKey), context, hostAuthorization)
            try await gate.bindCreated(id)
        } else { id = args.projectID! }
        let hosted = try await open(id, action, context, hostAuthorization)
        let scoped = HeavyEditorModelLease(controller: hosted.model.controller, authorize: { request in
            try await gate.authorize(request); try await hosted.model.authorize?(request)
        }, release: hosted.model.release)
        return try await HeavyEditorModelCalls.withLease(scoped) { lease in
            try await gate.check()
            let result: EditorJSON
            if action == .importFile {
                let artifact = try await source(args.fileID!, context)
                try await gate.check()
                result = try await Self.importFile(kind: kind, id: id, revision: args.baseRevision!, artifact: artifact,
                    options: args.arguments ?? .object([:]), lease: lease)
            } else {
                let operation: HeavyEditorToolOperation = action == .describe || action == .create ? .describe : action == .query ? .query : action == .export ? .export : .invoke
                result = try await HeavyEditorModelCalls.run(operation, kind: kind,
                    request: .init(projectID: id, baseRevision: args.baseRevision, command: args.command, arguments: args.arguments, discovery: args.discovery), lease: lease)
            }
            try await gate.check()
            let output = try await hosted.complete(result, context)
            try await gate.check()
            return output
        }
    }
    @MainActor private static func importFile(kind: HeavyEditorKind, id: UUID, revision: UInt64,
        artifact: HeavyEditorArtifact, options: EditorJSON, lease: HeavyEditorModelLease) async throws -> EditorJSON {
        guard lease.controller.document.id == id, lease.controller.descriptor.kind == kind else { throw HeavyEditorError.wrongDocument }
        try await lease.controller.waitUntilReady()
        try await lease.controller.importFile(name: artifact.name, data: artifact.data, arguments: options, expectedRevision: revision, authorization: lease.authorize)
        return try await lease.controller.describe(authorization: lease.authorize)
    }
}
