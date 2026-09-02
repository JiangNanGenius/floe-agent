// FloeCore — deterministic lifetime policy for optional visual background surfaces.

import Foundation

/// Keeps a user's explicit Picture-in-Picture dismissal stable for the
/// lifetime of the current task batch. Scene transitions are not new user
/// intent, so returning to Floe and leaving again must not recreate PiP.
public struct BackgroundVisualSurfacePolicy: Sendable, Codable, Hashable {
    public private(set) var isSuppressedForCurrentBatch: Bool

    public init(isSuppressedForCurrentBatch: Bool = false) {
        self.isSuppressedForCurrentBatch = isSuppressedForCurrentBatch
    }

    /// A genuinely new run is a new batch eligibility boundary.
    public mutating func beginNewRun() {
        isSuppressedForCurrentBatch = false
    }

    /// Persists across foreground/background scene cycles until a new run.
    public mutating func userClosedPictureInPicture() {
        isSuppressedForCurrentBatch = true
    }

    public func allowsVisualSurface(for preference: BackgroundExecutionPreference) -> Bool {
        preference != .standard && !isSuppressedForCurrentBatch
    }
}
