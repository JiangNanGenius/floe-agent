// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeCore
import FloeGameCore
import FloeGameBuildKit
import FloeGameExecutionBridge
import FloeGameAppIntegration
import FloeGamePortableKit
import FloeGit

/// Build/export sheet over the existing execution bridge. It shows real routes,
/// prerequisites and durable records; it never downloads a tool, signs an
/// installer or re-dispatches a restored CI job automatically.
struct GameProjectBuildScreen: View {
    let session: GameWorkspaceSession
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var plan: GameBuildCapabilityPlan?
    @State private var selectedRoutes: Set<String> = []
    @State private var output: GameBuildArguments.Output = .web
    @State private var records: [GameBuildRecord] = []
    @State private var building = false
    @State private var closing = false
    @State private var error: String?
    @State private var outcome: GameBuildOutcome?
    @State private var repositorySelection: GameBuildRepositorySelection?
    @State private var showingRepositoryPicker = false
    @State private var readiness: GameBuildToolReadiness?
    @State private var resourceReadiness: GameRuntimeEngineReadiness?
    @State private var resourceBusy = false
    @State private var resourceError: String?
    @State private var sourceUploadConsent = false
    @State private var distributionProfileID: String?
    @State private var sourceRequired = false
    @State private var sourceStatus: GameRuntimeSourceAccompanimentStatus?
    @State private var sourceSnapshot: GameSourceCompanionSnapshot?
    @State private var choosingSource = false
    @State private var sourceBusy = false
    @State private var sourceError: String?
    @State private var includeSourceCompanion = false
    @State private var companionExport: GameSourceCompanionExport?
    @State private var hookScenes: [GameInstrumentationSceneChoice] = []
    @State private var hookScene: String?
    @State private var hookPlan: GameInstrumentationPlanSummary?
    @State private var hookReceipt: GameInstrumentationApplyReceipt?
    @State private var hookBusy = false
    @State private var hookError: String?

    private var engine: GameEngineID? { session.project.selectionSnapshot?.selectedEngine }
    private var supportsDeveloperHooks: Bool {
        guard let engine else { return false }
        return [.unity, .godot, .gdevelop, .cocosCreator].contains(engine)
    }
    private var usesCI: Bool {
        guard let plan else { return false }
        return plan.routes.contains {
            selectedRoutes.contains($0.id) && $0.producer == .ci
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(IDELanguageRunText.t("构建目标", "Build target")) {
                    Picker(IDELanguageRunText.t("输出", "Output"), selection: $output) {
                        Text(IDELanguageRunText.t("Web 试玩包", "Web bundle")).tag(GameBuildArguments.Output.web)
                        Text(IDELanguageRunText.t("源代码包", "Source archive")).tag(GameBuildArguments.Output.source)
                        Text(IDELanguageRunText.t("原生工程", "Native project")).tag(GameBuildArguments.Output.nativeProject)
                        Text(IDELanguageRunText.t("原生安装包", "Native installer")).tag(GameBuildArguments.Output.nativeInstaller)
                    }
                    if let plan {
                        Text(engine.map { "\($0.rawValue) → \(output.rawValue)" } ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                        let outputs = plan.outputs.filter { matches($0) }
                        if outputs.isEmpty {
                            Text(IDELanguageRunText.t("这个引擎没有所选输出。选择其他输出或配置引擎工具。", "This engine has no selected output. Choose another output or configure the engine tool."))
                                .font(.callout).foregroundStyle(.orange)
                        } else {
                            ForEach(outputs, id: \.routeID) { value in
                                Toggle(isOn: Binding(
                                    get: { selectedRoutes.contains(value.routeID) },
                                    set: { on in
                                        if on { selectedRoutes.insert(value.routeID) }
                                        else { selectedRoutes.remove(value.routeID) }
                                    })) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(value.artifactName)
                                        Text(value.deliveryNote).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } else if error == nil {
                        ProgressView()
                    }
                    if let plan, let readiness {
                        let missing = readiness.missingPrerequisites(
                            in: plan, selectedRouteIDs: selectedRoutes)
                        if !missing.isEmpty {
                            Text(IDELanguageRunText.t("需要你配置：", "You need to configure: ")
                                + missing.map { $0.tool.id + "@" + $0.tool.version }.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Text(readiness.summary)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                if let resourceReadiness {
                    Section(IDELanguageRunText.t("运行资源", "Runtime resources")) {
                        LabeledContent(resourceReadiness.displayName,
                                       value: resourceReadiness.statusText)
                        if resourceBusy {
                            ProgressView(value: environment.gameWorkspaces.runtimeResources
                                .progress[resourceReadiness.packID] ?? 0)
                                .progressViewStyle(.linear)
                            if let engine {
                                Button(IDELanguageRunText.t("取消下载", "Cancel download")) {
                                    Task {
                                        await environment.gameWorkspaces
                                            .cancelRuntimeResourcePreparation(for: engine)
                                        resourceBusy = false
                                    }
                                }.font(.caption)
                            }
                        }
                        if resourceReadiness.canDownload || resourceReadiness.canRetry {
                            Button {
                                Task { await downloadRuntime() }
                            } label: {
                                HStack {
                                    if resourceBusy { ProgressView().controlSize(.small) }
                                    Text(resourceReadiness.canDownload
                                         ? IDELanguageRunText.t("下载已验证运行资源",
                                                                "Download verified runtime")
                                         : IDELanguageRunText.t("重试", "Retry"))
                                }
                            }.disabled(resourceBusy)
                        }
                        if let resourceError {
                            Text(resourceError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }

                if sourceRequired, distributionProfileID != nil, output == .web {
                    Section(IDELanguageRunText.t("对应源码", "Corresponding source")) {
                        LabeledContent(IDELanguageRunText.t("公开状态", "Public state"),
                                       value: sourceStatus?.text
                                        ?? IDELanguageRunText.t("未发布", "Unpublished"))
                            .font(.caption)
                        if let sourceSnapshot {
                            LabeledContent(IDELanguageRunText.t("已选择", "Selected"),
                                           value: sourceSnapshot.displayName)
                            Text("\(sourceSnapshot.bytes) B · \(sourceSnapshot.sha256.prefix(16))")
                                .font(.caption2).foregroundStyle(.secondary)
                            Toggle(isOn: $includeSourceCompanion) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(IDELanguageRunText.t("导出时附带精确源码",
                                                              "Include exact source in the export"))
                                    Text(IDELanguageRunText.t(
                                        "仅本地工程导出；不会上传、发布或创建公开源码提供。",
                                        "Local engineering export only; nothing is uploaded, published or offered publicly."))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            HStack {
                                Button(IDELanguageRunText.t("替换…", "Replace…")) {
                                    choosingSource = true
                                }
                                Button(IDELanguageRunText.t("移除", "Remove"), role: .destructive) {
                                    removeSource()
                                }
                            }.font(.caption)
                            Button {
                                Task { await exportCompanion() }
                            } label: {
                                HStack {
                                    if sourceBusy { ProgressView().controlSize(.small) }
                                    Text(IDELanguageRunText.t("导出源码伴随包…",
                                                              "Export source companion…"))
                                }
                            }.disabled(sourceBusy)
                            if let companionExport {
                                ShareLink(item: companionExport.directory) {
                                    Label(IDELanguageRunText.t("分享源码伴随包",
                                                               "Share source companion"),
                                          systemImage: "square.and.arrow.up")
                                }
                                Text("\(companionExport.receipt.files.count) · "
                                     + "\(companionExport.receipt.files.reduce(0) { $0 + $1.bytes }) B")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        } else {
                            Text(IDELanguageRunText.t(
                                "尚未选择对应源码。完整分发导出需要你的精确源码包；公开源码未发布不影响本地工程导出。",
                                "No corresponding source selected. A full distribution export needs your exact source bundle; the unpublished public offer does not block this local engineering export."))
                                .font(.caption)
                            Button(IDELanguageRunText.t("选择源码包…", "Choose source bundle…")) {
                                choosingSource = true
                            }.disabled(sourceBusy)
                        }
                        if sourceBusy { ProgressView().controlSize(.small) }
                        if let sourceError {
                            Text(sourceError).font(.caption).foregroundStyle(.red)
                        }
                        Text(IDELanguageRunText.t(
                            "公开状态为未发布时只生成工程导出，不构成公开发布、公开源码提供或法律结论。",
                            "While unpublished this only produces an engineering export; it is not a public release, public source offer or legal conclusion."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                if supportsDeveloperHooks, let engine {
                    Section(IDELanguageRunText.t("开发钩子", "Developer hooks")) {
                        Text(hookExplanation(engine))
                            .font(.caption).foregroundStyle(.secondary)
                        if hookScenes.count > 1 {
                            Picker(IDELanguageRunText.t("场景", "Scene"), selection: Binding(
                                get: { hookScene ?? "" },
                                set: { value in
                                    hookScene = value
                                    hookPlan = nil
                                })) {
                                ForEach(hookScenes) { scene in
                                    Text("\(scene.name) — \(scene.path)").tag(scene.id)
                                }
                            }
                        }
                        if let hookPlan {
                            LabeledContent(IDELanguageRunText.t("场景", "Scene"),
                                           value: hookPlan.scene.map { "\($0.name) · \($0.path)" }
                                               ?? IDELanguageRunText.t("不适用", "Not applicable"))
                            Text(hookPlan.changedPaths.isEmpty
                                 ? IDELanguageRunText.t("已安装，无需更改。", "Installed; no change.")
                                 : IDELanguageRunText.t("将修改：", "Will change: ")
                                    + hookPlan.changedPaths.joined(separator: ", "))
                                .font(.caption)
                            if !hookPlan.capabilities.isEmpty {
                                Text(IDELanguageRunText.t("调试能力：", "Debug capabilities: ")
                                    + hookPlan.capabilities.joined(separator: ", "))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            ForEach(hookPlan.diagnostics.prefix(4), id: \.self) { line in
                                Text(line).font(.caption2).foregroundStyle(.secondary)
                            }
                            if hookPlan.requiresRebuild {
                                Text(IDELanguageRunText.t("安装后需要重新构建对应导出。",
                                                          "Rebuild the matching export after installation."))
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                            Button {
                                Task { await applyHook(engine) }
                            } label: {
                                HStack {
                                    if hookBusy { ProgressView().controlSize(.small) }
                                    Text(hookBusy ? IDELanguageRunText.t("正在安装…", "Installing…")
                                          : IDELanguageRunText.t("安装钩子", "Install hooks"))
                                }
                            }.disabled(hookBusy || !hookPlan.dormancyGated)
                        } else {
                            Button {
                                Task { await loadHookPlan(engine) }
                            } label: {
                                HStack {
                                    if hookBusy { ProgressView().controlSize(.small) }
                                    Text(hookBusy ? IDELanguageRunText.t("正在检查…", "Checking…")
                                          : IDELanguageRunText.t("检查钩子", "Check hooks"))
                                }
                            }.disabled(hookBusy)
                        }
                        if let hookReceipt {
                            Label(IDELanguageRunText.t("已安装到修订 \(hookReceipt.revision.prefix(12))",
                                                      "Installed at revision \(hookReceipt.revision.prefix(12))"),
                                  systemImage: "checkmark.seal")
                                .font(.caption).foregroundStyle(.green)
                        }
                        if let hookError {
                            Text(hookError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }

                Section(IDELanguageRunText.t("GitHub Actions（可选）", "GitHub Actions (optional)")) {
                    if let selectedRepository = repositorySelection {
                        LabeledContent(IDELanguageRunText.t("仓库", "Repository"), value: selectedRepository.fullName)
                        LabeledContent(IDELanguageRunText.t("分支", "Branch"), value: selectedRepository.branch)
                        Button(IDELanguageRunText.t("清除选择", "Clear selection")) {
                            Task { await clearRepository() }
                        }
                    } else {
                        Text(IDELanguageRunText.t("未选择仓库。仅本地/设备路径可用；需要 CI 的路线会给出明确缺失。", "No repository selected. Local/device routes remain; CI-only routes report their real missing prerequisite."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(IDELanguageRunText.t("选择已有 GitHub 仓库", "Choose existing GitHub repository")) {
                        showingRepositoryPicker = true
                    }
                    if usesCI {
                        Toggle(isOn: Binding(
                            get: { sourceUploadConsent },
                            set: { value in
                                sourceUploadConsent = value
                                GameBuildRepositorySettings.setSourceUploadConsent(value)
                            })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(IDELanguageRunText.t("允许为 CI 上传本次保存版本",
                                                          "Allow uploading this saved revision for CI"))
                                Text(IDELanguageRunText.t("只上传当前项目的源码快照到所选仓库；不包含令牌、签名或本机路径。",
                                                          "Uploads only this project's source snapshot to the selected repository; no token, signing identity or local path is included."))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section(IDELanguageRunText.t("构建记录", "Build records")) {
                    if records.isEmpty {
                        Text(IDELanguageRunText.t("没有已保存的构建记录。", "No durable build records."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(records, id: \.buildID) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.buildID.prefix(12)).font(.headline.monospaced())
                            Text("\(record.engine) · \(record.state.rawValue) · \(record.artifacts.count) artifacts")
                                .font(.caption).foregroundStyle(.secondary)
                            if let error = record.error {
                                Text(error).font(.caption2).foregroundStyle(.red)
                            }
                            if record.state == .succeeded, let ready = record.distributionReady {
                                Text(ready ? IDELanguageRunText.t("已验证", "Verified") : IDELanguageRunText.t("未完成", "Incomplete"))
                                    .font(.caption2).foregroundStyle(ready ? .green : .orange)
                            }
                        }
                        .swipeActions {
                            Button(IDELanguageRunText.t("删除记录", "Delete record"), role: .destructive) {
                                Task { await deleteRecord(record) }
                            }
                        }
                    }
                    Text(IDELanguageRunText.t("已恢复的终态记录不会自动重新派发；进行中的 CI 句柄只在本进程有效。", "Restored terminal records are not re-dispatched; in-flight CI handles are process-local."))
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if let outcome {
                    Section(IDELanguageRunText.t("结果", "Result")) {
                        Label(outcome.ready ? IDELanguageRunText.t("全部输出已验证", "All outputs verified")
                              : IDELanguageRunText.t("未就绪", "Not ready"),
                              systemImage: outcome.ready ? "checkmark.seal" : "exclamationmark.triangle")
                            .foregroundStyle(outcome.ready ? .green : .orange)
                        ForEach(outcome.artifacts, id: \.name) { artifact in
                            VStack(alignment: .leading) {
                                Text(artifact.name)
                                Text("\(artifact.bytes) B · \(artifact.sha256.prefix(16))")
                                    .font(.caption2).foregroundStyle(.secondary)
                                if artifact.sealed != nil {
                                    Text(IDELanguageRunText.t("已封装为可试玩 Web 包", "Sealed as a playable Web package"))
                                        .font(.caption2).foregroundStyle(.tint)
                                }
                            }
                        }
                        if let transitive = outcome.sourceTransport {
                            Text(String(describing: transitive)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }

                Section {
                    Button {
                        Task { await build() }
                    } label: {
                        HStack {
                            if building { ProgressView().controlSize(.small) }
                            Text(building ? IDELanguageRunText.t("正在构建…", "Building…")
                                  : IDELanguageRunText.t("开始构建", "Build"))
                        }
                    }.disabled(building || engine == nil || selectedRoutes.isEmpty
                        || (usesCI && !sourceUploadConsent)
                        || (includeSourceCompanion && sourceSnapshot == nil))
                    if building {
                        Button(role: .destructive) {
                            Task { await cancelBuild() }
                        } label: {
                            Text(IDELanguageRunText.t("取消构建", "Cancel build"))
                        }
                        .accessibilityIdentifier("game.build.cancel")
                    }
                }
            }
            .navigationTitle(IDELanguageRunText.t("构建／导出", "Build / export"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IDELanguageRunText.t("关闭", "Close")) {
                        Task { await closeSheet() }
                    }.disabled(closing)
                }
            }
            .interactiveDismissDisabled(building)
            .task {
                await load()
                await loadHookScenes()
            }
            .fileImporter(isPresented: $choosingSource,
                          allowedContentTypes: [.folder, .zip, .data],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { Task { await chooseSource(url) } }
                case .failure(let failure):
                    sourceError = failure.localizedDescription
                }
            }
            .onChange(of: output) { _, value in
                if value != .web { includeSourceCompanion = false }
            }
            .sheet(isPresented: $showingRepositoryPicker) {
                GameBuildRepositoryPicker(selection: $repositorySelection) { selection in
                    Task { await configure(selection) }
                }
            }
        }
    }

    private func hookExplanation(_ engine: GameEngineID) -> String {
        switch engine {
        case .gdevelop:
            return IDELanguageRunText.t(
                "不会改写 game.json。安装会记录审核过的桥文件；导出或运行时把同样的惰性桥写入私有试玩副本。已导出的可玩游戏无需再次导出。",
                "game.json is never rewritten. Installation records the reviewed bridge; the exporter or run path stamps the same dormant bridge into a private playable copy. An already-exported game needs no re-export.")
        case .cocosCreator:
            return IDELanguageRunText.t(
                "创建 Creator 3.8 组件与精确 .meta UUID，并挂接到所选场景。需要重新构建网页版；不会覆盖同名用户脚本。",
                "Creates the Creator 3.8 component and exact .meta UUID and attaches it to the selected scene. A Web rebuild is required; a same-name user script is never overwritten.")
        default:
            return IDELanguageRunText.t(
                "通过现有工程仓库安装审核过的开发钩子；安装后需要重新构建对应导出。普通导出保持惰性。",
                "Installs the reviewed development hook through the existing project repository; rebuild the matching export afterward. Ordinary exports stay dormant.")
        }
    }

    private func clearRepository() async {
        do {
            try await environment.gameWorkspaces.configureGitHub(session: session, selection: nil)
            repositorySelection = nil
            sourceUploadConsent = false
        } catch { self.error = error.localizedDescription }
    }

    private func loadHookScenes() async {
        guard supportsDeveloperHooks, let engine else { return }
        hookError = nil
        do {
            hookScenes = try await environment.gameWorkspaces.developerHookScenes(
                for: session, engine: engine)
            if let selected = hookScene,
               hookScenes.contains(where: { $0.id == selected }) {
                return
            }
            hookScene = hookScenes.first(where: { $0.isStartScene })?.id
                ?? (hookScenes.count == 1 ? hookScenes[0].id : nil)
        } catch { hookError = error.localizedDescription }
    }

    private func loadHookPlan(_ engine: GameEngineID) async {
        hookBusy = true
        hookError = nil
        defer { hookBusy = false }
        do {
            hookPlan = try await environment.gameWorkspaces.developerHookPlan(
                for: session, engine: engine, sceneID: hookScene)
        } catch { hookError = error.localizedDescription }
    }

    private func applyHook(_ engine: GameEngineID) async {
        guard let hookPlan else { return }
        hookBusy = true
        hookError = nil
        defer { hookBusy = false }
        do {
            hookReceipt = try await environment.gameWorkspaces.developerHookApply(
                for: session, plan: hookPlan)
            self.hookPlan = nil
            await loadHookScenes()
            await loadHookPlan(engine)
        } catch { hookError = error.localizedDescription }
    }

    private func matches(_ value: GameBuildOutput) -> Bool {
        switch output {
        case .web: value.kind == .webBundle
        case .source: value.kind == .sourceArchive
        case .nativeProject: value.kind == .nativeProject
        case .nativeInstaller: value.kind == .nativeInstaller
        }
    }

    private func load() async {
        do {
            guard let engine else { throw GameWorkspaceRegistryError.notGameProject }
            try await environment.gameWorkspaces.ensurePlayableSession(for: session)
            await environment.gameWorkspaces.runtimeResources.refresh()
            let execution = try await environment.gameWorkspaces.executionSession(for: session)
            let plan = try await environment.gameWorkspaces.capabilityPlan(session: session, engine: engine)
            self.plan = plan
            self.selectedRoutes = Set(plan.outputs.filter { matches($0) }.map(\.routeID))
            self.records = try await execution.restoreBuilds()
            self.repositorySelection = GameBuildRepositorySettings.load()
            self.sourceUploadConsent = GameBuildRepositorySettings.sourceUploadConsent()
            self.readiness = await environment.gameWorkspaces.buildToolReadiness()
            self.resourceReadiness = environment.gameWorkspaces.runtimeResources.readiness(for: engine)
            self.distributionProfileID = environment.gameWorkspaces.runtimeResources
                .distributionProfileID(for: engine)
            self.sourceRequired = environment.gameWorkspaces.runtimeResources
                .requiresPairedSource(for: engine)
            self.sourceStatus = environment.gameWorkspaces.runtimeResources
                .sourceAccompanimentStatus(for: engine)
            self.sourceSnapshot = environment.gameWorkspaces.sourceCompanionSnapshot(
                session: session, engine: engine)
            if !sourceRequired { includeSourceCompanion = false }
        } catch { self.error = error.localizedDescription }
    }

    private func chooseSource(_ url: URL) async {
        guard let engine else { return }
        sourceBusy = true
        sourceError = nil
        defer { sourceBusy = false }
        do {
            sourceSnapshot = try await environment.gameWorkspaces.importSourceCompanion(
                url: url, session: session, engine: engine)
            includeSourceCompanion = true
            companionExport = nil
        } catch is CancellationError {
            sourceError = nil
        } catch {
            sourceError = sourceCompanionMessage(error)
        }
    }

    private func removeSource() {
        guard let engine else { return }
        do {
            try environment.gameWorkspaces.removeSourceCompanion(session: session, engine: engine)
            sourceSnapshot = nil
            includeSourceCompanion = false
            companionExport = nil
            sourceError = nil
        } catch {
            sourceError = error.localizedDescription
        }
    }

    private func exportCompanion() async {
        guard let engine else { return }
        sourceBusy = true
        sourceError = nil
        defer { sourceBusy = false }
        do {
            companionExport = try await environment.gameWorkspaces.exportSourceCompanion(
                session: session, engine: engine)
        } catch is CancellationError {
            sourceError = nil
        } catch {
            sourceError = sourceCompanionMessage(error)
        }
    }

    private func sourceCompanionMessage(_ error: Error) -> String {
        if let value = error as? GamePortableSourceOfferError {
            switch value {
            case .missingFile, .missingRoot, .invalidBundle:
                return IDELanguageRunText.t(
                    "没有找到与已审阅记录一致的完整源码包。请选择精确源码包文件，或包含全部声明文件的已物化源码伴随目录。",
                    "No complete source bundle matching the reviewed record was found. Choose the exact bundle file, or a materialized source-companion folder containing every declared file.")
            case .digestMismatch:
                return IDELanguageRunText.t(
                    "源码包大小或哈希与已审阅记录不一致，不能用于导出。",
                    "The source bundle size or hash does not match the reviewed record and cannot be used.")
            case .destinationExists:
                return IDELanguageRunText.t(
                    "目标已存在；不会覆盖。",
                    "The destination already exists; nothing was overwritten.")
            case .io:
                return IDELanguageRunText.t(
                    "读取源码包失败，请确认文件仍可访问。",
                    "The source bundle could not be read. Confirm it is still accessible.")
            case .notPublished:
                return IDELanguageRunText.t(
                    "公开源码尚未发布。",
                    "The public source offer is unpublished.")
            }
        }
        return error.localizedDescription
    }

    private func downloadRuntime() async {
        guard let engine else { return }
        resourceBusy = true
        resourceError = nil
        defer { resourceBusy = false }
        do {
            try await environment.gameWorkspaces.prepareRuntimeResource(
                for: engine, session: session)
            resourceReadiness = environment.gameWorkspaces.runtimeResources.readiness(for: engine)
            await load()
        } catch is CancellationError {
            resourceError = nil
        } catch {
            resourceError = error.localizedDescription
        }
    }

    private func cancelBuild() async {
        guard building else { return }
        let outcome = await environment.gameWorkspaces.cancelBuilds(session: session)
        guard !outcome.isConfirmed else { return }
        error = IDELanguageRunText.t(
            "构建尚未确认停止，请重试取消。项目仍保持打开。",
            "The build has not confirmed stopping. Retry Cancel; the project stays open.")
            + (outcome.detail.isEmpty ? "" : "\n" + outcome.detail)
    }

    private func closeSheet() async {
        guard !closing else { return }
        closing = true
        if building {
            let outcome = await environment.gameWorkspaces.cancelBuilds(session: session)
            guard outcome.isConfirmed else {
                closing = false
                error = IDELanguageRunText.t(
                    "构建尚未确认停止，请重试关闭或取消构建。",
                    "The build has not confirmed stopping. Retry Close or Cancel build.")
                    + (outcome.detail.isEmpty ? "" : "\n" + outcome.detail)
                return
            }
        }
        dismiss()
    }

    private func build() async {
        guard let engine else { return }
        if usesCI && !sourceUploadConsent {
            error = IDELanguageRunText.t(
                "请先允许为 CI 上传本次保存版本，或改选本地/源代码路线。",
                "Allow uploading this saved revision for CI, or choose a local/source route.")
            return
        }
        building = true
        defer { building = false }
        do {
            let execution = try await environment.gameWorkspaces.executionSession(for: session)
            let result = try await environment.gameWorkspaces.build(
                session: session, engine: engine, output: output,
                routeIDs: selectedRoutes,
                distributionProfileID: includeSourceCompanion
                    ? distributionProfileID : nil)
            outcome = result.outcome
            records = try await execution.restoreBuilds()
            readiness = await environment.gameWorkspaces.buildToolReadiness()
            error = result.missingPrerequisites.isEmpty
                ? nil
                : IDELanguageRunText.t("仍需配置：", "Still missing: ")
                    + result.missingPrerequisites.joined(separator: ", ")
        } catch { self.error = error.localizedDescription }
    }

    private func deleteRecord(_ record: GameBuildRecord) async {
        guard let id = UUID(uuidString: record.buildID) else { return }
        do {
            let execution = try await environment.gameWorkspaces.executionSession(for: session)
            try await execution.deleteBuild(id)
            records = try await execution.restoreBuilds()
        } catch { self.error = error.localizedDescription }
    }

    private func configure(_ selection: GameBuildRepositorySelection) async {
        do {
            try await environment.gameWorkspaces.configureGitHub(session: session, selection: selection)
            repositorySelection = selection
            showingRepositoryPicker = false
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

/// Pick an existing configured repository from the real source-control account.
/// No token, subscription or developer account check is introduced here.
struct GameBuildRepositoryPicker: View {
    @Binding var selection: GameBuildRepositorySelection?
    let onChoose: (GameBuildRepositorySelection) -> Void
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if environment.sourceControlCenter.account == nil {
                    ContentUnavailableView {
                        Label(IDELanguageRunText.t("尚未连接 GitHub", "GitHub not connected"),
                              systemImage: "person.crop.circle.badge.questionmark")
                    } description: {
                        Text(IDELanguageRunText.t("请先在现有“源代码管理”设置中登录；此处不会保存令牌。", "Sign in through the existing Source Control settings first; no token is stored here."))
                    }
                } else if environment.sourceControlCenter.repositories.isEmpty {
                    Text(IDELanguageRunText.t("没有可用仓库。", "No repositories available."))
                } else {
                    ForEach(environment.sourceControlCenter.repositories) { repository in
                        Button {
                            do {
                                let value = try GameBuildRepositorySelection(repository: repository)
                                selection = value
                                onChoose(value)
                            } catch { self.error = error.localizedDescription }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(repository.fullName)
                                Text(repository.defaultBranch + (repository.isPrivate ? " · private" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(IDELanguageRunText.t("选择仓库", "Choose repository"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(IDELanguageRunText.t("关闭", "Close")) { dismiss() } } }
        }
    }
}
#endif
