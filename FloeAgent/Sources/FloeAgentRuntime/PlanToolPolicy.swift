import Foundation
import FloeModels
import FloeTools

/// Product mode governs executable tools independently of prompt style and model budgets.
public enum ConversationToolAccess: String, Sendable, Codable {
    case task, chat, plan

    public static let chatNames: Set<String> = ToolSchemaOfferPlanner.baseMemoryToolNames.union([
        "user.ask", "web.search", "web.fetch", "workspace.listDirectory", "workspace.searchFiles", "workspace.readFile"
    ])
    static let planBaseNames = chatNames.union([
        "workspace.inspectFileMetadata", "conversation.list", "conversation.search", "conversation.read",
        "goal.read", "checklist.readPlan", "skill.list", "skill.search"
    ]) // Three runtime helpers and plan.submit complete the 24.
    static let planInvestigationNames = planBaseNames.union([
        "git.status", "git.diff", "git.log", "skill.read", "checklist.resetPlan", "memory.sources.read",
        "document.pdf.inspect", "document.office.inspect", "document.readSheet"
    ])

    public func allows(_ descriptor: ToolCatalog.Descriptor) -> Bool {
        guard self != .task else { return true }
        let names = self == .chat ? Self.chatNames : Self.planInvestigationNames
        guard names.contains(descriptor.name) else { return false }
        if case .success = PlanToolPolicy().decision(for: descriptor) { return true }
        return false
    }

    private static func publicWebKeys(_ name: String) -> Set<String>? {
        switch name {
        case "web.search": ["query","mode","domains","excludeDomains","recencyDays","maxResults","provider"]
        case "web.fetch": ["url","format","maxCharacters","startCharacter","timeout","cachePolicy"]
        default: nil
        }
    }

    func presented(_ descriptor: ToolCatalog.Descriptor) -> ToolCatalog.Descriptor? {
        guard allows(descriptor) else { return nil }
        guard self != .task else { return descriptor }
        var result = descriptor
        switch descriptor.name {
        case "web.search", "web.fetch":
            let search = descriptor.name == "web.search"
            guard let keep = Self.publicWebKeys(descriptor.name),
                  var schema = (try? JSONSerialization.jsonObject(with: Data(descriptor.parametersJSON.utf8))) as? [String: Any],
                  schema["type"] as? String == "object" else { return nil }
            let props = schema["properties"] as? [String: Any] ?? [:]
            var visible = props.filter { keep.contains($0.key) }
            if search, var provider = visible["provider"] as? [String: Any] {
                provider["description"] = "Optional configured public web provider name, kind, or UUID."
                visible["provider"] = provider
            }
            schema["properties"] = visible
            guard let bytes = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) else { return nil }
            result.parametersJSON = String(decoding: bytes, as: UTF8.self)
            result.toolDescription = search ? "Search configured public web sources. Fetch a result to verify the page."
                : "Read a public HTTPS page with no authentication. Use startCharacter to continue."
        case "memory.search" where self == .chat:
            result.toolDescription = "Find relevant durable memories. Results include IDs for updating or forgetting entries."
        case "skill.read":
            if var schema = (try? JSONSerialization.jsonObject(with: Data(result.parametersJSON.utf8))) as? [String: Any],
               var props = schema["properties"] as? [String: Any] {
                props["source"] = ["type": "string", "enum": ["installed"]]
                schema["properties"] = props
                if let bytes = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) {
                    result.parametersJSON = String(decoding: bytes, as: UTF8.self)
                }
            }
            result.toolDescription = "Read installed workflow instructions by ID and offset, without preparing executable resources."
        default: break
        }
        return result
    }

    func permitsArguments(_ call: ToolCall) -> Bool {
        guard self != .task else { return true }
        if call.toolName == "skill.read" {
            guard let args = (try? JSONSerialization.jsonObject(with: call.argumentsJSON)) as? [String: Any] else { return false }
            return args["source"] == nil || args["source"] as? String == "installed"
        }
        guard let allowed = Self.publicWebKeys(call.toolName) else { return true }
        guard let args = (try? JSONSerialization.jsonObject(with: call.argumentsJSON)) as? [String: Any] else { return false }
        return Set(args.keys).isSubset(of: allowed)
    }
}

public enum PlanToolDenialReason: String, Sendable, Codable, Hashable {
    case mutationNotAllowed
    case internalStateNotModelCallable
    case professionalSearchNotAllowed
    case unknownTool
}

/// Capability filter used both while constructing provider schemas and
/// immediately before execution. It is deliberately independent of model
/// instructions: a forged tool call still reaches `decision(for:)`.
/// Native questions and the exact main-run checklist reset are narrow
/// internal metadata exceptions. Neither grants external mutation authority.
public struct PlanToolPolicy: Sendable {
    public init() {}

    public func decision(for descriptor: ToolCatalog.Descriptor) -> Result<Void, PlanToolPolicyError> {
        if ["memory.remember", "memory.update", "memory.forget"].contains(descriptor.name) {
            guard descriptor.effect == .internalState, descriptor.isSideEffecting,
                  descriptor.riskLabels == [.persistsPersonalData], descriptor.executionBoundary == .any,
                  !descriptor.requiresHostScope else {
                return .failure(PlanToolPolicyError(reason: .mutationNotAllowed, toolName: descriptor.name))
            }
            return .success(())
        }
        switch descriptor.effect {
        case .readOnly:
            guard !descriptor.isSideEffecting, !descriptor.riskLabels.contains(.writesFiles) else {
                return .failure(PlanToolPolicyError(reason: .mutationNotAllowed, toolName: descriptor.name))
            }
            return .success(())
        case .internalState:
            if [UserAskTool.name, TaskResetPlanTool.name].contains(descriptor.name),
               descriptor.executionBoundary == .mainRunOnly,
               !descriptor.isSideEffecting,
               descriptor.riskLabels.isEmpty,
               !descriptor.requiresHostScope {
                return .success(())
            }
            return .failure(PlanToolPolicyError(reason: .internalStateNotModelCallable, toolName: descriptor.name))
        case .mutating:
            return .failure(PlanToolPolicyError(reason: .mutationNotAllowed, toolName: descriptor.name))
        }
    }

    public func allowedDescriptors(
        from descriptors: [ToolCatalog.Descriptor]
    ) -> [ToolCatalog.Descriptor] {
        descriptors.filter {
            if case .success = decision(for: $0) { return true }
            return false
        }
    }

    public func denialResult(
        call: ToolCall,
        descriptor: ToolCatalog.Descriptor?
    ) -> ToolResult? {
        guard let descriptor else {
            return ToolResult(
                callID: call.id,
                status: .denied,
                outputSummary: "Plan mode denied unknown tool '\(call.toolName)'",
                outputDigest: ""
            )
        }
        // The native professional source is intentionally read-only, but plan
        // mode keeps its previous public-web boundary. This argument-aware
        // denial leaves the base descriptor/authorization identity untouched.
        if descriptor.name == ProfessionalSearchAuthority.unifiedToolName,
           ProfessionalSearchAuthority.requestsProfessionalSource(argumentsJSON: call.argumentsJSON) {
            let error = PlanToolPolicyError(
                reason: .professionalSearchNotAllowed,
                toolName: descriptor.name
            )
            return ToolResult(
                callID: call.id,
                status: .denied,
                outputSummary: error.localizedDescription,
                outputDigest: ""
            )
        }
        guard case .failure(let error) = decision(for: descriptor) else { return nil }
        return ToolResult(
            callID: call.id,
            status: .denied,
            outputSummary: error.localizedDescription,
            outputDigest: ""
        )
    }
}

public struct PlanToolPolicyError: Error, Sendable, Codable, Hashable, LocalizedError {
    public var reason: PlanToolDenialReason
    public var toolName: String

    public init(reason: PlanToolDenialReason, toolName: String) {
        self.reason = reason
        self.toolName = toolName
    }

    public var errorDescription: String? {
        switch reason {
        case .mutationNotAllowed:
            "Plan mode is read-only; tool '\(toolName)' may change external state"
        case .internalStateNotModelCallable:
            "Floe internal draft state cannot be modified through tool '\(toolName)'"
        case .professionalSearchNotAllowed:
            "Plan mode allows public web search only; professional dataset search requires an ordinary agent run"
        case .unknownTool:
            "Plan mode denied unknown tool '\(toolName)'"
        }
    }
}

/// Reusable executor-side guard for callers outside `FloeAgentRuntime`.
public struct PlanEnforcingToolExecutor: ToolExecutor {
    private let underlying: any ToolExecutor
    private let policy: PlanToolPolicy

    public init(underlying: any ToolExecutor, policy: PlanToolPolicy = PlanToolPolicy()) {
        self.underlying = underlying
        self.policy = policy
    }

    public func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        underlying.descriptor(named: name)
    }

    public var allDescriptors: [ToolCatalog.Descriptor] {
        underlying.allDescriptors
    }

    public func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        if let denial = policy.denialResult(call: call, descriptor: underlying.descriptor(named: call.toolName)) {
            return denial
        }
        return try await underlying.execute(call, context: context)
    }
}
