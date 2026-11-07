// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeTools

enum APNsEnrollmentDeliveryResult: Sendable, Equatable { case registered, pending, ignored }

enum APNsInstallChannel: String, Codable, Sendable { case testFlight, appStore, development, unknown }
enum APNsSigningEnvironment: String, Codable, Sendable { case development, production, unknown }
enum APNsVisibleAuthorization: String, Codable, Sendable { case notDetermined, denied, authorized, provisional, ephemeral, unknown
    var allowed: Bool { [.authorized, .provisional, .ephemeral].contains(self) }
}

struct APNsPreferences: Codable, Hashable, Sendable {
    var enabled = false
    var versionReminders = false
    var revision: Int64 = 0
}

/// Computed by the EXISTING scheduler after ownership/occurrence/run
/// reconciliation. This type contains neither task text nor permission.
struct APNsEligibilitySnapshot: Codable, Hashable, Sendable {
    var hasEnabledSchedule: Bool
    var hasProgressableExecution: Bool
    var sampledAt: Date
    var eligible: Bool { hasEnabledSchedule || hasProgressableExecution }
    static let unavailable = Self(hasEnabledSchedule: false, hasProgressableExecution: false, sampledAt: .distantPast)
    init(hasEnabledSchedule: Bool, hasProgressableExecution: Bool, sampledAt: Date = Date()) {
        self.hasEnabledSchedule = hasEnabledSchedule
        self.hasProgressableExecution = hasProgressableExecution; self.sampledAt = sampledAt
    }
}

struct APNsInstalledVersion: Codable, Hashable, Sendable {
    var version: String
    var build: String
    var channel: APNsInstallChannel
    var bundleID: String
    static func current(channel: APNsInstallChannel) -> Self {
        .init(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            channel: channel, bundleID: Bundle.main.bundleIdentifier ?? "")
    }
    func alreadyInstalled(_ release: APNsReleaseRecord) -> Bool {
        // Build identity is shared by TestFlight and App Store. Moving the
        // SAME build to the store cannot create a second update reminder.
        if let current = Int64(build), let candidate = Int64(release.build), current >= candidate { return true }
        if build == release.build { return true }
        return version.compare(release.version, options: .numeric) == .orderedDescending
    }
}

struct APNsRegistrationRequest: Codable, Sendable {
    var schemaVersion = 1
    var installationID: UUID
    var revision: Int64
    var enabled: Bool
    var versionReminders: Bool
    var hasEligibleSchedules: Bool
    var visibleAuthorization: APNsVisibleAuthorization
    var backgroundRefreshAvailable: Bool
    var installed: APNsInstalledVersion
    /// Resolved from this exact package's signing, never DEBUG or channel.
    var signingEnvironment: APNsSigningEnvironment
    var deviceToken: String?
}
struct APNsRegistrationReceipt: Codable, Hashable, Sendable {
    var installationID: UUID
    var acceptedRevision: Int64
    var enabled: Bool
    var acceptedAt: Date
    var leaseExpiresAt: Date
}

struct APNsReleaseRecord: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var channel: APNsInstallChannel
    var version: String
    var build: String
    var title: String
    var notes: String
    var isInstallable: Bool
    var availableAt: Date
}

struct APNsPayload: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case heartbeat, release }
    var schemaVersion: Int
    var kind: Kind
    var eventID: UUID
    var installationID: UUID
    var registrationRevision: Int64
    var sentAt: Date
    var expiresAt: Date
    var releaseID: String?
    var channel: APNsInstallChannel?
}

enum APNsDeliverySource: String, Sendable { case foreground, background, notificationTap }
enum APNsWakeOutcome: String, Codable, Sendable { case newData, noData, deferred, rejected }
struct APNsWakeRequest: Sendable {
    let eventID: UUID
    let receivedAt: Date
    let deadline: Date
    let cancellation: CancellationToken
}

struct APNsSeenDelivery: Codable, Sendable {
    var key: String
    var expiresAt: Date
}
struct APNsPersistentState: Codable, Sendable {
    var schemaVersion = 1
    var installationID = UUID()
    var preferences = APNsPreferences()
    var receipt: APNsRegistrationReceipt?
    var registrationFingerprint: String?
    /// True only after the service requested fresh OS token proof. Optional
    /// preserves the on-disk schema of already saved installations.
    var tokenRenewalPending: Bool?
    var nextRegistrationAttemptAt: Date?
    var seen: [APNsSeenDelivery] = []
    var lastReceivedAt: Date?
    var lastWakeOutcome: APNsWakeOutcome?
}

struct APNsStatus: Codable, Sendable {
    var enabled: Bool
    var versionReminders: Bool
    var visibleAuthorization: APNsVisibleAuthorization
    var backgroundRefreshAvailable: Bool
    var hasEligibleWork: Bool?
    var deviceRegistered: Bool
    var serverConnected: Bool
    var channel: APNsInstallChannel
    var lastServerAcceptedAt: Date?
    var nextRegistrationAttemptAt: Date?
    var lastReceivedAt: Date?
    var lastWakeOutcome: APNsWakeOutcome?
    var syncState: String
}

protocol APNsEnrollmentTransport: Sendable {
    /// Server MUST authenticate installationID+secret and reject older
    /// revisions, including late requests after a successful revocation.
    func apply(_ request: APNsRegistrationRequest, installationSecret: Data) async throws -> APNsRegistrationReceipt
}
protocol APNsReleaseResolving: Sendable {
    func release(id: String, channel: APNsInstallChannel) async throws -> APNsReleaseRecord
}

protocol APNsReleaseHistoryResolving: APNsReleaseResolving {
    /// Formerly public release notes only. Never an installability receipt.
    func releaseHistory(id: String, channel: APNsInstallChannel) async throws -> APNsReleaseRecord
}

/// Only a recognized status/code pair may change the local registration
/// lifecycle. A generic 401/409 never authorizes proof or identity reset.
enum APNsRemoteFailure: String, Codable, Sendable {
    case invalidAuthorization, enrollmentProofRequired, enrollmentProofExpired, enrollmentProofUsed, enrollmentProofMismatch
    case tokenNeedsRenewal, staleRevision, revisionConflict, challengePending
    case unknownAppAttestKey, appAttestAssertionRequired
    case invalidAppProof, channelProofMismatch, unsupportedInstallChannel

    var status: Int {
        switch self {
        case .invalidAuthorization, .enrollmentProofRequired, .enrollmentProofExpired, .enrollmentProofUsed, .enrollmentProofMismatch: 401
        case .tokenNeedsRenewal, .staleRevision, .revisionConflict, .challengePending,
             .unknownAppAttestKey, .appAttestAssertionRequired: 409
        case .invalidAppProof, .channelProofMismatch, .unsupportedInstallChannel: 422
        }
    }
}

enum APNsServiceError: Error, LocalizedError, Sendable {
    case invalidPayload, stalePayload, disabled, duplicate, unavailable, unconfigured, storage, protocolViolation, http(Int)
    case remote(APNsRemoteFailure)
    case enrollmentPending, foregroundRequired, attestationUnavailable, rateLimited(until: Date), enrollmentDeferred(until: Date)
    var errorDescription: String? {
        switch self {
        case .invalidPayload, .stalePayload: APNsText.t("这条通知已失效。", "This notification is no longer valid.")
        case .disabled: APNsText.t("推送已关闭。", "Push is off.")
        case .duplicate: APNsText.t("这条通知已处理。", "This notification was already handled.")
        case .unconfigured: APNsText.t("推送服务尚未连接。", "The push service is not connected yet.")
        case .storage: APNsText.t("无法读取推送设置，请重试。", "Unable to read push settings. Try again.")
        case .protocolViolation: APNsText.t("未能确认服务登记，请重试。", "Service registration could not be confirmed. Try again.")
        case .enrollmentPending, .enrollmentDeferred: APNsText.t("设备登记尚未确认，保持 App 打开后重试。", "Device registration is pending. Keep the app open and try again.")
        case .foregroundRequired: APNsText.t("打开 App 后可完成设备登记。", "Open the app to finish device registration.")
        case .attestationUnavailable: APNsText.t("此安装暂不能完成设备验证。", "Device verification is not available for this installation yet.")
        case .rateLimited: APNsText.t("服务暂时繁忙，请稍后重试。", "The service is busy. Try again later.")
        case .remote(.tokenNeedsRenewal): APNsText.t("设备登记需要更新，正在等待系统确认。", "Device registration needs updating. Waiting for system confirmation.")
        case .remote(.invalidAppProof), .remote(.channelProofMismatch), .remote(.unsupportedInstallChannel):
            APNsText.t("此安装暂不能连接推送服务。", "This installation cannot connect to the push service yet.")
        case .remote: APNsText.t("未能确认服务登记，请重试。", "Service registration could not be confirmed. Try again.")
        case .http, .unavailable: APNsText.t("暂时无法连接，请稍后重试。", "Unable to connect. Try again later.")
        }
    }
    var retryable: Bool {
        switch self { case .unavailable: true; case .http(let status): status == 408 || status == 429 || status >= 500; default: false }
    }
}
#endif
