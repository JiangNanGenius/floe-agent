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

    static func group(_ name: String) -> String { String(name.split(separator: ".").first ?? "other") }

    static func matches(query: String, descriptors: [ToolCatalog.Descriptor]) -> [ToolCatalog.Descriptor] {
        let query = query.lowercased()
        let synonyms: [String: [String]] = [
            "vnc": ["vnc", "远程桌面", "鼠标", "remote desktop"],
            "ssh": ["ssh", "主机", "终端", "server", "terminal"],
            "network": ["network", "网络", "ping", "dns", "http", "端口", "traceroute"],
            "workspace": ["workspace", "文件", "编辑", "file", "python", "html", "代码"],
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
        for descriptor in descriptors {
            if tokens.contains(where: { descriptor.name.lowercased().contains($0) }) {
                groups.insert(group(descriptor.name))
            }
        }
        // A remote desktop chain needs its connection/configuration tools too.
        if groups.contains("vnc") { groups.insert("ssh") }
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
}
