// SPDX-License-Identifier: MPL-2.0
//
// IDELanguageRunView — the compact native sheet presented by the IDE play
// button. It renders exactly one typed run plan: the on-device interpreter,
// an explicit configured-SSH-host run, or an actionable unavailable reason.
// It never claims a runtime is installed that the capability snapshot did not
// observe, and it shows the quoted command before anything is dispatched.

#if canImport(UIKit)
import SwiftUI

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
        }
    }

    static func mechanism(_ mechanism: IDELanguageRunMechanism) -> String {
        switch mechanism {
        case .localInterpreter:
            return t("本机运行时", "On-device runtime")
        case .remoteInterpreter:
            return t("远程解释运行", "Remote interpreter")
        case .remoteCompileRun:
            return t("远程编译运行", "Remote compile & run")
        }
    }
}

struct IDELanguageRunView: View {
    @ObservedObject var controller: IDELanguageRunController
    @ObservedObject var state: IDEWorkbenchState
    @Environment(\.dismiss) private var dismiss

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
                if case .remote = controller.selection.target { remoteSettingsSection }
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
                    .disabled(!controller.canDispatch)
                    .accessibilityIdentifier("workspace.ide.run.confirm")
                }
            }
            .task { await controller.prepare() }
            .onChange(of: controller.selection) { _, _ in controller.refreshPlan() }
            .onChange(of: state.activePath) { _, _ in controller.refreshPlan() }
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

    private var targetSection: some View {
        Section(IDELanguageRunText.t("运行目标", "Run target")) {
            Picker(selection: $controller.selection.target) {
                Text(IDELanguageRunText.t("本机", "This device"))
                    .tag(IDELanguageRunSelection.Target.local)
                ForEach(controller.hosts) { host in
                    Text(host.name)
                        .tag(IDELanguageRunSelection.Target.remote(hostID: host.id, hostName: host.name))
                }
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

    private var availabilitySection: some View {
        Section(IDELanguageRunText.t("可用性", "Availability")) {
            if let mechanism = controller.plan.mechanism {
                LabeledContent(IDELanguageRunText.t("方式", "Mechanism")) {
                    Text(IDELanguageRunText.mechanism(mechanism))
                }
                if mechanism.isCrossCompile {
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
            Text(IDELanguageRunText.t("每个参数单独加引号，绝不拼接原始字符串。",
                                      "Every argument is quoted individually; raw strings are never concatenated."))
                .font(.caption2).foregroundStyle(.secondary)
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
