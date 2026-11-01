import Foundation

import BridgeCore
import BridgeHost

struct ProductTestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ProductTestFailure(message: "expectation failed: \(message)") }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw ProductTestFailure(message: "\(message): expected \(expected), got \(actual)")
    }
}

func expectNotNil<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw ProductTestFailure(message: "expectation failed: \(message)")
    }
    return value
}

@MainActor
func waitUntil(timeout: TimeInterval = 2,
               _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock(); value = true; lock.unlock()
    }

    func get() -> Bool {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

final class MemoryClientStore: BridgeRPCClientStore, @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [String: BridgeRPCStoredClient] = [:]
    private var nonces: [String: [String: Int]] = [:]

    func loadClients() throws -> [BridgeRPCStoredClient] {
        lock.lock(); defer { lock.unlock() }
        return Array(clients.values)
    }

    func loadNonces() throws -> [String: [String: Int]] {
        lock.lock(); defer { lock.unlock() }
        return nonces
    }

    func upsertClient(_ client: BridgeRPCStoredClient) throws {
        lock.lock(); defer { lock.unlock() }
        clients[client.clientID] = client
    }

    func removeClient(clientID: String) throws {
        lock.lock(); defer { lock.unlock() }
        clients.removeValue(forKey: clientID)
    }

    func removeAllClients() throws {
        lock.lock(); defer { lock.unlock() }
        clients.removeAll()
        nonces.removeAll()
    }

    func saveNonces(_ nonces: [String: [String: Int]]) throws {
        lock.lock(); defer { lock.unlock() }
        self.nonces = nonces
    }
}

// MARK: - Preferences / restore

@MainActor
func preferenceMigrationKeepsLegacyDiagnosticsOut() async throws {
    let name = "org.floeagent.iosbridge.product.tests." + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: name) else {
        throw ProductTestFailure(message: "could not create isolated defaults")
    }
    defer { defaults.removePersistentDomain(forName: name) }

    defaults.set(true, forKey: BridgeProductPreferences.legacyLANKey)
    defaults.set(true, forKey: BridgeProductPreferences.legacyControlKey)
    let migrated = BridgeProductPreferences.load(from: defaults)
    try expectEqual(migrated.lanEnabled, false, "legacy LAN must not become product LAN")
    try expectEqual(migrated.bonjourEnabled, false, "legacy control must not become Bonjour")
    try expect(BridgeProductPreferences.legacyDiagnosticsWereEnabled(in: defaults),
               "legacy keys should still be observable")

    defaults.set(true, forKey: BridgeProductPreferences.lanKey)
    defaults.set(true, forKey: BridgeProductPreferences.bonjourKey)
    let enabled = BridgeProductPreferences.load(from: defaults)
    try expect(enabled.lanEnabled && enabled.bonjourEnabled, "new product keys must load")
    defaults.set(false, forKey: BridgeProductPreferences.lanKey)
    let normalized = BridgeProductPreferences.load(from: defaults)
    try expect(!normalized.lanEnabled && !normalized.bonjourEnabled,
               "Bonjour must normalize off without LAN")

    // A missing new key stays off even when the legacy values were true.
    defaults.removePersistentDomain(forName: name)
    defaults.set(true, forKey: BridgeProductPreferences.legacyLANKey)
    let absent = BridgeProductPreferences.load(from: defaults)
    try expect(!absent.lanEnabled && !absent.bonjourEnabled,
               "absent product keys default off")
}

@MainActor
func desiredRunningIntentIsIndependentFromAutoRestore() async throws {
    let name = "org.floeagent.iosbridge.product.tests." + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: name) else {
        throw ProductTestFailure(message: "could not create isolated defaults")
    }
    defer { defaults.removePersistentDomain(forName: name) }

    try expect(!BridgeProductRunIntent.load(from: defaults),
               "a fresh product install has no desired-running intent")
    defaults.set(true, forKey: BridgeProductPreferences.legacyLANKey)
    defaults.set(true, forKey: BridgeProductPreferences.legacyControlKey)
    try expect(!BridgeProductRunIntent.load(from: defaults),
               "legacy LAN/control true never becomes a desired run")

    func restore(autoRestore: Bool,
                 desiredRunning: Bool,
                 setup: Bool = true,
                 fault: Bool = false,
                 running: Bool = false) -> Bool {
        BridgeProductRestorationPolicy.shouldRestoreOnLaunch(
            autoRestore: autoRestore,
            desiredRunning: desiredRunning,
            completedSetup: setup,
            terminalFault: fault,
            engineRunning: running
        )
    }

    // Default -> first actual Start -> ready -> reopen restores.
    try expect(!restore(autoRestore: false, desiredRunning: false),
               "default is not restorable")
    BridgeProductRunIntent.markRunning(in: defaults)
    try expect(BridgeProductRunIntent.load(from: defaults),
               "Start records wanted running")
    try expect(restore(autoRestore: true, desiredRunning: true),
               "first started session restores after reopen")
    try expectEqual(BridgeAutoStartPolicy.valueAfterEngineReady(stored: nil), true,
                    "first actual ready may default-enable auto-restore")
    try expectEqual(BridgeAutoStartPolicy.valueAfterEngineReady(stored: false), nil,
                    "a deliberate auto-restore choice is not replaced")

    // Start -> Stop -> reopen stays stopped even with auto-restore true.
    BridgeProductRunIntent.markStopped(in: defaults)
    try expect(!restore(autoRestore: true,
                        desiredRunning: BridgeProductRunIntent.load(from: defaults)),
               "stopped intent must not restore")
    // Start -> Stop -> Start -> reopen restores.
    BridgeProductRunIntent.markRunning(in: defaults)
    try expect(restore(autoRestore: true,
                       desiredRunning: BridgeProductRunIntent.load(from: defaults)),
               "a later Start restores again")

    // A deliberately disabled auto-restore preference is independent.
    try expect(!restore(autoRestore: false, desiredRunning: true),
               "disabled auto-restore stays manual after Start")
    try expect(!restore(autoRestore: true, desiredRunning: true, setup: false),
               "first-run must not auto-restore")
    try expect(!restore(autoRestore: true, desiredRunning: true, fault: true),
               "terminal fault in this process must not auto-restore")
    try expect(!restore(autoRestore: true, desiredRunning: true, running: true),
               "already running must not start again")

    // Authenticated RPC stop records the same stopped intent as a UI Stop.
    BridgeProductRunIntent.markStopped(in: defaults)
    try expect(!restore(autoRestore: true,
                        desiredRunning: BridgeProductRunIntent.load(from: defaults)),
               "authenticated stop records stopped intent")
}

// MARK: - Readiness / primary action

@MainActor
func usableAddressRequiresBothAuthorities() async throws {
    var shared = BridgeSnapshot()
    shared.phase = .ready
    shared.serviceRunning = true
    shared.engineEntryObserved = true
    shared.engineRunning = true

    let engine = BridgeRPCEngineSnapshot(
        owner: "test",
        generation: 7,
        readiness: .ready(generation: 7),
        supportedMethods: ["device_info"]
    )
    var rpc = BridgeRPCHostSnapshot(
        running: true,
        loopbackIPv4Ready: true,
        loopbackIPv6Ready: true,
        lanEnabled: false,
        port: 8200,
        engine: engine
    )

    let local = BridgeProductReadinessPolicy.localURLs(rpc: rpc, shared: shared)
    try expectEqual(local.count, 2, "dual-stack loopback yields both local URLs")
    try expectEqual(local.first?.absoluteString, "http://127.0.0.1:8200/",
                    "IPv4 local address")
    try expectEqual(BridgeProductReadinessPolicy.remotePageURL(rpc: rpc, shared: shared)?.absoluteString,
                    "http://127.0.0.1:8200/remote", "remote page uses the real port")

    var listeningOnly = shared
    listeningOnly.phase = .preparing
    listeningOnly.engineRunning = false
    try expect(BridgeProductReadinessPolicy.localURLs(rpc: rpc, shared: listeningOnly).isEmpty,
               "a bound port while preparing is not a usable address")

    var rpcWithoutEngine = rpc
    rpcWithoutEngine.engine = BridgeRPCEngineSnapshot()
    try expect(BridgeProductReadinessPolicy.localURLs(rpc: rpcWithoutEngine, shared: shared).isEmpty,
               "listener alone is not ready")

    var noPort = rpc
    noPort.port = nil
    try expect(BridgeProductReadinessPolicy.localURLs(rpc: noPort, shared: shared).isEmpty,
               "missing bound port is not ready")

    var terminal = shared
    terminal.terminalFault = true
    terminal.terminalFaultCode = "fatal"
    try expect(BridgeProductReadinessPolicy.localURLs(rpc: rpc, shared: terminal).isEmpty,
               "terminal fault must never expose the address")

    rpc.lanEnabled = true
    rpc.lanIPv4Ready = true
    let lan = BridgeProductReadinessPolicy.lanURLs(
        rpc: rpc,
        shared: shared,
        addresses: ["192.168.1.9", "not-an-ip", "192.168.1.9"]
    )
    try expectEqual(lan.map(\.absoluteString), ["http://192.168.1.9:8200/"],
                    "LAN URLs are real, deduplicated IPv4 addresses only")
}

@MainActor
func runStateAndPrimaryActionFollowLifecycle() async throws {
    var shared = BridgeSnapshot()
    shared.phase = .ready
    shared.serviceRunning = true
    shared.engineEntryObserved = true
    shared.engineRunning = true

    try expectEqual(
        BridgeProductRunStatePolicy.runState(shared: shared, rpcRunning: true, requiresSetup: false),
        .running, "ready engine and listener is running"
    )
    try expectEqual(
        BridgeProductRunStatePolicy.runState(shared: shared, rpcRunning: false, requiresSetup: false),
        .needsAttention, "engine without listener is not presented as running"
    )
    try expectEqual(
        BridgeProductRunStatePolicy.primaryAction(shared: shared, rpcRunning: false, requiresSetup: false),
        .stop, "an active lifecycle still offers stop"
    )

    var preparing = BridgeSnapshot()
    preparing.phase = .waitingForEngine
    preparing.serviceRunning = true
    try expectEqual(
        BridgeProductRunStatePolicy.runState(shared: preparing, rpcRunning: true, requiresSetup: false),
        .preparing, "active preparation is preparing"
    )
    try expectEqual(
        BridgeProductRunStatePolicy.primaryAction(shared: preparing, rpcRunning: true, requiresSetup: false),
        .stop, "Stop stays reachable while preparing"
    )

    var idle = BridgeSnapshot()
    idle.phase = .idle
    try expectEqual(
        BridgeProductRunStatePolicy.runState(shared: idle, rpcRunning: false, requiresSetup: true),
        .needsSetup, "missing prerequisites route to setup"
    )
    try expectEqual(
        BridgeProductRunStatePolicy.primaryAction(shared: idle, rpcRunning: false, requiresSetup: true),
        .setup, "the primary action is setup when prerequisites are missing"
    )

    var terminal = idle
    terminal.terminalFault = true
    terminal.terminalFaultCode = "engine-terminal"
    try expectEqual(
        BridgeProductRunStatePolicy.runState(shared: terminal, rpcRunning: false, requiresSetup: false),
        .reopenRequired, "terminal fault requires reopening"
    )
    try expectEqual(
        BridgeProductRunStatePolicy.primaryAction(shared: terminal, rpcRunning: false, requiresSetup: false),
        .reopen, "terminal fault does not offer a fake start"
    )
}

// MARK: - Approval gate

@MainActor
func approvalGateQueuesBackgroundRequestUntilForeground() async throws {
    let gate = BridgePairingApprovalGate()
    func request(_ id: String, timeout: TimeInterval = 2) -> BridgeRPCApprovalRequest {
        BridgeRPCApprovalRequest(
            requestID: id,
            clientName: " Test Browser ",
            isLoopback: true,
            via: .local,
            fingerprint: "a1b2c3d4",
            timeout: timeout
        )
    }

    // A same-phone client sends /pair while Bridge is background. The one
    // bounded request must be queued, not denied, and survive into foreground.
    let backgroundTask = Task { @MainActor in
        await gate.request(request("bg-approve"))
    }
    guard await waitUntil({ gate.pending?.id == "bg-approve" }) else {
        backgroundTask.cancel()
        throw ProductTestFailure(message: "background pairing request was not queued")
    }
    try expectEqual(gate.pending?.clientName, "Test Browser", "client name is trimmed")
    try expectEqual(gate.pending?.source, .thisDevice, "loopback source")
    try expectEqual(gate.pending?.fingerprint, "a1b2c3d4", "hex fingerprint survives")
    try expect(!BridgeProductApprovalPolicy.canPresent(isForeground: false, hasPending: true),
               "a background request is not presented while inactive")

    // Owner reopens Bridge and presses Allow; approval rechecks foreground.
    try expect(gate.approve(requestID: "bg-approve", isForeground: { true }),
               "foreground owner approve resolves the queued request")
    try expectEqual(await backgroundTask.value, .approve,
                    "a request queued in background can be approved after foreground")
    try expect(gate.pending == nil, "prompt is cleared")
    try expect(!gate.approve(requestID: "bg-approve", isForeground: { true }),
               "late approve cannot grant twice")
    try expect(!gate.withdraw(), "late withdraw has nothing to resolve")

    // Approval never succeeds while inactive.
    let inactiveTask = Task { @MainActor in
        await gate.request(request("bg-inactive"))
    }
    guard await waitUntil({ gate.pending?.id == "bg-inactive" }) else {
        inactiveTask.cancel()
        throw ProductTestFailure(message: "inactive approval request was not queued")
    }
    try expect(gate.approve(requestID: "bg-inactive", isForeground: { false }),
               "an inactive approve resolves the request")
    try expectEqual(await inactiveTask.value, .deny,
                    "an inactive approve cannot grant the client")
    try expect(gate.pending == nil, "inactive approve clears the prompt")

    // A request that stays background until its existing deadline is denied.
    let timeoutDecision = await gate.request(request("bg-timeout", timeout: 0.2))
    try expectEqual(timeoutDecision, .deny, "a background request honors the real deadline")
    try expect(gate.pending == nil, "timeout clears the queued prompt")

    // Owner Stop/background withdrawal denies a queued request.
    let stopTask = Task { @MainActor in
        await gate.request(request("bg-stop"))
    }
    guard await waitUntil({ gate.pending?.id == "bg-stop" }) else {
        stopTask.cancel()
        throw ProductTestFailure(message: "stop pairing request was not queued")
    }
    try expect(gate.withdraw(), "owner Stop denies the queued request")
    try expectEqual(await stopTask.value, .deny, "withdraw returns deny")
}

@MainActor
func approvalGateDenyStopAndTimeoutResolveOnce() async throws {
    let gate = BridgePairingApprovalGate()
    let request = BridgeRPCApprovalRequest(
        requestID: "pair-deny",
        clientName: "Browser",
        isLoopback: false,
        via: .lan,
        fingerprint: "deadbeef",
        timeout: 2
    )

    let task = Task { @MainActor in
        await gate.request(request)
    }
    guard await waitUntil({ gate.pending != nil }) else {
        task.cancel()
        throw ProductTestFailure(message: "approval prompt did not appear")
    }
    try expectEqual(gate.pending?.source, .localNetwork, "LAN source")
    try expect(gate.deny(), "owner deny resolves")
    try expectEqual(await task.value, .deny, "deny is returned")
    try expect(!gate.approve(isForeground: { true }), "approve after deny cannot revive the request")

    let stopped = Task { @MainActor in
        await gate.request(request)
    }
    guard await waitUntil({ gate.pending != nil }) else {
        stopped.cancel()
        throw ProductTestFailure(message: "second approval prompt did not appear")
    }
    try expect(gate.withdraw(), "Stop/background withdraw resolves")
    try expectEqual(await stopped.value, .deny, "withdraw denies")
    try expect(!gate.withdraw(), "withdraw resolves only once")

    // The authority's timeout is injected through the request; use a short
    // value so the test exercises the real deadline path.
    let timeoutRequest = BridgeRPCApprovalRequest(
        requestID: "pair-timeout",
        clientName: "Slow browser",
        isLoopback: true,
        via: .local,
        fingerprint: nil,
        timeout: 0.3
    )
    let timeoutDecision = await gate.request(timeoutRequest)
    try expectEqual(timeoutDecision, .deny, "timeout denies")
    try expect(gate.pending == nil, "timeout clears the prompt")
    try expect(!gate.approve(requestID: "pair-timeout", isForeground: { true }), "approve after timeout does nothing")

    let cancelled = Task { @MainActor in
        await gate.request(request)
    }
    guard await waitUntil({ gate.pending != nil }) else {
        cancelled.cancel()
        throw ProductTestFailure(message: "cancellation prompt did not appear")
    }
    cancelled.cancel()
    let cancelledDecision = await cancelled.value
    try expectEqual(cancelledDecision, .deny, "task cancellation denies")
    try expect(!gate.approve(isForeground: { true }), "approve after cancellation does nothing")
}

@MainActor
func approvalGateAllowsOnlyOnePrompt() async throws {
    let gate = BridgePairingApprovalGate()
    let first = BridgeRPCApprovalRequest(
        requestID: "first", clientName: "First", isLoopback: true,
        via: .local, fingerprint: nil, timeout: 2
    )
    let second = BridgeRPCApprovalRequest(
        requestID: "second", clientName: "Second", isLoopback: false,
        via: .lan, fingerprint: nil, timeout: 2
    )
    let task = Task { @MainActor in
        await gate.request(first)
    }
    guard await waitUntil({ gate.pending != nil }) else {
        task.cancel()
        throw ProductTestFailure(message: "first prompt did not appear")
    }
    let deniedSecond = await gate.request(second)
    try expectEqual(deniedSecond, .deny, "a second prompt is denied, not queued")
    try expectEqual(gate.pending?.id, "first", "the first prompt remains the only one")
    try expect(gate.deny(requestID: "first"), "first prompt can still be denied")
    try expectEqual(await task.value, .deny, "first result")
}

@MainActor
func approvalGateScopesCancellationAndRechecksForeground() async throws {
    let gate = BridgePairingApprovalGate()
    let first = BridgeRPCApprovalRequest(
        requestID: "first", clientName: "First", isLoopback: true,
        via: .local, fingerprint: nil, timeout: 2
    )
    let second = BridgeRPCApprovalRequest(
        requestID: "second", clientName: "Second", isLoopback: true,
        via: .local, fingerprint: nil, timeout: 2
    )

    let firstTask = Task { @MainActor in
        await gate.request(first)
    }
    guard await waitUntil({ gate.pending?.id == "first" }) else {
        firstTask.cancel()
        throw ProductTestFailure(message: "first prompt did not appear")
    }
    try expect(gate.approve(requestID: "first", isForeground: { true }),
               "first prompt approves")
    try expectEqual(await firstTask.value, .approve, "first decision")
    try expect(!gate.approve(requestID: "first", isForeground: { true }),
               "late approve cannot grant twice")

    let secondTask = Task { @MainActor in
        await gate.request(second)
    }
    guard await waitUntil({ gate.pending?.id == "second" }) else {
        secondTask.cancel()
        throw ProductTestFailure(message: "second prompt did not appear")
    }
    // This is the delayed cancellation/approval for the already-resolved
    // first request.
    try expect(!gate.withdraw(requestID: "first"),
               "a delayed cancel for a resolved request is scoped out")
    try expect(!gate.approve(requestID: "first", isForeground: { true }),
               "a late approve for a resolved request cannot grant")
    try expectEqual(gate.pending?.id, "second",
                    "a delayed callback must not deny or replace the newer prompt")

    var foreground = true
    foreground = false
    try expect(gate.approve(requestID: "second", isForeground: { foreground }),
               "approve callback still resolves the request")
    try expectEqual(await secondTask.value, .deny,
                    "an inactive approve resolves as deny")
    try expect(gate.pending == nil, "inactive approve clears the prompt")

    let third = BridgeRPCApprovalRequest(
        requestID: "third", clientName: "Third", isLoopback: true,
        via: .local, fingerprint: nil, timeout: 0.2
    )
    let deadlineDecision = await gate.request(third)
    try expectEqual(deadlineDecision, .deny, "the real deadline denies")
    try expect(!gate.approve(requestID: "third", isForeground: { foreground }),
               "an approve after the deadline cannot revive the request")
}

@MainActor
func approvalDisplaySanitizesUntrustedInput() async throws {
    let raw = " Bank\u{202E}evil\u{200B} " + String(repeating: "x", count: 200)
    let sanitized = BridgeProductApprovalPolicy.displayName(raw)
    try expect(!sanitized.unicodeScalars.contains { (0x202A...0x202E).contains($0.value) },
               "bidi override removed")
    try expect(!sanitized.contains("\u{200B}"), "zero-width removed")
    try expectEqual(sanitized.count, 64, "display name is bounded")
    try expectEqual(BridgeProductApprovalPolicy.displayName("  \n\t "), "",
                    "control-only name becomes empty")
    try expectEqual(BridgeProductApprovalPolicy.fingerprint("A1B2C3D4"), "a1b2c3d4",
                    "hex fingerprint normalized for display")
    try expectEqual(BridgeProductApprovalPolicy.fingerprint("not-hex"), nil,
                    "non-hex fingerprint rejected")
    try expect(!BridgeProductApprovalPolicy.canPresent(isForeground: false, hasPending: false),
               "background cannot present")
    try expect(!BridgeProductApprovalPolicy.canPresent(isForeground: true, hasPending: true),
               "one prompt at a time")
    try expect(BridgeProductApprovalPolicy.canQueue(hasPending: false),
               "a background request can queue for later owner approval")
    try expect(!BridgeProductApprovalPolicy.canQueue(hasPending: true),
               "only one bounded request may wait")
}

// MARK: - Diagnostics / runtime

@MainActor
func diagnosticsExportIsPublicSafe() async throws {
    var shared = BridgeSnapshot()
    shared.phase = .failed
    shared.lastError = "engine failed reading /Users/alice/Library/secret"
    shared.notes = ["staged /Volumes/TECLAST/private/file", "ordinary note"]
    shared.startedAt = "2026-11-02T01:00:00Z"

    let rpc = BridgeRPCHostSnapshot(
        running: true,
        loopbackIPv4Ready: true,
        loopbackIPv6Ready: true,
        lanIPv4Ready: true,
        lanEnabled: true,
        bonjourState: "published",
        port: 8200,
        engine: BridgeRPCEngineSnapshot(owner: "engine", generation: 1,
                                        readiness: .ready(generation: 1),
                                        supportedMethods: ["device_info"]),
        clients: [
            BridgeRPCClientRecord(
                clientID: "secret-client-id",
                clientName: "Secret Client",
                grantedAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastActiveAt: Date(timeIntervalSince1970: 1_700_000_100),
                lastAddress: "192.168.1.9",
                lastVia: .lan
            )
        ],
        capabilities: ["device_info", "screenshot"]
    )
    let report = BridgeProductDiagnosticsReport.make(
        shared: shared,
        rpc: rpc,
        listenerError: "could not open /private/var/tmp/listener",
        pendingApproval: true,
        statusLog: BridgeProductStatusLogHealth(
            eventCount: 3,
            retainedDates: ["2026-11-02"],
            persistence: "persistent",
            lastFailure: nil
        )
    )
    let json = report.jsonString()
    try expect(!json.contains("/Users/"), "export redacts user paths")
    try expect(!json.contains("/Volumes/"), "export redacts volume paths")
    try expect(!json.contains("/private/"), "export redacts private paths")
    try expect(!json.contains("Secret Client"), "export omits client names")
    try expect(!json.contains("secret-client-id"), "export omits client ids")
    try expect(!json.contains("192.168.1.9"), "export omits client addresses")
    try expect(json.contains("\"port\" : 8200"), "export keeps the real port")
    try expect(json.contains("\"pendingApproval\" : true"), "export states approval pending")
    try expect(json.contains("\"source\" : \"structured-status-events\""),
               "export names the structured status source")
    try expect(json.contains("\"eventCount\" : 3"), "export keeps the bounded event count")
    try expect(json.contains("<path>"), "redaction marker is explicit")
    try expectEqual(BridgeProductRuntime.limits().streamConsumerBufferBytes, 2 * 1_024 * 1_024,
                    "media integration buffer is the coordinated 2 MiB value")
}

@MainActor
func statusLogPersistsBoundedPrivateEvents() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-status-log-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var shared = BridgeSnapshot()
    shared.phase = .ready
    shared.serviceRunning = true
    shared.engineEntryObserved = true
    shared.engineRunning = true
    shared.generation = 9
    shared.pairingImported = true

    var rpc = BridgeRPCHostSnapshot(
        running: true,
        loopbackIPv4Ready: true,
        loopbackIPv6Ready: true,
        lanIPv4Ready: true,
        lanEnabled: true,
        bonjourState: "published",
        port: 8200,
        engine: BridgeRPCEngineSnapshot(owner: "test", generation: 9,
                                        readiness: .ready(generation: 9),
                                        supportedMethods: ["device_info", "screenshot"]),
        clients: [
            BridgeRPCClientRecord(
                clientID: "secret-client-id",
                clientName: "Secret Client",
                grantedAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastActiveAt: Date(timeIntervalSince1970: 1_700_000_100),
                lastAddress: "192.168.1.9",
                lastVia: .lan
            )
        ],
        capabilities: ["device_info", "screenshot"],
        storageError: "failed reading /Users/alice/Library/secret",
        nonceStoreAvailable: true,
        networkError: "listener /private/var/tmp/socket"
    )
    rpc.clients[0].sensitiveInputGranted = true

    let log = BridgeProductStatusLog(
        directory: root,
        ddiProgressURL: root.appendingPathComponent("missing-progress.json"),
        statusURL: root.appendingPathComponent("missing-status.json"),
        maxEvents: 8,
        maxBytes: 1_024
    )
    for index in 0..<40 {
        log.record(kind: index.isMultiple(of: 2) ? .ownerStart : .ownerStop,
                   shared: shared,
                   rpc: rpc,
                   lanPreference: index.isMultiple(of: 2))
    }
    log.flushForTesting()

    let lines = log.recentLog(limit: 500, matching: nil)
    try expect(!lines.isEmpty, "the source returns actual events, not an empty stub")
    try expect(lines.count <= 8, "RAM event count is bounded")
    let text = lines.joined(separator: "\n")
    for banned in ["Secret Client", "secret-client-id", "192.168.1.9",
                   "sensitiveInputGranted", "/Users/", "/private/"] {
        try expect(!text.contains(banned), "status events exclude \(banned)")
    }
    try expect(lines.allSatisfy { $0.contains("k=") && $0.contains("t=") },
               "each event has fixed timestamp and kind fields")

    let files = try expectNotNil(log.logFiles(), "persisted files are listed")
    try expectEqual(files,
                    [BridgeProductStatusLog.currentFileName,
                     BridgeProductStatusLog.rotatedFileName],
                    "fixed known log file names")
    let currentURL = root.appendingPathComponent(BridgeProductStatusLog.currentFileName)
    let rotatedURL = root.appendingPathComponent(BridgeProductStatusLog.rotatedFileName)
    let currentData = try Data(contentsOf: currentURL)
    let rotatedData = try Data(contentsOf: rotatedURL)
    try expect(currentData.count <= 1_024, "current file respects the byte cap")
    try expect(rotatedData.count <= 1_024, "rotation respects the byte cap")
    let permissions = try FileManager.default
        .attributesOfItem(atPath: currentURL.path)[.posixPermissions] as? NSNumber
    try expectEqual(permissions?.intValue, 0o600, "persisted log is owner-only")

    let health = log.health()
    try expectEqual(health.persistence, "persistent", "a successful flush is persistent")
    try expect(health.eventCount <= 8, "health reports the bounded count")
    let dates = try expectNotNil(log.logHistory(date: nil), "retained dates")
    let firstDate = try expectNotNil(health.retainedDates.first, "one retained date")
    try expect(dates.contains(firstDate), "history lists retained dates")
    try expect(log.logHistory(date: "1900-01-01") == nil,
               "absent dates are honest nil")
    try expect(log.recentLog(limit: 500, matching: "ownerstart").allSatisfy {
        $0.lowercased().contains("ownerstart")
    }, "matching filters actual lines")

    let reloaded = BridgeProductStatusLog(
        directory: root,
        ddiProgressURL: root.appendingPathComponent("missing-progress.json"),
        statusURL: root.appendingPathComponent("missing-status.json"),
        maxEvents: 8,
        maxBytes: 1_024
    )
    let reloadedLines = reloaded.recentLog(limit: 500, matching: nil)
    try expect(!reloadedLines.isEmpty, "a new process reloads retained events")
    try expect(reloaded.health().eventCount <= 8, "reload remains bounded")
}

@MainActor
func statusLogKeepsTypedDDIProvenance() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-status-log-ddi-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let progressURL = root.appendingPathComponent("ddi-progress.json")
    let pid = Int(ProcessInfo.processInfo.processIdentifier)
    let progress: [String: Any] = [
        "hostPid": pid,
        "stage": "opaque-install-entered",
        "outcome": "running",
        "elapsedMilliseconds": 1_234,
        "errorCode": "raw-error-code",
        "notes": ["raw note /Users/alice/secret"],
    ]
    try JSONSerialization.data(withJSONObject: progress).write(to: progressURL)

    let log = BridgeProductStatusLog(
        directory: root,
        ddiProgressURL: progressURL,
        statusURL: root.appendingPathComponent("missing-status.json")
    )
    var shared = BridgeSnapshot()
    shared.ddi = .mounted
    shared.ddiSource = BridgeDDIMountProvenance.onDevice.rawValue
    shared.ddiLayout = BridgeDDILayout.cryptex.rawValue
    shared.lastOnDeviceMountAt = "2026-11-02T01:02:03.456Z"
    shared.lastOnDeviceMountLayout = BridgeDDILayout.cryptex.rawValue
    shared.ddiDetail = "raw detail /Users/alice/secret"
    log.record(kind: .ownerStart,
               shared: shared,
               rpc: BridgeRPCHostSnapshot(),
               ddiMethod: BridgeDDIInstallMethod.cryptex.rawValue)
    log.flushForTesting()

    let line = log.recentLog(limit: 10, matching: nil).joined(separator: "\n")
    for expected in ["ddi_source=on-device",
                     "ddi_layout=cryptex",
                     "ddi_method=cryptex",
                     "ddi_stage=opaque-install-entered",
                     "ddi_outcome=running",
                     "ddi_elapsed_ms=1234",
                     "last_ondevice_mount=2026-11-02T01:02:03.456Z",
                     "last_ondevice_layout=cryptex"] {
        try expect(line.contains(expected), "typed DDI fact \(expected)")
    }
    for banned in ["raw-error-code", "raw note", "/Users/", "raw detail"] {
        try expect(!line.contains(banned), "DDI detail is excluded: \(banned)")
    }

    var unrecognized = shared
    unrecognized.ddiSource = "raw-source-detail"
    unrecognized.ddiLayout = "raw-layout-detail"
    log.record(kind: .sharedState,
               shared: unrecognized,
               rpc: BridgeRPCHostSnapshot())
    log.flushForTesting()
    let unknownLine = log.recentLog(limit: 1, matching: nil).joined()
    try expect(unknownLine.contains("ddi_source=unknown"),
               "unrecognized provenance says unknown")
    try expect(unknownLine.contains("ddi_layout=unknown"),
               "unrecognized layout says unknown")
    try expect(!unknownLine.contains("raw-source-detail"),
               "raw source is never serialized")
    try expect(!unknownLine.contains("raw-layout-detail"),
               "raw layout is never serialized")

    let staleProgress: [String: Any] = [
        "hostPid": 999_999,
        "stage": "opaque-install-entered",
        "outcome": "running",
        "elapsedMilliseconds": 55,
    ]
    try JSONSerialization.data(withJSONObject: staleProgress).write(to: progressURL)
    log.record(kind: .sharedState,
               shared: shared,
               rpc: BridgeRPCHostSnapshot())
    log.flushForTesting()
    let staleLine = log.recentLog(limit: 1, matching: nil).joined()
    try expect(!staleLine.contains("ddi_stage="),
               "progress from another process is ignored")

    var before = BridgeSnapshot()
    before.ddi = .mounted
    var after = before
    after.ddiSource = BridgeDDIMountProvenance.onDevice.rawValue
    after.ddiLayout = BridgeDDILayout.cryptex.rawValue
    after.lastOnDeviceMountAt = "2026-11-02T01:02:03.456Z"
    try expect(BridgeProductStatusLog.sharedChanged(previous: before, current: after),
               "provenance change is a status change")
    var detailOnly = before
    detailOnly.ddiDetail = "raw detail"
    try expect(!BridgeProductStatusLog.sharedChanged(previous: before, current: detailOnly),
               "raw detail alone does not create a status event")
}

@MainActor
func statusLogRestoresHistoricalMountFactsAfterRelaunch() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-status-log-restore-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let statusURL = root.appendingPathComponent("previous-status.json")
    let previousStatus: [String: Any] = [
        "lastOnDeviceMountAt": "2026-11-01T22:00:00.000Z",
        "lastOnDeviceMountLayout": "cryptex",
        "lastError": "raw error /Users/alice/secret",
        "ddiSource": "raw-source-detail",
        "notes": ["raw note"],
    ]
    try JSONSerialization.data(withJSONObject: previousStatus).write(to: statusURL)

    let log = BridgeProductStatusLog(
        directory: root.appendingPathComponent("log", isDirectory: true),
        ddiProgressURL: root.appendingPathComponent("missing-progress.json"),
        statusURL: statusURL
    )
    var shared = BridgeSnapshot()
    shared.phase = .idle
    shared.ddi = .unknown
    log.record(kind: .launch, shared: shared, rpc: BridgeRPCHostSnapshot())
    log.flushForTesting()

    let line = log.recentLog(limit: 1, matching: nil).joined()
    try expect(line.contains("last_ondevice_mount=2026-11-01T22:00:00.000Z"),
               "the previous verified mount timestamp survives a relaunch")
    try expect(line.contains("last_ondevice_layout=cryptex"),
               "the corresponding recognized layout survives")
    try expect(line.contains("ddi_source=unknown"),
               "historical mount is not a current on-device claim")
    for banned in ["raw error", "/Users/", "raw-source-detail", "raw note"] {
        try expect(!line.contains(banned), "previous status text is excluded: \(banned)")
    }
}

@MainActor
func statusLogIgnoresClientActivityChurn() async throws {
    let previous = BridgeRPCHostSnapshot(
        running: true,
        loopbackIPv4Ready: true,
        loopbackIPv6Ready: true,
        port: 8200,
        engine: BridgeRPCEngineSnapshot(owner: "test", generation: 2,
                                        readiness: .ready(generation: 2),
                                        supportedMethods: ["device_info"]),
        clients: [
            BridgeRPCClientRecord(
                clientID: "client",
                clientName: "Client",
                grantedAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastActiveAt: Date(timeIntervalSince1970: 1_700_000_100),
                lastAddress: "192.168.1.9",
                lastVia: .lan
            )
        ],
        capabilities: ["device_info"]
    )
    var next = previous
    next.clients[0].lastActiveAt = Date(timeIntervalSince1970: 1_700_000_200)
    next.clients[0].lastAddress = "192.168.1.10"
    try expect(!BridgeProductStatusLog.rpcChanged(previous: previous, current: next),
               "ordinary client activity does not create a status event")

    next.running = false
    try expect(BridgeProductStatusLog.rpcChanged(previous: previous, current: next),
               "an actual listener transition creates a status event")
}

@MainActor
func statusLogFailureIsSafeAndMemoryOnly() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-status-log-fail-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let occupied = root.appendingPathComponent("occupied")
    try Data("not a directory".utf8).write(to: occupied)

    var shared = BridgeSnapshot()
    shared.phase = .stopped
    let log = BridgeProductStatusLog(
        directory: occupied,
        ddiProgressURL: root.appendingPathComponent("missing-progress.json"),
        statusURL: root.appendingPathComponent("missing-status.json")
    )
    log.record(kind: .ownerStart,
               shared: shared,
               rpc: BridgeRPCHostSnapshot())
    log.flushForTesting()

    try expect(!log.recentLog(limit: 10, matching: nil).isEmpty,
               "events remain readable in memory")
    try expectEqual(log.health().persistence, "memory-only",
                    "failed persistence is not claimed as stored")
    try expect(log.logFiles() == nil, "no files claimed when persistence failed")
    try expectEqual(log.health().lastFailure, "directory-unavailable",
                    "failure is a safe fixed value")
    try expect(!(log.health().lastFailure ?? "").contains("/"),
               "failure does not leak a private path")
}

@MainActor
func statusLogTicketRouteReturnsRealEvents() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-status-log-route-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var shared = BridgeSnapshot()
    shared.phase = .waitingForEngine
    shared.serviceRunning = true
    shared.engineEntryObserved = false
    shared.engineRunning = false
    shared.generation = 3
    shared.ddi = .notMounted
    shared.ddiSource = nil
    shared.lastOnDeviceMountAt = "2026-11-01T23:00:00.000Z"
    shared.lastOnDeviceMountLayout = BridgeDDILayout.cryptex.rawValue
    var rpc = BridgeRPCHostSnapshot(
        running: true,
        loopbackIPv4Ready: true,
        loopbackIPv6Ready: true,
        port: 8200,
        engine: BridgeRPCEngineSnapshot(owner: "test", generation: 3,
                                        readiness: .notReady(reason: "raw engine reason"),
                                        supportedMethods: ["device_info"]),
        capabilities: ["device_info"]
    )
    rpc.bonjourState = "off"
    let log = BridgeProductStatusLog(
        directory: root,
        ddiProgressURL: root.appendingPathComponent("missing-progress.json"),
        statusURL: root.appendingPathComponent("missing-status.json"),
        maxEvents: 32,
        maxBytes: 8 * 1_024
    )
    log.record(kind: .ownerStart, shared: shared, rpc: rpc)
    log.flushForTesting()

    let limits = BridgeRPCLimits.default
    let authority = BridgeRPCAuthority(
        store: MemoryClientStore(),
        limits: limits,
        approvalHandler: { _ in .approve }
    )
    let service = BridgeRPCService(
        configuration: BridgeRPCService.Configuration(requestedPort: 0, limits: limits),
        authority: authority,
        registry: BridgeRPCEngineRegistry(),
        coordinator: BridgeRPCExecutionCoordinator(limits: limits),
        resources: BridgeRPCEmptyResources(),
        logs: log,
        streamSource: nil
    )
    service.beginServing()
    let peer = BridgeRPCPeerInfo(address: "127.0.0.1", via: .local, isLoopback: true)
    let pairBody = BridgeRPCJSONValue.object([
        "client_name": .string("status-log-client"),
        "plain": .bool(true),
    ]).canonicalData()
    let pairResult = await service.handle(
        BridgeRPCHTTPRequest(method: "POST", path: "/pair", pathOnly: "/pair",
                             query: "", headers: ["Content-Type": "application/json"],
                             body: pairBody),
        peer: peer
    )
    guard case .response(let pairResponse) = pairResult else {
        throw ProductTestFailure(message: "pairing did not return an HTTP response")
    }
    try expectEqual(pairResponse.status, 200, "loopback plain pairing")
    let pairObject = try BridgeRPCJSON.decode(pairResponse.body).objectValue
    let clientID = try expectNotNil(pairObject?["tok"]?.stringValue, "paired client id")
    let ticket = try expectNotNil(authority.issueStreamTicket(clientID: clientID),
                                  "log ticket")

    let logsResult = await service.handle(
        BridgeRPCHTTPRequest(method: "GET",
                             path: "/logs?ticket=\(ticket.ticket)",
                             pathOnly: "/logs",
                             query: "ticket=\(ticket.ticket)",
                             headers: [:],
                             body: Data()),
        peer: peer
    )
    guard case .response(let logsResponse) = logsResult else {
        throw ProductTestFailure(message: "logs did not return an HTTP response")
    }
    try expectEqual(logsResponse.status, 200, "ticket-backed logs route")
    let body = String(decoding: logsResponse.body, as: UTF8.self)
    try expect(body.contains("k=ownerStart"),
               "canonical route returns real structured events")
    try expect(body.contains("engine_ready=false"),
               "pre-readiness state is visible through the canonical log route")
    try expect(body.contains("ddi=not-mounted"),
               "the no-DDI state is visible before engine readiness")
    try expect(body.contains("ddi_source=unknown"),
               "missing native provenance is reported as unknown")
    try expect(body.contains("ddi_layout=unknown"),
               "missing layout is reported as unknown")
    try expect(body.contains("last_ondevice_mount=2026-11-01T23:00:00.000Z"),
               "the last verified on-device mount timestamp survives")
    try expect(body.contains("last_ondevice_layout=cryptex"),
               "the corresponding verified layout survives")
    try expect(!body.contains("raw engine reason"),
               "arbitrary engine reasons are not serialized")
    try expect(!body.contains("status-log-client"),
               "log route does not leak the client name")
}

@MainActor
func hostServiceLifecycleIsReal() async throws {
    let host = BridgeRPCHostService(
        configuration: BridgeRPCHostService.Configuration(
            requestedPort: 0,
            limits: BridgeProductRuntime.limits()
        ),
        store: MemoryClientStore()
    )
    let observedRunning = AtomicFlag()
    host.setStateHandler { snapshot in
        if snapshot.running { observedRunning.set() }
    }
    // The owner stop hook is accepted; the transport close remains the default
    // behavior and no test-only path is added to production code.
    host.setStopHandler {}
    try host.start()
    let started = host.snapshot()
    try expect(started.running, "service is running after start")
    try expect(started.loopbackReady, "real dual-stack loopback listeners are bound")
    try expect(started.port != nil, "an actual port is reported")
    try expect(!started.isReady, "listener without a registered engine is not ready")
    try expect(observedRunning.get(), "state callback observed the running service")
    host.stop()
    let stopped = host.snapshot()
    try expect(!stopped.running, "service stops its listeners")
}
