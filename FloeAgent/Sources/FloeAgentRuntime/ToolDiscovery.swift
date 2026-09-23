import Foundation
import FloeTools
import FloeCore

/// Provider-independent deferred schemas. Search uses only executable tools
/// already inside this run's permission/skill ceiling.
enum ToolDiscovery {
    static let coreNames: Set<String> = ["skill.search", "skill.read", "skill.list", "checklist.readPlan", "checklist.updatePlan", "exec.shell"]
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

    /// Maps a model-spelled name to the canonical ceiling name via the shared
    /// spelling utility. Compat-mode providers see dots as underscores on the
    /// wire, so cursors and exact queries may arrive underscored.
    static func canonicalSpelling(_ spelling: String, among descriptors: [ToolCatalog.Descriptor]) -> String {
        ToolNameSpelling.canonical(spelling, among: descriptors.map(\.name)) ?? spelling
    }

    static func wireSpelling(_ canonical: String, wireSafe: Bool) -> String {
        ToolNameSpelling.wire(canonical, safe: wireSafe)
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
            let description: String
            let group: String
            let schemaLoaded: Bool
            let relatedSkillIDs: [String]
            let aliases: [String]
        }
        struct Response: Encodable {
            let tools: [Entry]
            let total: Int
            let nextAfterName: String?
        }
        let response = Response(tools: page.map {
            Entry(name: wireSafeNames ? wireSpelling($0.name, wireSafe: true) : $0.name,
                  description: String($0.toolDescription.prefix(240)),
                  group: group($0.name), schemaLoaded: loaded.contains($0.name),
                  relatedSkillIDs: relatedSkills[$0.name, default: []],
                  aliases: ToolAliasTable.aliases(of: $0.name))
        }, total: rows.count, nextAfterName: remaining.count > page.count
            ? page.last.map { wireSafeNames ? wireSpelling($0.name, wireSafe: true) : $0.name }
            : nil)
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
        // Native-first arbitration over the tools this run actually offers.
        // Media intent selects native media tools; it never expands into the
        // Linux interpreter unless the user asked for a script or no native
        // capability covers the task.
        let routing = ToolRoutingPolicy.decision(forTask: query, offeredToolNames: descriptors.map(\.name))
        let synonyms = ToolAliasTable.synonyms
        var groups = Set(synonyms.compactMap { group, terms in
            terms.contains(where: query.contains) ? group : nil
        })
        let tokens = query.split(whereSeparator: { $0.isWhitespace || "，,;；/".contains($0) }).map(String.init)
        let exact = descriptors.filter { descriptor in
            let aliases = ToolAliasTable.aliases(of: descriptor.name)
            return tokens.contains(descriptor.name.lowercased())
                || aliases.contains(where: { tokens.contains($0.lowercased()) })
                || tokens.contains(where: {
                    let canonical = ToolAliasTable.canonical($0)
                    return canonical.lowercased() == descriptor.name.lowercased()
                        || canonicalSpelling($0, among: descriptors).lowercased() == descriptor.name.lowercased()
                })
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
        // A matched native capability keeps the emulated interpreter out of the
        // automatic expansion; this suppresses only this expansion, so explicit
        // names, loaded schemas and tools.search by exact name are unchanged.
        // The gate is operation-aware: an offered native tool that does not
        // match the requested operation never triggers it.
        if routing.prefersNativeTools {
            groups.subtract(ToolRoutingPolicy.interpreterGroups(among: descriptors.map(\.name)))
        }
        if groups.isEmpty {
            // A word in one description does not justify loading every tool
            // in that namespace. Rank individual matches, deterministically.
            var ranked: [(descriptor: ToolCatalog.Descriptor, score: Int)] = []
            for descriptor in descriptors {
                let description = descriptor.toolDescription.lowercased()
                let score = tokens.filter { $0.count > 2 && description.contains($0) }.count
                if score > 0 { ranked.append((descriptor, score)) }
            }
            ranked.sort { left, right in
                // For a media task the native tools lead the ranked matches;
                // score and name keep the order deterministic.
                if routing.intent == .nativeMedia {
                    let leftNative = ToolRoutingPolicy.isNativeMediaTool(left.descriptor.name)
                    let rightNative = ToolRoutingPolicy.isNativeMediaTool(right.descriptor.name)
                    if leftNative != rightNative { return leftNative }
                }
                return left.score == right.score
                    ? left.descriptor.name < right.descriptor.name
                    : left.score > right.score
            }
            return capabilityGapFallback(ranked.prefix(8).map { $0.descriptor }, routing: routing, descriptors: descriptors)
        }
        let selected = descriptors.filter { groups.contains(group($0.name)) }
        guard routing.prefersNativeTools else {
            return capabilityGapFallback(selected, routing: routing, descriptors: descriptors)
        }
        // Native media tools lead the curated set for a media task; other
        // matched groups (office, workspace, http, …) stay available.
        return selected.filter { ToolRoutingPolicy.isNativeMediaTool($0.name) }
            + selected.filter { !ToolRoutingPolicy.isNativeMediaTool($0.name) }
    }

    /// Primary guest entry points, used only for a media task no offered native
    /// tool matches. The fallback is appended after any native candidates, is
    /// derived strictly from the offered descriptors, and never invents a
    /// disabled tool. When a native capability does match the operation this
    /// returns `base` unchanged: the guest is then not part of the automatic
    /// expansion at all.
    private static func capabilityGapFallback(
        _ base: [ToolCatalog.Descriptor],
        routing: ToolRoutingPolicy.Decision,
        descriptors: [ToolCatalog.Descriptor]
    ) -> [ToolCatalog.Descriptor] {
        guard routing.intent == .nativeMedia, !routing.prefersNativeTools else { return base }
        let fallbackNames: Set<String> = ["exec.shell", "shell.open", "exec.localPython", "exec.localService"]
        let existing = Set(base.map(\.name))
        let fallback = descriptors.filter { fallbackNames.contains($0.name) && !existing.contains($0.name) }
        return base + fallback
    }

    static func index(_ descriptors: [ToolCatalog.Descriptor], wireSafeNames: Bool = false) -> String {
        let groups = Dictionary(grouping: descriptors, by: { group($0.name) })
        let names = Set(descriptors.map(\.name))
        func n(_ name: String) -> String { wireSpelling(name, wireSafe: wireSafeNames) }
        var lines: [String] = []
        if names.isSuperset(of: ["checklist.readPlan", "checklist.updatePlan"]) {
            lines.append("At task start, judge whether the request requires substantial multi-step work. If so, use \(n("checklist.readPlan")) and \(n("checklist.updatePlan")) to maintain a durable checklist while executing; simple questions need none. Revise the same checklist when new evidence or user steering changes the work: preserve step IDs, update the revision, and retain completed evidence. A checklist never enables Goal mode.")
        }
        lines.append("Use \(n("tools.list")) to enumerate tool metadata available in this run; it does not load every schema. Use \(n("tools.search")) to load definitions by exact name or capability, batching independent queries. Available groups: "
            + (groups.isEmpty ? "none" : groups.keys.sorted().map { "\($0) (\(groups[$0]!.count))" }.joined(separator: ", "))
            + ". Deferred schemas are not missing capabilities; runtime permissions and prerequisites still apply.")
        if names.contains("skill.list") { lines.append("Use \(n("skill.list")) for the complete installed guide inventory.") }
        if names.isSuperset(of: ["skill.search", "skill.read"]) {
            lines.append("Guides provide optional workflow help via \(n("skill.search"))/\(n("skill.read")). Known tool calls do not require a guide; reuse a guide already read at the current revision.")
        }
        if names.contains("network.http") {
            lines.append("For web tasks, prefer direct HTTP when sufficient: use \(n("network.http")) for raw HTML, documented or observed API endpoints, JSON, forms and pagination. Do not invent endpoints or claim a successful action without checking its HTTP result. \(n("web.fetch")) extracts readable content; use raw HTTP to inspect links, forms or script references that extraction omits. For multi-request state, parsing or batch work, use authorized shell curl/Python/Node with session files scoped to the current workspace. Use the browser when JavaScript rendering, browser login or a user interaction is actually required; do not bypass access controls or a challenge. A short response alone is not a reason to launch the browser.")
        }
        if names.contains("browser.panel") {
            lines.append("Browser tools and local previews do not open the user interface. Only when a concrete interaction needs the user's help, use \(n("browser.panel")) action=requestUser with a clear reason. Routine navigation and progress reporting should remain in the background.")
        }
        if names.contains("exec.shell") {
            lines.append("\(n("exec.shell")) is the general local execution entry point, with its schema kept available when authorized. Use POSIX shell commands and scripts for file/text processing, loops, pipelines and combining Python or Node operations in the current workspace. Choose shell when it expresses the task naturally; there is no requirement to split a command workflow into many specialized tools. Inspect available commands with command -v before relying on an unfamiliar utility. \(n("shell.open"))/\(n("shell.exchange")) provide persistent sessions when available. Shell calls retain the same permissions and result checks as other tools.")
        }
        if names.contains("exec.localPython") {
            lines.append("Local Python execution is \(n("exec.localPython")); it is a different environment from SSH Executor or interactive Terminal.")
        }
        // Native-first routing guidance is emitted only for capabilities this
        // run actually offers. It never names a disabled or unconfigured tool.
        let descriptorNames = descriptors.map(\.name)
        let nativeMediaNames = descriptorNames.filter(ToolRoutingPolicy.isNativeMediaTool).sorted()
        let interpreterNames = descriptorNames
            .filter { ToolRoutingPolicy.isInterpreterTool($0) && $0 != "environment.prepareLinux" }
            .sorted()
        if !nativeMediaNames.isEmpty {
            let examples = nativeMediaNames.prefix(6).map(n).joined(separator: ", ")
            // Name only the interpreter entries that are actually offered.
            let explicitInterpreters = ["exec.shell", "shell.open", "exec.localPython"]
                .filter { names.contains($0) }
                .map(n)
            let interpreterMentions = explicitInterpreters.isEmpty
                ? interpreterNames.prefix(2).map(n)
                : explicitInterpreters
            let avoid = interpreterMentions.isEmpty
                ? "a general-purpose script"
                : interpreterMentions.joined(separator: " or ")
            var line = "Native-first routing: \(examples) are app-native tools. They run on-device through Apple frameworks or through the app's configured model route — never through the emulated guest — and the guest has no GPU passthrough. Prefer them over re-implementing the operation with \(avoid); a video/image/audio/PDF task is not owned by the Linux interpreter just because it is installed. Use the guest interpreter for media only when no offered native tool covers the requested operation or the user explicitly asked for a script or command-line tool."
            if names.contains("media.capabilities") {
                line += " Before promising a media operation, read \(n("media.capabilities")) to confirm the offered tool's operation is actually configured: a native tool name alone does not prove the requested operation is available."
            }
            lines.append(line)
        } else if !interpreterNames.isEmpty {
            let offered = interpreterNames.prefix(3).map(n).joined(separator: ", ")
            lines.append("Media rule: no native image/video/audio/PDF/OCR tool is offered, so media work uses the guest interpreter (\(offered)) only within its real capability and must be reported as not configured when the user expects a native one.")
        }
        if names.contains("video.generate") {
            lines.append("Video generation can use any configured cloud video route: call \(n("video.models")) first to read the public candidate names (`model`/`modelName`) and their parameter limits, choose the candidate that fits the request yourself, then pass its public `model` value to \(n("video.generate")). Never ask the user for an internal UUID, and never resubmit a running job.")
        }
        if names.contains("image.generate") {
            lines.append("Image generation can use any configured image route: call \(n("image.models")) first to read the public candidate names (`model`/`modelName`) and their parameter limits, choose the candidate that fits the request yourself, then pass its public `model` value to \(n("image.generate")). `model` and `modelID` are a mutually exclusive one-of; never ask the user for an internal UUID, and never resubmit a running or outcome-unknown generation.")
        }
        return lines.joined(separator: "\n")
    }

    /// Discovery is a presentation budget, never an authority grant.
    static func bounded(_ descriptors: [ToolCatalog.Descriptor], priority: [String], pinned: Set<String> = [], maxTools: Int = 23, maxBytes: Int = 23_000) -> [ToolCatalog.Descriptor] {
        let core = coreNames
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
