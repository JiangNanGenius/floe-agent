import Foundation
import Crypto
import FloeCore
import FloeTools

public struct ManagedSkill: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var version: String
    public var enabled: Bool
    public var digest: String
    public var markdown: String?
    public init(id: String, name: String, version: String, enabled: Bool, digest: String, markdown: String? = nil) {
        self.id = id; self.name = name; self.version = version
        self.enabled = enabled; self.digest = digest; self.markdown = markdown
    }
}

public protocol SkillManaging: Sendable {
    func read(id: String?) async throws -> [ManagedSkill]
    func manage(_ request: SkillManageTool.Arguments) async throws -> String
}

public struct SkillReadTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var id: String?
        public init(id: String? = nil) { self.id = id }
    }
    public static let name = "skill.read"
    public static let toolDescription = "List installed skill metadata, or read one exact skill ID with its Markdown and current digest for editing. This does not execute skill instructions."
    public static let parametersJSON = #"{"type":"object","properties":{"id":{"type":"string"}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    private let manager: any SkillManaging
    public init(manager: any SkillManaging) { self.manager = manager }
    public func validate(_ args: Arguments) throws {
        if let id = args.id { try SkillManageTool.validateID(id) }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args); try context.cancellation.throwIfCancelled()
        let data = try JSONEncoder().encode(try await manager.read(id: args.id))
        return skillOutput(String(decoding: data, as: UTF8.self))
    }
}

public struct SkillManageTool: AgentTool {
    public enum Action: String, Codable, Sendable { case update, setEnabled, remove }
    public struct Arguments: Decodable, Sendable {
        public var action: Action
        public var id: String
        public var expectedDigest: String
        public var instructions: String?
        public var enabled: Bool?
        public init(action: Action, id: String, expectedDigest: String, instructions: String? = nil, enabled: Bool? = nil) {
            self.action = action; self.id = id; self.expectedDigest = expectedDigest
            self.instructions = instructions; self.enabled = enabled
        }
    }
    public static let name = "skill.manage"
    public static let toolDescription = "Update an installed skill's instruction body, enable/disable it, or remove it. Removal retains a filesystem backup of the package for manual recovery; there is no automatic restore tool. First use skill.read for the exact ID and expectedDigest. Requires approval. Update preserves frontmatter, scripts, manifest and capability grants; it does not edit executable code or broaden permissions."
    public static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["update","setEnabled","remove"]},"id":{"type":"string"},"expectedDigest":{"type":"string"},"instructions":{"type":"string","description":"New Markdown body without frontmatter; update only"},"enabled":{"type":"boolean","description":"Required only for setEnabled"}},"required":["action","id","expectedDigest"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .changesAgentBehavior]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    private let manager: any SkillManaging
    public init(manager: any SkillManaging) { self.manager = manager }
    public static func validateID(_ id: String) throws {
        guard id.range(of: "^[a-z0-9][a-z0-9_-]{0,127}$", options: .regularExpression) != nil else {
            throw FloeError.validationFailed("Invalid skill ID")
        }
    }
    public func validate(_ args: Arguments) throws {
        try Self.validateID(args.id)
        guard args.expectedDigest.count == 64, args.expectedDigest.allSatisfy(\.isHexDigit) else {
            throw FloeError.validationFailed("Read the current skill digest before changing it")
        }
        switch args.action {
        case .update:
            guard let body = args.instructions, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  body.utf8.count <= 256 * 1024, args.enabled == nil else { throw FloeError.validationFailed("Update requires instructions only, at most 256 KiB") }
        case .setEnabled:
            guard args.enabled != nil, args.instructions == nil else { throw FloeError.validationFailed("setEnabled requires enabled only") }
        case .remove:
            guard args.enabled == nil, args.instructions == nil else { throw FloeError.validationFailed("remove accepts no update fields") }
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args); try context.cancellation.throwIfCancelled()
        guard context.approvalGrantID != nil else { throw FloeError.validationFailed("Skill changes require approval") }
        return skillOutput(try await manager.manage(args))
    }
}

private func skillOutput(_ text: String) -> ToolExecutionOutput {
    ToolExecutionOutput(summary: text, fullOutputSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined())
}
