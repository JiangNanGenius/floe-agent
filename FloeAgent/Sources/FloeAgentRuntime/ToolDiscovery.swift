import Foundation
import FloeTools
import FloeCore

/// Provider-independent deferred schemas. Search uses only executable tools
/// already inside this run's permission/skill ceiling.
enum ToolDiscovery {
    static let name = "tools.search"
    static let listName = "tools.list"
    static var listDescriptor: ToolCatalog.Descriptor {
        .init(name: listName,
              toolDescription: "List the complete executable tool directory within this task's permission ceiling without loading schemas or executing tools. Follow nextAfterName until absent. Filter by group if desired. schemaLoaded=false means discoverable, not missing; use tools.search with an exact name or queries array to load definitions.",
              parametersJSON: #"{"type":"object","properties":{"afterName":{"type":"string"},"group":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":100}},"additionalProperties":false}"#,
              riskLabels: [], isSideEffecting: false)
    }

    struct ListArguments: Decodable {
        var afterName: String?
        var group: String?
        var limit: Int?
    }

    /// Maps a model-spelled name to the canonical ceiling name. Compat-mode
    /// providers see dots as underscores on the wire, so cursors and exact
    /// queries may arrive underscored; case-insensitive throughout because
    /// compat models routinely drift case. A unique sanitized match wins.
    static func canonicalSpelling(_ spelling: String, among descriptors: [ToolCatalog.Descriptor]) -> String {
        let names = descriptors.map(\.name)
        if names.contains(spelling) { return spelling }
        if let folded = names.first(where: { $0.lowercased() == spelling.lowercased() }) { return folded }
        let target = spelling.replacingOccurrences(of: ".", with: "_").lowercased()
        let matches = names.filter { $0.replacingOccurrences(of: ".", with: "_").lowercased() == target }
        return matches.count == 1 ? matches[0] : spelling
    }

    static func wireSpelling(_ canonical: String, wireSafe: Bool) -> String {
        wireSafe ? canonical.replacingOccurrences(of: ".", with: "_") : canonical
    }

    static func list(arguments: Data, descriptors: [ToolCatalog.Descriptor], loaded: Set<String>, relatedSkills: [String: [String]] = [:], wireSafeNames: Bool = false) throws -> String {
        var args = try JSONDecoder().decode(ListArguments.self, from: arguments)
        if let cursor = args.afterName {
            let normalized = canonicalSpelling(cursor, among: descriptors)
            if normalized != cursor { args.afterName = normalized }
        }
        guard (1...100).contains(args.limit ?? 30) else {
            throw FloeError.validationFailed("Tool list limit must be 1–100")
        }
        let rows = descriptors.filter { args.group == nil || group($0.name) == args.group }
            .sorted { $0.name < $1.name }
        let remaining = rows.filter { args.afterName == nil || $0.name > args.afterName! }
        let page = Array(remaining.prefix(args.limit ?? 30))
        struct Entry: Encodable {
            let name: String
            let wireName: String?
            let description: String
            let group: String
            let schemaLoaded: Bool
            let ownerSkillID: String?
            let relatedSkillIDs: [String]
        }
        struct Response: Encodable {
            let tools: [Entry]
            let total: Int
            let nextAfterName: String?
        }
        let response = Response(tools: page.map {
            Entry(name: $0.name,
                  wireName: wireSafeNames ? wireSpelling($0.name, wireSafe: true) : nil,
                  description: String($0.toolDescription.prefix(240)),
                  group: group($0.name), schemaLoaded: loaded.contains($0.name),
                  ownerSkillID: $0.ownerSkillID, relatedSkillIDs: relatedSkills[$0.name, default: []])
        }, total: rows.count, nextAfterName: remaining.count > page.count ? page.last?.name : nil)
        return String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
    }
    static var descriptor: ToolCatalog.Descriptor {
        .init(name: name,
              toolDescription: "Load executable schemas by exact tool name or capability. Use skill.search/skill.read when workflow guidance is needed; exact tool calls do not require reading a guide. This search only loads definitions, never executes tools or grants permissions. Prefer an exact name when a group is too large.",
              parametersJSON: DiscoveryQueries.parametersJSON,
              riskLabels: [], isSideEffecting: false)
    }

    static func group(_ name: String) -> String { ToolCapabilityGroups.group(name) }

    static func matches(queries: [String], descriptors: [ToolCatalog.Descriptor]) -> [ToolCatalog.Descriptor] {
        var seen = Set<String>()
        return queries.flatMap { matches(query: $0, descriptors: descriptors) }.filter { seen.insert($0.name).inserted }
    }

    static func matches(query: String, descriptors: [ToolCatalog.Descriptor]) -> [ToolCatalog.Descriptor] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        let synonyms: [String: [String]] = [
            "vnc": ["vnc", "远程桌面", "鼠标", "remote desktop"],
            "executor": ["ssh", "executor", "执行命令", "运行命令"],
            "hosts": ["主机", "server", "连接配置"],
            "terminal": ["终端", "terminal", "交互", "telnet", "串口"],
            "python": ["python", "numpy", "pillow", "pandas", "scipy", "matplotlib", "数据分析"],
            "pdf": ["pdf"],
            "office": ["markdown", "rtf", "富文本", "格式转换", "互转", "office", "word", "excel", "powerpoint", "ppt", "幻灯片", "演示文稿", "表格", "工作簿", "文档"],
            "http": ["http", "接口", "api"],
            "network": ["network", "网络", "ping", "dns", "http", "端口", "traceroute"],
            "workspace": ["workspace", "文件", "编辑", "file", "html", "代码"],
            "canvas": ["canvas", "画布", "生成", "图片", "视频"],
            "memory": ["memory", "记忆", "remember"],
            "skill": ["skill", "技能"],
            "browser": ["browser", "浏览器", "网页", "website"],
            "web": ["web", "搜索", "search", "查找"],
            "git": ["git", "仓库", "commit", "repository"],
            "mail": ["mail", "邮件", "邮箱", "收信", "发信", "imap", "pop3", "smtp"]
        ]
        var groups = Set(synonyms.compactMap { group, terms in
            terms.contains(where: query.contains) ? group : nil
        })
        let tokens = query.split(whereSeparator: { $0.isWhitespace || "，,;；/".contains($0) }).map(String.init)
        let exact = descriptors.filter { descriptor in
            tokens.contains(descriptor.name.lowercased())
                || tokens.contains(where: { canonicalSpelling($0, among: descriptors).lowercased() == descriptor.name.lowercased() })
        }
        if !exact.isEmpty { return exact }
        for descriptor in descriptors {
            if tokens.contains(where: { descriptor.name.lowercased().contains($0) }) {
                groups.insert(group(descriptor.name))
            }
        }
        // A remote desktop chain needs its connection/configuration tools too.
        if groups.contains("vnc") { groups.formUnion(["executor", "hosts"]) }
        if groups.contains("executor") || groups.contains("terminal") { groups.insert("hosts") }
        if groups.isEmpty {
            // A word in one description does not justify loading every tool
            // in that namespace. Rank individual matches, deterministically.
            var ranked: [(descriptor: ToolCatalog.Descriptor, score: Int)] = []
            for descriptor in descriptors {
                let description = descriptor.toolDescription.lowercased()
                let score = tokens.filter { $0.count > 2 && description.contains($0) }.count
                if score > 0 { ranked.append((descriptor, score)) }
            }
            ranked.sort { $0.score == $1.score ? $0.descriptor.name < $1.descriptor.name : $0.score > $1.score }
            return ranked.prefix(8).map { $0.descriptor }
        }
        return descriptors.filter { groups.contains(group($0.name)) }
    }

    static func index(_ descriptors: [ToolCatalog.Descriptor]) -> String {
        let groups = Dictionary(grouping: descriptors, by: { group($0.name) })
        let names = Set(descriptors.map(\.name))
        var lines: [String] = []
        if names.isSuperset(of: ["task.readPlan", "task.updatePlan"]) {
            lines.append("At task start, judge whether the request requires substantial multi-step work. If so, use task.readPlan and task.updatePlan to maintain a durable checklist while executing; simple questions need none. Revise the same checklist when new evidence or user steering changes the work: preserve step IDs, update the revision, and retain completed evidence. A checklist never enables Goal mode.")
        }
        lines.append("Use tools.list to enumerate tool metadata available in this run; it does not load every schema. Use tools.search to load definitions by exact name or capability, batching independent queries. Available groups: "
            + (groups.isEmpty ? "none" : groups.keys.sorted().map { "\($0) (\(groups[$0]!.count))" }.joined(separator: ", "))
            + ". Deferred schemas are not missing capabilities; runtime permissions and prerequisites still apply.")
        if names.contains("skill.list") { lines.append("Use skill.list for the complete installed guide inventory.") }
        if names.isSuperset(of: ["skill.search", "skill.read"]) {
            lines.append("Guides provide optional workflow help via skill.search/skill.read. Known tool calls do not require a guide; reuse a guide already read at the current revision.")
        }
        if names.contains("exec.localPython") {
            lines.append("Local Python execution is exec.localPython; it is a different environment from SSH Executor or interactive Terminal.")
        }
        return lines.joined(separator: "\n")
    }

    /// Discovery is a presentation budget, never an authority grant.
    static func bounded(_ descriptors: [ToolCatalog.Descriptor], priority: [String], pinned: Set<String> = [], maxTools: Int = 23, maxBytes: Int = 23_000) -> [ToolCatalog.Descriptor] {
        let core: Set<String> = ["skill.search", "skill.read", "skill.list", "task.readPlan", "task.updatePlan"]
        let ranks = Dictionary(priority.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        let ordered = descriptors.sorted {
            let a = core.contains($0.name) || pinned.contains($0.name)
            let b = core.contains($1.name) || pinned.contains($1.name)
            if a != b { return a }
            let x = ranks[$0.name] ?? Int.max, y = ranks[$1.name] ?? Int.max
            return x == y ? $0.name < $1.name : x < y
        }
        var result: [ToolCatalog.Descriptor] = [], bytes = 0
        for descriptor in ordered {
            let size = descriptor.parametersJSON.utf8.count + descriptor.toolDescription.utf8.count
            let required = core.contains(descriptor.name) || pinned.contains(descriptor.name)
            guard required || (result.count < maxTools && bytes + size <= maxBytes) else { continue }
            result.append(descriptor); bytes += size
        }
        return result
    }
}
