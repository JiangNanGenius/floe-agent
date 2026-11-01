import XCTest
import UIKit
import BridgeCore
import Darwin

/// The actual embedded XCTest method. It is loaded only after the DDI is
/// mounted, calls BridgeCore on entry and in its ongoing loop, and never
/// returns for a normal Stop: the initialized driver is retained so a later
/// Start can reuse it without a second `_XCTestMain`.
///
/// The long-lived method is deliberately `async` and suspends between bounded
/// iterations. Instead of relying on a nested `RunLoop.run` to service
/// main-queue work, it yields the MainActor executor explicitly, so XCTest's
/// own run loop can schedule host timers, command pollers and cancellation
/// fences while the driver stays alive. The one-shot main-thread entry and the
/// retained-driver/Stop semantics are unchanged.
@MainActor
final class BridgeEngineTests: XCTestCase {
    private let files = BridgeTestFiles()
    private var heartbeat: BridgeEngineHeartbeat!
    private var processedIDs = Set<String>()
    private var lastInvalidSignature: String?
    private var testBundlePath = "<missing>"
    private var testBundleIdentifier = "<missing>"
    private var containsUITests = false
    private var hostBundleIdentifier = "<missing>"
    /// The last app this engine actually observed in the foreground and then
    /// acted on/read. Home uses it as the source app whose departure is
    /// evidence, so a Calculator session is not judged through Settings state.
    private var lastControlledBundleIdentifier: String?
    /// The one process-lifetime RPC executor + frame provider registered after
    /// the real test entry is accepted. The registry keeps this object alive
    /// and first-wins, so a listener restart cannot replace it.
    private var rpcRuntime: BridgeEngineRPCRuntime?

    /// Thread-safe, content-free count of XCTest issues recorded while an SDK
    /// call is active. Accessed from the nonisolated `recordIssue` override.
    nonisolated private let issueCapture = BridgeEngineIssueCapture()

    /// Keep XCTest's normal failure recording (including bootstrap/lifecycle
    /// handling) while making a returned-but-recorded issue visible to the
    /// scoped call classification. Product builds forward a sanitized issue
    /// with the same type/severity/source context and no description, error or
    /// attachments, so element values typed earlier cannot escape into an
    /// xcresult. The legacy prototype can retain the original object only
    /// behind the literal diagnostic flag.
    nonisolated override func record(_ issue: XCTIssue) {
        issueCapture.noteIssue()
        if BridgeBuild.prototypeDiagnostics {
            super.record(issue)
            return
        }
        super.record(BridgeEngineIssueSanitizer.sanitized(issue))
    }

    func testBridgeEngineLoop() async throws {
        continueAfterFailure = true
        executionTimeAllowance = 86_400
        files.ensureDirectories()
        BridgeLog.shared.configure(url: files.logURL)
        files.log("test_method_entered name=\(name) pid=\(ProcessInfo.processInfo.processIdentifier)")

        let environment = ProcessInfo.processInfo.environment
        if let path = environment["XCTestBundlePath"], !path.isEmpty {
            testBundlePath = path
        }
        if let info = NSDictionary(contentsOfFile: testBundlePath + "/Info.plist") as? [String: Any] {
            testBundleIdentifier = info["CFBundleIdentifier"] as? String ?? "<missing>"
            containsUITests = (info["XCTContainsUITests"] as? NSNumber)?.boolValue ?? false
        }
        hostBundleIdentifier = Bundle.main.bundleIdentifier ?? "<missing>"

        let snapshot = BridgeSharedState.shared.snapshot()
        let bootstrapGeneration = snapshot.dispatchedGeneration ?? snapshot.generation
        let accepted = BridgeSharedState.shared.markEngineEntry(
            generation: bootstrapGeneration,
            testMethod: name,
            testBundleIdentifier: testBundleIdentifier,
            hostBundleIdentifier: hostBundleIdentifier,
            containsUITests: containsUITests,
            threadIsMain: pthread_main_np() != 0
        )
        guard accepted else {
            files.log("engine_entry_rejected generation=\(bootstrapGeneration) phase=\(snapshot.phase.rawValue)")
            let rejection: [String: Any] = [
                "ready": false,
                "authoredBy": "XCTest test method",
                "reason": "BridgeCore rejected the entry (stale generation or bootstrap not dispatched)",
                "generation": bootstrapGeneration,
                "phase": snapshot.phase.rawValue,
                "processIdentifier": ProcessInfo.processInfo.processIdentifier,
            ]
            BridgeAtomicFile.writeJSON(rejection,
                                       to: BridgePaths.diagnostics.appendingPathComponent("engine-entry-rejected.json"))
            return
        }

        heartbeat = BridgeEngineHeartbeat(files: files, testMethod: name)
        heartbeat.ensureRunning()

        let runtime = BridgeEngineRPCRuntime(issueCapture: issueCapture, files: files)
        let registration = BridgeRuntime.engineRegistry.register(owner: runtime.owner,
                                                                 executor: runtime)
        switch registration {
        case .registered(let generation):
            let framesRegistered = BridgeRuntime.screenFrames.register(owner: runtime.owner,
                                                                       provider: runtime)
            runtime.markEntryAccepted()
            rpcRuntime = runtime
            files.log("rpc_engine_registered generation=\(generation) owner=\(runtime.owner) frames=\(framesRegistered)")
        case .alreadyRegistered(let generation):
            // A repeated entry in the same process must reuse the registered
            // object (and therefore its gate) rather than creating a second
            // executor with a different serialization slot.
            let existing = BridgeRuntime.engineRegistry.currentExecutor() as? BridgeEngineRPCRuntime
            let selected = existing ?? runtime
            selected.sdk.rebind(issueCapture: issueCapture)
            selected.markEntryAccepted()
            _ = BridgeRuntime.screenFrames.register(owner: selected.owner, provider: selected)
            rpcRuntime = selected
            files.log("rpc_engine_already_registered generation=\(generation) owner=\(selected.owner)")
        case .rejected(let reason):
            files.log("rpc_engine_registration_rejected reason=\(reason)")
        }

        files.log("engine_loop_started heartbeat=2.0s command_lane=engine cooperative=async")

        // Do not return. Returning would let the XCTest driver exit this
        // process, which is exactly the teardown a normal Stop must avoid.
        // Suspending between iterations releases the MainActor executor; the
        // XCTest run loop keeps running and can service the host's main-queue
        // work while this task remains alive indefinitely.
        var sleepCancellationLogged = false
        while true {
            autoreleasepool {
                let current = BridgeSharedState.shared.snapshot()
                if current.engineRunning {
                    heartbeat.ensureRunning()
                    processPendingCommands()
                } else {
                    heartbeat.stop()
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                if !sleepCancellationLogged {
                    sleepCancellationLogged = true
                    files.log("engine_loop_sleep_cancelled driver_preserved=1")
                    BridgeSharedState.shared.withLifecycle {
                        $0.noteEngineFailure(
                            pid: Int32(ProcessInfo.processInfo.processIdentifier),
                            code: "engine-task-cancelled",
                            message: "The test session was cancelled. Reopen the app to initialize a new session."
                        )
                    }
                }
                // A cancelled task's subsequent sleeps throw immediately.
                // Keep this failed driver alive at a bounded idle rate until
                // the user reopens the app, without spinning on Task.yield().
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(200)) {
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func processPendingCommands() {
        // Product builds never read, claim or execute the legacy file lane.
        // This guard is deliberately before the first pending-file read, SDK
        // gate acquisition and install-token load-or-create: a stale pending
        // file must not mint a legacy key or bypass the RPC client
        // approval/grant/replay controls. The historical canary behavior stays
        // available only with the literal prototype diagnostic flag on.
        guard BridgeBuild.prototypeDiagnostics else { return }
        // The legacy file lane shares the same SDK serialization slot as RPC
        // actions and frame capture. If an RPC action owns it, leave the file
        // commands pending and retry on the next bounded tick instead of
        // starting a parallel XCTest call.
        let pendingCommands = BridgeFileChannel.pending(lane: .engine)
        guard !pendingCommands.isEmpty else { return }
        let sharedGate = rpcRuntime?.gate
        if let sharedGate {
            guard sharedGate.tryAcquire() else { return }
        }
        defer { sharedGate?.release() }
        for pending in pendingCommands {
            let command = pending.envelope
            // Reload the Keychain value for each command. A host rotation in
            // the same poll batch must reject an old-token command that follows
            // it instead of reusing the token captured before the batch.
            guard let token = (try? BridgeInstallToken.load(account: BridgeInstallToken.fileChannelAccount))
                ?? (try? BridgeInstallToken.loadOrCreate(account: BridgeInstallToken.fileChannelAccount)) else {
                continue
            }
            let decision = BridgeCommandPolicy.validate(
                command,
                lane: .engine,
                expectedPid: Int32(ProcessInfo.processInfo.processIdentifier),
                expectedToken: token,
                expectedGeneration: BridgeSharedState.shared.snapshot().generation
            )
            guard let processedURL = BridgeFileChannel.claim(
                url: pending.url,
                lane: .engine,
                identifier: command.id
            ) else {
                continue
            }
            guard decision == .accepted else {
                BridgeFileChannel.writeRejected(command, lane: .engine, decision: decision)
                files.log("command_rejected id=\(command.id) decision=\(String(describing: decision))")
                try? FileManager.default.removeItem(at: processedURL)
                continue
            }
            guard !processedIDs.contains(command.id) else {
                try? FileManager.default.removeItem(at: processedURL)
                continue
            }
            processedIDs.insert(command.id)
            files.log("command_received id=\(command.id) action=\(command.action)")
            let result = execute(command)
            BridgeFileChannel.writeResult(result, lane: .engine)
            files.log("command_result id=\(command.id) action=\(command.action) status=\(result.status)")
            try? FileManager.default.removeItem(at: processedURL)
        }
    }

    private func execute(_ command: BridgeCommandEnvelope) -> BridgeCommandResult {
        let snapshot = BridgeSharedState.shared.snapshot()
        // The generation that authorized this command. LAN commands carry it
        // explicitly; a legacy file-lane command uses the generation observed
        // when execution began. The final mutation gate compares this exact
        // value with the live lifecycle immediately before each SDK call.
        let commandGeneration = command.expectedGeneration ?? snapshot.generation
        var details: [String: String] = [
            "hostBundleIdentifier": hostBundleIdentifier,
            "testBundleIdentifier": testBundleIdentifier,
            "bundleIdentifiersMatch": "\(testBundleIdentifier == hostBundleIdentifier)",
            "XCTContainsUITests": "\(containsUITests)",
            "testBundlePath": testBundlePath,
            "threadIsMain": "\(Thread.isMainThread)",
            "generation": "\(snapshot.generation)",
            "engineRunning": "\(snapshot.engineRunning)",
        ]
        var status = "ok"
        var error: String?
        currentCommandID = command.id
        // Non-secret binding of the effective arguments. The LAN broker checks
        // this against the ledger record so a stored result cannot be paired
        // with a different authorized argument shape. Generic actions use the
        // normalized parameters (defaults filled), matching the LAN ledger.
        let genericParameters = BridgeControlAction.all.contains(command.action)
            ? controlParameters(command)
            : nil
        let digestParameters = BridgeControlAction.all.contains(command.action)
            ? genericParameters
            : command.parameters
        details["argumentsDigest"] = BridgeControlArguments.resultDigest(
            action: command.action,
            parameters: digestParameters
        )
        if let summary = genericParameters?.summaryJSON() {
            // Same normalized arguments, never the raw text. This is the
            // result-side copy that pairs with the request/command copies.
            details["parameters"] = summary
        }

        switch command.action {
        case "status":
            details["phase"] = snapshot.phase.rawValue
            details["enginePid"] = "\(snapshot.enginePid ?? -1)"
            details["xcuiApplicationClassLoaded"] = "\(NSClassFromString("XCUIApplication") != nil)"
            details["xcuiScreenClassLoaded"] = "\(NSClassFromString("XCUIScreen") != nil)"
            details["xcuiDeviceClassLoaded"] = "\(NSClassFromString("XCUIDevice") != nil)"
            if Thread.isMainThread {
                details["applicationState"] = MainActor.assumeIsolated {
                    applicationStateName(UIApplication.shared.applicationState)
                }
            } else {
                details["applicationState"] = "unavailable-on-background-thread"
            }
        case "screenshot":
            let outcome = screenshot()
            status = outcome.status
            error = outcome.error
            details.merge(outcome.details) { _, new in new }
        case "open_settings":
            let outcome = openSettings()
            status = outcome.status
            error = outcome.error
            details.merge(outcome.details) { _, new in new }
        case "tap_general":
            let outcome = tapGeneral()
            status = outcome.status
            error = outcome.error
            details.merge(outcome.details) { _, new in new }
        case "home":
            let outcome = pressHome()
            status = outcome.status
            error = outcome.error
            details.merge(outcome.details) { _, new in new }
        case "stop_engine":
            let stopped = BridgeSharedState.shared.withLifecycle {
                $0.requestEngineStop(reason: "engine-command")
            }
            heartbeat.stop()
            status = stopped ? "ok" : "not_ready"
            details["driverRetained"] = "true"
            details["note"] = "The test method remains alive; Start/Resume reuses this driver."
        case BridgeControlAction.activateApp:
            if let parameters = genericParameters {
                let outcome = activateGenericApp(parameters, commandGeneration: commandGeneration)
                status = outcome.status
                error = outcome.error
                details.merge(outcome.details) { _, new in new }
            } else {
                status = "rejected"
                error = "Invalid automation parameters."
                details["parameterDecision"] = "rejected"
            }
        case BridgeControlAction.inspectUI:
            if let parameters = genericParameters {
                let outcome = inspectTargetUI(parameters)
                status = outcome.status
                error = outcome.error
                details.merge(outcome.details) { _, new in new }
            } else {
                status = "rejected"
                error = "Invalid automation parameters."
                details["parameterDecision"] = "rejected"
            }
        case BridgeControlAction.tap:
            if let parameters = genericParameters {
                let outcome = tapTarget(parameters, commandGeneration: commandGeneration)
                status = outcome.status
                error = outcome.error
                details.merge(outcome.details) { _, new in new }
            } else {
                status = "rejected"
                error = "Invalid automation parameters."
                details["parameterDecision"] = "rejected"
            }
        case BridgeControlAction.swipe:
            if let parameters = genericParameters {
                let outcome = swipeTarget(parameters, commandGeneration: commandGeneration)
                status = outcome.status
                error = outcome.error
                details.merge(outcome.details) { _, new in new }
            } else {
                status = "rejected"
                error = "Invalid automation parameters."
                details["parameterDecision"] = "rejected"
            }
        case BridgeControlAction.typeText:
            if let parameters = genericParameters {
                let outcome = typeTextIntoTarget(parameters, commandGeneration: commandGeneration)
                status = outcome.status
                error = outcome.error
                details.merge(outcome.details) { _, new in new }
            } else {
                status = "rejected"
                error = "Invalid automation parameters."
                details["parameterDecision"] = "rejected"
            }
        default:
            status = "unsupported"
            error = "Unsupported engine action."
        }

        // Keep the immutable request generation in the result and report the
        // post-action generation separately. A host-side start/stop/resume can
        // legitimately advance the shared generation while this engine command
        // is in flight; that must not be read as a stale success or failure.
        let resulting = BridgeSharedState.shared.snapshot()
        details["requestedGeneration"] = "\(snapshot.generation)"
        details["resultingGeneration"] = "\(resulting.generation)"

        return BridgeCommandResult(
            id: command.id,
            action: command.action,
            status: status,
            authoredBy: "BridgeCore test engine",
            generation: snapshot.generation,
            details: details,
            error: error
        )
    }

    private struct Outcome {
        var status: String
        var details: [String: String]
        var error: String?
    }

    private func screenshot() -> Outcome {
        var screenShot: XCUIScreenshot?
        let captureError = perform(stage: "screenshot") {
            screenShot = XCUIScreen.main.screenshot()
        }
        if let captureError {
            return Outcome(status: "error", details: [:], error: captureError.localizedDescription)
        }
        guard let screenShot else {
            return Outcome(status: "error", details: [:], error: "XCUIScreen returned no screenshot")
        }
        let data = screenShot.pngRepresentation
        guard !data.isEmpty else {
            return Outcome(status: "error", details: [:], error: "The screenshot PNG was empty")
        }
        let fileName = "screenshot-\(BridgeAtomicFile.safeIdentifier(currentCommandID))-\(Int(Date().timeIntervalSince1970)).png"
        let url = BridgePaths.diagnostics.appendingPathComponent(fileName)
        do {
            try BridgeAtomicFile.write(data, to: url)
        } catch {
            return Outcome(status: "error", details: [:], error: error.localizedDescription)
        }
        let image = screenShot.image
        return Outcome(status: "ok", details: [
            "screenshotFile": fileName,
            "screenshotBytes": "\(data.count)",
            "pixelWidth": "\(Int(image.size.width * image.scale))",
            "pixelHeight": "\(Int(image.size.height * image.scale))",
        ], error: nil)
    }

    private var currentCommandID = "screenshot"

    private func openSettings() -> Outcome {
        let app = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        var foreground = false
        var launchUsed = false
        var stageError: NSError?
        stageError = perform(stage: "activate") { app.activate() }
        _ = perform(stage: "wait-activate") {
            foreground = app.wait(for: .runningForeground, timeout: 15)
        }
        if !foreground {
            launchUsed = true
            _ = perform(stage: "launch") { app.launch() }
            _ = perform(stage: "wait-launch") {
                foreground = app.wait(for: .runningForeground, timeout: 15)
            }
        }
        var state = "unknown"
        _ = perform(stage: "state") { state = self.stateName(app.state) }
        if foreground { noteControlledApp("com.apple.Preferences") }
        var details = ["foreground": "\(foreground)", "state": state, "launchUsed": "\(launchUsed)"]
        if let stageError { details["stageError"] = stageError.localizedDescription }
        return Outcome(status: foreground ? "ok" : "error",
                       details: details,
                       error: foreground ? nil : "Settings did not reach runningForeground")
    }

    private struct SettingsCandidateElement {
        var model: BridgeSettingsCandidate
        var element: XCUIElement
    }

    private func tapGeneral() -> Outcome {
        let app = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        var state = "unknown"
        _ = perform(stage: "state") { state = self.stateName(app.state) }
        guard state == "runningForeground" else {
            return Outcome(status: "not_foreground",
                          details: ["state": state],
                          error: "Settings is not in the foreground; run open_settings first")
        }
        noteControlledApp("com.apple.Preferences")

        var facts = BridgeSettingsRootFacts(
            isForeground: false,
            hasRootNavigationTitle: false,
            hasSettingsSearchField: false,
            hasBackNavigationButton: true,
            destinationVisible: false
        )
        var rootEvidence = ""
        _ = perform(stage: "root-facts") {
            let observed = self.settingsRootFacts(app)
            facts = observed.facts
            rootEvidence = observed.evidence ?? ""
        }
        let commonDetails: [String: String] = [
            "rootEvidence": rootEvidence,
            "rootTitle": "\(facts.hasRootNavigationTitle)",
            "searchField": "\(facts.hasSettingsSearchField)",
            "backButton": "\(facts.hasBackNavigationButton)",
        ]
        if facts.destinationVisible {
            return Outcome(
                status: "unverified",
                details: commonDetails.merging([
                    "tapPerformed": "false",
                    "destinationVerified": "true",
                ]) { _, new in new },
                error: "The General destination was already visible before any tap; no click was observed."
            )
        }

        var window = BridgeScreenRect(x: 0, y: 0, width: 0, height: 0)
        _ = perform(stage: "window") { window = self.settingsWindow(app) }
        var scrollAttempts = 0
        var lastCandidates: [BridgeSettingsCandidate] = []
        var lastCandidateDetail = ""
        var lastRefusal = "none"

        while true {
            var candidates: [SettingsCandidateElement] = []
            var ambiguous = false
            _ = perform(stage: "elements") {
                let observed = self.settingsCandidates(app)
                candidates = observed.candidates
                ambiguous = observed.ambiguous
                lastCandidateDetail = observed.detail
            }
            if ambiguous {
                return Outcome(
                    status: "ambiguous_or_missing",
                    details: commonDetails.merging([
                        "candidates": "\(candidates.count)",
                        "candidateDetail": lastCandidateDetail,
                    ]) { _, new in new },
                    error: "More than one General/通用 candidate; refusing to guess"
                )
            }
            lastCandidates = candidates.map { $0.model }
            var overlays: [BridgeScreenRect] = []
            _ = perform(stage: "overlays") { overlays = self.settingsOverlays(app) }
            let decision = BridgeSettingsTapPolicy.evaluate(
                facts: facts,
                candidates: lastCandidates,
                window: window,
                overlays: overlays,
                scrollAttemptsUsed: scrollAttempts
            )
            switch decision {
            case .tap(let index):
                guard candidates.indices.contains(index) else {
                    return Outcome(status: "unverified", details: commonDetails,
                                   error: "The selected General target disappeared before the tap.")
                }
                let target = candidates[index]
                var tapCall: SDKCallResult?
                tapCall = performSDKCall(stage: "tap") {
                    // A coordinate at the verified element's center is a real
                    // tap on that element, not an arbitrary screen guess.
                    target.element.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                    ).tap()
                }
                guard let tapCall else {
                    return Outcome(
                        status: "error",
                        details: commonDetails.merging([
                            "strategy": target.model.strategy,
                            "targetFrame": self.rectString(target.model.frame),
                            "tapPerformed": "false",
                        ]) { _, new in new },
                        error: "The tap admission allowed the mutation but no call result was produced; no effect is claimed."
                    )
                }
                if tapCall.error != nil {
                    return Outcome(
                        status: "error",
                        details: commonDetails.merging([
                            "strategy": target.model.strategy,
                            "targetFrame": self.rectString(target.model.frame),
                            "tapPerformed": tapCall.outcome.mutationDispatchClaim(),
                            "callOutcome": tapCall.outcome.classification,
                            "recordedIssueCount": "\(tapCall.outcome.recordedIssueCount)",
                            "outcomeUnknown": "true",
                        ]) { _, new in new },
                        error: "The General tap was entered but threw; whether an effect occurred is unknown. Do not retry blindly."
                    )
                }
                let destination = waitForSettingsDestination(app)
                let verified = destination != nil
                var details = commonDetails.merging([
                    "strategy": target.model.strategy,
                    "targetLabel": target.model.label,
                    "targetFrame": rectString(target.model.frame),
                    "tapPerformed": tapCall.outcome.mutationDispatchClaim(actualEffectVerified: verified),
                    "callOutcome": tapCall.outcome.classification,
                    "recordedIssueCount": "\(tapCall.outcome.recordedIssueCount)",
                    "destinationVerified": "\(verified)",
                    "destinationLabel": destination ?? "",
                    "scrollAttempts": "\(scrollAttempts)",
                ]) { _, new in new }
                if tapCall.outcome.recordedIssueCount > 0 {
                    details["callRecordedIssue"] = "true"
                    if !verified { details["outcomeUnknown"] = "true" }
                }
                if !verified {
                    details["searchOverlays"] = "\(overlays.count)"
                }
                return Outcome(
                    status: verified ? "ok" : "unverified",
                    details: details,
                    error: verified
                        ? nil
                        : (tapCall.outcome.recordedIssueCount > 0
                            ? "The General tap returned but recorded an XCTest issue, and no About/Software Update destination was verified; the effect is unknown."
                            : "The General cell was tapped but no About/Software Update destination was verified.")
                )
            case .scroll(let direction, let attempt):
                guard attempt <= BridgeSettingsCanaryPolicy.maximumScrollAttempts else {
                    return Outcome(
                        status: "unverified",
                        details: commonDetails.merging([
                            "refusal": BridgeSettingsTapRefusal.targetNotReachable.rawValue,
                            "scrollAttempts": "\(scrollAttempts)",
                        ]) { _, new in new },
                        error: "General remained outside the unobscured window interior."
                    )
                }
                let scrollError = scrollSettings(app, direction: direction)
                if let scrollError {
                    return Outcome(
                        status: "error",
                        details: commonDetails.merging([
                            "scrollDirection": direction.rawValue,
                        ]) { _, new in new },
                        error: scrollError.localizedDescription
                    )
                }
                scrollAttempts = attempt
                _ = perform(stage: "window-refresh") { window = self.settingsWindow(app) }
            case .alreadyAtDestination:
                return Outcome(
                    status: "unverified",
                    details: commonDetails.merging([
                        "tapPerformed": "false",
                        "destinationVerified": "true",
                    ]) { _, new in new },
                    error: "The General destination was already visible before any tap; no click was observed."
                )
            case .refuse(let reason):
                lastRefusal = reason.rawValue
                let status = reason == .rootUnconfirmed ? "not_root" : "unverified"
                let error: String
                switch reason {
                case .notForeground:
                    error = "Settings is not in the foreground."
                case .rootUnconfirmed:
                    error = "Settings is not at a confirmed root screen; refusing to choose General."
                case .ambiguousTarget:
                    error = "More than one General/通用 candidate; refusing to guess."
                case .missingTarget:
                    error = "No General/通用 candidate was found."
                case .invalidWindow:
                    error = "The Settings window bounds were not usable."
                case .targetNotReachable:
                    error = "General could not be brought into the unobscured window interior."
                }
                return Outcome(
                    status: status,
                    details: commonDetails.merging([
                        "refusal": lastRefusal,
                        "candidates": "\(lastCandidates.count)",
                        "candidateDetail": lastCandidateDetail,
                        "scrollAttempts": "\(scrollAttempts)",
                    ]) { _, new in new },
                    error: error
                )
            }
        }
    }

    private func settingsRootFacts(
        _ app: XCUIApplication
    ) -> (facts: BridgeSettingsRootFacts, evidence: String?) {
        let foreground = app.state == .runningForeground
        let titlePredicate = NSPredicate(format: "identifier IN %@", ["Settings", "设置"])
        let hasTitle = app.navigationBars.matching(titlePredicate).firstMatch.exists
        let hasSearch = app.searchFields.firstMatch.exists
        let backPredicate = NSPredicate(
            format: "identifier == %@ OR label IN %@",
            "BackButton",
            ["Settings", "设置", "General", "通用"]
        )
        let hasBack = app.navigationBars.buttons.matching(backPredicate).firstMatch.exists
        let facts = BridgeSettingsRootFacts(
            isForeground: foreground,
            hasRootNavigationTitle: hasTitle,
            hasSettingsSearchField: hasSearch,
            hasBackNavigationButton: hasBack,
            destinationVisible: settingsDestinationVisible(app)
        )
        return (facts, BridgeSettingsTapPolicy.rootEvidence(facts))
    }

    private func settingsDestinationVisible(_ app: XCUIApplication) -> Bool {
        for label in BridgeSettingsCanaryPolicy.destinationLabels
        where app.staticTexts[label].exists || app.cells[label].exists {
            return true
        }
        return false
    }

    private func waitForSettingsDestination(_ app: XCUIApplication) -> String? {
        // Four fixed labels with a short per-label wait keep the total check
        // bounded instead of multiplying a long timeout by the label count.
        for label in BridgeSettingsCanaryPolicy.destinationLabels {
            if app.staticTexts[label].waitForExistence(timeout: 0.5) { return label }
            if app.cells[label].exists { return label }
        }
        return nil
    }

    private func settingsCandidates(
        _ app: XCUIApplication
    ) -> (candidates: [SettingsCandidateElement], ambiguous: Bool, detail: String) {
        let predicate = NSPredicate(format: "label IN %@", BridgeSettingsCanaryPolicy.allowedLabels)
        let strategies: [(String, XCUIElementQuery)] = [
            ("cell", app.cells),
            ("staticText", app.staticTexts),
            ("button", app.buttons),
        ]
        for (name, query) in strategies {
            var seen = Set<String>()
            var candidates: [SettingsCandidateElement] = []
            for element in query.matching(predicate).allElementsBoundByIndex where element.exists {
                let frame = screenRect(element.frame)
                guard !frame.isEmpty else { continue }
                let key = "\(frame.x),\(frame.y),\(frame.width),\(frame.height)"
                guard seen.insert(key).inserted else { continue }
                candidates.append(SettingsCandidateElement(
                    model: BridgeSettingsCandidate(label: element.label, frame: frame, strategy: name),
                    element: element
                ))
            }
            if !candidates.isEmpty {
                let detail = candidates.map {
                    "\($0.model.strategy) label=\($0.model.label) frame=\(rectString($0.model.frame))"
                }.joined(separator: " | ")
                return (candidates, candidates.count > 1, detail)
            }
        }
        return ([], false, "")
    }

    private func settingsWindow(_ app: XCUIApplication) -> BridgeScreenRect {
        let window = app.windows.firstMatch
        if window.exists { return screenRect(window.frame) }
        return screenRect(app.frame)
    }

    private func settingsOverlays(_ app: XCUIApplication) -> [BridgeScreenRect] {
        var overlays: [BridgeScreenRect] = []
        for field in app.searchFields.allElementsBoundByIndex where field.exists {
            let frame = screenRect(field.frame)
            if !frame.isEmpty { overlays.append(frame) }
        }
        // Some Settings versions expose the floating search affordance as a
        // button/container rather than a search field. Include only short
        // labelled elements so a full-screen container cannot mask every row.
        let predicate = NSPredicate(
            format: "label IN %@ OR identifier IN %@",
            ["Search", "搜索"],
            ["Search", "search"]
        )
        for query in [app.buttons, app.otherElements] {
            for element in query.matching(predicate).allElementsBoundByIndex where element.exists {
                let frame = screenRect(element.frame)
                guard !frame.isEmpty, frame.height <= 140 else { continue }
                overlays.append(frame)
            }
        }
        return overlays
    }

    private func scrollSettings(_ app: XCUIApplication, direction: BridgeSettingsScrollDirection) -> NSError? {
        // A coordinate drag in the middle of the window avoids starting on the
        // bottom search field. It is a bounded scroll gesture, not a tap.
        let startY = direction == .up ? 0.58 : 0.32
        let endY = direction == .up ? 0.28 : 0.62
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
        let error = perform(stage: "scroll-\(direction.rawValue)") {
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
        return error
    }

    private func screenRect(_ rect: CGRect) -> BridgeScreenRect {
        BridgeScreenRect(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height)
        )
    }

    private func rectString(_ rect: BridgeScreenRect) -> String {
        String(format: "%.0f,%.0f,%.0f,%.0f", rect.x, rect.y, rect.width, rect.height)
    }

    private func hostApplicationState() -> String {
        Thread.isMainThread
            ? MainActor.assumeIsolated { applicationStateName(UIApplication.shared.applicationState) }
            : "unknown"
    }

    /// Home is verified against the app this engine actually controlled and
    /// the public SpringBoard state. A source-app departure alone is retained
    /// as `source-left-foreground-only`; it is not upgraded to a Home or
    /// lock-screen claim. The legacy no-argument `home` command still works;
    /// the source is the last app observed foreground by a control/read action.
    private func pressHome() -> Outcome {
        let springboardBundle = "com.apple.springboard"
        let sourceBundle = lastControlledBundleIdentifier.flatMap {
            $0 == springboardBundle ? nil : $0
        }
        let sourceApp = sourceBundle.map { XCUIApplication(bundleIdentifier: $0) }
        let springboard = XCUIApplication(bundleIdentifier: springboardBundle)

        var sourceBefore = "unknown"
        if let sourceApp {
            _ = perform(stage: "home-source-before") {
                sourceBefore = self.stateName(sourceApp.state)
            }
        }
        var springboardBefore = "unknown"
        _ = perform(stage: "home-springboard-before") {
            springboardBefore = self.stateName(springboard.state)
        }
        let hostBefore = hostApplicationState()

        let pressCall = performSDKCall(stage: "home") {
            XCUIDevice.shared.press(.home)
        }
        let started = Date()
        var observation = BridgeHomeObservation(
            sourceBundleIdentifier: sourceBundle,
            sourceStateBefore: sourceBefore,
            sourceStateAfter: sourceBefore,
            springboardStateBefore: springboardBefore,
            springboardStateAfter: springboardBefore,
            hostStateBefore: hostBefore,
            hostStateAfter: hostBefore,
            pressReturned: pressCall.outcome.returned
        )
        var assessment = BridgeHomeEvidence.assess(observation)

        // Observe after both a returned press and a failed call: a raised
        // button call may still have delivered the event. Stop as soon as
        // SpringBoard plus source departure are observed.
        for _ in 0..<20 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
            var sourceAfter = "unknown"
            if let sourceApp {
                _ = perform(stage: "home-source-after") {
                    sourceAfter = self.stateName(sourceApp.state)
                }
            }
            var springboardAfter = "unknown"
            _ = perform(stage: "home-springboard-after") {
                springboardAfter = self.stateName(springboard.state)
            }
            observation.sourceStateAfter = sourceAfter
            observation.springboardStateAfter = springboardAfter
            observation.hostStateAfter = hostApplicationState()
            assessment = BridgeHomeEvidence.assess(observation)
            if assessment.actualHomeObserved { break }
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1_000)

        var details: [String: String] = [
            "stateBefore": observation.hostStateBefore,
            "stateAfter": observation.hostStateAfter,
            "hostApplicationStateBefore": observation.hostStateBefore,
            "hostApplicationStateAfter": observation.hostStateAfter,
            "sourceBundleIdentifier": sourceBundle ?? "",
            "sourceKnown": "\(assessment.sourceKnown)",
            "sourceStateBefore": observation.sourceStateBefore,
            "sourceStateAfter": observation.sourceStateAfter,
            "sourceLeftForeground": "\(assessment.sourceLeftForeground)",
            "springboardStateBefore": observation.springboardStateBefore,
            "springboardStateAfter": observation.springboardStateAfter,
            "springboardForeground": "\(assessment.springboardForeground)",
            "hostBackgrounded": "\(assessment.hostBackgrounded)",
            "dispatched": pressCall.error != nil ? "entered-call-failed" : (pressCall.outcome.recordedIssueCount > 0 ? "returned-with-issue" : "returned-clean"),
            "callEntered": "true",
            "callReturned": "\(pressCall.outcome.returned)",
            "callOutcome": pressCall.outcome.classification,
            "recordedIssueCount": "\(pressCall.outcome.recordedIssueCount)",
            "actualHomeObserved": "\(assessment.actualHomeObserved)",
            "homeVerified": "\(assessment.actualHomeObserved)",
            "homeEvidence": assessment.homeEvidence,
            "lockscreenVerified": "false",
            "unlockRequired": "unknown",
            "destinationVerified": "\(assessment.destinationVerified)",
            "observedAfterMilliseconds": "\(elapsed)",
            "mutationEntered": "true",
        ]
        if sourceBundle == "com.apple.Preferences" {
            details["settingsBefore"] = observation.sourceStateBefore
            details["settingsAfter"] = observation.sourceStateAfter
        }
        if pressCall.error != nil {
            details["pressCallError"] = "true"
            details["outcomeUnknown"] = assessment.actualHomeObserved ? "false" : "true"
        } else if pressCall.outcome.recordedIssueCount > 0 {
            details["callRecordedIssue"] = "true"
            details["outcomeUnknown"] = assessment.actualHomeObserved ? "false" : "true"
        }

        if assessment.actualHomeObserved {
            return Outcome(status: "ok", details: details, error: nil)
        }
        if assessment.status == "error" {
            return Outcome(
                status: "error",
                details: details,
                error: "The Home press call did not return and no state change was observed; the effect is unknown. Do not assume it was cancelled."
            )
        }
        if pressCall.outcome.recordedIssueCount > 0 {
            return Outcome(
                status: "unverified",
                details: details,
                error: "The Home press call returned but recorded an XCTest issue; the home screen was not observed and the effect is unknown."
            )
        }
        let unverifiedMessage = pressCall.error == nil
            ? "Home was dispatched, but the home screen was not observed (\(assessment.homeEvidence)); only the recorded departure/background evidence is proven."
            : "The Home press call did not return; the observed evidence is \(assessment.homeEvidence), but the home screen was not observed. The effect is unknown."
        return Outcome(
            status: "unverified",
            details: details,
            error: unverifiedMessage
        )
    }

    // MARK: - Generic cross-app control

    /// Closed, typed arguments for the generic actions. Policy validation has
    /// already run in the file channel; this revalidates before any SDK call.
    private func controlParameters(_ command: BridgeCommandEnvelope) -> BridgeControlParameters? {
        guard let parameters = command.parameters,
              case .success(let normalized) = BridgeControlArguments.validate(
                  action: command.action,
                  parameters: parameters
              ) else {
            return nil
        }
        return normalized
    }

    private func targetForeground(_ app: XCUIApplication) -> (state: String, foreground: Bool) {
        var state = "unknown"
        _ = perform(stage: "target-state") { state = self.stateName(app.state) }
        return (state, state == "runningForeground")
    }

    private func noteControlledApp(_ bundleIdentifier: String) {
        guard !bundleIdentifier.isEmpty,
              bundleIdentifier != "com.apple.springboard" else { return }
        lastControlledBundleIdentifier = bundleIdentifier
    }

    private func notForegroundOutcome(bundleIdentifier: String,
                                      state: String,
                                      action: String) -> Outcome {
        Outcome(
            status: "not_foreground",
            details: [
                "bundleIdentifier": bundleIdentifier,
                "state": state,
                "foreground": "false",
                "unlockRequired": "unknown",
                "dispatched": "false",
                "requestedAction": action,
                "destinationVerified": "false",
            ],
            error: "The target app is not in the foreground. Unlock the device and open the app, then retry."
        )
    }

    /// Refuses a generic command at the final admission boundary without
    /// entering the next SDK mutation. `focusTapPerformed` distinguishes an
    /// earlier focus tap (already entered) from a completely untouched
    /// command; neither case claims the next mutation ran.
    private func mutationRefusal(_ decision: BridgeControlMutationDecision,
                                 action: String,
                                 bundleIdentifier: String,
                                 state: String,
                                 focusTapPerformed: Bool = false) -> Outcome {
        let status: String
        let message: String
        switch decision {
        case .staleGeneration:
            status = "stale"
            message = "The command generation is no longer current; no further mutation was dispatched."
        case .engineNotReady:
            status = "not_ready"
            message = "The engine is no longer ready; no further mutation was dispatched."
        case .targetNotForeground:
            status = "not_foreground"
            message = "The expected app is no longer in the foreground; no further mutation was dispatched."
        case .allowed:
            status = "error"
            message = "The final admission check was not a refusal."
        }
        var details: [String: String] = [
            "bundleIdentifier": bundleIdentifier,
            "state": state,
            "foreground": state == "runningForeground" ? "true" : "false",
            "requestedAction": action,
            "admissionDecision": decision.code,
            "mutationEntered": focusTapPerformed ? "true" : "false",
            "dispatched": "false",
            "destinationVerified": "false",
        ]
        if decision == .targetNotForeground {
            details["unlockRequired"] = "unknown"
        }
        if focusTapPerformed {
            details["focusTapPerformed"] = "true"
            details["textDispatched"] = "false"
        }
        return Outcome(status: status, details: details, error: message)
    }

    /// The single final gate before a generic SDK mutation. It rejects a stale
    /// generation or stopped engine without spending a potentially blocking
    /// foreground read, then observes the expected app's current state, and
    /// finally re-reads the shared lifecycle and invokes the mutation closure
    /// only if that same instant is still current. No lock is held while the
    /// mutation runs, so host Stop remains able to fence the command.
    private func preflightAndMutate(_ app: XCUIApplication,
                                    commandGeneration: UInt64,
                                    action: String,
                                    requiresForeground: Bool,
                                    state: inout String,
                                    mutation: () -> Void) -> BridgeControlMutationDecision {
        let before = BridgeSharedState.shared.mutationAdmissionState()
        let early = BridgeControlMutationAdmission.evaluate(
            expectedGeneration: commandGeneration,
            currentGeneration: before.generation,
            engineAcceptsCommands: before.acceptsEngineCommands,
            requiresForeground: false,
            expectedForeground: false
        )
        if !early.isAllowed { return early }

        var observedState = "unknown"
        var foreground = true
        if requiresForeground {
            _ = perform(stage: "\(action)-preflight-foreground") {
                observedState = self.stateName(app.state)
            }
            foreground = observedState == "runningForeground"
        }
        let after = BridgeSharedState.shared.mutationAdmissionState()
        state = observedState
        return BridgeControlMutationAdmission.admit(
            expectedGeneration: commandGeneration,
            currentGeneration: after.generation,
            engineAcceptsCommands: after.acceptsEngineCommands,
            requiresForeground: requiresForeground,
            expectedForeground: foreground,
            mutation: mutation
        )
    }

    /// True when the command authorization changed while an already-entered
    /// SDK call was running. The caller must report call-entered/unknown, not
    /// cancelled or definitely not performed.
    private func authorizationBecameStale(_ commandGeneration: UInt64) -> Bool {
        let current = BridgeSharedState.shared.mutationAdmissionState()
        return current.generation != commandGeneration ||
            !current.acceptsEngineCommands
    }

    private func activateGenericApp(_ parameters: BridgeControlParameters,
                                commandGeneration: UInt64) -> Outcome {
        guard let bundleIdentifier = parameters.bundleIdentifier else {
            return Outcome(status: "rejected", details: [:], error: "Missing bundle identifier.")
        }
        let app = XCUIApplication(bundleIdentifier: bundleIdentifier)
        var observedState = "unknown"
        let initial = targetForeground(app)
        observedState = initial.state
        if initial.foreground {
            // Activation is an intentional foreground transition, so it does
            // not require the target to be foreground beforehand. It still
            // must not start after the command's generation was fenced.
            let decision = preflightAndMutate(
                app,
                commandGeneration: commandGeneration,
                action: "activate",
                requiresForeground: false,
                state: &observedState
            ) {}
            guard decision.isAllowed else {
                return mutationRefusal(decision, action: BridgeControlAction.activateApp,
                                       bundleIdentifier: bundleIdentifier,
                                       state: observedState)
            }
            noteControlledApp(bundleIdentifier)
            return Outcome(
                status: "ok",
                details: [
                    "bundleIdentifier": bundleIdentifier,
                    "foreground": "true",
                    "state": observedState,
                    "activationVerified": "true",
                    "strategy": "already-foreground",
                    "launchFallbackUsed": "false",
                    "mutationEntered": "false",
                    "dispatched": "no-op-already-foreground",
                    "destinationVerified": "true",
                ],
                error: nil
            )
        }
        var activateCall: SDKCallResult?
        let decision = preflightAndMutate(
            app,
            commandGeneration: commandGeneration,
            action: "activate",
            requiresForeground: false,
            state: &observedState
        ) {
            activateCall = performSDKCall(stage: "activate") { app.activate() }
        }
        guard decision.isAllowed else {
            return mutationRefusal(decision, action: BridgeControlAction.activateApp,
                                   bundleIdentifier: bundleIdentifier,
                                   state: observedState)
        }
        guard let activateCall else {
            return Outcome(
                status: "error",
                details: ["bundleIdentifier": bundleIdentifier,
                          "activationVerified": "false",
                          "destinationVerified": "false"],
                error: "The activation admission allowed the mutation but no call result was produced; no effect is claimed."
            )
        }
        let callDetails: [String: String] = [
            "callEntered": "true",
            "callReturned": "\(activateCall.outcome.returned)",
            "callOutcome": activateCall.outcome.classification,
            "recordedIssueCount": "\(activateCall.outcome.recordedIssueCount)",
        ]
        if authorizationBecameStale(commandGeneration) {
            var details: [String: String] = [
                "bundleIdentifier": bundleIdentifier,
                "state": observedState,
                "foreground": "false",
                "activationVerified": "false",
                "strategy": "XCUIApplication.activate",
                "launchFallbackUsed": "false",
                "mutationEntered": "true",
                "activationCallEntered": "true",
                "authorizationStaleAfterEnter": "true",
                "outcomeUnknown": "true",
                "dispatched": "entered-lifecycle-changed",
                "destinationVerified": "false",
                "unlockRequired": "unknown",
            ]
            details.merge(callDetails) { _, new in new }
            return Outcome(
                status: "unverified",
                details: details,
                error: "The activation call was entered, but the engine lifecycle changed before it returned; the outcome is unknown."
            )
        }
        var foreground = false
        _ = perform(stage: "activate-wait") {
            foreground = app.wait(for: .runningForeground, timeout: 10)
        }
        var state = "unknown"
        _ = perform(stage: "activate-state") { state = self.stateName(app.state) }
        let verified = foreground && state == "runningForeground"
        let staleAfter = authorizationBecameStale(commandGeneration)
        if verified && !staleAfter {
            noteControlledApp(bundleIdentifier)
        }
        var details: [String: String] = [
            "bundleIdentifier": bundleIdentifier,
            "foreground": "\(verified)",
            "state": state,
            "activationVerified": "\(verified)",
            "strategy": "XCUIApplication.activate",
            "launchFallbackUsed": "false",
            "mutationEntered": "true",
            "activationCallEntered": "true",
            "destinationVerified": "\(verified && !staleAfter)",
        ]
        details.merge(callDetails) { _, new in new }
        if activateCall.error != nil {
            if verified && !staleAfter {
                details["dispatched"] = "verified-after-call-error"
                details["callRecordedIssue"] = activateCall.outcome.recordedIssueCount > 0 ? "true" : "false"
                return Outcome(status: "ok", details: details, error: nil)
            }
            details["dispatched"] = "entered-call-failed"
            details["outcomeUnknown"] = "true"
            return Outcome(
                status: "error",
                details: details,
                error: "The activation call was entered but threw; no foreground state proved the effect. The outcome is unknown."
            )
        }
        if staleAfter {
            details["authorizationStaleAfterEnter"] = "true"
            details["outcomeUnknown"] = "true"
            details["dispatched"] = "entered-lifecycle-changed"
            return Outcome(
                status: "unverified",
                details: details,
                error: "The activation call was entered, but the engine lifecycle changed before it returned; the outcome is unknown."
            )
        }
        if verified {
            details["dispatched"] = activateCall.outcome.recordedIssueCount > 0
                ? "verified-despite-recorded-issue"
                : "accepted"
            if activateCall.outcome.recordedIssueCount > 0 {
                details["callRecordedIssue"] = "true"
            }
            return Outcome(status: "ok", details: details, error: nil)
        }
        details["dispatched"] = "accepted-not-verified"
        if activateCall.outcome.recordedIssueCount > 0 {
            details["callRecordedIssue"] = "true"
            details["outcomeUnknown"] = "true"
            return Outcome(
                status: "unverified",
                details: details,
                error: "The activation call returned but recorded an XCTest issue; no foreground state proved the effect. The outcome is unknown."
            )
        }
        return Outcome(
            status: "unverified",
            details: details,
            error: "Activation did not reach an observed foreground state."
        )
    }

    /// Adapts the public snapshot protocol to the pure, bounded renderer in
    /// BridgeCore. Metadata and children are read lazily; a descendant wrapper
    /// is constructed only when the renderer's depth/node/byte budget asks for
    /// it. This avoids a second full-tree copy after the unavoidable public
    /// `XCUIElement.snapshot()` materialization. All metadata/child access
    /// happens inside the caller's `perform` Objective-C exception guard.
    @MainActor
    private final class EngineUISnapshotNode: BridgeUIElementNode {
        private let snapshot: XCUIElementSnapshot
        private lazy var children: [XCUIElementSnapshot] = snapshot.children
        private lazy var elementType: XCUIElement.ElementType = snapshot.elementType

        init(snapshot: XCUIElementSnapshot) {
            self.snapshot = snapshot
        }

        var uiElementTypeName: String { String(describing: elementType) }
        var uiElementTypeRawValue: Int { Int(elementType.rawValue) }
        var uiIdentifier: String { snapshot.identifier }
        var uiLabel: String { snapshot.label }
        var uiValue: String? {
            // A secure field's value is never read into this adapter; the
            // renderer emits <redacted> from the type alone.
            guard !uiIsSecureTextField else { return nil }
            return snapshot.value.map { String(describing: $0) }
        }
        var uiPlaceholderValue: String? { snapshot.placeholderValue }
        var uiFrameDescription: String {
            let rect = snapshot.frame
            return String(format: "%.0f,%.0f,%.0f,%.0f",
                          rect.origin.x, rect.origin.y,
                          rect.size.width, rect.size.height)
        }
        var uiIsEnabled: Bool { snapshot.isEnabled }
        var uiIsSelected: Bool { snapshot.isSelected }
        var uiHasFocus: Bool { snapshot.hasFocus }
        var uiIsSecureTextField: Bool { elementType == .secureTextField }
        var uiChildCount: Int { children.count }

        func uiChild(at index: Int) -> EngineUISnapshotNode? {
            guard children.indices.contains(index) else { return nil }
            return EngineUISnapshotNode(snapshot: children[index])
        }
    }

    private func inspectTargetUI(_ parameters: BridgeControlParameters) -> Outcome {
        guard let bundleIdentifier = parameters.bundleIdentifier else {
            return Outcome(status: "rejected", details: [:], error: "Missing bundle identifier.")
        }
        let app = XCUIApplication(bundleIdentifier: bundleIdentifier)
        let target = targetForeground(app)
        guard target.foreground else {
            return notForegroundOutcome(bundleIdentifier: bundleIdentifier,
                                        state: target.state,
                                        action: BridgeControlAction.inspectUI)
        }
        noteControlledApp(bundleIdentifier)
        var root: XCUIElementSnapshot?
        let snapshotCall = performSDKCall(stage: "snapshot") {
            root = try? app.snapshot()
        }
        if snapshotCall.error != nil || root == nil {
            return Outcome(
                status: "error",
                details: [
                    "bundleIdentifier": bundleIdentifier,
                    "state": target.state,
                    "snapshotSource": "XCUIElement.snapshot",
                    "observed": "false",
                    "callOutcome": snapshotCall.outcome.classification,
                    "recordedIssueCount": "\(snapshotCall.outcome.recordedIssueCount)",
                    "destinationVerified": "false",
                ],
                error: "The UI snapshot could not be read."
            )
        }
        if snapshotCall.outcome.recordedIssueCount > 0 {
            return Outcome(
                status: "unverified",
                details: [
                    "bundleIdentifier": bundleIdentifier,
                    "state": target.state,
                    "snapshotSource": "XCUIElement.snapshot",
                    "observed": "false",
                    "callOutcome": snapshotCall.outcome.classification,
                    "recordedIssueCount": "\(snapshotCall.outcome.recordedIssueCount)",
                    "snapshotRecordedIssue": "true",
                    "destinationVerified": "false",
                ],
                error: "The UI snapshot returned but recorded an XCTest issue; no tree is treated as complete. Re-read before acting."
            )
        }
        guard let root else {
            return Outcome(status: "error", details: ["bundleIdentifier": bundleIdentifier],
                           error: "The UI snapshot could not be read.")
        }
        let limits = BridgeUITreeLimits(
            maxDepth: parameters.maxDepth ?? BridgeControlArguments.defaultMaxDepth,
            maxNodes: parameters.maxNodes ?? BridgeControlArguments.defaultMaxNodes,
            maxStringBytes: parameters.maxStringBytes ?? BridgeControlArguments.defaultMaxStringBytes,
            maxTotalBytes: parameters.maxTotalBytes ?? BridgeControlArguments.defaultMaxTotalBytes
        )
        var rendered: BridgeUITreeRender?
        let renderError = perform(stage: "snapshot-render", sensitive: true) {
            rendered = BridgeUITreeRenderer.render(
                root: EngineUISnapshotNode(snapshot: root),
                limits: limits
            )
        }
        guard renderError == nil, let rendered else {
            return Outcome(
                status: "error",
                details: [
                    "bundleIdentifier": bundleIdentifier,
                    "state": target.state,
                    "snapshotSource": "XCUIElement.snapshot",
                    "observed": "false",
                    "destinationVerified": "false",
                ],
                error: "The UI tree could not be rendered; no partial tree was returned."
            )
        }
        let stats = rendered.statistics
        let details: [String: String] = [
            "bundleIdentifier": bundleIdentifier,
            "state": target.state,
            "foreground": "true",
            "snapshotSource": "XCUIElement.snapshot",
            "snapshotMaterialization": "public-full-tree-then-trimmed",
            "adapterTraversal": "lazy-budgeted-by-depth-nodes-bytes",
            "treeFormat": "floe-ui-tree-v1",
            "observed": "true",
            "observedAt": BridgeClock.timestamp(),
            "returnedNodeCount": "\(stats.returnedNodeCount)",
            "visitedNodeCount": "\(stats.visitedNodeCount)",
            "maxDepthReached": "\(stats.maxDepthReached)",
            "maxDepth": "\(limits.maxDepth)",
            "maxNodes": "\(limits.maxNodes)",
            "maxStringBytes": "\(limits.maxStringBytes)",
            "maxTotalBytes": "\(limits.maxTotalBytes)",
            "truncatedDepth": "\(stats.truncatedDepth)",
            "truncatedNodes": "\(stats.truncatedNodes)",
            "truncatedBytes": "\(stats.truncatedBytes)",
            "truncatedStrings": "\(stats.truncatedStrings)",
            "secureValueRedactions": "\(stats.secureValueRedactions)",
            "uiTree": rendered.json,
            "uiTreeBytes": "\(rendered.utf8Bytes)",
            "destinationVerified": "false",
        ]
        return Outcome(status: "ok", details: details, error: nil)
    }

    private func snapshotMatches(_ root: XCUIElementSnapshot,
                                 identifier: String) -> [XCUIElementSnapshot] {
        var matches: [XCUIElementSnapshot] = []
        var stack: [XCUIElementSnapshot] = [root]
        var visited = 0
        while let node = stack.popLast(), visited < 4_000 {
            visited += 1
            if node.identifier == identifier { matches.append(node) }
            stack.append(contentsOf: node.children)
        }
        return matches
    }

    private func snapshotHasSecureField(_ root: XCUIElementSnapshot,
                                        at point: CGPoint) -> Bool {
        var stack: [XCUIElementSnapshot] = [root]
        var visited = 0
        while let node = stack.popLast(), visited < 4_000 {
            visited += 1
            if node.elementType == .secureTextField, node.frame.contains(point) {
                return true
            }
            stack.append(contentsOf: node.children)
        }
        return false
    }

    private func snapshotHasSecureField(_ root: XCUIElementSnapshot,
                                        intersectingFrom start: CGPoint,
                                        to end: CGPoint) -> Bool {
        let bounds = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        ).insetBy(dx: -1, dy: -1)
        var stack: [XCUIElementSnapshot] = [root]
        var visited = 0
        while let node = stack.popLast(), visited < 4_000 {
            visited += 1
            if node.elementType == .secureTextField, node.frame.intersects(bounds) {
                return true
            }
            stack.append(contentsOf: node.children)
        }
        return false
    }

    private func isEditableType(_ type: XCUIElement.ElementType) -> Bool {
        switch type {
        case .textField, .searchField, .textView:
            return true
        default:
            return false
        }
    }

    private func point(in frame: CGRect,
                       normalizedX: Double,
                       normalizedY: Double) -> CGPoint {
        CGPoint(
            x: frame.minX + CGFloat(normalizedX) * frame.width,
            y: frame.minY + CGFloat(normalizedY) * frame.height
        )
    }

    private func tapTarget(_ parameters: BridgeControlParameters,
                                commandGeneration: UInt64) -> Outcome {
        guard let bundleIdentifier = parameters.bundleIdentifier else {
            return Outcome(status: "rejected", details: [:], error: "Missing bundle identifier.")
        }
        let app = XCUIApplication(bundleIdentifier: bundleIdentifier)
        let target = targetForeground(app)
        guard target.foreground else {
            return notForegroundOutcome(bundleIdentifier: bundleIdentifier,
                                        state: target.state,
                                        action: BridgeControlAction.tap)
        }
        noteControlledApp(bundleIdentifier)
        var root: XCUIElementSnapshot?
        let snapshotCall = performSDKCall(stage: "tap-snapshot") {
            root = try? app.snapshot()
        }
        guard snapshotCall.error == nil,
              snapshotCall.outcome.recordedIssueCount == 0,
              let root else {
            return Outcome(
                status: snapshotCall.error != nil ? "error" : "unverified",
                details: [
                    "bundleIdentifier": bundleIdentifier,
                    "state": target.state,
                    "foreground": "true",
                    "callOutcome": snapshotCall.outcome.classification,
                    "recordedIssueCount": "\(snapshotCall.outcome.recordedIssueCount)",
                    "snapshotRecordedIssue": snapshotCall.outcome.recordedIssueCount > 0 ? "true" : "false",
                    "tapPerformed": "false",
                    "destinationVerified": "false",
                ],
                error: snapshotCall.outcome.recordedIssueCount > 0
                    ? "The target UI snapshot recorded an XCTest issue; no tap was performed. Re-read before acting."
                    : "The target UI could not be read; no tap was performed."
            )
        }
        var appFrame = CGRect.zero
        _ = perform(stage: "tap-app-frame") { appFrame = app.frame }
        guard appFrame.width > 1, appFrame.height > 1 else {
            return Outcome(
                status: "error",
                details: ["bundleIdentifier": bundleIdentifier,
                          "tapPerformed": "false",
                          "destinationVerified": "false"],
                error: "The target app frame was not usable; no tap was performed."
            )
        }

        var normalizedX = 0.0
        var normalizedY = 0.0
        var strategy = "normalized-coordinate"
        var targetIdentifier = ""
        var targetType = "unknown"
        var targetFrame = ""
        var targetPoint = CGPoint.zero

        if let identifier = parameters.identifier {
            let matches = snapshotMatches(root, identifier: identifier)
            guard matches.count == 1, let node = matches.first else {
                return Outcome(
                    status: matches.isEmpty ? "target_missing" : "ambiguous_target",
                    details: [
                        "bundleIdentifier": bundleIdentifier,
                        "targetIdentifier": identifier,
                        "matchCount": "\(matches.count)",
                        "tapPerformed": "false",
                        "destinationVerified": "false",
                    ],
                    error: matches.isEmpty
                        ? "No element matched the accessibility identifier; no tap was performed."
                        : "More than one element matched the accessibility identifier; no tap was performed."
                )
            }
            targetIdentifier = identifier
            targetType = String(describing: node.elementType)
            targetFrame = rectString(screenRect(node.frame))
            if node.elementType == .secureTextField {
                return Outcome(
                    status: "secure_target_refused",
                    details: [
                        "bundleIdentifier": bundleIdentifier,
                        "targetIdentifier": identifier,
                        "targetType": targetType,
                        "tapPerformed": "false",
                        "destinationVerified": "false",
                    ],
                    error: "Secure text fields are not automated; no tap was performed."
                )
            }
            guard node.frame.width > 0, node.frame.height > 0 else {
                return Outcome(status: "target_not_reachable",
                               details: ["bundleIdentifier": bundleIdentifier,
                                         "targetIdentifier": identifier,
                                         "tapPerformed": "false",
                                         "destinationVerified": "false"],
                               error: "The matched element has no usable frame; no tap was performed.")
            }
            let center = CGPoint(x: node.frame.midX, y: node.frame.midY)
            guard appFrame.contains(center) else {
                return Outcome(status: "target_not_reachable",
                               details: ["bundleIdentifier": bundleIdentifier,
                                         "targetIdentifier": identifier,
                                         "tapPerformed": "false",
                                         "destinationVerified": "false"],
                               error: "The matched element is outside the app frame; no tap was performed.")
            }
            if snapshotHasSecureField(root, at: center) {
                return Outcome(status: "secure_target_refused",
                               details: ["bundleIdentifier": bundleIdentifier,
                                         "targetIdentifier": identifier,
                                         "tapPerformed": "false",
                                         "destinationVerified": "false"],
                               error: "The tap point overlaps a secure text field; no tap was performed.")
            }
            normalizedX = Double((center.x - appFrame.minX) / appFrame.width)
            normalizedY = Double((center.y - appFrame.minY) / appFrame.height)
            targetPoint = center
            strategy = "identifier"
        } else {
            guard let x = parameters.normalizedX, let y = parameters.normalizedY else {
                return Outcome(status: "rejected", details: [:], error: "Missing tap coordinates.")
            }
            normalizedX = x
            normalizedY = y
            targetPoint = point(in: appFrame, normalizedX: x, normalizedY: y)
            if snapshotHasSecureField(root, at: targetPoint) {
                return Outcome(status: "secure_target_refused",
                               details: ["bundleIdentifier": bundleIdentifier,
                                         "tapPerformed": "false",
                                         "destinationVerified": "false"],
                               error: "The tap point overlaps a secure text field; no tap was performed.")
            }
        }

        let coordinate = app.coordinate(withNormalizedOffset: CGVector(dx: normalizedX, dy: normalizedY))
        var observedState = target.state
        var tapCall: SDKCallResult?
        let decision = preflightAndMutate(
            app,
            commandGeneration: commandGeneration,
            action: "tap",
            requiresForeground: true,
            state: &observedState
        ) {
            tapCall = performSDKCall(stage: "tap") { coordinate.tap() }
        }
        guard decision.isAllowed else {
            return mutationRefusal(decision, action: BridgeControlAction.tap,
                                   bundleIdentifier: bundleIdentifier,
                                   state: observedState)
        }
        guard let tapCall else {
            return Outcome(
                status: "error",
                details: ["bundleIdentifier": bundleIdentifier,
                          "tapPerformed": "false",
                          "destinationVerified": "false"],
                error: "The tap admission allowed the mutation but no call result was produced; no effect is claimed."
            )
        }
        var details: [String: String] = [
            "bundleIdentifier": bundleIdentifier,
            "state": observedState,
            "foreground": "true",
            "strategy": strategy,
            "coordinateSpace": "app-normalized",
            "normalizedX": String(format: "%.6f", normalizedX),
            "normalizedY": String(format: "%.6f", normalizedY),
            "resolvedScreenX": String(format: "%.1f", targetPoint.x),
            "resolvedScreenY": String(format: "%.1f", targetPoint.y),
            "appFrame": rectString(screenRect(appFrame)),
            "mutationEntered": "true",
            "callEntered": "true",
            "callReturned": "\(tapCall.outcome.returned)",
            "callOutcome": tapCall.outcome.classification,
            "recordedIssueCount": "\(tapCall.outcome.recordedIssueCount)",
            "destinationVerified": "false",
        ]
        if !targetIdentifier.isEmpty {
            details["targetIdentifier"] = targetIdentifier
            details["targetType"] = targetType
            details["targetFrame"] = targetFrame
        }
        if tapCall.error != nil {
            details["tapPerformed"] = tapCall.outcome.mutationDispatchClaim()
            details["outcomeUnknown"] = "true"
            return Outcome(
                status: "error",
                details: details,
                error: "The tap call was entered but threw or could not be completed; whether an effect occurred is unknown. Do not retry blindly."
            )
        }
        if tapCall.outcome.recordedIssueCount > 0 {
            details["tapPerformed"] = tapCall.outcome.mutationDispatchClaim()
            details["callRecordedIssue"] = "true"
            details["outcomeUnknown"] = "true"
            return Outcome(
                status: "unverified",
                details: details,
                error: "The tap call returned but recorded an XCTest issue; whether the event was dispatched is unknown. Do not retry blindly."
            )
        }
        if authorizationBecameStale(commandGeneration) {
            details["tapPerformed"] = "true"
            details["authorizationStaleAfterEnter"] = "true"
            details["outcomeUnknown"] = "true"
            return Outcome(
                status: "unverified",
                details: details,
                error: "The tap call was entered, but the engine lifecycle changed before it returned; the effect is unknown."
            )
        }
        details["tapPerformed"] = tapCall.outcome.mutationDispatchClaim()
        return Outcome(status: "ok", details: details, error: nil)
    }

    private func swipeTarget(_ parameters: BridgeControlParameters,
                                commandGeneration: UInt64) -> Outcome {
        guard let bundleIdentifier = parameters.bundleIdentifier else {
            return Outcome(status: "rejected", details: [:], error: "Missing bundle identifier.")
        }
        let app = XCUIApplication(bundleIdentifier: bundleIdentifier)
        let target = targetForeground(app)
        guard target.foreground else {
            return notForegroundOutcome(bundleIdentifier: bundleIdentifier,
                                        state: target.state,
                                        action: BridgeControlAction.swipe)
        }
        noteControlledApp(bundleIdentifier)
        var root: XCUIElementSnapshot?
        let snapshotCall = performSDKCall(stage: "swipe-snapshot") {
            root = try? app.snapshot()
        }
        guard snapshotCall.error == nil,
              snapshotCall.outcome.recordedIssueCount == 0,
              let root else {
            return Outcome(
                status: snapshotCall.error != nil ? "error" : "unverified",
                details: ["bundleIdentifier": bundleIdentifier,
                          "callOutcome": snapshotCall.outcome.classification,
                          "recordedIssueCount": "\(snapshotCall.outcome.recordedIssueCount)",
                          "snapshotRecordedIssue": snapshotCall.outcome.recordedIssueCount > 0 ? "true" : "false",
                          "swipePerformed": "false",
                          "destinationVerified": "false"],
                error: snapshotCall.outcome.recordedIssueCount > 0
                    ? "The target UI snapshot recorded an XCTest issue; no swipe was performed. Re-read before acting."
                    : "The target UI could not be read; no swipe was performed."
            )
        }
        var appFrame = CGRect.zero
        _ = perform(stage: "swipe-app-frame") { appFrame = app.frame }
        guard appFrame.width > 1, appFrame.height > 1,
              let startX = parameters.startNormalizedX,
              let startY = parameters.startNormalizedY,
              let endX = parameters.endNormalizedX,
              let endY = parameters.endNormalizedY else {
            return Outcome(
                status: "rejected",
                details: ["bundleIdentifier": bundleIdentifier,
                          "swipePerformed": "false",
                          "destinationVerified": "false"],
                error: "Swipe coordinates or the target app frame were not usable; no swipe was performed."
            )
        }
        let duration = parameters.durationMilliseconds
            ?? BridgeControlArguments.defaultSwipeDurationMilliseconds
        let startPoint = point(in: appFrame, normalizedX: startX, normalizedY: startY)
        let endPoint = point(in: appFrame, normalizedX: endX, normalizedY: endY)
        if snapshotHasSecureField(root, intersectingFrom: startPoint, to: endPoint) {
            return Outcome(
                status: "secure_target_refused",
                details: ["bundleIdentifier": bundleIdentifier,
                          "swipePerformed": "false",
                          "destinationVerified": "false"],
                error: "The swipe path overlaps a secure text field; no swipe was performed."
            )
        }
        let distancePoints = hypot(Double(endPoint.x - startPoint.x),
                                   Double(endPoint.y - startPoint.y))
        let seconds = max(0.001, Double(duration) / 1_000.0)
        let velocity = min(5_000.0, max(50.0, distancePoints / seconds))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: startY))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: endX, dy: endY))
        var observedState = target.state
        var swipeCall: SDKCallResult?
        let decision = preflightAndMutate(
            app,
            commandGeneration: commandGeneration,
            action: "swipe",
            requiresForeground: true,
            state: &observedState
        ) {
            swipeCall = performSDKCall(stage: "swipe") {
                start.press(forDuration: 0.05,
                            thenDragTo: end,
                            withVelocity: XCUIGestureVelocity(rawValue: velocity),
                            thenHoldForDuration: 0.0)
            }
        }
        guard decision.isAllowed else {
            return mutationRefusal(decision, action: BridgeControlAction.swipe,
                                   bundleIdentifier: bundleIdentifier,
                                   state: observedState)
        }
        guard let swipeCall else {
            return Outcome(
                status: "error",
                details: ["bundleIdentifier": bundleIdentifier,
                          "swipePerformed": "false",
                          "destinationVerified": "false"],
                error: "The swipe admission allowed the mutation but no call result was produced; no effect is claimed."
            )
        }
        var details: [String: String] = [
            "bundleIdentifier": bundleIdentifier,
            "state": observedState,
            "foreground": "true",
            "coordinateSpace": "app-normalized",
            "startNormalizedX": String(format: "%.6f", startX),
            "startNormalizedY": String(format: "%.6f", startY),
            "endNormalizedX": String(format: "%.6f", endX),
            "endNormalizedY": String(format: "%.6f", endY),
            "startScreenX": String(format: "%.1f", startPoint.x),
            "startScreenY": String(format: "%.1f", startPoint.y),
            "endScreenX": String(format: "%.1f", endPoint.x),
            "endScreenY": String(format: "%.1f", endPoint.y),
            "requestedDurationMilliseconds": "\(duration)",
            "effectiveVelocityPointsPerSecond": String(format: "%.1f", velocity),
            "distancePoints": String(format: "%.1f", distancePoints),
            "appFrame": rectString(screenRect(appFrame)),
            "mutationEntered": "true",
            "callEntered": "true",
            "callReturned": "\(swipeCall.outcome.returned)",
            "callOutcome": swipeCall.outcome.classification,
            "recordedIssueCount": "\(swipeCall.outcome.recordedIssueCount)",
            "destinationVerified": "false",
        ]
        if swipeCall.error != nil {
            details["swipePerformed"] = swipeCall.outcome.mutationDispatchClaim()
            details["outcomeUnknown"] = "true"
            return Outcome(
                status: "error",
                details: details,
                error: "The swipe call was entered but threw or could not be completed; whether an effect occurred is unknown. Do not retry blindly."
            )
        }
        if swipeCall.outcome.recordedIssueCount > 0 {
            details["swipePerformed"] = swipeCall.outcome.mutationDispatchClaim()
            details["callRecordedIssue"] = "true"
            details["outcomeUnknown"] = "true"
            return Outcome(
                status: "unverified",
                details: details,
                error: "The swipe call returned but recorded an XCTest issue; whether the gesture was dispatched is unknown. Do not retry blindly."
            )
        }
        if authorizationBecameStale(commandGeneration) {
            details["swipePerformed"] = "true"
            details["authorizationStaleAfterEnter"] = "true"
            details["outcomeUnknown"] = "true"
            return Outcome(
                status: "unverified",
                details: details,
                error: "The swipe call was entered, but the engine lifecycle changed before it returned; the effect is unknown."
            )
        }
        details["swipePerformed"] = swipeCall.outcome.mutationDispatchClaim()
        return Outcome(status: "ok", details: details, error: nil)
    }

    private struct LiveTextField {
        var element: XCUIElement
        var field: BridgeUIEditableField
    }

    private struct KeyboardFocusProbe {
        var available = false
        var focusedCount = 0
        var editableCount = 0
        var secureFocused = false
        var matchedTarget = false
        var matchReason = "unavailable"
        var focusedElement: XCUIElement?
        var focusedField: BridgeUIEditableField?
    }

    private var textInputRawValues: [Int] {
        [
            XCUIElement.ElementType.textField,
            .secureTextField,
            .searchField,
            .textView,
        ].map { Int($0.rawValue) }
    }

    /// Every node that can be a text input, plus every identified node so an
    /// identifier that resolves to a non-editable element is refused as such
    /// instead of reported as missing.
    private func textInputFields(in root: XCUIElementSnapshot) -> [BridgeUIEditableField] {
        var output: [BridgeUIEditableField] = []
        var stack: [XCUIElementSnapshot] = [root]
        var visited = 0
        while let node = stack.popLast(), visited < 4_000 {
            visited += 1
            let secure = node.elementType == .secureTextField
            let editable = isEditableType(node.elementType)
            if editable || secure || !node.identifier.isEmpty {
                let rect = screenRect(node.frame)
                output.append(BridgeUIEditableField(
                    identifier: node.identifier,
                    label: node.label,
                    placeholder: node.placeholderValue ?? "",
                    elementType: String(describing: node.elementType),
                    elementTypeRawValue: Int(node.elementType.rawValue),
                    isSecure: secure,
                    isEditable: editable,
                    frame: BridgeUIRect(
                        x: rect.x, y: rect.y,
                        width: rect.width, height: rect.height
                    )
                ))
            }
            stack.append(contentsOf: node.children)
        }
        return output
    }

    private struct TextFieldBeforeValue {
        var value: String?
        var trusted: Bool
        var source: String
    }

    private func textFieldInitialValue(in root: XCUIElementSnapshot,
                                       matching field: BridgeUIEditableField) -> TextFieldBeforeValue {
        var stack: [XCUIElementSnapshot] = [root]
        var visited = 0
        while let node = stack.popLast(), visited < 4_000 {
            visited += 1
            let rect = screenRect(node.frame)
            let sameFrame = abs(rect.x - field.frame.x) <= 1 &&
                abs(rect.y - field.frame.y) <= 1 &&
                abs(rect.width - field.frame.width) <= 1 &&
                abs(rect.height - field.frame.height) <= 1
            let sameIdentity = !field.identifier.isEmpty
                ? node.identifier == field.identifier
                : sameFrame
            if sameIdentity,
               Int(node.elementType.rawValue) == field.elementTypeRawValue {
                guard node.elementType != .secureTextField,
                      let raw = node.value else {
                    return TextFieldBeforeValue(
                        value: nil, trusted: false, source: "unavailable"
                    )
                }
                let value = String(describing: raw)
                // A value equal to the placeholder establishes the standard
                // empty-field state. Any other string is the real before value.
                return TextFieldBeforeValue(
                    value: value == node.placeholderValue ? "" : value,
                    trusted: true,
                    source: value == node.placeholderValue ? "placeholder-empty" : "value"
                )
            }
            stack.append(contentsOf: node.children)
        }
        return TextFieldBeforeValue(value: nil, trusted: false, source: "unavailable")
    }

    private func liveTextField(_ element: XCUIElement) -> LiveTextField? {
        let type = element.elementType
        let secure = type == .secureTextField
        let editable = isEditableType(type)
        guard editable || secure else { return nil }
        let rect = screenRect(element.frame)
        return LiveTextField(
            element: element,
            field: BridgeUIEditableField(
                identifier: element.identifier,
                label: element.label,
                placeholder: element.placeholderValue ?? "",
                elementType: String(describing: type),
                elementTypeRawValue: Int(type.rawValue),
                isSecure: secure,
                isEditable: editable,
                frame: BridgeUIRect(
                    x: rect.x, y: rect.y,
                    width: rect.width, height: rect.height
                )
            )
        )
    }

    private func liveTextFields(_ app: XCUIApplication) -> (fields: [LiveTextField],
                                                            error: NSError?,
                                                            recordedIssues: Int) {
        var output: [LiveTextField] = []
        let queries: [XCUIElementQuery] = [
            app.textFields,
            app.searchFields,
            app.textViews,
            app.secureTextFields,
        ]
        let call = performSDKCall(stage: "type-live-enumerate") {
            for query in queries {
                let elements = query.allElementsBoundByIndex
                for element in elements.prefix(32) {
                    if let field = self.liveTextField(element) {
                        output.append(field)
                    }
                }
            }
        }
        return (output, call.error, call.outcome.recordedIssueCount)
    }

    private func sameTextField(_ live: BridgeUIEditableField,
                               _ expected: BridgeUIEditableField) -> Bool {
        if !expected.identifier.isEmpty {
            return live.identifier == expected.identifier
        }
        if !expected.label.isEmpty, live.label == expected.label { return true }
        if !expected.placeholder.isEmpty,
           live.placeholder == expected.placeholder { return true }
        guard live.elementTypeRawValue == expected.elementTypeRawValue else { return false }
        let minimumArea = min(live.frame.area, expected.frame.area)
        guard minimumArea > 0 else { return false }
        return live.frame.intersectionArea(with: expected.frame) >= minimumArea * 0.5
    }

    private func validateLiveTextField(_ live: LiveTextField,
                                       expected: BridgeUIEditableField,
                                       appFrame: CGRect) -> Result<LiveTextField, BridgeUITextTargetError> {
        guard !live.field.isSecure else {
            return .failure(BridgeUITextTargetError(
                code: "secure_input_refused",
                message: "The selected element is a secure text field; no text was typed.",
                matchCount: 1
            ))
        }
        guard live.field.isEditable else {
            return .failure(BridgeUITextTargetError(
                code: "target_not_editable",
                message: "The selected element is not an editable text field; no text was typed.",
                matchCount: 1
            ))
        }
        guard !live.field.frame.isEmpty,
              appFrame.contains(CGPoint(x: live.field.frame.midX,
                                        y: live.field.frame.midY)) else {
            return .failure(BridgeUITextTargetError(
                code: "target_not_reachable",
                message: "The selected field has no usable on-screen frame; no text was typed.",
                matchCount: 1
            ))
        }
        guard sameTextField(live.field, expected) else {
            return .failure(BridgeUITextTargetError(
                code: "target_changed",
                message: "The selected field changed before it could be focused; no text was typed.",
                matchCount: 1
            ))
        }
        return .success(live)
    }

    /// Resolves the snapshot-selected field to a live `XCUIElement`. Identifier
    /// is the precise path; label and placeholder are exact queries; a bounded
    /// live enumeration at the selected frame is the fallback. The SDK then
    /// enforces that the element (or a descendant) actually has keyboard focus
    /// when `typeText` is called.
    private func resolveLiveTextField(_ app: XCUIApplication,
                                      selection: BridgeUITextTargetSelection,
                                      appFrame: CGRect) -> Result<LiveTextField, BridgeUITextTargetError> {
        let expected = selection.field
        if !expected.identifier.isEmpty {
            let query = app.descendants(matching: .any)
                .matching(identifier: expected.identifier)
            var count = 0
            var live: LiveTextField?
            let call = performSDKCall(stage: "type-live-identifier") {
                count = query.count
                if count == 1 { live = self.liveTextField(query.element) }
            }
            if call.error == nil, call.outcome.recordedIssueCount == 0 {
                if count == 0 {
                    return .failure(BridgeUITextTargetError(
                        code: "target_changed",
                        message: "The selected field is no longer present; no text was typed.",
                        matchCount: 0
                    ))
                }
                if count > 1 {
                    return .failure(BridgeUITextTargetError(
                        code: "ambiguous_target",
                        message: "The selected identifier is no longer unique; no text was typed.",
                        matchCount: count
                    ))
                }
                if let live {
                    return validateLiveTextField(live, expected: expected, appFrame: appFrame)
                }
                return .failure(BridgeUITextTargetError(
                    code: "target_not_editable",
                    message: "The selected identifier no longer describes an editable field; no text was typed.",
                    matchCount: 1
                ))
            }
        }

        for attribute in ["label", "placeholderValue"] {
            let value = attribute == "label" ? expected.label : expected.placeholder
            let selectorName = attribute == "label" ? "label" : "placeholder"
            guard !value.isEmpty else { continue }
            let predicate = NSPredicate(
                format: "\(attribute) == %@ AND elementType IN %@",
                value,
                textInputRawValues
            )
            let query = app.descendants(matching: .any).matching(predicate)
            var count = 0
            var live: LiveTextField?
            let call = performSDKCall(stage: "type-live-\(attribute)") {
                count = query.count
                if count == 1 { live = self.liveTextField(query.element) }
            }
            if call.error == nil, call.outcome.recordedIssueCount == 0 {
                if count > 1 {
                    return .failure(BridgeUITextTargetError(
                        code: "ambiguous_target",
                        message: "More than one editable field matched the selected \(selectorName); no text was typed.",
                        matchCount: count
                    ))
                }
                if count == 1, let live {
                    return validateLiveTextField(live, expected: expected, appFrame: appFrame)
                }
            }
        }

        // Attribute queries can be unavailable for custom controls. Fall back
        // to a bounded live enumeration and the same point-selection rules,
        // anchored at the snapshot field's center (the keyboard is not up yet).
        let (fields, enumerateError, enumerateIssues) = liveTextFields(app)
        guard enumerateError == nil, enumerateIssues == 0 else {
            return .failure(BridgeUITextTargetError(
                code: "target_query_failed",
                message: "The live editable fields could not be read without a recorded issue; no text was typed."
            ))
        }
        let normalizedX = (expected.frame.midX - appFrame.minX) / appFrame.width
        let normalizedY = (expected.frame.midY - appFrame.minY) / appFrame.height
        let appUIFrame = BridgeUIRect(
            x: appFrame.minX, y: appFrame.minY,
            width: appFrame.width, height: appFrame.height
        )
        switch BridgeUITextTargetSelector.select(
            target: .point(normalizedX: normalizedX, normalizedY: normalizedY),
            fields: fields.map(\.field),
            appFrame: appUIFrame
        ) {
        case .failure(let error):
            return .failure(error)
        case .success(let liveSelection):
            guard let live = fields.first(where: { $0.field == liveSelection.field }) else {
                return .failure(BridgeUITextTargetError(
                    code: "target_changed",
                    message: "The live field could not be matched to the selected target; no text was typed."
                ))
            }
            return validateLiveTextField(live, expected: expected, appFrame: appFrame)
        }
    }

    private func keyboardFocusProbe(_ app: XCUIApplication,
                                    target: BridgeUIEditableField?) -> KeyboardFocusProbe {
        var probe = KeyboardFocusProbe()
        let predicate = NSPredicate(
            format: "hasKeyboardFocus == true AND elementType IN %@",
            textInputRawValues
        )
        let query = app.descendants(matching: .any).matching(predicate)
        var count = 0
        var liveFields: [LiveTextField] = []
        let call = performSDKCall(stage: "type-focus-query") {
            count = query.count
            if count > 0 {
                for element in query.allElementsBoundByIndex.prefix(16) {
                    if let field = self.liveTextField(element) {
                        liveFields.append(field)
                    }
                }
            }
        }
        guard call.error == nil, call.outcome.recordedIssueCount == 0 else { return probe }
        probe.available = true
        probe.focusedCount = count
        var matched = false
        var reason = "none"
        for item in liveFields {
            if item.field.isSecure {
                probe.secureFocused = true
                continue
            }
            guard item.field.isEditable else { continue }
            probe.editableCount += 1
            if probe.focusedElement == nil {
                probe.focusedElement = item.element
                probe.focusedField = item.field
            }
            if let target, focusMatches(item.field, target: target) {
                matched = true
                reason = "query-match"
            }
        }
        if !matched, let target, count == 1, probe.editableCount == 1,
           let only = probe.focusedField,
           only.elementTypeRawValue == target.elementTypeRawValue {
            // Point-selected fields without a stable identifier/label can move
            // when the keyboard animates. A single focused editable element of
            // the same type is accepted as probe evidence; the SDK typeText
            // focus assertion remains the actual dispatch gate.
            matched = true
            reason = "single-editable-type"
        }
        probe.matchedTarget = matched
        probe.matchReason = reason
        return probe
    }

    private func focusMatches(_ live: BridgeUIEditableField,
                              target: BridgeUIEditableField) -> Bool {
        if !target.identifier.isEmpty {
            return live.identifier == target.identifier
        }
        if !target.label.isEmpty, live.label == target.label { return true }
        if !target.placeholder.isEmpty,
           live.placeholder == target.placeholder { return true }
        guard live.elementTypeRawValue == target.elementTypeRawValue else { return false }
        let minimumArea = min(live.frame.area, target.frame.area)
        guard minimumArea > 0 else { return false }
        return live.frame.intersectionArea(with: target.frame) >= minimumArea * 0.25
    }

    private func textTargetRefusal(_ error: BridgeUITextTargetError,
                                   bundleIdentifier: String,
                                   strategy: String,
                                   focusTapPerformed: Bool) -> Outcome {
        var details: [String: String] = [
            "bundleIdentifier": bundleIdentifier,
            "targetStrategy": strategy,
            "focusTapPerformed": "\(focusTapPerformed)",
            "textDispatched": "false",
            "destinationVerified": "false",
        ]
        if let matchCount = error.matchCount {
            details["matchCount"] = "\(matchCount)"
        }
        return Outcome(status: error.code, details: details, error: error.message)
    }

    private func textFieldTargetRequired(bundleIdentifier: String,
                                         focusedCount: Int,
                                         focusedEditableCount: Int,
                                         focusProbeAvailable: Bool,
                                         focusTapPerformed: Bool,
                                         reason: String) -> Outcome {
        Outcome(
            status: "unverified",
            details: [
                "bundleIdentifier": bundleIdentifier,
                "focusedCount": "\(focusedCount)",
                "focusedEditableCount": "\(focusedEditableCount)",
                "focusProbeAvailable": "\(focusProbeAvailable)",
                "focusVerified": "false",
                "focusTapPerformed": "\(focusTapPerformed)",
                "textDispatched": "false",
                "destinationVerified": "false",
            ],
            error: reason
        )
    }

    private func secureTextRefusal(bundleIdentifier: String,
                                   targetStrategy: String,
                                   focusTapPerformed: Bool) -> Outcome {
        Outcome(
            status: "secure_input_refused",
            details: [
                "bundleIdentifier": bundleIdentifier,
                "targetStrategy": targetStrategy,
                "focusTapPerformed": "\(focusTapPerformed)",
                "mutationEntered": focusTapPerformed ? "true" : "false",
                "secureField": "true",
                "textDispatched": "false",
                "destinationVerified": "false",
            ],
            error: "A secure text field is focused or overlaps the target; no text was typed."
        )
    }

    private func typeTextIntoTarget(_ parameters: BridgeControlParameters,
                                    commandGeneration: UInt64) -> Outcome {
        guard let bundleIdentifier = parameters.bundleIdentifier,
              let text = parameters.text else {
            return Outcome(status: "rejected", details: [:], error: "Missing text input parameters.")
        }
        let app = XCUIApplication(bundleIdentifier: bundleIdentifier)
        let target = targetForeground(app)
        guard target.foreground else {
            return notForegroundOutcome(bundleIdentifier: bundleIdentifier,
                                        state: target.state,
                                        action: BridgeControlAction.typeText)
        }
        noteControlledApp(bundleIdentifier)
        var root: XCUIElementSnapshot?
        let snapshotCall = performSDKCall(stage: "type-snapshot") {
            root = try? app.snapshot()
        }
        guard snapshotCall.error == nil,
              snapshotCall.outcome.recordedIssueCount == 0,
              let root else {
            return Outcome(
                status: snapshotCall.error != nil ? "error" : "unverified",
                details: ["bundleIdentifier": bundleIdentifier,
                          "callOutcome": snapshotCall.outcome.classification,
                          "recordedIssueCount": "\(snapshotCall.outcome.recordedIssueCount)",
                          "snapshotRecordedIssue": snapshotCall.outcome.recordedIssueCount > 0 ? "true" : "false",
                          "textDispatched": "false",
                          "destinationVerified": "false"],
                error: snapshotCall.outcome.recordedIssueCount > 0
                    ? "The target UI snapshot recorded an XCTest issue; no text was typed. Re-read before acting."
                    : "The target UI could not be read; no text was typed."
            )
        }
        var appFrame = CGRect.zero
        _ = perform(stage: "type-app-frame") { appFrame = app.frame }
        guard appFrame.width > 1, appFrame.height > 1 else {
            return Outcome(
                status: "error",
                details: ["bundleIdentifier": bundleIdentifier,
                          "textDispatched": "false",
                          "destinationVerified": "false"],
                error: "The target app frame was not usable; no text was typed."
            )
        }
        let appUIFrame = BridgeUIRect(
            x: appFrame.minX, y: appFrame.minY,
            width: appFrame.width, height: appFrame.height
        )

        var resolved: LiveTextField?
        var targetStrategy = "focused-field"
        var targetIdentifier = ""
        var initialValue: String?
        var initialValueTrusted = false
        var initialValueSource = "unavailable"
        var observedState = target.state
        var focusTapPerformed = false
        var focusTapClaim = "false"
        var focusProbe = KeyboardFocusProbe()
        var focusProbeMismatch = false

        if let selector = parameters.textTarget {
            let fields = textInputFields(in: root)
            let selection: BridgeUITextTargetSelection
            switch BridgeUITextTargetSelector.select(
                target: selector,
                fields: fields,
                appFrame: appUIFrame
            ) {
            case .success(let value):
                selection = value
            case .failure(let error):
                return textTargetRefusal(error,
                                         bundleIdentifier: bundleIdentifier,
                                         strategy: selector.strategy,
                                         focusTapPerformed: false)
            }
            targetStrategy = selection.strategy
            targetIdentifier = selection.field.identifier
            let beforeValue = textFieldInitialValue(in: root, matching: selection.field)
            initialValue = beforeValue.value
            initialValueTrusted = beforeValue.trusted
            initialValueSource = beforeValue.source
            switch resolveLiveTextField(app, selection: selection, appFrame: appFrame) {
            case .success(let live):
                resolved = live
            case .failure(let error):
                return textTargetRefusal(error,
                                         bundleIdentifier: bundleIdentifier,
                                         strategy: selection.strategy,
                                         focusTapPerformed: false)
            }
        } else {
            let probe = keyboardFocusProbe(app, target: nil)
            focusProbe = probe
            if probe.secureFocused {
                return secureTextRefusal(bundleIdentifier: bundleIdentifier,
                                         targetStrategy: targetStrategy,
                                         focusTapPerformed: false)
            }
            guard probe.available else {
                return textFieldTargetRequired(
                    bundleIdentifier: bundleIdentifier,
                    focusedCount: probe.focusedCount,
                    focusedEditableCount: probe.editableCount,
                    focusProbeAvailable: false,
                    focusTapPerformed: false,
                    reason: "The XCTest hasKeyboardFocus query was unavailable; no text was typed. Pass --identifier, --label, --placeholder or --x/--y to target a field explicitly."
                )
            }
            guard probe.focusedCount == 1,
                  let element = probe.focusedElement,
                  let field = probe.focusedField else {
                return textFieldTargetRequired(
                    bundleIdentifier: bundleIdentifier,
                    focusedCount: probe.focusedCount,
                    focusedEditableCount: probe.editableCount,
                    focusProbeAvailable: true,
                    focusTapPerformed: false,
                    reason: "Exactly one focused editable field could not be verified; no text was typed. Pass --identifier, --label, --placeholder or --x/--y to target a field explicitly."
                )
            }
            guard !field.isSecure, field.isEditable else {
                return secureTextRefusal(bundleIdentifier: bundleIdentifier,
                                         targetStrategy: targetStrategy,
                                         focusTapPerformed: false)
            }
            resolved = LiveTextField(element: element, field: field)
            targetIdentifier = field.identifier
            var raw: Any?
            let readCall = performSDKCall(stage: "type-initial-value") {
                raw = element.value
            }
            if readCall.error == nil,
               readCall.outcome.recordedIssueCount == 0,
               let value = raw as? String {
                initialValue = value == field.placeholder ? "" : value
                initialValueTrusted = true
                initialValueSource = value == field.placeholder ? "placeholder-empty" : "value"
            }
        }

        guard let resolved else {
            return Outcome(
                status: "error",
                details: ["bundleIdentifier": bundleIdentifier,
                          "textDispatched": "false",
                          "destinationVerified": "false"],
                error: "No live editable field could be resolved; no text was typed."
            )
        }

        if parameters.textTarget != nil {
            let center = CGPoint(x: resolved.field.frame.midX,
                                 y: resolved.field.frame.midY)
            guard appFrame.contains(center) else {
                return textTargetRefusal(
                    BridgeUITextTargetError(
                        code: "target_not_reachable",
                        message: "The selected field is outside the app frame; no text was typed.",
                        matchCount: 1
                    ),
                    bundleIdentifier: bundleIdentifier,
                    strategy: targetStrategy,
                    focusTapPerformed: false
                )
            }
            let coordinate = app.coordinate(withNormalizedOffset: CGVector(
                dx: (center.x - appFrame.minX) / appFrame.width,
                dy: (center.y - appFrame.minY) / appFrame.height
            ))
            var focusCall: SDKCallResult?
            let focusDecision = preflightAndMutate(
                app,
                commandGeneration: commandGeneration,
                action: "type-focus",
                requiresForeground: true,
                state: &observedState
            ) {
                focusCall = performSDKCall(stage: "type-focus") {
                    coordinate.tap()
                }
            }
            guard focusDecision.isAllowed else {
                return mutationRefusal(focusDecision,
                                       action: BridgeControlAction.typeText,
                                       bundleIdentifier: bundleIdentifier,
                                       state: observedState)
            }
            guard let focusCall else {
                return Outcome(
                    status: "error",
                    details: ["bundleIdentifier": bundleIdentifier,
                              "targetStrategy": targetStrategy,
                              "focusTapPerformed": "false",
                              "textDispatched": "false",
                              "destinationVerified": "false"],
                    error: "The focus admission allowed the tap but no call result was produced; no text was dispatched."
                )
            }
            focusTapClaim = focusCall.outcome.mutationDispatchClaim()
            focusTapPerformed = focusTapClaim == "true"
            let focusCallDetails: [String: String] = [
                "focusTapCallEntered": "true",
                "focusTapCallReturned": "\(focusCall.outcome.returned)",
                "focusTapCallOutcome": focusCall.outcome.classification,
                "focusTapRecordedIssueCount": "\(focusCall.outcome.recordedIssueCount)",
            ]
            if authorizationBecameStale(commandGeneration) {
                var staleDetails: [String: String] = [
                    "bundleIdentifier": bundleIdentifier,
                    "state": observedState,
                    "targetStrategy": targetStrategy,
                    "targetIdentifier": targetIdentifier,
                    "focusTapPerformed": focusTapClaim,
                    "textDispatched": "false",
                    "mutationEntered": "true",
                    "authorizationStaleAfterEnter": "true",
                    "outcomeUnknown": "true",
                    "destinationVerified": "false",
                ]
                staleDetails.merge(focusCallDetails) { _, new in new }
                return Outcome(
                    status: "unverified",
                    details: staleDetails,
                    error: "The focus tap was entered, but the engine lifecycle changed before typing; no text was dispatched and the focus effect is unknown."
                )
            }
            if focusCall.error != nil {
                var failedDetails: [String: String] = [
                    "bundleIdentifier": bundleIdentifier,
                    "state": observedState,
                    "targetStrategy": targetStrategy,
                    "targetIdentifier": targetIdentifier,
                    "focusTapPerformed": focusTapClaim,
                    "textDispatched": "false",
                    "mutationEntered": "true",
                    "outcomeUnknown": "true",
                    "destinationVerified": "false",
                ]
                failedDetails.merge(focusCallDetails) { _, new in new }
                return Outcome(
                    status: "error",
                    details: failedDetails,
                    error: "The focus tap was entered but threw; no text was dispatched and the focus effect is unknown."
                )
            }
            if focusCall.outcome.recordedIssueCount > 0 {
                var issueDetails: [String: String] = [
                    "bundleIdentifier": bundleIdentifier,
                    "state": observedState,
                    "targetStrategy": targetStrategy,
                    "targetIdentifier": targetIdentifier,
                    "focusTapPerformed": focusTapClaim,
                    "textDispatched": "false",
                    "mutationEntered": "true",
                    "callRecordedIssue": "true",
                    "outcomeUnknown": "true",
                    "destinationVerified": "false",
                ]
                issueDetails.merge(focusCallDetails) { _, new in new }
                return Outcome(
                    status: "unverified",
                    details: issueDetails,
                    error: "The focus tap returned but recorded an XCTest issue; no text was dispatched and the focus effect is unknown."
                )
            }

            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
            var probe = keyboardFocusProbe(app, target: resolved.field)
            if probe.available, probe.focusedCount == 0, !probe.secureFocused {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
                probe = keyboardFocusProbe(app, target: resolved.field)
            }
            focusProbe = probe
            if probe.secureFocused {
                return secureTextRefusal(bundleIdentifier: bundleIdentifier,
                                         targetStrategy: targetStrategy,
                                         focusTapPerformed: true)
            }
            if probe.available, probe.focusedCount > 0, !probe.matchedTarget {
                focusProbeMismatch = true
            }
        }

        let (stateNow, foregroundNow) = targetForeground(app)
        observedState = stateNow
        guard foregroundNow else {
            return Outcome(
                status: "not_foreground",
                details: ["bundleIdentifier": bundleIdentifier,
                          "state": stateNow,
                          "foreground": "false",
                          "targetStrategy": targetStrategy,
                          "targetIdentifier": targetIdentifier,
                          "focusTapPerformed": "\(focusTapPerformed)",
                          "textDispatched": "false",
                          "unlockRequired": "unknown",
                          "destinationVerified": "false"],
                error: "The target app left the foreground before text could be typed; no text was dispatched."
            )
        }

        var typeCall: SDKCallResult?
        let typeDecision = preflightAndMutate(
            app,
            commandGeneration: commandGeneration,
            action: "type-text",
            requiresForeground: true,
            state: &observedState
        ) {
            typeCall = performSDKCall(stage: "type-text", detectFocusRefusal: true) {
                resolved.element.typeText(text)
            }
        }
        guard typeDecision.isAllowed else {
            return mutationRefusal(typeDecision,
                                   action: BridgeControlAction.typeText,
                                   bundleIdentifier: bundleIdentifier,
                                   state: observedState,
                                   focusTapPerformed: focusTapPerformed)
        }
        guard let typeCall else {
            return Outcome(
                status: "error",
                details: ["bundleIdentifier": bundleIdentifier,
                          "targetStrategy": targetStrategy,
                          "textDispatched": "false",
                          "destinationVerified": "false"],
                error: "The text admission allowed the call but no call result was produced; no text is claimed."
            )
        }

        var details: [String: String] = [
            "bundleIdentifier": bundleIdentifier,
            "state": observedState,
            "foreground": "true",
            "targetStrategy": targetStrategy,
            "targetIdentifier": targetIdentifier,
            "focusTapPerformed": focusTapClaim,
            "focusProbeAvailable": "\(focusProbe.available)",
            "focusProbeMatched": "\(focusProbe.matchedTarget)",
            "focusProbeMismatch": "\(focusProbeMismatch)",
            "focusedCount": "\(focusProbe.focusedCount)",
            "focusedEditableCount": "\(focusProbe.editableCount)",
            "secureField": "false",
            "characters": "\(text.count)",
            "utf8Bytes": "\(text.utf8.count)",
            "mutationEntered": "true",
            "callEntered": "true",
            "callReturned": "\(typeCall.outcome.returned)",
            "callOutcome": typeCall.outcome.classification,
            "recordedIssueCount": "\(typeCall.outcome.recordedIssueCount)",
            "destinationVerified": "false",
        ]
        if typeCall.error != nil {
            details["focusVerified"] = "false"
            if typeCall.outcome.focusRefused {
                details["sdkFocusRefusal"] = "true"
                details["textDispatched"] = typeCall.outcome.textDispatchClaim(actualValueVerified: false)
                return Outcome(
                    status: "unverified",
                    details: details,
                    error: "The SDK refused text input because the selected field did not have keyboard focus; no text was dispatched. Re-read the screen and target a visible editable field."
                )
            }
            details["textDispatched"] = "unknown"
            details["outcomeUnknown"] = "true"
            return Outcome(
                status: "error",
                details: details,
                error: "The text input call was entered but threw; whether any text was entered is unknown. Do not retry blindly."
            )
        }
        if typeCall.outcome.recordedIssueCount > 0 {
            details["callRecordedIssue"] = "true"
        }
        if authorizationBecameStale(commandGeneration) {
            details["textDispatched"] = typeCall.outcome.textDispatchClaim(actualValueVerified: false)
            details["focusVerified"] = "\(typeCall.outcome.focusClaim(probeMatched: focusProbe.matchedTarget, actualValueVerified: false))"
            details["focusEvidence"] = typeCall.outcome.recordedIssueCount > 0
                ? "recorded-issue"
                : (focusProbe.matchedTarget ? "keyboard-focus-probe+clean-return" : "returned-clean-unverified")
            details["authorizationStaleAfterEnter"] = "true"
            details["outcomeUnknown"] = "true"
            return Outcome(
                status: "unverified",
                details: details,
                error: "The text input call returned, but the engine lifecycle changed before its value could be checked; whether the text landed is unknown."
            )
        }

        var rawValue: Any?
        let valueCall = performSDKCall(stage: "type-value") {
            rawValue = resolved.element.value
        }
        let afterValue: String? = (valueCall.error == nil &&
                                   valueCall.outcome.recordedIssueCount == 0)
            ? rawValue as? String
            : nil
        let valueAssessment = BridgeTextValueAssessor.assess(
            beforeValue: initialValue,
            beforeTrusted: initialValueTrusted,
            request: text,
            afterValue: afterValue
        )
        let actualValueVerified = valueAssessment.appendVerified
        details["actualValueVerified"] = "\(actualValueVerified)"
        details["valueObservation"] = valueAssessment.observation
        details["valueAppendVerified"] = "\(valueAssessment.appendVerified)"
        details["valueMatchesRequest"] = "\(valueAssessment.valueMatchesRequest)"
        details["beforeValueTrusted"] = "\(valueAssessment.beforeTrusted)"
        details["beforeValueSource"] = initialValueSource
        details["valueReadOutcome"] = valueCall.outcome.classification
        details["valueReadRecordedIssueCount"] = "\(valueCall.outcome.recordedIssueCount)"
        if let bytes = valueAssessment.valueUTF8Bytes {
            details["valueUTF8Bytes"] = "\(bytes)"
        }
        if let bytes = valueAssessment.expectedUTF8Bytes {
            details["expectedUTF8Bytes"] = "\(bytes)"
        }
        details["textDispatched"] = typeCall.outcome.textDispatchClaim(
            actualValueVerified: actualValueVerified
        )
        details["focusVerified"] = "\(typeCall.outcome.focusClaim(probeMatched: focusProbe.matchedTarget, actualValueVerified: actualValueVerified))"
        if actualValueVerified {
            details["focusEvidence"] = "actual-value"
        } else if valueAssessment.valueMatchesRequest {
            details["focusEvidence"] = "weaker-value-match"
        } else if typeCall.outcome.cleanReturn && focusProbe.matchedTarget {
            details["focusEvidence"] = "keyboard-focus-probe+clean-return"
        } else if typeCall.outcome.recordedIssueCount > 0 {
            details["focusEvidence"] = "recorded-issue"
        } else if typeCall.outcome.cleanReturn {
            details["focusEvidence"] = "returned-clean-unverified"
        } else if typeCall.outcome.thrown {
            details["focusEvidence"] = "threw"
        } else {
            details["focusEvidence"] = "unknown"
        }
        details["destinationVerified"] = "\(actualValueVerified)"

        if actualValueVerified {
            return Outcome(status: "ok", details: details, error: nil)
        }
        details["outcomeUnknown"] = "true"
        if typeCall.outcome.recordedIssueCount > 0 {
            return Outcome(
                status: "unverified",
                details: details,
                error: "The text input call returned but recorded an XCTest issue, and the append effect was not established; the dispatch is unknown. Do not retry blindly."
            )
        }
        return Outcome(
            status: "unverified",
            details: details,
            error: "The text input call returned without a recorded issue, but the append effect was not established (observation=\(valueAssessment.observation)); whether any text was entered is unknown. Do not retry blindly."
        )
    }

    private struct SDKCallResult {
        var outcome: BridgeSDKCallOutcome
        var error: NSError?
    }

    /// Wraps one SDK call with a scoped XCTest-issue count and Objective-C
    /// exception catcher. The closure is the only entry into the SDK call.
    /// A normal return plus zero issues is `returned-clean`; a normal return
    /// with one or more recorded issues is `returned-with-issue` and must not
    /// be treated as a successful dispatch/focus claim. The issue object and
    /// its descriptions are never retained or logged.
    private func performSDKCall(stage: String,
                                sensitive: Bool = true,
                                detectFocusRefusal: Bool = false,
                                _ body: @escaping () -> Void) -> SDKCallResult {
        let token = issueCapture.begin()
        var error: NSError?
        let returned = BRCatchException(body, &error)
        let issues = issueCapture.end(token)
        if returned {
            return SDKCallResult(
                outcome: BridgeSDKCallOutcome(
                    entered: true,
                    returned: true,
                    recordedIssueCount: issues
                ),
                error: nil
            )
        }
        let resolved = error ?? NSError(
            domain: "org.floeagent.iosbridge.engine",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "unknown Objective-C exception"]
        )
        files.log(BridgeEngineSafeDiagnostic.exceptionLine(stage: stage,
                                                           error: resolved,
                                                           sensitive: sensitive))
        let reason = (resolved.userInfo[NSLocalizedDescriptionKey] as? String) ?? ""
        let focusRefused = detectFocusRefusal &&
            (reason.contains("Neither element nor any descendant has keyboard focus") ||
             reason.contains("XCUITestingErrorElementNotFocused"))
        let safeError = NSError(
            domain: "org.floeagent.iosbridge.engine",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "The automation call failed."]
        )
        return SDKCallResult(
            outcome: BridgeSDKCallOutcome(
                entered: true,
                returned: false,
                focusRefused: focusRefused,
                recordedIssueCount: issues
            ),
            error: safeError
        )
    }

    private func perform(stage: String,
                         sensitive: Bool = false,
                         _ body: @escaping () -> Void) -> NSError? {
        var error: NSError?
        let completed = BRCatchException(body, &error)
        if !completed {
            let resolved = error ?? NSError(domain: "org.floeagent.iosbridge.engine",
                                            code: -1,
                                            userInfo: [NSLocalizedDescriptionKey: "unknown Objective-C exception"])
            // Never let an SDK exception message echo user input text into a
            // log or a command result. Only the numeric code is read.
            files.log(BridgeEngineSafeDiagnostic.exceptionLine(stage: stage,
                                                               error: resolved,
                                                               sensitive: sensitive))
            return NSError(domain: "org.floeagent.iosbridge.engine",
                           code: -1,
                           userInfo: [NSLocalizedDescriptionKey: "The automation call failed."])
        }
        return nil
    }

    private func applicationStateName(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    private func stateName(_ state: XCUIApplication.State) -> String {
        switch state {
        case .unknown: return "unknown"
        case .notRunning: return "notRunning"
        case .runningBackgroundSuspended: return "runningBackgroundSuspended"
        case .runningBackground: return "runningBackground"
        case .runningForeground: return "runningForeground"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }
}
