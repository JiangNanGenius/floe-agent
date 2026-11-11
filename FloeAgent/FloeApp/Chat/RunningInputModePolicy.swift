// FloeApp — Running-input (steer/queue) send and menu decisions.
//
// SPDX-License-Identifier: MPL-2.0
//
// Pure decision logic for the composer send path and the pending-message
// three-dot menu: an idle composer executes directly, an active run routes
// through the user's global steer/queue preference, and a pending message's
// mode migrates both ways only while it has NOT been consumed. Kept free of
// App-runtime dependencies (Foundation + FloeCore + FloeModels only, no
// UIKit) so the contract is directly testable on any Apple platform.

import Foundation
import FloeCore
import FloeModels

enum PendingInputModeAction: String, CaseIterable, Sendable {
    /// queued -> steer: deliver into the active run.
    case promoteToSteer
    /// steerPending -> queued: withdraw before consumption, back to waiting.
    case demoteToQueue
}

/// Where one composed message goes. This is the single send-path rule for
/// ordinary chat and every file assistant.
enum RunningInputSendRoute: Equatable, Sendable {
    /// No active run: the message starts its own run immediately.
    case executeImmediately
    /// An active run owns the turn: route through the running-input path
    /// with the resolved steer/queue mode.
    case runningInput(RunningInputMode)
}

enum RunningInputModePolicy {

    /// One rule for ordinary chat and every file assistant: an idle composer
    /// executes directly; only an ACTIVE run routes the draft through the
    /// running-input path with the user's resolved steer/queue mode. The
    /// mode arrives from ThreadDetailViewModel, which follows the global
    /// setting live unless this thread's user overrode it explicitly.
    static func sendRoute(
        isRunActive: Bool,
        mode: RunningInputMode
    ) -> RunningInputSendRoute {
        isRunActive ? .runningInput(mode) : .executeImmediately
    }

    /// Mode-migration actions offered by a pending row's three-dot menu.
    /// Bidirectional while unconsumed; a consumed (or cancelled) row offers
    /// nothing because its content can no longer be recalled honestly.
    static func modeActions(
        status: PendingUserInputStatus,
        canSteer: Bool
    ) -> [PendingInputModeAction] {
        switch status {
        case .queued:
            // Without an active run there is nothing to steer into; the row
            // already waits for the current run to finish.
            return canSteer ? [.promoteToSteer] : []
        case .steerPending:
            return [.demoteToQueue]
        case .promoting, .consumed, .cancelled:
            return []
        }
    }
}
