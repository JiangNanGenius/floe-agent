import Foundation
import Combine
import FloeCore
import FloeModels
import FloePersistence
import FloeEnvironments
import FloeExecution
import FloeTools
import FloeSSH
import FloeSkills

struct TaskExecutionAvailabilityError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class TaskExecutionEnvironmentCenter: ObservableObject {
    struct Choice: Identifiable, Equatable {
        enum Kind: Equatable { case linux, mac, ssh(UUID) }
        var id: String
        var name: String
        var kind: Kind
        var symbol: String { switch kind { case .linux: "shippingbox"; case .mac: "desktopcomputer"; case .ssh: "network" } }
    }
    struct Snapshot {
        var binding: TaskExecutionBinding?
        var migration: TaskEnvironmentMigration?
        var choices: [Choice] = []
        var fileCount = 0
        var fileBytes: Int64 = 0
        var unavailableSkills: [String] = []
        var failure: String?
        var checking = false
        var preview: SkillMigrationPreview?
        var selectedChoiceID: String?
        var legacyChoices: [TaskExecutionTarget] = []
    }
    @Published private(set) var snapshots: [UUID: Snapshot] = [:]
    private unowned let environment: AppEnvironment
    private var checkedChoices: [UUID: (choiceID: String, preview: SkillMigrationPreview, requiredSkills: Set<String>)] = [:]
    private var checks: [UUID: UUID] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var cancellations: [UUID: CancellationToken] = [:]
    private let store: TaskExecutionBindingStore
    let mirror: TaskWorkspaceMirror

    init(environment: AppEnvironment) {
        self.environment = environment
        store = TaskExecutionBindingStore(database: environment.database)
        mirror = environment.taskWorkspaceMirror
    }
    func isMigrating(_ conversationID: UUID) -> Bool { jobs[conversationID] != nil }

    func choices() async throws -> [Choice] {
        var result = [Choice(id: "local", name: copy("本机运行环境", "On-device environment"), kind: .linux)]
        if MacBridgeConnectionCenter.isMac {
            result.append(Choice(id: "mac", name: copy("这台 Mac", "This Mac"), kind: .mac))
        }
        for host in try await environment.remoteHostStore.hosts() where host.isRemoteExecutionEnvironment ?? true {
            guard let auth = try? JSONDecoder().decode(SSHAuthMethod.self, from: Data(host.authJSON.utf8)), auth != .none else { continue }
            result.append(Choice(id: host.id.uuidString, name: host.displayName, kind: .ssh(host.id)))
        }
        return result
    }

    func load(_ conversationID: UUID) async {
        var value = snapshots[conversationID] ?? Snapshot(); value.checking = true
        snapshots[conversationID] = value
        do {
            value.choices = try await choices()
            value.binding = try await store.binding(conversationID: conversationID)
            value.migration = try await store.activeMigration(conversationID: conversationID)
            if var interrupted = value.migration, jobs[conversationID] == nil,
               !interrupted.phase.isCommitted, interrupted.phase != .failed {
                interrupted.phase = .failed
                interrupted.failure = copy("准备已暂停，可重试或取消迁移。", "Preparation paused. Retry or cancel this move.")
                value.migration = try await store.update(interrupted, expectedRevision: interrupted.revision)
            }
            value.failure = value.migration?.failure ?? value.failure
            if value.binding == nil {
                value.legacyChoices = await environment.environmentRegistry.containersOwned(by: conversationID.uuidString)
                    .filter { $0.kind == .session && $0.state == .active }.compactMap { try? self.target($0) }
            }
            let lease = try await root(conversationID); defer { lease.release() }
            let files = try TaskWorkspaceMirror.files(root: lease.url)
            value.fileCount = files.count; value.fileBytes = files.reduce(0) { $0 + $1.bytes }
            value.checking = false; snapshots[conversationID] = value
        } catch {
            value.checking = false; value.failure = error.localizedDescription; snapshots[conversationID] = value
        }
    }

    /// Inspect a destination without downloading, starting a VM or staging files.
    func check(conversationID: UUID, choice: Choice) async {
        guard jobs[conversationID] == nil else { return }
        let identity = UUID(); checks[conversationID] = identity
        snapshots[conversationID, default: Snapshot()].checking = true
        snapshots[conversationID, default: Snapshot()].preview = nil
        snapshots[conversationID, default: Snapshot()].selectedChoiceID = choice.id
        checkedChoices[conversationID] = nil
        do {
            try await validateChoicePolicy(choice, conversationID: conversationID)
            let target: SkillRuntimeTarget
            if let existing = try await store.activeMigration(conversationID: conversationID) {
                guard existing.preparationOutcomeUnknown != true, existing.preparationOperationIDs?.isEmpty != false else {
                    throw TaskExecutionAvailabilityError(message: copy("目标上的准备结果尚未确认，请先取消此迁移并检查目标状态。", "Destination preparation has an unknown result. Cancel this move and check the destination first."))
                }
                guard let resolved = await environment.resolveSkillRuntimeTarget(environmentID: existing.target.environmentID, runID: nil) else {
                    throw FloeError.notFound(copy("目标运行位置", "Destination environment"))
                }
                target = resolved
            } else {
                switch choice.kind {
                case .linux:
                    target = .linuxGuest(environmentID: "preview", architecture: "riscv64", isConnected: environment.linuxGuestService != nil)
                case .mac:
                    target = .macBridge(environmentID: "preview", isConnected: await MacBridgeClient.shared.isConnected())
                case .ssh(let host):
                    let facts = try await inspectRemote(host)
                    target = .remoteSSH(environmentID: "preview", remoteHostID: host, remoteRootPath: facts.home,
                        operatingSystem: facts.system == "macos" ? .macOS : .linux, architecture: facts.architecture,
                        distribution: facts.distribution, runtimeGeneration: facts.generation, isConnected: true)
                }
            }
            let required = try await environment.requiredMigrationSkills(conversationID: conversationID)
            let preview = await environment.skillsCenter.migrationPreview(target: target, requiredSkillIDs: required)
            guard checks[conversationID] == identity else { return }
            checkedChoices[conversationID] = (choice.id, preview, required)
            snapshots[conversationID, default: Snapshot()].preview = preview
            snapshots[conversationID, default: Snapshot()].failure = nil
        } catch {
            guard checks[conversationID] == identity else { return }
            snapshots[conversationID, default: Snapshot()].failure = error.localizedDescription
        }
        guard checks[conversationID] == identity else { return }
        snapshots[conversationID, default: Snapshot()].checking = false
    }

    func selectPrevious(conversationID: UUID, environmentID: String) async {
        snapshots[conversationID, default: Snapshot()].failure = nil
        do {
            guard jobs[conversationID] == nil, try await store.binding(conversationID: conversationID) == nil,
                  let record = await environment.environmentRegistry.record(id: environmentID),
                  record.kind == .session, record.ownerID == conversationID.uuidString else {
                throw FloeError.validationFailed(copy("原运行位置已变化，请刷新。", "The previous environment changed. Refresh to continue."))
            }
            _ = try await store.bindInitial(TaskExecutionBinding(conversationID: conversationID, target: target(record)))
        } catch { snapshots[conversationID, default: Snapshot()].failure = error.localizedDescription }
        await load(conversationID)
    }

    /// Called before any executable tool. Existing run/task pins beat all later defaults.
    func resolveBinding(conversationID: UUID, runID: UUID, root: URL,
                        workspace: WorkspaceRecord?, override: String? = nil) async throws -> TaskExecutionBinding {
        if let migration = try await store.activeMigration(conversationID: conversationID), !migration.phase.isCommitted {
            throw FloeError.validationFailed(copy("请先完成或取消此任务的迁移。", "Finish or cancel this task’s move before continuing."))
        }
        if let run = try await environment.runStore.run(id: runID), let pin = run.executionBinding {
            try await validate(pin.target)
            return pin
        }
        if let pin = try await store.binding(conversationID: conversationID) {
            if let override, override != pin.target.environmentID {
                throw FloeError.validationFailed(copy("计划与任务的运行位置不同，请先迁移任务。", "The plan and task use different environments. Move the task first."))
            }
            try await validate(pin.target); if try await environment.runStore.run(id: runID) != nil { try await store.pinRun(runID: runID, binding: pin) }; return pin
        }
        let target: TaskExecutionTarget
        if let override {
            guard let record = await environment.environmentRegistry.record(id: override) else { throw FloeError.notFound("Execution environment") }
            if record.kind == .session, record.ownerID != conversationID.uuidString {
                // Scheduled occurrences preserve the frozen machine, while owning a distinct session.
                let kind: Choice.Kind
                switch record.effectiveExecutionBackend {
                case .linuxVM: kind = .linux
                case .macBridge: kind = .mac
                case .remoteSSH:
                    guard let host = record.remoteHostID else { throw FloeError.notFound("Scheduled host") }
                    kind = .ssh(host)
                case .native: throw FloeError.validationFailed("The scheduled execution environment needs an update")
                }
                target = try await prepareTarget(Choice(id: record.id, name: "", kind: kind), conversationID: conversationID, root: root, fresh: false)
            } else { target = try self.target(record) }
        } else {
            let existing = await environment.environmentRegistry.containersOwned(by: conversationID.uuidString)
                .filter { $0.kind == .session && $0.state == .active }
            if existing.count == 1 { target = try self.target(existing[0]) }
            else if existing.count > 1 {
                throw TaskExecutionAvailabilityError(message: copy("此任务有多个旧运行位置，请在任务菜单中选择运行位置。", "This task has more than one saved environment. Choose its location in the task menu."))
            } else {
                let preferred: Choice
                if case .host(let id) = workspace?.activeTarget {
                    preferred = Choice(id: id.uuidString, name: "", kind: .ssh(id))
                } else if case .host(let id) = environment.settingsCenter.execution.target {
                    preferred = Choice(id: id.uuidString, name: "", kind: .ssh(id))
                } else if MacBridgeConnectionCenter.isMac, MacBridgeRoutingPreferences.preferMacForNewTasks,
                          await MacBridgeClient.shared.hasPairing() {
                    preferred = Choice(id: "mac", name: "", kind: .mac)
                } else { preferred = Choice(id: "local", name: "", kind: .linux) }
                target = try await prepareTarget(preferred, conversationID: conversationID, root: root, fresh: false)
            }
        }
        let pin = try await store.bindInitial(TaskExecutionBinding(conversationID: conversationID, target: target))
        try await validate(pin.target)
        if try await environment.runStore.run(id: runID) != nil { try await store.pinRun(runID: runID, binding: pin) }
        return pin
    }

    func target(_ record: ContainerRecord) throws -> TaskExecutionTarget {
        let backend: TaskExecutionTarget.Backend
        switch record.effectiveExecutionBackend {
        case .linuxVM: backend = .linuxVM
        case .macBridge: backend = .macBridge
        case .remoteSSH: backend = .remoteSSH
        case .native: throw FloeError.validationFailed(copy("请先选择可用的运行环境。", "Choose an available execution environment first."))
        }
        return TaskExecutionTarget(environmentID: record.id, backend: backend,
            remoteHostID: record.remoteHostID, remoteRootPath: record.remoteRootPath,
            operatingSystem: record.operatingSystem ?? (backend == .linuxVM ? "linux" : backend == .macBridge ? "macos" : "unknown"),
            architecture: record.architecture ?? (backend == .linuxVM ? "riscv64" : backend == .macBridge ? "arm64" : "unknown"),
            runtimeGeneration: record.runtimeGeneration)
    }

    private func validate(_ target: TaskExecutionTarget) async throws {
        guard let record = await environment.environmentRegistry.record(id: target.environmentID),
              record.state == .active, !record.requiresRebuild,
              try self.sameIdentity(self.target(record), target) else {
            throw TaskExecutionAvailabilityError(message: copy("原运行位置不可用，请重新连接或迁移任务。", "The saved environment is unavailable. Reconnect or move this task."))
        }
    }

    private func sameIdentity(_ first: TaskExecutionTarget, _ second: TaskExecutionTarget) -> Bool {
        var first = first, second = second
        first.runtimeGeneration = nil; second.runtimeGeneration = nil
        return first == second
    }

    func prepareTarget(_ choice: Choice, conversationID: UUID, root: URL, fresh: Bool) async throws -> TaskExecutionTarget {
        let registry = environment.environmentRegistry
        try await validateChoicePolicy(choice, conversationID: conversationID)
        let workspaceID = FloeDigest.sha256Hex(Data(root.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
        let record: ContainerRecord
        switch choice.kind {
        case .linux:
            record = try await registry.ensureSessionContainer(conversationID: conversationID.uuidString,
                workspaceID: workspaceID, workspaceRootPath: root.path, executionBackend: .linuxVM, forceNew: fresh)
        case .mac:
            guard await MacBridgeClient.shared.isConnected() else { throw TaskExecutionAvailabilityError(message: copy("请先连接这台 Mac。", "Connect this Mac first.")) }
            record = try await registry.ensureMacBridgeSessionContainer(conversationID: conversationID.uuidString,
                workspaceID: workspaceID, workspaceRootPath: root.path, forceNew: fresh)
        case .ssh(let hostID):
            let facts = try await inspectRemote(hostID)
            let path = facts.home + "/.floe/tasks/" + conversationID.uuidString.lowercased() + "/" + UUID().uuidString.lowercased()
            record = try await registry.ensureRemoteSessionContainer(conversationID: conversationID.uuidString,
                workspaceID: workspaceID, workspaceRootPath: root.path, hostID: hostID, remoteRootPath: path,
                operatingSystem: facts.system, architecture: facts.architecture,
                distribution: facts.distribution, runtimeGeneration: facts.generation, forceNew: fresh)
        }
        return try target(record)
    }

    private func validateChoicePolicy(_ choice: Choice, conversationID: UUID) async throws {
        if case .ssh = choice.kind,
           try await SQLiteWorkspaceStore(database: environment.database).taskPolicy(conversationID: conversationID).remoteExecutionAllowed == false {
            throw TaskExecutionAvailabilityError(message: copy("此任务已关闭远程执行，请先在权限中开启。", "Remote execution is disabled for this task. Enable it in permissions first."))
        }
    }

    private struct RemoteFacts {
        var home: String; var system: String; var architecture: String
        var distribution: String?; var generation: String
    }
    private func inspectRemote(_ hostID: UUID) async throws -> RemoteFacts {
        let probe: SSHExecResult
        do { probe = try await environment.sshCommandService.run(command: "uname -s; uname -m; printf 'FLOE_HOME='; (cd \"$HOME\" && pwd -P); (cat /etc/os-release 2>/dev/null || true); printf 'FLOE_BOOT='; (cat /proc/sys/kernel/random/boot_id 2>/dev/null || sysctl -n kern.boottime 2>/dev/null || true)",
            hostID: hostID, timeout: 15, maxOutputBytes: 16 * 1024) }
        catch { throw TaskExecutionAvailabilityError(message: copy("无法连接选定的远程电脑，请重新连接。", "The selected remote computer is unavailable. Reconnect to continue.")) }
        let lines = probe.stdout.components(separatedBy: .newlines)
        guard probe.exitCode == 0, !probe.truncated, lines.count >= 3,
              ["Linux", "Darwin"].contains(lines[0]),
              let home = lines.first(where: { $0.hasPrefix("FLOE_HOME=") }).map({ String($0.dropFirst(10)) }),
              home.hasPrefix("/"), !home.contains(".."), !home.contains("\0"),
              let generation = lines.first(where: { $0.hasPrefix("FLOE_BOOT=") }).map({ String($0.dropFirst(10)) }), !generation.isEmpty else {
            throw TaskExecutionAvailabilityError(message: copy("无法确认远端的运行环境。", "The remote environment could not be identified."))
        }
        return RemoteFacts(home: home, system: lines[0] == "Darwin" ? "macos" : "linux", architecture: lines[1],
            distribution: lines.first { $0.hasPrefix("ID=") }.map { String($0.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }, generation: generation)
    }

    private func root(_ conversationID: UUID) async throws -> WorkspaceCenter.TaskRootLease {
        guard let conversation = try await environment.conversationStore.conversation(id: conversationID), conversation.purpose == .ordinary else {
            throw FloeError.validationFailed(copy("请选择普通任务。", "Choose a saved task."))
        }
        let store = SQLiteWorkspaceStore(database: environment.database)
        let record = try await store.ensureWorkspace(conversationID: conversationID, title: conversation.title)
        return try await environment.workspaceCenter.acquireTaskRoot(record, conversationID: conversationID)
    }

    func start(conversationID: UUID, choice: Choice, acceptCapabilityLosses: Bool = false) {
        guard jobs[conversationID] == nil else { return }
        guard let checked = checkedChoices[conversationID], checked.choiceID == choice.id,
              checked.preview.canProceed, !checked.preview.requiresExplicitAcceptance || acceptCapabilityLosses else {
            snapshots[conversationID, default: Snapshot()].failure = copy("请先检查目标位置并确认变化。", "Check the destination and confirm its changes first.")
            return
        }
        snapshots[conversationID, default: Snapshot()].failure = nil
        let token = CancellationToken(); cancellations[conversationID] = token
        jobs[conversationID] = Task { [weak self] in
            guard let self else { return }
            defer { self.jobs[conversationID] = nil; self.cancellations[conversationID] = nil; self.objectWillChange.send() }
            await self.performMigration(conversationID: conversationID, choice: choice, acceptedLosses: checked.preview.optionalCapabilityLosses, cancellation: token)
        }
    }
    /// Reconnection after the atomic commit never re-enters preparation.
    func resumeCommitted(conversationID: UUID) {
        guard jobs[conversationID] == nil else { return }
        let token = CancellationToken(); cancellations[conversationID] = token
        jobs[conversationID] = Task { [weak self] in
            guard let self else { return }
            defer { self.jobs[conversationID] = nil; self.cancellations[conversationID] = nil; self.objectWillChange.send() }
            do {
                guard let value = try await self.store.activeMigration(conversationID: conversationID), value.phase == .committed else { return }
                await self.performMigration(conversationID: conversationID,
                    choice: Choice(id: "reconnect", name: "", kind: .linux), acceptedLosses: value.acceptedCapabilityLosses ?? [], cancellation: token)
            } catch { self.snapshots[conversationID, default: Snapshot()].failure = error.localizedDescription }
        }
    }

    func cancel(_ conversationID: UUID) {
        cancellations[conversationID]?.cancel()
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let value = try await self.store.requestCancellation(conversationID: conversationID), !value.phase.isCommitted else { return }
                self.publish(value)
                if self.jobs[conversationID] == nil {
                    let token = CancellationToken(); token.cancel()
                    self.cancellations[conversationID] = token
                    self.jobs[conversationID] = Task { [weak self] in
                        guard let self else { return }
                        defer { self.jobs[conversationID] = nil; self.cancellations[conversationID] = nil; self.objectWillChange.send() }
                        let choice = Choice(id: "cancel", name: "", kind: .linux)
                        await self.performMigration(conversationID: conversationID, choice: choice, acceptedLosses: [], cancellation: token)
                    }
                }
            } catch { self.snapshots[conversationID, default: Snapshot()].failure = error.localizedDescription }
        }
    }

    private func performMigration(conversationID: UUID, choice: Choice, acceptedLosses: [String], cancellation: CancellationToken) async {
        var fencedSource: String?
        var migration: TaskEnvironmentMigration?
        do {
            let lease = try await root(conversationID); defer { lease.release() }
            if let previous = try await store.activeMigration(conversationID: conversationID) {
                migration = previous
            } else {
                guard let source = try await store.binding(conversationID: conversationID) else {
                    let previous = await environment.environmentRegistry.containersOwned(by: conversationID.uuidString).filter { $0.kind == .session }
                    guard previous.isEmpty else {
                        throw FloeError.validationFailed(copy("请选择上次使用的运行位置。", "Choose the previous execution location first."))
                    }
                    let initial = try await prepareTarget(choice, conversationID: conversationID, root: lease.url, fresh: false)
                    let saved = try await store.bindInitial(TaskExecutionBinding(conversationID: conversationID, target: initial))
                    guard saved.target == initial else { throw FloeError.validationFailed(copy("任务已选择其他运行位置，请刷新。", "Another location was selected for this task. Refresh to continue.")) }
                    await load(conversationID)
                    return
                }
                let target = try await prepareTarget(choice, conversationID: conversationID, root: lease.url, fresh: true)
                guard target.environmentID != source.target.environmentID else {
                    throw FloeError.validationFailed(copy("此任务已在该位置。", "This task already uses that location."))
                }
                migration = TaskEnvironmentMigration(source: source, target: target)
                migration?.acceptedCapabilityLosses = acceptedLosses
                try await store.begin(migration!)
            }
            guard var value = migration else { return }
            if !value.phase.isCommitted {
                if value.cancellationRequested == true { throw CancellationError() }
                guard value.preparationOutcomeUnknown != true, value.preparationOperationIDs?.isEmpty != false else {
                    throw FloeError.validationFailed(copy("目标上的准备结果尚未确认。请先取消此迁移，核对目标状态后再开始。", "Destination preparation has an unknown result. Cancel this move, check the destination, then start again."))
                }
                try cancellation.throwIfCancelled()
                value.phase = .waiting; value.failure = nil; value = try await store.update(value, expectedRevision: value.revision)
                migration = value; publish(value)
                // Live processes/PTYs cannot migrate. Existing Stop remains the way to end them.
                try await environment.waitForTaskEnvironmentSafePoint(conversationID: conversationID,
                    environmentID: value.source.target.environmentID, cancellation: cancellation)
                fencedSource = value.source.target.environmentID
                try cancellation.throwIfCancelled()
                value.phase = .preparing; value = try await store.update(value, expectedRevision: value.revision)
                migration = value; publish(value)
                if value.source.target.backend == .remoteSSH {
                    guard let sourceTarget = await environment.resolveSkillRuntimeTarget(environmentID: value.source.target.environmentID, runID: nil), sourceTarget.isConnected else {
                        throw TaskExecutionAvailabilityError(message: copy("无法确认原运行位置，请重新连接后重试。", "The original environment could not be verified. Reconnect and try again."))
                    }
                }
                try await environment.synchronizeExecutionTarget(value.source.target, root: lease.url, cancellation: cancellation)
                try await environment.prepareExecutionTarget(value.target, cancellation: cancellation)
                let required = try await environment.requiredMigrationSkills(conversationID: conversationID)
                guard let runtimeTarget = await environment.resolveSkillRuntimeTarget(environmentID: value.target.environmentID, runID: nil) else {
                    throw FloeError.notFound(copy("目标运行位置", "Destination environment"))
                }
                let preview = await environment.skillsCenter.migrationPreview(target: runtimeTarget, requiredSkillIDs: required)
                guard preview.canProceed, Set(preview.optionalCapabilityLosses) == Set(acceptedLosses) else {
                    throw FloeError.validationFailed(copy("可用技能或依赖发生变化，请重新检查目标位置。", "Available skills or dependencies changed. Check the destination again."))
                }
                let skillPins = Dictionary(uniqueKeysWithValues: try await environment.skillStore.all().filter { $0.status == "enabled" }.map { ($0.id, $0.rewrittenDigest) })
                let files = try await environment.synchronizeExecutionTarget(value.target, root: lease.url, cancellation: cancellation)
                let targetLease = try await environment.executionManagementLease(value.target.environmentID, cancellation: cancellation)
                do {
                    guard let toolEnvironment = targetLease.context.environment else { throw FloeError.notFound("Target environment") }
                    let staging = await environment.skillsCenter.stageMigrationSkillResources(migrationID: value.id,
                        target: runtimeTarget, toolEnvironment: toolEnvironment,
                        resourceContext: SkillResourceContext(environmentID: value.target.environmentID, workspaceRootURL: lease.url, cancellation: cancellation))
                    guard staging.failureReason == nil, staging.unavailableCount == 0, staging.skillDigests == skillPins else {
                        throw FloeError.validationFailed(copy("技能文件尚未准备好，请重试。", "Skill files are not ready. Try again."))
                    }
                    value.dependencyReceiptDigest = try await environment.prepareMigratedSkillDependencies(target: value.target,
                        migrationID: value.id, skillIDs: required, cancellation: cancellation)
                    await targetLease.finish()
                } catch { await targetLease.finish(); throw error }
                // Native preparation records each dispatch/terminal outcome
                // in the ledger. Join its latest revision before the CAS.
                if let latest = try await store.activeMigration(conversationID: conversationID), latest.id == value.id {
                    value.revision = latest.revision
                    value.cancellationRequested = latest.cancellationRequested
                    value.preparationOutcomeUnknown = latest.preparationOutcomeUnknown
                    value.preparationOperationIDs = latest.preparationOperationIDs
                } else { throw FloeError.validationFailed(copy("迁移状态已变化，请刷新。", "The move changed. Refresh to continue.")) }
                value.requiredSkillIDs = required.sorted()
                value.skillDigests = skillPins
                let currentSkillPins = Dictionary(uniqueKeysWithValues: try await environment.skillStore.all().filter { $0.status == "enabled" }.map { ($0.id, $0.rewrittenDigest) })
                guard currentSkillPins == skillPins else { throw FloeError.validationFailed(copy("技能在准备期间发生变化，请重新检查。", "Skills changed during preparation. Check them again.")) }
                try cancellation.throwIfCancelled()
                value.phase = .verifying; value.preparedFileCount = files.count
                value.preparedBytes = files.reduce(0) { $0 + $1.bytes }
                value = try await store.update(value, expectedRevision: value.revision); migration = value; publish(value)
                let current = try TaskWorkspaceMirror.files(root: lease.url, cancellation: cancellation)
                guard current == files else { throw FloeError.validationFailed(copy("文件在准备期间发生变化，请重试。", "Files changed during preparation. Try again.")) }
                let manifestEncoder = JSONEncoder(); manifestEncoder.outputFormatting = [.sortedKeys]
                value.manifestDigest = FloeDigest.sha256Hex(try manifestEncoder.encode(current))
                value.phase = .verified; value = try await store.update(value, expectedRevision: value.revision)
                migration = value; publish(value)
                try cancellation.throwIfCancelled()
                value = try await store.commit(value); migration = value; publish(value)
            }
            // A post-commit retry only reconnects. It never recopies the source or commits twice.
            try await validate(value.target)
            try await environment.prepareExecutionTarget(value.target, cancellation: cancellation)
            let notice = try await environment.environmentMigrationNotice(value.target)
            value = try await store.finish(value, notice: notice)
            migration = value; publish(value)
        } catch {
            if var value = migration {
                do {
                    if let latest = try await store.activeMigration(conversationID: conversationID), latest.id == value.id { value = latest }
                    let stopping = cancellation.isCancelled || error is CancellationError || value.cancellationRequested == true
                    if !value.phase.isCommitted {
                        if stopping {
                            value.cancellationRequested = true
                            if value.preparationOutcomeUnknown == true || value.preparationOperationIDs?.isEmpty == false {
                                // Preserve a possibly active install's files.
                                // A new attempt gets a fresh owned directory.
                                value.phase = .cancelled
                                value.failure = copy("迁移已取消。目标操作的结果尚未确认，准备文件已保留。", "Move cancelled. The destination operation’s result is unknown, so its preparation files were kept.")
                            } else { do {
                                try await cleanupCancelledTarget(value)
                                value.phase = .cancelled; value.failure = nil
                            } catch {
                                value.phase = .failed
                                value.failure = copy("迁移已停止，目标上的准备文件尚未清理。重新连接后重试取消。", "The move stopped. Destination preparation files are retained. Reconnect and retry cancellation.")
                            } }
                        } else { value.phase = .failed; value.failure = error.localizedDescription }
                    } else { value.failure = error.localizedDescription }
                    value = try await store.update(value, expectedRevision: value.revision)
                    migration = value; publish(value)
                } catch { snapshots[conversationID, default: Snapshot()].failure = error.localizedDescription }
            } else { snapshots[conversationID, default: Snapshot()].failure = error.localizedDescription }
        }
        if let fencedSource { await environment.releaseExecutionMigrationFence(fencedSource) }
        if let migration { _ = environment.skillsCenter.releaseMigrationResources(migrationID: migration.id) }
        await load(conversationID)
    }

    private func cleanupCancelledTarget(_ value: TaskEnvironmentMigration) async throws {
        // A target was created solely for this ledger. Never touch the source,
        // the canonical App files or a target that has already been committed.
        guard !value.phase.isCommitted, value.target.environmentID != value.source.target.environmentID else { return }
        guard try await store.binding(conversationID: value.source.conversationID)?.target.environmentID != value.target.environmentID else {
            throw FloeError.validationFailed(copy("目标仍被任务使用。", "The task still uses this destination."))
        }
        guard let record = await environment.environmentRegistry.record(id: value.target.environmentID) else { return }
        guard record.kind == .session, record.ownerID == value.source.conversationID.uuidString,
              await environment.executionLeaseCount(record.id) == 0 else {
            throw FloeError.validationFailed(copy("目标仍在使用中。", "The destination is still in use."))
        }
        if value.target.backend == .remoteSSH {
            let target = try await environment.remoteShellTarget(value.target)
            try await mirror.removeOwnedTarget(target: target, cancellation: CancellationToken())
        }
        // Mac workspace files are shared with this saved task; only the new
        // metadata/layer is disposable. The bridge workspace remains intact.
        try await FloePlatformServices.shared.deleteEnvironment(id: value.target.environmentID)
    }

    private func publish(_ migration: TaskEnvironmentMigration) {
        var state = snapshots[migration.source.conversationID] ?? Snapshot()
        state.migration = migration; state.failure = migration.failure
        snapshots[migration.source.conversationID] = state
    }
    private func copy(_ zh: String, _ en: String) -> String { IDELanguageRunText.t(zh, en) }
}
