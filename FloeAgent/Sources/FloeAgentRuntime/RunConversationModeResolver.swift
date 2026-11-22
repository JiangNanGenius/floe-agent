// SPDX-License-Identifier: MPL-2.0

import Foundation

public enum RunConversationModeResolutionError: Error, Equatable, LocalizedError {
    case invalidPersistedRunMode(String)
    case conflictingEvidence(run: ConversationMode, checkpoint: ConversationMode)
    case missingLegacyEvidence(checkpointWasUnreadable: Bool)

    public var errorDescription: String? {
        switch self {
        case .invalidPersistedRunMode(let raw):
            "The saved run has an unsupported execution mode (\(raw)). Update Floe or start a new task."
        case .conflictingEvidence:
            "The saved run and its checkpoint disagree about execution mode. Recovery stopped before any model or tool execution."
        case .missingLegacyEvidence(let checkpointWasUnreadable):
            checkpointWasUnreadable
                ? "The legacy run has no trusted execution mode and its checkpoint is unreadable. Recovery stopped before any model or tool execution."
                : "The legacy run has no trusted execution mode. Recovery stopped before any model or tool execution."
        }
    }
}

/// Resolves the immutable run contract without consulting the conversation's
/// mutable current mode. New V34 rows always carry `persistedRunMode`; a
/// legacy NULL row may use a trustworthy checkpoint and otherwise fails closed.
public enum RunConversationModeResolver {
    public static func resolve(
        persistedRunMode: String?,
        checkpointMode: ConversationMode?,
        checkpointWasUnreadable: Bool = false
    ) throws -> ConversationMode {
        let runMode: ConversationMode?
        if let persistedRunMode {
            guard let parsed = ConversationMode(rawValue: persistedRunMode) else {
                throw RunConversationModeResolutionError
                    .invalidPersistedRunMode(persistedRunMode)
            }
            runMode = parsed
        } else {
            runMode = nil
        }

        if let runMode {
            if let checkpointMode, checkpointMode != runMode {
                throw RunConversationModeResolutionError.conflictingEvidence(
                    run: runMode,
                    checkpoint: checkpointMode
                )
            }
            // The V34 run row is authoritative. A missing/truncated checkpoint
            // changes replay detail, not whether plan/goal semantics are safe.
            return runMode
        }
        if !checkpointWasUnreadable, let checkpointMode {
            return checkpointMode
        }
        throw RunConversationModeResolutionError.missingLegacyEvidence(
            checkpointWasUnreadable: checkpointWasUnreadable
        )
    }
}
