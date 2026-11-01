#if BRIDGE_PROTOTYPE
import Foundation
import BridgeCore

/// Prototype-only host command surface. It mirrors the file-channel pattern
/// proven by the canary: one JSON command per file, a Keychain random token,
/// the current process PID, and no network listener. It never ships in a
/// public product. The engine lane is separate and is processed by the test
/// method only after a real entry.
@MainActor
final class BridgeHostCommandPoller {
    private weak var model: BridgeAppModel?
    private var timer: Timer?
    private var polling = false

    init(model: BridgeAppModel) {
        self.model = model
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        BridgeLog.shared.append("host_command_poll_started interval=0.5s lane=host")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard !polling, BridgeBuild.prototypeDiagnostics else { return }
        polling = true
        defer { polling = false }
        guard let model else { return }

        for pending in BridgeFileChannel.pending(lane: .host) {
            let command = pending.envelope
            guard let processed = BridgeFileChannel.claim(
                url: pending.url,
                lane: .host,
                identifier: command.id.isEmpty ? "unknown" : command.id
            ) else {
                continue
            }
            // The claimed file still contains the presented token and any
            // rotation material. Remove it after the result is written; never
            // move it into retained evidence or logs.
            defer { try? FileManager.default.removeItem(at: processed) }

            // Reload for every command rather than trusting a token captured
            // before the batch. A rotation earlier in this loop must invalidate
            // an old-token command that follows it without a new poll tick.
            guard let token = try? BridgeInstallToken.loadOrCreate(
                account: BridgeInstallToken.fileChannelAccount
            ) else {
                BridgeFileChannel.writeRejected(command, lane: .host, decision: .invalidToken)
                BridgeLog.shared.append("host_command_rejected id=\(command.id) decision=invalidToken reason=token-unavailable")
                continue
            }
            let decision = BridgeCommandPolicy.validate(
                command,
                lane: .host,
                expectedPid: Int32(ProcessInfo.processInfo.processIdentifier),
                expectedToken: token,
                expectedGeneration: BridgeSharedState.shared.snapshot().generation
            )
            guard decision == .accepted else {
                BridgeFileChannel.writeRejected(command, lane: .host, decision: decision)
                BridgeLog.shared.append("host_command_rejected id=\(command.id) decision=\(String(describing: decision))")
                continue
            }

            let result = execute(command, model: model)
            BridgeFileChannel.writeResult(result, lane: .host)
            BridgeLog.shared.append("host_command action=\(command.action) id=\(command.id) status=\(result.status)")
        }
    }

    private func execute(_ command: BridgeCommandEnvelope, model: BridgeAppModel) -> BridgeCommandResult {
        if command.action == "rotate_token" {
            return executeRotation(command, model: model)
        }
        if command.action == "configure_recovery" {
            return executeRecoveryConfiguration(command, model: model)
        }

        let snapshot = BridgeSharedState.shared.snapshot()
        let ddi = BridgeDDIProbe.status()
        var details: [String: String] = [
            "phase": snapshot.phase.rawValue,
            "serviceRunning": "\(snapshot.serviceRunning)",
            "engineRunning": "\(snapshot.engineRunning)",
            "engineEntryObserved": "\(snapshot.engineEntryObserved)",
            "oneShotDispatched": "\(snapshot.oneShotDispatched)",
            "dispatchedGeneration": "\(snapshot.dispatchedGeneration.map(String.init) ?? "<none>")",
            "generation": "\(snapshot.generation)",
            "hostPid": "\(snapshot.hostPid)",
            "tunnel": snapshot.tunnel.rawValue,
            "tunnelProbe": snapshot.tunnelProbe,
            "ddiMounted": "\(ddi.mounted)",
            "ddiLayout": ddi.layout?.rawValue ?? "<none>",
            "pairingImported": "\(model.pairingImported)",
            "argumentsDigest": BridgeControlArguments.resultDigest(
                action: command.action,
                parameters: command.parameters
            ),
        ]
        if let error = snapshot.lastError { details["lastError"] = error }
        if let canary = BridgeCanaryReportStore.read() {
            details["canaryState"] = canary.state.rawValue
            details["canaryRunID"] = canary.runID
            details["canaryOwnerPid"] = "\(canary.ownerProcessIdentifier)"
            details["canaryOwnerGeneration"] = "\(canary.ownerGeneration)"
            details["canaryProgress"] = "\(canary.passedCount)/\(canary.steps.count)"
            details["canaryOwnerIsCurrentProcess"] = "\(canary.ownerProcessIdentifier == snapshot.hostPid)"
        }
        let liveness = BridgeLivenessStatus.evaluate(
            snapshot: snapshot,
            liveness: BridgeAtomicFile.readJSON(BridgePaths.livenessFile),
            engineHeartbeat: BridgeAtomicFile.readJSON(BridgePaths.engineHeartbeatFile)
        )
        details["livenessHealth"] = liveness.health.rawValue
        details["livenessHealthReason"] = liveness.healthReason
        details["applicationState"] = liveness.applicationState
        details["sceneState"] = liveness.sceneState
        details["applicationStateIsCurrent"] = "\(liveness.applicationStateIsCurrent)"
        details["mainThreadFreshness"] = liveness.mainThread.freshness.rawValue
        details["mainThreadBeatCount"] = "\(liveness.mainThread.count)"
        details["mainThreadBeatAgeMs"] = liveness.mainThread.ageMilliseconds.map(String.init) ?? "<unknown>"
        details["dispatchFreshness"] = liveness.dispatch.freshness.rawValue
        details["dispatchBeatCount"] = "\(liveness.dispatch.count)"
        details["dispatchBeatAgeMs"] = liveness.dispatch.ageMilliseconds.map(String.init) ?? "<unknown>"
        details["engineHeartbeatFreshness"] = liveness.engineHeartbeat.freshness.rawValue
        details["engineHeartbeatCount"] = "\(liveness.engineHeartbeat.count)"
        details["engineHeartbeatAgeMs"] = liveness.engineHeartbeat.ageMilliseconds.map(String.init) ?? "<unknown>"
        details["protectedDataObserved"] = "\(liveness.protectedData.observed)"
        details["protectedDataIsCurrentProcess"] = "\(liveness.protectedData.isCurrentProcess)"
        details["protectedDataInitialAvailable"] =
            liveness.protectedData.initialAvailable.map { "\($0)" } ?? "<unknown>"
        details["protectedDataAvailable"] =
            liveness.protectedData.currentAvailable.map { "\($0)" } ?? "<unknown>"
        details["protectedDataObservedAt"] = liveness.protectedData.observedAt ?? "<unknown>"
        details["protectedDataLastEvent"] = liveness.protectedData.lastEvent ?? "<none>"
        var status = "ok"
        var error: String?

        switch command.action {
        case "status":
            break
        case "start":
            model.start()
            details["dispatched"] = "start"
        case "stop":
            model.stop()
            details["dispatched"] = "stop"
        case "resume":
            model.resume()
            details["dispatched"] = "resume"
        case "shutdown":
            model.performAuthenticatedShutdown(identifier: command.id)
            details["dispatched"] = "shutdown"
        case "start_tunnel":
            model.startTunnel()
            details["dispatched"] = "start_tunnel"
        case "stop_tunnel":
            model.stopTunnel()
            details["dispatched"] = "stop_tunnel"
        case "download_ddi":
            model.downloadDDI()
            details["dispatched"] = "download_ddi"
        case "mount_ddi":
            model.mountOnly()
            details["dispatched"] = "mount_ddi"
        case "remove_ddi":
            switch model.removeDDI() {
            case .started(let generation):
                details["dispatched"] = "remove_ddi"
                details["removalGeneration"] = "\(generation)"
            case .refused(let code, let message):
                status = "rejected"
                error = message
                details["decision"] = code
            }
        case "ddi_stage_probe":
            switch model.runStageProbe() {
            case .started(let generation):
                details["dispatched"] = "ddi_stage_probe"
                details["probeGeneration"] = "\(generation)"
                details["reportFile"] = BridgePaths.ddiStageProbeFile.lastPathComponent
            case .refused(let code, let message):
                status = "rejected"
                error = message
                details["decision"] = code
            }
        default:
            status = "unsupported"
            error = "Unsupported host action."
        }

        // The result is bound to the generation that authorized the request.
        // A successful start/stop/resume legitimately advances the shared
        // generation; report that post-action value separately so a controller
        // never mistakes the transition for a stale result.
        let resulting = BridgeSharedState.shared.snapshot()
        details["requestedGeneration"] = "\(snapshot.generation)"
        details["resultingGeneration"] = "\(resulting.generation)"

        return BridgeCommandResult(
            id: command.id,
            action: command.action,
            status: status,
            authoredBy: "Bridge host coordinator",
            generation: snapshot.generation,
            details: details,
            error: error
        )
    }

    /// Applies only the supplied fields and reports actual post-apply state.
    /// The LAN URL is non-secret; no token ever appears in the result.
    private func executeRecoveryConfiguration(
        _ command: BridgeCommandEnvelope,
        model: BridgeAppModel
    ) -> BridgeCommandResult {
        do {
            let configuration = try model.configureRecovery(
                autoStart: command.autoStart,
                lanEnabled: command.lanEnabled,
                controlEnabled: command.controlEnabled,
                controlKey: command.controlKey
            )
            var details: [String: String] = [
                "autoStart": "\(configuration.autoStart)",
                "lanEnabled": "\(configuration.lanEnabled)",
                "lanListening": "\(configuration.lanListening)",
                "controlEnabled": "\(configuration.controlEnabled)",
                "controlListening": "\(configuration.controlListening)",
            ]
            if let url = configuration.lanURL { details["lanURL"] = url }
            if let url = configuration.controlURLs.first { details["controlURL"] = url }
            if let fingerprint = configuration.controlKeyFingerprint {
                details["controlKeyFingerprint"] = fingerprint
            }
            details["argumentsDigest"] = BridgeControlArguments.resultDigest(
                action: command.action,
                parameters: command.parameters
            )
            return BridgeCommandResult(
                id: command.id,
                action: command.action,
                status: "ok",
                authoredBy: "Bridge host coordinator",
                generation: BridgeSharedState.shared.snapshot().generation,
                details: details
            )
        } catch {
            return BridgeCommandResult(
                id: command.id,
                action: command.action,
                status: "rejected",
                authoredBy: "Bridge host coordinator",
                generation: BridgeSharedState.shared.snapshot().generation,
                details: [
                    "argumentsDigest": BridgeControlArguments.resultDigest(
                        action: command.action,
                        parameters: command.parameters
                    ),
                ],
                error: error.localizedDescription
            )
        }
    }

    /// Rotation returns an acknowledgement only. The replacement and old
    /// tokens never appear in details, errors or logs.
    private func executeRotation(
        _ command: BridgeCommandEnvelope,
        model: BridgeAppModel
    ) -> BridgeCommandResult {
        let outcome = model.rotatePrototypeToken(replacementToken: command.replacementToken)
        let status: String
        let error: String?
        switch outcome {
        case .rotated:
            status = "ok"
            error = nil
        case .invalidReplacement:
            status = "rejected"
            error = "Replacement token is not canonical."
        case .unchanged:
            status = "rejected"
            error = "Replacement token is unchanged."
        case .failed:
            status = "error"
            error = "Token rotation failed."
        }
        return BridgeCommandResult(
            id: command.id,
            action: command.action,
            status: status,
            authoredBy: "Bridge host coordinator",
            generation: BridgeSharedState.shared.snapshot().generation,
            details: [
                "acknowledgement": status == "ok" ? "token rotated" : "token not changed",
                "argumentsDigest": BridgeControlArguments.resultDigest(
                    action: command.action,
                    parameters: command.parameters
                ),
            ],
            error: error
        )
    }
}

#endif
