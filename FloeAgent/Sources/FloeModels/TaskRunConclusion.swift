// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A completed invocation and a paused, resumable task are different product
/// states. A transport/cleanup error cannot replace an already-settled result.
public enum TaskRunConclusion: String, Sendable, Equatable {
    case completed, failed, checkpointed, cancelled

    public static func from(state: String) -> Self? {
        switch state.lowercased() {
        case "completed": .completed
        case "failed": .failed
        case "checkpointed", "interrupted": .checkpointed
        case "cancelled", "canceled", "aborted": .cancelled
        default: nil
        }
    }

    public var invocationSettledNormally: Bool { self == .completed || self == .checkpointed }

    /// Snapshot repaint, late usage and terminal events are not a resume.
    public static func isRuntimeActivity(state: String) -> Bool {
        ["preparing", "streamingModel", "preparingToolCall", "executingTool", "committingResults",
         "compacting", "verifying", "reconnecting"].contains(state)
    }
}
