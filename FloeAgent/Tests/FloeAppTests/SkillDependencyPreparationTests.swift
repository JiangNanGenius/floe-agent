// FloeAppTests — official Skill dependency preparation center.
//
// Locks the reviewed dependency channel end to end with fakes at every
// injected seam (authority / environment / launch generation / guest
// operations / runtime-component probe / install-time prefetch seams). None
// of these tests labels fakes as a real guest: the real TinyEMU install and
// readback loop remains Main-owned qualification. What IS locked here is the
// contract:
//   * authority: forged/disabled/edited identity and formal-shape drift
//     refuse; recording itself installs nothing;
//   * plan binding: an immutable (environmentID, runID)-bound plan pinning
//     package version + contentDigest + declaration digest;
//   * target selection: profile architectures are matched against the real
//     local Linux backend (riscv64, injectable): non-matching profiles never
//     plan/prefetch/mutate, contradicting exact pins across matching profiles
//     refuse before any transaction, identical duplicates reuse;
//   * wheel store: verified bytes persist under the REAL canonical PEP 427
//     wheel name with a spec+filename+sha256+size binding, reuse is digest-
//     revalidated and replaced on contradiction, and a signed pip lock binds
//     the fetch, the cache and pip's own --require-hashes install mode;
//   * preparation: exact managed pins only, collision readback BEFORE any
//     mutation (no silent downgrade ever), already-verified pins reuse
//     without mutation, required-not-ready refuses only this skill's
//     invocation while optional gaps annotate and proceed;
//   * receipts: bound to the launch generation (boot rotation forces a fresh
//     re-verify) and to the exact package + descriptor pair (an update
//     landing mid-run revokes the stale binding honestly — the running
//     invocation stays pinned to the bytes it verified);
//   * coalescing/cancellation: one owned preparation per identity serves all
//     waiters; a cancelled waiter detaches, and the last departing waiter
//     cancels and joins; releaseEnvironment fences the whole environment;
//   * uninstall: ownership records only — the operations protocol exposes no
//     removal verbs at all (no automatic apt/pip/npm delete);
//   * global install: the shared-store prefetch (download-only host wheel
//     audit + GitHub-only component artifact cache) runs for what it can
//     honestly prepare, apt/npm/font record an explicit awaiting-target
//     state, failures are kept honestly, the status persists across a
//     simulated restart (new actor, same store), cache bytes are reused and
//     re-verified — and prefetch is never a readiness claim.

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeExecution
import FloeSkills
import FloeTools
@testable import FloeApp

// MARK: - Helpers

private func makeTempDirectory(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-skill-dep-\(label)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A canonical-shape static ELF64 RISC-V ET_EXEC fixture for the
/// runtime-component prefetch gate (same shape the component tests use).
private func makeELF64Bytes() -> Data {
    var bytes = Data(count: 64 + 56)
    bytes[0] = 0x7F; bytes[1] = UInt8(ascii: "E"); bytes[2] = UInt8(ascii: "L"); bytes[3] = UInt8(ascii: "F")
    bytes[4] = 2; bytes[5] = 1; bytes[6] = 1
    func put16(_ offset: Int, _ value: UInt16) {
        bytes[offset] = UInt8(value & 0xFF); bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
    }
    func put32(_ offset: Int, _ value: UInt32) {
        put16(offset, UInt16(value & 0xFFFF)); put16(offset + 2, UInt16((value >> 16) & 0xFFFF))
    }
    func put64(_ offset: Int, _ value: UInt64) {
        put32(offset, UInt32(value & 0xFFFFFFFF)); put32(offset + 4, UInt32((value >> 32) & 0xFFFFFFFF))
    }
    put16(16, 2); put16(18, 243); put32(20, 1)
    put64(32, 64); put16(54, 56); put16(56, 1)
    put32(64, 1) // PT_LOAD
    return bytes
}

private func makeEngineDescriptorBytes(engine: Data) throws -> Data {
    let version = "0.1.17+floe.1.0.0"
    let object: [String: Any] = [
        "schemaVersion": 1,
        "componentID": "impeccable-engine",
        "componentVersion": version,
        "minimumAppVersion": "1.7.59",
        "target": [
            "os": "linux", "arch": "riscv64",
            "triple": "riscv64gc-unknown-linux-musl",
            "format": "elf64-little-riscv-exec-static"
        ],
        "artifact": [
            "path": "engines/impeccable/dist/impeccable-\(version)/riscv64gc-unknown-linux-musl/floe-impeccable",
            "size": engine.count,
            "sha256": FloeDigest.sha256Hex(engine)
        ],
        "captureContract": ["version": 1, "sha256": String(repeating: "c", count: 64)]
    ]
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

/// Cancellation-aware gate: preparation verbs block here until released or
/// until the owned preparation's cancellation actually lands (the production
/// guest verbs are all token-cancellable; this fake mirrors that so the
/// cancel+join promise is testable and never deadlocks).
private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    func release() { lock.lock(); released = true; lock.unlock() }
    var isReleased: Bool { lock.lock(); defer { lock.unlock() }; return released }
    func wait(cancellation: CancellationToken?) async throws {
        while !isReleased {
            if Task.isCancelled || cancellation?.isCancelled == true { throw CancellationError() }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        if Task.isCancelled || cancellation?.isCancelled == true { throw CancellationError() }
    }
}

// MARK: - Scripted guest operations

/// Inventory is split into OWNED (writable venv) rows and INHERITED
/// (`--system-site-packages`) rows exactly like `LinuxGuestPythonDistribution
/// .writable`: conflicts may only be raised against owned pins, inherited
/// versions are reusable at equality and shadowable (never removable — the
/// protocol has no removal verbs). Ensure verbs mutate the owned layer and
/// leave the inherited layer byte-unchanged for preserved evidence.
private final class FakeOperations: SkillDependencyPackageOperating, @unchecked Sendable {
    private struct Failure: Error { let reason: String }
    private let lock = NSLock()
    private var pythonOwned: [String: String] = [:]
    private var pythonSystem: [String: String] = [:]
    private var nodeMap: [String: String] = [:]
    private var aptMap: [String: String] = [:]
    private var pythonCalls: [String] = []
    private var pythonHashCalls: [(String, [String])] = []
    private var pythonPinsCalls: [[(String, [String])]] = []
    private var aptCalls: [(String, String)] = []
    private var npmCalls: [String] = []
    private var fontCalls: [(String, String)] = []
    private var pythonFailure: Failure?
    private var aptFailure: Failure?
    private var npmFailure: Failure?
    private var fontProbePasses = true
    var gate: ContinuationGate?

    func setPythonInitial(_ map: [String: String]) { lock.withLock { pythonOwned = map; pythonSystem = [:] } }
    /// Inherited system-site rows with an EMPTY owned layer: an older apt
    /// version may not block the reviewed venv pin.
    func setPythonSystemInitial(_ map: [String: String]) { lock.withLock { pythonSystem = map; pythonOwned = [:] } }
    func setPythonOwnedInitial(_ map: [String: String]) { lock.withLock { pythonOwned = map } }
    var pythonSystemSnapshot: [String: String] { lock.withLock { pythonSystem } }
    var pythonOwnedSnapshot: [String: String] { lock.withLock { pythonOwned } }
    func setAptInitial(_ map: [String: String]) { lock.withLock { aptMap = map } }
    func setNodeInitial(_ map: [String: String]) { lock.withLock { nodeMap = map } }
    func setPythonFailure(_ reason: String?) { lock.withLock { pythonFailure = reason.map { Failure(reason: $0) } } }
    func setAptFailure(_ reason: String?) { lock.withLock { aptFailure = reason.map { Failure(reason: $0) } } }
    func setNpmFailure(_ reason: String?) { lock.withLock { npmFailure = reason.map { Failure(reason: $0) } } }
    func setFontProbe(_ passes: Bool) { lock.withLock { fontProbePasses = passes } }
    var pythonEnsureCalls: [String] { lock.withLock { pythonCalls } }
    var pythonHashEnsureCalls: [(String, [String])] { lock.withLock { pythonHashCalls } }
    var pinsTransactions: [[(String, [String])]] { lock.withLock { pythonPinsCalls } }
    var counts: (python: Int, apt: Int, npm: Int, font: Int) {
        lock.withLock { (pythonCalls.count + pythonPinsCalls.reduce(0) { $0 + $1.count }, aptCalls.count, npmCalls.count, fontCalls.count) }
    }

    func pythonInstalledVersions(environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> [String: String] {
        lock.withLock { pythonSystem.merging(pythonOwned) { _, new in new } }
    }

    func pythonOwnedVenvVersions(environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> [String: String]? {
        lock.withLock { pythonOwned }
    }

    func pythonEnsure(spec: String, hashes: [String], environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String {
        try await gate?.wait(cancellation: cancellation)
        if let failure = lock.withLock({ pythonFailure }) { throw failure }
        let parts = spec.split(separator: "==", maxSplits: 1).map(String.init)
        lock.withLock {
            pythonCalls.append(spec)
            pythonHashCalls.append((spec, hashes))
            if parts.count == 2 { pythonOwned[parts[0].lowercased()] = parts[1] }
        }
        return "installVerify ok \(spec)"
    }

    func pythonInstallPins(_ pins: [(spec: String, hashes: [String])], environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String {
        try await gate?.wait(cancellation: cancellation)
        if let failure = lock.withLock({ pythonFailure }) { throw failure }
        lock.withLock {
            pythonPinsCalls.append(pins.map { ($0.spec, $0.hashes) })
            for pin in pins {
                let parts = pin.spec.split(separator: "==", maxSplits: 1).map(String.init)
                if parts.count == 2 { pythonOwned[parts[0].lowercased()] = parts[1] }
            }
        }
        return "installVerify ok closure \(pins.count)"
    }

    func aptInstalledVersion(identity: String, environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String? {
        lock.withLock { aptMap[identity] }
    }

    func aptEnsure(identity: String, version: String, environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String {
        try await gate?.wait(cancellation: cancellation)
        if let failure = lock.withLock({ aptFailure }) { throw failure }
        lock.withLock {
            aptCalls.append((identity, version))
            aptMap[identity] = version
        }
        return "dpkg \(identity)=\(version)"
    }

    func nodeInstalledVersions(environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> [String: String] {
        lock.withLock { nodeMap }
    }

    func npmEnsure(spec: String, environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String {
        try await gate?.wait(cancellation: cancellation)
        if let failure = lock.withLock({ npmFailure }) { throw failure }
        guard let at = spec.lastIndex(of: "@") else { throw Failure(reason: "bad spec") }
        let name = String(spec[..<at])
        let version = String(spec[spec.index(after: at)...])
        lock.withLock {
            npmCalls.append(spec)
            nodeMap[name] = version
        }
        return "node \(spec)"
    }

    func fontEnsure(identity: String, version: String, environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String {
        try await gate?.wait(cancellation: cancellation)
        if let failure = lock.withLock({ aptFailure }) { throw failure }
        lock.withLock {
            fontCalls.append((identity, version))
            aptMap[identity] = version
        }
        guard lock.withLock({ fontProbePasses }) else {
            throw Failure(reason: "the pinned font installed but the fixed CJK availability probe did not pass")
        }
        return "dpkg \(identity)=\(version), cjk-probe ok"
    }

    func cjkProbePasses(environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> Bool {
        lock.withLock { fontProbePasses }
    }
}

// MARK: - Live boxes (simulate disable/edit/update/boot at the seams)

private final class AuthorityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SkillDependencyAuthority?
    init(_ value: SkillDependencyAuthority?) { current = value }
    var value: SkillDependencyAuthority? { lock.withLock { current } }
    func set(_ value: SkillDependencyAuthority?) { lock.withLock { current = value } }
}

private final class GenerationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64
    init(_ value: UInt64) { self.value = value }
    func get() -> UInt64 { lock.withLock { value } }
    func bump() { lock.withLock { value += 1 } }
}

private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: String?
    init(_ reason: String?) { self.reason = reason }
    func get() -> String? { lock.withLock { reason } }
    func setReady() { lock.withLock { reason = nil } }
    func setDeferred(_ reason: String) { lock.withLock { self.reason = reason } }
}

/// The canonical PEP 427 basename a PyPI pure-wheel artifact for an exact
/// `name==version` spec must carry (distribution component uses `_` for
/// canonical separator runs).
private func canonicalWheelName(spec: String) -> String {
    let parts = spec.split(separator: "==", maxSplits: 1).map(String.init)
    let name = parts.count == 2 ? parts[0] : spec
    let version = parts.count == 2 ? parts[1] : "0"
    let wheelName = name.lowercased().replacingOccurrences(of: "[-_.]+", with: "_", options: .regularExpression)
    return "\(wheelName)-\(version)-py3-none-any.whl"
}

private func makeWheelBundle(spec: String, filename: String? = nil) -> SkillDependencyWheelBundle {
    let bytes = Data("fake pure wheel payload for \(spec)".utf8)
    return SkillDependencyWheelBundle(
        spec: spec,
        filename: filename ?? canonicalWheelName(spec: spec),
        sha256: FloeDigest.sha256Hex(bytes),
        size: bytes.count,
        bytes: bytes
    )
}

// MARK: - Harness

private struct Harness {
    let center: SkillDependencyPreparationCenter
    let operations: FakeOperations
    let environmentID: String
    let persistenceRoot: URL
    let engine: Data
    let engineDescriptorBytes: Data
    let declarationBytes: Data
    let authorityBox: AuthorityBox
    let generationBox: GenerationBox
    let probeBox: ProbeBox
    let environment: ToolEnvironment
    let wheelStore: URL
}

private func pipOnly() -> String {
    """
    {"schemaVersion":1,"profiles":[{"id":"linux-guest","target":{"os":"linux","architectures":["any"]},"requirements":[{"kind":"pip","name":"pypdf","version":"5.4.0","purpose":"PDF merge step.","required":true}]}]}
    """
}

/// The same declaration with a signed wheel lock attached (the lock lives in
/// the package inventory; the harness files it under the pinned path).
private func pipWithLock() -> String {
    """
    {"schemaVersion":1,"profiles":[{"id":"linux-guest","target":{"os":"linux","architectures":["any"]},"requirements":[{"kind":"pip","name":"pypdf","version":"5.4.0","purpose":"PDF merge step.","required":true,"lockfile":"references/requirements.lock.txt"}]}]}
    """
}

private func makeHarness(requirementsJSON: String, lockText: String? = nil) -> Harness {
    let operations = FakeOperations()
    let persistenceRoot = makeTempDirectory("store")
    let environmentID = "env-" + UUID().uuidString
    let environment = ToolEnvironment(
        id: environmentID,
        writableLayerURL: makeTempDirectory("layer"),
        layerURLs: [],
        variables: [:]
    )
    let declarationBytes = Data(requirementsJSON.utf8)
    let engine = makeELF64Bytes()
    let engineDescriptorBytes = try! makeEngineDescriptorBytes(engine: engine)
    var packageFiles: [String: Data] = [:]
    packageFiles["references/dependencies.json"] = declarationBytes
    packageFiles["references/engine-dependency.json"] = engineDescriptorBytes
    if let lockText {
        packageFiles["references/requirements.lock.txt"] = Data(lockText.utf8)
    }
    let authority = SkillDependencyAuthority(
        skillID: "dep-skill",
        packageVersion: "2.1.0",
        contentDigest: String(repeating: "d", count: 64),
        packageSHA256: String(repeating: "e", count: 64),
        catalogSHA256: String(repeating: "f", count: 64),
        reviewSHA256: String(repeating: "0", count: 64),
        publicationCommit: String(repeating: "1", count: 40),
        feedStatus: .production,
        reviewDecision: .approve,
        feedSignatureKeyID: CuratedSkillHub.productionKeyID,
        reviewKeyID: CuratedSkillHub.productionKeyID,
        hubRepository: CuratedSkillHub.hubRepository,
        declarationBytes: declarationBytes,
        declarationSHA256: FloeDigest.sha256Hex(declarationBytes),
        packageFiles: packageFiles
    )
    let authorityBox = AuthorityBox(authority)
    let generationBox = GenerationBox(7)
    let probeBox = ProbeBox(nil)
    let center = SkillDependencyPreparationCenter(
        authorityProvider: { _ in authorityBox.value },
        environmentResolver: { id in id == environmentID ? environment : nil },
        launchGeneration: { _ in generationBox.get() },
        operations: operations,
        runtimeComponentProbe: { _, _, _ in probeBox.get() },
        appVersion: { "1.7.60" },
        persistenceRoot: persistenceRoot
    )
    return Harness(
        center: center, operations: operations, environmentID: environmentID,
        persistenceRoot: persistenceRoot, engine: engine,
        engineDescriptorBytes: engineDescriptorBytes, declarationBytes: declarationBytes,
        authorityBox: authorityBox, generationBox: generationBox,
        probeBox: probeBox, environment: environment,
        wheelStore: makeTempDirectory("wheel-store")
    )
}

@Suite("FloeApp.SkillDependencyPreparation", .serialized)
struct SkillDependencyPreparationTests {
    // MARK: - Plan recording

    @Test func recordPlanRequiresEnvironmentRunAndAuthority() async {
        let harness = makeHarness(requirementsJSON: pipOnly())
        let authority = harness.authorityBox.value!
        let noEnvironment = await harness.center.recordPlan(skillID: "dep-skill", environmentID: nil, runID: UUID(), authority: authority)
        guard case .rejected(let reason) = noEnvironment, reason == SkillDependencyReason.noEnvironment else {
            Issue.record("expected noEnvironment"); return
        }
        let noRun = await harness.center.recordPlan(skillID: "dep-skill", environmentID: harness.environmentID, runID: nil, authority: authority)
        guard case .rejected(let second) = noRun, second == SkillDependencyReason.noRun else {
            Issue.record("expected noRun"); return
        }
        let noAuthority = await harness.center.recordPlan(skillID: "dep-skill", environmentID: harness.environmentID, runID: UUID(), authority: nil)
        guard case .rejected(let third) = noAuthority, third == SkillDependencyReason.authorizationUnavailable else {
            Issue.record("expected authorizationUnavailable"); return
        }
    }

    @Test func forgedAuthorityShapeRefuses() async {
        let harness = makeHarness(requirementsJSON: pipOnly())
        let good = harness.authorityBox.value!
        let forged = SkillDependencyAuthority(
            skillID: good.skillID, packageVersion: good.packageVersion,
            contentDigest: good.contentDigest, packageSHA256: good.packageSHA256,
            catalogSHA256: good.catalogSHA256, reviewSHA256: good.reviewSHA256,
            publicationCommit: good.publicationCommit, feedStatus: good.feedStatus,
            reviewDecision: .reject, feedSignatureKeyID: good.feedSignatureKeyID,
            reviewKeyID: "foreign-key", hubRepository: good.hubRepository,
            declarationBytes: good.declarationBytes, declarationSHA256: good.declarationSHA256,
            packageFiles: good.packageFiles
        )
        let outcome = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: UUID(), authority: forged
        )
        guard case .rejected(let reason) = outcome, reason == SkillDependencyReason.authorizationUnavailable else {
            Issue.record("formal shape must refuse: \(outcome)"); return
        }
    }

    @Test func recordedPlanStateAndPersistence() async {
        let harness = makeHarness(requirementsJSON: pipOnly())
        let outcome = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: UUID(),
            authority: harness.authorityBox.value
        )
        guard case .recorded = outcome else { Issue.record("expected recorded"); return }
        let state = await harness.center.state(environmentID: harness.environmentID, skillID: "dep-skill")
        #expect(state.planRecorded && state.sourceAuthorized)
        let stored = harness.persistenceRoot.appendingPathComponent("dep-skill.json")
        #expect(FileManager.default.fileExists(atPath: stored.path))
    }

    @Test func newerSchemaFailsCompatibilityNotReadiness() async {
        let harness = makeHarness(requirementsJSON: pipOnly().replacing("\"schemaVersion\":1", with: "\"schemaVersion\":2"))
        let outcome = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: UUID(),
            authority: harness.authorityBox.value
        )
        guard case .rejected(let reason) = outcome, reason == SkillDependencyReason.unsupportedSchema else {
            Issue.record("expected unsupportedSchema, got \(outcome)"); return
        }
        let invoke = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: UUID(), cancellation: nil
        )
        guard case .refused = invoke else { Issue.record("no plan may exist for an unsupported schema"); return }
    }

    // MARK: - Invocation gate

    @Test func invokeWithoutPlanIsHonestNoRunRefusal() async {
        let harness = makeHarness(requirementsJSON: pipOnly())
        let outcome = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: UUID(), cancellation: nil
        )
        guard case .refused(let reason) = outcome, reason == SkillDependencyReason.noRun else {
            Issue.record("expected noRun"); return
        }
    }

    @Test func pipExactPinInstallsAndReadsBack() async throws {
        let harness = makeHarness(requirementsJSON: pipOnly())
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID,
            authority: harness.authorityBox.value
        )
        let outcome = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
        )
        guard case .ready(let annotation) = outcome else { Issue.record("expected ready: \(outcome)"); return }
        #expect(annotation.contains("pip:pypdf@5.4.0"))
        #expect(harness.operations.pythonEnsureCalls == ["pypdf==5.4.0"])
    }

    @Test func alreadyVerifiedPinSkipsMutation() async throws {
        let harness = makeHarness(requirementsJSON: pipOnly())
        harness.operations.setPythonInitial(["pypdf": "5.4.0"])
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID,
            authority: harness.authorityBox.value
        )
        let outcome = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
        )
        guard case .ready(let annotation) = outcome else { Issue.record("expected ready"); return }
        #expect(annotation.contains("already verified"))
        #expect(harness.operations.counts.python == 0)
    }

    @Test func sameEnvironmentConflictRefusesWithoutAnyMutation() async throws {
        let harness = makeHarness(requirementsJSON: pipOnly())
        harness.operations.setPythonInitial(["pypdf": "4.2.0"])
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID,
            authority: harness.authorityBox.value
        )
        let outcome = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
        )
        guard case .refused(let reason) = outcome else { Issue.record("expected refusal"); return }
        #expect(reason.contains("conflicts with the reviewed pin"))
        #expect(reason.contains("no silent downgrade or upgrade"))
        #expect(harness.operations.counts.python == 0)
    }

    @Test func aptCollisionRefusesBeforeAnyTransaction() async throws {
        let json = """
        {"schemaVersion":1,"profiles":[{"id":"debian","target":{"os":"linux","architectures":["riscv64"]},"requirements":[{"kind":"apt","name":"python3-scipy","version":"1.15.3-1","purpose":"Numeric.","required":true},{"kind":"font","name":"fonts-noto-cjk","version":"1:20240730+repack1-1","purpose":"CJK labels.","required":false}]}]}
        """
        let harness = makeHarness(requirementsJSON: json)
        harness.operations.setAptInitial(["python3-scipy": "1.11.4-1"])
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID,
            authority: harness.authorityBox.value
        )
        let outcome = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
        )
        guard case .refused(let reason) = outcome else { Issue.record("expected refusal, got \(outcome)"); return }
        #expect(reason.contains("python3-scipy"))
        #expect(harness.operations.counts.apt == 0)
    }

    @Test func optionalGapAnnotatesWhileRequiredSucceeds() async throws {
        let json = """
        {"schemaVersion":1,"profiles":[{"id":"linux-guest","target":{"os":"linux","architectures":["any"]},"requirements":[{"kind":"pip","name":"pypdf","version":"5.4.0","purpose":"PDF.","required":true},{"kind":"font","name":"fonts-noto-cjk","version":"1:20240730+repack1-1","purpose":"CJK labels.","required":false}]}]}
        """
        let harness = makeHarness(requirementsJSON: json)
        harness.operations.setFontProbe(false)
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID,
            authority: harness.authorityBox.value
        )
        let outcome = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
        )
        guard case .ready(let annotation) = outcome else { Issue.record("expected ready with annotation, got \(outcome)"); return }
        #expect(annotation.contains("optional dependency font:fonts-noto-cjk is not available"))
        #expect(annotation.contains("pip:pypdf@5.4.0"))
    }

    @Test func requiredFailureRefusesAndLeavesHonestState() async throws {
        let harness = makeHarness(requirementsJSON: pipOnly())
        harness.operations.setPythonFailure("guest pip budget exhausted")
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID,
            authority: harness.authorityBox.value
        )
        let outcome = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
        )
        guard case .refused(let reason) = outcome else { Issue.record("expected refusal"); return }
        #expect(reason.contains("required dependency pip:pypdf is not ready"))
        let state = await harness.center.state(environmentID: harness.environmentID, skillID: "dep-skill")
        #expect(state.planRecorded && !state.readbackVerified)
        #expect(state.deferredReason?.contains("required dependency") == true)
    }

    // MARK: - Receipt binding / boot rotation / update pinning

    @Test func receiptsReuseWithinGenerationAndRevalidateAfterBoot() async throws {
        let harness = makeHarness(requirementsJSON: pipOnly())
        let firstRun = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: firstRun,
            authority: harness.authorityBox.value
        )
        _ = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: firstRun, cancellation: nil
        )
        #expect(harness.operations.counts.python == 1)
        let secondRun = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: secondRun,
            authority: harness.authorityBox.value
        )
        let reuse = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: secondRun, cancellation: nil
        )
        guard case .ready = reuse else { Issue.record("expected reuse"); return }
        #expect(harness.operations.counts.python == 1)
        // Guest restart: generation-bound receipts cannot cross boots; the
        // pin re-reads (here it is already installed, so no new mutation, but
        // the fresh verified evidence replaces the stale receipt).
        harness.generationBox.bump()
        let thirdRun = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: thirdRun,
            authority: harness.authorityBox.value
        )
        let afterBoot = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: thirdRun, cancellation: nil
        )
        guard case .ready(let annotation) = afterBoot else { Issue.record("expected ready"); return }
        #expect(annotation.contains("already verified"))
        #expect(harness.operations.counts.python == 1)
    }

    @Test func livePackageReplacementUnderARunningPlanRevokesStaleBinding() async throws {
        let harness = makeHarness(requirementsJSON: pipOnly())
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID,
            authority: harness.authorityBox.value
        )
        let replacedGood = harness.authorityBox.value!
        let replaced = SkillDependencyAuthority(
            skillID: replacedGood.skillID, packageVersion: "2.2.0", // update landed mid-run
            contentDigest: String(repeating: "9", count: 64), packageSHA256: replacedGood.packageSHA256,
            catalogSHA256: replacedGood.catalogSHA256, reviewSHA256: replacedGood.reviewSHA256,
            publicationCommit: replacedGood.publicationCommit, feedStatus: replacedGood.feedStatus,
            reviewDecision: replacedGood.reviewDecision, feedSignatureKeyID: replacedGood.feedSignatureKeyID,
            reviewKeyID: replacedGood.reviewKeyID, hubRepository: replacedGood.hubRepository,
            declarationBytes: replacedGood.declarationBytes, declarationSHA256: replacedGood.declarationSHA256,
            packageFiles: replacedGood.packageFiles
        )
        harness.authorityBox.set(replaced)
        let outcome = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
        )
        guard case .refused(let reason) = outcome, reason == SkillDependencyReason.planStale else {
            Issue.record("running invocation must stay pinned to the bytes it verified"); return
        }
        let again = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
        )
        guard case .refused(let second) = again, second == SkillDependencyReason.noRun else {
            Issue.record("stale plan must be dropped; re-read required"); return
        }
    }

    @Test func revokedAuthorizationRefusesFurtherUse() async throws {
        let harness = makeHarness(requirementsJSON: pipOnly())
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID,
            authority: harness.authorityBox.value
        )
        harness.authorityBox.set(nil) // disable/edit/uninstall drift
        let outcome = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
        )
        guard case .refused(let reason) = outcome, reason == SkillDependencyReason.planStale else {
            Issue.record("expected stale-plan refusal"); return
        }
    }

    @Test func unresolvableEnvironmentIsRefusedHonestly() async throws {
        let harness = makeHarness(requirementsJSON: pipOnly())
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: "env-ghost", runID: runID,
            authority: harness.authorityBox.value
        )
        let outcome = await harness.center.invoke(
            skillID: "dep-skill", environmentID: "env-ghost", runID: runID, cancellation: nil
        )
        guard case .refused(let reason) = outcome, reason == SkillDependencyReason.environmentUnavailable else {
            Issue.record("expected environmentUnavailable, got \(outcome)"); return
        }
    }

    // MARK: - runtimeComponent observation (allowlist/hook unchanged)

    @Test func runtimeComponentReadinessIsObservedNotForced() async throws {
        let json = """
        {"schemaVersion":1,"profiles":[{"id":"engine","target":{"os":"linux","architectures":["riscv64"]},"requirements":[{"kind":"runtimeComponent","componentDescriptorPath":"references/engine-dependency.json","purpose":"Engine.","required":true}]}]}
        """
        let harness = makeHarness(requirementsJSON: json)
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID,
            authority: harness.authorityBox.value
        )
        harness.probeBox.setDeferred("the resolved environment has no write layer")
        let deferred = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
        )
        guard case .refused(let reason) = deferred else { Issue.record("expected refusal while not probed"); return }
        #expect(reason.contains("runtimeComponent"))
        harness.probeBox.setReady()
        let ready = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
        )
        guard case .ready(let annotation) = ready else { Issue.record("expected ready"); return }
        #expect(annotation.contains("component probed"))
        let counts = harness.operations.counts
        #expect(counts.python == 0 && counts.apt == 0 && counts.npm == 0 && counts.font == 0)
    }

    // MARK: - Coalescing + cancellation

    @Test func concurrentWaitersCoalesceIntoOneOwnedPreparation() async throws {
        let harness = makeHarness(requirementsJSON: pipOnly())
        let gate = ContinuationGate()
        harness.operations.gate = gate
        let runOne = UUID()
        let runTwo = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runOne,
            authority: harness.authorityBox.value
        )
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runTwo,
            authority: harness.authorityBox.value
        )
        async let first = harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runOne, cancellation: nil
        )
        try await Task.sleep(nanoseconds: 30_000_000)
        async let second = harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runTwo, cancellation: nil
        )
        try await Task.sleep(nanoseconds: 30_000_000)
        gate.release()
        let one = await first
        let two = await second
        guard case .ready = one, case .ready = two else {
            Issue.record("both waiters must receive the coalesced result"); return
        }
        #expect(harness.operations.counts.python == 1)
    }

    @Test func lastDepartingWaiterCancelsAndJoinsTheOwnedPreparation() async throws {
        let harness = makeHarness(requirementsJSON: pipOnly())
        let gate = ContinuationGate()
        harness.operations.gate = gate
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID,
            authority: harness.authorityBox.value
        )
        let waiter = Task {
            await harness.center.invoke(
                skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
            )
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        waiter.cancel()
        let outcome = await waiter.value
        guard case .refused(let reason) = outcome, reason == SkillDependencyReason.cancelled else {
            Issue.record("cancelled waiter returns honestly: \(outcome)"); return
        }
        // The join completed before the refusal returned (no deadlock): the
        // owned preparation was cancelled and never reached a verified fact.
        #expect(harness.operations.counts.python == 0)
        gate.release()
    }

    @Test func releaseEnvironmentFencesPlansAndReceipts() async throws {
        let harness = makeHarness(requirementsJSON: pipOnly())
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID,
            authority: harness.authorityBox.value
        )
        _ = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
        )
        await harness.center.releaseEnvironment(harness.environmentID)
        let outcome = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
        )
        guard case .refused(let reason) = outcome, reason == SkillDependencyReason.noRun else {
            Issue.record("released environment must refuse"); return
        }
    }

    // MARK: - Uninstall: ownership only

    @Test func forgetSkillClearsOwnershipButKeepsEverythingInstalled() async throws {
        let harness = makeHarness(requirementsJSON: pipOnly())
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID,
            authority: harness.authorityBox.value
        )
        _ = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
        )
        #expect(harness.operations.counts.python == 1)
        await harness.center.forgetSkill("dep-skill")
        let stored = harness.persistenceRoot.appendingPathComponent("dep-skill.json")
        #expect(!FileManager.default.fileExists(atPath: stored.path))
        let state = await harness.center.state(environmentID: harness.environmentID, skillID: "dep-skill")
        #expect(!state.planRecorded)
        // The operations protocol exposes no removal verbs at all, and none
        // ran: the environment keeps its packages exactly as required by the
        // ownership-only contract.
    }

    // MARK: - Global install shared-store prefetch (download-only)

    @Test func globalInstallPrefetchesAuditableKindsAndMarksTargetWaiters() async throws {
        let json = """
        {"schemaVersion":1,"profiles":[{"id":"linux-guest","target":{"os":"linux","architectures":["any"]},"requirements":[{"kind":"pip","name":"pypdf","version":"5.4.0","purpose":"PDF.","required":true},{"kind":"apt","name":"python3-scipy","version":"1.15.3-1","purpose":"Numeric.","required":true},{"kind":"runtimeComponent","componentDescriptorPath":"references/engine-dependency.json","purpose":"Engine.","required":false}]}]}
        """
        let harness = makeHarness(requirementsJSON: json)
        let storeRoot = makeTempDirectory("component-cache")
        let wheelStore = makeTempDirectory("wheel-store")
        let lock = NSLock()
        let fetchedSpecs = LockedStringBox()
        let fetchedEngine = harness.engine
        // Rebuild the center with the wheel seams (they are init-time).
        let center = SkillDependencyPreparationCenter(
            authorityProvider: { _ in harness.authorityBox.value },
            environmentResolver: { id in id == harness.environmentID ? harness.environment : nil },
            launchGeneration: { _ in 7 },
            operations: harness.operations,
            runtimeComponentProbe: { _, _, _ in harness.probeBox.get() },
            pipWheels: { specs in lock.withLock { fetchedSpecs.entries.append(contentsOf: specs) }; return specs.map { makeWheelBundle(spec: $0) } },
            wheelStoreURL: wheelStore,
            appVersion: { "1.7.60" },
            persistenceRoot: harness.persistenceRoot
        )
        center.setLateBindings(
            transport: { _, _, _, _ in fetchedEngine },
            componentStoreRoot: storeRoot
        )
        let outcome = await center.prepareAtInstall(
            skillID: "dep-skill", environmentID: nil, runID: nil, cancellation: nil
        )
        #expect(outcome == nil) // environment half honestly deferred, never fake-ready
        #expect(lock.withLock { fetchedSpecs.entries } == ["pypdf==5.4.0"])
        // The verified BYTES actually persisted in the shared store under the
        // REAL canonical wheel name (what pip's --find-links scan can see),
        // with a binding sidecar carrying spec+filename+sha256+size.
        let directory = SkillDependencyPreparationCenter.wheelDirectory(in: wheelStore)
        #expect(directory.lastPathComponent == "official-wheels")
        let storedWheel = directory.appendingPathComponent("pypdf-5.4.0-py3-none-any.whl")
        let persisted = try Data(floeContentsOf: storedWheel)
        #expect(persisted == makeWheelBundle(spec: "pypdf==5.4.0").bytes)
        let bindingData = try Data(floeContentsOf: SkillDependencyPreparationCenter.wheelBindingURL(for: storedWheel))
        let binding = try JSONDecoder().decode(SkillDependencyPreparationCenter.WheelStoreBinding.self, from: bindingData)
        #expect(binding.spec == "pypdf==5.4.0")
        #expect(binding.filename == "pypdf-5.4.0-py3-none-any.whl")
        #expect(binding.sha256 == FloeDigest.sha256Hex(persisted))
        #expect(binding.size == persisted.count)
        // A second global install reuses the persisted bytes without refetching.
        _ = await center.prepareAtInstall(skillID: "dep-skill", environmentID: nil, runID: nil, cancellation: nil)
        #expect(lock.withLock { fetchedSpecs.entries.count } == 1)
        let statusNow = await center.sharedPreparationStatus(skillID: "dep-skill")
        try #require(statusNow != nil)
        #expect(statusNow!.contains("already present in the shared official store"))
        let cacheFile = storeRoot
            .appendingPathComponent("impeccable-engine", isDirectory: true)
            .appendingPathComponent("0.1.17+floe.1.0.0", isDirectory: true)
            .appendingPathComponent("riscv64gc-unknown-linux-musl", isDirectory: true)
            .appendingPathComponent("floe-impeccable")
        let cached = try Data(floeContentsOf: cacheFile)
        #expect(cached == harness.engine)
        let status = await harness.center.sharedPreparationStatus(skillID: "dep-skill")
        try #require(status != nil)
        #expect(status!.contains("pip pypdf@5.4.0 = prefetched/verified"))
        #expect(status!.contains("shared official store"))
        #expect(status!.contains("apt python3-scipy@1.15.3-1 = awaiting task environment"))
        #expect(status!.contains("runtimeComponent impeccable-engine@0.1.17+floe.1.0.0 = prefetched/verified"))
        #expect(status!.contains("environment install/readback: deferred"))
        // Prefetch is not readiness: the environment half never claims ready.
        let invokeFresh = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: UUID(), cancellation: nil
        )
        guard case .refused = invokeFresh else { Issue.record("expected noRun refusal before any plan"); return }
    }

    @Test func transientWheelVerificationWithoutStoreIsNeverLabeledPrepared() async throws {
        let harness = makeHarness(requirementsJSON: pipOnly())
        let center = SkillDependencyPreparationCenter(
            authorityProvider: { _ in harness.authorityBox.value },
            environmentResolver: { id in id == harness.environmentID ? harness.environment : nil },
            launchGeneration: { _ in 7 },
            operations: harness.operations,
            pipWheels: { specs in specs.map { makeWheelBundle(spec: $0) } },
            appVersion: { "1.7.60" },
            persistenceRoot: harness.persistenceRoot
        )
        _ = await center.prepareAtInstall(skillID: "dep-skill", environmentID: nil, runID: nil, cancellation: nil)
        let status = await center.sharedPreparationStatus(skillID: "dep-skill")
        try #require(status != nil)
        #expect(status!.contains("pip pypdf@5.4.0 = awaiting task environment"))
        #expect(status!.contains("nothing is counted prepared"))
        #expect(!status!.contains("prefetched/verified"))
    }

    @Test func prefetchFailureIsRecordedHonestlyNotSwallowed() async throws {
        let harness = makeHarness(requirementsJSON: pipOnly())
        let center = SkillDependencyPreparationCenter(
            authorityProvider: { _ in harness.authorityBox.value },
            environmentResolver: { id in id == harness.environmentID ? harness.environment : nil },
            launchGeneration: { _ in 7 },
            operations: harness.operations,
            pipWheels: { _ in throw CocoaError(.featureUnsupported) },
            wheelStoreURL: makeTempDirectory("wheel-store"),
            appVersion: { "1.7.60" },
            persistenceRoot: harness.persistenceRoot
        )
        _ = await center.prepareAtInstall(skillID: "dep-skill", environmentID: nil, runID: nil, cancellation: nil)
        let status = await center.sharedPreparationStatus(skillID: "dep-skill")
        try #require(status != nil)
        #expect(status!.contains("prefetch failed"))
        #expect(!status!.contains("prefetched/verified"))
    }

    @Test func prefetchedCacheIsReusedAndReverifiedAcrossRestart() async throws {
        let json = """
        {"schemaVersion":1,"profiles":[{"id":"engine","target":{"os":"linux","architectures":["riscv64"]},"requirements":[{"kind":"runtimeComponent","componentDescriptorPath":"references/engine-dependency.json","purpose":"Engine.","required":false}]}]}
        """
        let harness = makeHarness(requirementsJSON: json)
        let storeRoot = makeTempDirectory("component-cache")
        let counter = NSLock()
        let transports = LockedCounter()
        harness.center.setLateBindings(
            transport: { _, _, _, _ in counter.withLock { transports.value += 1 }; return harness.engine },
            componentStoreRoot: storeRoot
        )
        _ = await harness.center.prepareAtInstall(skillID: "dep-skill", environmentID: nil, runID: nil, cancellation: nil)
        #expect(counter.withLock { transports.value } == 1)
        // Simulated restart: a fresh actor on the same store re-verifies the
        // cached bytes instead of downloading again.
        let environmentID = harness.environmentID
        let environment = harness.environment
        let second = SkillDependencyPreparationCenter(
            authorityProvider: { _ in harness.authorityBox.value },
            environmentResolver: { id in id == environmentID ? environment : nil },
            launchGeneration: { _ in 7 },
            operations: nil,
            appVersion: { "1.7.60" },
            persistenceRoot: harness.persistenceRoot
        )
        second.setLateBindings(
            transport: { _, _, _, _ in counter.withLock { transports.value += 1 }; return harness.engine },
            componentStoreRoot: storeRoot
        )
        _ = await second.prepareAtInstall(skillID: "dep-skill", environmentID: nil, runID: nil, cancellation: nil)
        #expect(counter.withLock { transports.value } == 1)
        let status = await second.sharedPreparationStatus(skillID: "dep-skill")
        try #require(status != nil)
        #expect(status!.contains("verified cache bytes reused"))
    }

    // MARK: - skill.read invocation contract

    @Test func invocationInfoCarriesTheContract() throws {
        let json = """
        {"schemaVersion":1,"profiles":[{"id":"linux-guest","target":{"os":"linux","architectures":["any"]},"requirements":[{"kind":"pip","name":"pypdf","version":"5.4.0","purpose":"PDF merge step.","required":true},{"kind":"npm","name":"typescript","version":"5.9.3","purpose":"Type-check.","required":false}]}]}
        """
        let declaration = try SkillDependency.decode(Data(json.utf8))
        let info = SkillDependencyPreparationCenter.invocationInfo(skillID: "dep-skill", declaration: declaration)
        #expect(info.contains("## Dependency invocation"))
        #expect(info.contains("pip: pypdf@5.4.0 (required)"))
        #expect(info.contains("npm: typescript@5.9.3 (optional)"))
        #expect(info.contains("\"skillID\": \"dep-skill\""))
        #expect(info.contains("Commands without skillID are unchanged"))
    }

    // MARK: - Profile target selection (arm64-only must not mutate riscv64)

    @Test func nonMatchingArchitectureProfileRefusesPlanAndPrefetchHonestly() async throws {
        let json = """
        {"schemaVersion":1,"profiles":[{"id":"mac","target":{"os":"linux","architectures":["arm64"]},"requirements":[{"kind":"pip","name":"pypdf","version":"5.4.0","purpose":"PDF.","required":true}]}]}
        """
        let harness = makeHarness(requirementsJSON: json)
        let plan = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: UUID(),
            authority: harness.authorityBox.value
        )
        guard case .rejected(let reason) = plan else { Issue.record("arm64-only must refuse the plan"); return }
        #expect(reason.contains("architecture"))
        let invoke = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: UUID(), cancellation: nil
        )
        guard case .refused = invoke else { Issue.record("no plan may survive for a non-matching target"); return }
        // Global prefetch records the honest skip and downloads nothing.
        _ = await harness.center.prepareAtInstall(skillID: "dep-skill", environmentID: nil, runID: nil, cancellation: nil)
        let status = await harness.center.sharedPreparationStatus(skillID: "dep-skill")
        try #require(status != nil)
        #expect(status!.contains("profile targets arm64, not this Linux backend (riscv64)"))
        #expect(status!.contains("host wheel fetch not wired") == false)
        let counts = harness.operations.counts
        #expect(counts.python == 0 && counts.apt == 0 && counts.npm == 0 && counts.font == 0)
    }

    @Test func matchingProfilesPrepareAndForeignArchStaysUntouched() async throws {
        let json = """
        {"schemaVersion":1,"profiles":[{"id":"linux-guest","target":{"os":"linux","architectures":["any"]},"requirements":[{"kind":"pip","name":"pypdf","version":"5.4.0","purpose":"PDF.","required":true}]},{"id":"risc","target":{"os":"linux","architectures":["riscv64"]},"requirements":[{"kind":"apt","name":"hello","version":"2.10-3","purpose":"Smoke binary.","required":true}]},{"id":"mac","target":{"os":"linux","architectures":["arm64"]},"requirements":[{"kind":"npm","name":"typescript","version":"5.9.3","purpose":"Type-check.","required":true}]}]}
        """
        let harness = makeHarness(requirementsJSON: json)
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID,
            authority: harness.authorityBox.value
        )
        let outcome = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
        )
        // The arm64-only npm requirement would make this required and
        // un-preparable; the correct behavior is that it never participates.
        guard case .ready(let annotation) = outcome else { Issue.record("expected ready: \(outcome)"); return }
        #expect(annotation.contains("pip:pypdf@5.4.0"))
        #expect(annotation.contains("apt:hello@2.10-3"))
        #expect(!annotation.contains("typescript"))
        #expect(harness.operations.counts.npm == 0)
    }

    @Test func overlappingMatchingProfilesContradictingPinsRefuseBeforeMutation() async throws {
        let json = """
        {"schemaVersion":1,"profiles":[{"id":"a","target":{"os":"linux","architectures":["any"]},"requirements":[{"kind":"apt","name":"python3-scipy","version":"1.15.3-1","purpose":"Numeric.","required":true}]},{"id":"b","target":{"os":"linux","architectures":["riscv64"]},"requirements":[{"kind":"apt","name":"python3-scipy","version":"1.16.0-1","purpose":"Numeric.","required":true}]}]}
        """
        let harness = makeHarness(requirementsJSON: json)
        let plan = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: UUID(),
            authority: harness.authorityBox.value
        )
        guard case .rejected(let reason) = plan else { Issue.record("contradicting matching pins must refuse"); return }
        #expect(reason.contains("conflicting exact versions"))
        #expect(reason.contains("1.15.3-1") && reason.contains("1.16.0-1"))
        let invoke = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: UUID(), cancellation: nil
        )
        guard case .refused = invoke else { Issue.record("expected refusal"); return }
        #expect(harness.operations.counts.apt == 0)
    }

    @Test func identicalExactDuplicateAcrossMatchingProfilesReuses() async throws {
        let json = """
        {"schemaVersion":1,"profiles":[{"id":"a","target":{"os":"linux","architectures":["any"]},"requirements":[{"kind":"pip","name":"pypdf","version":"5.4.0","purpose":"PDF.","required":true}]},{"id":"b","target":{"os":"linux","architectures":["riscv64"]},"requirements":[{"kind":"pip","name":"pypdf","version":"5.4.0","purpose":"PDF.","required":true}]}]}
        """
        let harness = makeHarness(requirementsJSON: json)
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID,
            authority: harness.authorityBox.value
        )
        let outcome = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
        )
        guard case .ready = outcome else { Issue.record("exact duplicates are reuse, not conflict: \(outcome)"); return }
        #expect(harness.operations.counts.python == 1)
    }

    // MARK: - Shared wheel store: canonical names, bindings, signed locks

    private func makeStoreCenter(
        _ harness: Harness,
        storeURL: URL,
        wheelFilename: String? = nil,
        fetchCount: NSLock? = nil,
        counter: LockedCounter? = nil
    ) -> SkillDependencyPreparationCenter {
        SkillDependencyPreparationCenter(
            authorityProvider: { _ in harness.authorityBox.value },
            environmentResolver: { id in id == harness.environmentID ? harness.environment : nil },
            launchGeneration: { _ in 7 },
            operations: harness.operations,
            pipWheels: { specs in
                fetchCount?.withLock { counter?.value += specs.count }
                return specs.map { makeWheelBundle(spec: $0, filename: wheelFilename) }
            },
            wheelStoreURL: storeURL,
            appVersion: { "1.7.60" },
            persistenceRoot: harness.persistenceRoot
        )
    }

    @Test func wheelStorePersistsCanonicalNameAndReplacesContradictedBytes() async throws {
        let harness = makeHarness(requirementsJSON: pipOnly())
        let counter = LockedCounter()
        let lock = NSLock()
        let center = makeStoreCenter(harness, storeURL: harness.wheelStore, fetchCount: lock, counter: counter)
        _ = await center.prepareAtInstall(skillID: "dep-skill", environmentID: nil, runID: nil, cancellation: nil)
        let stored = SkillDependencyPreparationCenter.wheelDirectory(in: harness.wheelStore)
            .appendingPathComponent("pypdf-5.4.0-py3-none-any.whl")
        let good = makeWheelBundle(spec: "pypdf==5.4.0")
        #expect(try Data(floeContentsOf: stored) == good.bytes)
        #expect(lock.withLock { counter.value } == 1)
        // Reuse without refetch.
        _ = await center.prepareAtInstall(skillID: "dep-skill", environmentID: nil, runID: nil, cancellation: nil)
        #expect(lock.withLock { counter.value } == 1)
        // Contradicted bytes (digest no longer matches the binding) must be
        // refetched and replaced, never reused and never handed to pip.
        try Data("tampered".utf8).write(to: stored, options: .atomic)
        _ = await center.prepareAtInstall(skillID: "dep-skill", environmentID: nil, runID: nil, cancellation: nil)
        #expect(lock.withLock { counter.value } == 2)
        #expect(try Data(floeContentsOf: stored) == good.bytes)
        let status = await center.sharedPreparationStatus(skillID: "dep-skill")
        try #require(status != nil)
        #expect(status!.contains("pip pypdf@5.4.0 = prefetched/verified"))
    }

    @Test func wheelStoreRejectsNonCanonicalInventedFetchedName() async throws {
        let harness = makeHarness(requirementsJSON: pipOnly())
        // The old storage shape's name: valid ".whl" suffix but NOT a PEP 427
        // wheel basename — pip --find-links would ignore it, so it must not be
        // persisted at all.
        let center = makeStoreCenter(harness, storeURL: harness.wheelStore, wheelFilename: "9c1f2a-pypdf-5.4.0.whl")
        _ = await center.prepareAtInstall(skillID: "dep-skill", environmentID: nil, runID: nil, cancellation: nil)
        let status = await center.sharedPreparationStatus(skillID: "dep-skill")
        try #require(status != nil)
        #expect(status!.contains("prefetch failed"))
        #expect(status!.contains("PEP 427"))
        let files = (try? FileManager.default.contentsOfDirectory(
            atPath: SkillDependencyPreparationCenter.wheelDirectory(in: harness.wheelStore).path)) ?? []
        #expect(files.filter { $0.hasSuffix(".whl") }.isEmpty)
    }

    @Test func wheelDirectoryDoesNotDoubleTheOfficialWheelsLevel() {
        let root = URL(fileURLWithPath: "/tmp/floe-cache-pip")
        #expect(SkillDependencyPreparationCenter.wheelDirectory(in: root).lastPathComponent == "official-wheels")
        #expect(SkillDependencyPreparationCenter.wheelDirectory(in: root.appendingPathComponent("official-wheels"))
            == root.appendingPathComponent("official-wheels"))
    }

    @Test func signedLockBindsFetchAndInstallAndRefusesContradictions() async throws {
        let bundle = makeWheelBundle(spec: "pypdf==5.4.0")
        let matchingLock = "pypdf==5.4.0 \\\n    --hash=sha256:\(bundle.sha256)\n    --hash=sha256:\(String(repeating: "f", count: 64))\n# comment\n"
        // 1) Fetch/cache path: the digest is pinned -> verified.
        let goodHarness = makeHarness(requirementsJSON: pipWithLock(), lockText: matchingLock)
        let goodCenter = makeStoreCenter(goodHarness, storeURL: goodHarness.wheelStore)
        _ = await goodCenter.prepareAtInstall(skillID: "dep-skill", environmentID: nil, runID: nil, cancellation: nil)
        let status = await goodCenter.sharedPreparationStatus(skillID: "dep-skill")
        try #require(status != nil)
        #expect(status!.contains("pip pypdf@5.4.0 = prefetched/verified"))
        // 2) Install path runs pip's own --require-hashes mode with the lock digests.
        let runHarness = makeHarness(requirementsJSON: pipWithLock(), lockText: matchingLock)
        let runID = UUID()
        _ = await runHarness.center.recordPlan(
            skillID: "dep-skill", environmentID: runHarness.environmentID, runID: runID,
            authority: runHarness.authorityBox.value
        )
        let ready = await runHarness.center.invoke(
            skillID: "dep-skill", environmentID: runHarness.environmentID, runID: runID, cancellation: nil
        )
        guard case .ready(let annotation) = ready else { Issue.record("expected ready: \(ready)"); return }
        #expect(annotation.contains("lock sha256-verified"))
        let transactions = runHarness.operations.pinsTransactions
        #expect(transactions.count == 1)
        #expect(transactions[0].count == 1)
        #expect(transactions[0][0].0 == "pypdf==5.4.0")
        #expect(transactions[0][0].1.contains(bundle.sha256))
        // a lock install never silently drops to the single-root ensure path
        #expect(runHarness.operations.pythonEnsureCalls.isEmpty)
        // 3) A lock that pins a different digest fails the prefetch honestly.
        let wrongLock = "pypdf==5.4.0 \\\n    --hash=sha256:\(String(repeating: "a", count: 64))\n"
        let wrongHarness = makeHarness(requirementsJSON: pipWithLock(), lockText: wrongLock)
        let wrongCenter = makeStoreCenter(wrongHarness, storeURL: wrongHarness.wheelStore)
        _ = await wrongCenter.prepareAtInstall(skillID: "dep-skill", environmentID: nil, runID: nil, cancellation: nil)
        let wrongStatus = await wrongCenter.sharedPreparationStatus(skillID: "dep-skill")
        try #require(wrongStatus != nil)
        #expect(wrongStatus!.contains("prefetch failed"))
        #expect(wrongStatus!.contains("signed lock"))
        // 4) A lock without any digest for the exact spec fails closed.
        let bareLock = "pypdf==5.3.0 \\\n    --hash=sha256:\(bundle.sha256)\n"
        let bareHarness = makeHarness(requirementsJSON: pipWithLock(), lockText: bareLock)
        let bareCenter = makeStoreCenter(bareHarness, storeURL: bareHarness.wheelStore)
        _ = await bareCenter.prepareAtInstall(skillID: "dep-skill", environmentID: nil, runID: nil, cancellation: nil)
        let bareStatus = await bareCenter.sharedPreparationStatus(skillID: "dep-skill")
        try #require(bareStatus != nil)
        #expect(bareStatus!.contains("pins no sha256 digest"))
    }

    @Test func invokeRemovesAndRefusesStoreWheelContradictingTheLock() async throws {
        // A wheel persisted under the correct binding (digest X) while the
        // signed lock pins only digest Y must never reach pip through
        // --find-links: the install-time gate removes the contradicted pair
        // and refuses BEFORE any mutation.
        let planted = makeWheelBundle(spec: "pypdf==5.4.0")
        let store = makeTempDirectory("wheel-store")
        let binding = SkillDependencyPreparationCenter.WheelStoreBinding(
            spec: "pypdf==5.4.0", filename: "pypdf-5.4.0-py3-none-any.whl",
            sha256: planted.sha256, size: planted.size
        )
        try SkillDependencyPreparationCenter.persistWheelBinding(storeURL: store, bundle: planted, binding: binding)
        let otherDigest = String(repeating: "b", count: 64)
        let lock = "pypdf==5.4.0 \\\n    --hash=sha256:\(otherDigest)\n"
        let harness = makeHarness(requirementsJSON: pipWithLock(), lockText: lock)
        let center = SkillDependencyPreparationCenter(
            authorityProvider: { _ in harness.authorityBox.value },
            environmentResolver: { id in id == harness.environmentID ? harness.environment : nil },
            launchGeneration: { _ in 7 },
            operations: harness.operations,
            wheelStoreURL: store,
            appVersion: { "1.7.60" },
            persistenceRoot: harness.persistenceRoot
        )
        let runID = UUID()
        _ = await center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID,
            authority: harness.authorityBox.value
        )
        let outcome = await center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
        )
        guard case .refused(let reason) = outcome else { Issue.record("expected refusal, got \(outcome)"); return }
        #expect(reason.contains("does not match the signed lock"))
        #expect(harness.operations.counts.python == 0)
        let directory = SkillDependencyPreparationCenter.wheelDirectory(in: store)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("pypdf-5.4.0-py3-none-any.whl").path))
        #expect(!FileManager.default.fileExists(
            atPath: SkillDependencyPreparationCenter.wheelBindingURL(
                for: directory.appendingPathComponent("pypdf-5.4.0-py3-none-any.whl")
            ).path))
    }

    // MARK: - Full-closure locks and venv/system ownership

    private func closureLockText() -> (String, SkillDependencyWheelBundle, SkillDependencyWheelBundle) {
        let root = makeWheelBundle(spec: "pypdf==5.4.0")
        let transitive = makeWheelBundle(spec: "requests==2.32.4")
        let lock = "pypdf==5.4.0 \\\n    --hash=sha256:\(root.sha256)\n"
            + "requests==2.32.4 \\\n    --hash=sha256:\(transitive.sha256) \\\n    --hash=sha256:\(String(repeating: "c", count: 64))\n"
            + "# closure generated with pip-compile --generate-hashes\n"
        return (lock, root, transitive)
    }

    @Test func signedLockClosureInstallsRootAndTransitiveInOneManagedTransaction() async throws {
        let (lock, root, transitive) = closureLockText()
        let harness = makeHarness(requirementsJSON: pipWithLock(), lockText: lock)
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID,
            authority: harness.authorityBox.value
        )
        let outcome = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
        )
        guard case .ready(let annotation) = outcome else { Issue.record("expected ready: \(outcome)"); return }
        let transactions = harness.operations.pinsTransactions
        #expect(transactions.count == 1)
        #expect(transactions[0].count == 2)
        let bySpec = Dictionary(uniqueKeysWithValues: transactions[0].map { ($0.0, $0.1) })
        #expect(bySpec["pypdf==5.4.0"] == [root.sha256])
        #expect(bySpec["requests==2.32.4"]?.contains(transitive.sha256) == true)
        #expect(bySpec["requests==2.32.4"]?.count == 2)
        #expect(annotation.contains("lock sha256-verified closure 2"))
        #expect(harness.operations.pythonEnsureCalls.isEmpty)
    }

    @Test func inheritedSystemVersionDoesNotBlockTheVenvPinAndStaysPreserved() async throws {
        let (lock, _, _) = closureLockText()
        let harness = makeHarness(requirementsJSON: pipWithLock(), lockText: lock)
        // An older apt-shipped requests visible through --system-site-packages
        // must NOT refuse the reviewed venv pin (environment-scope rule): the
        // closure installs into the venv, shadowing it, and the inherited row
        // is byte-preserved (no removal verb exists at all).
        harness.operations.setPythonSystemInitial(["requests": "2.32.3"])
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID,
            authority: harness.authorityBox.value
        )
        let outcome = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
        )
        guard case .ready = outcome else { Issue.record("inherited mismatch must not block: \(outcome)"); return }
        #expect(harness.operations.pinsTransactions.count == 1)
        #expect(harness.operations.pythonSystemSnapshot["requests"] == "2.32.3")
        #expect(harness.operations.pythonOwnedSnapshot["requests"] == "2.32.4")
    }

    @Test func ownedTransitiveMismatchRefusesClosureBeforeAnyInstall() async throws {
        let (lock, _, _) = closureLockText()
        let harness = makeHarness(requirementsJSON: pipWithLock(), lockText: lock)
        // An OWNED older venv pin is a real conflict of the environment's
        // writable layer: refuse before the transaction, never silently
        // overwrite/downgrade.
        harness.operations.setPythonOwnedInitial(["requests": "2.31.0"])
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID,
            authority: harness.authorityBox.value
        )
        let outcome = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
        )
        guard case .refused(let reason) = outcome else { Issue.record("expected refusal: \(outcome)"); return }
        #expect(reason.contains("requests"))
        #expect(reason.contains("conflicts with the reviewed pin"))
        #expect(harness.operations.pinsTransactions.isEmpty)
        #expect(harness.operations.pythonEnsureCalls.isEmpty)
    }

    @Test func allClosurePinsAlreadyActiveSkipMutation() async throws {
        let (lock, _, _) = closureLockText()
        let harness = makeHarness(requirementsJSON: pipWithLock(), lockText: lock)
        // Root owned-current + transitive inherited-at-pin: every closure
        // member is already ACTIVE at the exact pin -> verification without
        // any pip transaction at all.
        harness.operations.setPythonSystemInitial(["requests": "2.32.4"])
        harness.operations.setPythonOwnedInitial(["pypdf": "5.4.0"])
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID,
            authority: harness.authorityBox.value
        )
        let outcome = await harness.center.invoke(
            skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
        )
        guard case .ready(let annotation) = outcome else { Issue.record("expected ready: \(outcome)"); return }
        #expect(annotation.contains("closure 2 satisfied"))
        #expect(harness.operations.pinsTransactions.isEmpty)
        #expect(harness.operations.pythonEnsureCalls.isEmpty)
        #expect(harness.operations.pythonSystemSnapshot["requests"] == "2.32.4")
    }

    @Test func unsupportedLockSyntaxRefusesHonestlyAtInstallAndPrefetch() async throws {
        let digest = String(repeating: "a", count: 64)
        for (label, lock) in [
            ("range operator", "pypdf>=5.4.0 \\\n    --hash=sha256:\(digest)\n"),
            ("entry without a sha256 pin", "pypdf==5.4.0\nrequests==2.32.4 --hash=sha256:\(digest)\n"),
            ("index flag smuggled in", "-i https://evil.example \n pypdf==5.4.0 --hash=sha256:\(digest)\n"),
            ("non-canonical digest", "pypdf==5.4.0 --hash=sha256:zz\n"),
            ("contradictory duplicate identity", "pypdf==5.4.0 --hash=sha256:\(digest)\npypdf==5.5.0 --hash=sha256:\(digest)\n"),
        ] {
            let harness = makeHarness(requirementsJSON: pipWithLock(), lockText: lock)
            let runID = UUID()
            _ = await harness.center.recordPlan(
                skillID: "dep-skill", environmentID: harness.environmentID, runID: runID,
                authority: harness.authorityBox.value
            )
            let outcome = await harness.center.invoke(
                skillID: "dep-skill", environmentID: harness.environmentID, runID: runID, cancellation: nil
            )
            guard case .refused(let reason) = outcome else {
                Issue.record("\(label): must refuse honestly, got \(outcome)")
                continue
            }
            #expect(reason.contains("strict"), "\(label)")
            #expect(harness.operations.pinsTransactions.isEmpty && harness.operations.pythonEnsureCalls.isEmpty, "\(label)")
            // The prefetch side refuses the same lock honestly and persists
            // nothing.
            let store = makeTempDirectory("wheel-store")
            let center = makeStoreCenter(harness, storeURL: store)
            _ = await center.prepareAtInstall(skillID: "dep-skill", environmentID: nil, runID: nil, cancellation: nil)
            let status = await center.sharedPreparationStatus(skillID: "dep-skill")
            try #require(status != nil, "\(label)")
            #expect(status!.contains("prefetch failed"), "\(label)")
        }
    }

    @Test func signedLockPrefetchPersistsRootAndTransitiveWheels() async throws {
        let (lock, root, transitive) = closureLockText()
        let harness = makeHarness(requirementsJSON: pipWithLock(), lockText: lock)
        let counter = LockedCounter()
        let guard_ = NSLock()
        let center = makeStoreCenter(harness, storeURL: harness.wheelStore, fetchCount: guard_, counter: counter)
        _ = await center.prepareAtInstall(skillID: "dep-skill", environmentID: nil, runID: nil, cancellation: nil)
        // Both closure wheels fetched (root first dedup applies), persisted
        // under their canonical names, and each carries the status.
        #expect(guard_.withLock { counter.value } == 2)
        let directory = SkillDependencyPreparationCenter.wheelDirectory(in: harness.wheelStore)
        let rootFile = directory.appendingPathComponent("pypdf-5.4.0-py3-none-any.whl")
        let transitiveFile = directory.appendingPathComponent("requests-2.32.4-py3-none-any.whl")
        #expect(try Data(floeContentsOf: rootFile) == root.bytes)
        #expect(try Data(floeContentsOf: transitiveFile) == transitive.bytes)
        let status = await center.sharedPreparationStatus(skillID: "dep-skill")
        try #require(status != nil)
        #expect(status!.contains("pip pypdf@5.4.0 = prefetched/verified"))
        #expect(status!.contains("pip requests@2.32.4 = prefetched/verified"))
        #expect(status!.contains("transitive closure member of pypdf"))
    }
}

/// Shared mutable fetch counter for the store-center helper.
private final class LockedCounter: @unchecked Sendable {
    var value = 0
}

/// Shared mutable fetch-spec recorder for the global-install seam
/// (guarded by the same external NSLock discipline as LockedCounter).
private final class LockedStringBox: @unchecked Sendable {
    var entries: [String] = []
}
#endif
