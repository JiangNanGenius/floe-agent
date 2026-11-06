// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import UIKit
import UserNotifications
import CryptoKit
import FloeTools

@MainActor final class APNsCenter: ObservableObject {
    typealias Eligibility = @MainActor @Sendable () async throws -> APNsEligibilitySnapshot
    typealias Wake = @MainActor @Sendable (APNsWakeRequest) async -> APNsWakeOutcome

    @Published private(set) var preferences = APNsPreferences()
    @Published private(set) var visibleAuthorization: APNsVisibleAuthorization = .unknown
    @Published private(set) var backgroundRefreshAvailable = false
    @Published private(set) var eligibilitySnapshot: APNsEligibilitySnapshot?
    @Published private(set) var channel: APNsInstallChannel = .unknown
    @Published private(set) var syncState = "off"
    @Published private(set) var failure: String?
    @Published var presentedRelease: APNsReleaseRecord?
    private(set) var state = APNsPersistentState()
    private let store: APNsStateStore?
    private let vault = APNsCredentialVault()
    private let eligibility: Eligibility
    private let performWake: Wake
    private let transport: (any APNsEnrollmentTransport)?
    private let releaseLookup: (any APNsReleaseResolving)?
    let signingEnvironment: APNsSigningEnvironment
    let testFlightURL: URL?
    let appStoreURL: URL?
    private var storageReady = false
    private var token: Data?
    private var syncTask: Task<Void, Never>?
    private var syncGeneration = UUID()
    private var registrationEpoch: UInt64 = 0
    private var requestedRegistrationEpoch: UInt64?
    private var activeWake: ActiveWake?
    private struct ActiveWake {
        var id: UUID
        var eventID: UUID
        var revision: Int64
        var token: CancellationToken
        var continuation: CheckedContinuation<APNsWakeOutcome, Never>
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
    }

    init(store: APNsStateStore? = nil, signingEnvironment: APNsSigningEnvironment = .unknown,
         transport: (any APNsEnrollmentTransport)? = nil, releaseLookup: (any APNsReleaseResolving)? = nil,
         testFlightURL: URL? = nil, appStoreURL: URL? = nil,
         eligibility: @escaping Eligibility, performWake: @escaping Wake) {
        self.eligibility = eligibility; self.performWake = performWake
        self.transport = transport; self.releaseLookup = releaseLookup
        self.signingEnvironment = signingEnvironment
        self.testFlightURL = Self.appleURL(testFlightURL, host: "testflight.apple.com")
        self.appStoreURL = Self.appleURL(appStoreURL, host: "apps.apple.com")
        let location: APNsStateStore?
        do { location = try store ?? APNsStateStore() } catch { location = nil }
        self.store = location
        do {
            guard let location else { throw APNsServiceError.storage }
            state = try location.load(); preferences = state.preferences; storageReady = true
            syncState = preferences.enabled ? "pending" : "off"
        } catch { failure = APNsServiceError.storage.localizedDescription; syncState = "storageUnavailable" }
    }

    /// Native settings actions only. AI has a separate READ-ONLY tool.
    func setEnabled(_ value: Bool) async {
        guard storageReady, preferences.enabled != value else { return }
        if !value {
            registrationEpoch &+= 1; requestedRegistrationEpoch = nil
            UIApplication.shared.unregisterForRemoteNotifications()
            cancelWake(); presentedRelease = nil
        }
        var next = state
        do {
            next.preferences.enabled = value; try advance(&next.preferences)
            try persist(next)
            if value { registrationEpoch &+= 1 }
            await reconcile()
        } catch {
            // Storage failure never permits late payloads after an opt-out.
            // Retain the pending choice in memory for the next retry.
            if !value { state = next; preferences = next.preferences }
            report(APNsServiceError.storage)
        }
    }
    func setVersionReminders(_ value: Bool) async {
        guard storageReady, preferences.enabled, preferences.versionReminders != value else { return }
        do {
            var next = state; next.preferences.versionReminders = value; try advance(&next.preferences); try persist(next)
            // Denying visible notifications never turns off silent registration.
            if value {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                if settings.authorizationStatus == .notDetermined {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                }
            }
            await reconcile()
        } catch { report(error) }
    }
    func reload() async {
        if storageReady {
            if preferences.enabled { requestedRegistrationEpoch = nil }
            await reconcile(); return
        }
        do {
            guard let store else { throw APNsServiceError.storage }
            state = try store.load(); preferences = state.preferences; storageReady = true; failure = nil
            await reconcile()
        } catch { report(error) }
    }

    /// Start, foreground, scheduler/occurrence terminal and settings changes
    /// all converge here. A superseded callback can never publish old state.
    func reconcile() async {
        guard storageReady else { return }
        syncGeneration = UUID(); let generation = syncGeneration
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.syncGeneration == generation { self.syncTask = nil } }
            await self.synchronize(generation: generation)
        }
    }
    func didRegister(token value: Data) async {
        guard preferences.enabled, requestedRegistrationEpoch == registrationEpoch,
              (16...512).contains(value.count), storageReady else { return }
        do {
            try vault.saveToken(value, installationID: state.installationID)
            token = value
            await reconcile()
        } catch { report(error) }
    }
    func didFailRegistration(_ error: Error) {
        guard preferences.enabled, requestedRegistrationEpoch == registrationEpoch else { return }
        requestedRegistrationEpoch = nil
        // Never print a token, request body, credential or server response.
        failure = APNsText.t("设备尚未完成登记，请重试。", "Device registration is incomplete. Try again.")
        syncState = "deviceRegistrationFailed"
        _ = error
    }

    func receive(payload: APNsPayload, source: APNsDeliverySource) async -> APNsWakeOutcome {
        guard storageReady, preferences.enabled else { return .rejected }
        let deadline = Date().addingTimeInterval(20)
        do {
            try validate(payload, allowExpiredRelease: false)
            guard try claim("event/" + payload.eventID.uuidString, expiresAt: payload.expiresAt) else { return .noData }
            if payload.kind == .release {
                guard preferences.versionReminders, visibleAuthorization.allowed else { return .noData }
                // An alert tap/foreground route fetches its release notes.
                // A silent delivery never spends its finite wake on StoreKit.
                if source == .background { return .noData }
                try await resolveRelease(payload, explicitlyOpened: source == .notificationTap)
                return .newData
            }
            let revision = preferences.revision
            let snapshot = try await eligibility()
            guard !Task.isCancelled, Date() < deadline, preferences.enabled, preferences.revision == revision, snapshot.eligible,
                  Date().timeIntervalSince(snapshot.sampledAt) < 60, activeWake == nil else { return .noData }
            eligibilitySnapshot = snapshot
            return await runFiniteWake(payload, deadline: deadline)
        } catch { return .rejected }
    }
    func expireWake(eventID: UUID) {
        guard activeWake?.eventID == eventID else { return }
        cancelWake()
    }

    /// Explicit notification taps may inspect old release notes, but a
    /// payload never supplies a URL or opens an update store automatically.
    func openRelease(payload: APNsPayload) async {
        do {
            try validate(payload, allowExpiredRelease: true)
            guard payload.kind == .release else { return }
            try await resolveRelease(payload, explicitlyOpened: true)
        } catch { report(error) }
    }
    func status() -> APNsStatus {
        let accepted = state.receipt
        return .init(enabled: preferences.enabled, versionReminders: preferences.versionReminders,
            visibleAuthorization: visibleAuthorization, backgroundRefreshAvailable: backgroundRefreshAvailable,
            hasEligibleWork: eligibilitySnapshot?.eligible, deviceRegistered: token != nil,
            serverConnected: preferences.enabled && accepted?.acceptedRevision == preferences.revision
                && accepted?.enabled == true && (accepted?.leaseExpiresAt ?? .distantPast) > Date(),
            channel: channel, lastServerAcceptedAt: accepted?.acceptedAt,
            lastReceivedAt: state.lastReceivedAt, lastWakeOutcome: state.lastWakeOutcome, syncState: syncState)
    }

    private func synchronize(generation: UUID) async {
        do {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard current(generation) else { return }
            visibleAuthorization = Self.authorization(settings.authorizationStatus)
            backgroundRefreshAvailable = UIApplication.shared.backgroundRefreshStatus == .available
            if preferences.enabled {
                if token == nil { token = try vault.token(installationID: state.installationID) }
                if requestedRegistrationEpoch == nil {
                    requestedRegistrationEpoch = registrationEpoch
                    // This is intentionally independent from alert permission.
                    UIApplication.shared.registerForRemoteNotifications()
                }
                let snapshot = try await eligibility()
                guard current(generation) else { return }
                eligibilitySnapshot = snapshot
                if channel == .unknown { channel = await APNsInstallChannelDetector.detect() }
                guard current(generation) else { return }
            }
            guard let transport else { syncState = preferences.enabled ? "unconfigured" : "off"; return }
            if preferences.enabled && signingEnvironment == .unknown {
                syncState = "signingUnconfirmed"
                failure = APNsText.t("此安装的推送能力尚未确认。", "Push support for this installation is unconfirmed.")
                return
            }
            if preferences.enabled && token == nil { syncState = "waitingForDevice"; return }
            let secret = try vault.secret(installationID: state.installationID, create: preferences.enabled)
            guard let secret else { syncState = "off"; return }
            var request = APNsRegistrationRequest(installationID: state.installationID, revision: preferences.revision,
                enabled: preferences.enabled, versionReminders: preferences.versionReminders,
                hasEligibleSchedules: preferences.enabled && (eligibilitySnapshot?.eligible ?? false),
                visibleAuthorization: visibleAuthorization, backgroundRefreshAvailable: backgroundRefreshAvailable,
                installed: .current(channel: channel), signingEnvironment: signingEnvironment,
                deviceToken: token.map { $0.map { String(format: "%02x", $0) }.joined() })
            // The same revision always names the same state. A changed task
            // qualification, token, channel or permission advances it first.
            var fingerprintRequest = request; fingerprintRequest.revision = 0
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let fingerprint = SHA256.hash(data: try encoder.encode(fingerprintRequest)).map { String(format: "%02x", $0) }.joined()
            if state.registrationFingerprint != fingerprint {
                var next = state; try advance(&next.preferences); next.registrationFingerprint = fingerprint; try persist(next)
                request.revision = preferences.revision
            }
            let revision = request.revision
            syncState = "connecting"; failure = nil
            for attempt in 0..<3 {
                guard current(generation), preferences.revision == revision else { return }
                do {
                    let receipt = try await transport.apply(request, installationSecret: secret)
                    guard current(generation), preferences.revision == revision else { return }
                    guard receipt.installationID == state.installationID, receipt.acceptedRevision == revision,
                          receipt.enabled == preferences.enabled, receipt.leaseExpiresAt > Date(),
                          abs(receipt.acceptedAt.timeIntervalSinceNow) <= 300 else { throw APNsServiceError.protocolViolation }
                    var next = state; next.receipt = receipt; try persist(next)
                    syncState = preferences.enabled ? "connected" : "off"; failure = nil
                    return
                } catch {
                    guard current(generation) else { return }
                    let problem = error as? APNsServiceError ?? .unavailable
                    if attempt == 2 || !problem.retryable { report(problem); return }
                    syncState = "retrying"
                    try await Task.sleep(for: .seconds(attempt == 0 ? 2 : 8))
                }
            }
        } catch { if current(generation) { report(error) } }
    }

    private func runFiniteWake(_ payload: APNsPayload, deadline: Date) async -> APNsWakeOutcome {
        let id = UUID(), cancellation = CancellationToken()
        let request = APNsWakeRequest(eventID: payload.eventID, receivedAt: Date(),
            deadline: deadline, cancellation: cancellation)
        return await withCheckedContinuation { continuation in
            activeWake = .init(id: id, eventID: payload.eventID, revision: preferences.revision, token: cancellation, continuation: continuation)
            activeWake?.work = Task { [weak self] in
                guard let self else { return }
                let result = await self.performWake(request)
                self.finishWake(id: id, result: result)
            }
            activeWake?.timer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) } catch { return }
                cancellation.cancel()
                self?.finishWake(id: id, result: .deferred)
            }
        }
    }
    private func finishWake(id: UUID, result: APNsWakeOutcome) {
        guard let wake = activeWake, wake.id == id else { return }
        activeWake = nil; wake.timer?.cancel()
        if result == .deferred || result == .rejected { wake.token.cancel(); wake.work?.cancel() }
        let final = preferences.enabled && preferences.revision == wake.revision ? result : .rejected
        var next = state; next.lastReceivedAt = Date(); next.lastWakeOutcome = final
        do { try persist(next) } catch { report(error) }
        wake.continuation.resume(returning: final)
        Task { await reconcile() }
    }
    private func cancelWake() {
        guard let wake = activeWake else { return }
        wake.token.cancel(); wake.work?.cancel(); finishWake(id: wake.id, result: .rejected)
    }
    private func resolveRelease(_ payload: APNsPayload, explicitlyOpened: Bool) async throws {
        guard let id = payload.releaseID, let targetChannel = payload.channel, let releaseLookup else { throw APNsServiceError.unconfigured }
        if channel == .unknown { channel = await APNsInstallChannelDetector.detect() }
        guard channel == targetChannel else { throw APNsServiceError.invalidPayload }
        let revision = preferences.revision
        let release = try await releaseLookup.release(id: id, channel: targetChannel)
        guard state.installationID == payload.installationID,
              explicitlyOpened || (preferences.enabled && preferences.versionReminders && preferences.revision == revision),
              release.id == id, release.channel == channel, release.isInstallable else { throw APNsServiceError.stalePayload }
        let current = APNsInstalledVersion.current(channel: channel)
        if !explicitlyOpened {
            guard !current.alreadyInstalled(release),
                  try claim("release/\(release.channel.rawValue)/\(release.build)", expiresAt: Date().addingTimeInterval(90 * 86_400)) else { return }
        }
        presentedRelease = release
    }
    private func validate(_ payload: APNsPayload, allowExpiredRelease: Bool) throws {
        guard payload.schemaVersion == 1, payload.installationID == state.installationID,
              payload.sentAt <= Date().addingTimeInterval(60),
              (allowExpiredRelease && payload.kind == .release) || (payload.expiresAt > Date()
                && payload.registrationRevision == preferences.revision) else { throw APNsServiceError.stalePayload }
    }
    private func claim(_ key: String, expiresAt: Date) throws -> Bool {
        var next = state; next.seen.removeAll { $0.expiresAt <= Date() }
        guard !next.seen.contains(where: { $0.key == key }) else { return false }
        next.seen.append(.init(key: key, expiresAt: expiresAt))
        if next.seen.count > 512 { next.seen.removeFirst(next.seen.count - 512) }
        next.lastReceivedAt = Date(); try persist(next)
        return true
    }
    private func persist(_ value: APNsPersistentState) throws {
        guard let store, storageReady else { throw APNsServiceError.storage }
        try store.save(value); state = value; preferences = value.preferences
    }
    private func advance(_ preferences: inout APNsPreferences) throws {
        guard preferences.revision < Int64.max else { throw APNsServiceError.storage }
        preferences.revision += 1
    }
    private func current(_ generation: UUID) -> Bool { generation == syncGeneration && !Task.isCancelled }
    private func report(_ error: Error) {
        failure = (error as? APNsServiceError ?? .unavailable).localizedDescription
        syncState = "failed"
    }
    private static func authorization(_ value: UNAuthorizationStatus) -> APNsVisibleAuthorization {
        switch value {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .unknown
        }
    }
    private static func appleURL(_ url: URL?, host: String) -> URL? {
        guard let url, url.scheme == "https", url.host?.lowercased() == host,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}
#endif
