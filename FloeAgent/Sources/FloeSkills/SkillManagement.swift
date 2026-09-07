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
    /// Latest installed revision for optimistic edits; `digest` remains the
    /// running task's pinned execution revision.
    public var currentDigest: String?
    public var markdown: String?
    public var requiredToolNames: [String]?
    public var nextOffset: Int?
    public var totalCharacters: Int?
    public init(id: String, name: String, version: String, enabled: Bool, digest: String, markdown: String? = nil, requiredToolNames: [String]? = nil, currentDigest: String? = nil) {
        self.id = id; self.name = name; self.version = version
        self.enabled = enabled; self.digest = digest; self.markdown = markdown
        self.requiredToolNames = requiredToolNames
        self.currentDigest = currentDigest
    }
}

public protocol SkillManaging: Sendable {
    func read(id: String?) async throws -> [ManagedSkill]
    func read(id: String?, runID: UUID) async throws -> [ManagedSkill]
    func manage(_ request: SkillManageTool.Arguments) async throws -> String
}

public extension SkillManaging {
    func read(id: String?, runID: UUID) async throws -> [ManagedSkill] { try await read(id: id) }
}

/// Metadata discovery does not read/activate instructions or execute scripts.
public struct SkillSearchTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var query: String
        public init(query: String) { self.query = query }
    }
    public static let name = "skill.search"
    public static let toolDescription = "Find installed workflow guides by task, domain or skill ID (English or Chinese). Prefer this for PDF, Office, network and multi-step domain workflows; then skill.read the returned ID before acting. For an exact executable function use tools.search. Search does not grant permissions, enable a disabled skill or execute scripts."
    public static let parametersJSON = #"{"type":"object","properties":{"query":{"type":"string","minLength":1,"maxLength":512}},"required":["query"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    private let manager: any SkillManaging
    public init(manager: any SkillManaging) { self.manager = manager }
    public func validate(_ args: Arguments) throws {
        guard !args.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, args.query.count <= 512 else {
            throw FloeError.validationFailed("Supply a nonempty skill search query of at most 512 characters")
        }
    }
    public static func matches(query: String, rows: [ManagedSkill]) -> [ManagedSkill] {
        let query = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let aliases: [String: [String]] = [
            "floe-python": ["python", "pandas", "numpy", "pillow", "scipy", "matplotlib", "数据分析"],
            "floe-pdf": ["pdf", "扫描文档", "ocr", "表单"],
            "floe-office": ["office", "word", "excel", "docx", "xlsx", "表格", "工作簿", "文档"],
            "floe-network": ["network", "网络", "http", "dns", "ping", "traceroute", "内网"],
            "floe-remote": ["remote", "vnc", "ssh", "terminal", "executor", "远程", "终端"],
            "floe-files-vcs": ["git", "文件", "archive", "rar", "zip", "归档", "解压"],
            "floe-browser": ["browser", "网页", "浏览器"],
            "floe-apple": ["apple", "邮件", "mail", "日历", "提醒"],
            "floe-crypto": ["crypto", "加密", "签名", "哈希"]
        ]
        let tokens = query.split { $0.isWhitespace || $0.isPunctuation }.map(String.init)
        var ranked: [(skill: ManagedSkill, score: Int)] = []
        for row in rows {
            let identity = (row.id + " " + row.name).lowercased()
            let aliasScore = (aliases[row.id] ?? []).filter { query.contains($0) }.count * 10
            let nameScore = tokens.filter { identity.contains($0) }.count
            let score = query == row.id.lowercased() ? 100 : aliasScore + nameScore
            if score > 0 { ranked.append((row, score)) }
        }
        ranked.sort { $0.score == $1.score ? $0.skill.id < $1.skill.id : $0.score > $1.score }
        return ranked.prefix(8).map { $0.skill }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        let rows = try await manager.read(id: nil, runID: context.runID)
        let matches = Self.matches(query: args.query, rows: rows)
        struct Response: Encodable {
            let matches: [ManagedSkill]
            let installedIDs: [String]
            let nextAction: String
        }
        let data = try JSONEncoder().encode(Response(matches: matches,
            installedIDs: matches.isEmpty ? rows.map(\.id).sorted() : [],
            nextAction: matches.isEmpty ? "Choose an installed ID with skill.read, or tools.search for an executable capability; do not repeat the same search." : "Read the chosen enabled guide with skill.read(id:); disabled guides require a user settings change."))
        return ToolExecutionOutput(summary: String(decoding: data, as: UTF8.self), fullOutputSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), maximumSummaryCharacters: 32_768)
    }
}

public struct SkillReadTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var id: String?
        public var offset: Int?
        public var limit: Int?
        public init(id: String? = nil, offset: Int? = nil, limit: Int? = nil) { self.id = id; self.offset = offset; self.limit = limit }
    }
    public static let name = "skill.read"
    public static let toolDescription = "List installed skill metadata, or read one exact skill ID with pinned Markdown, audited scripts and digest. If nextOffset is present, keep reading that id and offset until complete before applying the instructions or running a script. Reading loads available tool schemas; it never executes scripts or grants permissions. Task snapshots keep the reviewed version across upgrades and recovery. For skill.manage use currentDigest (or the metadata list digest), not an older pinned execution digest."
    public static let parametersJSON = #"{"type":"object","properties":{"id":{"type":"string"},"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":32768}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    private let manager: any SkillManaging
    public init(manager: any SkillManaging) { self.manager = manager }
    public func validate(_ args: Arguments) throws {
        if let id = args.id { try SkillManageTool.validateID(id) }
        guard args.offset ?? 0 >= 0, (1...32_768).contains(args.limit ?? 32_768), args.id != nil || (args.offset == nil && args.limit == nil) else {
            throw FloeError.validationFailed("Pagination requires an exact skill id, nonnegative offset and limit of 1–32768 characters")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args); try context.cancellation.throwIfCancelled()
        var rows = try await manager.read(id: args.id, runID: context.runID)
        for index in rows.indices {
            guard let markdown = rows[index].markdown else { continue }
            let total = markdown.count, offset = args.offset ?? 0, limit = args.limit ?? 32_768
            guard offset <= total else { throw FloeError.validationFailed("Skill offset is beyond the document") }
            rows[index].markdown = String(markdown.dropFirst(offset).prefix(limit))
            rows[index].totalCharacters = total
            rows[index].nextOffset = offset + limit < total ? offset + limit : nil
        }
        let data = try JSONEncoder().encode(rows)
        guard data.count <= 262_144 else { throw FloeError.validationFailed("Skill response exceeds 256 KiB; select one smaller skill") }
        return ToolExecutionOutput(summary: String(decoding: data, as: UTF8.self), fullOutputSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), maximumSummaryCharacters: 262_144)
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
        do { try SkillIdentifier.validate(id) }
        catch { throw FloeError.validationFailed("Invalid skill ID") }
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
