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
    private let vault: any APNsCredentials
    private let platform: APNsPlatform
    private let eligibility: Eligibility
    private let performWake: Wake
    private let transport: (any APNsEnrollmentTransport)?
    private let releaseLookup: (any APNsReleaseResolving)?
    private let enrollment: (any APNsEnrollmentLifecycle)?
    let signingEnvironment: APNsSigningEnvironment
    let testFlightURL: URL?
    let appStoreURL: URL?
    private var storageReady = false
    private var token: Data?
    private var syncTask: Task<Void, Never>?
    private var syncGeneration = UUID()
    private var evidenceReconcilePending = false
    private var registrationEpoch: UInt64 = 0
    private var requestedRegistrationEpoch: UInt64?
    private var activeWake: ActiveWake?
    private var enrollmentJoin: EnrollmentJoin?
    private struct EnrollmentJoin {
        let id: UUID
        let eventID: UUID
        let generation: UUID
        let deadline: Date
        let continuation: CheckedContinuation<APNsEnrollmentDeliveryResult, Never>
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
    }
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
         credentials: any APNsCredentials = APNsCredentialVault(), platform: APNsPlatform = .live,
         enrollment: (any APNsEnrollmentLifecycle)? = nil,
         eligibility: @escaping Eligibility, performWake: @escaping Wake) {
        self.eligibility = eligibility; self.performWake = performWake
        self.vault = credentials; self.platform = platform
        self.enrollment = enrollment
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
            if preferences.enabled, let issue = state.registrationFailure {
                failure = issue.localizedDescription; syncState = issue.registrationState
            }
        } catch { failure = APNsServiceError.storage.localizedDescription; syncState = "storageUnavailable" }
        enrollment?.setEvidenceChangedHandler { [weak self] in
            guard let self, self.preferences.enabled, self.storageReady else { return }
            // Finish the current proof/receipt first. Cancelling it solely
            // because StoreKit finished would create an avoidable busy loop.
            self.evidenceReconcilePending = true
            self.reconcileVerifiedEvidenceIfReady()
        }
    }

    /// Native settings actions only. AI has a separate READ-ONLY tool.
    func setEnabled(_ value: Bool) async {
        guard storageReady, preferences.enabled != value else { return }
        if !value {
            evidenceReconcilePending = false
            if let join = enrollmentJoin { finishEnrollmentJoin(id: join.id, result: .pending, cancelExchange: false) }
            enrollment?.cancel()
            registrationEpoch &+= 1; requestedRegistrationEpoch = nil
            platform.unregister()
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
                let intentRevision = preferences.revision
                let authorization = await platform.authorization()
                guard !Task.isCancelled, preferences.enabled, preferences.versionReminders,
                      preferences.revision == intentRevision else { return }
                if authorization == .notDetermined {
                    try? await platform.requestVisibleAuthorization()
                    guard !Task.isCancelled, preferences.enabled, preferences.versionReminders,
                          preferences.revision == intentRevision else { return }
                }
            }
            await reconcile()
        } catch { report(error) }
    }
    func reload() async {
        if storageReady {
            if preferences.enabled { requestedRegistrationEpoch = nil }
            let work = startSynchronization()
            await work?.value
            return
        }
        do {
            guard let store else { throw APNsServiceError.storage }
            state = try store.load(); preferences = state.preferences; storageReady = true; failure = nil
            let work = startSynchronization()
            await work?.value
        } catch { report(error) }
    }

    /// Start, foreground, scheduler/occurrence terminal and settings changes
    /// all converge here. A superseded callback can never publish old state.
    func reconcile() async { _ = startSynchronization() }

    /// Synchronous MainActor start+capture: an explicit Retry waits for ITS
    /// finite task, never a later generation that replaced syncTask while an
    /// await was suspended. Ordinary reconcile remains process-owned.
    private func startSynchronization() -> Task<Void, Never>? {
        guard storageReady else { return nil }
        if platform.isForeground() { evidenceReconcilePending = false }
        syncGeneration = UUID(); let generation = syncGeneration
        syncTask?.cancel()
        let work = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.syncGeneration == generation {
                    self.syncTask = nil
                    self.reconcileVerifiedEvidenceIfReady()
                }
            }
            await self.synchronize(generation: generation)
        }
        syncTask = work
        return work
    }
    func didRegister(token value: Data) async {
        guard preferences.enabled, requestedRegistrationEpoch == registrationEpoch,
              (16...512).contains(value.count), storageReady else { return }
        do {
            try vault.saveToken(value, installationID: state.installationID)
            if state.tokenRenewalPending == true {
                var next = state
                // A real OS callback is required even when it returns the
                // same token. Preserve the installation and original secret.
                next.tokenRenewalPending = false
                try advance(&next.preferences)
                next.registrationFingerprint = nil
                try persist(next)
            }
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

    /// Enrollment is consumed independently and never starts work or records
    /// a delivery/result in the ordinary notification ledger.
    @discardableResult func receiveEnrollmentChallenge(_ challenge: APNsEnrollmentChallenge) -> Bool {
        guard preferences.enabled, storageReady, state.tokenRenewalPending != true else { return false }
        return enrollment?.receive(challenge) ?? false
    }
    func receiveEnrollmentChallenge(_ challenge: APNsEnrollmentChallenge, deadline: Date) async -> APNsEnrollmentDeliveryResult {
        guard !Task.isCancelled, deadline > Date(), deadline.timeIntervalSinceNow <= 20,
              preferences.enabled, storageReady, state.tokenRenewalPending != true,
              enrollmentJoin == nil, let work = syncTask,
              enrollment?.receive(challenge, deliveryDeadline: deadline) == true else { return .ignored }
        let id = UUID(), generation = syncGeneration
        return await withTaskCancellationHandler {
            if Task.isCancelled {
                cancelEnrollmentSynchronization(generation: generation)
                return .pending
            }
            return await withCheckedContinuation { continuation in
                enrollmentJoin = .init(id: id, eventID: challenge.eventID, generation: generation, deadline: deadline, continuation: continuation)
                enrollmentJoin?.work = Task { [weak self] in
                    await work.value // Exact original complete + PUT owner.
                    guard let self else { return }
                    let registered = self.syncGeneration == generation && self.preferences.enabled && self.status().serverConnected
                    self.finishEnrollmentJoin(id: id, result: registered ? .registered : .pending, cancelExchange: false)
                }
                enrollmentJoin?.timer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) } catch { return }
                    self?.finishEnrollmentJoin(id: id, result: .pending, cancelExchange: true)
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finishEnrollmentJoin(id: id, result: .pending, cancelExchange: true) } }
    }
    func expireEnrollmentDelivery(eventID: UUID) {
        guard let join = enrollmentJoin, join.eventID == eventID else { return }
        finishEnrollmentJoin(id: join.id, result: .pending, cancelExchange: true)
    }
    private func finishEnrollmentJoin(id: UUID, result: APNsEnrollmentDeliveryResult, cancelExchange: Bool) {
        guard let join = enrollmentJoin, join.id == id else { return }
        enrollmentJoin = nil; join.timer?.cancel(); join.work?.cancel()
        if cancelExchange { cancelEnrollmentSynchronization(generation: join.generation) }
        join.continuation.resume(returning: result)
        reconcileVerifiedEvidenceIfReady()
    }
    private func reconcileVerifiedEvidenceIfReady() {
        guard evidenceReconcilePending, preferences.enabled, platform.isForeground(),
              syncTask == nil, enrollmentJoin == nil else { return }
        evidenceReconcilePending = false
        Task { [weak self] in await self?.reconcile() }
    }
    private func cancelEnrollmentSynchronization(generation: UUID) {
        guard syncGeneration == generation else { return }
        if let retryAt = enrollment?.retryAfterInterruption {
            var next = state; next.nextRegistrationAttemptAt = retryAt
            next.registrationFailure = .foregroundRequired
            do { try persist(next) } catch { report(error) }
        }
        syncGeneration = UUID(); syncTask?.cancel(); enrollment?.cancel()
        syncState = "pending"
    }
    func applicationStateChanged(isForeground: Bool) {
        guard !isForeground, enrollment?.hasActiveExchange == true || enrollmentJoin != nil
                || (enrollment?.retryAfterInterruption != nil && syncTask != nil) else { return }
        // A real matched background delivery keeps only its original bounded
        // complete/PUT join. Otherwise preserve solely the inert target wait;
        // no background instance proof, new key or unowned HTTP continuation.
        if let join = enrollmentJoin, join.deadline > Date() { return }
        if enrollmentJoin == nil, enrollment?.canAwaitTargetInBackground == true {
            syncState = "pending"
            return
        }
        if let join = enrollmentJoin {
            finishEnrollmentJoin(id: join.id, result: .pending, cancelExchange: true)
        } else {
            if let retryAt = enrollment?.retryAfterInterruption {
                var next = state; next.nextRegistrationAttemptAt = retryAt
                next.registrationFailure = .foregroundRequired
                do { try persist(next) } catch { report(error) }
            }
            syncGeneration = UUID(); syncTask?.cancel(); enrollment?.cancel()
        }
        if preferences.enabled { syncState = "pending" }
    }

    func receive(payload: APNsPayload, source: APNsDeliverySource) async -> APNsWakeOutcome {
        guard storageReady, preferences.enabled, state.tokenRenewalPending != true else { return .rejected }
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
            serverConnected: preferences.enabled && state.tokenRenewalPending != true
                && accepted?.acceptedRevision == preferences.revision
                && accepted?.enabled == true && (accepted?.leaseExpiresAt ?? .distantPast) > Date(),
            channel: channel, lastServerAcceptedAt: accepted?.acceptedAt,
            nextRegistrationAttemptAt: state.nextRegistrationAttemptAt,
            lastReceivedAt: state.lastReceivedAt, lastWakeOutcome: state.lastWakeOutcome, syncState: syncState)
    }

    private func synchronize(generation: UUID) async {
        do {
            if let retryAt = state.nextRegistrationAttemptAt, retryAt > Date() {
                // A date is not proof of HTTP 429. Legacy date-only records
                // and ordinary enrollment waits must never fabricate busy.
                let issue = state.registrationFailure ?? .enrollmentDeferred(until: retryAt)
                syncState = issue.registrationState
                failure = issue.localizedDescription
                return
            }
            let authorization = await platform.authorization()
            guard current(generation) else { return }
            visibleAuthorization = authorization
            backgroundRefreshAvailable = platform.backgroundRefreshAvailable()
            if preferences.enabled {
                if token == nil && state.tokenRenewalPending != true {
                    token = try vault.token(installationID: state.installationID)
                }
                if requestedRegistrationEpoch == nil {
                    requestedRegistrationEpoch = registrationEpoch
                    // This is intentionally independent from alert permission.
                    platform.register()
                }
                let snapshot = try await eligibility()
                guard current(generation) else { return }
                eligibilitySnapshot = snapshot
                let detectionRevision = preferences.revision
                let detected = await platform.installChannel()
                guard current(generation), preferences.revision == detectionRevision else { return }
                // An unknown read cannot erase previously verified evidence.
                // A new known channel is applied through the normal revision.
                if detected != .unknown || channel == .unknown { channel = detected }
                guard current(generation) else { return }
            }
            guard let transport else { syncState = preferences.enabled ? "unconfigured" : "off"; return }
            if preferences.enabled && signingEnvironment == .unknown {
                syncState = "signingUnconfirmed"
                failure = APNsText.t("此安装的推送能力尚未确认。", "Push support for this installation is unconfirmed.")
                return
            }
            if preferences.enabled && (token == nil || state.tokenRenewalPending == true) {
                syncState = "waitingForDevice"
                return
            }
            let secret = try vault.secret(installationID: state.installationID, create: preferences.enabled)
            guard let secret else { syncState = "off"; return }
            var request = APNsRegistrationRequest(installationID: state.installationID, revision: preferences.revision,
                enabled: preferences.enabled, versionReminders: preferences.versionReminders,
                hasEligibleSchedules: preferences.enabled && (eligibilitySnapshot?.eligible ?? false),
                visibleAuthorization: visibleAuthorization, backgroundRefreshAvailable: backgroundRefreshAvailable,
                installed: .current(channel: channel), signingEnvironment: signingEnvironment,
                deviceToken: preferences.enabled ? token.map { $0.map { String(format: "%02x", $0) }.joined() } : nil)
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
                    // Timer scheduling is not the authority: a late response
                    // must fail the actual delivery deadline before persisting
                    // even if its timer has not yet run on the main actor.
                    if let join = enrollmentJoin, join.generation == generation, Date() >= join.deadline {
                        finishEnrollmentJoin(id: join.id, result: .pending, cancelExchange: true)
                        return
                    }
                    if !platform.isForeground(), enrollment?.retryAfterInterruption != nil,
                       enrollmentJoin?.generation != generation {
                        cancelEnrollmentSynchronization(generation: generation)
                        return
                    }
                    guard receipt.installationID == state.installationID, receipt.acceptedRevision == revision,
                          receipt.enabled == preferences.enabled, receipt.leaseExpiresAt > Date(),
                          abs(receipt.acceptedAt.timeIntervalSinceNow) <= 300 else { throw APNsServiceError.protocolViolation }
                    var next = state; next.receipt = receipt; next.nextRegistrationAttemptAt = nil
                    next.registrationFailure = nil; try persist(next)
                    enrollment?.registrationDidCommit()
                    syncState = preferences.enabled ? "connected" : "off"; failure = nil
                    return
                } catch {
                    guard current(generation) else { return }
                    guard preferences.revision == revision else {
                        // A newer settings intent may be awaiting its system
                        // permission query before starting a new generation.
                        // This old request cannot renew/clear the newer token.
                        syncState = "pending"
                        return
                    }
                    let problem = error as? APNsServiceError ?? .unavailable
                    if case .enrollmentDeferred(let retryAt) = problem {
                        var next = state; next.nextRegistrationAttemptAt = retryAt
                        next.registrationFailure = problem; try persist(next)
                        failure = problem.localizedDescription; syncState = problem.registrationState
                        return
                    }
                    if case .rateLimited(let retryAt) = problem {
                        var next = state; next.nextRegistrationAttemptAt = retryAt
                        next.registrationFailure = problem; try persist(next)
                        failure = problem.localizedDescription; syncState = problem.registrationState
                        return
                    }
                    if case .remote(.tokenNeedsRenewal) = problem {
                        // No generic 409 takes this path. A new OS callback
                        // must arrive before the old token can be submitted
                        // under a fresh revision, even if its bytes match.
                        try beginTokenRenewal(generation: generation)
                        return
                    }
                    if let retryAt = enrollment?.retryAfterInterruption, retryAt > Date() {
                        var next = state; next.nextRegistrationAttemptAt = retryAt
                        next.registrationFailure = problem; try persist(next)
                        failure = problem.localizedDescription; syncState = problem.registrationState
                        return
                    }
                    if case .enrollmentPending = problem { reportRegistration(problem); return }
                    if case .foregroundRequired = problem { reportRegistration(problem); return }
                    if attempt == 2 || !problem.retryable { reportRegistration(problem); return }
                    syncState = "retrying"
                    try await Task.sleep(for: .seconds(attempt == 0 ? 2 : 8))
                }
            }
        } catch { if current(generation) { reportRegistration(error) } }
    }

    private func beginTokenRenewal(generation: UUID) throws {
        guard current(generation), preferences.enabled else { return }
        var next = state
        next.tokenRenewalPending = true
        try persist(next)
        token = nil
        registrationEpoch &+= 1
        requestedRegistrationEpoch = registrationEpoch
        syncState = "waitingForDevice"
        failure = APNsServiceError.remote(.tokenNeedsRenewal).localizedDescription
        platform.register()
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
        if channel == .unknown {
            let detectionGeneration = syncGeneration, detectionRevision = preferences.revision
            let detected = await platform.installChannel()
            guard !Task.isCancelled, state.installationID == payload.installationID else { throw APNsServiceError.stalePayload }
            // A concurrent, newer enrollment may have learned the channel
            // while this route was suspended. Never overwrite its evidence.
            if channel == .unknown {
                guard detectionGeneration == syncGeneration, detectionRevision == preferences.revision else {
                    throw APNsServiceError.stalePayload
                }
                channel = detected
            }
        }
        guard channel == targetChannel else { throw APNsServiceError.invalidPayload }
        let revision = preferences.revision
        let release: APNsReleaseRecord
        do { release = try await releaseLookup.release(id: id, channel: targetChannel) }
        catch APNsServiceError.http(404) {
            guard explicitlyOpened, let history = releaseLookup as? any APNsReleaseHistoryResolving else {
                throw APNsServiceError.http(404)
            }
            // Only explicit old-notification taps may inspect formerly
            // public notes. Automatic receive never falls back to history.
            release = try await history.releaseHistory(id: id, channel: targetChannel)
        }
        guard state.installationID == payload.installationID,
              explicitlyOpened || (preferences.enabled && preferences.versionReminders && preferences.revision == revision),
              release.id == id, release.channel == channel,
              explicitlyOpened || release.isInstallable else { throw APNsServiceError.stalePayload }
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
    private func reportRegistration(_ error: Error) {
        let problem = error as? APNsServiceError ?? .unavailable
        var next = state; next.registrationFailure = problem
        do { try persist(next) }
        catch { report(APNsServiceError.storage); return }
        failure = problem.localizedDescription
        syncState = problem.registrationState
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
