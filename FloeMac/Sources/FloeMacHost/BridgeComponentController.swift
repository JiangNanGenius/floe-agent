// Floe Mac M00 — the one shared Bridge service used by both mode entries.
//
// SPDX-License-Identifier: MPL-2.0
//
// Agent mode and Bridge mode observe and control the same controller instance.
// Starting from either entry is idempotent: no second process and no second
// listener. The host never starts over or stops a Bridge it did not launch.
// Mode switching never restarts the service or migrates/reruns a task.
//
// Production uses the existing standalone Bridge Keychain identity and real
// data root. The explicit test fixture is the only path allowed to use a
// synthetic client and isolated storage.

import Combine
import CryptoKit
import Darwin
import Foundation

/// This value is bound to one authenticated control connection and cannot be
/// transferred to a replacement connection.
struct BridgeHostExitReservation: Sendable {
    let token: String
    let connection: BridgeControlClient
    let generation: UInt64
    let pinnedKey: Data
    let servicePID: Int32
}

enum BridgeHostExitPreparation: Sendable {
    case noService
    case reserved(BridgeHostExitReservation)
    case refused(String)
}
import FloeMacBridgeProtocol

struct BridgeReadyFile: Codable, Equatable, Sendable {
    var schema: String?
    var state: String
    var port: Int?
    var pid: Int32?
    var parentPID: Int32?
    var storageRoot: String?
    var workerHome: String?
    var controlSocket: String?
    var identitySource: String?
    var identityFingerprintSHA256: String?
    var version: String?
    var build: String?
    var bundleIdentifier: String?
    var bundlePath: String?
    var listenerScope: String?
    var orphaned: Bool?
    var message: String?
    var error: String?
    var timestamp: String?
}

@MainActor
final class BridgeComponentController: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case ready(BridgeControlStatus)
        case stopping
        case conflict(BridgeEndpointInventory)
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .ready, .starting, .stopping: true
            case .idle, .conflict, .failed: false
            }
        }

        var status: BridgeControlStatus? {
            if case .ready(let status) = self { return status }
            return nil
        }
    }

    enum LaunchOrigin: String, Sendable {
        case agent
        case bridge
        case probe
        case attached

        var label: String {
            switch self {
            case .agent: "Agent entry"
            case .bridge: "Bridge entry"
            case .probe: "Probe"
            case .attached: "Reattached"
            }
        }
    }

    static let fixedPort: UInt16 = 43871

    @Published private(set) var state: State = .idle
    @Published private(set) var launchOrigin: LaunchOrigin?
    @Published private(set) var logTail: String = ""
    @Published private(set) var lastProcessIdentifier: Int32?
    @Published private(set) var lastPing: String?
    @Published private(set) var isPinging = false
    @Published private(set) var stopBlockMessage: String?
    @Published private(set) var pendingConsents: [BridgeControlConsent] = []
    /// Compatibility accessor for probe/UI code that acts on the first
    /// request. New UI iterates `pendingConsents`.
    var pendingConsent: BridgeControlConsent? { pendingConsents.first }
    @Published private(set) var endpointInventory: BridgeEndpointInventory?
    @Published private(set) var identityPin: BridgeIdentityPin?
    @Published private(set) var identityError: String?
    @Published private(set) var lastStatusRefresh: Date?

    let dataRoot: URL
    let testFixture: URL?
    /// Test-only client identity. It never reaches real Bridge data.
    private(set) var probeClientKey = Curve25519.Signing.PrivateKey()

    private let helperOverride: URL?
    private var process: Process?
    private var ownsProcess = false
    private var logHandle: FileHandle?
    private var client: BridgeControlClient?
    private var generation: UInt64 = 0
    private var intentionalStop = false
    private var readinessTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var sessionPin: Data?
    private var pairingRevision: UInt64 = 0
    private var consecutiveControlFailures = 0
    private var hostTerminationFence = false
    private var hostExitRequestTimeout: TimeInterval = 6

    /// Closes all host-side start entrypoints, including views that use this
    /// shared controller directly. It does not reserve the remote service.
    func beginHostTerminationFence() -> Bool {
        guard !hostTerminationFence else { return false }
        hostTerminationFence = true
        return true
    }

    func cancelHostTerminationFence() { hostTerminationFence = false }

    init(dataRoot: URL = BridgeComponentController.defaultDataRoot,
         helperOverride: URL? = nil,
         testFixture: URL? = nil) {
        self.dataRoot = dataRoot.standardizedFileURL
        self.helperOverride = helperOverride
        self.testFixture = testFixture?.resolvingSymlinksInPath().standardizedFileURL
    }

    static var defaultDataRoot: URL {
        if let text = ProcessInfo.processInfo.environment["FLOE_MAC_BRIDGE_CONTROL_ROOT"], !text.isEmpty {
            return URL(fileURLWithPath: text, isDirectory: true)
        }
        return ModePreferenceStore.defaultRootURL
            .appendingPathComponent("BridgeControl", isDirectory: true)
    }

    static func isIsolated(_ root: URL) -> Bool {
        let realHome = UserBridgeGuard.realHomeDirectory.standardizedFileURL
        let userBridge = UserBridgeGuard.userBridgeRoot.standardizedFileURL
        let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        return path != "/" && path != realHome.path && path != userBridge.path
            && !path.hasPrefix(userBridge.path + "/")
            && !userBridge.path.hasPrefix(path + "/")
    }

    private var controlRoot: URL {
        if let testFixture {
            return testFixture.appendingPathComponent("Control", isDirectory: true)
        }
        return dataRoot
    }

    private var readyURL: URL { controlRoot.appendingPathComponent("ready.json", isDirectory: false) }
    private var discoveryURL: URL { controlRoot.appendingPathComponent("discovery.json", isDirectory: false) }
    private var socketURL: URL { controlRoot.appendingPathComponent("b.sock", isDirectory: false) }
    private var logURL: URL { controlRoot.appendingPathComponent("service.log", isDirectory: false) }

    func locateHelper() -> URL? {
        if let helperOverride {
            return FileManager.default.isExecutableFile(atPath: helperOverride.path) ? helperOverride : nil
        }
        if let text = ProcessInfo.processInfo.environment["FLOE_MAC_BRIDGE_SERVICE_PATH"], !text.isEmpty {
            let url = URL(fileURLWithPath: text, isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        let bundle = Bundle.main.bundleURL
        let candidates = [
            bundle.appendingPathComponent(
                "Contents/Helpers/FloeMacBridgeService.app/Contents/MacOS/FloeMacBridgeService",
                isDirectory: false
            ),
            bundle.deletingLastPathComponent().appendingPathComponent(
                "FloeMacBridgeService.app/Contents/MacOS/FloeMacBridgeService",
                isDirectory: false
            )
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Both Agent and Bridge entries call this. It is idempotent while this
    /// controller owns or is attached to a service.
    func start(origin: LaunchOrigin) {
        guard !hostTerminationFence, process == nil, !state.isRunning else { return }
        generation &+= 1
        let expected = generation
        stopBlockMessage = nil
        pendingConsents = []
        pairingRevision = 0
        lastPing = nil
        identityPin = nil
        sessionPin = nil
        identityError = nil
        state = .starting
        Task { [weak self] in
            await self?.beginStart(origin: origin, generation: expected)
        }
    }

    private func beginStart(origin: LaunchOrigin, generation expected: UInt64) async {
        guard expected == generation else { return }
        let endpoint = BridgeEndpointInspector.inspect()
        endpointInventory = endpoint
        if endpoint.listening {
            if await attachToExisting(endpoint: endpoint, origin: .attached, generation: expected) { return }
            guard expected == generation else { return }
            if hasAuthenticatedConnection { return }
            if identityError != nil { return }
            state = .conflict(endpoint)
            launchOrigin = nil
            return
        }

        do {
            try prepareControlRoot()
            if let stale = liveDiscovery() {
                if await attachToDiscovery(stale, endpoint: endpoint, origin: .attached, generation: expected) {
                    return
                }
                guard expected == generation else { return }
                if hasAuthenticatedConnection { return }
                state = .failed(
                    "A previous embedded Bridge process (PID \(stale.pid)) is still alive but its control channel is unavailable. It was not killed or replaced."
                )
                launchOrigin = nil
                return
            }
            try removeStaleControlFiles()
            if let testFixture {
                try prepareTestFixture(testFixture)
                probeClientKey = try loadOrCreateProbeClientKey(fixture: testFixture)
            }
        } catch {
            state = .failed(error.localizedDescription)
            launchOrigin = nil
            return
        }

        guard let helper = locateHelper() else {
            state = .failed("Embedded Bridge service is missing from the app bundle.")
            launchOrigin = nil
            return
        }
        guard isControlRootSafe() else {
            state = .failed("Refusing to use the real standalone Bridge data directory as the control root.")
            launchOrigin = nil
            return
        }

        let child = Process()
        child.executableURL = helper
        var arguments = [
            "--mode", testFixture == nil ? "production" : "test",
            "--control-socket", socketURL.path,
            "--ready-file", readyURL.path,
            "--discovery-file", discoveryURL.path,
            "--parent-pid", String(getpid())
        ]
        if let testFixture {
            arguments += ["--test-fixture", testFixture.path,
                          "--probe-client-key", probeClientKey.publicKey.rawRepresentation.base64EncodedString(),
                          "--orphan-idle-grace", "2"]
        } else {
            arguments.append("--create-identity-if-absent")
        }
        child.arguments = arguments
        child.currentDirectoryURL = controlRoot
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "FLOE_MAC_MODE_ROOT")
        environment.removeValue(forKey: "FLOE_MAC_MODE")
        if let testFixture {
            let workerHome = testFixture.appendingPathComponent("worker-home", isDirectory: true)
            environment["HOME"] = workerHome.path
            environment["CFFIXED_USER_HOME"] = workerHome.path
        }
        child.environment = environment

        closeLogHandle()
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            logHandle = handle
            child.standardOutput = handle
            child.standardError = handle
        }

        intentionalStop = false
        consecutiveControlFailures = 0
        sessionPin = nil
        identityError = nil
        child.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            let pid = terminated.processIdentifier
            Task { @MainActor [weak self] in
                self?.handleTermination(generation: expected, pid: pid, status: status)
            }
        }
        do {
            try child.run()
        } catch {
            closeLogHandle()
            state = .failed("Could not launch the embedded Bridge: \(error.localizedDescription)")
            launchOrigin = nil
            return
        }
        process = child
        ownsProcess = true
        lastProcessIdentifier = child.processIdentifier
        launchOrigin = origin
        state = .starting
        readinessTask?.cancel()
        readinessTask = Task { [weak self] in
            await self?.waitForReady(generation: expected, timeout: 15)
        }
    }

    private func waitForReady(generation expected: UInt64, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled || expected != generation { return }
            if hasAuthenticatedConnection { return }
            if let child = process, !child.isRunning {
                let ready = readReadyFile()
                let detail = ready?.message ?? ready?.error ?? readLogTail()
                state = .failed("Embedded Bridge exited before becoming ready. \(detail)")
                cleanupAfterFailure()
                return
            }
            if let discovery = readDiscovery(), let connection = await connect(discovery) {
                do {
                    let status = try await connection.request(BridgeControlMessage(kind: .status))
                    guard expected == generation, !hasAuthenticatedConnection else { connection.close(); return }
                    guard let value = status.status else {
                        connection.close()
                        throw BridgeControlFailure.remote("The service did not return status.")
                    }
                    if value.state == "ready" {
                        guard discovery.pid == value.pid, expected == generation else {
                            connection.close()
                            return
                        }
                        let verified: (Data, BridgeIdentityPin)
                        do {
                            verified = try await authenticate(connection, status: value, generation: expected)
                        } catch {
                            connection.close()
                            if expected == generation && !hasAuthenticatedConnection {
                                identityError = error.localizedDescription
                                state = .failed("Bridge identity verification failed: \(error.localizedDescription)")
                            }
                            return
                        }
                        guard expected == generation else { connection.close(); return }
                        let claimed: BridgeControlStatus
                        do {
                            claimed = try await claim(connection, generation: expected)
                        } catch {
                            connection.close()
                            if expected == generation && !hasAuthenticatedConnection {
                                identityError = error.localizedDescription
                                state = .failed("Bridge host claim failed: \(error.localizedDescription)")
                            }
                            return
                        }
                        guard expected == generation else { connection.close(); return }
                        guard install(connection: connection, origin: launchOrigin ?? .probe,
                                      generation: expected, verified: verified, status: claimed) else {
                            connection.close()
                            if hasAuthenticatedConnection { return }
                            throw BridgeControlFailure.notConnected
                        }
                        return
                    }
                    if value.state == "failed" {
                        connection.close()
                        state = .failed(value.message ?? "Embedded Bridge failed to start.")
                        cleanupAfterFailure()
                        return
                    }
                    connection.close()
                } catch {
                    connection.close()
                }
            }
            guard expected == generation, !hasAuthenticatedConnection else { return }
            if let ready = readReadyFile(), ready.state == "failed" {
                state = .failed(ready.message ?? ready.error ?? "Embedded Bridge failed to start.")
                cleanupAfterFailure()
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard expected == generation, !hasAuthenticatedConnection else { return }
        state = .failed("Timed out waiting for the embedded Bridge. \(readLogTail())")
        if client != nil {
            await stopAndWait(reason: "startup timeout")
        } else if readReadyFile()?.state == "ready" {
            stopBlockMessage = "The service reported ready but the authenticated control channel did not come up. It was left running rather than killed blindly."
        } else {
            terminateUnreadyProcess()
        }
    }

    private var hasAuthenticatedConnection: Bool {
        sessionPin != nil && client?.isConnected == true
    }

    // MainActor serializes competing installs; callbacks are registered under
    // the client's state lock before this connection is published as ready.
    private func install(connection: BridgeControlClient, origin: LaunchOrigin, generation expected: UInt64,
                         verified: (Data, BridgeIdentityPin), status: BridgeControlStatus) -> Bool {
        guard expected == generation, !hasAuthenticatedConnection else { return false }
        let connectionID = connection.identity
        guard connection.installCallbacks(onEvent: { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleEvent(event, generation: expected, connectionID: connectionID)
            }
        }, onDisconnect: { [weak self] reason in
            Task { @MainActor [weak self] in
                self?.handleControlDisconnect(generation: expected, connectionID: connectionID, reason: reason)
            }
        }) else { return false }
        client?.close()
        client = connection
        sessionPin = verified.0
        identityPin = verified.1
        identityError = nil
        launchOrigin = origin
        if status.state == "ready" { state = .ready(status) }
        else { state = .starting }
        applyConsents(status.pendingConsents, revision: status.pairingRevision, fallback: status.consent)
        lastStatusRefresh = Date()
        startStatusPolling(generation: expected)
        return true
    }

#if FLOE_IPC_TESTING
    func testInstall(_ candidate: BridgeControlClient, verified: (Data, BridgeIdentityPin),
                     status: BridgeControlStatus) -> Bool {
        install(connection: candidate, origin: .attached, generation: generation, verified: verified, status: status)
    }
    func testDeliverEvent(_ event: BridgeControlEvent, from connectionID: UUID) {
        handleEvent(event, generation: generation, connectionID: connectionID)
    }
    func testDeliverDisconnect(from connectionID: UUID) {
        handleControlDisconnect(generation: generation, connectionID: connectionID, reason: "fixture")
    }
    func testClaimAndInstall(_ candidate: BridgeControlClient, status: BridgeControlStatus) async -> Bool {
        do {
            let verified = try await authenticate(candidate, status: status, generation: generation)
            let claimed = try await claim(candidate, generation: generation)
            return install(connection: candidate, origin: .attached, generation: generation,
                           verified: verified, status: claimed)
        } catch {
            identityError = error.localizedDescription
            return false
        }
    }
    func testApplyStatus(_ status: BridgeControlStatus) { applyStatus(status) }
    var testConnectionID: UUID? { client?.identity }
    var testSessionPin: Data? { sessionPin }
    var testPendingConsents: [BridgeControlConsent] { pendingConsents }
    var testPairingRevision: UInt64 { pairingRevision }
    func setHostExitRequestTimeoutForTesting(_ timeout: TimeInterval) {
        hostExitRequestTimeout = timeout
    }
#endif

    private func startStatusPolling(generation expected: UInt64) {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, expected == self.generation else { return }
                await self.pollStatus(generation: expected)
            }
        }
    }

    private func pollStatus(generation expected: UInt64) async {
        guard expected == generation, sessionPin != nil, let client else { return }
        do {
            let reply = try await client.request(BridgeControlMessage(kind: .status), timeout: 4)
            guard expected == generation, self.client === client, sessionPin != nil else { return }
            guard let status = reply.status else { return }
            consecutiveControlFailures = 0
            lastStatusRefresh = Date()
            applyStatus(status)
        } catch {
            guard expected == generation, self.client === client, sessionPin != nil else { return }
            consecutiveControlFailures += 1
            if consecutiveControlFailures >= 3 {
                state = .failed("The embedded Bridge control channel stopped responding: \(error.localizedDescription)")
            }
        }
    }

    private func handleEvent(_ event: BridgeControlEvent, generation expected: UInt64, connectionID: UUID) {
        guard expected == generation, client?.identity == connectionID, hasAuthenticatedConnection else { return }
        switch event.kind {
        case "consentRequest", "consentListChanged":
            if let consents = event.consents, let revision = event.pairingRevision {
                applyConsents(consents, revision: revision, fallback: event.consent)
            } else if let consent = event.consent {
                // Older helper compatibility: an event without a revision is
                // accepted only while no ordered snapshot is in use.
                applyConsents([consent], revision: pairingRevision, fallback: nil)
            }
        case "consentResolved":
            if let status = event.status { applyStatus(status) }
        case "statusChanged":
            if let status = event.status { applyStatus(status) }
        case "shutdownRequested":
            state = .stopping
        default:
            break
        }
    }

    /// A status is the complete truth; only its consent list carries an
    /// independent monotonic revision. Out-of-order or duplicated events must
    /// not resurrect an old request.
    private func applyStatus(_ status: BridgeControlStatus) {
        applyConsents(status.pendingConsents, revision: status.pairingRevision, fallback: status.consent)
        switch status.state {
        case "ready":
            if case .ready(let existing) = state, existing == status { return }
            state = .ready(status)
        case "starting":
            if case .starting = state {} else { state = .starting }
        case "stopping":
            state = .stopping
        case "failed":
            state = .failed(status.message ?? "Embedded Bridge reported a failure.")
        default:
            break
        }
    }

    private func applyConsents(_ list: [BridgeControlConsent], revision: UInt64,
                               fallback: BridgeControlConsent?) {
        var effective = list
        var effectiveRevision = revision
        if effective.isEmpty, let fallback {
            effective = [fallback]
            effectiveRevision = 0
        }
        guard effectiveRevision >= pairingRevision else { return }
        if effectiveRevision == pairingRevision && effective == pendingConsents { return }
        pairingRevision = effectiveRevision
        pendingConsents = effective
    }

    private func handleControlDisconnect(generation expected: UInt64, connectionID: UUID, reason: String) {
        guard expected == generation, client?.identity == connectionID else { return }
        sessionPin = nil
        pendingConsents = []
        pairingRevision = 0
        guard !intentionalStop else { return }
        if let child = process, child.isRunning {
            state = .failed("The embedded Bridge control channel closed while the process is still running: \(reason)")
        } else if process == nil {
            state = .failed("The embedded Bridge control channel closed: \(reason)")
        }
    }

    private func handleTermination(generation expected: UInt64, pid: Int32, status: Int32) {
        guard expected == generation, process?.processIdentifier == pid else { return }
        process = nil
        ownsProcess = false
        readinessTask?.cancel()
        readinessTask = nil
        statusTask?.cancel()
        statusTask = nil
        client?.close()
        client = nil
        sessionPin = nil
        closeLogHandle()
        if intentionalStop {
            state = .idle
            launchOrigin = nil
            return
        }
        launchOrigin = nil
        if case .failed = state { return }
        let ready = readReadyFile()
        state = .failed("Embedded Bridge exited unexpectedly (status \(status)). \(ready?.message ?? readLogTail())")
    }

    private func attachToExisting(endpoint: BridgeEndpointInventory, origin: LaunchOrigin, generation expected: UInt64) async -> Bool {
        guard let discovery = readDiscovery() else { return false }
        return await attachToDiscovery(discovery, endpoint: endpoint, origin: origin, generation: expected)
    }

    private func attachToDiscovery(_ discovery: BridgeControlDiscovery, endpoint: BridgeEndpointInventory, origin: LaunchOrigin, generation expected: UInt64) async -> Bool {
        guard discovery.socket == socketURL.path,
              discovery.storageRoot.hasPrefix(ServicePathsForHost.realUserHome.path + "/")
                || testFixture != nil else {
            return false
        }
        guard let connection = await connect(discovery) else { return false }
        do {
            let reply = try await connection.request(BridgeControlMessage(kind: .status), timeout: 4)
            if expected == generation && hasAuthenticatedConnection { connection.close(); return true }
            guard let status = reply.status, status.pid == discovery.pid else {
                connection.close()
                return false
            }
            if status.state == "failed" || status.state == "stopping" {
                connection.close()
                return false
            }
            if let endpointPID = endpoint.pid, endpointPID != discovery.pid {
                connection.close()
                return false
            }
            guard expected == generation else { connection.close(); return false }
            let verified = try await authenticate(connection, status: status, generation: expected)
            guard expected == generation else { connection.close(); return false }
            let claimed = try await claim(connection, generation: expected)
            guard expected == generation else { connection.close(); return false }
            if !install(connection: connection, origin: origin, generation: expected, verified: verified, status: claimed) {
                connection.close()
                return expected == generation && hasAuthenticatedConnection
            }
            if process?.processIdentifier != discovery.pid {
                process = nil
                ownsProcess = false
            }
            lastProcessIdentifier = discovery.pid
            return true
        } catch {
            connection.close()
            if expected == generation && !hasAuthenticatedConnection {
                identityError = error.localizedDescription
                state = .failed("Bridge identity verification failed: \(error.localizedDescription)")
            }
            return expected == generation && hasAuthenticatedConnection
        }
    }

    private func connect(_ discovery: BridgeControlDiscovery) async -> BridgeControlClient? {
        do {
            return try await Task.detached(priority: .userInitiated) {
                try BridgeControlClient.connect(socketPath: discovery.socket, token: discovery.token)
            }.value
        } catch {
            return nil
        }
    }

    private func liveDiscovery() -> BridgeControlDiscovery? {
        guard let discovery = readDiscovery() else { return nil }
        guard discovery.pid > 1, kill(discovery.pid, 0) == 0 else { return nil }
        return discovery
    }

    private func readDiscovery() -> BridgeControlDiscovery? {
        guard let data = try? Data(contentsOf: discoveryURL) else { return nil }
        return try? JSONDecoder().decode(BridgeControlDiscovery.self, from: data)
    }

    private func readReadyFile() -> BridgeReadyFile? {
        guard let data = try? Data(contentsOf: readyURL) else { return nil }
        return try? JSONDecoder().decode(BridgeReadyFile.self, from: data)
    }

    func refreshStatus() async {
        let expected = generation
        let endpoint = BridgeEndpointInspector.inspect()
        endpointInventory = endpoint
        if sessionPin != nil, let client {
            do {
                let reply = try await client.request(BridgeControlMessage(kind: .status), timeout: 4)
                guard expected == generation, self.client === client, sessionPin != nil else { return }
                if let status = reply.status {
                    lastStatusRefresh = Date()
                    applyStatus(status)
                    logTail = readLogTail()
                    return
                }
            } catch {
                // fall through to a reconnect attempt below
                guard expected == generation, self.client === client else { return }
            }
        }
        guard expected == generation else { return }
        if let discovery = liveDiscovery() {
            generation &+= 1
            sessionPin = nil
            identityPin = nil
            identityError = nil
            pendingConsents = []
            pairingRevision = 0
            client?.close()
            client = nil
            state = .starting
            let current = generation
            if await attachToDiscovery(discovery, endpoint: endpoint, origin: .attached, generation: current) {
                logTail = readLogTail()
                return
            }
            guard current == generation else { return }
            if identityError != nil { return }
        }
        if endpoint.listening {
            state = .conflict(endpoint)
            launchOrigin = nil
        } else if process == nil {
            state = .idle
            launchOrigin = nil
        }
        logTail = readLogTail()
    }

    /// The pin is established from an authenticated control channel and a
    /// challenge signature. A later response must use the same key.
    private func authenticate(_ candidate: BridgeControlClient, status: BridgeControlStatus, generation expected: UInt64) async throws -> (Data, BridgeIdentityPin) {
            guard expected == generation else { throw BridgeControlFailure.notConnected }
            let nonce = makeNonce()
            let reply = try await candidate.request(
                BridgeControlMessage(kind: .challenge, nonce: nonce.base64EncodedString()),
                timeout: 4
            )
            guard let keyText = reply.publicKeyBase64, let keyData = Data(base64Encoded: keyText),
                  keyData.count == 32,
                  let signatureText = reply.signatureBase64,
                  let signature = Data(base64Encoded: signatureText) else {
                throw BridgeControlFailure.remote("The helper identity response was incomplete.")
            }
            if let sessionPin {
                guard keyData == sessionPin else {
                    throw BridgeControlFailure.remote("The helper identity does not match the key pinned for this session.")
                }
            }
            guard expected == generation else { throw BridgeControlFailure.notConnected }
            let pin = try BridgeIdentityPinStore.verifyChallenge(
                publicKey: keyData, signature: signature, nonce: nonce, status: status, at: controlRoot
            )
            return (keyData, pin)
    }

    /// Claim is explicit and follows the identity challenge on this exact
    /// connection. A status/probe connection that never claims cannot become
    /// the owner, and an old connection cannot keep ownership after handover.
    private func claim(_ candidate: BridgeControlClient, generation expected: UInt64) async throws -> BridgeControlStatus {
        let reply = try await candidate.request(BridgeControlMessage(kind: .claim), timeout: 4)
        guard expected == generation else { throw BridgeControlFailure.notConnected }
        guard let status = reply.status else {
            throw BridgeControlFailure.remote("The Bridge did not confirm host ownership.")
        }
        return status
    }

    private func makeNonce() -> Data {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }

    func performPing() async {
        guard state.status != nil, sessionPin != nil, let client else {
            lastPing = "Bridge is not ready."
            return
        }
        let expected = generation
        isPinging = true
        defer { isPinging = false }
        do {
            let nonce = makeNonce()
            let reply = try await client.request(
                BridgeControlMessage(kind: .challenge, nonce: nonce.base64EncodedString()),
                timeout: 4
            )
            guard let keyText = reply.publicKeyBase64, let keyData = Data(base64Encoded: keyText),
                  keyData.count == 32,
                  let signatureText = reply.signatureBase64,
                  let signature = Data(base64Encoded: signatureText) else {
                throw BridgeControlFailure.remote("The helper identity response was incomplete.")
            }
            guard expected == generation, self.client === client, sessionPin == keyData else {
                throw BridgeControlFailure.notConnected
            }
            guard let currentStatus = state.status else {
                throw BridgeControlFailure.remote("The Bridge stopped before its identity could be pinned.")
            }
            let pin = try BridgeIdentityPinStore.verifyChallenge(
                publicKey: keyData, signature: signature, nonce: nonce, status: currentStatus, at: controlRoot
            )
            sessionPin = keyData
            identityPin = pin
            identityError = nil
            if testFixture != nil {
                let body = BridgeRequestBody(
                    clientKey: probeClientKey.publicKey.rawRepresentation,
                    method: "ping",
                    payload: [:]
                )
                let request = try BridgeRequest(body: body, key: probeClientKey)
                let requestData = try BridgeWire.encode(request)
                guard let url = URL(string: "http://127.0.0.1:\(Self.fixedPort)/rpc") else {
                    throw BridgeControlFailure.remote("Invalid loopback endpoint.")
                }
                var urlRequest = URLRequest(url: url)
                urlRequest.httpMethod = "POST"
                urlRequest.timeoutInterval = 5
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                urlRequest.setValue("127.0.0.1:\(Self.fixedPort)", forHTTPHeaderField: "Host")
                urlRequest.httpBody = requestData
                let (responseData, response) = try await URLSession.shared.data(for: urlRequest)
                guard expected == generation, self.client === client, sessionPin == keyData else { return }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    lastPing = "Bridge rejected the signed ping (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))."
                    return
                }
                let decoded = try BridgeWire.decode(BridgeResponse.self, from: responseData)
                let result = try decoded.verified(for: request.body, pinnedKey: keyData)
                guard decoded.body.serverKey == keyData else {
                    throw BridgeControlFailure.remote("The RPC response used a different server key than the pinned helper identity.")
                }
                let capabilities = result["capabilities"]?.array?.compactMap(\.string) ?? []
                lastPing = "Signed RPC ping OK · pinned identity \(pin.fingerprintSHA256.prefix(12)) · \(capabilities.count) capabilities"
            } else {
                lastPing = "Helper identity verified · \(pin.fingerprintSHA256.prefix(12)) · RPC ping requires a paired client (not created in production M00)."
            }
        } catch {
            guard expected == generation, self.client === client else { return }
            lastPing = "Identity verification failed: \(error.localizedDescription)"
        }
    }

    func approveConsent() async {
        await decideConsent(allow: true, consent: pendingConsent)
    }

    func approveConsent(attemptID: String) async {
        await decideConsent(allow: true, consent: pendingConsents.first { $0.attemptID == attemptID })
    }

    func declineConsent() async {
        await decideConsent(allow: false, consent: pendingConsent)
    }

    func declineConsent(attemptID: String) async {
        await decideConsent(allow: false, consent: pendingConsents.first { $0.attemptID == attemptID })
    }

    /// Cancel is a decline, not a dismissed approval. It never authorizes a
    /// client and never clears another current request.
    func cancelConsent() async {
        await decideConsent(allow: false, consent: pendingConsent)
    }

    func cancelConsent(attemptID: String) async {
        await decideConsent(allow: false, consent: pendingConsents.first { $0.attemptID == attemptID })
    }

    private func decideConsent(allow: Bool, consent: BridgeControlConsent?) async {
        guard sessionPin != nil, let consent, let client else { return }
        let expected = generation
        do {
            let reply = try await client.request(BridgeControlMessage(
                kind: .pairingDecision,
                clientID: consent.clientID,
                attemptID: consent.attemptID.isEmpty ? nil : consent.attemptID,
                verification: consent.verification,
                allow: allow
            ), timeout: 6)
            guard expected == generation, self.client === client, sessionPin != nil else { return }
            if let status = reply.status { applyStatus(status) }
            if let error = reply.error { stopBlockMessage = error }
            // A stale decision leaves the snapshot untouched on the service;
            // refresh regardless so the UI shows the current exact request.
            await refreshStatus()
        } catch {
            guard expected == generation, self.client === client, sessionPin != nil else { return }
            stopBlockMessage = "The pairing decision could not be delivered: \(error.localizedDescription)"
        }
    }

    func revoke(clientID: String) async {
        guard sessionPin != nil, let client else { return }
        let expected = generation
        do {
            let reply = try await client.request(BridgeControlMessage(kind: .revoke, clientID: clientID), timeout: 6)
            guard expected == generation, self.client === client, sessionPin != nil else { return }
            if let error = reply.error { stopBlockMessage = error }
            if let status = reply.status { applyStatus(status) }
        } catch {
            guard expected == generation, self.client === client, sessionPin != nil else { return }
            stopBlockMessage = "The pairing could not be revoked: \(error.localizedDescription)"
        }
    }

    func liveStatus() async -> BridgeControlStatus? {
        let expected = generation
        if sessionPin != nil, let client, let reply = try? await client.request(BridgeControlMessage(kind: .status), timeout: 4) {
            guard expected == generation, self.client === client, sessionPin != nil else { return nil }
            if let status = reply.status {
                applyConsents(status.pendingConsents, revision: status.pairingRevision, fallback: status.consent)
                lastStatusRefresh = Date()
                return status
            }
        }
        return nil
    }

    var hasLiveServiceProcess: Bool {
        if let process { return process.isRunning }
        if client != nil { return true }
        return liveDiscovery() != nil
    }

    /// Atomically closes admission on the authenticated service. A missing or
    /// old control channel is a refusal, never an idle-status substitute.
    func reserveForHostExit() async -> BridgeHostExitPreparation {
        guard hostTerminationFence else { return .refused("The Bridge exit fence is not active.") }
        if !state.isRunning, !hasLiveServiceProcess { return .noService }
        guard let connection = client, let pin = sessionPin,
              let pid = state.status?.pid, pid > 1, connection.isConnected else {
            return .refused("The Bridge connection is not ready. It was left running.")
        }
        let expected = generation
        do {
            let reply = try await connection.request(
                BridgeControlMessage(kind: .reserve, reason: "Floe is preparing to quit."), timeout: hostExitRequestTimeout)
            guard expected == generation, self.client === connection, sessionPin == pin,
                  connection.isConnected, let token = reply.token, !token.isEmpty,
                  reply.status?.updateReservation?.token == token else {
                let released = await closeAndReconcileExit(connection: connection, pin: pin, pid: pid)
                return .refused(released ? "The Bridge reservation could not be confirmed. Reconnect and retry." :
                    "The Bridge reservation could not be confirmed or released. Check Bridge status before retrying.")
            }
            return .reserved(BridgeHostExitReservation(token: token, connection: connection,
                                                       generation: expected, pinnedKey: pin, servicePID: pid))
        } catch let BridgeControlFailure.remote(message) {
            // A rejected reserve is an explicit service reply. No UI has been
            // closed yet, and no legacy stop is attempted.
            return .refused(message)
        } catch {
            let released = await closeAndReconcileExit(connection: connection, pin: pin, pid: pid)
            return .refused(released ? "The Bridge did not confirm its reservation. Reconnect and retry." :
                "The Bridge reservation outcome is unknown. Check Bridge status before retrying.")
        }
    }

    /// Returns true only after the service acknowledges the matching cancel,
    /// or a fresh verified status confirms admission reopened after disconnect.
    func cancelHostExit(_ reservation: BridgeHostExitReservation) async -> Bool {
        guard exitReservationIsCurrent(reservation) else {
            return await closeAndReconcileExit(connection: reservation.connection,
                                               pin: reservation.pinnedKey, pid: reservation.servicePID)
        }
        do {
            let reply = try await reservation.connection.request(
                BridgeControlMessage(kind: .cancel, token: reservation.token), timeout: hostExitRequestTimeout)
            guard exitReservationIsCurrent(reservation), reply.status?.updateReservation == nil,
                  reply.status?.admissionClosed == false else {
                return await closeAndReconcileExit(connection: reservation.connection,
                                                   pin: reservation.pinnedKey, pid: reservation.servicePID)
            }
            return true
        } catch {
            return await closeAndReconcileExit(connection: reservation.connection,
                                               pin: reservation.pinnedKey, pid: reservation.servicePID)
        }
    }

    /// Commit keeps the service gate closed until the exact process exits.
    /// A timeout does not mean the request failed or authorize a second stop.
    func commitHostExit(_ reservation: BridgeHostExitReservation) async -> Bool {
        guard exitReservationIsCurrent(reservation) else {
            _ = await closeAndReconcileExit(connection: reservation.connection,
                                            pin: reservation.pinnedKey, pid: reservation.servicePID)
            return false
        }
        do {
            _ = try await reservation.connection.request(
                BridgeControlMessage(kind: .commit, token: reservation.token, reason: "application quit"), timeout: hostExitRequestTimeout)
            guard exitReservationIsCurrent(reservation) else {
                _ = await closeAndReconcileExit(connection: reservation.connection,
                                                pin: reservation.pinnedKey, pid: reservation.servicePID)
                if !Self.processExists(reservation.servicePID) {
                    return completeStoppedService(reservation.connection, pid: reservation.servicePID)
                }
                return false
            }
            intentionalStop = true
            generation &+= 1
            let stoppingGeneration = generation
            statusTask?.cancel()
            statusTask = nil
            state = .stopping
            let wait = Task { @MainActor in
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while ContinuousClock.now < deadline, Self.processExists(reservation.servicePID) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                return !Self.processExists(reservation.servicePID)
            }
            let stopped = await wait.value
            guard stopped else {
                intentionalStop = false
                state = .failed("Bridge shutdown was not confirmed. It was not force-killed.")
                return false
            }
            guard generation == stoppingGeneration else { return false }
            return completeStoppedService(reservation.connection, pid: reservation.servicePID)
        } catch {
            // The helper may have committed before its reply was lost. Do not
            // send a second commit or treat timeout as proof that it is idle.
            _ = await closeAndReconcileExit(connection: reservation.connection,
                                            pin: reservation.pinnedKey, pid: reservation.servicePID)
            if !Self.processExists(reservation.servicePID) {
                return completeStoppedService(reservation.connection, pid: reservation.servicePID)
            }
            return false
        }
    }

    private func completeStoppedService(_ connection: BridgeControlClient, pid: Int32) -> Bool {
        guard client == nil || client === connection,
              process == nil || process?.processIdentifier == pid else { return false }
        connection.close()
        if client === connection { client = nil; sessionPin = nil }
        process = nil
        ownsProcess = false
        launchOrigin = nil
        pendingConsents = []
        state = .idle
        closeLogHandle()
        return true
    }

    private func exitReservationIsCurrent(_ reservation: BridgeHostExitReservation) -> Bool {
        generation == reservation.generation && client === reservation.connection &&
            sessionPin == reservation.pinnedKey && reservation.connection.isConnected
    }

    private static func processExists(_ pid: Int32) -> Bool {
        guard pid > 1 else { return true }
        return kill(pid, 0) == 0 || errno != ESRCH
    }

    /// A lost response may hide an already-held reservation. Close its owning
    /// channel, then poll a separate challenge-verified status for the same
    /// service until the reservation and its admission gate are both gone.
    private func closeAndReconcileExit(connection: BridgeControlClient, pin: Data, pid: Int32) async -> Bool {
        // Reconciliation is cleanup and must continue even if the initiating
        // quit task has been cancelled.
        let reconciliation = Task { @MainActor [weak self] in
            guard let self else { connection.close(); return false }
            return await self.reconcileClosedExitConnection(connection: connection, pin: pin, pid: pid)
        }
        return await reconciliation.value
    }

    private func reconcileClosedExitConnection(connection: BridgeControlClient, pin: Data, pid: Int32) async -> Bool {
        if client === connection {
            generation &+= 1
            client = nil
            sessionPin = nil
            statusTask?.cancel()
            statusTask = nil
            intentionalStop = false
            state = .failed("The Bridge control connection was closed. Reconnect to continue.")
        }
        connection.close()
        let expected = generation
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            guard expected == generation else { return false }
            if !Self.processExists(pid) { return true }
            if let discovery = readDiscovery(), discovery.pid == pid,
               discovery.socket == socketURL.path, let probe = await connect(discovery) {
                do {
                    let reply = try await probe.request(BridgeControlMessage(kind: .status), timeout: 2)
                    if let status = reply.status, status.pid == pid {
                        let verified = try await authenticate(probe, status: status, generation: expected)
                        probe.close()
                        if verified.0 == pin, status.state == "ready",
                           status.updateReservation == nil, status.admissionClosed == false { return true }
                    } else { probe.close() }
                } catch { probe.close() }
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        return false
    }

    func requestStop() async {
        await stopAndWait(reason: "explicit stop")
    }

    func stopAndWait(reason: String) async {
        let expected = generation
        intentionalStop = true
        stopBlockMessage = nil
        guard let client, sessionPin != nil else {
            if case .conflict = state { return }
            if process != nil {
                // A helper that became ready before its control channel was
                // installed may already have a paired client. Never SIGKILL
                // that process without reading its live task state first.
                if let discovery = liveDiscovery(),
                   await attachToDiscovery(discovery, endpoint: BridgeEndpointInspector.inspect(), origin: .attached, generation: generation) {
                    await stopAndWait(reason: reason)
                    return
                }
                if readReadyFile()?.state == "ready" || identityError != nil {
                    intentionalStop = false
                    stopBlockMessage = "The service reported ready but its control channel is unavailable. It was left running so an active task is not killed blindly."
                    return
                }
                terminateUnreadyProcess()
                state = .idle
                launchOrigin = nil
                return
            }
            if liveDiscovery() != nil {
                intentionalStop = false
                stopBlockMessage = "The Bridge identity is not verified. The service was left running."
                return
            }
            state = .idle
            launchOrigin = nil
            return
        }
        do {
            let current = try await client.request(BridgeControlMessage(kind: .status), timeout: 4)
            guard expected == generation, self.client === client, sessionPin != nil else {
                intentionalStop = false
                stopBlockMessage = "The Bridge connection changed before the stop request. It was left running."
                return
            }
            if let status = current.status {
                if !status.activeTaskIDs.isEmpty || status.activityCount > 0 {
                    intentionalStop = false
                    latestStopRefusal(status)
                    return
                }
                if !status.unknownTaskIDs.isEmpty {
                    stopBlockMessage = "\(status.unknownTaskIDs.count) task(s) have no confirmed result and were retained. The service can stop; nothing was restarted."
                }
            }
            let reply = try await client.request(BridgeControlMessage(kind: .stop, reason: reason), timeout: 6)
            guard expected == generation, self.client === client, sessionPin != nil else { return }
            if let error = reply.error {
                intentionalStop = false
                stopBlockMessage = error
                if let status = reply.status { applyStatus(status) }
                return
            }
            // Fence any in-flight status/event/termination callback for this
            // instance before we replace its state with an explicit stop.
            generation &+= 1
            state = .stopping
            let processGone = await Self.waitForOwnedProcessExit { self.expectedProcessGone() }
            if !processGone {
                intentionalStop = false
                state = .failed("Stop was requested but the embedded Bridge is still running. It was not force-killed.")
                return
            }
            client.close()
            self.client = nil
            process = nil
            ownsProcess = false
            statusTask?.cancel()
            statusTask = nil
            launchOrigin = nil
            pendingConsents = []
            pairingRevision = 0
            state = .idle
            logTail = readLogTail()
            closeLogHandle()
        } catch {
            guard expected == generation, self.client === client else { return }
            intentionalStop = false
            stopBlockMessage = "The stop request was not delivered: \(error.localizedDescription)"
            await refreshStatus()
        }
    }

    /// Cancellation only stops waiting: it never proves that the service
    /// exited. The caller retains the process unless the final check succeeds.
    static func waitForOwnedProcessExit(timeout: Duration = .seconds(10),
                                        isGone: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !isGone() && clock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return isGone() }
        }
        return isGone()
    }

    private func latestStopRefusal(_ status: BridgeControlStatus) {
        state = .ready(status)
        let tasks = status.activeTaskIDs
        if !tasks.isEmpty {
            stopBlockMessage = "\(tasks.count) Bridge task(s) are still active. The service was not stopped. Active: \(tasks.joined(separator: ", "))"
        } else {
            stopBlockMessage = "A Bridge request or file transfer is still active. The service was not stopped."
        }
    }

    private func terminateUnreadyProcess() {
        guard let child = process else { return }
        if child.isRunning {
            child.terminate()
            let deadline = Date().addingTimeInterval(3)
            while child.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if child.isRunning {
                // No listener and no ready record means no paired client could
                // have started a task in this process.
                kill(child.processIdentifier, SIGKILL)
            }
        }
        process = nil
        ownsProcess = false
        closeLogHandle()
    }

    private func expectedProcessGone() -> Bool {
        if let process { return !process.isRunning }
        let discovery = readDiscovery()
        if let discovery {
            return kill(discovery.pid, 0) != 0
        }
        return true
    }

    /// UI termination must not kill a service that still has work. The helper
    /// survives a missing parent and keeps its listener. This only drops the
    /// host-side handles.
    func detachForTermination() {
        generation &+= 1
        statusTask?.cancel()
        statusTask = nil
        readinessTask?.cancel()
        readinessTask = nil
        client?.close()
        client = nil
        sessionPin = nil
        process = nil
        ownsProcess = false
        pendingConsents = []
        pairingRevision = 0
        closeLogHandle()
    }

    private func cleanupAfterFailure() {
        readinessTask?.cancel()
        readinessTask = nil
        statusTask?.cancel()
        statusTask = nil
        client?.close()
        client = nil
        sessionPin = nil
        pendingConsents = []
        pairingRevision = 0
        closeLogHandle()
        process = nil
        ownsProcess = false
        launchOrigin = nil
    }

    private func prepareControlRoot() throws {
        guard isControlRootSafe() else {
            throw BridgeControlFailure.remote("The control root is not an isolated Floe Mac directory.")
        }
        try FileManager.default.createDirectory(
            at: controlRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let values = try controlRoot.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw BridgeControlFailure.remote("The control root must not be a symbolic link.")
        }
    }

    private func isControlRootSafe() -> Bool {
        let resolved = controlRoot.resolvingSymlinksInPath().standardizedFileURL
        let userBridge = UserBridgeGuard.userBridgeRoot.standardizedFileURL
        guard resolved.path != "/", !resolved.path.hasPrefix(userBridge.path + "/") else { return false }
        if testFixture == nil {
            let expectedParent = ModePreferenceStore.defaultRootURL.standardizedFileURL
            return resolved.deletingLastPathComponent().path == expectedParent.path
        }
        return true
    }

    private func prepareTestFixture(_ fixture: URL) throws {
        let resolved = fixture.resolvingSymlinksInPath().standardizedFileURL
        let userBridge = UserBridgeGuard.userBridgeRoot.standardizedFileURL
        guard resolved.path != "/", !resolved.path.hasPrefix(userBridge.path + "/") else {
            throw BridgeControlFailure.remote("The test fixture must be isolated from real Bridge data.")
        }
        for component in ["service-home", "worker-home", "Control"] {
            let url = resolved.appendingPathComponent(component, isDirectory: true)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw BridgeControlFailure.remote("A fixture component is a symbolic link: \(url.path)")
            }
        }
    }

    private func loadOrCreateProbeClientKey(fixture: URL) throws -> Curve25519.Signing.PrivateKey {
        let url = fixture.appendingPathComponent("probe-client.json", isDirectory: false)
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let encoded = object["privateKey"] as? String,
                  let raw = Data(base64Encoded: encoded), raw.count == 32 else {
                throw BridgeControlFailure.remote("The fixture probe client key is invalid.")
            }
            return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        }
        let key = Curve25519.Signing.PrivateKey()
        let payload: [String: Any] = [
            "schema": "floe-mac-bridge-probe-client-v1",
            "privateKey": key.rawRepresentation.base64EncodedString(),
            "publicKey": key.publicKey.rawRepresentation.base64EncodedString()
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return key
    }

    private func removeStaleControlFiles() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: discoveryURL.path) {
            if let discovery = readDiscovery(), kill(discovery.pid, 0) == 0 {
                return
            }
            try manager.removeItem(at: discoveryURL)
        }
        if let ready = readReadyFile(), ready.state == "ready" {
            try? manager.removeItem(at: readyURL)
        } else if manager.fileExists(atPath: readyURL.path) {
            try? manager.removeItem(at: readyURL)
        }
        if manager.fileExists(atPath: socketURL.path) {
            try? manager.removeItem(at: socketURL)
        }
    }

    private func closeLogHandle() {
        try? logHandle?.close()
        logHandle = nil
    }

    func readLogTail() -> String {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > 4_096 ? size - 4_096 : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return "" }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func refreshLogTail() {
        logTail = readLogTail()
    }
}

enum ServicePathsForHost {
    static var realUserHome: URL {
        if let password = getpwuid(getuid()) {
            let path = String(cString: password.pointee.pw_dir)
            if !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
    }
}
