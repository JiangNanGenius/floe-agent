#if canImport(AppIntents)
import AppIntents
import Foundation
import UniformTypeIdentifiers
import FloeCore

/// System actions and entity rehydration project the same exact-run service.
/// No view, second runtime, or conversation's latest run is involved.
@MainActor
enum FloeShortcutRunIntentBridge {
    #if DEBUG
    /// Task-scoped service injection for hosted intent `perform()` tests.
    /// There is deliberately no process-global install path: setting the
    /// value for one test task cannot reroute a concurrent real Shortcuts
    /// action, and the whole seam is compiled out of Release.
    @TaskLocal static var debugService: FloeShortcutRunService?
    #endif

    static func snapshot(
        runID: UUID,
        expectedConversationID: UUID?,
        environment: @MainActor () -> AppEnvironment
    ) async throws -> FloeShortcutRunEntity {
        try await withService(environment: environment) { service in
            let status = try await service.status(runID: runID)
            try verifyOwnership(status, expectedConversationID: expectedConversationID)
            return entity(status, requestedRunID: runID)
        }
    }

    /// Decodes the identity the system passed back. Every action requires both
    /// the exact run and the task that owns it: an empty or malformed task
    /// identifier is rejected outright so it can never degrade into "no
    /// ownership check" and let a reference read or cancel a run it cannot
    /// prove it owns. Entity rehydration supplies only run IDs and does not
    /// use this fence; actions always receive the full entity.
    static func identifier(
        _ entity: FloeShortcutRunEntity
    ) throws -> (runID: UUID, conversationID: UUID) {
        guard let runID = UUID(uuidString: entity.runID) else {
            throw FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.invalid_id"))
        }
        guard !entity.conversationID.isEmpty,
              let conversationID = UUID(uuidString: entity.conversationID) else {
            throw FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.invalid_id"))
        }
        return (runID, conversationID)
    }

    /// A reference's task identity must match the durable run's owner. This
    /// rejects a stale/edited/forged reference instead of silently reading a
    /// run from another conversation; the run ID alone is still the target.
    static func verifyOwnership(
        _ status: FloeRunStatus,
        expectedConversationID: UUID?
    ) throws {
        guard let expectedConversationID else { return }
        guard status.runID != nil, status.conversationID == expectedConversationID else {
            throw FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.ownership"))
        }
    }

    static func withService<Value: Sendable>(
        environment: @MainActor () -> AppEnvironment,
        operation: (FloeShortcutRunService) async throws -> Value
    ) async throws -> Value {
        #if DEBUG
        if let debugService {
            return try await operation(debugService)
        }
        #endif
        do {
            return try await operation(environment().floeShortcutRunService())
        } catch let error as FloeShortcutRunError {
            switch error {
            case .shortcutsCapabilityDisabled:
                throw FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.disabled"))
            case .applicationStillStarting:
                throw FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.starting"))
            case .durableStorageUnavailable:
                throw FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.storage"))
            case .modelConfigurationUnavailable:
                throw FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.configuration"))
            case .emptyTaskPrompt:
                throw FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.empty_prompt"))
            case .noDefaultModelConfigured:
                throw FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.no_model"))
            }
        }
    }

    static func entity(_ status: FloeRunStatus, requestedRunID: UUID,
                       waitTimedOut: Bool = false, cancellationRequested: Bool = false) -> FloeShortcutRunEntity {
        let displayState: FloeShortcutRunDisplayState
        switch status.state {
        case .running: displayState = status.rawStateName == "cancelling" ? .cancelling : .running
        case .waitingApproval: displayState = .waitingApproval
        case .paused: displayState = .paused
        case .checkpointed: displayState = .checkpointed
        case .completed: displayState = status.isFullSuccess ? .completed : .incomplete
        case .failed: displayState = .failed
        case .cancelled: displayState = .cancelled
        case .interrupted: displayState = .interrupted
        case .unavailable: displayState = .unavailable
        }
        return .init(runID: status.runID ?? requestedRunID,
            conversationID: status.conversationID,
            title: status.title ?? FloeL10n.l("shortcuts.run.entity.type"),
            state: displayState, isFinished: status.finishedPerDurableRecord,
            isSuccessful: status.isFullSuccess, requiresUserAction: status.requiresUserAction,
            waitTimedOut: waitTimedOut, cancellationRequested: cancellationRequested)
    }

    // MARK: Run files (S3-D)

    /// Concise user-facing copy for each honest file outcome. Internal
    /// details (sequence ids, digests, reasons) never reach this text; they
    /// stay in the typed error for diagnostics. Names use the display
    /// basename only — never an absolute path.
    static func fileActionError(_ error: FloeRunFilesError) -> FloeShortcutActionError {
        switch error {
        case .serviceUnavailable:
            return FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.files.service"))
        case .durableReadFailed:
            return FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.storage"))
        case .runUnavailable:
            return FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.files.unavailable"))
        case .ownership:
            return FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.ownership"))
        case .notReady:
            return FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.files.not_ready"))
        case .manifestDamaged:
            return FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.files.damaged"))
        case .overLimit:
            return FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.files.limit"))
        case .fileMissing(let displayName):
            return FloeShortcutActionError(
                FloeL10n.l("shortcuts.run.error.files.missing", displayName))
        case .fileChanged(let displayName):
            return FloeShortcutActionError(
                FloeL10n.l("shortcuts.run.error.files.changed", displayName))
        case .fileOversized(let displayName), .fileRejected(let displayName, _):
            return FloeShortcutActionError(
                FloeL10n.l("shortcuts.run.error.files.unverified", displayName))
        case .verificationCancelled:
            return FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.files.cancelled"))
        }
    }

    /// Types one verified snapshot for the system. Receipt metadata is the
    /// authority; an unknown or custom identifier degrades to the MIME
    /// type, and anything unusable falls back to plain `public.data` —
    /// never a fabricated content claim.
    static func intentFileType(for descriptor: FloeRunFileDescriptor) -> UTType {
        if let uti = descriptor.uti, !uti.isEmpty, let type = UTType(uti) {
            return type
        }
        if let type = UTType(mimeType: descriptor.mimeType) {
            return type
        }
        return .data
    }
}

struct FloeShortcutActionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
#endif
