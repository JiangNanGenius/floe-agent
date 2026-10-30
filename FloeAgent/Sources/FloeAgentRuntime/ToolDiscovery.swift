import Foundation
import FloeTools
import FloeCore

/// Provider-independent deferred schemas. Search uses only executable tools
/// already inside this run's permission/skill ceiling.
enum ToolDiscovery {
    static let coreNames: Set<String> = ["skill.search", "skill.read", "skill.list", "checklist.readPlan", "checklist.updatePlan", "exec.shell", "user.ask"]
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
        let descriptors = descriptors.filter { !RetiredExecutionTools.contains($0.name) }
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

    /// Runtime-owned metadata helpers are separate from executable tools.
    /// Conversation schemas must not direct the model to skill/task tools
    /// outside its ceiling. The dispatcher still searches only its filtered,
    /// live catalog; this wording never changes admission or execution policy.
    /// Ordinary runs (including ordinary fast chat, which now offers the same
    /// authorized toolchain as a task) keep the standard wording; a temporary
    /// conversation honestly scopes the directory to its read ceiling.
    static func runtimeDescriptors(publicWebOnly: Bool) -> [ToolCatalog.Descriptor] {
        // Captured-result paging is runtime metadata over this task's own
        // captures (post-redaction), never a new authority: it stays offered
        // in a temporary conversation too, where retention is RAM-only.
        guard publicWebOnly else {
            return [descriptor, listDescriptor, ToolResultPagingTool.descriptor]
        }
        let scope = "this temporary conversation's allowed public web tools and basic on-device reads (calendar events, reminders, maps place search, Home accessories, Watch status and the current location)"
        var search = descriptor
        search.toolDescription = "Find definitions for currently available tools within \(scope). Search by exact tool name or capability. This runtime metadata helper only loads permitted schemas; it never executes tools, grants permission or enables an unavailable provider. A forbidden name or capability cannot be unlocked by searching."
        var list = listDescriptor
        list.toolDescription = "List metadata for currently available tools within \(scope). This runtime metadata helper does not execute tools or grant permission. Use tools.search to load a permitted definition; schemaLoaded=false means deferred, not denied. Follow nextAfterName until absent."
        return [search, list, ToolResultPagingTool.descriptor]
    }

    static func group(_ name: String) -> String { ToolCapabilityGroups.group(name) }

    static func matches(queries: [String], descriptors: [ToolCatalog.Descriptor]) -> [ToolCatalog.Descriptor] {
        var seen = Set<String>()
        return queries.flatMap { matches(query: $0, descriptors: descriptors) }.filter { seen.insert($0.name).inserted }
    }

    static func matches(query: String, descriptors: [ToolCatalog.Descriptor]) -> [ToolCatalog.Descriptor] {
        let descriptors = descriptors.filter { !RetiredExecutionTools.contains($0.name) }
        guard !RetiredExecutionTools.contains(query.trimmingCharacters(in: .whitespacesAndNewlines)) else { return [] }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        // Capability discovery is truthful metadata, not route enforcement:
        // the query matches offered definitions by name/alias/group/description
        // and every matched definition stays discoverable. The runtime never
        // suppresses the interpreter because a native tool exists, and never
        // reorders results by a preferred backend; the model chooses from the
        // offered capabilities.
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
        // Guest topology is controlled by the host-side environment tools,
        // not by commands inside the guest. A query such as "Linux 虚拟机多核"
        // also matches the generic shell synonym, so put the three relevant
        // lifecycle schemas in front before the first shell call auto-boots
        // the saved shape (or new-environment default). Only offer tools in this run's ceiling.
        let guestTerms = ["linux", "guest", "tinyemu", "virtual machine", "虚拟机"]
        let shapeTerms = ["多核", "双核", "多线程", "核心", "cpu", "vcpu", "smp", "multi-core", "multicore", "cores"]
        let parallelTerms = ["multiprocessing", "worker_threads", "parallel compilation", "parallel build", "并行编译", "多进程", "并行计算"]
        if (guestTerms.contains(where: query.contains) && shapeTerms.contains(where: query.contains))
            || parallelTerms.contains(where: query.contains) {
            let lifecycleNames = ["environment.linuxStatus", "environment.startLinux", "environment.hardRestartLinux"]
            let lifecycle = lifecycleNames.compactMap { name in descriptors.first { $0.name == name } }
            let shell = descriptors.filter { $0.name == "exec.shell" }
            return lifecycle + shell
        }
        if ["port", "forward", FloeL10n.l("runtime.tool_discovery.port"), FloeL10n.l("runtime.tool_discovery.forward")].contains(where: query.contains),
           let ports = descriptors.first(where: { $0.name == "linux.port" }) {
            return [ports] + descriptors.filter { $0.name == "environment.linuxStatus" || $0.name == "exec.localService" }
        }
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
            ranked.sort { left, right in
                // Score and name keep the order deterministic; backend is not
                // a ranking criterion.
                left.score == right.score
                    ? left.descriptor.name < right.descriptor.name
                    : left.score > right.score
            }
            return ranked.prefix(8).map { $0.descriptor }
        }
        return descriptors.filter { groups.contains(group($0.name)) }
    }

    /// Tools whose canonical name (or a known alias) is an EXACT token of one
    /// query. An exact-name search must give the model the complete callable
    /// schema, not a 160-character teaser: the model may then call the tool
    /// immediately, and the schema is also loaded for the next request.
    static func exactNameMatches(_ queries: [String], descriptors: [ToolCatalog.Descriptor]) -> [ToolCatalog.Descriptor] {
        let descriptors = descriptors.filter { !RetiredExecutionTools.contains($0.name) }
        var result: [ToolCatalog.Descriptor] = []
        var seen = Set<String>()
        for query in queries {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { continue }
            let tokens = trimmed
                .split(whereSeparator: { $0.isWhitespace || "，,;；/".contains($0) })
                .map(String.init)
            for descriptor in descriptors where !seen.contains(descriptor.name) {
                let aliases = ToolAliasTable.aliases(of: descriptor.name)
                let exact = tokens.contains(descriptor.name.lowercased())
                    || aliases.contains(where: { tokens.contains($0.lowercased()) })
                    || tokens.contains(where: { token in
                        let canonical = ToolAliasTable.canonical(token)
                        return canonical.lowercased() == descriptor.name.lowercased()
                            || canonicalSpelling(token, among: descriptors).lowercased() == descriptor.name.lowercased()
                    })
                if exact {
                    seen.insert(descriptor.name)
                    result.append(descriptor)
                }
            }
        }
        return result
    }

    /// Complete callable schema text for exact-name matches. Bounded per tool
    /// and in total; an oversized definition says so instead of being
    /// silently cut into an invalid schema.
    static func exactSchemaSection(
        _ descriptors: [ToolCatalog.Descriptor],
        wireSafeNames: Bool,
        perToolBytes: Int = 24 * 1024,
        totalBytes: Int = 48 * 1024
    ) -> String {
        guard !descriptors.isEmpty else { return "" }
        var sections: [String] = []
        var used = 0
        for descriptor in descriptors {
            let name = wireSpelling(descriptor.name, wireSafe: wireSafeNames)
            let section = "Complete schema for \(name) (callable now; also loaded for later requests):\n"
                + descriptor.toolDescription + "\nparametersJSON: " + descriptor.parametersJSON
            // A JSON Schema cut to fit is not a smaller schema: required
            // fields, nested objects and enums can be lost and the model then
            // emits arguments the executor must reject. Report an oversized
            // definition instead of slicing it; the provider request carries
            // the complete definition once the name is activated.
            if section.utf8.count > perToolBytes {
                sections.append("The complete schema for \(name) is \(section.utf8.count) bytes, above this result's per-tool display envelope (\(perToolBytes) bytes). It was not sliced. It is loaded as a complete provider schema when offered; call it with its documented arguments and the runtime will validate them.")
                continue
            }
            if used + section.utf8.count > totalBytes {
                sections.append("More exact schemas were requested than this result can carry; search the remaining names one at a time. No schema below was cut.")
                break
            }
            used += section.utf8.count
            sections.append(section)
        }
        return sections.joined(separator: "\n\n")
    }

    static func index(_ descriptors: [ToolCatalog.Descriptor], wireSafeNames: Bool = false) -> String {
        let descriptors = descriptors.filter { !RetiredExecutionTools.contains($0.name) }
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
        if names.contains("cad.document") {
            lines.append("Use \(n("cad.document")) for 2D DWG/DXF and native .floecad work. read/query/locate/measure/check are read-only; propose binds the exact revision and SHA and returns a new/changed/deleted preview without changing the original; apply commits ONE atomic undoable transaction for that exact proposal — with a grant_id the user issued in the CAD UI, or WITHOUT one under the runtime-approved call authority for that exact call — after the proposal's revision/SHA is re-verified against the live document. Never claim a drawing or model edit was applied or saved without an apply/save receipt, and never invent a grant id. For an already authorized editing task, continue from propose to apply without grant_id, then read/save/export and verify the real result. Wait for adoption only when the user asked to review first or the runtime requires approval. Native workbench services (drawing/assembly/script/mesh) need one named operation: payload.action or the legacy payload.op \"<kind>.<action>\" (for example \"drawing.addPage\"); an action-less payload is refused, never defaulted. Mutating ones run via propose then apply; drawing PDF/SVG/DXF export also needs page_id from query kind=drawings. Call capabilities with kind=drawing|assembly|script|mesh for exact arguments and examples.")
        }
        if names.contains("task.schedule") {
            lines.append("Scheduled tasks use \(n("task.schedule")) (list/create/update/enable/disable/delete/runNow/history). The model, project, environment and permission binding are frozen from THIS task at creation and revalidated when the task runs; the tool never grants permissions and never widens this task's ceiling. `interval` is an absolute duration, `afterSuccess` is bound to one concrete upstream run and fires at most once after it succeeds, and daily/weekly times stay anchored to the device calendar timezone (missed times coalesce to the most recent one). A due task may run late or be reported as pending — never claim it ran without the real run/occurrence state.")
        }
        if names.contains(ToolResultPagingTool.name) {
            lines.append("After context compaction hides part of an earlier tool output, use \(n(ToolResultPagingTool.name)) to page the captured result by call id (omit callID to list this task's retained results). It never re-runs the tool and states honestly when nothing was retained.")
        }
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

        // Native-first routing guidance is emitted only for capabilities this
        // run actually offers. It never names a disabled or unconfigured tool.
        let descriptorNames = descriptors.map(\.name)
        let nativeMediaNames = descriptorNames.filter(ToolRoutingPolicy.isNativeMediaTool).sorted()
        let interpreterNames = descriptorNames
            .filter {
                ToolRoutingPolicy.isInterpreterTool($0) && !$0.hasPrefix("environment.")
            }
            .sorted()
        if !nativeMediaNames.isEmpty {
            let examples = nativeMediaNames.prefix(6).map(n).joined(separator: ", ")
            let interpreterMentions = ["exec.shell", "shell.open"]
                .filter { names.contains($0) }
                .map(n)
            var line = "Offered native media capabilities: \(examples). They run on-device through Apple frameworks or through the app's configured model route, not through the emulated guest; a Linux guest has no GPU passthrough. The choice of route belongs to the task and the model: offer these capabilities, state their real limits, and let the model choose. "
            if interpreterMentions.isEmpty {
                line += "No general interpreter is offered on this turn."
            } else {
                line += "The selected execution environment (\(interpreterMentions.joined(separator: ", "))) is also available within its real permissions and capabilities."
            }
            if names.contains("media.capabilities") {
                line += " Before promising a media operation, read \(n("media.capabilities")) to confirm the offered tool's operation is actually configured: a native tool name alone does not prove the requested operation is available."
            }
            lines.append(line)
        } else if !interpreterNames.isEmpty {
            let offered = interpreterNames.prefix(3).map(n).joined(separator: ", ")
            lines.append("No native image/video/audio/PDF/OCR tool is offered on this turn. Available execution entries: \(offered). Report a media capability as not configured when the user expects a native one; do not invent it.")
        }
        if names.contains("audio.synthesize") {
            lines.append("For file transcription or generated speech, use the configured audio tools. Call \(n("audio.services")) to read available local/cloud services and the assistant-only preference; never guess an unavailable service or change the ordinary read-aloud voice. Return the generated audio artifact or file receipt in the final response so the user can play or save it.")
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
        let descriptors = descriptors.filter { !RetiredExecutionTools.contains($0.name) }
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
