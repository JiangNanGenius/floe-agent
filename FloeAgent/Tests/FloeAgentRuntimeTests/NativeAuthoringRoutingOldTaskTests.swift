// FloeAgentRuntimeTests — turn-bound capability routing. Pinned scenarios:
// the REAL screenshot flow (a broad "写个网页版三国志9" task whose MUSIC asset
// substep lives in the current run's own checklist, then a bare "继续" after
// an app update), old-task new-message refresh, checkpoint-Continue refresh,
// catalog-driven breadth (workspace/GitHub/PDF), explicit user code routes,
// unconfigured-capability honesty, and child prompt/seed parity. Device and
// App-target behavior stay with the integration owner.

import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeAgentRuntime

@Suite("Native-first old-task routing")
struct NativeAuthoringRoutingOldTaskTests {
    private func descriptor(_ name: String) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: name,
            toolDescription: "test \(name)",
            parametersJSON: #"{"type":"object","properties":{}}"#,
            riskLabels: [],
            isSideEffecting: false
        )
    }

    /// A realistic post-update ceiling: the music chain plus the generic
    /// coding entries the old game task had already discovered.
    private func updatedCatalog() -> [ToolCatalog.Descriptor] {
        [
            "studio.create", "studio.list", "studio.read", "studio.edit", "studio.run",
            "workspace.writeFile", "workspace.readFile", "workspace.moveFile", "workspace.publishOutput",
            "exec.shell", "tools.search", "tools.list", "web.search", "web.fetch",
            "image.generate", "image.models",
            "exec.localPython"
        ].map(descriptor)
    }

    private func oldTaskSeeded() -> Set<String> {
        ["exec.shell", "workspace.writeFile", "workspace.readFile", "tools.search", "tools.list", "web.search", "web.fetch"]
    }

    // MARK: - The real trigger: decomposed substep + bare 继续

    @Test func sgz9StyleBareContinueStillRefreshesMusicFromItsOwnPlan() {
        let context = NativeAuthoringRouting.boundedTaskContext(
            currentUserTask: "继续",
            originalGoal: "写个网页版三国志9，要有地图、内政和战斗",
            planStepTitles: ["搭建核心循环", "生成一段背景音乐循环 WAV 资产并接入网页", "地图渲染优化"]
        )
        let additions = NativeAuthoringRouting.taskBoundAdditions(
            userTask: "继续",
            taskContext: context,
            liveDescriptors: updatedCatalog(),
            discoveredNames: oldTaskSeeded()
        ).map(\.name)
        #expect(Set(["studio.create", "studio.list", "studio.read", "studio.edit", "studio.run"]).isSubset(of: Set(additions)))
        #expect(!additions.contains("exec.shell"))
        #expect(!additions.contains("exec.localPython")) // retired/guest entry never refreshed
        #expect(additions.count <= 12)
        let lines = NativeAuthoringRouting.contextLines(
            userTask: "继续",
            taskContext: context,
            descriptors: updatedCatalog(),
            bindingNames: additions
        ).joined(separator: "\n")
        #expect(lines.contains("Native music route"))
        #expect(lines.contains("本轮能力绑定"))
    }

    @Test func bareContinueWithoutAssetStepStaysQuietButPersistentRuleFires() {
        let context = NativeAuthoringRouting.boundedTaskContext(
            currentUserTask: "继续",
            originalGoal: "写个网页版三国志9",
            planStepTitles: ["实现战斗结算界面"]
        )
        let additions = NativeAuthoringRouting.taskBoundAdditions(
            userTask: "继续",
            taskContext: context,
            liveDescriptors: updatedCatalog(),
            discoveredNames: oldTaskSeeded()
        )
        #expect(additions.isEmpty) // no invented capability from a silent context
        let lines = NativeAuthoringRouting.contextLines(
            userTask: "继续", taskContext: context, descriptors: updatedCatalog()
        ).joined(separator: "\n")
        // The always-on substep rule still tells the model that a later
        // media-asset substep must check offered capabilities first.
        #expect(lines.contains("Substep capability rule"))
        #expect(lines.contains("不是") || lines.contains("not the user specifying code-based media synthesis"))
        #expect(!lines.contains("Native music route"))
        #expect(!lines.contains("本轮能力绑定"))
    }

    // MARK: - Old-task new message + Continue (user-confirmed broken paths)

    @Test func seededOldTaskStillRediscoversNativeMusicFromNewMessage() {
        let additions = NativeAuthoringRouting.taskBoundAdditions(
            userTask: "给sgz9的网页游戏加一段背景音乐",
            liveDescriptors: updatedCatalog(),
            discoveredNames: oldTaskSeeded()
        ).map(\.name)
        #expect(Set(["studio.create", "studio.list", "studio.read", "studio.edit", "studio.run"]).isSubset(of: Set(additions)))
        let merged = NativeAuthoringRouting.mergedDiscoveryState(
            userTask: "给sgz9的网页游戏加一段背景音乐",
            liveDescriptors: updatedCatalog(),
            discoveredNames: oldTaskSeeded(),
            currentPriority: ["exec.shell", "workspace.writeFile"]
        )
        #expect(merged.names.isSuperset(of: oldTaskSeeded().union(["studio.run"])))
        #expect(Array(merged.priority.prefix(additions.count)) == additions)
        #expect(merged.priority.suffix(2) == ["exec.shell", "workspace.writeFile"])
    }

    @Test func checkpointRestoredStateRefreshesAndStaysIdempotent() {
        let restored: Set<String> = ["exec.shell", "skill.read", "workspace.writeFile"]
        let merged = NativeAuthoringRouting.mergedDiscoveryState(
            userTask: "generate a short background music loop for the web game",
            liveDescriptors: updatedCatalog(),
            discoveredNames: restored,
            currentPriority: ["exec.shell", "skill.read"]
        )
        #expect(merged.names.isSuperset(of: restored))
        #expect(merged.names.contains("studio.create"))
        let again = NativeAuthoringRouting.mergedDiscoveryState(
            userTask: "generate a short background music loop for the web game",
            liveDescriptors: updatedCatalog(),
            discoveredNames: merged.names,
            currentPriority: merged.priority
        )
        #expect(again.names == merged.names)
        #expect(again.priority == merged.priority)
    }

    // MARK: - Catalog-driven breadth (no per-module whitelist)

    @Test func workspaceEditRefreshesNativeFileTools() {
        let additions = NativeAuthoringRouting.taskBoundAdditions(
            userTask: "把项目里的配置文件重命名并整理目录",
            liveDescriptors: updatedCatalog(),
            discoveredNames: ["exec.shell"]
        ).map(\.name)
        #expect(additions.contains("workspace.moveFile"))
    }

    @Test func newlyOfferedGitHubReaderRefreshes() {
        var catalog = updatedCatalog()
        catalog.append(descriptor("github.readLink"))
        let additions = NativeAuthoringRouting.taskBoundAdditions(
            userTask: "读一下这个 GitHub 仓库里的 issue #42 讨论",
            liveDescriptors: catalog,
            discoveredNames: ["exec.shell"]
        ).map(\.name)
        #expect(additions.contains("github.readLink"))
    }

    @Test func pdfCapabilityRefreshesWithoutWhitelistEdit() {
        var catalog = updatedCatalog()
        catalog.append(descriptor("document.pdf.merge"))
        let additions = NativeAuthoringRouting.taskBoundAdditions(
            userTask: "把这几份 PDF 合并再加水印",
            liveDescriptors: catalog,
            discoveredNames: ["exec.shell"]
        ).map(\.name)
        #expect(additions.contains("document.pdf.merge"))
    }

    @Test func trulyUnrelatedCodingRequestStaysUnchanged() {
        let merged = NativeAuthoringRouting.mergedDiscoveryState(
            userTask: "Fix the login crash.",
            liveDescriptors: updatedCatalog(),
            discoveredNames: ["exec.shell"],
            currentPriority: ["exec.shell"]
        )
        #expect(merged.names == ["exec.shell"])
        #expect(merged.priority == ["exec.shell"])
    }

    // MARK: - User routes and honesty

    @Test func explicitCodeRouteIsHonored() {
        let additions = NativeAuthoringRouting.taskBoundAdditions(
            userTask: "用 Python 脚本合成一段背景音乐放进游戏",
            liveDescriptors: updatedCatalog(),
            discoveredNames: []
        )
        #expect(additions.isEmpty)
        // Even with an asset step in the plan, the CURRENT message's explicit
        // code route suppresses this turn's native re-binding.
        let context = NativeAuthoringRouting.boundedTaskContext(
            currentUserTask: "直接用 numpy 脚本生成音乐就行",
            originalGoal: "写个网页版三国志9",
            planStepTitles: ["生成背景音乐资产"]
        )
        #expect(NativeAuthoringRouting.taskBoundAdditions(
            userTask: "直接用 numpy 脚本生成音乐就行",
            taskContext: context,
            liveDescriptors: updatedCatalog(),
            discoveredNames: ["exec.shell"]
        ).isEmpty)
        let lines = NativeAuthoringRouting.contextLines(
            userTask: "直接用 numpy 脚本生成音乐就行",
            taskContext: context,
            descriptors: updatedCatalog()
        ).joined(separator: "\n")
        #expect(!lines.contains("Native music route"))
        // The persistent rule still states deference to the explicit choice.
        #expect(lines.contains("CURRENT message explicitly chose code"))
    }

    @Test func unconfiguredCapabilityIsNeverInventedOrGlossed() {
        let shellOnly = [descriptor("exec.shell"), descriptor("tools.search"), descriptor("tools.list")]
        let additions = NativeAuthoringRouting.taskBoundAdditions(
            userTask: "给网页游戏做背景音乐",
            liveDescriptors: shellOnly,
            discoveredNames: []
        )
        #expect(additions.isEmpty)
        let lines = NativeAuthoringRouting.contextLines(
            userTask: "给网页游戏做背景音乐",
            descriptors: shellOnly
        ).joined(separator: "\n")
        // No specialized capability exists beyond the interpreter and the
        // runtime helpers: even the persistent rule stays silent.
        #expect(lines.isEmpty)
    }

    @Test func newTaskAndOldTaskRefreshConverge() {
        // A fresh run's guess and an old run's refresh expose the same music
        // chain (new-vs-old contrast acceptance).
        let freshGuess = Set(ToolDiscovery.matches(query: "制作一首背景音乐", descriptors: updatedCatalog())
            .map(\.name)
            .filter { NativeAuthoringRouting.isRefreshableCapability($0) })
        let refreshed = Set(NativeAuthoringRouting.taskBoundAdditions(
            userTask: "制作一首背景音乐",
            liveDescriptors: updatedCatalog(),
            discoveredNames: []
        ).map(\.name))
        #expect(refreshed.isSubset(of: freshGuess))
        #expect(refreshed.isSuperset(of: ["studio.create", "studio.read", "studio.run"]))
    }

    // MARK: - Vocabulary

    @Test func musicRequestsAreNativeMediaIntentInBothLanguages() {
        #expect(ToolRoutingPolicy.intent(forTask: "make background music for the game") == .nativeMedia)
        #expect(ToolRoutingPolicy.intent(forTask: "create a soundtrack loop") == .nativeMedia)
        #expect(ToolRoutingPolicy.intent(forTask: "给网页游戏创作背景音乐") == .nativeMedia)
        #expect(ToolRoutingPolicy.intent(forTask: "生成一段歌曲伴奏") == .nativeMedia)
        #expect(ToolRoutingPolicy.intent(forTask: "用 numpy 合成音效") == .scripted)
        // ASCII boundary: "musical" must not fire the "music" term, and no
        // other media term is present.
        #expect(ToolRoutingPolicy.intent(forTask: "the musical theater poster layout") == .general)
    }

    @Test func musicSearchFindsStudioAndKeepsShellAsPeer() {
        let found = ToolDiscovery.matches(query: "generate background music for the game", descriptors: updatedCatalog())
            .map(\.name)
        #expect(found.contains("studio.create"))
        #expect(found.contains("studio.run"))
        // Honest peers: the interpreter is never suppressed because a native
        // tool exists.
        #expect(found.contains("exec.shell"))
        #expect(!found.contains("exec.localPython"))
    }

    // MARK: - Actionable lines

    @Test func musicChainLineIsActionableAndReceiptTruthful() {
        let lines = NativeAuthoringRouting.contextLines(
            userTask: "给sgz9的网页游戏加一段背景音乐",
            descriptors: updatedCatalog()
        ).joined(separator: "\n")
        #expect(lines.contains("Native music route"))
        #expect(lines.contains("renderWAV/renderMP3"))
        // A created/saved project is never claimed as playable audio.
        #expect(lines.contains("只有渲染/导出回执证明") && lines.contains("only the verified render/export receipt proves a file"))
        // Delivery boundary is CATALOG-CONDITIONAL: no import route offered
        // here, so the line states the limit honestly instead of claiming an
        // import path or freezing a build-wide "never exists" sentence.
        #expect(lines.contains("本轮未提供经验证的 run 产物→任务工作区导入路线"))
        #expect(lines.contains("no verified-output→workspace import route"))
        #expect(!lines.contains("本构建中模型侧没有"))
        #expect(!lines.contains("workspace.importOutput"))
        // Explicit user-route deference, denial truth, pending truth.
        #expect(lines.contains("用户当前消息明确指定用代码") && lines.contains("follow the user"))
        #expect(lines.contains("denials are final") && lines.contains("拒绝不能绕行"))
        #expect(lines.contains("deferred is not missing") || lines.contains("延后不等于不可用"))
        #expect(lines.utf8.count < 7_000)
    }

    @Test func musicLineUsesTheRealImportRouteWhenTheCatalogOffersIt() {
        var catalog = updatedCatalog()
        catalog.append(descriptor("workspace.importOutput"))
        let lines = NativeAuthoringRouting.contextLines(
            userTask: "给sgz9的网页游戏加一段背景音乐",
            descriptors: catalog
        ).joined(separator: "\n")
        #expect(lines.contains("workspace.importOutput"))
        #expect(lines.contains("outputID"))
        #expect(!lines.contains("本轮未提供经验证的 run 产物→任务工作区导入路线"))
        #expect(!lines.contains("no verified-output→workspace import route"))
    }

    @Test func musicChainLineNeedsTheWholeNativeChain() {
        let offered = [descriptor("studio.list"), descriptor("studio.read"), descriptor("exec.shell"), descriptor("tools.search"), descriptor("tools.list")]
        let bindings = NativeAuthoringRouting.taskBoundAdditions(
            userTask: "创作背景音乐", liveDescriptors: offered, discoveredNames: []
        ).map(\.name)
        let lines = NativeAuthoringRouting.contextLines(
            userTask: "创作背景音乐", descriptors: offered, bindingNames: bindings
        ).joined(separator: "\n")
        #expect(!lines.contains("Native music route"))
        #expect(lines.contains("Turn capability binding"))
    }

    @Test func linesOnlyNameOfferedToolsOnEitherWireSpelling() {
        let offered = [descriptor("notes.read"), descriptor("notes.edit"), descriptor("exec.shell"), descriptor("tools.search"), descriptor("tools.list")]
        let bindings = NativeAuthoringRouting.taskBoundAdditions(
            userTask: "笔记里整理一段说明", liveDescriptors: offered, discoveredNames: []
        ).map(\.name)
        let lines = NativeAuthoringRouting.contextLines(
            userTask: "笔记里整理一段说明", descriptors: offered, bindingNames: bindings
        ).joined(separator: "\n")
        #expect(lines.contains("notes.read"))
        #expect(!lines.contains("studio.create") && !lines.contains("studio.run"))
        let wire = NativeAuthoringRouting.contextLines(
            userTask: "给sgz9的网页游戏加一段背景音乐",
            descriptors: updatedCatalog(),
            displayName: { ToolNameSpelling.wire($0, safe: true) }
        ).joined(separator: "\n")
        #expect(wire.contains("studio_create"))
    }

    // MARK: - Child parity (host-visible seams)

    @Test func canonicalChildPromptCarriesNativeGuidance() {
        let studio = [
            descriptor("studio.create"), descriptor("studio.list"), descriptor("studio.read"),
            descriptor("studio.edit"), descriptor("studio.run"), descriptor("exec.shell"),
            descriptor("tools.search"), descriptor("tools.list")
        ]
        let prompt = SubagentRunner.handoffPromptForTesting(
            kind: .execute,
            context: nil,
            canonicalChild: true,
            nativeDescriptors: studio,
            userTask: "为网页游戏创作一段背景音乐"
        )
        #expect(prompt.contains("Native first"))
        #expect(prompt.contains("Native music route"))
        #expect(prompt.contains("same effective ceiling") || prompt.contains("identical effective ceiling"))
        // Legacy read-only children keep the old contract untouched.
        let legacy = SubagentRunner.handoffPromptForTesting(
            kind: .execute,
            context: nil,
            canonicalChild: false,
            nativeDescriptors: studio,
            userTask: "为网页游戏创作一段背景音乐"
        )
        #expect(!legacy.contains("Native music route"))
        // The default seam (existing callers) is unchanged.
        #expect(!SubagentRunner.handoffPromptForTesting(kind: .explore, context: "ctx").contains("Native first"))
    }

    @Test func childSeedUsesTheSameBoundedAdditions() {
        let offered = updatedCatalog()
        let additions = NativeAuthoringRouting.taskBoundAdditions(
            userTask: "compose background music for the game",
            liveDescriptors: offered,
            discoveredNames: []
        ).map(\.name)
        let seeded = ChildToolDiscovery.seedNames(
            offeredNames: Set(offered.map(\.name)),
            includeChildOnlyPeers: false,
            extra: Set(additions)
        )
        #expect(seeded.contains("studio.run"))
        #expect(seeded.contains("exec.shell")) // core seed untouched
        let base = ChildToolDiscovery(descriptors: offered, seedNames: ChildToolDiscovery.seedNames(
            offeredNames: Set(offered.map(\.name)), includeChildOnlyPeers: false))
        var discovery = base
        _ = discovery.load(additions, maxBytes: 1_000_000)
        #expect(Set(discovery.loaded).isSuperset(of: Set(additions)))
    }
}
