import Foundation
import FloeTools

/// Turn-bound native-capability discovery and guidance.
///
/// The stable catalog policy lives in `NativeAuthoringGuidance` (emitted once
/// per directory). This type binds the CURRENT work to the catalog this run
/// actually offers, because a continued conversation may carry discovery
/// state written before a newer app version installed new capabilities: the
/// first-turn guess runs only while `discoveredToolNames` is empty
/// (`AgentRuntime.runModelTurn`), so on both old-task paths — a new message
/// in the old task and a checkpoint Continue — newly offered schemas would
/// stay out of the candidate set while the history keeps its scripting
/// pattern.
///
/// The real trigger is often NOT the current message: a broad user request
/// ("写个网页版三国志9") is decomposed by the agent into an asset substep
/// (background music), and the next user message may only be "继续". Matching
/// therefore runs over a BOUNDED, REAL task context — the current user
/// message, the run's original user goal and the CURRENT run's own checklist
/// step titles — never assistant prose or tool output, so a prior scripting
/// route is never inherited and no authority is widened. Suppression by an
/// explicit code route is evaluated against the CURRENT user message only,
/// because only a user message is a real user route: "write a web game" does
/// not mean "synthesize the media with code".
///
/// Refresh is catalog-driven, not whitelist-driven: every capability the real
/// `ToolDiscovery` matcher returns inside this run's ceiling is eligible, and
/// only the GENERAL execution entries (Linux-guest interpreters by routing
/// metadata) plus runtime-virtual helpers and retired aliases are excluded.
/// A newly installed module (music, charts, PDF, GitHub reading, workspace
/// editing, LaTeX…) therefore participates without a per-release edit here.
///
/// Presentation only: every returned descriptor comes from the live,
/// ceiling-filtered descriptors the caller passes; results are additive,
/// capped and idempotent (an unchanged context cannot churn the provider
/// prefix cache); authority, approval, revision/CAS and output validation are
/// unchanged — a loaded schema grants nothing and a denied call stays denied.
enum NativeAuthoringRouting {
    /// Music-creation wording. ASCII terms match on word boundaries; CJK
    /// terms match as substrings (same rule as `ToolRoutingPolicy.mediaTerms`).
    static let musicTerms: [String] = [
        "music", "song", "soundtrack", "bgm", "melody", "remix",
        "音乐", "歌曲", "配乐", "背景音乐", "伴奏", "作曲", "编曲", "混音", "单曲"
    ]

    /// Runtime-virtual helpers that carry no capability semantics; refreshing
    /// them as "new capabilities" would be noise.
    private static let helperNames: Set<String> = [
        ToolDiscovery.name, ToolDiscovery.listName, ToolResultPagingTool.name,
        "delegate", "delegate.peers", "delegate.message"
    ]

    /// The shared eligibility predicate for schema refresh and guidance. Uses
    /// the existing execution-routing metadata (never a name whitelist) so
    /// generic interpreters and retired aliases stay out while every real
    /// specialized capability the matcher returned is eligible.
    static func isRefreshableCapability(_ name: String) -> Bool {
        !ToolRoutingPolicy.isInterpreterTool(name)
            && !RetiredExecutionTools.contains(name)
            && !helperNames.contains(name)
            && !ToolDiscovery.coreNames.contains(name)
    }

    /// Preferred admission order for refreshed schemas: shared inspection
    /// readers first, then the live music chain when the context asks for
    /// music, then names alphabetically. Deterministic; never backend-ranked.
    private static func rank(_ name: String, musicContext: Bool) -> Int {
        if let inspection = NativeAuthoringGuidance.inspectionOrder.firstIndex(of: name) {
            return inspection
        }
        if musicContext {
            let chain = ["studio.create", "studio.list", "studio.read", "studio.edit", "studio.run",
                         "studio.media", "studio.library", "studio.media.provider"]
            if let index = chain.firstIndex(of: name) { return 100 + index }
        }
        return 1_000
    }

    private struct Ranked {
        let descriptor: ToolCatalog.Descriptor
        let rank: Int
        let name: String
    }

    /// Descriptors reached by a capability SYNONYM term present in the query
    /// (group level) or by a whole token equal to the exact name, a rename
    /// alias, or one of the name's dot components ("github" → github.readLink).
    private struct StrongSignals {
        let groups: Set<String>
        let names: Set<String>

        func qualifies(_ descriptor: ToolCatalog.Descriptor) -> Bool {
            groups.contains(ToolDiscovery.group(descriptor.name)) || names.contains(descriptor.name.lowercased())
        }
    }

    private static func strongSignals(query: String, descriptors: [ToolCatalog.Descriptor]) -> StrongSignals {
        let lowered = query.lowercased()
        var groups = Set<String>()
        for (group, terms) in ToolAliasTable.synonyms {
            if terms.contains(where: { lowered.contains($0) }) { groups.insert(group) }
        }
        var names = Set<String>()
        let tokens = lowered.split(whereSeparator: { $0.isWhitespace || "，,;；/".contains($0) }).map(String.init)
        let offered = descriptors.map(\.name)
        for token in tokens where token.count > 2 {
            for name in offered where name.lowercased() == token
                || ToolAliasTable.aliases(of: name).contains(where: { $0.lowercased() == token })
                || ToolAliasTable.canonical(token).lowercased() == name.lowercased()
                || name.lowercased().split(separator: ".").contains(where: { $0 == Substring(token) }) {
                names.insert(name.lowercased())
            }
        }
        return StrongSignals(groups: groups, names: names)
    }

    static func isMusicRequest(_ text: String) -> Bool {
        containsAny(musicTerms, in: text.lowercased())
    }

    /// The BOUNDED real task context used for capability matching: current
    /// user message + the run's original user goal + the current run's own
    /// checklist step titles. Every input is capped; nothing from assistant
    /// messages, tool outputs or older runs is read here.
    static func boundedTaskContext(
        currentUserTask: String,
        originalGoal: String?,
        planStepTitles: [String]
    ) -> String {
        var pieces: [String] = []
        let current = currentUserTask.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty { pieces.append(String(current.prefix(2_000))) }
        if let originalGoal {
            let goal = originalGoal.trimmingCharacters(in: .whitespacesAndNewlines)
            // The original goal IS the current message on turn one; no dupes.
            if !goal.isEmpty, goal != current { pieces.append(String(goal.prefix(1_200))) }
        }
        let steps = planStepTitles.prefix(24).map { String($0.prefix(160)) }
        if !steps.isEmpty { pieces.append(steps.joined(separator: "\n")) }
        return pieces.joined(separator: "\n")
    }

    /// Schemas the bounded context matches among the LIVE offered descriptors
    /// that this run has not discovered yet. Additive, capped, idempotent and
    /// catalog-driven. Suppressed when the CURRENT user message itself
    /// explicitly asks for a script/code route (the user's chosen path for
    /// this turn; capabilities stay discoverable as before).
    static func taskBoundAdditions(
        userTask: String,
        taskContext: String = "",
        liveDescriptors: [ToolCatalog.Descriptor],
        discoveredNames: Set<String>
    ) -> [ToolCatalog.Descriptor] {
        let current = userTask.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = taskContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = context.isEmpty ? current : context
        guard !effective.isEmpty else { return [] }
        guard !ToolRoutingPolicy.requestsScript(current) else { return [] }
        let matched = ToolDiscovery.matches(query: effective, descriptors: liveDescriptors)
        let strong = strongSignals(query: effective, descriptors: liveDescriptors)
        var pending: [ToolCatalog.Descriptor] = []
        for descriptor in matched where isRefreshableCapability(descriptor.name) {
            // Strong-signal gate: the descriptor must be reached by a real
            // capability synonym group or by a whole token that equals its
            // name/alias/name component. `ToolDiscovery.matches` also expands
            // groups from bare name SUBSTRINGS ("write" inside a synthetic
            // "test.discoverwrite"); carrying that looseness into every-turn
            // refresh would churn schemas on incidental words. Exact and
            // synonym hits still refresh fully.
            guard strong.qualifies(descriptor) else { continue }
            if !discoveredNames.contains(descriptor.name) { pending.append(descriptor) }
        }
        guard !pending.isEmpty else { return [] }
        let music = isMusicRequest(effective)
        var ranked: [Ranked] = []
        for descriptor in pending {
            ranked.append(Ranked(
                descriptor: descriptor,
                rank: rank(descriptor.name, musicContext: music),
                name: descriptor.name
            ))
        }
        ranked.sort { left, right in
            left.rank == right.rank ? left.name < right.name : left.rank < right.rank
        }
        var result: [ToolCatalog.Descriptor] = []
        for item in ranked where result.count < 12 {
            result.append(item.descriptor)
        }
        return result
    }

    /// The exact union the runtime applies. Existing discovery names and
    /// priority entries are preserved; additions lead the priority (like a
    /// `tools.search` activation) so a tight schema window admits the fresh
    /// capabilities before older optional entries.
    static func mergedDiscoveryState(
        userTask: String,
        taskContext: String = "",
        liveDescriptors: [ToolCatalog.Descriptor],
        discoveredNames: Set<String>,
        currentPriority: [String]
    ) -> (names: Set<String>, priority: [String]) {
        let additions = taskBoundAdditions(
            userTask: userTask, taskContext: taskContext,
            liveDescriptors: liveDescriptors, discoveredNames: discoveredNames)
        guard !additions.isEmpty else { return (discoveredNames, currentPriority) }
        let additionNames = additions.map(\.name)
        let seen = Set(additionNames)
        var names = discoveredNames
        names.formUnion(additionNames)
        return (names, additionNames + currentPriority.filter { !seen.contains($0) })
    }

    /// Always-on (catalog-gated) substep asset rule. It fires on EVERY run
    /// that offers at least one specialized capability regardless of the
    /// current message, because the real music/asset trigger is usually a
    /// later agent-decomposed substep behind a bare "继续". Grants no
    /// authority and names no unoffered capability.
    static func persistentLines(
        descriptors: [ToolCatalog.Descriptor],
        displayName: (String) -> String = { $0 }
    ) -> [String] {
        let capabilities = descriptors.filter { isRefreshableCapability($0.name) }
        guard !capabilities.isEmpty else { return [] }
        let hasStudio = Set(capabilities.map(\.name)).contains("studio.list")
        var line = "Substep capability rule / 子步骤能力规则：你自己分解出的工作项同样属于本任务；制作或编辑媒体/文档/图表/3D/数据/文件/链接读取等资产前，先查看本轮已提供、已配置且支持该目标的专用能力并优先尝试原生路径（schema 被本窗口延后时用 \(displayName("tools.search")) 按精确名加载——延后不等于不可用；产物以真实回执验证）。普通的编程/网页/脚本项目请求不等于用户指定用代码合成该媒体。仅当用户当前消息明确要求用代码或指定路线制作/编辑该媒体时才遵从用户路线；专用能力未配置、明确不支持或调用真实失败并读回后，才使用既有执行；拒绝不能绕行，未决任务按现有生命周期等待，本行不授予任何权限。The substeps you decompose yourself belong to this task: before producing or editing media/documents/charts/3D/data/file/link assets by generated code, check whether an offered configured specialized capability supports the target and try it first (load a deferred exact schema with \(displayName("tools.search")) — deferred is not missing; verify artifacts by real receipts). A general coding/web-project request is not the user specifying code-based media synthesis. Follow the user route only when the user's CURRENT message explicitly chose code or a named route for that media; existing execution stays for unconfigured/unsupported/read-back-failed specialized work; denials are final and pending jobs await the existing lifecycle. This line grants nothing."
        if hasStudio {
            line += " 个人作品原生创作（音乐/图示/画布/文档等）经 studio.* 在本任务内执行；同任务委派子代理持有同一有效上限并通过现有 canonical dispatch 逐调用授权。Personal-work authoring (music/diagram/canvas/documents…) runs through studio.* inside THIS task; a same-task delegated child holds the identical effective ceiling and dispatches per call."
        }
        return [line]
    }

    /// Actionable capability lines bound to (a) the bounded task context and
    /// (b) the descriptors this run actually offers. `bindingNames` is the
    /// fresh-additions list from `taskBoundAdditions` for THIS preparation
    /// (empty when everything the context matched is already in the run's
    /// candidate set), so the binding line only announces genuine
    /// re-discovery while the music chain line stays whenever the music
    /// operation is relevant and the whole native chain is offered. Grants
    /// no authority and never names a tool that is not offered.
    static func contextLines(
        userTask: String,
        taskContext: String = "",
        descriptors: [ToolCatalog.Descriptor],
        bindingNames: [String] = [],
        displayName: (String) -> String = { $0 }
    ) -> [String] {
        let current = userTask.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = taskContext.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = persistentLines(descriptors: descriptors, displayName: displayName)
        let effective = context.isEmpty ? current : context
        // A user-stated code route on the CURRENT message suppresses this
        // turn's capability re-binding (the persistent rule already states
        // deference to that same explicit choice).
        guard !ToolRoutingPolicy.requestsScript(current) else { return lines }
        let offeredNames = Set(descriptors.map(\.name))
        if !bindingNames.isEmpty {
            var groupSet = Set<String>()
            for name in bindingNames where offeredNames.contains(name) {
                groupSet.insert(ToolDiscovery.group(name))
            }
            let groups = groupSet.sorted()
            let sample = bindingNames.prefix(6).filter { offeredNames.contains($0) }
                .map { displayName($0) }.joined(separator: ", ")
            lines.append("Turn capability binding / 本轮能力绑定：当前任务上下文新命中此运行已提供的专用能力组 [\(groups.joined(separator: ", "))]（如 \(sample)），其完整 schema 已加入本轮候选。优先尝试真实支持目标的原生/专用操作并按其返回的示例与修订执行；产物必须用真实回执验证；用户当前明确指定代码或既定路线时遵从用户路线；拒绝不能绕行，未决等待。This turn's bounded task context newly matched the offered specialized capabilities above and their complete schemas entered this request's candidate set; prefer a supported native/dedicated operation using its own examples/revisions (the user's current explicit code route outranks this line), verify artifacts by real receipts, keep denials final and await pending jobs.")
        }
        if isMusicRequest(effective),
           offeredNames.isSuperset(of: ["studio.create", "studio.list", "studio.read", "studio.edit", "studio.run"]) {
            var music = "原生音乐路线 / Native music route：\(displayName("studio.create")) {kind:\"music\",title} → \(displayName("studio.read")) 读取 musicCapabilities/templates/editExample 与真实修订 → \(displayName("studio.edit")) 使用该读取返回的 midi.clip.*/midi.template.* 命令（ID/tick 一律照抄，不猜）→ \(displayName("studio.run")) renderWAV/renderMP3 并等待其真实回执（outputFiles、字节、SHA、audioObservation）。创建或保存作品本身不等于已存在可播放音频，只有渲染/导出回执证明文件；静音混音会渲染出静音文件，勿擅自解除静音。用户当前消息明确指定用代码合成/编辑该媒体时遵从用户路线；否则先走上述原生路线，未支持或失败须有读回证据后再用既有执行。Native first for the music operation itself: create→read→edit→render with the awaited receipt before synthesizing an equivalent numpy/wave script; a saved project is not playable audio — only the verified render/export receipt proves a file. If the user's current message explicitly chose code for this media, follow the user; otherwise try this chain first and fall back only on read-back unsupported/failed evidence."
            if offeredNames.contains("workspace.importOutput") {
                music += " 交付为游戏网页资源文件时，用 \(displayName("workspace.importOutput")) {runID:实际产出run、outputID:真实回执ID、path:本任务工作区新相对路径（不覆盖）} 导入已验证的 run 渲染产物，再按导入回执核对真实字节/SHA 后接入网页，勿手写来源路径或伪回执。For a workspace game asset, import the verified run render with \(displayName("workspace.importOutput")) using the real runID/outputID from the receipt and a non-overwriting destination path, verify the imported bytes/SHA, then wire it into the page."
            } else {
                music += " 本轮未提供经验证的 run 产物→任务工作区导入路线：交付为游戏资源文件时如实说明该交付边界，按既有策略回退（用户路线或读回失败后的既有执行），勿谎称网页已能播放，也勿以此为由跳过原生创作本身。This run offers no verified-output→workspace import route: state that delivery boundary honestly for a game asset file, fall back per the existing policy (user route or execution after read-back failure), never claim the page can already play the render, and never skip the native operation itself for that reason."
            }
            lines.append(music)
        }
        return lines
    }
}

private extension NativeAuthoringRouting {
    static func containsAny(_ terms: [String], in lowered: String) -> Bool {
        for term in terms {
            if term.unicodeScalars.allSatisfy({ $0.isASCII }) {
                if asciiTermPresent(term, in: lowered) { return true }
            } else if lowered.contains(term) {
                return true
            }
        }
        return false
    }

    /// Same rule as `ToolCapabilityGroups.containsAny`: an ASCII term must not
    /// match inside a longer ASCII word ("musical" must not fire "music").
    static func asciiTermPresent(_ term: String, in query: String) -> Bool {
        guard !term.isEmpty, query.contains(term) else { return false }
        var searchStart = query.startIndex
        while searchStart < query.endIndex,
              let range = query.range(of: term, range: searchStart..<query.endIndex) {
            let beforeOK = range.lowerBound == query.startIndex
                || !isASCIILetter(query[query.index(before: range.lowerBound)])
            let afterOK = range.upperBound == query.endIndex
                || !isASCIILetter(query[range.upperBound])
            if beforeOK && afterOK { return true }
            searchStart = query.index(after: range.lowerBound)
        }
        return false
    }

    static func isASCIILetter(_ character: Character) -> Bool {
        character.isLetter && character.isASCII
    }
}
