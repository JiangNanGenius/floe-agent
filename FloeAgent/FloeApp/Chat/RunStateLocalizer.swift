// FloeApp — Machine state → localized title / color / loading flag.
//
// SPDX-License-Identifier: MPL-2.0
//
// The ONLY mapping from run state machine names to presentation (see
// ARCHITECTURE §6.2). Views must not interpret state names themselves.
// Rule of record: an `error` event or a `failed` state must immediately
// end the loading state — `isLoading(stateName:hasError:)` is the sole
// decision function.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Static mapping from state machine names (preparing, streamingModel,
/// …) to localized copy, semantic color and the loading flag.
enum RunStateLocalizer {

    /// Localized title for a machine state name (§6.2 mapping table).
    /// Unknown names fall back to the honest "unknown" state instead of
    /// leaking raw machine text into the UI.
    static func title(for stateName: String) -> LocalizedStringKey {
        switch stateName {
        case "preparing": "state.preparing"
        case "streamingModel": "state.streaming"
        case "executingTool": "state.executing_tool"
        case "waitingApproval": "state.waiting_approval"
        case "compacting", "checkpointed", "paused": "state.paused"
        case "cancelling": "state.cancelling"
        case "completed": "state.completed"
        case "failed": "state.failed"
        default: "state.unknown"
        }
    }

    /// Semantic color for a machine state name (§6.2 mapping table).
    static func color(for stateName: String) -> Color {
        switch stateName {
        case "preparing", "streamingModel", "executingTool":
            FloeTheme.primary
        case "waitingApproval", "compacting", "checkpointed", "paused":
            FloeTheme.pending
        case "cancelling", "failed":
            FloeTheme.destructive
        case "completed":
            FloeTheme.success
        default:
            FloeTheme.unknown
        }
    }

    /// Whether the run should present an in-progress affordance.
    ///
    /// Rule (§6.2): any error event or the failed state ends the loading
    /// state immediately; waitingApproval and paused-like states show a
    /// static (non-spinning) affordance; terminal states never load.
    static func isLoading(stateName: String, hasError: Bool) -> Bool {
        if hasError { return false }
        switch stateName {
        case "preparing", "streamingModel", "executingTool", "cancelling":
            return true
        default:
            return false
        }
    }

    /// Whether the state name is terminal (completed or failed).
    static func isTerminal(_ stateName: String) -> Bool {
        stateName == "completed" || stateName == "failed"
    }
}
#endif
