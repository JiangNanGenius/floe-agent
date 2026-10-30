import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeEnvironments
import FloeExecution
import FloeTools
import FloeSkills
import FloeAgentRuntime

enum TaskTargetOperationFailure: Error { case outcomeUnknown(String) }

extension AppEnvironment {
    func resolveSkillRuntimeTarget(environmentID: String, runID: UUID?) async -> SkillRuntimeTarget? {
        guard let record = await environmentRegistry.record(id: environmentID), record.state == .active, !record.requiresRebuild else { return nil }
        switch record.effectiveExecutionBackend {
        case .native: return .appNative(runID: runID)
        case .linuxVM:
            let generation = await linuxGuestService?.runtimeStates().first { $0.environmentID == environmentID && $0.running }?.identity.launchGeneration
            return SkillRuntimeTarget(runID: runID, environmentID: environmentID, operatingSystem: .linux,
                architectures: ["riscv64"], backend: .linuxVM, distribution: "debian",
                launchGeneration: generation, isConnected: linuxGuestService != nil, resolution: .resolved)
        case .macBridge:
            return .macBridge(environmentID: environmentID, runID: runID,
                architecture: record.architecture ?? "arm64", runtimeGeneration: record.runtimeGeneration,
                isConnected: await MacBridgeClient.shared.isConnected())
        case .remoteSSH:
            guard let host = record.remoteHostID, let root = record.remoteRootPath,
                  let system = record.operatingSystem, let architecture = record.architecture else { return nil }
            var connected = false, generation = record.runtimeGeneration
            if let owner = record.ownerID.flatMap(UUID.init(uuidString:)),
               (try? await SQLiteWorkspaceStore(database: database).taskPolicy(conversationID: owner))?.remoteExecutionAllowed == false {
                return .remoteSSH(environmentID: environmentID, runID: runID, remoteHostID: host,
                    remoteRootPath: root, operatingSystem: system == "macos" ? .macOS : system == "linux" ? .linux : .unknown,
                    architecture: architecture, distribution: record.distribution, runtimeGeneration: generation, isConnected: false)
            }
            do {
                let result = try await sshCommandService.run(command: "uname -s; uname -m; printf 'FLOE_BOOT='; (cat /proc/sys/kernel/random/boot_id 2>/dev/null || sysctl -n kern.boottime 2>/dev/null || true)",
                    hostID: host, timeout: 8, maxOutputBytes: 4096)
                let lines = result.stdout.components(separatedBy: .newlines)
                connected = result.exitCode == 0 && !result.truncated && lines.count >= 2
                    && (lines[0] == "Darwin" ? "macos" : lines[0].lowercased()) == system
                    && SkillRuntimeTarget.normalizeArchitecture(lines[1]) == SkillRuntimeTarget.normalizeArchitecture(architecture)
                if connected, let boot = lines.first(where: { $0.hasPrefix("FLOE_BOOT=") }) {
                    generation = String(boot.dropFirst(10))
                    try await environmentRegistry.updateRuntimeGeneration(id: environmentID, generation: generation)
                }
            } catch { connected = false }
            return .remoteSSH(environmentID: environmentID, runID: runID, remoteHostID: host,
                remoteRootPath: root, operatingSystem: system == "macos" ? .macOS : system == "linux" ? .linux : .unknown,
                architecture: architecture, distribution: record.distribution, runtimeGeneration: generation, isConnected: connected)
        }
    }

    func remoteShellTarget(_ target: TaskExecutionTarget) async throws -> SSHShellTarget {
        guard target.backend == .remoteSSH, let host = target.remoteHostID, let path = target.remoteRootPath,
              let record = await environmentRegistry.record(id: target.environmentID), record.state == .active else {
            throw FloeError.validationFailed(IDELanguageRunText.t("运行位置不可用。", "The execution location is unavailable."))
        }
        guard let boot = record.runtimeGeneration, !boot.isEmpty else {
            throw FloeError.validationFailed(IDELanguageRunText.t("请重新连接以确认远端状态。", "Reconnect to verify the remote environment."))
        }
        let epoch = boot + ":" + target.environmentID
        guard let result = SSHShellTarget(hostID: host, remoteTaskRoot: path, environmentID: target.environmentID, generation: epoch) else {
            throw FloeError.validationFailed("Invalid remote workspace")
        }
        return result
    }

    @discardableResult
    func synchronizeExecutionTarget(_ target: TaskExecutionTarget, root: URL, cancellation: CancellationToken) async throws -> [TaskWorkspaceFile] {
        try cancellation.throwIfCancelled()
        switch target.backend {
        case .linuxVM:
            // /workspace is the existing task-owned host share, not a new copy of the guest disk.
            return try TaskWorkspaceMirror.files(root: root, cancellation: cancellation)
        case .macBridge:
            // Before performs the existing three-way reconciliation and pulls
            // Mac-only changes. Pulling first would reject a local-only edit.
            _ = try await MacBridgeClient.shared.synchronizeBeforeExecution(root: root)
            return try TaskWorkspaceMirror.files(root: root, cancellation: cancellation)
        case .remoteSSH:
            let resolved = try await remoteShellTarget(target)
            return try await taskWorkspaceMirror.synchronize(target: resolved, root: root, cancellation: cancellation)
        }
    }

    /// Returns with the source external executor fenced. The migration owner releases it.
    func waitForTaskEnvironmentSafePoint(conversationID: UUID, environmentID: String, cancellation: CancellationToken) async throws {
        let jobs = SQLiteBackgroundJobStore(database: database)
        while true {
            try cancellation.throwIfCancelled(); try Task.checkCancellation()
            let runs = try await runStore.runs(conversationID: conversationID)
            let live = runs.contains { conversationCenter.hasLiveOwnerForEnvironmentMigration(runID: $0.id) }
            let children = try await SQLiteChildRunStore(database: database).children(conversationID: conversationID)
            let externalJobs = try await jobs.activeJobs(environmentID: environmentID).filter {
                $0.kind == .tool && CapabilityExecutionRouter.decision(for: $0.targetTool).backend != .nativeApple
            }
            if !live, !children.contains(where: { !$0.state.isTerminal }), externalJobs.isEmpty {
                // Recheck persistent owners AFTER the foreground run has exited;
                // it may have started a server while we were waiting.
                await mcpServiceCreationCoordinator.load()
                for record in mcpServiceCreationCoordinator.records where record.request.environmentID == environmentID {
                    if record.phase.isProcessing {
                        throw FloeError.validationFailed(IDELanguageRunText.t("先结束正在准备的 MCP 服务，再迁移。", "Finish preparing the MCP service before moving this task."))
                    }
                    if [.ready, .added].contains(record.phase) {
                        // Added is a saved-connection state, not proof that a
                        // process remains alive. Read the actual service job.
                        guard let id = record.serviceJobID, let job = try await jobs.job(id: id), job.state.isTerminal else {
                            throw FloeError.validationFailed(IDELanguageRunText.t("先停止此任务的 MCP 服务，再迁移。", "Stop this task’s MCP service before moving it."))
                        }
                    }
                }
                guard await shellSessionCenter.activeSessionCount(environmentID: environmentID) == 0,
                    (await linuxGuestService?.activeLocalServiceCount(environmentID: environmentID) ?? 0) == 0 else {
                    throw FloeError.validationFailed(IDELanguageRunText.t("先关闭此任务的终端、网页和 MCP 服务，再迁移。", "Close this task’s terminals, web and MCP services before moving it."))
                }
                let childStore = SQLiteChildRunStore(database: database)
                for child in children where child.state != .completed && child.state != .cancelled {
                    if let checkpoint = try await childStore.checkpoint(childRunID: child.id) {
                        let unpaired = checkpoint.pendingCalls.contains { call in
                            CapabilityExecutionRouter.decision(for: call.toolName).backend != .nativeApple
                                && !checkpoint.pendingSettled.contains(where: { $0.call.id == call.id })
                        }
                        let uncertain = checkpoint.pendingSettled.contains { pair in
                            pair.result.outcomeUnknown == true
                                && CapabilityExecutionRouter.decision(for: pair.call.toolName).backend != .nativeApple
                        } || checkpoint.replayedPairs.contains { pair in
                            pair.result.outcomeUnknown == true
                                && CapabilityExecutionRouter.decision(for: pair.call.toolName).backend != .nativeApple
                        }
                        guard !unpaired && !uncertain else {
                            throw FloeError.validationFailed(IDELanguageRunText.t("子任务有操作结果尚未确认，请先在原位置恢复或处理。", "A subtask has an unconfirmed operation. Resume or resolve it in the original environment first."))
                        }
                    }
                }
                for run in runs where !["completed", "cancelled"].contains(run.state) {
                    if let checkpoint = try await checkpointStore.load(runID: run.id) {
                        let uncertain = (checkpoint.executionLedgerEntries ?? []).contains {
                            $0.resultFingerprint.hasPrefix("unknown-outcome:") && $0.isSideEffecting != false
                                && CapabilityExecutionRouter.decision(for: $0.toolName).backend != .nativeApple
                        } || (checkpoint.toolLifecycleEntries ?? []).contains {
                            $0.phase == .dispatched && $0.isSideEffecting != false
                                && CapabilityExecutionRouter.decision(for: $0.toolName).backend != .nativeApple
                        }
                        guard !uncertain else {
                            throw FloeError.validationFailed(IDELanguageRunText.t("有操作的执行结果尚未确认。请先核对原运行位置，再迁移。", "An operation’s result is unknown. Check the original environment before moving this task."))
                        }
                    }
                }
                if await fenceExecutionForMigration(environmentID) { return }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Only actual explicitly associated script invocations make a dependency
    /// mandatory for this task; merely installing or reading a guide does not.
    func requiredMigrationSkills(conversationID: UUID) async throws -> Set<String> {
        var result = Set<String>()
        for run in try await runStore.runs(conversationID: conversationID) where !["completed", "cancelled"].contains(run.state) {
            var cursor = 0
            while true {
                let page = try await runStore.events(runID: run.id, afterSequence: cursor, limit: 200)
                guard !page.isEmpty else { break }
                for event in page where event.kind == .toolRequest {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8)) as? [String: Any],
                          object["tool"] as? String == "exec.shell", let input = object["input"] as? String,
                          let args = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any],
                          let id = args["skillID"] as? String, !id.isEmpty else { continue }
                    result.insert(id)
                }
                cursor = page.last!.sequence
            }
        }
        return result
    }

    func runTargetDependencyCommand(_ command: String, environment target: ToolEnvironment, cancellation: CancellationToken?) async throws -> String {
        guard let root = try await environmentRegistry.workspaceRoot(for: target.id) else { throw FloeError.notFound("Task workspace") }
        let token = cancellation ?? CancellationToken()
        let lease = try await executionManagementLease(target.id, cancellation: token)
        var context = lease.context
        context.workspaceRootURL = root
        let result = await localShellService.run(command: command, cwd: ".", environment: [:], stdin: nil,
            requestedTimeout: nil, maxOutputBytes: 128 * 1024, isBackground: false, context: context)
        await lease.finish()
        switch result {
        case .outcome(.exited(let code, let stdout, let stderr, let truncated, let stderrTruncated, _)):
            guard code == 0, !truncated, !stderrTruncated else {
                throw FloeError.validationFailed(IDELanguageRunText.t("依赖准备未完成，请检查目标上的工具、网络和安装权限。", "Dependencies are not ready. Check tools, connectivity and installation permissions on the target."))
            }
            _ = stderr
            return stdout
        case .outcome(.outcomeUnknown(_, let message)):
            if let record = await environmentRegistry.record(id: target.id), let owner = record.ownerID.flatMap(UUID.init(uuidString:)) {
                try await TaskExecutionBindingStore(database: database).recordPreparationOutcomeUnknown(conversationID: owner, targetEnvironmentID: target.id)
            }
            throw TaskTargetOperationFailure.outcomeUnknown(message)
        case .outcome(.cancelled): throw CancellationError()
        default: throw FloeError.validationFailed(IDELanguageRunText.t("目标未完成依赖准备。", "The target did not complete dependency preparation."))
        }
    }

    func prepareMigratedSkillDependencies(target: TaskExecutionTarget, migrationID: UUID, skillIDs: Set<String>, cancellation: CancellationToken) async throws -> String {
        var verified: [String] = []
        for skill in try await skillStore.all() where skill.status == "enabled" && skillIDs.contains(skill.id) {
            try cancellation.throwIfCancelled()
            // External/no-declaration skills remain model-managed; absence is never a readiness receipt.
            guard await skillsCenter.dependencyAuthorization(skillID: skill.id) != nil else { continue }
            let outcome = await executionDependencyPreparation.prepareForMigration(skillID: skill.id,
                environmentID: target.environmentID, migrationID: migrationID, cancellation: cancellation)
            switch outcome {
            case .verified(let annotation, let requirements):
                verified.append(skill.id + ":" + skill.rewrittenDigest + ":" + annotation + ":" + requirements.map { $0.name + "=" + ($0.version ?? "") }.joined(separator: ","))
            case .refused(let reason, _), .unavailable(let reason):
                throw FloeError.validationFailed(skill.name + ": " + reason)
            }
        }
        return FloeDigest.sha256Hex(Data(verified.sorted().joined(separator: "\n").utf8))
    }

    func externalSkillStageTarget(environmentID: String, root: URL) async -> SkillExternalStageTarget? {
        guard let record = await environmentRegistry.record(id: environmentID), record.state == .active,
              let expectedRoot = try? await environmentRegistry.workspaceRoot(for: environmentID),
              expectedRoot.resolvingSymlinksInPath().standardizedFileURL == root.resolvingSymlinksInPath().standardizedFileURL else { return nil }
        do {
            let target = try taskExecutionEnvironments.target(record)
            switch target.backend {
            case .linuxVM: return nil
            case .macBridge:
                let workspace = try await MacBridgeClient.shared.workspace(root: root)
                return SkillExternalStageTarget(workspaceRoot: root, executionRoot: workspace.path) { _, _, cancellation in
                    try cancellation.throwIfCancelled()
                    _ = try await MacBridgeClient.shared.synchronizeBeforeExecution(root: root)
                    try cancellation.throwIfCancelled()
                }
            case .remoteSSH:
                let sshTarget = try await remoteShellTarget(target)
                return SkillExternalStageTarget(workspaceRoot: root, executionRoot: sshTarget.remoteTaskRoot) { [mirror = taskWorkspaceMirror] local, bundle, cancellation in
                    guard let transfer = SSHShellTarget(hostID: sshTarget.hostID, remoteTaskRoot: bundle.guestRoot,
                        environmentID: sshTarget.environmentID, generation: sshTarget.generation) else { throw FloeError.validationFailed("Skill target path") }
                    let state = root.appendingPathComponent(".floe/remote-sync/\(environmentID)/skills/\(bundle.pinnedSHA256)", isDirectory: true)
                    _ = try await mirror.synchronize(target: transfer, root: local, cancellation: cancellation, stateDirectory: state)
                }
            }
        } catch { return nil }
    }

    func environmentMigrationNotice(_ target: TaskExecutionTarget) async throws -> String {
        let name: String
        if let host = target.remoteHostID {
            name = try await remoteHostStore.host(id: host)?.displayName ?? IDELanguageRunText.t("远程电脑", "Remote computer")
        } else { name = target.backend == .macBridge ? IDELanguageRunText.t("这台 Mac", "This Mac") : IDELanguageRunText.t("本机运行环境", "On-device environment") }
        return IDELanguageRunText.t("已切换到 \(name)，可继续任务。", "Moved to \(name). You can continue the task.")
    }
}
