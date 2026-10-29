import Foundation

/// Separates crash-leftover recovery from runs created by the current app
/// process. A durable run can briefly exist before its live service is
/// registered, so ownership alone is not sufficient during app startup.
public enum LaunchRunRecoveryPolicy {
    public static func shouldInterrupt(
        startedAt: Date,
        currentProcessCutoff: Date,
        hasLiveOwner: Bool
    ) -> Bool {
        startedAt < currentProcessCutoff && !hasLiveOwner
    }
}
