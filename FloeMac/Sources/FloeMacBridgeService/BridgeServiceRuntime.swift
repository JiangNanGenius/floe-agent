// Floe Mac M00 — embedded Bridge service runtime.
//
// SPDX-License-Identifier: MPL-2.0
//
// One server, one persistent identity and one real data root. The runtime
// reports live job state over the authenticated control channel, forwards the
// complete ordered pairing-request snapshot to the host, refuses to stop while
// work is active and keeps running if the host UI disappears with active work.
// It never writes a synthetic pairing into real data.
//
// Shutdown is linearized: the same BridgeUpdateActivity reservation used by
// update installation atomically closes admission only when no request, job,
// transfer or consent lease exists. The reservation is retained through
// listener closure and process exit, so no check-then-stop window can admit
// new work after idle was observed.
//
// An owning connection may also hold that reservation across a host-side
// drain: reserve closes admission and returns an unguessable token bound to
// the authenticated connection; cancel releases it; commit transfers the very
// same installation reservation into shutdown without a release/reacquire
// gap. A lost or superseded connection releases the reservation, and a stale
// or foreign token can never commit, so a half-finished OTA can never stop
// the service under a new owner.

import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Dispatch
import Foundation
import FloeMacBridgeProtocol

struct BridgeReadyReport: Codable, Sendable {
    var schema: String
    var state: String
    var port: Int?
    var pid: Int32
    var parentPID: Int32
    var storageRoot: String
    var workerHome: String
    var controlSocket: String
    var identitySource: String
    var identityFingerprintSHA256: String?
    var version: String?
    var build: String?
    var bundleIdentifier: String?
    var bundlePath: String
    var listenerScope: String
    var orphaned: Bool
    var message: String?
    var timestamp: String
}

private final class PairingInstallBox: @unchecked Sendable {
    var snapshot: BridgeService.PairingSnapshot?
}

/// One authenticated update reservation. The wire token is generated here
/// (the activity installation token is never exposed); the installation is
/// the admission-closure token retained from reserve to commit, and
/// connectionID is the only connection allowed to cancel or commit.
private struct UpdateReservation: Sendable {
    let installation: BridgeUpdateActivity.Installation
    let connectionID: UUID
    let token: String
    let reservedAt: String
    let reason: String
}

final class BridgeServiceRuntime: @unchecked Sendable {
    enum ShutdownAdmission {
        case started
        case alreadyStopping
        case refused
    }

    let arguments: ServiceArguments
    let paths: BridgePaths
    let identity: ResolvedBridgeIdentity
    let service: BridgeService
    let httpServer: BridgeHTTPServer
    let controlServer: BridgeControlServer
    let controlToken: String
    let startedAt: String
    let workerHome: URL
    let signingInformation: SigningInformation?
    let storeLock: BridgeStoreLock
    let fixture: FixtureRoot?

    private let lock = NSLock()
    private let controlSocket: String
    private let readyFile: URL
    private let discoveryFile: URL
    private var state = "starting"
    private var message: String?
    private var pendingConsents: [BridgeControlConsent] = []
    private var pairingRevision: UInt64?
    private var orphaned = false
    private var shuttingDown = false
    private var ownerConnectionID: UUID?
    private var liveConnections: Set<UUID> = []
    // A displaced owner cannot use this same connection to seize ownership
    // again, even by obtaining a fresh challenge in a later generation.
    private var supersededConnections: Set<UUID> = []
    private var challengedConnections: [UUID: UInt64] = [:]
    private var ownerGeneration: UInt64 = 0
    // A lease spans the actual cross-actor mutation. A disconnect removes
    // authority immediately, but a replacement claim waits until the old
    // side effect has completed and released this lease.
    private var mutationLease: UUID?
    #if FLOE_IPC_TESTING
    private var controlTestHook: (@Sendable (String) async -> Void)?

    private func suspendForTesting(_ point: String) async {
        let hook = lock.withLock { controlTestHook }
        await hook?(point)
    }
    #endif
    private var shutdownReservation: BridgeUpdateActivity.Installation?
    private var updateReservation: UpdateReservation?
    private var failureShutdownPending = false
    private var lastStatus: BridgeControlStatus?
    private var orphanTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var watchdog: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private let permissions: (screenCapture: Bool, accessibility: Bool)
    private let parentPIDProvider: @Sendable () -> pid_t
    private let shutdownExit: @Sendable (Int32) -> Void

    init(arguments: ServiceArguments, identity: ResolvedBridgeIdentity, paths: BridgePaths,
         expectedPairStore: BridgeService.PairStoreIdentity? = nil,
         storeLock: BridgeStoreLock,
         fixture: FixtureRoot? = nil,
         httpPort: UInt16 = BridgeWire.port,
         parentPIDProvider: @escaping @Sendable () -> pid_t = { getppid() },
         shutdownExit: @escaping @Sendable (Int32) -> Void = { code in _exit(code) }) throws {
        guard let controlSocketArgument = arguments.controlSocket,
              let readyFileArgument = arguments.readyFile,
              let discoveryFileArgument = arguments.discoveryFile else {
            throw ServiceArgumentError.message("Control paths are required.")
        }
        let socketPath = controlSocketArgument.standardizedFileURL.path
        let token = BridgeControlCodec.randomToken()
        let service = try BridgeService(paths: paths, signingKey: identity.signingKey,
                                        expectedPairStore: expectedPairStore)
        self.arguments = arguments
        self.identity = identity
        self.paths = paths
        self.controlToken = token
        self.startedAt = ISO8601DateFormatter().string(from: Date())
        self.workerHome = fixture?.workerHome ?? FileManager.default.homeDirectoryForCurrentUser
        // Test mode must not trigger TCC prompts or inherit the developer
        // machine's screen capture/accessibility state.
        self.permissions = arguments.mode == .test ? (false, false) : BridgeIdentity.permissions()
        self.signingInformation = {
            if case .keychain(_, let signing) = identity { return signing }
            return nil
        }()
        self.controlSocket = socketPath
        self.readyFile = readyFileArgument.standardizedFileURL
        self.discoveryFile = discoveryFileArgument.standardizedFileURL
        self.service = service
        self.storeLock = storeLock
        self.fixture = fixture
        self.parentPIDProvider = parentPIDProvider
        self.shutdownExit = shutdownExit
        self.httpServer = try BridgeHTTPServer(service: service, port: httpPort)
        self.controlServer = BridgeControlServer(
            socketPath: socketPath,
            token: token,
            handler: { _, _ in BridgeControlMessage(kind: .reply, error: "The service is not ready.") }
        )
    }

    func start() throws {
        // Install the ordered snapshot observer before the HTTP listener can
        // receive a pairing request. The observer and the initial snapshot are
        // produced atomically by the actor, so no request can be missed.
        let install = PairingInstallBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { [service, weak self] in
            let snapshot = await service.setPairingObserver { [weak self] snapshot in
                self?.applyPairingSnapshot(snapshot)
            }
            install.snapshot = snapshot
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 2) == .success,
              let initial = install.snapshot else {
            throw ServiceArgumentError.message("The Bridge pairing observer could not be installed.")
        }
        applyPairingSnapshot(initial)
        controlServer.setAuthenticationHandler { [weak self] connectionID in
            self?.hostAuthenticated(connectionID)
        }
        controlServer.setDisconnectHandler { [weak self] connectionID in
            self?.hostDisconnected(connectionID)
        }
        try controlServer.start()
        try writeDiscovery()
        httpServer.start { [weak self] error in
            self?.listenerState(error)
        }
        startWatchdog()
        startSignalSources()
        statusTask = Task { [weak self] in
            await self?.statusLoop()
        }
    }

    private func listenerState(_ error: String?) {
        lock.withLock {
            if let error {
                state = "failed"
                message = error
                failureShutdownPending = true
            } else {
                state = "ready"
                message = nil
            }
        }
        writeReady()
        broadcastStatus()
        if error != nil {
            _ = beginShutdown(
                code: 1,
                delay: .milliseconds(400),
                reason: "The local Bridge listener failed; new work is not admitted."
            )
        }
    }

    private func startWatchdog() {
        guard let parentPID = arguments.parentPID, parentPID > 1 else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.watchdogTick(expectedParent: parentPID)
        }
        timer.resume()
        lock.withLock { watchdog = timer }
    }

    private func startSignalSources() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        for signalNumber in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: DispatchQueue.global(qos: .utility))
            source.setEventHandler { [weak self] in
                self?.signalReceived(signalNumber)
            }
            source.resume()
            lock.withLock { signalSources.append(source) }
        }
    }

    private func watchdogTick(expectedParent: pid_t) {
        // An explicit host claim owns the service. The original launching
        // parent may exit after a takeover; that must not start the grace
        // timer under the new owner.
        let claimed = lock.withLock { ownerConnectionID != nil && !shuttingDown }
        if claimed { return }
        let actualParent = parentPIDProvider()
        if actualParent == expectedParent {
            let wasOrphaned = lock.withLock { () -> Bool in
                guard orphaned else { return false }
                orphaned = false
                orphanTask?.cancel()
                orphanTask = nil
                return true
            }
            if wasOrphaned {
                writeReady()
                broadcastStatus()
            }
            return
        }
        let firstNotice = lock.withLock { () -> Bool in
            guard !orphaned, !shuttingDown, ownerConnectionID == nil else { return false }
            orphaned = true
            return true
        }
        if firstNotice {
            writeOrphanMarker(reason: "parent process \(expectedParent) disappeared; actual parent is \(actualParent)")
            writeReady()
            broadcastStatus()
        }
        scheduleOrphanEvaluation()
    }

    private func scheduleOrphanEvaluation() {
        let shouldStart = lock.withLock { () -> Bool in
            guard orphanTask == nil, !shuttingDown, ownerConnectionID == nil else { return false }
            return true
        }
        guard shouldStart else { return }
        let grace = arguments.orphanIdleGrace
        let task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(Int64(max(0, grace) * 1_000)))
            guard !Task.isCancelled else { return }
            let active = await self.service.jobs.activeTaskIDs()
            let activity = self.service.updateActivity.activityCount
            let stillOrphaned = self.lock.withLock {
                self.orphaned && !self.shuttingDown && self.ownerConnectionID == nil
            }
            self.lock.withLock {
                if self.orphanTask != nil { self.orphanTask = nil }
            }
            if stillOrphaned, active.isEmpty, activity == 0 {
                _ = self.beginShutdown(
                    code: 0,
                    delay: .milliseconds(100),
                    reason: "The owning host is gone; the Bridge service is stopping and new work is not admitted.",
                    requiresNoOwner: true
                )
            }
        }
        lock.withLock { orphanTask = task }
    }

    private func hostAuthenticated(_ connectionID: UUID) {
        // Authentication alone is not ownership. Status/probe connections may
        // read state; only an explicit verified claim below binds the service.
        lock.withLock { _ = liveConnections.insert(connectionID) }
    }

    private func hostDisconnected(_ connectionID: UUID) {
        var lostOwner = false
        var becameOrphan = false
        var releaseInstallation: BridgeUpdateActivity.Installation?
        lock.withLock {
            liveConnections.remove(connectionID)
            supersededConnections.remove(connectionID)
            challengedConnections.removeValue(forKey: connectionID)
            // A reservation is owned by its authenticated connection. When
            // that connection goes away, the pending/committed-but-unanswered
            // handoff dies with it; admission must reopen for the next owner.
            if let reservation = updateReservation, reservation.connectionID == connectionID {
                updateReservation = nil
                releaseInstallation = reservation.installation
            }
            guard ownerConnectionID == connectionID else { return }
            ownerConnectionID = nil
            lostOwner = true
            guard !shuttingDown, !orphaned,
                  arguments.parentPID != nil,
                  parentPIDProvider() != arguments.parentPID else { return }
            orphaned = true
            becameOrphan = true
        }
        // Release after dropping the runtime lock: while admission is still
        // closed, a racing new owner simply sees "busy", never a window where
        // its own reserve could be lost by this late resume.
        if let releaseInstallation {
            service.updateActivity.resume(after: releaseInstallation)
        }
        guard lostOwner else { return }
        if becameOrphan {
            writeOrphanMarker(reason: "the claiming host connection closed and the original parent is gone")
            writeReady()
            scheduleOrphanEvaluation()
        }
        broadcastStatus()
    }

    private func claimOwner(_ connectionID: UUID) -> Bool {
        var releasedInstallation: BridgeUpdateActivity.Installation?
        let claimed = lock.withLock { () -> Bool in
            guard !shuttingDown, mutationLease == nil,
                  liveConnections.contains(connectionID),
                  !supersededConnections.contains(connectionID),
                  controlServer.isConnectionActive(connectionID),
                  challengedConnections[connectionID] == ownerGeneration,
                  ownerGeneration < UInt64.max else { return false }
            if let previousOwner = ownerConnectionID, previousOwner != connectionID {
                supersededConnections.insert(previousOwner)
                // Ownership moved: the old owner's reservation is released so
                // its half-finished handoff can never commit under the new
                // owner. The new owner observes "no reservation" and may
                // start its own.
                if let reservation = updateReservation, reservation.connectionID == previousOwner {
                    updateReservation = nil
                    releasedInstallation = reservation.installation
                }
            }
            ownerConnectionID = connectionID
            ownerGeneration += 1
            challengedConnections.removeAll()
            orphaned = false
            orphanTask?.cancel()
            orphanTask = nil
            return true
        }
        if let releasedInstallation {
            service.updateActivity.resume(after: releasedInstallation)
        }
        if claimed {
            writeReady()
            broadcastStatus()
        }
        return claimed
    }

    private func acquireMutationLease(_ connectionID: UUID) -> UUID? {
        lock.withLock {
            guard !shuttingDown, liveConnections.contains(connectionID),
                  controlServer.isConnectionActive(connectionID),
                  ownerConnectionID == connectionID, mutationLease == nil else { return nil }
            let lease = UUID()
            mutationLease = lease
            return lease
        }
    }

    private func releaseMutationLease(_ lease: UUID) {
        lock.withLock { if mutationLease == lease { mutationLease = nil } }
    }

    private func applyPairingSnapshot(_ snapshot: BridgeService.PairingSnapshot) {
        let mapped = snapshot.pending.map {
            BridgeControlConsent(
                attemptID: $0.attemptID,
                clientID: $0.clientID,
                displayName: $0.displayName,
                verification: $0.verification,
                receivedAt: $0.receivedAt
            )
        }
        var changed = false
        lock.withLock {
            if let current = pairingRevision {
                guard snapshot.revision >= current else { return }
                if snapshot.revision == current && mapped == pendingConsents { return }
            }
            pairingRevision = snapshot.revision
            pendingConsents = mapped
            changed = true
        }
        guard changed else { return }
        let first = mapped.first
        controlServer.broadcast(BridgeControlEvent(
            kind: "consentListChanged",
            consent: first,
            consents: mapped,
            pairingRevision: snapshot.revision
        ))
        broadcastStatus()
    }

    private func signalReceived(_ signalNumber: Int32) {
        Task { [weak self] in
            guard let self else { return }
            let admission = self.beginShutdown(
                code: 0,
                delay: .milliseconds(150),
                reason: "The Bridge service is stopping; new work is not admitted."
            )
            if case .refused = admission {
                let text = "Signal \(signalNumber) was not allowed to end active Bridge work or an owned service."
                self.lock.withLock { self.message = text }
                self.writeOrphanMarker(reason: text)
                self.writeReady()
                self.broadcastStatus()
            }
        }
    }

    /// Atomic closure of new admission. The reservation token is stored and
    /// deliberately never released: the listener, control channel and process
    /// all close under the same fence.
    ///
    /// When `reservationToken` is supplied, the caller's existing reservation
    /// is committed: the same installation reservation moves into shutdown,
    /// so no release/reacquire window can admit work between reserve and
    /// commit. The token and its owning connection are re-verified here.
    private func beginShutdown(code: Int32, delay: Duration, reason: String,
                               requiresNoOwner: Bool = false,
                               expectedOwner: UUID? = nil,
                               reservationToken: String? = nil) -> ShutdownAdmission {
        var outcome = ShutdownAdmission.refused
        lock.withLock {
            if shuttingDown {
                outcome = .alreadyStopping
                return
            }
            guard mutationLease == nil else { return }
            // An orphan/signal attempt that raced a new authenticated claim
            // must not stop the service under its new owner. The check and
            // the reservation share this lock with claimOwner().
            if requiresNoOwner, ownerConnectionID != nil {
                return
            }
            // An explicit stop is bound to the connection that passed the
            // owner check. If another host claimed in between, its ownership
            // wins and this stop is refused.
            if let expectedOwner {
                // A socket can become inactive before its disconnect callback
                // acquires this lock. Ownership alone is not proof that the
                // request still has a live authenticated connection.
                guard ownerConnectionID == expectedOwner,
                      liveConnections.contains(expectedOwner),
                      controlServer.isConnectionActive(expectedOwner) else { return }
            }
            if let reservationToken {
                guard let reservation = updateReservation,
                      reservation.token == reservationToken,
                      reservation.connectionID == expectedOwner,
                      service.updateActivity.owns(reservation.installation) else {
                    return
                }
                // Transfer the same reservation; it is never released.
                shutdownReservation = reservation.installation
                updateReservation = nil
            } else {
                guard let token = service.reserveUpdateInstallationIfIdle(reason: reason) else {
                    return
                }
                shutdownReservation = token
            }
            shuttingDown = true
            failureShutdownPending = false
            state = "stopping"
            outcome = .started
        }
        guard case .started = outcome else { return outcome }
        writeReady()
        broadcastStatus()
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: delay)
            self.finishShutdown(code: code)
        }
        return outcome
    }

    private func finishShutdown(code: Int32) {
        lock.withLock {
            statusTask?.cancel()
            statusTask = nil
            orphanTask?.cancel()
            orphanTask = nil
            watchdog?.cancel()
            watchdog = nil
            for source in signalSources { source.cancel() }
            signalSources = []
        }
        httpServer.stop()
        controlServer.stop()
        removeDiscovery()
        writeReady()
        // The service owns no recoverable in-memory task state: every job is
        // persisted under Tasks. Exit with admission still closed and the
        // store lock retained until the kernel closes the process.
        usleep(150_000)
        shutdownExit(code)
    }

    private func statusLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            let shouldContinue = lock.withLock { !shuttingDown }
            guard shouldContinue else { return }
            if lock.withLock({ failureShutdownPending }) {
                _ = beginShutdown(
                    code: 1,
                    delay: .milliseconds(300),
                    reason: "The local Bridge listener failed; new work is not admitted."
                )
            }
            let status = await makeStatus()
            let changed = lock.withLock { lastStatus != status }
            if changed, lock.withLock({ !shuttingDown }) {
                lock.withLock { lastStatus = status }
                controlServer.broadcast(BridgeControlEvent(kind: "statusChanged", status: status))
            }
            if status.orphaned, status.activeTaskIDs.isEmpty, status.activityCount == 0,
               lock.withLock({ ownerConnectionID == nil && !shuttingDown }) {
                scheduleOrphanEvaluation()
            }
        }
    }

    private func broadcastStatus() {
        Task { [weak self] in
            guard let self else { return }
            let status = await self.makeStatus()
            self.lock.withLock { self.lastStatus = status }
            self.controlServer.broadcast(BridgeControlEvent(kind: "statusChanged", status: status))
        }
    }

    private func stopRefusalMessage(_ status: BridgeControlStatus) -> String {
        if !status.activeTaskIDs.isEmpty {
            return "Stop was refused: \(status.activeTaskIDs.count) Bridge task(s) are still running. The service continues."
        }
        return "Stop was refused: a Bridge request, transfer or pairing decision is still in progress. The service continues."
    }

    private func makeStatus() async -> BridgeControlStatus {
        let activeIDs = await service.jobs.activeTaskIDs()
        let active = activeIDs.sorted()
        let rawPairs = await service.pairedClients()
        let pairs = rawPairs
            .sorted { $0.1 < $1.1 }
            .map { BridgeControlPairedClient(clientID: $0.0, name: $0.1, verification: nil) }
        let capabilities = await service.advertisedCapabilities()
        let unknown = unknownTaskIDs().filter { !active.contains($0) }
        let snapshot = lock.withLock {
            (state: state, message: message, consents: pendingConsents,
             revision: pairingRevision ?? 0, orphaned: orphaned,
             claimed: ownerConnectionID != nil, permissions: permissions,
             reservation: updateReservation.map {
                 BridgeControlUpdateReservation(
                     token: $0.token, reservedAt: $0.reservedAt, reason: $0.reason)
             })
        }
        let bundle = Bundle.main
        let port: Int? = snapshot.state == "ready" ? httpServer.boundPort.map(Int.init) : nil
        return BridgeControlStatus(
            state: snapshot.state,
            port: port,
            pid: getpid(),
            parentPID: parentPIDProvider(),
            storageRoot: paths.root.path,
            workerHome: workerHome.path,
            controlSocket: controlSocket,
            identitySource: identity.source,
            identityPublicKeyBase64: identity.publicKey.base64EncodedString(),
            identityFingerprintSHA256: identity.fingerprintSHA256,
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            bundleIdentifier: bundle.bundleIdentifier,
            bundlePath: bundle.bundlePath,
            listenerScope: "127.0.0.1",
            activeTaskIDs: active,
            unknownTaskIDs: unknown,
            pairedClients: pairs,
            capabilities: capabilities,
            activityCount: service.updateActivity.activityCount,
            consent: snapshot.consents.first,
            pendingConsents: snapshot.consents,
            pairingRevision: snapshot.revision,
            hostClaimed: snapshot.claimed,
            storeLockPath: storeLock.url.path,
            storeLockExclusive: storeLock.isHeld,
            orphaned: snapshot.orphaned,
            startedAt: startedAt,
            screenCaptureAllowed: snapshot.permissions.screenCapture,
            accessibilityAllowed: snapshot.permissions.accessibility,
            message: snapshot.message,
            updateReservation: snapshot.reservation,
            admissionClosed: service.updateActivity.isAdmissionClosed
        )
    }

    private func unknownTaskIDs() -> [String] {
        let tasksRoot = paths.root.appendingPathComponent("Tasks", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tasksRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [String] = []
        for entry in entries {
            let id = entry.lastPathComponent
            guard BridgeWire.validID(id),
                  let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else {
                continue
            }
            let owner = entry.appendingPathComponent("owner.json", isDirectory: false)
            let receipt = entry.appendingPathComponent("result.json", isDirectory: false)
            if FileManager.default.fileExists(atPath: owner.path),
               !FileManager.default.fileExists(atPath: receipt.path) {
                result.append(id)
            }
        }
        return result.sorted()
    }

    private func writeReady() {
        if let fixture {
            do {
                try fixture.verifyPinned()
            } catch {
                FileHandle.standardError.write(Data(
                    ("Refusing to write a ready report after the fixture root changed: "
                        + error.localizedDescription + "\n").utf8
                ))
                return
            }
        }
        let snapshot = lock.withLock {
            (state, message, orphaned)
        }
        let report = BridgeReadyReport(
            schema: "floe-mac-bridge-ready-v2",
            state: snapshot.0,
            port: snapshot.0 == "ready" ? httpServer.boundPort.map(Int.init) : nil,
            pid: getpid(),
            parentPID: parentPIDProvider(),
            storageRoot: paths.root.path,
            workerHome: workerHome.path,
            controlSocket: controlSocket,
            identitySource: identity.source,
            identityFingerprintSHA256: identity.fingerprintSHA256,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            bundlePath: Bundle.main.bundlePath,
            listenerScope: "127.0.0.1",
            orphaned: snapshot.2,
            message: snapshot.1,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        do {
            try data.write(to: readyFile, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: readyFile.path)
        } catch {
            FileHandle.standardError.write(Data(("Ready report write failed: \(error)\n").utf8))
        }
    }

    private func writeDiscovery() throws {
        if let fixture {
            try fixture.verifyPinned()
        }
        let discovery = BridgeControlDiscovery(
            pid: getpid(),
            parentPID: parentPIDProvider(),
            socket: controlSocket,
            token: controlToken,
            storageRoot: paths.root.path,
            identityFingerprintSHA256: identity.fingerprintSHA256,
            identitySource: identity.source,
            startedAt: startedAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(discovery)
        try data.write(to: discoveryFile, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: discoveryFile.path)
    }

    private func removeDiscovery() {
        guard let data = try? Data(contentsOf: discoveryFile),
              let discovery = try? JSONDecoder().decode(BridgeControlDiscovery.self, from: data),
              discovery.pid == getpid(), discovery.token == controlToken else {
            return
        }
        try? FileManager.default.removeItem(at: discoveryFile)
    }

    private func writeOrphanMarker(reason: String) {
        let marker = URL(fileURLWithPath: controlSocket, isDirectory: false)
            .deletingLastPathComponent()
            .appendingPathComponent("orphaned.json", isDirectory: false)
        let payload: [String: Any] = [
            "schema": "floe-mac-bridge-orphan-v1",
            "pid": getpid(),
            "parentPID": parentPIDProvider(),
            "reason": reason,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]) else {
            return
        }
        try? data.write(to: marker, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }

    private func reply(_ message: BridgeControlMessage, error: String? = nil,
                       status: BridgeControlStatus? = nil) -> BridgeControlMessage {
        BridgeControlMessage(kind: .reply, replyTo: message.id, status: status, error: error)
    }

    private func handle(_ message: BridgeControlMessage, connectionID: UUID) async -> BridgeControlMessage {
        switch message.kind {
        case .status:
            return reply(message, status: await makeStatus())
        case .claim:
            #if FLOE_IPC_TESTING
            await suspendForTesting("claim")
            #endif
            guard claimOwner(connectionID) else {
                return reply(message, error: "Verify the helper identity again and retry when the Bridge is available.", status: await makeStatus())
            }
            return reply(message, status: await makeStatus())
        case .pairingDecision:
            guard let lease = acquireMutationLease(connectionID) else {
                return reply(message, error: "Only the host that currently owns this Bridge can decide a pairing request.", status: await makeStatus())
            }
            defer { releaseMutationLease(lease) }
            #if FLOE_IPC_TESTING
            await suspendForTesting("pairingLease")
            #endif
            guard let clientID = message.clientID,
                  let verification = message.verification,
                  let attemptID = message.attemptID, !attemptID.isEmpty,
                  let allow = message.allow else {
                return reply(message, error: "A pairing decision needs the current request, client, fingerprint and decision.")
            }
            let snapshot = await service.pairingSnapshot()
            guard let attempt = snapshot.pending.first(where: {
                $0.clientID == clientID && $0.verification == verification
                    && $0.attemptID == attemptID
            }) else {
                return reply(message,
                             error: "This pairing request is no longer current. Refresh and confirm the shown fingerprint.",
                             status: await makeStatus())
            }
            do {
                guard try await service.decide(attemptID: attempt.attemptID, verification: verification, allow: allow) else {
                    return reply(message,
                                 error: "This pairing request changed before the decision. Refresh and try again.",
                                 status: await makeStatus())
                }
            } catch {
                // A persistence failure leaves the pending request and its
                // consent lease intact; the host keeps showing the same code.
                return reply(message, error: error.localizedDescription, status: await makeStatus())
            }
            applyPairingSnapshot(await service.pairingSnapshot())
            let status = await makeStatus()
            controlServer.broadcast(BridgeControlEvent(kind: "consentResolved", status: status,
                                                       message: allow ? "approved" : "declined"))
            return reply(message, status: status)
        case .revoke:
            guard let lease = acquireMutationLease(connectionID) else {
                return reply(message, error: "Only the host that currently owns this Bridge can revoke a pairing.", status: await makeStatus())
            }
            defer { releaseMutationLease(lease) }
            #if FLOE_IPC_TESTING
            await suspendForTesting("revokeLease")
            #endif
            guard let clientID = message.clientID, BridgeWire.validID(clientID) else {
                return reply(message, error: "A client identifier is required.")
            }
            do {
                try await service.revoke(clientID)
            } catch {
                return reply(message, error: error.localizedDescription, status: await makeStatus())
            }
            applyPairingSnapshot(await service.pairingSnapshot())
            return reply(message, status: await makeStatus())
        case .challenge:
            guard let nonceText = message.nonce,
                  let nonce = Data(base64Encoded: nonceText), nonce.count == 32 else {
                return reply(message, error: "The identity challenge nonce must be base64-encoded 32 bytes.")
            }
            guard let generation = lock.withLock({ liveConnections.contains(connectionID) && !supersededConnections.contains(connectionID) && controlServer.isConnectionActive(connectionID) && !shuttingDown ? ownerGeneration : nil }) else {
                return reply(message, error: "The host connection is no longer active.")
            }
            #if FLOE_IPC_TESTING
            await suspendForTesting("challenge")
            #endif
            guard let signature = try? identity.signingKey.signature(
                for: BridgeControlCodec.identityChallenge(nonce)
            ) else {
                return reply(message, error: "The helper could not sign the identity challenge.")
            }
            let recorded = lock.withLock { () -> Bool in
                guard liveConnections.contains(connectionID), !supersededConnections.contains(connectionID), controlServer.isConnectionActive(connectionID), !shuttingDown, ownerGeneration == generation else { return false }
                challengedConnections[connectionID] = generation
                return true
            }
            guard recorded else { return reply(message, error: "The host connection or ownership changed.") }
            return BridgeControlMessage(
                kind: .reply,
                replyTo: message.id,
                publicKeyBase64: identity.publicKey.base64EncodedString(),
                signatureBase64: signature.base64EncodedString()
            )
        case .stop:
            guard isOwner(connectionID) else {
                return reply(message, error: "Only the host that currently owns this Bridge can stop it.", status: await makeStatus())
            }
            #if FLOE_IPC_TESTING
            await suspendForTesting("stopBeforeCommit")
            #endif
            // An explicit stop may commit the owner's own reservation: the
            // same installation reservation is transferred into shutdown.
            let heldToken = lock.withLock {
                updateReservation?.connectionID == connectionID ? updateReservation?.token : nil
            }
            let admission = beginShutdown(
                code: 0,
                delay: .milliseconds(400),
                reason: "The Bridge service is stopping; new work is not admitted.",
                expectedOwner: connectionID,
                reservationToken: heldToken
            )
            #if FLOE_IPC_TESTING
            await suspendForTesting("stopAfterCommit")
            #endif
            if case .refused = admission {
                guard isOwner(connectionID) else {
                    return reply(message,
                                 error: "Only the host that currently owns this Bridge can stop it.",
                                 status: await makeStatus())
                }
                let status = await makeStatus()
                return reply(message, error: stopRefusalMessage(status), status: status)
            }
            let status = await makeStatus()
            controlServer.broadcast(BridgeControlEvent(kind: "shutdownRequested", status: status,
                                                       message: message.reason ?? "explicit stop"))
            return reply(message, status: status)
        case .reserve:
            return await handleReserve(message, connectionID: connectionID)
        case .cancel:
            return await handleCancel(message, connectionID: connectionID)
        case .commit:
            return await handleCommit(message, connectionID: connectionID)
        case .hello, .event, .reply:
            return reply(message, error: "Unsupported control request.")
        }
    }

    /// Authenticated, idempotent reservation of update admission. Only the
    /// owning connection may reserve; a repeated reserve from the same owner
    /// returns the same token because a lost reply must never be read as "no
    /// reservation" (the service may already have closed admission).
    private func handleReserve(_ message: BridgeControlMessage, connectionID: UUID) async -> BridgeControlMessage {
        guard isOwner(connectionID) else {
            return reply(message, error: "Only the host that currently owns this Bridge can reserve an update.", status: await makeStatus())
        }
        guard let lease = acquireMutationLease(connectionID) else {
            return reply(message, error: "Only the host that currently owns this Bridge can reserve an update.", status: await makeStatus())
        }
        defer { releaseMutationLease(lease) }
        #if FLOE_IPC_TESTING
        await suspendForTesting("reserve")
        #endif
        let reason = message.reason ?? "Floe Bridge is installing an update. Reconnect shortly."
        enum ReserveResult: Sendable {
            case token(String)
            case busy
            case foreign
            case ownerLost
        }
        let result = lock.withLock { () -> ReserveResult in
            guard !shuttingDown else { return .busy }
            // The socket may have closed while an earlier await was in
            // flight. Without this check, disconnect could run before the
            // reservation exists and leave a dead owner's gate closed forever.
            guard mutationLease == lease, ownerConnectionID == connectionID,
                  liveConnections.contains(connectionID),
                  controlServer.isConnectionActive(connectionID) else { return .ownerLost }
            if let existing = updateReservation {
                return existing.connectionID == connectionID ? .token(existing.token) : .foreign
            }
            guard let installation = service.reserveUpdateInstallationIfIdle(reason: reason) else {
                return .busy
            }
            let token = UUID().uuidString
            updateReservation = UpdateReservation(
                installation: installation,
                connectionID: connectionID,
                token: token,
                reservedAt: ISO8601DateFormatter().string(from: Date()),
                reason: reason
            )
            return .token(token)
        }
        switch result {
        case .token(let token):
            #if FLOE_IPC_TESTING
            await suspendForTesting("reserveAfterAdmission")
            #endif
            let status = await makeStatus()
            controlServer.broadcast(BridgeControlEvent(kind: "updateReserved", status: status, message: reason))
            return BridgeControlMessage(kind: .reply, replyTo: message.id, token: token, status: status)
        case .busy:
            let status = await makeStatus()
            return reply(message, error: stopRefusalMessage(status), status: status)
        case .foreign:
            return reply(message, error: "Another host connection already holds the update reservation.", status: await makeStatus())
        case .ownerLost:
            return reply(message, error: "The owning host connection is no longer active.", status: await makeStatus())
        }
    }

    /// Release a reservation the caller owns. A stale or foreign token is
    /// refused; cancel never touches another connection's handoff.
    private func handleCancel(_ message: BridgeControlMessage, connectionID: UUID) async -> BridgeControlMessage {
        guard isOwner(connectionID) else {
            return reply(message, error: "Only the host that currently owns this Bridge can cancel an update reservation.", status: await makeStatus())
        }
        guard let token = message.token, !token.isEmpty else {
            return reply(message, error: "A reservation token is required to cancel.")
        }
        guard let lease = acquireMutationLease(connectionID) else {
            return reply(message, error: "Only the host that currently owns this Bridge can cancel an update reservation.", status: await makeStatus())
        }
        defer { releaseMutationLease(lease) }
        #if FLOE_IPC_TESTING
        await suspendForTesting("cancel")
        #endif
        let installation = lock.withLock { () -> BridgeUpdateActivity.Installation? in
            guard let reservation = updateReservation,
                  reservation.token == token,
                  reservation.connectionID == connectionID else { return nil }
            updateReservation = nil
            return reservation.installation
        }
        guard let installation else {
            return reply(message, error: "The update reservation is no longer current. Refresh and reserve again.", status: await makeStatus())
        }
        service.updateActivity.resume(after: installation)
        let status = await makeStatus()
        controlServer.broadcast(BridgeControlEvent(kind: "updateReservationCancelled", status: status))
        return reply(message, status: status)
    }

    /// Commit the caller's own reservation into shutdown. The same
    /// installation reservation is transferred; there is no release/reacquire
    /// gap between reserve and shutdown. A stale or foreign token can never
    /// commit, so a half-finished OTA cannot stop the service.
    private func handleCommit(_ message: BridgeControlMessage, connectionID: UUID) async -> BridgeControlMessage {
        guard isOwner(connectionID) else {
            return reply(message, error: "Only the host that currently owns this Bridge can commit an update reservation.", status: await makeStatus())
        }
        guard let token = message.token, !token.isEmpty else {
            return reply(message, error: "A reservation token is required to commit.")
        }
        #if FLOE_IPC_TESTING
        await suspendForTesting("commitBeforeCommit")
        #endif
        let admission = beginShutdown(
            code: 0,
            delay: .milliseconds(400),
            reason: "The Bridge service is stopping; new work is not admitted.",
            expectedOwner: connectionID,
            reservationToken: token
        )
        #if FLOE_IPC_TESTING
        await suspendForTesting("commitAfterCommit")
        #endif
        if case .refused = admission {
            guard isOwner(connectionID) else {
                return reply(message,
                             error: "Only the host that currently owns this Bridge can commit an update reservation.",
                             status: await makeStatus())
            }
            let status = await makeStatus()
            if status.updateReservation == nil {
                return reply(message,
                             error: "The update reservation is no longer current. Refresh and reserve again.",
                             status: status)
            }
            return reply(message, error: stopRefusalMessage(status), status: status)
        }
        let status = await makeStatus()
        controlServer.broadcast(BridgeControlEvent(kind: "updateCommitted", status: status,
                                                   message: message.reason ?? "reservation commit"))
        return reply(message, status: status)
    }

    private func isOwner(_ connectionID: UUID) -> Bool {
        lock.withLock { liveConnections.contains(connectionID) && controlServer.isConnectionActive(connectionID) && ownerConnectionID == connectionID && !shuttingDown }
    }
}

#if FLOE_IPC_TESTING
extension BridgeServiceRuntime {
    func setControlHookForTesting(_ hook: (@Sendable (String) async -> Void)?) {
        lock.withLock { controlTestHook = hook }
    }
    func setClosedBeforeCallbackHookForTesting(_ hook: (@Sendable (UUID) -> Void)?) {
        controlServer.setClosedBeforeCallbackHookForTesting(hook)
    }
    func closeConnectionForTesting(_ id: UUID) { controlServer.closeConnectionForTesting(id) }
    var ownerConnectionActiveForTesting: Bool {
        guard let owner = lock.withLock({ ownerConnectionID }) else { return false }
        return controlServer.isConnectionActive(owner)
    }
    var liveConnectionsForTesting: Int { lock.withLock { liveConnections.count } }
    var mutationInFlightForTesting: Bool { lock.withLock { mutationLease != nil } }
    func signalForTesting(_ signalNumber: Int32) { signalReceived(signalNumber) }
    func statusForTesting() async -> BridgeControlStatus { await makeStatus() }
    var pendingConsentsForTesting: [BridgeControlConsent] { lock.withLock { pendingConsents } }
    var ownerConnectionForTesting: UUID? { lock.withLock { ownerConnectionID } }
    var updateReservationTokenForTesting: String? { lock.withLock { updateReservation?.token } }
    var updateReservationConnectionForTesting: UUID? { lock.withLock { updateReservation?.connectionID } }
    /// The installation reservation currently held for a pending handoff.
    func reservationInstallationForTesting() -> BridgeUpdateActivity.Installation? {
        lock.withLock { updateReservation?.installation }
    }
    /// The installation reservation retained for shutdown after a commit.
    var shutdownInstallationForTesting: BridgeUpdateActivity.Installation? {
        lock.withLock { shutdownReservation }
    }
    func cancelTimersForTesting() {
        lock.withLock {
            statusTask?.cancel()
            statusTask = nil
            orphanTask?.cancel()
            orphanTask = nil
            watchdog?.cancel()
            watchdog = nil
            for source in signalSources { source.cancel() }
            signalSources = []
        }
        httpServer.stop()
        controlServer.stop()
    }
}
#endif

extension BridgeServiceRuntime {
    /// The control server is created before the runtime can capture self, so
    /// install the real handler immediately after initialization.
    func installControlHandler() {
        let handler: BridgeControlServer.Handler = { [weak self] message, connectionID in
            guard let self else {
                return BridgeControlMessage(kind: .reply, replyTo: message.id,
                                            error: "The embedded Bridge service is unavailable.")
            }
            return await self.handle(message, connectionID: connectionID)
        }
        controlServer.replaceHandler(handler)
    }
}
