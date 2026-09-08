import Foundation
import Crypto
import FloeCore
import FloeTools

/// Enumerates metadata only. Does not read or activate workflow instructions.
public struct SkillListTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var afterID: String?
        public var limit: Int?
        public init(afterID: String? = nil, limit: Int? = nil) {
            self.afterID = afterID; self.limit = limit
        }
    }
    public static let name = "skill.list"
    public static let toolDescription = "List all installed skill metadata in stable ID order, including disabled skills. Follow nextAfterID until null. Does not read instructions, enable skills, load schemas or grant permissions. Use skill.search for one or multiple capability queries."
    public static let parametersJSON = #"{"type":"object","properties":{"afterID":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":100}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    private let manager: any SkillManaging
    public init(manager: any SkillManaging) { self.manager = manager }
    public func validate(_ args: Arguments) throws {
        guard (1...100).contains(args.limit ?? 30) else {
            throw FloeError.validationFailed("Skill list limit must be 1–100")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        let rows = try await manager.read(id: nil, runID: context.runID).sorted { $0.id < $1.id }
        let remaining = rows.filter { args.afterID == nil || $0.id > args.afterID! }
        var page = Array(remaining.prefix(args.limit ?? 30))
        for index in page.indices {
            page[index].markdown = nil
            page[index].nextOffset = nil
            page[index].totalCharacters = nil
        }
        struct Response: Encodable {
            let skills: [ManagedSkill]
            let total: Int
            let nextAfterID: String?
        }
        let data = try JSONEncoder().encode(Response(skills: page, total: rows.count,
            nextAfterID: remaining.count > page.count ? page.last?.id : nil))
        return .init(summary: String(decoding: data, as: UTF8.self),
            fullOutputSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            maximumSummaryCharacters: 262_144)
    }
}
