// SPDX-License-Identifier: MPL-2.0
//
// IDELanguageRunView — the compact native sheet presented by the IDE play
// button. It renders exactly one typed run plan: the on-device interpreter,
// an explicit configured-SSH-host run, or an actionable unavailable reason.
// It never claims a runtime is installed that the capability snapshot did not
// observe, and it shows the quoted command before anything is dispatched.

#if canImport(UIKit)
import SwiftUI
import FloeExecution

/// Inline en/zh strings for this surface. The primary agent may move these
/// keys into `Localizable.xcstrings`; until then the sheet is usable in both
/// languages without depending on an unmerged catalog entry.
enum IDELanguageRunText {
    static var isChinese: Bool { Locale.current.identifier.hasPrefix("zh") }
    static func t(_ zh: String, _ en: String) -> String { isChinese ? zh : en }

    static func interpreterName(_ interpreter: IDELanguageLocalInterpreter) -> String {
        switch interpreter {
        case .python3: return "Python"
        case .node: return "Node"
        case .shell: return t("Shell", "Shell")
        case .lua: return "WASI Lua"
        }
    }

    static func reason(_ reason: IDELanguageRunUnavailableReason) -> String {
        switch reason {
        case .noActiveFile:
            return t("没有打开的文件", "No file is open")
        case .invalidPath:
            return t("文件路径无效，无法运行", "The file path is not valid")
        case .unsupportedFileType(let ext):
            return t("暂不支持运行 .\(ext) 文件", "Running .\(ext) files is not supported")
        case .localRuntimeMissing(let interpreter):
            return t("本机未安装 \(interpreterName(interpreter)) 运行时", "The \(interpreterName(interpreter)) runtime is not installed on this device")
        case .remoteLanguageNeedsHost(let tool):
            return t("\(tool) 只能通过已配置的 SSH 主机运行，请选择目标主机", "\(tool) can only run on a configured SSH host; choose a target host")
        case .noRemoteHostConfigured:
            return t("没有已配置的 SSH 主机", "No SSH host is configured")
        case .conflictUnresolved:
            return t("存在未解决的编辑冲突，已取消运行", "An unresolved edit conflict cancelled the run")
        case .snapshotSaveFailed:
            return t("保存当前文件失败，已取消运行", "Saving the current file failed; the run was cancelled")
        case .guestShapeUnavailable:
            return t("所选的客户机内核数无法交付，已在启动前阻止运行（不会以 1 核静默替代 2 核）",
                     "The selected guest core count cannot be delivered; the run was blocked before any guest start (an explicit dual-core request is never silently run on one hart)")
        case .gitHubNotConnected:
            return t("尚未连接 GitHub，请在设置中登录", "GitHub is not connected; sign in under Settings")
        case .noGitHubRepositorySelected:
            return t("请选择要运行 CI 的 GitHub 仓库", "Choose the GitHub repository to run CI on")
        case .gitHubActionsUnsupported(let language):
            return t("GitHub Actions 暂不支持运行 \(language)", "GitHub Actions cannot run \(language) yet")
        case .invalidWorkflowPath:
            return t("工作流路径无效，必须位于 .github/workflows 下的 YAML 文件", "The workflow path is invalid; it must be a YAML file under .github/workflows")
        }
    }

    static func stagingFailure(_ failure: IDERunStagingFailure) -> String {
        switch failure {
        case .invalidSourcePath:
            return t("文件路径无效，无法传输", "The file path is not valid for transfer")
        case .sourceTooLarge(let limit):
            return t("文件超过 \(limit / 1024) KB 的传输上限", "The file exceeds the \(limit / 1024) KB transfer limit")
        case .sourceUnreadable:
            return t("无法读取刚保存的文件内容", "The just-saved file could not be read")
        case .conflict:
            return t("远端暂存目录存在不属于本次运行的数据，已停止且未覆盖", "The remote staging directory holds data this run does not own; nothing was overwritten")
        case .writeFailed:
            return t("远端未确认收到相同的字节内容", "The host did not acknowledge the exact bytes sent")
        case .verificationFailed:
            return t("远端回读的内容与已保存的文件不一致，未执行运行", "The remote read-back did not match the saved file; the run was not executed")
        case .notVisibleOnHost:
            return t("暂存文件在主机默认云工作区根目录不可见（主机可能自定义了根目录），未执行运行", "The staged file is not visible at the host's default cloud-workspace root (the host may use a custom root); the run was not executed")
        }
    }

    static func status(_ status: IDELanguageRunStatus) -> String? {
        switch status {
        case .idle: return nil
        case .preparing:
            return t("正在准备运行（保存、探测、校验传输）…", "Preparing the run (save, probe, verified transfer)…")
        case .blocked(let reason): return Self.reason(reason)
        case .probeFailed(let tool):
            return t("远端主机上没有可执行的 \(tool)，未发送运行命令", "\(tool) is not executable on the host; no run command was sent")
        case .probeError:
            return t("无法探测远端可执行文件，未发送运行命令", "Could not probe the remote executable; no run command was sent")
        case .terminalUnavailable:
            return t("本地终端无法启动", "The local terminal could not start")
        case .guestShapeRefused(let refusal):
            return Self.guestShapeStartRefusal(refusal)
        case .projectToolEnvironmentUnavailable:
            return t("无法解析本工作区的执行环境，已取消本地运行（未打开终端）", "Could not resolve this workspace's execution environment; the local run was not started")
        case .remoteHostUnavailable:
            return t("远程主机不可用", "The remote host is unavailable")
        case .remoteStagingUnavailable:
            return t("该主机上没有可连接的 Floe 远程助手，无法完成已校验的源码传输", "No reachable Floe remote agent on this host, so the verified source transfer cannot run")
        case .stagingFailed(let failure):
            return Self.stagingFailure(failure)
        case .stagingCleanupUnconfirmed(let stagingRoot, let stageFailure):
            let base = t("本次运行未确认已清理远端暂存目录：\(stagingRoot)。该目录可能残留，可手动删除；不会删除不属于本次运行的数据。",
                         "Could not confirm cleanup of this run's remote staging directory: \(stagingRoot). It may remain and can be removed manually; data not owned by this run is never deleted.")
            if let stageFailure {
                return base + " " + Self.stagingFailure(stageFailure)
            }
            return base
        case .workspaceChanged:
            return t("工作区已更改，已阻止本次运行", "The workspace changed; this run was blocked")
        case .runningLocal:
            return t("已在本地终端运行", "Running in the local terminal")
        case .runningRemote:
            return t("正在远程主机上运行（源码已校验传输）", "Running on the remote host (source staged and verified)")
        case .cancelledPreparation:
            return t("已取消运行准备。",
                     "Run preparation was cancelled.")
        case .finishedLocal(let exitCode):
            if let exitCode {
                return t("本地运行已结束（退出码 \(exitCode)）", "Local run finished (exit \(exitCode))")
            }
            return t("本地运行已结束", "Local run finished")
        case .finishedRemote(let exitCode):
            return t("远程运行已结束（退出码 \(exitCode)）", "Remote run finished (exit \(exitCode))")
        case .remoteRunTimedOut:
            return t("远程运行超时，已断开 SSH 连接；无法确认远端进程是否退出或清理陷阱是否运行。",
                     "The remote run timed out and the SSH connection was closed; the remote process exit and cleanup trap are not confirmed.")
        case .stoppedLocal:
            return t("已停止本次本地运行", "Stopped this local run")
        case .stopRequestedRemote:
            return t("已请求停止本次远程运行；无法确认远端进程是否退出、SSH 客户端是否关闭或暂存目录是否已清理。",
                     "Stop was requested for this remote run; the remote process exit, the SSH client close and the staging cleanup are not confirmed.")
        case .gitHubActionsPreparing:
            return t("正在发布快照并触发 GitHub Actions…", "Publishing the snapshot and dispatching GitHub Actions…")
        case .gitHubActionsDispatched(let runID):
            if let runID {
                return t("已触发 GitHub Actions（run \(runID)）", "GitHub Actions dispatched (run \(runID))")
            }
            return t("已触发 GitHub Actions，正在关联运行记录", "GitHub Actions dispatched; associating the run")
        case .gitHubActionsAssociationPending:
            return t("已触发工作流，但尚未唯一关联到本次快照；不会重复提交，将按快照继续核对。",
                     "The workflow was dispatched but no unique run is associated yet; Floe will not resubmit and keeps checking by snapshot.")
        case .gitHubActionsCancelRequested:
            return t("已请求取消；GitHub 会异步结束该运行，Floe 会继续核对直到确认 cancelled。",
                     "Cancel requested; GitHub finalizes the run asynchronously and Floe keeps checking until it is cancelled.")
        case .gitHubActionsFailed(let detail):
            return detail
        }
    }

    // MARK: Guest shape

    static func shapeLabel(_ selection: GuestRunEntryShapeSelection) -> String {
        switch selection {
        case .automatic: return t("自动（按声明信号）", "Automatic (by declared signals)")
        case .singleCore: return t("1 个客户机内核", "1 guest core")
        case .dualCore: return t("2 个客户机内核", "2 guest cores")
        }
    }

    /// One typed gate refusal. Every branch names the blocker instead of
    /// implying a shape will run.
    static func shapeRefusal(_ refusal: GuestRunEntryShapeRefusal) -> String {
        switch refusal {
        case .releaseVCPUUnsupported(let requested, let maximum):
            return t("本版本最多 \(maximum) 个客户机内核，尚未交付 \(requested) 核：双核尚未完成发布资格和真机验证。选择 2 核会在启动前被拒绝，不会以 1 核静默运行。",
                     "This release delivers at most \(maximum) guest core; \(requested) cores are not yet qualified for release and device use. Selecting 2 cores is refused before launch; it never silently runs on one hart.")
        case .imageDoesNotProveSMP(let requested):
            return t("当前镜像清单没有提供 SMP 证据，资源池会拒绝 \(requested) 核的授权；已在启动前拒绝，不会以 1 核静默运行。",
                     "The current image manifest does not prove SMP, so the resource pool refuses a \(requested)-core grant; the run is refused before launch and never silently runs on one hart.")
        case .dispatchNotShapeAware(let requested):
            return t("运行调度路径尚未接入客户机形状请求，当前无法把 \(requested) 核交给启动流程；已在启动前拒绝，不会以 1 核静默运行。",
                     "The run dispatch path cannot deliver a guest shape request yet, so \(requested) cores cannot reach the start path; the run is refused before launch and never silently runs on one hart.")
        }
    }

    /// One typed start-path refusal: the environment's guest could not take the
    /// requested shape. The running guest is never reshaped or restarted, and
    /// nothing executed at another shape.
    static func guestShapeStartRefusal(_ refusal: ShellGuestRunShapeError) -> String {
        switch refusal {
        case .startAlreadyInProgress:
            return t("该环境已有另一次客户机启动正在进行；本次运行未启动任何东西，请等它结束后重试。",
                     "Another guest start is already in progress for this environment; nothing was started for this run. Wait for it to finish and run again.")
        case .runningGuestShapeMismatch(_, let requested, let running):
            return t("该环境的客户机正在以 \(running) 个内核运行，与请求的 \(requested) 个内核不一致；已拒绝本次请求，未重启或改变正在运行的客户机。请先停止该客户机，再以新形状启动。",
                     "This environment's guest is already running with \(running) core(s), which does not match the requested \(requested); the request was refused and the running guest was not restarted or reshaped. Stop the guest to start it at the new shape.")
        case .runningGuestShapeUnknown(_, let requested):
            return t("该环境已有客户机在运行，但无法读取其已授予的内核数；为确保不静默按其他形状运行，请求 \(requested) 个内核的本次运行已被拒绝。",
                     "A guest is already running for this environment but its granted core count could not be read; to avoid running at an unrequested shape, this \(requested)-core run was refused.")
        }
    }

    /// The automatic plan's effective shape, stated with its basis. When the
    /// advisory planned two harts but the gate delivers one, the reason names
    /// the gate that blocked two instead of leaving a silent downgrade.
    static func automaticShapeNote(_ plan: GuestRunEntryShapePlan) -> String {
        guard plan.recommendation.shape.vcpus == .two else {
            return t("声明信号未要求并行：本次以 1 个客户机内核启动。",
                     "The declared signals do not ask for parallelism: this run starts with 1 guest core.")
        }
        if plan.automaticDeliversRecommendation {
            return t("声明信号表明可并行：本次将以 2 个客户机内核启动。",
                     "Declared signals indicate parallel work: this run starts with 2 guest cores.")
        }
        var note = t("声明信号推荐 2 核，但当前只能交付 1 核。本次将以 1 个客户机内核启动。",
                     "The declared signals recommend 2 cores, but only 1 can be delivered. This run starts with 1 guest core.")
        if let refusal = plan.option(for: .dualCore)?.refusal {
            note += " " + shapeRefusal(refusal)
        }
        return note
    }

    static func mechanism(_ mechanism: IDELanguageRunMechanism) -> String {
        switch mechanism {
        case .localInterpreter:
            return t("本机运行时", "On-device runtime")
        case .remoteInterpreter:
            return t("远程解释运行", "Remote interpreter")
        case .remoteCompileRun:
            return t("远程编译运行", "Remote compile & run")
        case .gitHubActionsCloud:
            return t("GitHub Actions 云端构建", "GitHub Actions cloud build")
        }
    }

    static func runnerPlatform(_ platform: GitHubActionsRunnerPlatform) -> String {
        switch platform {
        case .linux: return "Linux"
        case .macOS: return "macOS"
        }
    }

    static func snapshotSummary(_ preview: GitHubActionsSnapshotPreview?) -> String {
        guard let preview else { return t("尚无快照", "No snapshot yet") }
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(preview.totalBytes), countStyle: .file)
        return t("将上传 \(preview.manifest.fileCount) 个文件（\(bytes)）；排除 \(preview.manifest.excluded.count) 个。",
                 "\(preview.manifest.fileCount) files (\(bytes)) will be uploaded; \(preview.manifest.excluded.count) excluded.")
    }

    static func role(_ role: IDEGitHubActionsRunRole) -> String {
        switch role {
        case .build: return t("编译构建", "Build")
        case .lintTest: return t("Lint/测试", "Lint/test")
        }
    }

    static func remoteState(_ state: GitHubActionsJobState) -> String {
        switch state {
        case .preparing: return t("准备中", "Preparing")
        case .snapshotPublished: return t("快照已发布", "Snapshot published")
        case .dispatching: return t("已触发，等待运行记录", "Dispatched, awaiting run")
        case .associationPending: return t("等待关联运行", "Awaiting run association")
        case .queued: return t("排队中", "Queued")
        case .running: return t("运行中", "Running")
        case .cancelling: return t("取消中", "Cancelling")
        case .completed: return t("已完成", "Completed")
        case .failed: return t("失败", "Failed")
        case .cancelled: return t("已取消", "Cancelled")
        case .error: return t("出错", "Error")
        }
    }
}

struct IDELanguageRunView: View {
    @ObservedObject var controller: IDELanguageRunController
    @ObservedObject var state: IDEWorkbenchState
    /// The app-owned center is observed directly so a run dispatched from a
    /// previous session (or this sheet reopened) is still listed and updated.
    @ObservedObject private var gitHubCenter = GitHubActionsJobCenter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var jobLogRecordID: UUID?
    @State private var jobLogText: String?
    @State private var showingJobLog = false
    /// The run-entry guest shape choice and its resolved plan are BOTH owned by
    /// the controller: the picker writes `controller.guestShapeSelection` and
    /// the sheet renders `controller.guestShapePlan`, so the visible plan, the
    /// Run button gate and the dispatched typed request can never diverge.
    private var guestShapePlan: GuestRunEntryShapePlan? { controller.guestShapePlan }

    private var fileName: String {
        guard let path = state.activePath, let last = path.split(separator: "/").last else {
            return IDELanguageRunText.t("当前文件", "Current file")
        }
        return String(last)
    }

    private var definition: IDELanguageRunDefinition? {
        guard let path = state.activePath else { return nil }
        return IDELanguageRunPolicy.definition(forRelativePath: path)
    }

    var body: some View {
        NavigationStack {
            Form {
                fileSection
                targetSection
                if showsGuestShapeSection { guestShapeSection }
                if case .remote = controller.selection.target { remoteSettingsSection }
                if case .githubActions = controller.selection.target { gitHubActionsSection }
                availabilitySection
                commandSection
            }
            .navigationTitle(IDELanguageRunText.t("运行", "Run"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IDELanguageRunText.t("关闭", "Close")) { dismiss() }
                        .accessibilityIdentifier("workspace.ide.run.close")
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    if controller.canStop {
                        Button(role: .destructive) {
                            Task { await controller.stop() }
                        } label: {
                            Label(IDELanguageRunText.t("停止", "Stop"), systemImage: "stop.fill")
                        }
                        .accessibilityIdentifier("workspace.ide.run.stop")
                    }
                    Button {
                        Task { await controller.dispatch() }
                    } label: {
                        Label(IDELanguageRunText.t("运行", "Run"), systemImage: "play.fill")
                    }
                    .disabled(!controller.canDispatch || guestShapeBlocksDispatch)
                    .accessibilityIdentifier("workspace.ide.run.confirm")
                }
            }
            .task { await controller.prepare() }
            .task(id: guestShapeTaskKey) { await controller.refreshGuestShapePlan() }
            .onChange(of: controller.selection) { _, _ in
                Task { await controller.selectionDidChange() }
            }
            .onChange(of: state.activePath) { _, _ in
                controller.refreshPlan()
                Task { await controller.selectionDidChange() }
            }
            .sheet(isPresented: $showingJobLog) {
                NavigationStack {
                    ScrollView {
                        Text(jobLogText ?? IDELanguageRunText.t("暂无日志", "No log"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle(IDELanguageRunText.t("作业日志", "Job log"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(IDELanguageRunText.t("关闭", "Close")) { showingJobLog = false }
                        }
                    }
                }
            }
        }
    }

    // MARK: Sections

    private var fileSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileName).font(.headline)
                    if let definition {
                        Text(definition.displayName).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(IDELanguageRunText.t("未知语言", "Unknown language"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// The target picker uses a stable string so a value-carrying
    /// `githubActions` target still round-trips; selecting it fills in the
    /// first connected repository (or the placeholder until one exists).
    private var targetKindBinding: Binding<String> {
        Binding(
            get: {
                switch controller.selection.target {
                case .local: return "local"
                case .remote(let id, _): return "remote:\(id.uuidString)"
                case .githubActions: return "github"
                }
            },
            set: { value in
                if value == "github" {
                    if let repository = controller.gitHubRepositories.first {
                        controller.setGitHubRepository(repository)
                    } else {
                        controller.setGitHubRepository(placeholderRepository)
                    }
                } else if value.hasPrefix("remote:"),
                          let host = controller.hosts.first(where: { value.hasSuffix($0.id.uuidString) }) {
                    controller.selection.target = .remote(hostID: host.id, hostName: host.name)
                } else {
                    controller.selection.target = .local
                }
            }
        )
    }

    private var placeholderRepository: GitHubActionsRepositorySelection {
        GitHubActionsRepositorySelection(
            id: 0, fullName: "", defaultBranch: "main", isPrivate: false
        )
    }

    private var targetSection: some View {
        Section(IDELanguageRunText.t("运行目标", "Run target")) {
            Picker(selection: targetKindBinding) {
                Text(IDELanguageRunText.t("本机", "This device"))
                    .tag("local")
                ForEach(controller.hosts) { host in
                    Text(host.name)
                        .tag("remote:\(host.id.uuidString)")
                }
                Text("GitHub Actions")
                    .tag("github")
            } label: {
                Text(IDELanguageRunText.t("目标", "Target"))
            }
            .accessibilityIdentifier("workspace.ide.run.target")
            if controller.hosts.isEmpty {
                Text(IDELanguageRunText.t("没有已配置的 SSH 主机。请在主机设置中添加。",
                                          "No SSH host is configured. Add one in Host settings."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Guest shape (Python/Node script runs)

    /// The interpreter whose run boots the Linux guest, when the local target
    /// is selected and the file is a guest-backed language. nil hides the
    /// control (remote targets, native shell, WASI Lua).
    private var guestShapeInterpreter: IDELanguageLocalInterpreter? {
        guard case .local = controller.selection.target,
              let path = state.activePath,
              let definition = IDELanguageRunPolicy.definition(forRelativePath: path),
              let interpreter = definition.localInterpreter,
              IDELanguageRunPolicy.runsInLinuxGuest(interpreter) else { return nil }
        return interpreter
    }

    private var showsGuestShapeSection: Bool {
        guard guestShapeInterpreter != nil else { return false }
        if case .local = controller.plan { return true }
        return false
    }

    /// True while a guest-backed local run cannot dispatch with the current
    /// selection. A refused dual-core choice disables Run: the sheet never
    /// starts a guest at a shape the user did not choose.
    private var guestShapeBlocksDispatch: Bool {
        guard showsGuestShapeSection else { return false }
        return !(guestShapePlan?.isRunnable ?? false)
    }

    /// Recomputes the plan whenever the pinned file, the target or the
    /// selection changes. The controller rebuilds it from the shared advisory
    /// (honoring a user override or recorded outcome), the verified image's SMP
    /// proof and the release gate, so the sheet never displays a plan that
    /// differs from the one dispatch consumes.
    private var guestShapeTaskKey: String {
        let target: String
        switch controller.selection.target {
        case .local: target = "local"
        case .remote(let id, _): target = "remote:\(id.uuidString)"
        case .githubActions: target = "github"
        }
        return "\(target)|\(state.activePath ?? "")|\(guestShapeInterpreter?.rawValue ?? "none")|\(controller.guestShapeSelection.rawValue)"
    }

    private func guestShapeOptionLabel(_ selection: GuestRunEntryShapeSelection) -> String {
        let label = IDELanguageRunText.shapeLabel(selection)
        guard let plan = guestShapePlan,
              let option = plan.option(for: selection),
              !option.isAvailable else { return label }
        return label + " · " + IDELanguageRunText.t("不可用", "unavailable")
    }

    private var guestShapeSection: some View {
        Section(IDELanguageRunText.t("客户机内核", "Guest cores")) {
            Picker(selection: $controller.guestShapeSelection) {
                ForEach(GuestRunEntryShapeSelection.allCases, id: \.self) { selection in
                    Text(guestShapeOptionLabel(selection)).tag(selection)
                }
            } label: {
                Text("vCPU")
            }
            .accessibilityIdentifier("workspace.ide.run.guestShape")

            if let plan = guestShapePlan {
                switch plan.selection {
                case .automatic:
                    Text(IDELanguageRunText.automaticShapeNote(plan))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .singleCore:
                    Text(IDELanguageRunText.t(
                        "显式选择 1 个客户机内核；请求按严格模式提交，资源池不会静默减少内核数。",
                        "An explicit single guest core; the request is strict and the pool never silently reduces the core count."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                case .dualCore:
                    if let refusal = plan.refusal {
                        Label(IDELanguageRunText.shapeRefusal(refusal), systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if plan.effectiveVCPUs == .two {
                        Text(IDELanguageRunText.t(
                            "显式选择 2 个客户机内核；请求按严格模式提交。",
                            "An explicit dual guest cores request; it is submitted strictly."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            Text(IDELanguageRunText.t(
                "Python/Node 脚本在 Linux 客户机中运行。此选择只影响客户机启动时的内核数；已运行的客户机保持其当前形状（形状变更需要停止并重启客户机）。",
                "Python/Node scripts run inside the Linux guest. This choice affects the core count at guest start only; an already-running guest keeps its current shape (changing it requires a stop and restart)."
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var remoteSettingsSection: some View {
        Section(IDELanguageRunText.t("远程运行", "Remote run")) {
            Label(IDELanguageRunText.t("单文件运行：仅将当前文件按已保存字节传输到主机上本次运行专属的暂存目录，回读校验 SHA-256 后才会执行；项目依赖不会被传输。",
                                       "Single-file run: only the current file is transferred — byte-exact into a run-owned staging directory on the host, verified by SHA-256 read-back before anything executes; project dependencies are not transferred."),
                  systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
            Label(IDELanguageRunText.t("运行结束后，该次运行的清理陷阱只删除本次运行专属的暂存目录。",
                                       "After the run, this run's cleanup trap removes only its own staging directory."),
                  systemImage: "trash")
                .font(.caption).foregroundStyle(.secondary)
            if let mapped = controller.capabilities.mapping {
                Text(IDELanguageRunText.t("该项目还在该主机上配置了完整项目镜像：\(mapped.workingDirectory)（仅供参考，运行使用已校验的暂存副本）。",
                                          "This project also has a full mirror on this host: \(mapped.workingDirectory) (informational; the run uses the verified staged copy)."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if case .remote(let command, _) = controller.plan {
                Text(IDELanguageRunText.t("暂存路径：\(command.stagedSourcePath)",
                                          "Staging path: \(command.stagedSourcePath)"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(IDELanguageRunText.t("可执行探测：\(command.probeCommand)",
                                          "Executable probe: \(command.probeCommand)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: GitHub Actions

    private var gitHubTemplateYAML: String? {
        controller.gitHubTemplate?.yaml
    }

    private var repositoryBinding: Binding<Int64> {
        Binding(
            get: { controller.selection.target.repository?.id ?? 0 },
            set: { id in
                guard let repository = controller.gitHubRepositories.first(where: { $0.id == id }) else { return }
                controller.setGitHubRepository(repository)
            }
        )
    }

    private var branchBinding: Binding<String> {
        Binding(
            get: {
                controller.selection.target.gitHubActionsRef
                    ?? controller.selection.target.repository?.defaultBranch
                    ?? ""
            },
            set: { controller.setGitHubRef($0) }
        )
    }

    private var workflowBinding: Binding<String> {
        Binding(
            get: { controller.selection.target.gitHubActionsWorkflowPath ?? "" },
            set: { controller.setGitHubWorkflowPath($0.isEmpty ? nil : $0) }
        )
    }

    private var gitHubActionsSection: some View {
        Section(IDELanguageRunText.t("GitHub Actions 云构建", "GitHub Actions cloud build")) {
            Label(IDELanguageRunText.t(
                "workflow_dispatch 只能发现默认分支上的工作流；安装会把 Floe 模板提交到该仓库默认分支（仅快进，不覆盖内容不同的同名文件）。",
                "workflow_dispatch only discovers workflows on the default branch; installing commits the Floe template there (fast-forward only, never overwriting a same-name file with different content)."
            ), systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.secondary)

            if controller.gitHubRepositories.isEmpty {
                Text(IDELanguageRunText.t("尚未连接 GitHub 或未读取到仓库。", "GitHub is not connected, or no repository was returned."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(IDELanguageRunText.t("重新读取仓库", "Reload repositories")) {
                    Task { await controller.selectionDidChange() }
                }
            } else {
                Picker(selection: repositoryBinding) {
                    ForEach(controller.gitHubRepositories) { repository in
                        Text(repository.isPrivate ? "\(repository.fullName) (private)" : repository.fullName)
                            .tag(repository.id)
                    }
                } label: {
                    Text(IDELanguageRunText.t("仓库", "Repository"))
                }
                .accessibilityIdentifier("workspace.ide.run.github.repository")

                LabeledContent(IDELanguageRunText.t("分支", "Branch")) {
                    TextField(IDELanguageRunText.t("分支", "Branch"), text: branchBinding)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("workspace.ide.run.github.branch")
                }

                Picker(selection: workflowBinding) {
                    if controller.gitHubTemplate != nil {
                        Text(IDELanguageRunText.t("Floe 模板（需先安装）", "Floe template (install first)"))
                            .tag("")
                    }
                    ForEach(controller.gitHubWorkflowPaths, id: \.self) { path in
                        Text(path).tag(path)
                    }
                } label: {
                    Text(IDELanguageRunText.t("工作流", "Workflow"))
                }
                .accessibilityIdentifier("workspace.ide.run.github.workflow")

                if controller.gitHubActionsPreview == nil {
                    Text(IDELanguageRunText.t(
                        "快照不可用：请先打开一个工作区文件。",
                        "Snapshot unavailable: open a workspace file first."
                    ))
                    .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(IDELanguageRunText.snapshotSummary(controller.gitHubActionsPreview))
                        .font(.caption).foregroundStyle(.secondary)
                }

                if controller.selection.target.gitHubActionsWorkflowPath == nil,
                   let template = controller.gitHubTemplate {
                    Button {
                        Task { await controller.installGitHubWorkflowTemplate() }
                    } label: {
                        Label(
                            IDELanguageRunText.t("安装模板到默认分支", "Install template on default branch"),
                            systemImage: "arrow.up.doc"
                        )
                    }
                    .accessibilityIdentifier("workspace.ide.run.github.install")
                    DisclosureGroup(IDELanguageRunText.t("查看模板 YAML", "Review template YAML")) {
                        Text(template.yaml)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text(IDELanguageRunText.t(
                        "安装只写入 \(template.workflowPath)；若该路径已有不同内容，Floe 会改为导出到工作区 .floe/workflows/ 供你审查。",
                        "Install writes only \(template.workflowPath); if that path already has different content Floe exports it to .floe/workflows/ for review instead."
                    ))
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }

            gitHubRunList

            if let error = gitHubCenter.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// Durable records owned by the app-level center. They are listed even
    /// after the sheet is reopened, so a run that continued on GitHub is not
    /// lost when the app (or this view) went away.
    @ViewBuilder
    private var gitHubRunList: some View {
        let records = controller.gitHubWorkspaceRecords
        if !records.isEmpty {
            DisclosureGroup(IDELanguageRunText.t("运行记录", "Runs")) {
                if records.contains(where: { !$0.state.isTerminal }) {
                    Label(IDELanguageRunText.t(
                        "自动更新中。关闭 App 后构建继续，重新打开会同步结果。",
                        "Updates automatically. Builds continue with the App closed; reopening syncs the result."
                    ), systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(record.languageID) · \(record.role)")
                                .font(.subheadline)
                            Spacer()
                            Text(IDELanguageRunText.remoteState(record.state))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let runID = record.runID {
                            Text("run \(runID) · \(record.remoteStatus ?? "") \(record.remoteConclusion ?? "")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(record.updatedAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption2).foregroundStyle(.secondary)
                        if let detail = record.lastError {
                            Text(detail).font(.caption2).foregroundStyle(.orange)
                        }
                        HStack(spacing: 12) {
                            Button(IDELanguageRunText.t("刷新", "Refresh")) {
                                Task { await controller.refreshGitHubRecord(record.id) }
                            }
                            if !record.state.isTerminal {
                                Button(IDELanguageRunText.t("取消", "Cancel"), role: .destructive) {
                                    Task { await controller.cancelGitHubRecord(record.id) }
                                }
                            }
                            if record.runID != nil {
                                Button(IDELanguageRunText.t("读取产物列表", "Load artifacts")) {
                                    Task { await controller.loadGitHubArtifacts(record.id) }
                                }
                                Button(IDELanguageRunText.t("作业日志", "Job log")) {
                                    Task { await loadJobLog(recordID: record.id) }
                                }
                            }
                        }
                        .font(.caption)
                        ForEach(record.artifacts) { artifact in
                            HStack {
                                Text(artifact.name).font(.caption2)
                                if artifact.expired {
                                    Text(IDELanguageRunText.t("已过期", "expired"))
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                                Spacer()
                                if let path = artifact.downloadedRelativePath {
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(path)
                                        Text(artifact.downloadVerified == true
                                             ? IDELanguageRunText.t("摘要已验证", "Digest verified")
                                             : IDELanguageRunText.t("已下载 · 仅本地校验和", "Downloaded · local checksum only"))
                                    }
                                    .font(.caption2).foregroundStyle(.secondary)
                                } else {
                                    Button(IDELanguageRunText.t("下载", "Download")) {
                                        Task {
                                            _ = await controller.downloadGitHubArtifact(
                                                recordID: record.id, artifact: artifact, overwrite: false
                                            )
                                        }
                                    }
                                    .font(.caption2)
                                    .disabled(artifact.expired)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func loadJobLog(recordID: UUID) async {
        jobLogRecordID = recordID
        let jobs = await controller.gitHubJobs(recordID: recordID)
        guard let job = jobs.first else {
            jobLogText = nil
            showingJobLog = true
            return
        }
        let slice = await controller.gitHubJobLog(recordID: recordID, jobID: job.id)
        if let slice {
            jobLogText = slice.truncated ? slice.text + "\n[truncated]" : slice.text
        } else {
            jobLogText = nil
        }
        showingJobLog = true
    }

    private var availabilitySection: some View {        Section(IDELanguageRunText.t("可用性", "Availability")) {
            if let mechanism = controller.plan.mechanism {
                LabeledContent(IDELanguageRunText.t("方式", "Mechanism")) {
                    Text(IDELanguageRunText.mechanism(mechanism))
                }
                if mechanism.isCloudHosted {
                    Label(IDELanguageRunText.t(
                        "编译在 GitHub 的 Linux/macOS 运行器上进行；产物是云端编译结果，不能作为 iOS 可执行文件在本机安装或运行。",
                        "The build runs on GitHub's Linux/macOS runner; the artifact is a cloud build output and cannot be installed or run as an iOS binary on this device."
                    ), systemImage: "cloud")
                        .font(.caption).foregroundStyle(.secondary)
                } else if mechanism.isCrossCompile {
                    Label(IDELanguageRunText.t("编译产物写入运行专属临时目录，运行后由该次运行清理。",
                                               "Compiled output goes to a run-owned temporary directory and is cleaned up by this run."),
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(IDELanguageRunText.t("当前目标不可运行", "The current target cannot run"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let reason = controller.plan.blockedReason {
                Label(IDELanguageRunText.reason(reason), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let status = IDELanguageRunText.status(controller.status) {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }

            LabeledContent(IDELanguageRunText.t("本机运行时", "On-device runtimes")) {
                Text(localRuntimeSummary)
            }
            .font(.caption)
        }
    }

    private var commandSection: some View {
        Section(IDELanguageRunText.t("将执行的命令", "Command to run")) {
            if let line = controller.dispatchedCommandLine ?? controller.plan.commandLine {
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
            if case .githubActions = controller.plan {
                Text(IDELanguageRunText.t(
                    "此处是 workflow_dispatch 摘要；仓库、分支、工作流与快照在上方确认。",
                    "This is the workflow_dispatch summary; confirm repository, branch, workflow and snapshot above."
                ))
                .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(IDELanguageRunText.t("每个参数单独加引号，绝不拼接原始字符串。",
                                          "Every argument is quoted individually; raw strings are never concatenated."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var localRuntimeSummary: String {
        let available = IDELanguageLocalInterpreter.allCases
            .filter { controller.capabilities.localInterpreters.contains($0) }
            .map { IDELanguageRunText.interpreterName($0) }
        return available.isEmpty
            ? IDELanguageRunText.t("无", "None")
            : available.joined(separator: ", ")
    }
}

/// Live terminal for the run-owned execution. It renders the same bounded
/// output the controller observes — the local session stream, or the captured
/// remote result — so a run is never hidden inside a session the UI cannot
/// see. Input stays disabled: the command is already dispatched and Stop is
/// the owned, scoped cancellation for both surfaces.
struct IDERunTerminalView: View {
    @ObservedObject var controller: IDELanguageRunController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(IDELanguageRunText.status(controller.status) ?? IDELanguageRunText.t("运行", "Run"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        Task { await controller.stop() }
                    } label: {
                        Label(IDELanguageRunText.t("停止", "Stop"), systemImage: "stop.fill")
                    }
                    .disabled(!controller.canStop)
                    .accessibilityIdentifier("workspace.ide.run.terminal.stop")
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                Divider()
                SSHEmulatorView(
                    output: controller.runOutput,
                    isInteractive: false,
                    onSend: { _ in },
                    onResize: { _, _ in }
                )
            }
            .navigationTitle(IDELanguageRunText.t("运行终端", "Run terminal"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(IDELanguageRunText.t("关闭", "Close")) { dismiss() }
                }
            }
        }
    }
}

private extension IDELanguageRunPlan {
    var blockedReason: IDELanguageRunUnavailableReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}
#endif
