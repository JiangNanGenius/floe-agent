import Foundation
import FloeTools

/// Provider-independent deferred schemas. Search uses only executable tools
/// already inside this run's permission/skill ceiling.
enum ToolDiscovery {
    static let name = "tools.search"
    static var descriptor: ToolCatalog.Descriptor {
        .init(name: name,
              toolDescription: "Discover installed tool groups by task, group or exact name. Matching tools become callable with their full parameter schemas on the next model request. Search before claiming a capability is missing. This only loads definitions; it does not run tools or grant permissions.",
              parametersJSON: #"{"type":"object","properties":{"query":{"type":"string","minLength":1}},"required":["query"],"additionalProperties":false}"#,
              riskLabels: [], isSideEffecting: false)
    }

    static func group(_ name: String) -> String { ToolCapabilityGroups.group(name) }

    static func matches(query: String, descriptors: [ToolCatalog.Descriptor]) -> [ToolCatalog.Descriptor] {
        let query = query.lowercased()
        let synonyms: [String: [String]] = [
            "vnc": ["vnc", "远程桌面", "鼠标", "remote desktop"],
            "executor": ["ssh", "executor", "执行命令", "运行命令"],
            "hosts": ["主机", "server", "连接配置"],
            "terminal": ["终端", "terminal", "交互", "telnet", "串口"],
            "python": ["python", "numpy", "pillow"],
            "pdf": ["pdf"],
            "office": ["office", "word", "excel", "表格", "工作簿", "文档"],
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
        let tokens = query.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
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
            let ranked = descriptors.filter { descriptor in
                tokens.contains { $0.count > 2 && descriptor.toolDescription.lowercased().contains($0) }
            }.prefix(8)
            groups.formUnion(ranked.map { group($0.name) })
        }
        return descriptors.filter { groups.contains(group($0.name)) }
    }

    static func index(_ descriptors: [ToolCatalog.Descriptor]) -> String {
        let groups = Dictionary(grouping: descriptors, by: { group($0.name) })
        return "Tool discovery: full schemas are loaded only for relevant groups. Installed groups: "
            + groups.keys.sorted().map { "\($0) (\(groups[$0]!.count))" }.joined(separator: ", ")
            + ". Use tools.search to load another group. Connection state does not remove installed capabilities. Load the user's requested route first. Memory housekeeping is not a prerequisite for using tools; continue the actual task after any relevant memory check."
    }

    /// Discovery is a presentation budget, never an authority grant.
    static func bounded(_ descriptors: [ToolCatalog.Descriptor], priority: [String], pinned: Set<String> = [], maxTools: Int = 23, maxBytes: Int = 23_000) -> [ToolCatalog.Descriptor] {
        let core: Set<String> = ["skill.read"]
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
