import Foundation
import FloeTools

/// Provider-independent deferred schemas. Search uses only executable tools
/// already inside this run's permission/skill ceiling.
enum ToolDiscovery {
    static let name = "tools.search"
    static var descriptor: ToolCatalog.Descriptor {
        .init(name: name,
              toolDescription: "Load executable schemas by exact tool name or capability. Use skill.search/skill.read when workflow guidance is needed; exact tool calls do not require reading a guide. This search only loads definitions, never executes tools or grants permissions. Prefer an exact name when a group is too large.",
              parametersJSON: #"{"type":"object","properties":{"query":{"type":"string","minLength":1}},"required":["query"],"additionalProperties":false}"#,
              riskLabels: [], isSideEffecting: false)
    }

    static func group(_ name: String) -> String { ToolCapabilityGroups.group(name) }

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
        let exact = descriptors.filter { tokens.contains($0.name.lowercased()) }
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
        return "Tool discovery: full schemas are loaded only for relevant groups. Installed groups: "
            + groups.keys.sorted().map { "\($0) (\(groups[$0]!.count))" }.joined(separator: ", ")
            + ". These groups are installed; schemas load on first relevant tools.search, and deferred does not mean unavailable. Guides are optional workflow help via skill.search/skill.read; exact callable schemas use tools.search. Python execution is exec.localPython (python group), SSH Executor and interactive Terminal are separate. Connection state does not remove installed capabilities. Memory housekeeping is not a prerequisite; continue the actual task after any relevant memory check."
    }

    /// Discovery is a presentation budget, never an authority grant.
    static func bounded(_ descriptors: [ToolCatalog.Descriptor], priority: [String], pinned: Set<String> = [], maxTools: Int = 23, maxBytes: Int = 23_000) -> [ToolCatalog.Descriptor] {
        let core: Set<String> = ["skill.search", "skill.read"]
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
