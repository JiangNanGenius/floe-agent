// FloeAppTests — regressions for the two production 1.2.0 crashes and
// redacted feedback request construction.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import AVFoundation
import BackgroundTasks
import Testing
import FloeAgentRuntime
import FloePersistence
@testable import FloeApp

private actor ContinuedProcessingExpirationTestGate {
    private var persistenceStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspendPersistence() async {
        persistenceStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilPersistenceStarts() async {
        guard !persistenceStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releasePersistence() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

@Suite("FloeApp crash and feedback regressions")
struct CrashAndFeedbackRegressionTests {
    @Test("Window scene phases aggregate by stable per-scene identity")
    func windowScenePhaseIdentityContract() {
        var aggregation = AppScenePhaseAggregation()
        #expect(aggregation.effectivePhase == .background)
        #expect(aggregation.report(.active, sceneID: "scene-a") == .active)

        // A second, background window must not suspend app-wide SSH/VNC while
        // the first window remains active.
        #expect(aggregation.report(.background, sceneID: "scene-b") == nil)
        #expect(aggregation.effectivePhase == .active)

        #expect(aggregation.report(.inactive, sceneID: "scene-a") == .inactive)
        #expect(aggregation.effectivePhase == .inactive)

        #expect(aggregation.report(.active, sceneID: "scene-b") == .active)
        let activeRemoval = aggregation.remove(sceneID: "scene-b")
        #expect(activeRemoval?.removedPhase == .active)
        #expect(activeRemoval?.effectivePhaseChange == .inactive)
        #expect(aggregation.phasesBySceneID == ["scene-a": .inactive])
        #expect(aggregation.effectivePhase == .inactive)

        let finalRemoval = aggregation.remove(sceneID: "scene-a")
        #expect(finalRemoval?.removedPhase == .inactive)
        #expect(finalRemoval?.effectivePhaseChange == .background)
        #expect(aggregation.phasesBySceneID.isEmpty)
        #expect(aggregation.effectivePhase == .background)
    }

    @Test("Face ID access has a packaged privacy explanation")
    func faceIDUsageDescriptionExists() throws {
        let explanation = try #require(
            Bundle.main.object(forInfoDictionaryKey: "NSFaceIDUsageDescription") as? String
        )
        #expect(!explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("Continued processing submits a concrete registered identifier")
    func continuedIdentifierIsConcrete() {
        let identifier = BackgroundTaskKind.continued.submissionIdentifier
        #expect(identifier.hasPrefix("org.floeagent.ios.continued."))
        #expect(!identifier.contains("*"))
        #expect(identifier != BackgroundTaskKind.continued.rawValue)
        #expect(identifier.hasPrefix(
            BackgroundTaskKind.continued.submissionIdentifierPrefix
        ))
    }

    @Test("Continued processing coalesces duplicate outstanding submissions")
    func continuedSubmissionCoalescingContract() {
        var lifecycle = ContinuedProcessingLifecycle<String>()
        let beganFirstSubmission = lifecycle.beginSubmission()
        let beganDuplicateSubmission = lifecycle.beginSubmission()
        #expect(beganFirstSubmission)
        #expect(!beganDuplicateSubmission)

        lifecycle.finishSubmission(identifier: "continued.first")
        #expect(lifecycle.pendingRequestIdentifiers == ["continued.first"])
        #expect(lifecycle.outstandingRequestIdentifiers == ["continued.first"])
        #expect(lifecycle.hasOutstandingWork)
        let beganWhileRequestIsPending = lifecycle.beginSubmission()
        #expect(!beganWhileRequestIsPending)

        let cancelled = lifecycle.cancelPendingRequests()
        #expect(cancelled == ["continued.first"])
        #expect(!lifecycle.hasOutstandingWork)
        let beganAfterCancellation = lifecycle.beginSubmission()
        #expect(beganAfterCancellation)
        lifecycle.finishSubmission(identifier: nil)
        #expect(!lifecycle.hasOutstandingWork)
    }

    @Test("Continued processing retains multiple identifiers and de-duplicates handles")
    func continuedMultiHandleContract() {
        var lifecycle = ContinuedProcessingLifecycle<String>()
        let beganSubmission = lifecycle.beginSubmission()
        #expect(beganSubmission)
        lifecycle.finishSubmission(identifier: "continued.current")

        let acceptedCurrent = lifecycle.acceptHandle(
            identifier: "continued.current",
            handleID: "current-1"
        )
        let acceptedCurrentDuplicate = lifecycle.acceptHandle(
            identifier: "continued.current",
            handleID: "current-1"
        )
        let acceptedLegacyFirst = lifecycle.acceptHandle(
            identifier: "continued.legacy",
            handleID: "legacy-1"
        )
        let acceptedLegacySecond = lifecycle.acceptHandle(
            identifier: "continued.legacy",
            handleID: "legacy-2"
        )
        #expect(acceptedCurrent)
        #expect(!acceptedCurrentDuplicate)
        #expect(acceptedLegacyFirst)
        #expect(acceptedLegacySecond)

        #expect(lifecycle.pendingRequestIdentifiers.isEmpty)
        #expect(lifecycle.acceptedHandleCount == 3)
        #expect(lifecycle.acceptedHandlesByIdentifier["continued.current"]
            == ["current-1"])
        #expect(lifecycle.acceptedHandlesByIdentifier["continued.legacy"]
            == ["legacy-1", "legacy-2"])
        #expect(lifecycle.outstandingRequestIdentifiers
            == ["continued.current", "continued.legacy"])
        let beganWhileHandlesAreActive = lifecycle.beginSubmission()
        #expect(!beganWhileHandlesAreActive)

        let completedLegacyFirst = lifecycle.completeHandle(
            identifier: "continued.legacy",
            handleID: "legacy-1"
        )
        #expect(completedLegacyFirst)
        #expect(lifecycle.acceptedHandleCount == 2)
        #expect(lifecycle.acceptedHandlesByIdentifier["continued.legacy"]
            == ["legacy-2"])
    }

    @Test("Continued processing expiration drains every accepted sibling")
    func continuedExpirationDrainsSiblingsContract() {
        var lifecycle = ContinuedProcessingLifecycle<String>()
        let acceptedFirst = lifecycle.acceptHandle(
            identifier: "continued.first",
            handleID: "first-1"
        )
        let acceptedSecond = lifecycle.acceptHandle(
            identifier: "continued.second",
            handleID: "second-1"
        )
        let acceptedThird = lifecycle.acceptHandle(
            identifier: "continued.second",
            handleID: "second-2"
        )
        #expect(acceptedFirst)
        #expect(acceptedSecond)
        #expect(acceptedThird)

        let completed = lifecycle.completeAllAcceptedHandles()
        #expect(completed["continued.first"] == ["first-1"])
        #expect(completed["continued.second"] == ["second-1", "second-2"])
        #expect(lifecycle.acceptedHandleCount == 0)
        #expect(!lifecycle.hasOutstandingWork)
        let beganAfterExpiration = lifecycle.beginSubmission()
        #expect(beganAfterExpiration)
    }

    @Test("Continued expiration completes siblings before persistence can suspend")
    @MainActor
    func continuedExpirationIsCompletionFirstAndIdempotent() async {
        var lifecycle = ContinuedProcessingLifecycle<String>()
        lifecycle.acceptHandle(
            identifier: "continued.first",
            handleID: "first-1"
        )
        lifecycle.acceptHandle(
            identifier: "continued.sibling",
            handleID: "sibling-1"
        )
        var events: [String] = []
        let gate = ContinuedProcessingExpirationTestGate()

        let firstCallback = Task { @MainActor in
            await ContinuedProcessingExpirationSequence.runIfManaged(
                drainAndCompleteIfManaged: {
                    guard lifecycle.acceptedHandlesByIdentifier["continued.first"]?
                        .contains("first-1") == true else { return false }
                    let drained = lifecycle.completeAllAcceptedHandles()
                    let drainedCount = drained.values.reduce(0) { $0 + $1.count }
                    events.append("completed-\(drainedCount)")
                    return true
                },
                persistRecoveryPoints: {
                    events.append("persist-started")
                    await gate.suspendPersistence()
                    events.append("persist-finished")
                }
            )
        }

        // Persistence is now deliberately suspended. All sibling handles must
        // already be drained, proving there was no await before completion.
        await gate.waitUntilPersistenceStarts()
        #expect(lifecycle.acceptedHandleCount == 0)
        #expect(events == ["completed-2", "persist-started"])

        let duplicateHandled = await ContinuedProcessingExpirationSequence
            .runIfManaged(
                drainAndCompleteIfManaged: {
                    guard lifecycle.acceptedHandlesByIdentifier["continued.first"]?
                        .contains("first-1") == true else { return false }
                    _ = lifecycle.completeAllAcceptedHandles()
                    events.append("duplicate-completed")
                    return true
                },
                persistRecoveryPoints: {
                    events.append("duplicate-persisted")
                }
            )
        #expect(!duplicateHandled)
        #expect(events == ["completed-2", "persist-started"])

        await gate.releasePersistence()
        #expect(await firstCallback.value)
        #expect(events == [
            "completed-2",
            "persist-started",
            "persist-finished"
        ])
    }

    @Test("Empty audio buffers are rejected before Speech Analyzer")
    func emptyAudioBufferIsRejected() throws {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        let empty = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        #expect(empty.frameLength == 0)
        #expect(!VoiceBufferValidator.isUsable(empty))

        empty.frameLength = 1
        #expect(VoiceBufferValidator.isUsable(empty))
    }

    @Test("Feedback request includes the problem and redacts diagnostics")
    func feedbackRequestIsRedacted() throws {
        let secret = ["sk", "live1234567890abcdef"].joined(separator: "-")
        let request = try FeedbackUploadService.makeRequest(
            FeedbackSubmission(
                id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                problem: "Voice button crashes with key \(secret)",
                diagnostics: "authorization: Bearer eyJhbGciOiJ9.payload"
            ),
            boundary: "TestBoundary"
        )

        #expect(request.url == FeedbackUploadService.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type")
            == "multipart/form-data; boundary=TestBoundary")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key")
            == "11111111-2222-3333-4444-555555555555")
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("name=\"manifest\""))
        #expect(body.contains("Voice button crashes"))
        #expect(body.contains("diagnostics-11111111-2222-3333-4444-555555555555-0"))
        #expect(body.contains("⟨redacted⟩"))
        #expect(!body.contains(secret))
        #expect(!body.contains("eyJhbGciOiJ9.payload"))
    }

    @Test("Large diagnostics preserve configuration header and latest failure")
    func diagnosticsKeepHeadAndTail() {
        let input = "HEADER provider=DeepSeek\n"
            + String(repeating: "middle\n", count: 30_000)
            + "LATEST providerRequestBuildFailed\n"
        let bounded = FeedbackUploadService.boundedDiagnostics(input)
        #expect(bounded.count <= FeedbackUploadService.maximumDiagnosticsCharacters)
        #expect(bounded.contains("HEADER provider=DeepSeek"))
        #expect(bounded.contains("LATEST providerRequestBuildFailed"))
        #expect(bounded.contains("middle diagnostics omitted"))
    }

    @Test("Feedback images are bounded multipart attachments")
    func feedbackImagesAreMultipartAttachments() throws {
        let jpeg = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
        let attachment = FeedbackImageAttachment(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            filename: "screen\r\nshot.jpg",
            data: jpeg
        )
        let request = try FeedbackUploadService.makeRequest(
            FeedbackSubmission(
                problem: "The model request failed",
                diagnostics: "provider error",
                imageAttachments: [attachment]
            ),
            boundary: "ImageBoundary"
        )
        let body = try #require(request.httpBody)
        let headers = String(decoding: body, as: UTF8.self)

        #expect(headers.contains("name=\"attachments\""))
        #expect(headers.contains("filename=\"screen__shot.jpg\""))
        #expect(headers.contains("Content-Type: image/jpeg"))
        #expect(headers.contains("X-Floe-Attachment-ID: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        #expect(body.range(of: jpeg) != nil)
        #expect(headers.contains("\"image_attachment_count\":\"1\""))
    }

    @Test("Feedback rejects more than three images")
    func feedbackRejectsTooManyImages() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let attachments = (0..<4).map {
            FeedbackImageAttachment(filename: "image-\($0).jpg", data: jpeg)
        }
        #expect(throws: FeedbackUploadError.tooManyImages) {
            _ = try FeedbackUploadService.makeRequest(
                FeedbackSubmission(
                    problem: "Too many screenshots",
                    diagnostics: nil,
                    imageAttachments: attachments
                ),
                boundary: "ImageBoundary"
            )
        }
    }

    @Test("Feedback requires a user-written problem")
    func feedbackRequiresProblem() {
        #expect(throws: FeedbackUploadError.emptyProblem) {
            _ = try FeedbackUploadService.makeRequest(
                FeedbackSubmission(problem: "   ", diagnostics: nil),
                boundary: "TestBoundary"
            )
        }
    }

    @Test("Feedback success requires a server-issued report ID")
    func feedbackReceiptContract() {
        #expect(FeedbackUploadService.reportID(
            from: Data(#"{"report_id":"report-123"}"#.utf8)
        ) == "report-123")
        #expect(FeedbackUploadService.reportID(
            from: Data(#"{"accepted":[]}"#.utf8)
        ) == nil)
    }

    @Test("Feedback honors the server retry window after HTTP 429")
    func feedbackRetryAfterContract() throws {
        let response = try #require(HTTPURLResponse(
            url: FeedbackUploadService.endpoint,
            statusCode: 429,
            httpVersion: "HTTP/2",
            headerFields: ["Retry-After": "17"]
        ))
        #expect(FeedbackUploadService.retryAfterSeconds(from: response) == 17)
    }

    @Test("PiP starts and retries only from actionable stable states")
    @MainActor
    func pictureInPictureManualControlStateContract() {
        typealias State = BackgroundVideoService.PiPPreparationState
        #expect(State.prepared.manualAction == .start)
        #expect(State.active.manualAction == .stop)
        #expect(State.failed.manualAction == .retryPreparation)
        #expect(State.starting.manualAction == .none)
        #expect(State.renderingContent.manualAction == .none)
        #expect(State.waitingForMedia.manualAction == .none)
        #expect(State.idle.manualAction == .none)
        #expect(State.prepared.offersManualControl)
        #expect(State.starting.offersManualControl)
        #expect(State.active.offersManualControl)
        #expect(State.failed.offersManualControl)
        #expect(!State.renderingContent.offersManualControl)
        #expect(!State.waitingForMedia.offersManualControl)
        #expect(!State.idle.offersManualControl)

        let service = BackgroundVideoService()
        #expect(!service.shouldOfferManualControl)
        service.setRunContext(
            title: "Active task",
            progress: "Running",
            automaticallyStartsFromInline: true
        )
        #expect(service.shouldOfferManualControl)
        #expect(service.canPerformManualControl)
        #expect(service.manualControlTitle == "准备画中画")
        service.stop()
        #expect(!service.shouldOfferManualControl)
    }

    @Test("PiP host detach keeps controllers across inactive and background transitions")
    func pictureInPictureHostDetachLifecycleContract() {
        #expect(BackgroundPiPLifecyclePolicy.retainsControllerWhenHostDetaches(
            effectivePhase: .inactive,
            preparationPhase: .preparing
        ))
        #expect(BackgroundPiPLifecyclePolicy.retainsControllerWhenHostDetaches(
            effectivePhase: .background,
            preparationPhase: .prepared
        ))
        #expect(BackgroundPiPLifecyclePolicy.retainsControllerWhenHostDetaches(
            effectivePhase: .active,
            preparationPhase: .starting
        ))
        #expect(!BackgroundPiPLifecyclePolicy.retainsControllerWhenHostDetaches(
            effectivePhase: .active,
            preparationPhase: .prepared
        ))
        #expect(BackgroundPiPLifecyclePolicy.defersAutomaticHostDetach(
            effectivePhase: .active,
            preparationPhase: .prepared,
            automaticallyStartsFromInline: true,
            hasRunContext: true
        ))
        #expect(!BackgroundPiPLifecyclePolicy.defersAutomaticHostDetach(
            effectivePhase: .active,
            preparationPhase: .prepared,
            automaticallyStartsFromInline: false,
            hasRunContext: true
        ))
        #expect(!BackgroundPiPLifecyclePolicy.defersAutomaticHostDetach(
            effectivePhase: .background,
            preparationPhase: .prepared,
            automaticallyStartsFromInline: true,
            hasRunContext: true
        ))
        #expect(!BackgroundPiPLifecyclePolicy.shouldCancelDeferredHostDetach(
            hasUsableReplacementHost: false
        ))
        #expect(BackgroundPiPLifecyclePolicy.shouldCancelDeferredHostDetach(
            hasUsableReplacementHost: true
        ))
    }

    @Test("PiP records a background transition missed before media readiness")
    func pictureInPictureMissedAutomaticTransitionContract() {
        var policy = BackgroundPiPLifecyclePolicy()
        policy.setAutomaticStartEnabled(true, sourceReady: false)
        #expect(policy.automaticTransition == .armed)

        policy.transition(
            to: .inactive,
            automaticallyStartsFromInline: true,
            sourceReady: false,
            startPending: false
        )
        #expect(policy.automaticTransition == .missed)
        #expect(!policy.allowsAutomaticStartFromInline)

        policy.transition(
            to: .background,
            automaticallyStartsFromInline: true,
            sourceReady: false,
            startPending: false
        )
        policy.preparationDidBecomeReady(automaticallyStartsFromInline: true)
        #expect(policy.automaticTransition == .missed)
        #expect(!policy.allowsAutomaticStartFromInline)

        policy.transition(
            to: .active,
            automaticallyStartsFromInline: true,
            sourceReady: true,
            startPending: false
        )
        #expect(policy.automaticTransition == .armed)
        #expect(policy.allowsAutomaticStartFromInline)
    }

    @Test("PiP fallback starts only after a confirmed background transition")
    func pictureInPictureConfirmedBackgroundStartContract() {
        #expect(BackgroundPiPLifecyclePolicy.shouldStartAfterBackgroundTransition(
            effectivePhase: .background,
            preparationPhase: .prepared,
            automaticallyStartsFromInline: true,
            hasRunContext: true
        ))
        for phase in [BackgroundPiPEffectiveScenePhase.active, .inactive] {
            #expect(!BackgroundPiPLifecyclePolicy.shouldStartAfterBackgroundTransition(
                effectivePhase: phase,
                preparationPhase: .prepared,
                automaticallyStartsFromInline: true,
                hasRunContext: true
            ))
        }
        #expect(!BackgroundPiPLifecyclePolicy.shouldStartAfterBackgroundTransition(
            effectivePhase: .background,
            preparationPhase: .preparing,
            automaticallyStartsFromInline: true,
            hasRunContext: true
        ))
        #expect(!BackgroundPiPLifecyclePolicy.shouldStartAfterBackgroundTransition(
            effectivePhase: .background,
            preparationPhase: .prepared,
            automaticallyStartsFromInline: false,
            hasRunContext: true
        ))
    }

    @Test("PiP retracts an automatic start that completes after foreground return")
    func pictureInPictureLateStartContract() {
        var policy = BackgroundPiPLifecyclePolicy()
        policy.setAutomaticStartEnabled(true, sourceReady: true)
        policy.transition(
            to: .inactive,
            automaticallyStartsFromInline: true,
            sourceReady: true,
            startPending: false
        )
        policy.willStart(manualRequestPending: false)
        #expect(policy.startOrigin == .automaticInline)
        policy.transition(
            to: .active,
            automaticallyStartsFromInline: true,
            sourceReady: true,
            startPending: true
        )
        #expect(policy.stopWhenStartCompletes)
        #expect(policy.didStartRequiresImmediateStop())

        var manualPolicy = BackgroundPiPLifecyclePolicy()
        manualPolicy.manualStartRequested()
        manualPolicy.willStart(manualRequestPending: true)
        #expect(manualPolicy.startOrigin == .manualControl)
        #expect(!manualPolicy.didStartRequiresImmediateStop())
        manualPolicy.requestForegroundRetraction(startPending: true)
        #expect(manualPolicy.didStartRequiresImmediateStop())
    }

    @Test("PiP manual retry prepares first and starts only from a prepared tap")
    func pictureInPictureManualRetryContract() {
        #expect(BackgroundPiPLifecyclePolicy.manualTapDecision(
            preparationPhase: .failed,
            hasRunContext: true
        ) == .prepareOnly)
        #expect(BackgroundPiPLifecyclePolicy.manualTapDecision(
            preparationPhase: .idle,
            hasRunContext: true
        ) == .prepareOnly)
        #expect(BackgroundPiPLifecyclePolicy.manualTapDecision(
            preparationPhase: .prepared,
            hasRunContext: true
        ) == .startSynchronously)
        #expect(BackgroundPiPLifecyclePolicy.manualTapDecision(
            preparationPhase: .active,
            hasRunContext: true
        ) == .stop)
        #expect(BackgroundPiPLifecyclePolicy.manualTapDecision(
            preparationPhase: .prepared,
            hasRunContext: false
        ) == .none)
    }

    @Test("A failed or timed-out manual PiP request cannot classify a late callback as manual")
    func pictureInPictureManualStartTrackerClearsPendingOrigin() {
        var tracker = BackgroundPiPManualStartTracker()
        #expect(tracker.begin() == 1)
        #expect(tracker.isPending)

        // Both the timeout and failed-to-start delegate paths use settle().
        tracker.settle()
        #expect(!tracker.isPending)
        #expect(tracker.attemptSerial == 1)

        #expect(tracker.begin() == 2)
        #expect(tracker.isPending)
        tracker.reset()
        #expect(!tracker.isPending)
        #expect(tracker.attemptSerial == 0)

        #expect(BackgroundPiPStopOrigin.manualControl.suppressesCurrentBatch)
        #expect(!BackgroundPiPStopOrigin.foregroundRetraction.suppressesCurrentBatch)
        #expect(BackgroundPiPStopOrigin.foregroundRetraction
            .allowsAutomaticRepreparation)
        #expect(!BackgroundPiPStopOrigin.manualControl
            .allowsAutomaticRepreparation)
    }

    @Test("Only standard mode requests a continued-processing Live Activity")
    func backgroundExecutionLiveActivityPolicy() {
        #expect(BackgroundRunCoordinator.shouldRequestContinuedProcessing(for: .standard))
        #expect(!BackgroundRunCoordinator.shouldRequestContinuedProcessing(
            for: .pictureInPicture
        ))
        #expect(!BackgroundRunCoordinator.shouldRequestContinuedProcessing(for: .screenShare))
        #expect(!BackgroundRunCoordinator.shouldKeepContinuedProcessing(
            for: .standard,
            launchPreferencesLoaded: false
        ))
        #expect(BackgroundRunCoordinator.shouldKeepContinuedProcessing(
            for: .standard,
            launchPreferencesLoaded: true
        ))
        #expect(!BackgroundRunCoordinator.shouldKeepContinuedProcessing(
            for: .pictureInPicture,
            launchPreferencesLoaded: true
        ))
    }

    @Test("Continued processing requires explicit user origin and aggregate foreground")
    func continuedProcessingSubmissionOriginPolicy() {
        #expect(BackgroundRunCoordinator.shouldSubmitContinuedProcessing(
            for: .standard,
            launchPreferencesLoaded: true,
            origin: .explicitUserAction,
            hasAggregateForegroundScene: true
        ))
        #expect(!BackgroundRunCoordinator.shouldSubmitContinuedProcessing(
            for: .standard,
            launchPreferencesLoaded: true,
            origin: .explicitUserAction,
            hasAggregateForegroundScene: false
        ))

        let automaticOrigins: [ContinuedProcessingStartOrigin] = [
            .foregroundRecovery,
            .scheduledTask,
            .goalContinuation,
            .queuedInput,
            .externalAutomation,
            .automaticTool
        ]
        for origin in automaticOrigins {
            #expect(!origin.allowsContinuedSubmission)
            #expect(!BackgroundRunCoordinator.shouldSubmitContinuedProcessing(
                for: .standard,
                launchPreferencesLoaded: true,
                origin: origin,
                hasAggregateForegroundScene: true
            ))
        }
        #expect(!BackgroundRunCoordinator.shouldSubmitContinuedProcessing(
            for: .standard,
            launchPreferencesLoaded: false,
            origin: .explicitUserAction,
            hasAggregateForegroundScene: true
        ))
    }

    @Test("Eligibility keeps first run origin and drains when explicit work ends")
    func continuedProcessingEligibilityLifetime() {
        var state = ContinuedProcessingEligibilityState<UUID>()
        let recoveredRun = UUID()
        let registeredRecoveredRun = state.registerRun(
            recoveredRun,
            origin: .foregroundRecovery
        )
        let upgradedRecoveredRun = state.registerRun(
            recoveredRun,
            origin: .explicitUserAction
        )
        #expect(registeredRecoveredRun)
        #expect(!upgradedRecoveredRun)
        #expect(state.origin(forRun: recoveredRun) == .foregroundRecovery)
        #expect(!state.hasEligibleWork)

        let explicitRun = UUID()
        let scheduledRun = UUID()
        let registeredExplicitRun = state.registerRun(
            explicitRun,
            origin: .explicitUserAction
        )
        let registeredScheduledRun = state.registerRun(
            scheduledRun,
            origin: .scheduledTask
        )
        #expect(registeredExplicitRun)
        #expect(registeredScheduledRun)
        #expect(state.hasEligibleWork)
        state.finishRun(explicitRun)
        #expect(!state.hasEligibleWork)
    }

    @Test("Continued-processing requests fail instead of queueing stale Live Activities")
    func continuedProcessingRequestStrategy() {
        if #available(iOS 26.0, *) {
            let request = ContinuedProcessingRequestFactory.make(
                identifier: "org.floeagent.ios.continued.test",
                title: "Test",
                subtitle: "Test"
            )
            #expect(request.strategy == .fail)
        }
    }

    @Test("Media generation never creates continued processing for any origin")
    func mediaGenerationNeverCreatesContinuedProcessing() {
        for origin in ContinuedProcessingStartOrigin.allCases {
            #expect(!BackgroundRunCoordinator
                .shouldSubmitContinuedProcessingForMediaGeneration(origin: origin))
        }
    }

    @Test("Run recovery mode is immutable and legacy evidence fails closed")
    func runConversationModeResolutionContract() throws {
        #expect(try RunConversationModeResolver.resolve(
            persistedRunMode: "plan",
            checkpointMode: nil
        ) == .plan)
        #expect(try RunConversationModeResolver.resolve(
            persistedRunMode: "goal",
            checkpointMode: nil,
            checkpointWasUnreadable: true
        ) == .goal)
        #expect(try RunConversationModeResolver.resolve(
            persistedRunMode: nil,
            checkpointMode: .chat
        ) == .chat)

        #expect(throws: RunConversationModeResolutionError.missingLegacyEvidence(
            checkpointWasUnreadable: false
        )) {
            try RunConversationModeResolver.resolve(
                persistedRunMode: nil,
                checkpointMode: nil
            )
        }
        #expect(throws: RunConversationModeResolutionError.missingLegacyEvidence(
            checkpointWasUnreadable: true
        )) {
            try RunConversationModeResolver.resolve(
                persistedRunMode: nil,
                checkpointMode: nil,
                checkpointWasUnreadable: true
            )
        }
        #expect(throws: RunConversationModeResolutionError.invalidPersistedRunMode("agent")) {
            try RunConversationModeResolver.resolve(
                persistedRunMode: "agent",
                checkpointMode: nil
            )
        }
        #expect(throws: RunConversationModeResolutionError.conflictingEvidence(
            run: .plan,
            checkpoint: .chat
        )) {
            try RunConversationModeResolver.resolve(
                persistedRunMode: "plan",
                checkpointMode: .chat
            )
        }
    }

    @Test("Live background mode changes reconcile surfaces without requesting consent")
    func backgroundExecutionLiveSurfaceTransitionPolicy() {
        #expect(!BackgroundRunCoordinator.shouldReconcileVisualSurface(
            hasActiveRuns: false,
            hasRetainedPausedRun: false
        ))
        #expect(BackgroundRunCoordinator.shouldReconcileVisualSurface(
            hasActiveRuns: true,
            hasRetainedPausedRun: false
        ))
        #expect(BackgroundRunCoordinator.shouldReconcileVisualSurface(
            hasActiveRuns: false,
            hasRetainedPausedRun: true
        ))

        let standard = BackgroundRunCoordinator.visualSurfaceTransition(for: .standard)
        #expect(standard.stopsPictureInPicture)
        #expect(standard.stopsScreenShare)
        #expect(!standard.preparesPictureInPicture)
        #expect(!standard.requestsScreenShareAuthorization)

        let pictureInPicture = BackgroundRunCoordinator.visualSurfaceTransition(
            for: .pictureInPicture
        )
        #expect(!pictureInPicture.stopsPictureInPicture)
        #expect(pictureInPicture.stopsScreenShare)
        #expect(pictureInPicture.preparesPictureInPicture)
        #expect(!pictureInPicture.requestsScreenShareAuthorization)

        let screenShare = BackgroundRunCoordinator.visualSurfaceTransition(for: .screenShare)
        #expect(screenShare.stopsPictureInPicture)
        #expect(!screenShare.stopsScreenShare)
        #expect(!screenShare.preparesPictureInPicture)
        #expect(!screenShare.requestsScreenShareAuthorization)
    }

    @Test("Ordinary conversation retains its PiP source while checkpointed")
    func ordinaryConversationRetainedPiPSourceOwnership() {
        let conversationID = UUID()
        #expect(BackgroundRunCoordinator.shouldOfferVisualSurfaceControl(
            conversationID: conversationID,
            activeConversationIDs: [],
            retainedConversationID: conversationID
        ))
        #expect(BackgroundRunCoordinator.shouldOfferVisualSurfaceControl(
            conversationID: conversationID,
            activeConversationIDs: [nil, conversationID],
            retainedConversationID: nil
        ))
        #expect(!BackgroundRunCoordinator.shouldOfferVisualSurfaceControl(
            conversationID: conversationID,
            activeConversationIDs: [UUID(), nil],
            retainedConversationID: UUID()
        ))
    }

    @Test("Explicit SSH to VNC route excludes unrelated execution runtimes")
    func explicitRemoteRouteToolRestriction() {
        let available: Set<String> = [
            "ssh.listHosts", "ssh.execute", "ssh.updateHost",
            "vnc.status", "vnc.connect", "vnc.observe",
            "exec.javascript", "exec.localPython", "memory.organizePreview"
        ]
        let selected = ConversationCenter.toolsForExplicitRemoteRoute(
            request: "先用 SSH 配置主机，再测试 VNC 点击",
            from: available
        )
        #expect(selected == [
            "ssh.listHosts", "ssh.execute", "ssh.updateHost",
            "vnc.status", "vnc.connect", "vnc.observe"
        ])
        #expect(ConversationCenter.toolsForExplicitRemoteRoute(
            request: "用 VNC 看一下屏幕",
            from: available
        ) == selected)
        #expect(!selected!.contains("memory.organizePreview"))
    }

    @Test("Agent memory tools require current-turn memory intent")
    func agentMemoryToolIntentGate() {
        #expect(!ConversationCenter.requestsAgentMemoryTools(
            "测试 VNC，连接失败就用 SSH 修复"
        ))
        #expect(ConversationCenter.requestsAgentMemoryTools(
            "记住这台主机的新版本，并检查以前的记忆是否冲突"
        ))
        #expect(ConversationCenter.requestsAgentMemoryTools(
            "Please remember this version and replace the old memory"
        ))
    }

    @Test("Memory dream compares new facts with prior versions")
    @MainActor
    func memoryDreamPromptIncludesPriorMemoryAudit() {
        let conversationID = UUID()
        let oldMemory = MemoryEntry(
            scope: .agentGlobal,
            status: .active,
            content: "Floe version is 1.4.82",
            confidence: 1,
            importance: 0.8,
            sourceKind: .explicitUserRequest
        )
        let prompt = MemoryDreamService.buildPrompt([
            PersistedMessage(
                id: UUID(),
                conversationID: conversationID,
                role: "user",
                content: "Floe has upgraded to 1.4.83",
                createdAt: Date()
            )
        ], existing: [oldMemory])

        #expect(prompt.contains(oldMemory.id.uuidString))
        #expect(prompt.contains("Floe version is 1.4.82"))
        #expect(prompt.contains("conflictsWithEntryIDs"))
        #expect(prompt.contains("Never assume an older value is still current"))
    }

    @Test("Semantic organizer never duplicates deterministic review suggestions")
    func semanticMemorySuggestionMergeIsStable() {
        let first = UUID()
        let second = UUID()
        let deterministic = MemoryOrganizationSuggestion(
            kind: .possibleDuplicate,
            memoryIDs: [first, second],
            reason: "deterministic",
            canApplyAutomatically: false
        )
        let semantic = MemoryOrganizationSuggestion(
            kind: .possibleDuplicate,
            memoryIDs: [second, first],
            reason: "semantic",
            canApplyAutomatically: false
        )

        #expect(MemorySemanticOrganizer.merging([deterministic], [semantic]).count == 1)
    }
}
#endif
