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
    public init(reason: Reason, phase: Phase) {
        self.reason = reason; self.phase = phase; errorDomain = nil; errorCode = nil
    }
    public init(error: Error, phase: Phase) {
        self.phase = phase
        let ns = error as NSError
        let safeDomains = ["CKErrorDomain", NSURLErrorDomain, NSCocoaErrorDomain, "FloeCore.FloeError"]
        errorDomain = safeDomains.contains(ns.domain) ? ns.domain : "other"
        errorCode = ns.code
        #if canImport(CloudKit)
        if ns.domain == CKErrorDomain, ns.code == CKError.Code.notAuthenticated.rawValue {
            reason = .signInRequired; return
        }
        if ns.domain == CKErrorDomain,
           [CKError.Code.networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy].map(\.rawValue).contains(ns.code) {
            reason = .temporarilyUnavailable; return
        }
        #endif
        if ns.domain == NSURLErrorDomain { reason = .temporarilyUnavailable }
        else { reason = phase == .configuration ? .configurationUnavailable : .synchronizationFailed }
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
