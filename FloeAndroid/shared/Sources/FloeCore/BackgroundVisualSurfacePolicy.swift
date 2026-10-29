// FloeCore — deterministic lifetime policy for optional visual background surfaces.

import Foundation

/// Keeps a user's explicit Picture-in-Picture dismissal stable for the
/// lifetime of the current task batch. Scene transitions are not new user
/// intent, so returning to Floe and leaving again must not recreate PiP.
public struct BackgroundVisualSurfacePolicy: Sendable, Codable, Hashable {
    public private(set) var batchID: UUID
    public private(set) var activeRunIDs: Set<UUID>
    public private(set) var isSuppressedForCurrentBatch: Bool
    public private(set) var lastSceneTransitionAt: Date?

    public init(
        batchID: UUID = UUID(),
        activeRunIDs: Set<UUID> = [],
        isSuppressedForCurrentBatch: Bool = false,
        lastSceneTransitionAt: Date? = nil
    ) {
        self.batchID = batchID
        self.activeRunIDs = activeRunIDs
        self.isSuppressedForCurrentBatch = isSuppressedForCurrentBatch
        self.lastSceneTransitionAt = lastSceneTransitionAt
    }

    /// Concurrent runs join the current batch and cannot undo a dismissal.
    /// A persisted run ID identifies a cold restoration of that same batch.
    public mutating func beginRun(
        _ runID: UUID,
        currentlyActiveRunIDs: Set<UUID>
    ) {
        if currentlyActiveRunIDs.isEmpty {
            if activeRunIDs.contains(runID) {
                activeRunIDs = [runID]
            } else {
                batchID = UUID()
                activeRunIDs = [runID]
                isSuppressedForCurrentBatch = false
            }
        } else {
            activeRunIDs.formUnion(currentlyActiveRunIDs)
            activeRunIDs.insert(runID)
        }
    }

    public mutating func finishRun(_ runID: UUID) {
        activeRunIDs.remove(runID)
    }

    /// Persists across foreground/background scene cycles until a new run.
    public mutating func userClosedPictureInPicture() {
        isSuppressedForCurrentBatch = true
    }

    public mutating func recordSceneTransition(at date: Date = Date()) {
        lastSceneTransitionAt = date
    }

    public func allowsVisualSurface(for preference: BackgroundExecutionPreference) -> Bool {
        preference != .standard && !isSuppressedForCurrentBatch
    }
}
