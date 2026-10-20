#if canImport(AppIntents)
import AppIntents
import Foundation
import FloeCore

// Xcode 27 SDK compatibility migration: `openAppWhenRun` is deprecated from
// iOS 26 in favor of `supportedModes`. Every action below runs strictly in
// the background — exactly the previous `openAppWhenRun = false` semantics —
// declared as `IntentModes.background`. Perform bodies, parameters and
// return types are unchanged; this is metadata-only and is not evidence
// that any real system automation trigger fires (that stays device-
// qualified work).

/// The legacy RunFloeTaskIntent still returns its original String identifier.
/// These actions pass a typed reference to one execution through Shortcuts.
struct StartFloeRunIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcuts.run.start.title"
    static let description = IntentDescription("shortcuts.run.start.description")
    static let supportedModes: IntentModes = .background
    @Parameter(title: "shortcuts.run.parameter.prompt") var prompt: String
    @Parameter(title: "shortcuts.run.parameter.title") var taskTitle: String?
    @AppDependency private var environment: AppEnvironment

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<FloeShortcutRunEntity> {
        let value = try await FloeShortcutRunIntentBridge.withService(environment: { environment }) { service in
            let receipt = try await service.start(prompt: prompt, title: taskTitle)
            let status = try await service.status(runID: receipt.runID)
            return FloeShortcutRunIntentBridge.entity(status, requestedRunID: receipt.runID)
        }
        return .result(value: value)
    }
}

struct GetFloeRunStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcuts.run.status.title"
    static let description = IntentDescription("shortcuts.run.status.description")
    static let supportedModes: IntentModes = .background
    @Parameter(title: "shortcuts.run.entity.type") var run: FloeShortcutRunEntity
    @AppDependency private var environment: AppEnvironment

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<FloeShortcutRunEntity> {
        let identity = try FloeShortcutRunIntentBridge.identifier(run)
        let value = try await FloeShortcutRunIntentBridge.snapshot(
            runID: identity.runID,
            expectedConversationID: identity.conversationID,
            environment: { environment }
        )
        return .result(value: value)
    }
}

struct WaitForFloeRunIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcuts.run.wait.title"
    static let description = IntentDescription("shortcuts.run.wait.description")
    static let supportedModes: IntentModes = .background
    @Parameter(title: "shortcuts.run.entity.type") var run: FloeShortcutRunEntity
    @Parameter(title: "shortcuts.run.parameter.timeout", default: 20) var timeoutSeconds: Double
    @AppDependency private var environment: AppEnvironment

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<FloeShortcutRunEntity> {
        let identity = try FloeShortcutRunIntentBridge.identifier(run)
        let value = try await FloeShortcutRunIntentBridge.withService(environment: { environment }) { service in
            let outcome = try await service.wait(runID: identity.runID, timeout: timeoutSeconds)
            try FloeShortcutRunIntentBridge.verifyOwnership(
                outcome.status, expectedConversationID: identity.conversationID)
            switch outcome {
            case .terminalReached(let status), .userActionRequired(let status), .waitCancelled(let status):
                return FloeShortcutRunIntentBridge.entity(status, requestedRunID: identity.runID)
            case .budgetExhausted(let status):
                return FloeShortcutRunIntentBridge.entity(
                    status, requestedRunID: identity.runID, waitTimedOut: true)
            }
        }
        return .result(value: value)
    }
}

struct GetFloeRunTextIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcuts.run.text.title"
    static let description = IntentDescription("shortcuts.run.text.description")
    static let supportedModes: IntentModes = .background
    @Parameter(title: "shortcuts.run.entity.type") var run: FloeShortcutRunEntity
    @Parameter(title: "shortcuts.run.parameter.partial", default: false) var includePartial: Bool
    @AppDependency private var environment: AppEnvironment

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let identity = try FloeShortcutRunIntentBridge.identifier(run)
        let text = try await FloeShortcutRunIntentBridge.withService(environment: { environment }) { service in
            let result = try await service.textResult(runID: identity.runID)
            try FloeShortcutRunIntentBridge.verifyOwnership(
                result.status, expectedConversationID: identity.conversationID)
            switch result.completeness {
            case .complete:
                break
            case .partial:
                guard includePartial else {
                    throw FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.partial"))
                }
            case .absent:
                throw FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.no_reply"))
            case .untrustworthy:
                throw FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.not_finished"))
            }
            guard let text = result.text else {
                throw FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.no_reply"))
            }
            return text
        }
        return .result(value: text)
    }
}

struct CancelFloeRunIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcuts.run.cancel.title"
    static let description = IntentDescription("shortcuts.run.cancel.description")
    static let supportedModes: IntentModes = .background
    @Parameter(title: "shortcuts.run.entity.type") var run: FloeShortcutRunEntity
    @AppDependency private var environment: AppEnvironment

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<FloeShortcutRunEntity> {
        let identity = try FloeShortcutRunIntentBridge.identifier(run)
        let value = try await FloeShortcutRunIntentBridge.withService(environment: { environment }) { service in
            // Verify the reference's task before asking the center to stop
            // anything: a stale/edited reference must never cancel a run in
            // another conversation. The conversation of a run is immutable,
            // so a pre-cancel read is authoritative and later runs in the
            // same conversation have their own IDs and are untouched.
            let status = try await service.status(runID: identity.runID)
            try FloeShortcutRunIntentBridge.verifyOwnership(
                status, expectedConversationID: identity.conversationID)
            let result = try await service.cancel(runID: identity.runID)
            if result.noLiveOwner {
                throw FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.no_live_owner"))
            }
            return FloeShortcutRunIntentBridge.entity(
                result.status, requestedRunID: identity.runID,
                cancellationRequested: result.requested)
        }
        return .result(value: value)
    }
}

/// S3-D: exactly one thin file action. All ownership, durable projection,
/// cap and snapshot-verification business logic lives in the service; this
/// action only passes the entity's exact identity, maps honest errors to
/// concise bilingual copy, and types each verified snapshot as an
/// `IntentFile`. Files are durable run-owned snapshots, so
/// `removedOnCompletion` is never set — it stays at its default false and
/// Shortcuts must not delete them when the run finishes. Native list
/// actions ("Repeat With Each", "Get Item from Input") consume individual
/// entries of the returned array; no File AppEntity or export family exists.
struct GetFloeRunFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcuts.run.files.title"
    static let description = IntentDescription("shortcuts.run.files.description")
    static let supportedModes: IntentModes = .background
    @Parameter(title: "shortcuts.run.entity.type") var run: FloeShortcutRunEntity
    @Parameter(title: "shortcuts.run.parameter.partial", default: false) var includePartial: Bool
    @AppDependency private var environment: AppEnvironment

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let identity = try FloeShortcutRunIntentBridge.identifier(run)
        let result = try await FloeShortcutRunIntentBridge.withService(environment: { environment }) { service in
            do {
                return try await service.fileResult(
                    runID: identity.runID,
                    expectedConversationID: identity.conversationID,
                    includePartial: includePartial
                )
            } catch let error as FloeRunFilesError {
                throw FloeShortcutRunIntentBridge.fileActionError(error)
            }
        }
        // Verified snapshots only; `IntentFile(data:)` is deliberately not
        // used so up-to-1 GiB bytes are never eagerly loaded here (URL-based
        // files memory-map lazily).
        let files = result.files.map { descriptor in
            IntentFile(
                fileURL: descriptor.url,
                filename: descriptor.displayName,
                type: FloeShortcutRunIntentBridge.intentFileType(for: descriptor)
            )
        }
        return .result(value: files)
    }
}
#endif
