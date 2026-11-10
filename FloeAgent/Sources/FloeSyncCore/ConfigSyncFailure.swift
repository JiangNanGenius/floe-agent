// SPDX-License-Identifier: MPL-2.0
import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// Safe configuration-sync reasons; independent of credential availability.
/// No account IDs, record payloads, URLs or secret bytes enter this value.
public struct ConfigSyncFailure: Sendable, Hashable {
    public enum Reason: String, Sendable, Hashable {
        case signInRequired, temporarilyUnavailable, configurationUnavailable, synchronizationFailed
    }
    public enum Phase: String, Sendable, Hashable { case configuration, synchronization }
    public let reason: Reason
    public let phase: Phase
    public let errorDomain: String?
    public let errorCode: Int?
    /// CloudKit's server-provided retry hint in seconds when the error
    /// carried a VALID one (finite and positive; `CKErrorRetryAfterKey`).
    /// A bounded numeric delay only — never a record id, account, URL or
    /// payload. NaN, infinity and non-positive values never reach this
    /// field: they are treated as absent and the engine falls back to its
    /// local bounded backoff. The sync engine consumes the hint for its
    /// transient retry as the server's own wait (it may exceed the local
    /// cap); user copy never renders raw protocol values or counts.
    public let retryAfter: TimeInterval?
    public init(reason: Reason, phase: Phase, retryAfter: TimeInterval? = nil) {
        self.reason = reason; self.phase = phase; errorDomain = nil; errorCode = nil
        self.retryAfter = retryAfter
    }
    public init(error: Error, phase: Phase) {
        self.phase = phase
        let ns = error as NSError
        let safeDomains = ["CKErrorDomain", NSURLErrorDomain, NSCocoaErrorDomain, "FloeCore.FloeError"]
        errorDomain = safeDomains.contains(ns.domain) ? ns.domain : "other"
        errorCode = ns.code
        var retryHint: TimeInterval?
        #if canImport(CloudKit)
        if let hint = ns.userInfo[CKErrorRetryAfterKey] as? NSNumber,
           hint.doubleValue > 0, hint.doubleValue.isFinite {
            retryHint = hint.doubleValue
        }
        if ns.domain == CKErrorDomain, ns.code == CKError.Code.notAuthenticated.rawValue {
            reason = .signInRequired; self.retryAfter = retryHint; return
        }
        if ns.domain == CKErrorDomain,
           [CKError.Code.networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy].map(\.rawValue).contains(ns.code) {
            reason = .temporarilyUnavailable; self.retryAfter = retryHint; return
        }
        #endif
        if ns.domain == NSURLErrorDomain { reason = .temporarilyUnavailable }
        else { reason = phase == .configuration ? .configurationUnavailable : .synchronizationFailed }
        self.retryAfter = retryHint
    }
    public func message(chinese: Bool) -> String {
        switch reason {
        case .signInRequired:
            chinese ? "请登录 iCloud 后重试配置同步。" : "Sign in to iCloud, then retry configuration sync."
        case .temporarilyUnavailable:
            chinese ? "配置同步暂不可用，请稍后重试。" : "Configuration sync is temporarily unavailable. Try again shortly."
        case .configurationUnavailable:
            chinese ? "配置同步尚未就绪，请重试。" : "Configuration sync is not ready. Try again."
        case .synchronizationFailed:
            chinese ? "未能完成配置同步，请重试。" : "Configuration sync could not finish. Try again."
        }
    }
    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == URLError.cancelled.rawValue { return true }
        #if canImport(CloudKit)
        if ns.domain == CKErrorDomain, ns.code == CKError.Code.operationCancelled.rawValue { return true }
        #endif
        return false
    }
}

/// One actor snapshot prevents a UI from pairing an old status with a newer
/// failure. It is a projection, never another sync runner or persisted state.
public struct ConfigSyncSnapshot: Sendable, Hashable {
    public let status: SyncStatus
    public let failure: ConfigSyncFailure?
    public let lastSyncAt: Date?
    public init(status: SyncStatus, failure: ConfigSyncFailure?, lastSyncAt: Date?) {
        self.status = status; self.failure = failure; self.lastSyncAt = lastSyncAt
    }
}
