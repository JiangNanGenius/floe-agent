import Foundation
import BridgeCore

enum BridgeDDIRemovalDispatch: Equatable {
    case started(UInt64)
    case refused(code: String, message: String)
}

enum BridgeDDIStageProbeDispatch: Equatable {
    case started(UInt64)
    case refused(code: String, message: String)
}

enum BridgeStartFlow: Equatable {
    case started(UInt64)
    case waiting(UInt64)
    case resumed(UInt64)
    case rejected(code: String, message: String)
    case ignored
}

enum BridgeCanaryDispatch: Equatable {
    case started(runID: String, generation: UInt64)
    case refused(code: String, message: String)
}

private enum CanaryWaitResult {
    case accepted(BridgeCommandResult, Int)
    case timedOut
    case fenced
    case cancelled
    case failed(code: String, message: String)
}

/// Drives the prototype startup sequence and owns the generation fence.
///
/// Order: observe DDI → (download DDI if missing) → start the app's own tunnel
/// → probe the real debug port → mount the DDI on-device → verify XCTest is
/// readable → dispatch one main-queue `_XCTestMain` → wait for the actual test
/// entry marker. A saved configuration, downloaded file or mounted framework is
/// never reported as engine-ready.
@MainActor
final class BridgeCoordinator {
    private weak var model: BridgeAppModel?
    private let shared = BridgeSharedState.shared
    private let tunnel: BridgeTunnelManager
    private let pairing: BridgePairingStore
    private let ddiStore: BridgeDDIStore
    private let ddiManager: BridgeDDIManager
    /// Service-owned packet-counter sampler. Only the coordinator starts and
    /// stops it around an active DDI probe/mount; no view owns its lifetime.
    private let snapshotSampler: BridgeTunnelSampler

    private var task: Task<Void, Never>?
    private var removalTask: Task<Void, Never>?
    /// Gates shared with the blocking worker threads. Stop records logical
    /// cancellation before a not-yet-entered mutation can run.
    private var mountGate: BridgeDDIMutationGate?
    private var removalGate: BridgeDDIMutationGate?
    private var probeGate: BridgeDDIMutationGate?
    private var generation: UInt64 = 0
    private var mountedByThisApp = false
    /// Covers the whole blocking FFI worker, not only the manager's phase.
    /// Start, mount and remove must all refuse while this is true, including
    /// after Stop has fenced the snapshot but the worker is still returning.
    private var ddiOperationInFlight = false
    /// Service-owned canary state. Only an explicit UI action creates a run;
    /// AutoStart and ordinary Start never touch it.
    private var canaryRun: BridgeCanaryRun?
    private var canaryTask: Task<Void, Never>?

    init(model: BridgeAppModel,
         tunnel: BridgeTunnelManager,
         pairing: BridgePairingStore,
         ddiStore: BridgeDDIStore,
         ddiManager: BridgeDDIManager) {
        self.model = model
        self.tunnel = tunnel
        self.pairing = pairing
        self.ddiStore = ddiStore
        self.ddiManager = ddiManager
        self.snapshotSampler = BridgeTunnelSampler(tunnel: tunnel)
    }

    var isBusy: Bool {
        shared.snapshot().phase.isActive
    }

    /// Exposed for the UI's action enablement; the coordinator still enforces
    /// every guard on the actual action.
    var isDDIWorkerBusy: Bool {
        ddiOperationInFlight || ddiManager.isRunning
    }

    func start(trigger: String) {
        _ = beginStart(trigger: trigger)
    }

    /// Shared entry for an ordinary Start and for the explicit start-and-check
    /// action. It performs the same guards and the same one-shot lifecycle
    /// decision; the canary never dispatches a second bootstrap.
    @discardableResult
    private func beginStart(trigger: String) -> BridgeStartFlow {
        guard let model else {
            return .rejected(code: "unavailable", message: "The host model is unavailable.")
        }
        let before = shared.snapshot()
        if before.terminalFault {
            let code = before.terminalFaultCode ?? "terminal-fault"
            showReopenRequired(code: code)
            return .rejected(code: code, message: reopenRequiredMessage(code))
        }
        if before.engineRunning && before.serviceRunning {
            BridgeLog.shared.append("start_ignored reason=engine-running")
            return .ignored
        }
        if isDDIWorkerBusy {
            let message = BridgeL10n.t(
                "A DDI operation is still running. Wait for it to finish before starting the engine.",
                "DDI 操作仍在进行。请等待其完成后再启动引擎。"
            )
            BridgeLog.shared.append("start_ignored reason=ddi-worker-busy trigger=\(trigger)")
            showBanner(message)
            return .rejected(code: "ddi-worker-busy", message: message)
        }
        if !before.oneShotDispatched &&
            !pairing.isImported && !BridgeDDIProbe.status().mounted {
            shared.withLifecycle { $0.setPairing(imported: false) }
            let message = BridgeL10n.t(
                "Import a RemotePairing file before the first on-device DDI mount.",
                "请先导入 RemotePairing 文件，再进行首次本机 DDI 挂载。"
            )
            showBanner(message)
            return .rejected(code: "pairing-required", message: message)
        }

        let decision = shared.withLifecycle { $0.requestStart(trigger: trigger) }
        switch decision {
        case .started(let startGeneration):
            task?.cancel()
            generation = startGeneration
            try? FileManager.default.removeItem(at: BridgePaths.engineReadyFile)
            BridgeLog.shared.append("coordinator_start trigger=\(trigger) generation=\(startGeneration)")
            model.refresh()
            task = Task { [weak self] in
                guard let self else { return }
                await self.runStart(startGeneration)
            }
            return .started(startGeneration)
        case .waitingForExistingBootstrap(let waitGeneration):
            task?.cancel()
            generation = waitGeneration
            BridgeLog.shared.append("coordinator_wait_existing_bootstrap trigger=\(trigger) generation=\(waitGeneration)")
            model.refresh()
            task = Task { [weak self] in
                guard let self else { return }
                await self.waitForEngineEntry(waitGeneration)
            }
            return .waiting(waitGeneration)
        case .resumed:
            task?.cancel()
            task = nil
            BridgeLog.shared.append("coordinator_resume_from_start trigger=\(trigger)")
            model.banner = nil
            model.refresh()
            return .resumed(shared.snapshot().generation)
        case .reopenRequired(let code):
            task?.cancel()
            task = nil
            BridgeLog.shared.append("coordinator_reopen_required source=start trigger=\(trigger) code=\(code)")
            showReopenRequired(code: code)
            return .rejected(code: code, message: reopenRequiredMessage(code))
        case .ignored:
            if shared.snapshot().phase.isActive {
                showBanner("A start is already in progress.")
            }
            return .ignored
        }
    }

    /// Stop always closes command entrances and cancels cancellable work. It
    /// never waits for, aborts or re-dispatches an already-enqueued XCTest
    /// initializer; a late entry is recorded as an initialized driver and can
    /// be reused by a later Start.
    func stop(trigger: String) {
        tunnel.syncStatus()
        let before = shared.snapshot()
        // Normal Stop closes the owner-armed control entrance before the
        // generation advances. Queued LAN work is fenced; a command already
        // claimed by a dispatcher keeps running and its late result stays
        // late. A later remote start is impossible until the device owner
        // rearms control.
        model?.disarmLANControlForStop()
        task?.cancel()
        mountGate?.cancel()
        probeGate?.cancel()
        task = nil
        // The removal task is cancelled logically. Its staged pairing file and
        // report are released only after the blocking worker actually returns;
        // `runRemoval` owns that cleanup so Stop never frees live FFI inputs.
        // Cancelling the gate is lock-only and never waits for the FFI call.
        removalGate?.cancel()
        removalTask?.cancel()
        ddiStore.cancel()
        cancelCanary(reason: "stop")
        _ = shared.withLifecycle { $0.requestEngineStop(reason: trigger) }
        if tunnel.phase == .connecting || tunnel.phase == .connected {
            tunnel.stop()
        }
        BridgeLog.shared.append(
            "coordinator_stop trigger=\(trigger) driverEntry=\(before.engineEntryObserved) " +
            "oneShotDispatched=\(before.oneShotDispatched) terminalFault=\(before.terminalFault) " +
            "ddiWorkerBusy=\(isDDIWorkerBusy)"
        )
        if before.terminalFault {
            showReopenRequired(code: before.terminalFaultCode ?? "terminal-fault")
            return
        }
        if before.oneShotDispatched && !before.engineEntryObserved {
            model?.banner = "Stopped. If the one-shot initializer completes, its driver will be recorded and a later Start can reuse it."
        }
        model?.refresh()
    }

    func resume(trigger: String) {
        switch shared.withLifecycle({ $0.requestEngineResume() }) {
        case .resumed:
            BridgeLog.shared.append("coordinator_engine_resume trigger=\(trigger)")
            model?.banner = nil
        case .reopenRequired(let code):
            BridgeLog.shared.append("coordinator_reopen_required source=resume trigger=\(trigger) code=\(code)")
            showReopenRequired(code: code)
            return
        case .unavailable:
            showBanner("No initialized engine is available to resume. Quit and reopen the app.")
        }
        model?.refresh()
    }

    // MARK: - Explicit start-and-check canary

    /// The only canary entry point. It attaches a service-owned check to an
    /// ordinary start/resume, waits for the real ready entry for this PID and
    /// generation, then issues existing authenticated file commands serially.
    @discardableResult
    func startAndCheck(trigger: String) -> BridgeCanaryDispatch {
        guard let model else {
            return .refused(code: "unavailable", message: "The host model is unavailable.")
        }
        if let current = canaryRun, current.isLive {
            let message = BridgeL10n.t(
                "A self-check is already running.",
                "自检已在运行中。"
            )
            showBanner(message)
            return .refused(code: "canary-active", message: message)
        }
        if shared.snapshot().engineRunning {
            let message = BridgeL10n.t(
                "Stop the engine before starting a self-check.",
                "请先停止引擎，再启动自检。"
            )
            showBanner(message)
            return .refused(code: "engine-running", message: message)
        }

        let flow = beginStart(trigger: "start-and-check")
        let generation: UInt64
        switch flow {
        case .started(let value), .waiting(let value), .resumed(let value):
            generation = value
        case .rejected(let code, let message):
            return .refused(code: code, message: message)
        case .ignored:
            let message = BridgeL10n.t(
                "The engine is already running or a start is in progress. Stop it before starting a self-check.",
                "引擎已在运行或启动正在进行中。请先停止，再启动自检。"
            )
            showBanner(message)
            return .refused(code: "start-ignored", message: message)
        }

        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let runID = BridgeCanaryRun.makeRunID(
            ownerProcessIdentifier: pid,
            ownerGeneration: generation
        )
        let run = BridgeCanaryRun(
            runID: runID,
            ownerProcessIdentifier: pid,
            ownerGeneration: generation
        )
        canaryTask?.cancel()
        canaryRun = run
        if !BridgeCanaryReportStore.write(run.report) {
            BridgeLog.shared.append("canary_report_write_failed runID=\(runID)")
        }
        model.noteCanary(run.report)
        canaryTask = Task { [weak self] in
            guard let self else { return }
            await self.runCanary(runID: runID, generation: generation)
        }
        BridgeLog.shared.append("canary_start runID=\(runID) generation=\(generation) pid=\(pid)")
        return .started(runID: runID, generation: generation)
    }

    private func currentCanary(_ runID: String) -> BridgeCanaryRun? {
        guard let canaryRun, canaryRun.report.runID == runID else { return nil }
        return canaryRun
    }

    private func persistCanary() {
        guard let canaryRun else { return }
        if !BridgeCanaryReportStore.write(canaryRun.report) {
            BridgeLog.shared.append("canary_report_write_failed runID=\(canaryRun.report.runID)")
        }
        model?.noteCanary(canaryRun.report)
    }

    private func runCanary(runID: String, generation: UInt64) async {
        defer {
            if canaryRun?.report.runID == runID {
                canaryTask = nil
            }
        }
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let entryDeadline = Date().addingTimeInterval(BridgeCanaryPolicy.entryTimeoutSeconds)
        var ready = false
        var markerIssueSince: Date?
        while !Task.isCancelled {
            let decision = BridgeCanaryReadiness.evaluate(
                snapshot: shared.snapshot(),
                readyMarker: BridgeAtomicFile.readJSON(BridgePaths.engineReadyFile),
                expectedGeneration: generation,
                expectedProcessIdentifier: pid
            )
            switch decision {
            case .ready:
                markerIssueSince = nil
                ready = true
            case .waiting(let reason):
                if reason.hasPrefix("ready-marker-") {
                    // The entry is real but its marker is missing/unusable.
                    // Allow a short write race, then fail instead of polling
                    // for an entry that cannot become any more real.
                    if markerIssueSince == nil { markerIssueSince = Date() }
                    if let markerIssueSince,
                       Date().timeIntervalSince(markerIssueSince) >= 5 {
                        finishCanaryBeforeSteps(
                            runID: runID,
                            code: reason,
                            message: "The engine reported a real entry but its ready marker was not usable within 5 seconds (\(reason))."
                        )
                        return
                    }
                } else {
                    markerIssueSince = nil
                    if Date() >= entryDeadline {
                        finishCanaryBeforeSteps(
                            runID: runID,
                            code: "engine-entry-timeout",
                            message: "The engine did not reach a confirmed ready entry within " +
                                "\(Int(BridgeCanaryPolicy.entryTimeoutSeconds)) seconds (\(reason))."
                        )
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
                continue
            case .fenced:
                finishCanaryBeforeSteps(
                    runID: runID,
                    code: "generation-fenced",
                    message: "The start was stopped before the self-check could run."
                )
                return
            case .failed(let code, let message):
                finishCanaryBeforeSteps(runID: runID, code: code, message: message)
                return
            }
            if ready { break }
        }
        guard !Task.isCancelled else {
            cancelCanaryRecord(
                runID: runID,
                code: "cancelled",
                message: "The self-check was cancelled before the first step."
            )
            return
        }
        guard var run = currentCanary(runID) else { return }
        guard run.markRunning() else {
            finishCanaryBeforeSteps(
                runID: runID,
                code: "canary-state",
                message: "The self-check could not enter the running state."
            )
            return
        }
        canaryRun = run
        persistCanary()
        BridgeLog.shared.append("canary_ready runID=\(runID) generation=\(generation)")

        while !Task.isCancelled {
            guard var run = currentCanary(runID), run.isLive else { return }
            guard let index = run.nextPendingIndex else {
                _ = run.complete()
                canaryRun = run
                persistCanary()
                BridgeLog.shared.append(
                    "canary_completed runID=\(runID) steps=\(run.totalCount) passed=\(run.passedCount)"
                )
                return
            }
            let step = run.report.steps[index]
            let snapshot = shared.snapshot()
            guard snapshot.generation == generation,
                  snapshot.engineRunning,
                  shared.engineAcceptsCommands() else {
                finishCanaryAtCurrentStep(
                    runID: runID,
                    code: "engine-not-accepting",
                    message: "The engine stopped accepting commands before step \(index + 1)."
                )
                return
            }
            guard let token = model?.channelToken() else {
                finishCanaryAtCurrentStep(
                    runID: runID,
                    code: "token-unavailable",
                    message: "The private command token could not be read; no command was issued."
                )
                return
            }
            guard run.beginIssue(index: index) else {
                finishCanaryAtCurrentStep(
                    runID: runID,
                    code: "canary-state",
                    message: "The self-check step could not enter the issuing state."
                )
                return
            }
            canaryRun = run
            persistCanary()
            let command = BridgeCommandEnvelope(
                id: step.commandID,
                action: step.action,
                pid: pid,
                token: token,
                expectedGeneration: generation,
                issuedAt: BridgeClock.timestamp()
            )
            guard BridgeFileChannel.issue(command, lane: .engine) != nil else {
                _ = run.failBeforeIssue(
                    index: index,
                    code: "issue-failed",
                    message: "The canary command file could not be written; no command was issued."
                )
                canaryRun = run
                persistCanary()
                return
            }
            _ = run.markAwaitingResult(index: index)
            canaryRun = run
            persistCanary()
            BridgeLog.shared.append(
                "canary_step_issued runID=\(runID) step=\(index + 1) action=\(step.action)"
            )

            let waited = await waitForCanaryResult(
                runID: runID,
                index: index,
                generation: generation,
                timeout: BridgeCanaryPolicy.timeout(for: step.action)
            )
            guard var latest = currentCanary(runID), latest.isLive else { return }
            switch waited {
            case .accepted(let result, let bytes):
                guard shared.snapshot().generation == generation else {
                    _ = latest.recordUnobserved(
                        index: index,
                        code: "generation-fenced",
                        message: "The generation changed before the result could be accepted."
                    )
                    canaryRun = latest
                    persistCanary()
                    return
                }
                let disposition = latest.recordResult(
                    index: index,
                    result: result,
                    resultBytes: bytes
                )
                canaryRun = latest
                persistCanary()
                BridgeLog.shared.append(
                    "canary_step_result runID=\(runID) step=\(index + 1) action=\(step.action) " +
                    "disposition=\(disposition) status=\(result.status)"
                )
                if disposition != .passed { return }
            case .timedOut:
                let seconds = Int(BridgeCanaryPolicy.timeout(for: step.action))
                _ = latest.recordUnobserved(
                    index: index,
                    code: "result-timeout",
                    message: "No result within \(seconds) seconds. The command was not replayed; " +
                        "an entered UIKit/XCTest call may still complete."
                )
                canaryRun = latest
                persistCanary()
                BridgeLog.shared.append(
                    "canary_step_timeout runID=\(runID) step=\(index + 1) action=\(step.action)"
                )
                return
            case .fenced:
                _ = latest.recordUnobserved(
                    index: index,
                    code: "generation-fenced",
                    message: "The generation changed while waiting; the result was not accepted."
                )
                canaryRun = latest
                persistCanary()
                return
            case .cancelled:
                _ = latest.recordUnobserved(
                    index: index,
                    code: "cancelled",
                    message: "The self-check was cancelled while waiting; the result was not observed."
                )
                canaryRun = latest
                persistCanary()
                return
            case .failed(let code, let message):
                _ = latest.recordUnobserved(
                    index: index,
                    code: code,
                    message: message
                )
                canaryRun = latest
                persistCanary()
                BridgeLog.shared.append(
                    "canary_step_engine_failed runID=\(runID) step=\(index + 1) code=\(code)"
                )
                return
            }
        }
        cancelCanaryRecord(
            runID: runID,
            code: "cancelled",
            message: "The self-check was cancelled."
        )
    }

    private func waitForCanaryResult(
        runID: String,
        index: Int,
        generation: UInt64,
        timeout: TimeInterval
    ) async -> CanaryWaitResult {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return .cancelled }
            guard let run = currentCanary(runID),
                  run.report.currentStepIndex == index,
                  run.report.steps.indices.contains(index) else {
                return .cancelled
            }
            let snapshot = shared.snapshot()
            if snapshot.generation != generation { return .fenced }
            let commandID = run.report.steps[index].commandID
            if let observed = BridgeFileChannel.result(identifier: commandID, lane: .engine) {
                // The fence wins even when a result file appeared in the same
                // polling window; a late result is never accepted as a pass.
                if shared.snapshot().generation != generation { return .fenced }
                return .accepted(observed.result, observed.bytes)
            }
            if snapshot.terminalFault {
                return .failed(
                    code: snapshot.terminalFaultCode ?? "terminal-fault",
                    message: snapshot.terminalFaultMessage ?? "The engine latched a terminal fault."
                )
            }
            if snapshot.phase == .failed {
                return .failed(
                    code: snapshot.errorCode ?? "failed",
                    message: snapshot.lastError ?? "The engine failed while the step was pending."
                )
            }
            if !snapshot.engineRunning {
                return .failed(
                    code: "engine-stopped",
                    message: "The engine stopped while the step was pending; the result was not observed."
                )
            }
            try? await Task.sleep(for: .milliseconds(BridgeCanaryPolicy.resultPollMilliseconds))
        }
        if Task.isCancelled { return .cancelled }
        if shared.snapshot().generation != generation { return .fenced }
        return .timedOut
    }

    private func finishCanaryBeforeSteps(runID: String, code: String, message: String) {
        guard var run = currentCanary(runID), run.isLive else { return }
        _ = run.failRun(code: code, message: message)
        canaryRun = run
        persistCanary()
        BridgeLog.shared.append("canary_stopped runID=\(runID) code=\(code)")
    }

    private func finishCanaryAtCurrentStep(runID: String, code: String, message: String) {
        guard var run = currentCanary(runID), run.isLive else { return }
        if let index = run.report.currentStepIndex,
           run.report.steps.indices.contains(index),
           run.report.steps[index].state == .issuing ||
            run.report.steps[index].state == .awaitingResult {
            _ = run.recordUnobserved(index: index, code: code, message: message)
        } else if let pending = run.nextPendingIndex {
            _ = run.failBeforeIssue(index: pending, code: code, message: message)
        } else {
            _ = run.failRun(code: code, message: message)
        }
        canaryRun = run
        persistCanary()
        BridgeLog.shared.append("canary_stopped runID=\(runID) code=\(code)")
    }

    private func cancelCanaryRecord(runID: String, code: String, message: String) {
        guard var run = currentCanary(runID), run.isLive else { return }
        _ = run.cancel(code: code, message: message)
        canaryRun = run
        persistCanary()
        BridgeLog.shared.append("canary_cancel runID=\(runID) code=\(code)")
    }

    private func cancelCanary(reason: String) {
        canaryTask?.cancel()
        guard let runID = canaryRun?.report.runID, canaryRun?.isLive == true else { return }
        let message: String
        switch reason {
        case "stop":
            message = BridgeL10n.t(
                "The self-check was cancelled by Stop. A command already issued may still complete; no result is claimed.",
                "自检已因停止而取消。已发出的命令可能仍会完成；不声明结果。"
            )
        default:
            message = BridgeL10n.t("The self-check was cancelled.", "自检已取消。")
        }
        cancelCanaryRecord(runID: runID, code: "cancelled-\(reason)", message: message)
    }

    func prepareAndMount(trigger: String) {
        let snapshot = shared.snapshot()
        if snapshot.terminalFault {
            showReopenRequired(code: snapshot.terminalFaultCode ?? "terminal-fault")
            return
        }
        if snapshot.oneShotDispatched {
            showBanner("The one-shot bootstrap already ran; a manual mount cannot re-run it in this process.")
            return
        }
        if snapshot.phase.isActive {
            showBanner("A start is already in progress.")
            return
        }
        if isDDIWorkerBusy {
            showBanner("A DDI operation is still running. Wait for it to finish before mounting.")
            return
        }
        task?.cancel()
        generation = shared.withLifecycle { $0.beginStart(trigger: "mount:\(trigger)") }
        let currentGeneration = generation
        task = Task { [weak self] in
            guard let self else { return }
            let ready = await self.ensureTransportReady(currentGeneration)
            guard ready else { return }
            self.shared.withLifecycle { $0.fence(reason: "mount-only-complete") }
            self.model?.banner = "DDI mount verified. Start will reuse this mount and bootstrap the engine."
            self.model?.refresh()
        }
    }

    func importPairing(url: URL) async {
        do {
            try pairing.importFile(from: url)
            shared.withLifecycle { $0.setPairing(imported: true) }
            BridgeLog.shared.append("pairing_import_ok")
            model?.banner = nil
        } catch {
            BridgeLog.shared.append("pairing_import_failed error=\(error.localizedDescription)")
            showBanner(error.localizedDescription)
        }
        model?.refresh()
    }

    func removePairing() {
        pairing.remove()
        shared.withLifecycle { $0.setPairing(imported: false) }
        model?.refresh()
    }

    func downloadDDI() {
        ddiStore.download()
        model?.refresh()
    }

    func cancelDDIDownload() {
        ddiStore.cancel()
        model?.refresh()
    }

    func importDDIFolder(url: URL) async {
        do {
            try await ddiStore.importFolder(from: url)
            model?.banner = "DDI files imported and validated."
        } catch {
            model?.banner = error.localizedDescription
        }
        model?.refresh()
    }

    func toggleTunnel() async {
        if shared.snapshot().engineRunning {
            showBanner("Stop the engine before changing the reflector.")
            return
        }
        if isDDIWorkerBusy {
            showBanner("A DDI operation is still running. Wait for it to finish before changing the reflector.")
            return
        }
        if tunnel.phase == .connected || tunnel.phase == .connecting {
            tunnel.stop()
            return
        }
        await startTunnelOnly()
    }

    func startTunnelOnly() async {
        if shared.snapshot().engineRunning {
            showBanner("Stop the engine before changing the reflector.")
            return
        }
        if isDDIWorkerBusy {
            showBanner("A DDI operation is still running. Wait for it to finish before changing the reflector.")
            return
        }
        if tunnel.phase == .connected {
            model?.refresh()
            return
        }
        if tunnel.phase == .connecting {
            model?.refresh()
            return
        }
        do {
            try await tunnel.start()
            let probe = await tunnel.probe()
            shared.withLifecycle { $0.setTunnelProbe(probe.description) }
            model?.banner = probe == .reachable
                ? "Reflector connected and the debug port answered."
                : "Reflector connected, but the debug port did not answer yet."
        } catch {
            showBanner(error.localizedDescription)
        }
        model?.refresh()
    }

    func stopTunnelOnly() {
        if shared.snapshot().engineRunning {
            showBanner("Stop the engine before stopping the reflector.")
            return
        }
        if isDDIWorkerBusy {
            showBanner("A DDI operation is still running. Wait for it to finish before changing the reflector.")
            return
        }
        tunnel.stop()
        model?.refresh()
    }

    // MARK: - DDI removal

    /// Prototype-only, authenticated removal entry point. The pure guard runs
    /// before any state change; the blocking worker is fenced by a new
    /// generation and the shared DDI-worker flag so Start/mount cannot overlap.
    func removeDDI(trigger: String) -> BridgeDDIRemovalDispatch {
        guard let model else {
            return .refused(code: "unavailable", message: "The host model is unavailable.")
        }
        let snapshot = shared.snapshot()
        let decision = BridgeDDIRemovalGuard.decide(
            BridgeDDIRemovalGuardInput(
                autoStartEnabled: model.autoStart,
                engineRunning: snapshot.engineRunning,
                serviceRunning: snapshot.serviceRunning,
                phaseActive: snapshot.phase.isActive,
                oneShotDispatched: snapshot.oneShotDispatched,
                engineEntryObserved: snapshot.engineEntryObserved,
                terminalFault: snapshot.terminalFault,
                ddiWorkerBusy: isDDIWorkerBusy,
                pairingImported: pairing.isImported
            )
        )
        if case .refused(let code) = decision {
            let message = Self.removalRefusalMessage(code)
            BridgeLog.shared.append("ddi_remove_refused code=\(code) trigger=\(trigger)")
            if code == BridgeDDIRemovalGuard.terminalFaultCode {
                showReopenRequired(code: snapshot.terminalFaultCode ?? code)
            } else {
                showBanner(message)
            }
            return .refused(code: code, message: message)
        }
        if tunnel.phase == .connecting || tunnel.phase == .disconnecting {
            let message = BridgeL10n.t(
                "Wait for the reflector to finish connecting or disconnecting, then retry.",
                "请等待反射隧道完成连接或断开后再试。"
            )
            BridgeLog.shared.append("ddi_remove_refused code=tunnel-transition trigger=\(trigger)")
            showBanner(message)
            return .refused(code: "tunnel-transition", message: message)
        }

        // No active start can exist at this point; cancel defensively so a
        // completed timer task cannot resume into the removal window.
        task?.cancel()
        task = nil
        let removalGeneration = shared.withLifecycle {
            $0.beginDDIRemoval(trigger: trigger)
        }

        ddiOperationInFlight = true
        model.ddiWorkerBusy = true
        model.banner = nil
        model.mountProgress = 0
        let gate = BridgeDDIMutationGate()
        removalGate = gate
        removalTask?.cancel()
        removalTask = Task { [weak self] in
            guard let self else { return }
            await self.runRemoval(removalGeneration, gate: gate)
        }
        BridgeLog.shared.append(
            "coordinator_remove_ddi trigger=\(trigger) generation=\(removalGeneration)"
        )
        model.refresh()
        return .started(removalGeneration)
    }

    private func runRemoval(
        _ removalGeneration: UInt64,
        gate: BridgeDDIMutationGate
    ) async {
        await withTaskCancellationHandler {
            await runRemovalBody(removalGeneration, gate: gate)
        } onCancel: {
            gate.cancel()
        }
    }

    private func runRemovalBody(
        _ removalGeneration: UInt64,
        gate: BridgeDDIMutationGate
    ) async {
        guard let model else { return }
        let actionStartedAt = BridgeClock.timestamp()
        let started = Date()
        let installMethod = ddiStore.method
        var report = BridgeDDIRemovalReport(
            generation: removalGeneration,
            installMethod: installMethod,
            mutationAttempted: false
        )
        let tunnelWasConnected = tunnel.phase == .connected
        var ownedTunnel = false
        var staged: URL?

        // The worker may still be running when Stop fences the generation.
        // Clear the in-flight flag only after this task actually returns, and
        // remove the staged pairing record only after the blocking call ends.
        defer {
            if let staged { try? FileManager.default.removeItem(at: staged) }
            ddiOperationInFlight = false
            model.ddiWorkerBusy = false
            if removalGate === gate { removalGate = nil }
            removalTask = nil
            model.mountProgress = 0
            model.refresh()
        }

        if !tunnelWasConnected {
            guard shared.withLifecycle({
                $0.advance(removalGeneration, to: .startingTunnel, activity: "remove-ddi-tunnel")
            }) else {
                report.outcome = .cancelled
                report.errorCode = "cancelled"
                report.errorMessage = "The removal generation was fenced before the reflector started."
                await finalizeRemoval(
                    report,
                    actionStartedAt: actionStartedAt,
                    started: started,
                    ownedTunnel: false,
                    tunnelWasConnected: false
                )
                return
            }
            // Mark ownership before the attempt: a timeout can leave the
            // system connection in a transient state, and cleanup must stop any
            // reflector this removal started even when start() threw.
            ownedTunnel = true
            do {
                try await tunnel.start()
            } catch {
                report.outcome = .failed
                report.errorCode = "tunnel-start-failed"
                report.errorMessage = error.localizedDescription
                await finalizeRemoval(
                    report,
                    actionStartedAt: actionStartedAt,
                    started: started,
                    ownedTunnel: ownedTunnel,
                    tunnelWasConnected: false
                )
                return
            }
        }

        guard isCurrent(removalGeneration), !Task.isCancelled else {
            report.outcome = .cancelled
            report.errorCode = "cancelled"
            report.errorMessage = "The removal generation was fenced before the reflector probe."
            await finalizeRemoval(
                report,
                actionStartedAt: actionStartedAt,
                started: started,
                ownedTunnel: ownedTunnel,
                tunnelWasConnected: tunnelWasConnected
            )
            return
        }

        let tunnelProbe = await tunnel.probe()
        shared.withLifecycle { $0.setTunnelProbe(tunnelProbe.description) }
        guard isCurrent(removalGeneration), !Task.isCancelled else {
            report.outcome = .cancelled
            report.errorCode = "cancelled"
            report.errorMessage = "The removal generation was fenced during the reflector probe."
            await finalizeRemoval(
                report,
                actionStartedAt: actionStartedAt,
                started: started,
                ownedTunnel: ownedTunnel,
                tunnelWasConnected: tunnelWasConnected
            )
            return
        }
        guard tunnelProbe == .reachable else {
            report.outcome = .failed
            report.errorCode = "tunnel-probe-failed"
            report.errorMessage = tunnelProbe.description
            await finalizeRemoval(
                report,
                actionStartedAt: actionStartedAt,
                started: started,
                ownedTunnel: ownedTunnel,
                tunnelWasConnected: tunnelWasConnected
            )
            return
        }

        guard shared.withLifecycle({
            $0.advance(removalGeneration, to: .mountingDDI, activity: "remove-ddi")
        }) else {
            report.outcome = .cancelled
            report.errorCode = "cancelled"
            report.errorMessage = "The removal generation was fenced before staging."
            await finalizeRemoval(
                report,
                actionStartedAt: actionStartedAt,
                started: started,
                ownedTunnel: ownedTunnel,
                tunnelWasConnected: tunnelWasConnected
            )
            return
        }

        do {
            staged = try pairing.stageForFFI()
        } catch {
            report.outcome = .failed
            report.errorCode = "pairing-staging-failed"
            report.errorMessage = error.localizedDescription
            await finalizeRemoval(
                report,
                actionStartedAt: actionStartedAt,
                started: started,
                ownedTunnel: ownedTunnel,
                tunnelWasConnected: tunnelWasConnected
            )
            return
        }
        guard let stagedURL = staged, isCurrent(removalGeneration), !Task.isCancelled else {
            report.outcome = .cancelled
            report.errorCode = "cancelled"
            report.errorMessage = "The removal generation was fenced before the worker started."
            await finalizeRemoval(
                report,
                actionStartedAt: actionStartedAt,
                started: started,
                ownedTunnel: ownedTunnel,
                tunnelWasConnected: tunnelWasConnected
            )
            return
        }

        let workerReport = await ddiManager.remove(
            pairingPath: stagedURL,
            installMethod: installMethod,
            generation: removalGeneration,
            gate: gate
        )
        // The blocking call has returned; this input is no longer live.
        try? FileManager.default.removeItem(at: stagedURL)
        staged = nil

        await finalizeRemoval(
            workerReport,
            actionStartedAt: actionStartedAt,
            started: started,
            ownedTunnel: ownedTunnel,
            tunnelWasConnected: tunnelWasConnected
        )
    }

    // MARK: - Read-only DDI stage probe

    /// Prototype-only authenticated entry point. It shares the manager's worker
    /// lifetime, the lifecycle generation fence and the staged pairing record,
    /// but it never enters the mutation gate or changes readiness/mount state.
    func runStageProbe(trigger: String) -> BridgeDDIStageProbeDispatch {
        guard let model else {
            return .refused(code: "unavailable", message: "The host model is unavailable.")
        }
        let snapshot = shared.snapshot()
        let decision = BridgeDDIStageProbeGuard.decide(
            BridgeDDIStageProbeGuardInput(
                terminalFault: snapshot.terminalFault,
                oneShotDispatched: snapshot.oneShotDispatched,
                engineEntryObserved: snapshot.engineEntryObserved,
                ddiWorkerBusy: isDDIWorkerBusy,
                engineRunning: snapshot.engineRunning,
                serviceRunning: snapshot.serviceRunning,
                phaseActive: snapshot.phase.isActive,
                autoStartEnabled: model.autoStart,
                pairingImported: pairing.isImported,
                assetsComplete: ddiStore.isComplete
            )
        )
        if case .refused(let code) = decision {
            let message = Self.stageProbeRefusalMessage(code)
            BridgeLog.shared.append("ddi_stage_probe_refused code=\(code) trigger=\(trigger)")
            if code == BridgeDDIStageProbeGuard.terminalFaultCode {
                showReopenRequired(code: snapshot.terminalFaultCode ?? code)
            } else {
                showBanner(message)
            }
            return .refused(code: code, message: message)
        }
        if tunnel.phase == .connecting || tunnel.phase == .disconnecting {
            let message = BridgeL10n.t(
                "Wait for the reflector to finish connecting or disconnecting, then retry.",
                "请等待反射隧道完成连接或断开后再试。"
            )
            BridgeLog.shared.append(
                "ddi_stage_probe_refused code=tunnel-transition trigger=\(trigger)"
            )
            showBanner(message)
            return .refused(code: "tunnel-transition", message: message)
        }

        // No active start/mount/removal can exist after the guard; cancel a
        // completed timer task defensively so it cannot resume into this fence.
        task?.cancel()
        task = nil
        let fence = shared.withLifecycle { $0.beginDDIStageProbe(trigger: trigger) }
        ddiOperationInFlight = true
        model.ddiWorkerBusy = true
        model.noteStageProbeSummary(nil)
        model.banner = nil
        let gate = BridgeDDIMutationGate()
        probeGate = gate
        let recorder = BridgeDDIStageProbeRecorder(
            hostPid: Int32(ProcessInfo.processInfo.processIdentifier),
            generation: fence.generation,
            installMethod: ddiStore.method
        )
        task = Task { [weak self] in
            guard let self else { return }
            await self.runStageProbeBody(fence: fence, gate: gate, recorder: recorder)
        }
        BridgeLog.shared.append(
            "coordinator_ddi_stage_probe trigger=\(trigger) generation=\(fence.generation) " +
            "method=\(ddiStore.method.rawValue)"
        )
        model.refresh()
        return .started(fence.generation)
    }

    private func runStageProbeBody(
        fence: BridgeDDIStageProbeFence,
        gate: BridgeDDIMutationGate,
        recorder: BridgeDDIStageProbeRecorder
    ) async {
        guard let model else { return }
        var ownedTunnel = false
        var staged: URL?
        defer {
            if let staged { try? FileManager.default.removeItem(at: staged) }
            snapshotSampler.stop()
            if probeGate === gate { probeGate = nil }
            ddiOperationInFlight = false
            model.ddiWorkerBusy = false
            task = nil
            model.refresh()
        }

        recorder.write(to: BridgePaths.ddiStageProbeFile)
        await performStageProbe(
            fence: fence,
            gate: gate,
            recorder: recorder,
            ownedTunnel: &ownedTunnel,
            staged: &staged
        )

        snapshotSampler.stop()
        if ownedTunnel {
            await stopOwnedProbeTunnel(recorder)
        }
        if Task.isCancelled || gate.isCancelled {
            _ = recorder.finish(.cancelled, errorCode: "cancelled")
        } else if recorder.snapshot().outcome == .running {
            recorder.note("probe finished without a terminal stage result")
            _ = recorder.finish(.failed, errorCode: "probe-incomplete")
        }
        recorder.write(to: BridgePaths.ddiStageProbeFile)
        let report = recorder.snapshot()
        model.noteStageProbeSummary(Self.stageProbeSummary(report))
        shared.withLifecycle {
            $0.endDDIStageProbe(fence, reason: "stage-probe-complete")
        }
        BridgeLog.shared.append(
            "ddi_stage_probe_report outcome=\(report.outcome.rawValue) " +
            "generation=\(report.generation) currentStage=\(report.currentStage ?? "none") " +
            "stages=\(report.stages.count) elapsedMs=\(report.elapsedMilliseconds)"
        )
        model.refresh()
    }

    private func performStageProbe(
        fence: BridgeDDIStageProbeFence,
        gate: BridgeDDIMutationGate,
        recorder: BridgeDDIStageProbeRecorder,
        ownedTunnel: inout Bool,
        staged: inout URL?
    ) async {
        recorder.begin(.tssReachability)
        let tss = await BridgeTSSReachabilityProbe.run(gate: gate)
        recorder.setTSS(tss)
        // The reachability stage completes with its own result. A timeout or
        // DNS failure is evidence about TSS, not a failure of the stage-probe
        // machinery, so it must not mask successful cryptexd stages.
        switch tss.outcome {
        case .httpResponse:
            recorder.complete(
                .tssReachability,
                detail: tss.httpStatus.map { "httpStatus=\($0)" }
            )
        case .timedOut:
            recorder.complete(.tssReachability, detail: "outcome=timed-out")
        case .cancelled:
            recorder.cancel(.tssReachability)
        case .failed:
            recorder.complete(
                .tssReachability,
                detail: "outcome=failed category=\(tss.errorCategory ?? "unknown")"
            )
        case .notRun:
            recorder.complete(.tssReachability, detail: "outcome=not-run")
        }
        recorder.write(to: BridgePaths.ddiStageProbeFile)
        BridgeLog.shared.append(
            "ddi_stage_probe_tss outcome=\(tss.outcome.rawValue) " +
            "httpStatus=\(tss.httpStatus.map(String.init) ?? "none") " +
            "durationMs=\(tss.durationMilliseconds) " +
            "category=\(tss.errorCategory ?? "none")"
        )

        if Task.isCancelled || gate.isCancelled { return }

        if ddiStore.method != .cryptex {
            recorder.setCryptexProbeApplicable(false)
            recorder.note("cryptexd stages do not apply to the personalized install path")
            recorder.note("install-method policy was not changed by this probe")
            _ = recorder.finish(.notApplicable, errorCode: "cryptex-not-applicable")
            return
        }

        if tunnel.phase != .connected {
            ownedTunnel = true
            recorder.begin(.tunnelStart)
            do {
                try await tunnel.start()
                recorder.complete(.tunnelStart)
            } catch {
                recorder.fail(.tunnelStart, code: "tunnel-start")
                recorder.note("the reflector did not reach connected")
                _ = recorder.finish(.failed, errorCode: "tunnel-start")
                return
            }
        }
        recorder.setTunnel(ownedTunnel ? "started" : "reused")
        recorder.write(to: BridgePaths.ddiStageProbeFile)

        recorder.begin(.tunnelProbe)
        let probe = await tunnel.probe()
        shared.withLifecycle { $0.setTunnelProbe(probe.description) }
        switch probe {
        case .reachable:
            recorder.complete(.tunnelProbe)
        case .localNetworkDenied:
            recorder.fail(.tunnelProbe, code: "local-network-denied")
            _ = recorder.finish(.failed, errorCode: "local-network-denied")
            return
        case .unreachable:
            recorder.fail(.tunnelProbe, code: "unreachable")
            _ = recorder.finish(.failed, errorCode: "tunnel-probe-failed")
            return
        }
        recorder.write(to: BridgePaths.ddiStageProbeFile)
        if Task.isCancelled || gate.isCancelled { return }

        snapshotSampler.start(
            hostPid: Int32(ProcessInfo.processInfo.processIdentifier),
            generation: fence.generation
        )

        recorder.begin(.pairingStage)
        do {
            staged = try pairing.stageForFFI()
        } catch {
            recorder.fail(.pairingStage, code: "pairing-staging")
            _ = recorder.finish(.failed, errorCode: "pairing-staging")
            return
        }
        guard let stagedURL = staged else {
            recorder.fail(.pairingStage, code: "pairing-staging")
            _ = recorder.finish(.failed, errorCode: "pairing-staging")
            return
        }
        recorder.complete(.pairingStage)
        recorder.write(to: BridgePaths.ddiStageProbeFile)

        let heartbeat = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    break
                }
                if self.probeGate !== gate { break }
                guard recorder.heartbeat() else { break }
                recorder.write(to: BridgePaths.ddiStageProbeFile)
                let snapshot = recorder.snapshot()
                let tunnel = BridgeTunnelSnapshotStore.shared.status()
                let counters = tunnel.snapshot.map {
                    "received=\($0.received) reflected=\($0.reflected)"
                } ?? "none"
                BridgeLog.shared.append(
                    "ddi_stage_probe_pending stage=\(snapshot.currentStage ?? "none") " +
                    "elapsedMs=\(snapshot.elapsedMilliseconds) " +
                    "generation=\(snapshot.generation) " +
                    "tunnel=\(tunnel.state.rawValue) \(counters)"
                )
            }
        }
        let report = await ddiManager.probeStages(
            pairingPath: stagedURL,
            imageDirectory: ddiStore.directory,
            reportURL: BridgePaths.ddiStageProbeFile,
            gate: gate,
            recorder: recorder
        )
        heartbeat.cancel()
        if report == nil {
            recorder.note("another DDI worker owns the FFI lifetime")
            _ = recorder.finish(.failed, errorCode: "ddi-worker-busy")
            return
        }
        recorder.write(to: BridgePaths.ddiStageProbeFile)
    }

    private func stopOwnedProbeTunnel(_ recorder: BridgeDDIStageProbeRecorder) async {
        recorder.begin(.tunnelStop)
        tunnel.stop()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if Task.isCancelled { break }
            tunnel.syncStatus()
            switch tunnel.phase {
            case .connected, .connecting, .disconnecting:
                break
            default:
                recorder.complete(.tunnelStop, detail: "phase=\(tunnel.phase.rawValue)")
                recorder.setTunnel("started-and-stopped")
                recorder.write(to: BridgePaths.ddiStageProbeFile)
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        recorder.complete(.tunnelStop, detail: "phase=\(tunnel.phase.rawValue)")
        recorder.setTunnel("started-stop-pending")
        recorder.write(to: BridgePaths.ddiStageProbeFile)
    }

    private static func stageProbeRefusalMessage(_ code: String) -> String {
        switch code {
        case BridgeDDIStageProbeGuard.terminalFaultCode:
            return BridgeL10n.t(
                "Reopen the app before checking DDI stages.",
                "请重新打开应用后再检查 DDI 阶段。"
            )
        case BridgeDDIStageProbeGuard.oneShotCode:
            return BridgeL10n.t(
                "The one-shot test entry already ran in this process. Reopen the app before checking stages.",
                "当前进程已执行一次性测试入口。请重新打开应用后再检查阶段。"
            )
        case BridgeDDIStageProbeGuard.workerBusyCode:
            return BridgeL10n.t(
                "A DDI operation is still running. Wait for it to finish.",
                "DDI 操作仍在进行，请等待其完成。"
            )
        case BridgeDDIStageProbeGuard.engineActiveCode:
            return BridgeL10n.t(
                "Stop the engine before checking DDI stages.",
                "请先停止引擎，再检查 DDI 阶段。"
            )
        case BridgeDDIStageProbeGuard.autoStartCode:
            return BridgeL10n.t(
                "Turn off Auto-recover before checking DDI stages.",
                "请先关闭自动恢复，再检查 DDI 阶段。"
            )
        case BridgeDDIStageProbeGuard.pairingCode:
            return BridgeL10n.t(
                "Import a RemotePairing file before checking DDI stages.",
                "请先导入 RemotePairing 文件，再检查 DDI 阶段。"
            )
        case BridgeDDIStageProbeGuard.assetsCode:
            return BridgeL10n.t(
                "Download or import the DDI files before checking stages.",
                "请先下载或导入 DDI 文件，再检查阶段。"
            )
        default:
            return BridgeL10n.t(
                "The DDI stage check cannot run in the current state.",
                "当前状态无法执行 DDI 阶段检查。"
            )
        }
    }

    private static func stageProbeSummary(_ report: BridgeDDIStageProbeReport) -> String {
        switch report.outcome {
        case .completed:
            var facts: [String] = []
            if let status = report.tss?.httpStatus {
                facts.append("TSS HTTP \(status)")
            } else if let outcome = report.tss?.outcome {
                facts.append("TSS \(outcome.rawValue)")
            }
            if let nonce = report.stages.first(where: {
                $0.stage == BridgeDDIProbeStage.cryptexNonce.rawValue && $0.state == .completed
            }), let detail = nonce.detail {
                facts.append(detail)
            }
            let suffix = facts.isEmpty ? "" : " · " + facts.joined(separator: " · ")
            return BridgeL10n.t(
                "DDI stage check complete\(suffix) · \(report.elapsedMilliseconds) ms",
                "DDI 阶段检查完成\(suffix) · \(report.elapsedMilliseconds) 毫秒"
            )
        case .notApplicable:
            return BridgeL10n.t(
                "Cryptex stages do not apply on this OS; only the TSS check ran.",
                "此系统不适用 Cryptex 阶段；仅执行了 TSS 检查。"
            )
        case .cancelled:
            return BridgeL10n.t(
                "DDI stage check cancelled.",
                "DDI 阶段检查已取消。"
            )
        case .failed:
            let failedStage = report.stages.last(where: { $0.state == .failed })?.stage
            let stage = report.currentStage ?? failedStage ?? report.errorCode ?? "unknown"
            let code = report.errorCode ?? "error"
            return BridgeL10n.t(
                "DDI stage check stopped at \(stage) (\(code)).",
                "DDI 阶段检查在 \(stage) 处停止（\(code)）。"
            )
        case .running:
            return BridgeL10n.t(
                "DDI stage check is still running.",
                "DDI 阶段检查仍在进行。"
            )
        }
    }

    private func finalizeRemoval(
        _ input: BridgeDDIRemovalReport,
        actionStartedAt: String,
        started: Date,
        ownedTunnel: Bool,
        tunnelWasConnected: Bool
    ) async {
        var report = input
        report.startedAt = actionStartedAt
        report.finishedAt = BridgeClock.timestamp()
        report.durationSeconds = Date().timeIntervalSince(started)

        if ownedTunnel {
            await stopOwnedTunnelAndWait()
            switch tunnel.phase {
            case .connected, .connecting, .disconnecting:
                report.tunnel = "started-stop-pending"
            default:
                report.tunnel = "started-and-stopped"
            }
        } else if tunnelWasConnected {
            report.tunnel = "reused"
        } else {
            report.tunnel = "not-started"
        }

        let current = isCurrent(report.generation) && !Task.isCancelled
        if !current {
            // The worker may have completed, but a fenced generation may not
            // claim a result or overwrite live state.
            report.outcome = .cancelled
            report.errorCode = "cancelled"
            report.errorMessage = "The removal generation was fenced before the worker result was accepted."
        }

        BridgeDDIRemovalReport.write(report, to: BridgePaths.ddiRemovalReportFile)
        BridgeLog.shared.append(
            "ddi_remove_report outcome=\(report.outcome.rawValue) " +
            "remoteAbsent=\(report.remoteAbsent == true) localAbsent=\(report.localProbeAbsent == true) " +
            "generation=\(report.generation) tunnel=\(report.tunnel)"
        )

        guard current else {
            model?.banner = BridgeL10n.t(
                "DDI removal was cancelled after the worker returned; no result is claimed.",
                "DDI 移除在 worker 返回后已取消；不声明结果。"
            )
            model?.refresh()
            return
        }

        switch report.outcome {
        case .removed:
            shared.withLifecycle {
                $0.setDDI(.notMounted, layout: nil, source: nil, detail: "removed by this app")
                $0.recordDDIProbe(
                    mounted: false,
                    layout: nil,
                    path: nil,
                    source: nil,
                    detail: "post-removal probe absent"
                )
            }
            model?.banner = BridgeL10n.t(
                "DDI removed. Both remote services report it absent and XCTest is no longer readable.",
                "DDI 已移除。两个远端服务均报告其不存在，XCTest 也已不可读。"
            )
            shared.withLifecycle { $0.fence(reason: "remove-ddi-complete") }
        case .alreadyAbsent:
            shared.withLifecycle {
                $0.setDDI(.notMounted, layout: nil, source: nil, detail: "already absent")
                $0.recordDDIProbe(
                    mounted: false,
                    layout: nil,
                    path: nil,
                    source: nil,
                    detail: "removal pre-check absent"
                )
            }
            model?.banner = BridgeL10n.t(
                "The DDI was already absent; nothing was changed.",
                "DDI 原本已不存在，未做更改。"
            )
            shared.withLifecycle { $0.fence(reason: "remove-ddi-noop") }
        case .preStateUnknown:
            recordRemovalFailure(report)
            model?.banner = BridgeL10n.t(
                "The DDI state could not be verified; nothing was removed. Check diagnostics.",
                "无法确认 DDI 状态，未执行移除。请查看诊断信息。"
            )
        case .verificationFailed:
            recordRemovalFailure(report)
            model?.banner = BridgeL10n.t(
                "The removal returned but DDI absence was not fully verified. Check diagnostics before starting.",
                "移除调用已返回，但未能完全验证 DDI 不存在。请查看诊断后再启动。"
            )
        case .failed:
            recordRemovalFailure(report)
            model?.banner = BridgeL10n.t(
                "DDI removal failed: \(report.errorMessage ?? report.errorCode ?? "unknown error")",
                "DDI 移除失败：\(report.errorMessage ?? report.errorCode ?? "未知错误")"
            )
        case .cancelled:
            recordRemovalFailure(report)
            model?.banner = BridgeL10n.t(
                "DDI removal was cancelled; no result is claimed.",
                "DDI 移除已取消；不声明结果。"
            )
        }

        model?.refresh()
    }

    /// Records a retryable removal failure without latching a terminal fault.
    /// The report remains the authoritative pre/post evidence; the shared
    /// state only reflects a fresh local probe when one exists and never sets
    /// an on-device mount timestamp.
    private func recordRemovalFailure(_ report: BridgeDDIRemovalReport) {
        let code = report.errorCode ?? "ddi-remove-failed"
        let message = report.errorMessage ?? "DDI removal did not complete."
        shared.withLifecycle { $0.fail(report.generation, code: code, message: message) }
        if let postMounted = report.postProbeMounted {
            if postMounted {
                shared.withLifecycle {
                    $0.setDDI(.mounted, layout: nil, source: nil,
                              detail: "removal verification failed; runtime still readable")
                }
            } else if report.remoteAbsent == true {
                shared.withLifecycle {
                    $0.setDDI(.notMounted, layout: nil, source: nil,
                              detail: "remote services report absent; local verification incomplete")
                }
            } else {
                shared.withLifecycle {
                    $0.setDDI(.unknown, layout: nil, source: nil,
                              detail: "removal failed; DDI state not verified")
                }
            }
        } else if let preMounted = report.preProbeMounted {
            shared.withLifecycle {
                $0.setDDI(preMounted ? .mounted : .notMounted, layout: nil, source: nil,
                          detail: "removal pre-check only; no post state")
            }
        }
    }

    private func stopOwnedTunnelAndWait() async {
        guard tunnel.phase == .connecting || tunnel.phase == .connected else { return }
        tunnel.stop()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            tunnel.syncStatus()
            switch tunnel.phase {
            case .connecting, .connected, .disconnecting:
                break
            default:
                return
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func removalRefusalMessage(_ code: String) -> String {
        switch code {
        case BridgeDDIRemovalGuard.oneShotCode:
            return BridgeL10n.t(
                "The one-shot test entry already ran in this process. Reopen the app before removing the DDI.",
                "当前进程已执行一次性测试入口。请重新打开应用后再移除 DDI。"
            )
        case BridgeDDIRemovalGuard.workerBusyCode:
            return BridgeL10n.t(
                "A DDI operation is still running. Wait for it to finish.",
                "DDI 操作仍在进行，请等待其完成。"
            )
        case BridgeDDIRemovalGuard.engineActiveCode:
            return BridgeL10n.t(
                "Stop the engine before removing the DDI.",
                "请先停止引擎，再移除 DDI。"
            )
        case BridgeDDIRemovalGuard.autoStartCode:
            return BridgeL10n.t(
                "Turn off Auto-recover before removing the DDI.",
                "请先关闭自动恢复，再移除 DDI。"
            )
        case BridgeDDIRemovalGuard.pairingCode:
            return BridgeL10n.t(
                "Import a RemotePairing file before removing the DDI.",
                "请先导入 RemotePairing 文件，再移除 DDI。"
            )
        default:
            return BridgeL10n.t(
                "The DDI cannot be removed in the current state.",
                "当前状态无法移除 DDI。"
            )
        }
    }

    // MARK: - Startup

    private func runStart(_ startGeneration: UInt64) async {
        guard await ensureTransportReady(startGeneration) else { return }
        guard isCurrent(startGeneration) else { return }

        let probe = BridgeDDIProbe.status()
        guard probe.mounted, probe.xctestReadable else {
            fail(startGeneration, code: "xctest-unreadable", message: "The DDI reports mounted but XCTest.framework is not readable.")
            return
        }

        // A previous Start may have enqueued the one-shot entry before Stop.
        // That entry is irreversible; never dispatch a second one. Re-enable
        // the service and wait for the real entry instead.
        let preBootstrap = shared.snapshot()
        if preBootstrap.terminalFault {
            showReopenRequired(code: preBootstrap.terminalFaultCode ?? "terminal-fault")
            return
        }
        if preBootstrap.oneShotDispatched {
            if preBootstrap.engineEntryObserved {
                switch shared.withLifecycle({ $0.requestEngineResume() }) {
                case .resumed:
                    model?.refresh()
                case .reopenRequired(let code):
                    showReopenRequired(code: code)
                case .unavailable:
                    model?.refresh()
                }
                return
            }
            guard shared.withLifecycle({ $0.advance(startGeneration, to: .waitingForEngine, activity: "waiting-engine") }) else { return }
            model?.refresh()
            await waitForEngineEntry(startGeneration)
            return
        }

        guard shared.withLifecycle({ $0.advance(startGeneration, to: .bootstrapping, activity: "bootstrap") }) else { return }
        model?.refresh()

        let bundle = Bundle.main
        let xctestPath = bundle.bundlePath + "/" + BridgeBuild.testBundlePath
        try? FileManager.default.removeItem(at: BridgePaths.engineReadyFile)
        try? FileManager.default.removeItem(at: BridgePaths.engineHeartbeatFile)
        try? FileManager.default.removeItem(at: BridgePaths.engineEntryConfirmedFile)

        // Once this dispatch is enqueued it is irreversible: Stop fences the
        // service and cancels preparation, but never tries to abort the XCTest
        // initializer. A late real entry records the initialized driver.
        let result = BRStartBootstrap(
            xctestPath,
            BridgePaths.hostLogFile.path,
            startGeneration,
            nil
        )

        switch result.rawValue {
        case 0:
            guard shared.withLifecycle({ $0.markBootstrapDispatched(startGeneration) }) else { return }
            BridgeLog.shared.append("bootstrap_dispatched generation=\(startGeneration)")
            model?.refresh()
            await waitForEngineEntry(startGeneration)
        case 6:
            BridgeLog.shared.append("bootstrap_cancelled_before_entry generation=\(startGeneration)")
            model?.refresh()
        case 1:
            BridgeLog.shared.append("bootstrap_already_started detail=\(BRLastBootstrapError() ?? "none")")
            fail(startGeneration, code: "bootstrap-already-started",
                 message: BridgeL10n.t(
                    "The one-shot bootstrap was already dispatched in this process. Reopen the app to retry.",
                    "当前进程已派发一次性引导，无法再次执行。请重新打开应用后再试。"
                 ),
                 terminal: true)
        case 3:
            fail(startGeneration, code: "ddi-runtime-missing",
                 message: "The mounted DDI does not expose a readable XCTest runtime. Mount the correct DDI and retry.")
        case 2:
            fail(startGeneration, code: "test-bundle-invalid",
                 message: BRLastBootstrapError() ?? "The embedded test bundle is not usable.")
        case 4:
            fail(startGeneration, code: "xctest-entry-missing",
                 message: BRLastBootstrapError() ?? "Could not resolve _XCTestMain.")
        case 5:
            fail(startGeneration, code: "bootstrap-context",
                 message: BRLastBootstrapError() ?? "Could not create the XCTest entry context.")
        default:
            fail(startGeneration, code: "bootstrap-unknown", message: "Unknown bootstrap result.")
        }
    }

    /// Returns true only when the DDI is mounted and readable. Every await is
    /// followed by a generation check; Stop fences the sequence and no late
    /// callback may mount, dispatch or mark ready.
    private func ensureTransportReady(_ startGeneration: UInt64) async -> Bool {
        var probe = BridgeDDIProbe.status()
        let observedSource: String? = probe.mounted
            ? (mountedByThisApp ? "on-device" : "preexisting")
            : nil
        let observedDetail = probe.mounted
            ? "XCTest readable before start"
            : "no readable XCTest framework"
        shared.withLifecycle {
            $0.recordDDIProbe(mounted: probe.mounted,
                              layout: probe.layout?.rawValue,
                              path: probe.xctestPath,
                              source: observedSource,
                              detail: observedDetail)
            $0.setDDI(probe.mounted ? .mounted : .notMounted,
                      layout: probe.layout?.rawValue,
                      source: observedSource,
                      detail: observedDetail)
        }
        BridgeLog.shared.append(
            "ddi_probe_prestart mounted=\(probe.mounted) " +
            "layout=\(probe.layout?.rawValue ?? "none") " +
            "runtime=\(probe.runtime?.rawValue ?? "none") " +
            "path=\(probe.xctestPath ?? "none") source=\(observedSource ?? "none")"
        )

        let pairingImported = pairing.isImported
        shared.withLifecycle { $0.setPairing(imported: pairingImported) }

        if probe.mounted {
            return isCurrent(startGeneration)
        }

        guard pairingImported else {
            fail(startGeneration, code: "pairing-required",
                 message: "The DDI is not mounted. Import a RemotePairing record to mount it from this device.")
            return false
        }

        if !ddiStore.isComplete {
            guard shared.withLifecycle({ $0.advance(startGeneration, to: .downloadingDDI, activity: "download-ddi") }) else { return false }
            model?.refresh()
            ddiStore.download()
            while ddiStore.isDownloading {
                if !isCurrent(startGeneration) { ddiStore.cancel(); return false }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard ddiStore.isComplete else {
                fail(startGeneration, code: "ddi-download-failed",
                     message: ddiStore.lastError ?? "The DDI files are not complete after the download.")
                return false
            }
        }

        guard isCurrent(startGeneration) else { return false }
        guard shared.withLifecycle({ $0.advance(startGeneration, to: .startingTunnel, activity: "start-tunnel") }) else { return false }
        model?.refresh()

        if tunnel.phase != .connected {
            do {
                try await tunnel.start()
            } catch {
                fail(startGeneration, code: "tunnel-start-failed", message: error.localizedDescription)
                return false
            }
        }
        guard isCurrent(startGeneration) else { return false }

        let tunnelProbe = await tunnel.probe()
        shared.withLifecycle { $0.setTunnelProbe(tunnelProbe.description) }
        switch tunnelProbe {
        case .reachable:
            break
        case .localNetworkDenied:
            fail(startGeneration, code: "local-network-denied",
                 message: "iOS denied local network access. Allow it in Settings → Privacy & Security → Local Network, then retry.")
            return false
        case .unreachable(let detail):
            fail(startGeneration, code: "tunnel-probe-failed",
                 message: "The reflector is connected but the device debug port did not answer: \(detail)")
            return false
        }
        guard isCurrent(startGeneration) else { return false }

        guard shared.withLifecycle({ $0.advance(startGeneration, to: .mountingDDI, activity: "mount-ddi") }) else { return false }
        model?.refresh()

        let staged: URL
        do {
            staged = try pairing.stageForFFI()
        } catch {
            fail(startGeneration, code: "pairing-staging-failed", message: error.localizedDescription)
            return false
        }
        defer { try? FileManager.default.removeItem(at: staged) }

        // A worker is live from this point until the blocking mount returns.
        // Start, mount and removal all refuse while this flag is set, even if
        // Stop fences the snapshot in the meantime.
        ddiOperationInFlight = true
        model?.ddiWorkerBusy = true
        let gate = BridgeDDIMutationGate()
        mountGate = gate
        // The progress record carries its own PID and generation. It is written
        // before the first call, at each observable marker and by a
        // service-owned heartbeat. It never asserts progress inside the opaque
        // install call.
        let trace = BridgeDDIInstallTrace(
            hostPid: Int32(ProcessInfo.processInfo.processIdentifier),
            generation: startGeneration,
            installMethod: ddiStore.method
        )
        trace.write(to: BridgePaths.ddiInstallProgressFile)
        snapshotSampler.start(
            hostPid: Int32(ProcessInfo.processInfo.processIdentifier),
            generation: startGeneration
        )
        let heartbeat = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    break
                }
                if self.mountGate !== gate { break }
                guard trace.heartbeat() else { break }
                trace.write(to: BridgePaths.ddiInstallProgressFile)
                let progress = trace.snapshot()
                let tunnel = BridgeTunnelSnapshotStore.shared.status()
                let counters = tunnel.snapshot.map {
                    "received=\($0.received) reflected=\($0.reflected)"
                } ?? "none"
                BridgeLog.shared.append(
                    "ddi_mount_pending elapsedMs=\(progress.elapsedMilliseconds) " +
                    "stage=\(progress.stage.rawValue) generation=\(progress.generation) " +
                    "tunnel=\(tunnel.state.rawValue) \(counters)"
                )
            }
        }
        defer {
            heartbeat.cancel()
            snapshotSampler.stop()
            trace.write(to: BridgePaths.ddiInstallProgressFile)
            if mountGate === gate { mountGate = nil }
            ddiOperationInFlight = false
            model?.ddiWorkerBusy = false
        }

        do {
            let report = try await withTaskCancellationHandler {
                try await ddiManager.mount(
                    pairingPath: staged,
                    method: ddiStore.method,
                    imageDirectory: ddiStore.directory,
                    trace: trace,
                    gate: gate
                ) { fraction in
                    Task { @MainActor in
                        self.model?.mountProgress = fraction
                    }
                }
            } onCancel: {
                gate.cancel()
            }
            if report["cancelled"] as? Bool == true {
                let attempted = report["mutationAttempted"] as? Bool ?? false
                trace.finish(.cancelled, errorCode: "cancelled")
                BridgeLog.shared.append(
                    "ddi_mount_cancelled mutationAttempted=\(attempted) " +
                    "note=\(report["cancelNote"] as? String ?? "none")"
                )
                model?.mountProgress = 0
                return false
            }
            // The worker may have returned a non-cancelled report in the small
            // window before Stop fenced the generation. No state may be
            // mutated or claimed after that fence.
            guard isCurrent(startGeneration), !Task.isCancelled else {
                trace.finish(.cancelled, errorCode: "fenced")
                BridgeLog.shared.append(
                    "ddi_mount_result_fenced generation=\(startGeneration)"
                )
                model?.mountProgress = 0
                return false
            }
            let alreadyMounted = report["alreadyMounted"] as? Bool
            if alreadyMounted == true {
                trace.finish(.notRun, errorCode: "already-mounted")
            }
            let preStateVerifiedAbsent = report["preStateVerifiedAbsent"] as? Bool ?? false
            let provenance = BridgeDDIMountProvenance.classify(
                alreadyMounted: alreadyMounted,
                preStateVerifiedAbsent: preStateVerifiedAbsent
            )
            let installedByThisCall = provenance == .onDevice
            if alreadyMounted == false && !preStateVerifiedAbsent {
                BridgeLog.shared.append("ddi_mount_provenance_rejected reason=pre-state-not-verified")
            }
            let reportedLayout = report["layout"] as? String
            // The mount call alone is not provenance. Until the final runtime
            // probe succeeds, do not claim an on-device mount or its timestamp.
            shared.withLifecycle {
                $0.setDDI(.mounting,
                          layout: reportedLayout,
                          source: installedByThisCall ? nil : provenance.rawValue,
                          detail: installedByThisCall
                              ? "install returned; verifying runtime"
                              : "already mounted before this call")
            }
            let alreadyMountedLabel = alreadyMounted == nil
                ? "missing"
                : (alreadyMounted == true ? "true" : "false")
            BridgeLog.shared.append(
                "ddi_mount_returned alreadyMounted=\(alreadyMountedLabel) " +
                "provenance=\(provenance.rawValue)"
            )
            model?.mountProgress = 0

            guard isCurrent(startGeneration) else { return false }
            probe = BridgeDDIProbe.status()
            guard probe.mounted, probe.xctestReadable else {
                mountedByThisApp = false
                shared.withLifecycle {
                    $0.setDDI(.failed,
                              layout: probe.layout?.rawValue ?? reportedLayout,
                              source: nil,
                              detail: "mount returned but XCTest runtime was not verified readable")
                }
                fail(startGeneration, code: "ddi-mount-unverified",
                     message: "The mount returned but XCTest.framework is still not readable.")
                return false
            }
            let verifiedLayout = probe.layout?.rawValue ?? reportedLayout
            if installedByThisCall {
                mountedByThisApp = true
                shared.withLifecycle {
                    $0.setDDI(.mounted, layout: verifiedLayout, source: provenance.rawValue,
                              detail: "mount verified by app")
                    $0.recordVerifiedOnDeviceMount(layout: verifiedLayout, path: probe.xctestPath)
                }
            } else {
                mountedByThisApp = false
                shared.withLifecycle {
                    $0.setDDI(.mounted, layout: verifiedLayout, source: provenance.rawValue,
                              detail: "already mounted before this call")
                }
            }
            BridgeLog.shared.append(
                "ddi_mount_verified source=\(provenance.rawValue) layout=\(verifiedLayout ?? "unknown")"
            )
        } catch {
            // Stop already fenced this start; a worker error is not a new
            // startup failure and must not overwrite the stopped state.
            if !isCurrent(startGeneration) || Task.isCancelled {
                trace.finish(.cancelled, errorCode: "cancelled")
                BridgeLog.shared.append(
                    "ddi_mount_worker_cancelled error=\(String(error.localizedDescription.prefix(160)))"
                )
                model?.mountProgress = 0
                return false
            }
            let code = (error as? BridgeDDIMountError)?.startupCode ?? "ddi-mount-failed"
            trace.finish(.failed, errorCode: code)
            fail(startGeneration, code: code, message: error.localizedDescription)
            return false
        }
        return true
    }

    /// Waits for the engine's own ready marker and accepts it only while the
    /// same service generation is still current. The ready phase is terminal
    /// for `phase.isActive`, so a generation+service check is used instead
    /// (R5); a Stop still changes the generation and closes the service, so a
    /// late entry cannot be confirmed.
    private func waitForEngineEntry(_ startGeneration: UInt64) async {
        let deadline = Date().addingTimeInterval(180)
        let hostPid = Int32(ProcessInfo.processInfo.processIdentifier)
        while Date() < deadline {
            let snapshot = shared.snapshot()
            guard snapshot.generation == startGeneration,
                  snapshot.serviceRunning,
                  snapshot.phase.isActive || snapshot.phase == .ready else {
                return
            }
            if let marker = shared.engineEntryMarker(),
               (marker["ready"] as? Bool) == true,
               let markerPid = (marker["processIdentifier"] as? NSNumber)?.int32Value,
               markerPid == hostPid,
               let testID = marker["testBundleIdentifier"] as? String,
               testID == BridgeBuild.hostBundleIdentifier,
               let markerGeneration = (marker["dispatchedGeneration"] as? NSNumber)?.uint64Value,
               let dispatchedGeneration = snapshot.dispatchedGeneration,
               markerGeneration == dispatchedGeneration,
               snapshot.engineEntryObserved,
               snapshot.enginePid == markerPid {
                writeEngineEntryConfirmation(
                    marker: marker,
                    pid: markerPid,
                    generation: startGeneration,
                    dispatchedGeneration: dispatchedGeneration
                )
                BridgeLog.shared.append(
                    "engine_entry_confirmed pid=\(markerPid) generation=\(startGeneration) " +
                    "dispatchedGeneration=\(dispatchedGeneration)"
                )
                model?.banner = nil
                model?.refresh()
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let snapshot = shared.snapshot()
        guard snapshot.generation == startGeneration, snapshot.serviceRunning else { return }
        if snapshot.phase == .ready,
           snapshot.engineEntryObserved,
           snapshot.enginePid == hostPid {
            // The real entry and logical readiness exist; only the marker is
            // unusable. Do not latch a terminal one-shot fault for a
            // diagnostic-file problem. The canary separately refuses to run
            // without a usable ready marker.
            BridgeLog.shared.append(
                "engine_entry_marker_unusable pid=\(hostPid) generation=\(startGeneration)"
            )
            model?.refresh()
            return
        }
        fail(startGeneration, code: "engine-entry-timeout",
             message: BridgeL10n.t(
                "The test bootstrap was dispatched but no test method entry was observed within 180 seconds. Reopen the app to retry; this process cannot repeat the one-shot entry.",
                "测试引导已派发，但 180 秒内未观察到测试方法入口。请重新打开应用后再试；当前进程无法再次执行一次性入口。"
             ),
             terminal: true)
    }

    /// Host-side evidence that the real test entry was observed for the same
    /// PID and one-shot dispatch. It is diagnostic only; readiness remains
    /// owned by the engine's own marker and the logical lifecycle.
    private func writeEngineEntryConfirmation(
        marker: [String: Any],
        pid: Int32,
        generation: UInt64,
        dispatchedGeneration: UInt64
    ) {
        let testBundle = marker["testBundleIdentifier"] as? String ?? ""
        let confirmation: [String: Any] = [
            "schema": 1,
            "ready": true,
            "authoredBy": "Bridge host coordinator",
            "processIdentifier": pid,
            "generation": generation,
            "dispatchedGeneration": dispatchedGeneration,
            "testBundleIdentifier": testBundle,
            "hostBundleIdentifier": BridgeBuild.hostBundleIdentifier,
            "bundleIdentifiersMatch": testBundle == BridgeBuild.hostBundleIdentifier,
            "readyMarkerAt": marker["readyAt"] as? String ?? "",
            "confirmedAt": BridgeClock.timestamp(),
        ]
        BridgeAtomicFile.writeJSON(confirmation, to: BridgePaths.engineEntryConfirmedFile)
    }

    private func reopenRequiredMessage(_ code: String) -> String {
        BridgeL10n.t(
            "The test engine faulted after startup began (\(code)). Reopen the app to retry; this process cannot dispatch another one-shot bootstrap.",
            "启动开始后测试引擎发生故障（\(code)）。请重新打开应用后再试；当前进程无法再次派发一次性引导。"
        )
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        shared.withLifecycle { $0.isCurrent(generation) }
    }

    private func fail(_ generation: UInt64, code: String, message: String, terminal: Bool = false) {
        if terminal {
            let latched = shared.withLifecycle {
                $0.failTerminal(generation, code: code, message: message)
            }
            BridgeLog.shared.append("startup_failed code=\(code) terminal=true latched=\(latched)")
        } else {
            shared.withLifecycle { $0.fail(generation, code: code, message: message) }
            BridgeLog.shared.append("startup_failed code=\(code) terminal=false")
        }
        model?.banner = message
        model?.refresh()
    }

    /// A post-dispatch fault cannot be retried in this process. Show the
    /// actionable outcome instead of starting another 180-second wait.
    private func showReopenRequired(code: String) {
        BridgeLog.shared.append("reopen_required code=\(code)")
        model?.banner = reopenRequiredMessage(code)
        model?.refresh()
    }

    private func showBanner(_ message: String) {
        model?.banner = message
    }
}

private extension BridgeTunnelProbeResult {
    var description: String {
        switch self {
        case .reachable: return "reachable"
        case .localNetworkDenied: return "local-network-denied"
        case .unreachable(let detail): return "unreachable:\(detail)"
        }
    }
}
