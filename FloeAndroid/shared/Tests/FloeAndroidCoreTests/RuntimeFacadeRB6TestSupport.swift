// SPDX-License-Identifier: MPL-2.0
//
// RB-6 qualification TEST SOURCE (authored, NOT executed by this package).
// Shared fixtures for the Skills/MCP/capabilities suites: a REAL accepted
// runtime generation (trusted host bootstrap on a temp root, the ORIGINAL
// 46-migration DatabaseManager), scripted gateway/route/epoch/admission
// ports, canonical synthetic skill packages, and the EXISTING loopback
// HTTP fixture driving the REAL MCPRemoteClient path. No production
// behavior is weakened: the scripted MCP network admission and the
// 127.0.0.1 endpoint exist only in this test target; shipped seams default
// closed (MCPTransportAdmissionClosed / SkillsRemoteTransportUnavailable /
// SkillModelRewritingUnavailable).
import XCTest
import Foundation
import Crypto
@testable import FloeAndroidCore
import FloeCore
import FloeSkills
import FloeTools
import FloePersistence

// MARK: - Accepted runtime generation fixture (real bootstrap, real schema)

final class RB6TestFixture: @unchecked Sendable {
    let rootDirectory: URL
    let installationRoot: URL
    let stagingRoot: URL
    let database: DatabaseManager
    let epoch: UInt64
    let ownerToken: String

    private init(base: URL, database: DatabaseManager, epoch: UInt64,
                 ownerToken: String) {
        rootDirectory = base
        installationRoot = base.appendingPathComponent("FloeAgent/Skills")
        stagingRoot = base.appendingPathComponent("staging")
        self.database = database
        self.epoch = epoch
        self.ownerToken = ownerToken
    }

    /// Async factory: temp dirs, REAL original migrations through the
    /// domain-visible DatabaseManager, then the REAL trusted-host start on
    /// the same root (the owned store owner opens its own manager of the
    /// same file — WAL, in-process; the domain under test uses this one).
    /// Readiness is the bootstrap's OWN typed state, never fabricated.
    /// The accepted bootstrap admits a new generation only after the previous
    /// one RETIRED. XCTest teardown tasks are not awaited, so every `make`
    /// first retires the PREVIOUS fixture deterministically (the deferred
    /// shutdown in the old test becomes an idempotent no-op).
    nonisolated(unsafe) private static var previousFixture: RB6TestFixture?
    private static let fixtureLock = NSLock()

    static func make(id: String) async throws -> RB6TestFixture {
        let previous = fixtureLock.withLock { () -> RB6TestFixture? in
            let value = previousFixture
            previousFixture = nil
            return value
        }
        if let previous { await previous.shutdown() }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-rb6-\(id)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("FloeAgent/Skills"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("staging"),
            withIntermediateDirectories: true)
        let token = String(repeating: "a", count: 8)
            + String(format: "%08x", UInt32(truncatingIfNeeded: abs(id.hashValue)))
        let ownerToken = String(token.prefix(16))
        // STRICTLY monotonic across one process: the accepted bootstrap
        // requires a newer epoch than the live/previous generation, so a
        // random value could (and did) collide into `epochNotNewer`.
        let epoch = DispatchTime.now().uptimeNanoseconds
        let database = try DatabaseManager(path: base.appendingPathComponent("floe.sqlite"))
        try await database.migrate()
        // A previous test's generation may still be retiring (teardown is
        // asynchronous in XCTest): wait for the REAL retirement before the
        // strictly-newer start instead of colliding with `alreadyDraining`.
        var prewait = 0
        while AndroidRuntimeBootstrap.currentPumps() != nil, prewait < 15_000 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            prewait += 10
        }
        switch AndroidRuntimeBootstrap.start(rootPath: base.path,
                                             ownerToken: ownerToken,
                                             epoch: epoch) {
        case .accepted, .idempotent:
            break
        case .rejected(let code):
            throw NSError(domain: "RB6Fixture", code: -1,
                          userInfo: ["code": code.rawValue])
        }
        // Wait for the REAL owned-store readiness (mailbox drain runs the
        // original open/migrate/recover sequence; no test-side shortcut).
        var waited = 0
        while AndroidRuntimeBootstrap.currentPumps()?.storeReady != true, waited < 20_000 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 10
        }
        guard AndroidRuntimeBootstrap.currentPumps()?.storeReady == true else {
            throw NSError(domain: "RB6Fixture", code: -2)
        }
        let fixture = RB6TestFixture(base: base, database: database, epoch: epoch,
                                     ownerToken: ownerToken)
        fixtureLock.withLock { previousFixture = fixture }
        return fixture
    }

    /// REAL fixture retirement: the trusted shutdown call only ENQUEUES the
    /// internal shutdown control, so this waits for its own effect-receipt
    /// terminal AND the authoritative ownership status (`ownedStorePhase ==
    /// closed`, generation gone, final phase stopped/failed). `currentPumps()`
    /// is NOT a retirement proof (it returns nil for a retiring generation).
    func shutdown() async {
        let outcome = AndroidRuntimeBootstrap.shutdown(expectedEpoch: epoch,
                                                       ownerToken: ownerToken)
        var receipt: String?
        switch outcome {
        case .accepted(let value), .idempotent(let value):
            receipt = value
        case .rejected:
            break
        }
        var terminalKind = "none"
        var storeClosed = false
        var generationGone = false
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if let receipt, let pumps = AndroidRuntimeBootstrap.currentEffectPumps() {
                if case .page(let items, _, _, _) = pumps.effects.poll(
                    receipt: receipt, afterSequence: 0),
                   let terminal = items.last(where: { $0.isTerminal }) {
                    terminalKind = terminal.kind.rawValue
                }
            }
            if let data = AndroidRuntimeBootstrap.statusSnapshotJSON()
                .data(using: .utf8),
               let status = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] {
                storeClosed = (status["ownedStorePhase"] as? String) == "closed"
                let phase = status["phase"] as? String
                generationGone = status["generation"] == nil
                    && (phase == "stopped" || phase == "failed")
            }
            if storeClosed && generationGone { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        print("RB6DIAG shutdown epoch=\(epoch) outcome=\(outcome) terminal=\(terminalKind) closed=\(storeClosed) gone=\(generationGone) owned=\(RuntimeOwnedWorkRegistry.shared.countsByKind(for: epoch))")
        // Close/remove ONLY after the REAL retirement facts. A failed drain
        // keeps the DB and root for inspection (no forced reset).
        if storeClosed && generationGone {
            try? await database.close()
            try? FileManager.default.removeItem(at: rootDirectory)
        }
    }

    /// Awaited fixture cleanup boundary for each test class's `tearDown`.
    static func shutdownCurrent() async {
        let current = fixtureLock.withLock { () -> RB6TestFixture? in
            let value = previousFixture
            previousFixture = nil
            return value
        }
        if let current { await current.shutdown() }
    }

    var hostContext: RB6HostContext {
        RB6HostContext(fingerprint: RuntimeStorageRoot(
            validatingAbsoluteDirectory: rootDirectory.path)?.fingerprint ?? "00000000")
    }

    func ownedWorkLifecycle(registry: RuntimeOwnedWorkRegistry = .shared)
        -> ConfigOwnedWorkLifecycle {
        ConfigOwnedWorkLifecycle(registry: registry,
                                 epochProvider: RB6EpochProvider(epoch: epoch))
    }
}

/// Mirrors the bootstrap's own 4-byte fingerprint rule so the domain's
/// requireBinding check runs against REAL accepted-generation identity.
struct RB6HostContext: SkillsHostContextProviding {
    let fingerprint: String
    var appVersionValue: String? = "9.9.9"
    func appVersion() -> String? { appVersionValue }
    func rootFingerprint(epoch: UInt64) -> String? {
        guard AndroidRuntimeBootstrap.currentPumps()?.epoch == epoch else { return nil }
        return fingerprint
    }
}

struct RB6EpochProvider: ConfigRuntimeEpochProviding {
    let epoch: UInt64
    func currentEpoch() -> UInt64? {
        AndroidRuntimeBootstrap.currentPumps()?.epoch == epoch ? epoch : nil
    }
}

struct RB6RouteContext: SkillsMcpRouteContextProviding {
    let token: String
    let generation: UInt64
    func currentRoute() -> RouteBinding? {
        RouteBinding(token: token, generation: generation)
    }
}

/// Test-only network admission OPEN (production ships
/// MCPTransportAdmissionClosed; the loopback fixture is a 127.0.0.1
/// scripted server, never a product path — see the lane's device/TLS
/// qualification gates).
struct RB6TestAdmission: MCPTransportAdmitting {
    var admits: Bool
    var admitsMCPNetwork: Bool { admits }
}

// MARK: - Scripted gateway (canonical mapping enforced, faults injectable)

final class RB6ScriptedGateway: SecretGatewayServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Data] = [:]
    private var _readCount = 0
    private var _writeCount = 0
    private var _deleteCount = 0
    private var registeredFlag: Bool
    var failNextWrite: Error?
    var failNextRead: Error?
    var failNextDelete: Error?

    init(registered: Bool = true, initial: [String: Data] = [:]) {
        registeredFlag = registered
        stored = initial
    }

    var isRegistered: Bool {
        lock.lock(); defer { lock.unlock() }
        return registeredFlag
    }
    func setRegistered(_ value: Bool) {
        lock.lock(); registeredFlag = value; lock.unlock()
    }

    func read(reference: String) async throws -> Data? {
        try lock.withLock {
            _readCount += 1
            if let fault = failNextRead { failNextRead = nil; throw fault }
            guard registeredFlag else { throw SecretGatewayError.needsConfiguration }
            return stored[reference]
        }
    }

    func write(reference: String, value: Data) async throws {
        try lock.withLock {
            _writeCount += 1
            if let fault = failNextWrite { failNextWrite = nil; throw fault }
            guard registeredFlag else { throw SecretGatewayError.needsConfiguration }
            stored[reference] = value
        }
    }

    func delete(reference: String) async throws {
        try lock.withLock {
            _deleteCount += 1
            if let fault = failNextDelete { failNextDelete = nil; throw fault }
            guard registeredFlag else { throw SecretGatewayError.needsConfiguration }
            stored.removeValue(forKey: reference)
        }
    }

    func snapshot(reference: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return stored[reference]
    }
    func counts() -> (reads: Int, writes: Int, deletes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (_readCount, _writeCount, _deleteCount)
    }
    func storedReferences() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return stored.keys.sorted()
    }
}

// MARK: - Canonical synthetic package material (public-safe fixtures)

enum RB6Package {
    static func markdown(name: String = "test-guide") -> String {
        """
        ---
        name: \(name)
        description: Synthetic fixture guide for RB6 qualification.
        ---

        # Steps
        1. Follow the documented workflow.
        """
    }

    static func manifestJSON(id: String, capabilities: [String] = ["workspace.read"],
                             tools: [String] = ["workspace.list"],
                             version: String = "1.0.0",
                             platforms: [String] = ["linux"]) -> String {
        let manifest: [String: Any] = [
            "schemaVersion": 1, "id": id, "version": version,
            "capabilities": capabilities, "tools": tools, "platforms": platforms,
            "scriptRuntime": "none", "pythonPackages": [],
        ]
        let data = try! JSONSerialization.data(withJSONObject: manifest,
                                               options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func writePackage(at root: URL, id: String,
                             manifest: String? = nil,
                             extraFiles: [String: String] = [:],
                             markdown: String? = nil) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let body = markdown ?? Self.markdown()
        try body.write(to: root.appendingPathComponent("SKILL.md"),
                       atomically: true, encoding: .utf8)
        if let manifest {
            try manifest.write(to: root.appendingPathComponent("floe.json"),
                               atomically: true, encoding: .utf8)
        }
        for (path, text) in extraFiles {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func canonicalDigest(at root: URL) throws -> String {
        var files: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return "" }
        for case let url as URL in enumerator where !url.hasDirectoryPath {
            files[String(url.standardizedFileURL.path
                .dropFirst(root.standardizedFileURL.path.count + 1))] =
                try Data(contentsOf: url)
        }
        return SkillPackageValidator.canonicalDigest(files: files)
    }

    /// FinderEnvelope wire body (the ORIGINAL closed shape).
    static func finderEnvelopeJSON(skillID: String, markdown: String? = nil,
                                   manifest: String? = nil,
                                   files: [String: String] = [:]) throws -> Data {
        var object: [String: Any] = ["skillMarkdown": markdown ?? Self.markdown()]
        if let manifest,
           let parsed = try? JSONSerialization.jsonObject(with: Data(manifest.utf8)) as? [String: Any] {
            object["manifest"] = parsed
        }
        if !files.isEmpty {
            var entries: [String: Any] = [:]
            for (path, text) in files {
                entries[path] = [
                    "data": Data(text.utf8).base64EncodedString(),
                    "mimeType": "text/plain",
                ]
            }
            object["files"] = entries
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

// MARK: - Synthetic hub transport (catalog + immutable zip via scripted
// closures, deterministic digests — test source only; the production
// transport is the qualified WebTools adapter).

final class RB6ScriptedHubTransport: SkillsRemoteTransport, @unchecked Sendable {
    struct Package {
        let id: String
        let version: String
        let zip: Data
        let releaseNotes: [String: String]
    }
    var commit = String(repeating: "a", count: 40)
    var catalogBytes: Data?
    var catalogSignature: Data?
    var packages: [String: Package] = [:]
    var failNext: Error?
    private(set) var resolveCalls = 0
    private(set) var fetchPaths: [String] = []

    func resolveCommit(_ source: GitHubSkillSource) async throws -> String {
        if let failure = failNext { self.failNext = nil; throw failure }
        resolveCalls += 1
        return commit
    }

    func fetch(_ source: GitHubSkillSource, commit: String, path: String) async throws -> Data {
        if let failure = failNext { self.failNext = nil; throw failure }
        fetchPaths.append(path)
        if path.hasSuffix("catalog.json"), let catalogBytes { return catalogBytes }
        if path.hasSuffix("catalog.sig"), let catalogSignature { return catalogSignature }
        for package in packages.values where path.hasSuffix("\(package.id).zip") {
            return package.zip
        }
        throw NSError(domain: "RB6Hub", code: 404)
    }

    func fetchFinderEnvelope(url: URL) async throws -> Data {
        if let failure = failNext { self.failNext = nil; throw failure }
        guard let envelope = finderEnvelopeBody else {
            throw NSError(domain: "RB6Hub", code: 410)
        }
        return envelope
    }
    var finderEnvelopeBody: Data?
}

// MARK: - Observing gateway (controlled mailbox physical truth)

/// A controlled `PhysicalObservingSecretGateway` for CAP-SECRET-2
/// qualification: deliveries a per-claim receipt at queue-accept, exposes the
/// INDIVIDUAL snapshot, and lets the test drive the real host completion.
/// Metadata only (claim/epoch/reference/kind/tracked); bytes stay in the
/// synthetic store. This is a test double at the BACKEND seam; the domain
/// code under test is the production implementation.
final class RB6ObservingGateway: AndroidSecretGateway, SecretGatewayServicing,
    PhysicalObservingSecretGateway, @unchecked Sendable
{
    enum DeleteBehavior: Sendable, Equatable {
        case committed
        case claimedOutstanding
        case invalidReference
    }

    private let lock = NSLock()
    private var stored: [String: Data]
    private var claims: [Int64: PhysicalOperationSnapshot] = [:]
    private var waiters: [Int64: [CheckedContinuation<PhysicalOperationSnapshot, Never>]] = [:]
    private var nextClaim: Int64 = 1
    private var readCount = 0
    private var writeCount = 0
    private var deleteCount = 0
    private var lastClaimValue: Int64?

    /// Mutable for tests; read under the lock in the physical paths.
    private var _deleteBehavior: DeleteBehavior = .committed
    var deleteBehavior: DeleteBehavior {
        get { lock.withLock { _deleteBehavior } }
        set { lock.withLock { _deleteBehavior = newValue } }
    }
    var isRegistered: Bool = true

    init(initial: [String: Data] = [:]) {
        stored = initial
    }

    // MARK: CRUD

    func read(reference: String) async throws -> Data? {
        try lock.withLock {
            readCount += 1
            guard isRegistered else { throw SecretGatewayError.needsConfiguration }
            return stored[reference]
        }
    }

    func write(reference: String, value: Data) async throws {
        try lock.withLock {
            writeCount += 1
            guard isRegistered else { throw SecretGatewayError.needsConfiguration }
            stored[reference] = value
        }
    }

    func delete(reference: String) async throws {
        try lock.withLock {
            deleteCount += 1
            guard isRegistered else { throw SecretGatewayError.needsConfiguration }
            stored.removeValue(forKey: reference)
        }
    }

    // MARK: Physical observation

    func readObserved(reference: String,
                      onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?)
        async throws -> Data?
    {
        let receipt = makeReceipt(reference: reference, kind: .read)
        onQueued?(receipt)
        complete(claim: receipt.claim, status: 1)
        return try await read(reference: reference)
    }

    func writeObserved(reference: String, value: Data,
                       onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?)
        async throws
    {
        let receipt = makeReceipt(reference: reference, kind: .write)
        onQueued?(receipt)
        try await write(reference: reference, value: value)
        complete(claim: receipt.claim, status: 3)
    }

    func deleteObserved(reference: String,
                        onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?)
        async throws
    {
        let behavior = deleteBehavior
        if behavior == .invalidReference {
            // Pre-ticket validation refusal: NO receipt is delivered (the
            // ticket never existed) — exactly the mailbox's path.
            try await lock.withLock { deleteCount += 1 }
            throw SecretBackendError.invalidReference
        }
        let receipt = makeReceipt(reference: reference, kind: .delete)
        onQueued?(receipt)
        switch behavior {
        case .claimedOutstanding:
            lock.withLock { claims[receipt.claim] = .claimedOutstanding }
            throw SecretBackendError.dispatcherUnresponsive
        case .committed, .invalidReference:
            try await delete(reference: reference)
            complete(claim: receipt.claim, status: 4)
        }
    }

    func physicalSnapshot(claim: Int64) -> PhysicalOperationSnapshot {
        lock.withLock { claims[claim] ?? .notRecorded }
    }

    func resolvePhysical(claim: Int64) -> Bool {
        lock.withLock {
            guard let snapshot = claims[claim] else { return true }
            switch snapshot {
            case .settled, .neverDispatched:
                claims.removeValue(forKey: claim)
                return true
            case .queued, .claimedOutstanding, .notRecorded:
                return false
            }
        }
    }

    func awaitPhysicalSettlement(claim: Int64) async -> PhysicalOperationSnapshot {
        await withCheckedContinuation { continuation in
            var immediate: PhysicalOperationSnapshot?
            lock.withLock {
                if let snapshot = claims[claim] {
                    switch snapshot {
                    case .settled, .neverDispatched:
                        immediate = snapshot
                    case .queued, .claimedOutstanding, .notRecorded:
                        waiters[claim, default: []].append(continuation)
                    }
                } else {
                    immediate = .notRecorded
                }
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    // MARK: Test control

    func complete(claim: Int64, status: Int32) {
        var continuations: [CheckedContinuation<PhysicalOperationSnapshot, Never>] = []
        lock.withLock {
            let snapshot = PhysicalOperationSnapshot.settled(status: status)
            claims[claim] = snapshot
            continuations = waiters.removeValue(forKey: claim) ?? []
        }
        for continuation in continuations {
            continuation.resume(returning: .settled(status: status))
        }
    }

    var lastClaim: Int64? { lock.withLock { lastClaimValue } }

    func completeLastClaim(status: Int32) {
        guard let claim = lastClaim else { return }
        complete(claim: claim, status: status)
    }

    func storedData(reference: String) -> Data? {
        lock.withLock { stored[reference] }
    }

    func counts() -> (reads: Int, writes: Int, deletes: Int) {
        lock.withLock { (readCount, writeCount, deleteCount) }
    }

    private func makeReceipt(reference: String,
                             kind: PhysicalOperationKind) -> PhysicalOperationReceipt {
        let claim = lock.withLock { () -> Int64 in
            let value = nextClaim
            nextClaim += 1
            lastClaimValue = value
            claims[value] = .queued
            return value
        }
        return PhysicalOperationReceipt(claim: claim, epoch: 1,
                                        reference: reference, kind: kind,
                                        tracked: true)
    }
}

extension RB6ScriptedGateway: AndroidSecretGateway {}
