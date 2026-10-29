import Foundation

/// Shared by managed text/Office writers so version comparison and atomic
/// replacement cannot interleave across different service instances. Hold only
/// during synchronous file transactions, never while awaiting user/model input.
/// Arbitrary external programs must still cooperate with file coordination;
/// this is not a kernel-wide file lock or a native-code sandbox.
public enum ManagedFileMutationLock {
    public static let shared = NSRecursiveLock()
}
