// FloeAppTests — trusted lazy runtime-component deployment (Impeccable engine).
//
// Locks the app-side chain end to end with fakes at every injected seam
// (transport / authorization / environment resolver / path map / guest
// runner / launch generation). NONE of these tests label fakes as a real
// guest: the real TinyEMU probe loop remains Main-owned qualification.
//
//   * plan recording: forged/imported/disabled/edited identity, revoked
//     declared grants, foreign descriptors, bad app versions and unsupported
//     contracts are refused; recording itself never touches transport/runner;
//   * download: exact same-Y fetch through the GitHub-only transport, exact
//     integer size + sha256 + static-ELF gate, truncation/digest/ELF negatives,
//     offline cache reuse, atomic verified commits;
//   * staging: reserved-root conflicts, foreign/damaged originals preserved,
//     verified adoption without re-download, cancellation cleanup;
//   * readiness: fixed verbs only, exact probe stdout, contract digest +
//     supported version, staged-vs-probed state distinction, receipt reuse
//     bound to the guest launch generation, re-probe after rotation;
//   * authority: live revalidation before/after download/staging and before
//     delivery, revocation mid-download cannot issue a late ready;
//   * lifecycle: releaseEnvironment cancels + joins; one environment's
//     cancellation never aborts a shared download another environment awaits;
//   * routing: native bindings are exported for the run only and override
//     caller-supplied values for the same keys.

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeExecution
import FloePersistence
import FloeSkills
import FloeTools
@testable import FloeApp

// MARK: - File-scope helpers

private func makeTemporaryDirectory(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-runtime-component-\(label)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeELF64Bytes(
    eType: UInt16 = 2,
    eMachine: UInt16 = 243,
    phnum: UInt16 = 1,
    programHeaders: [(type: UInt32, offset: Int)] = [(1, 64)]
) -> Data {
    var bytes = Data(count: 64)
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
    put16(16, eType); put16(18, eMachine); put32(20, 1)
    put64(32, 64); put16(54, 56); put16(56, phnum)
    let total = 64 + Int(phnum) * 56
    if bytes.count < total { bytes.append(Data(count: total - bytes.count)) }
    for (index, header) in programHeaders.enumerated() {
        put32(64 + index * 56, header.type)
    }
    return bytes
}

private struct ComponentFixture {
    let descriptor: SkillRuntimeDependencyDescriptor
    let descriptorBytes: Data
    let engineBytes: Data
    let contractBytes: Data
}

private func makeComponentFixture(engineBytes: Data? = nil, contractVersion: Int = 1) throws -> ComponentFixture {
    let engine = engineBytes ?? makeELF64Bytes()
    let contract = Data("""
        {"contract":"floe.impeccable.snapshot","contractVersion":\(contractVersion),"fixture":true}
        """.utf8)
    let version = "0.1.17+floe.1.0.0"
    let descriptorJSON = """
        {"artifact":{"path":"engines/impeccable/dist/impeccable-\(version)/riscv64gc-unknown-linux-musl/floe-impeccable","sha256":"\(FloeDigest.sha256Hex(engine))","size":\(engine.count)},"captureContract":{"sha256":"\(FloeDigest.sha256Hex(contract))","version":\(contractVersion)},"componentID":"impeccable-engine","componentVersion":"\(version)","minimumAppVersion":"1.7.59","schemaVersion":1,"target":{"arch":"riscv64","format":"elf64-little-riscv-exec-static","os":"linux","triple":"riscv64gc-unknown-linux-musl"}}
        """
    let descriptorBytes = Data(descriptorJSON.utf8)
    return ComponentFixture(
        descriptor: try SkillRuntimeDependency.decode(descriptorBytes),
        descriptorBytes: descriptorBytes,
        engineBytes: engine,
        contractBytes: contract
    )
}

// MARK: - Staged skill fixture (real production stager route)

private struct StagedSkillFixture {
    let skillID = "impeccable-fixture"
    let environmentID = "env-fixture"
    let snapshot: SkillContentSnapshot
    let workspace: URL
    let layer: URL
    let pathMap: LinuxGuestPathMap
    let stagedGuestRoot: String
    let stagedHostRoot: URL
    let manifest: SkillManifest
}

private func makeStagedSkillFixture(
    descriptorBytes: Data,
    capabilities: [String] = []
) async throws -> StagedSkillFixture {
    let workspace = makeTemporaryDirectory("workspace")
    let layer = makeTemporaryDirectory("layer")
    let packageRoot = workspace.appendingPathComponent("package-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
    let markdown = """
        ---
        name: impeccable-fixture
        description: Fixture curated package carrying an engine dependency descriptor
        ---
        Fixture instructions.
        """
    try Data(markdown.utf8).write(to: packageRoot.appendingPathComponent("SKILL.md"), options: .atomic)
    let manifest = SkillManifest(
        id: "impeccable-fixture", version: "1.0.0",
        capabilities: capabilities, tools: [], scriptRuntime: .none
    )
    try JSONEncoder().encode(manifest).write(to: packageRoot.appendingPathComponent("floe.json"), options: .atomic)
    let reference = packageRoot.appendingPathComponent("references/engine-dependency.json", isDirectory: false)
    try FileManager.default.createDirectory(at: reference.deletingLastPathComponent(), withIntermediateDirectories: true)
    try descriptorBytes.write(to: reference, options: .atomic)
    let validated = try SkillPackageValidator().validate(packageAt: packageRoot)
    let snapshot = try SkillContentSnapshot(root: packageRoot, expectedDigest: validated.canonicalSHA256)

    let pathMap = LinuxGuestPathMap(shares: [
        LinuxGuestShare(tag: LinuxGuestShare.environmentTag, hostDirectory: layer),
        LinuxGuestShare(tag: LinuxGuestShare.workspaceTag, hostDirectory: workspace)
    ])
    let stager = SkillWorkspaceResourceStager { _ in pathMap }
    let outcome = await stager.stage(
        snapshot: snapshot,
        in: SkillResourceContext(
            environmentID: "env-fixture", workspaceRootURL: workspace, cancellation: CancellationToken()
        )
    )
    guard case .staged(let staged) = outcome else {
        throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture staging failed"])
    }
    let leaf = staged.guestRoot.split(separator: "/").last!
    return StagedSkillFixture(
        snapshot: snapshot,
        workspace: workspace,
        layer: layer,
        pathMap: pathMap,
        stagedGuestRoot: staged.guestRoot,
        stagedHostRoot: workspace.appendingPathComponent(".floe/skills/\(leaf)", isDirectory: true),
        manifest: manifest
    )
}

// MARK: - Authority fixture

private let fixturePublicationY = String(repeating: "e", count: 40)

private func makeAuthority(
    fixture: StagedSkillFixture,
    descriptorBytes: Data,
    publicationY: String = fixturePublicationY,
    feedStatus: CuratedSkillFeedStatus = .production,
    reviewDecision: CuratedSkillReviewDecision = .approve,
    feedKeyID: String = CuratedSkillHub.productionKeyID,
    reviewKeyID: String = CuratedSkillHub.productionKeyID,
    hubRepository: String = CuratedSkillHub.hubRepository
) -> SkillRuntimeComponentAuthority {
    SkillRuntimeComponentAuthority(
        skillID: fixture.skillID,
        entryVersion: fixture.manifest.version,
        contentDigest: fixture.snapshot.package.canonicalSHA256,
        packageSHA256: String(repeating: "a", count: 64),
        catalogSHA256: String(repeating: "b", count: 64),
        reviewSHA256: String(repeating: "c", count: 64),
        auditedSourceCommit: String(repeating: "d", count: 40),
        publicationCommit: publicationY,
        feedStatus: feedStatus,
        reviewDecision: reviewDecision,
        feedSignatureKeyID: feedKeyID,
        reviewKeyID: reviewKeyID,
        hubRepository: hubRepository,
        descriptorBytes: descriptorBytes,
        descriptorSHA256: FloeDigest.sha256Hex(descriptorBytes),
        declaredFiles: fixture.snapshot.package.files,
        packageFiles: fixture.snapshot.files
    )
}

// MARK: - Fakes

private struct FakeTransportCall: Sendable, Equatable {
    let owner: String
    let repository: String
    let ref: String
    let path: String
}

private actor TransportGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func openGate() {
        open = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private final class FakeComponentTransport: @unchecked Sendable {
    let lock = NSLock()
    var history: [FakeTransportCall] = []
    var gate: TransportGate?
    var handler: @Sendable (FakeTransportCall) async throws -> Data = { _ in
        throw NSError(domain: "fixture-transport", code: 1)
    }
    func callHistory() -> [FakeTransportCall] {
        lock.withLock { history }
    }
    /// Synchronous: `NSLock` methods are unavailable from async contexts.
    private func record(_ call: FakeTransportCall) {
        lock.withLock { history.append(call) }
    }
    private func currentHandler() -> @Sendable (FakeTransportCall) async throws -> Data {
        lock.withLock { handler }
    }
    func fetch(_ owner: String, _ repository: String, _ ref: String, _ path: String) async throws -> Data {
        let call = FakeTransportCall(owner: owner, repository: repository, ref: ref, path: path)
        record(call)
        if let gate { await gate.wait() }
        let handler = currentHandler()
        return try await handler(call)
    }
}

private final class FakeComponentAuthorization: @unchecked Sendable {
    let lock = NSLock()
    var provider: @Sendable (String) -> SkillRuntimeComponentAuthority?
    init(provider: @escaping @Sendable (String) -> SkillRuntimeComponentAuthority? = { _ in nil }) {
        self.provider = provider
    }
    func authorize(_ skillID: String) -> SkillRuntimeComponentAuthority? {
        lock.lock(); defer { lock.unlock() }
        return provider(skillID)
    }
}

private final class GenerationBox: @unchecked Sendable {
    let lock = NSLock()
    var value: UInt64? = 7
    func current() -> UInt64? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: UInt64?) { lock.lock(); value = newValue; lock.unlock() }
}

private final class FakeComponentRunner: @unchecked Sendable, LinuxCommandRunning {
    struct RecordedRun: Sendable, Equatable {
        let environmentID: String
        let argv: [String]
    }
    let lock = NSLock()
    var runs: [RecordedRun] = []
    var supportsResult = true
    var chmodExit: Int32 = 0
    var probeExit: Int32 = 0
    var probeStdout = ""
    var contractExit: Int32 = 0
    var contractStdout = ""

    func callHistory() -> [RecordedRun] {
        lock.withLock { runs }
    }
    func supports(environmentID: String) async -> Bool { supportsResult }
    func ownsLinuxEnvironment(environmentID: String) async -> Bool { true }
    /// Synchronous: `NSLock` methods are unavailable from async contexts.
    private func recordAndMakeResult(environmentID: String, argv: [String]) -> LinuxCommandResult {
        lock.withLock {
            runs.append(RecordedRun(environmentID: environmentID, argv: argv))
            let verb = argv.last ?? ""
            if verb == "engine-probe" {
                return LinuxCommandResult(stdout: probeStdout, stderr: "", exitCode: probeExit)
            }
            if verb == "contract" {
                return LinuxCommandResult(stdout: contractStdout, stderr: "", exitCode: contractExit)
            }
            return LinuxCommandResult(stdout: "", stderr: "", exitCode: chmodExit)
        }
    }
    func run(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        standardInput: String?,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        recordAndMakeResult(environmentID: environmentID, argv: argv)
    }
    /// The most recent `/bin/sh -c` payload, for routing-merge assertions.
    func lastShellCommand() -> String? {
        lock.withLock { runs.last { $0.argv.first == "/bin/sh" }?.argv.last }
    }
}

private struct StubNativeShellBackend: LocalShellBackend {
    func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        .failed(message: "native backend unused in this test")
    }
    func normalizedRunTimeout(_ requested: TimeInterval) -> TimeInterval { requested }
    func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
        throw LinuxGuestError.consoleUnavailable("unused")
    }
    func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
        throw LinuxGuestError.consoleUnavailable("unused")
    }
    func closeSession(sessionID: String) async {}
    func signalSession(sessionID: String, signal: ShellSignal) async {}
    func resizeSession(sessionID: String, columns: Int, rows: Int) async {}
}

// MARK: - Harness

private struct ComponentCenterHarness {
    let center: SkillRuntimeComponentCenter
    let runner: FakeComponentRunner
    let transport: FakeComponentTransport
    let authorization: FakeComponentAuthorization
    let generation: GenerationBox
    let cacheRoot: URL

    func setProvider(_ provider: @escaping @Sendable (String) -> SkillRuntimeComponentAuthority?) {
        authorization.lock.lock()
        authorization.provider = provider
        authorization.lock.unlock()
    }
}

private func makeHarness(
    layers: [String: URL],
    pathMaps: [String: LinuxGuestPathMap],
    generation: UInt64? = 7,
    appVersion: String = "1.7.59"
) -> ComponentCenterHarness {
    let runner = FakeComponentRunner()
    let transport = FakeComponentTransport()
    let authorization = FakeComponentAuthorization()
    let generationBox = GenerationBox()
    generationBox.set(generation)
    let cacheRoot = makeTemporaryDirectory("cache")
    let center = SkillRuntimeComponentCenter(
        environmentResolver: { environmentID in
            guard let layer = layers[environmentID] else { return nil }
            return SkillRuntimeComponentEnvironment(layerURL: layer, isLinuxVM: true, isActive: true)
        },
        runner: runner,
        cacheRoot: cacheRoot,
        pathMapping: { environmentID in pathMaps[environmentID] },
        launchGeneration: { _ in generationBox.current() },
        appVersion: { appVersion },
        bindings: SkillRuntimeComponentLateBindings(
            transport: { owner, repository, ref, path in
                try await transport.fetch(owner, repository, ref, path)
            },
            authorization: { skillID in
                authorization.authorize(skillID)
            }
        )
    )
    return ComponentCenterHarness(
        center: center, runner: runner, transport: transport,
        authorization: authorization, generation: generationBox, cacheRoot: cacheRoot
    )
}

private let componentID = SkillRuntimeDependency.knownComponentID

private func expectedEngineGuestPath(_ version: String) -> String {
    "/floe/env/runtime-components/impeccable-engine/\(version)/riscv64gc-unknown-linux-musl/floe-impeccable"
}

private func stagedHostPath(layer: URL, version: String) -> URL {
    layer.appendingPathComponent("runtime-components/impeccable-engine/\(version)/riscv64gc-unknown-linux-musl/floe-impeccable", isDirectory: false)
}

/// Happy-path wiring shared by the end-to-end tests: fixture + plan recorded,
/// runner configured for the exact probe handshake.
private func makePreparedChain(
    appVersion: String = "1.7.59",
    generation: UInt64? = 7,
    contractVersion: Int = 1
) async throws -> (harness: ComponentCenterHarness, component: ComponentFixture, staged: StagedSkillFixture, authority: SkillRuntimeComponentAuthority, runID: UUID) {
    let component = try makeComponentFixture(contractVersion: contractVersion)
    let staged = try await makeStagedSkillFixture(descriptorBytes: component.descriptorBytes)
    let authority = makeAuthority(fixture: staged, descriptorBytes: component.descriptorBytes)
    let harness = makeHarness(
        layers: [staged.environmentID: staged.layer],
        pathMaps: [staged.environmentID: staged.pathMap],
        generation: generation, appVersion: appVersion
    )
    harness.transport.handler = { _ in component.engineBytes }
    harness.setProvider { skillID in skillID == staged.skillID ? authority : nil }
    harness.runner.probeStdout = SkillRuntimeDependency.expectedProbeStdout(
        componentVersion: component.descriptor.componentVersion
    )
    harness.runner.contractStdout = String(decoding: component.contractBytes, as: UTF8.self)
    let runID = UUID()
    let outcome = await harness.center.recordPlan(
        skillID: staged.skillID,
        environmentID: staged.environmentID,
        workspaceRootURL: staged.workspace,
        runID: runID,
        stagedGuestRoot: staged.stagedGuestRoot,
        authority: authority
    )
    guard case .recorded = outcome else {
        throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "recordPlan rejected: \(outcome)"])
    }
    return (harness, component, staged, authority, runID)
}

// MARK: - Suite

@MainActor
@Suite(.serialized) struct SkillRuntimeComponentTests {

    // MARK: Plan recording

    @Test func recordPlanWithoutEnvironmentIsRejected() async throws {
        let component = try makeComponentFixture()
        let staged = try await makeStagedSkillFixture(descriptorBytes: component.descriptorBytes)
        let authority = makeAuthority(fixture: staged, descriptorBytes: component.descriptorBytes)
        let harness = makeHarness(layers: [:], pathMaps: [:])
        let outcome = await harness.center.recordPlan(
            skillID: staged.skillID, environmentID: nil, workspaceRootURL: staged.workspace,
            runID: UUID(), stagedGuestRoot: staged.stagedGuestRoot, authority: authority
        )
        #expect(outcome == .rejected(reason: SkillRuntimeComponentReason.noEnvironment))
    }

    @Test func recordPlanWithoutRunIsRejected() async throws {
        let component = try makeComponentFixture()
        let staged = try await makeStagedSkillFixture(descriptorBytes: component.descriptorBytes)
        let authority = makeAuthority(fixture: staged, descriptorBytes: component.descriptorBytes)
        let harness = makeHarness(layers: [staged.environmentID: staged.layer], pathMaps: [:])
        let outcome = await harness.center.recordPlan(
            skillID: staged.skillID, environmentID: staged.environmentID, workspaceRootURL: staged.workspace,
            runID: nil, stagedGuestRoot: staged.stagedGuestRoot, authority: authority
        )
        #expect(outcome == .rejected(reason: SkillRuntimeComponentReason.noRun))
    }

    @Test func recordPlanWithoutStagedBundleIsRejected() async throws {
        let component = try makeComponentFixture()
        let staged = try await makeStagedSkillFixture(descriptorBytes: component.descriptorBytes)
        let authority = makeAuthority(fixture: staged, descriptorBytes: component.descriptorBytes)
        let harness = makeHarness(layers: [staged.environmentID: staged.layer], pathMaps: [:])
        let outcome = await harness.center.recordPlan(
            skillID: staged.skillID, environmentID: staged.environmentID, workspaceRootURL: staged.workspace,
            runID: UUID(), stagedGuestRoot: nil, authority: authority
        )
        #expect(outcome == .rejected(reason: SkillRuntimeComponentReason.notStaged))
    }

    @Test func recordPlanWithoutAuthorityIsRejected() async throws {
        let component = try makeComponentFixture()
        let staged = try await makeStagedSkillFixture(descriptorBytes: component.descriptorBytes)
        let harness = makeHarness(layers: [staged.environmentID: staged.layer], pathMaps: [:])
        let outcome = await harness.center.recordPlan(
            skillID: staged.skillID, environmentID: staged.environmentID, workspaceRootURL: staged.workspace,
            runID: UUID(), stagedGuestRoot: staged.stagedGuestRoot, authority: nil
        )
        #expect(outcome == .rejected(reason: SkillRuntimeComponentReason.authorizationUnavailable))
    }

    @Test func recordPlanWithMismatchedSkillIDIsRejected() async throws {
        let component = try makeComponentFixture()
        let staged = try await makeStagedSkillFixture(descriptorBytes: component.descriptorBytes)
        let authority = makeAuthority(fixture: staged, descriptorBytes: component.descriptorBytes)
        let harness = makeHarness(layers: [staged.environmentID: staged.layer], pathMaps: [:])
        let outcome = await harness.center.recordPlan(
            skillID: "somebody-else", environmentID: staged.environmentID, workspaceRootURL: staged.workspace,
            runID: UUID(), stagedGuestRoot: staged.stagedGuestRoot, authority: authority
        )
        #expect(outcome == .rejected(reason: SkillRuntimeComponentReason.authorityRevoked))
    }

    @Test func recordPlanWithInvalidDescriptorIsRejected() async throws {
        let broken = Data("not json".utf8)
        let staged = try await makeStagedSkillFixture(descriptorBytes: broken)
        let authority = makeAuthority(fixture: staged, descriptorBytes: broken)
        let harness = makeHarness(layers: [staged.environmentID: staged.layer], pathMaps: [:])
        let outcome = await harness.center.recordPlan(
            skillID: staged.skillID, environmentID: staged.environmentID, workspaceRootURL: staged.workspace,
            runID: UUID(), stagedGuestRoot: staged.stagedGuestRoot, authority: authority
        )
        #expect(outcome == .rejected(reason: SkillRuntimeComponentReason.descriptorRejected))
        let state = await harness.center.state(environmentID: staged.environmentID, componentID: componentID)
        #expect(state.deferredReason == SkillRuntimeComponentReason.descriptorRejected)
    }

    @Test func recordPlanRejectsNonProductionOrUnapprovedReceipts() async throws {
        let component = try makeComponentFixture()
        let staged = try await makeStagedSkillFixture(descriptorBytes: component.descriptorBytes)
        let harness = makeHarness(layers: [staged.environmentID: staged.layer], pathMaps: [:])
        let authorities = [
            makeAuthority(fixture: staged, descriptorBytes: component.descriptorBytes, feedStatus: .fixture),
            makeAuthority(fixture: staged, descriptorBytes: component.descriptorBytes, reviewDecision: .reject),
            makeAuthority(fixture: staged, descriptorBytes: component.descriptorBytes, feedKeyID: CuratedSkillHub.fixtureKeyID),
            makeAuthority(fixture: staged, descriptorBytes: component.descriptorBytes, reviewKeyID: "foreign-key"),
            makeAuthority(fixture: staged, descriptorBytes: component.descriptorBytes, hubRepository: "someone/else"),
            makeAuthority(fixture: staged, descriptorBytes: component.descriptorBytes, publicationY: "not-a-commit")
        ]
        for authority in authorities {
            let outcome = await harness.center.recordPlan(
                skillID: staged.skillID, environmentID: staged.environmentID, workspaceRootURL: staged.workspace,
                runID: UUID(), stagedGuestRoot: staged.stagedGuestRoot, authority: authority
            )
            #expect(outcome == .rejected(reason: SkillRuntimeComponentReason.authorityRevoked))
        }
    }

    @Test func recordPlanRejectsIncompatibleAppVersion() async throws {
        let component = try makeComponentFixture()
        let staged = try await makeStagedSkillFixture(descriptorBytes: component.descriptorBytes)
        let authority = makeAuthority(fixture: staged, descriptorBytes: component.descriptorBytes)
        let harness = makeHarness(
            layers: [staged.environmentID: staged.layer], pathMaps: [:], appVersion: "1.7.58"
        )
        let outcome = await harness.center.recordPlan(
            skillID: staged.skillID, environmentID: staged.environmentID, workspaceRootURL: staged.workspace,
            runID: UUID(), stagedGuestRoot: staged.stagedGuestRoot, authority: authority
        )
        #expect(outcome == .rejected(reason: SkillRuntimeComponentReason.incompatibleAppVersion))
    }

    @Test func recordPlanRejectsUnsupportedCaptureContractBeforeAnyIO() async throws {
        let component = try makeComponentFixture(contractVersion: 2)
        let staged = try await makeStagedSkillFixture(descriptorBytes: component.descriptorBytes)
        let authority = makeAuthority(fixture: staged, descriptorBytes: component.descriptorBytes)
        let harness = makeHarness(layers: [staged.environmentID: staged.layer], pathMaps: [:])
        let outcome = await harness.center.recordPlan(
            skillID: staged.skillID, environmentID: staged.environmentID, workspaceRootURL: staged.workspace,
            runID: UUID(), stagedGuestRoot: staged.stagedGuestRoot, authority: authority
        )
        #expect(outcome == .rejected(reason: SkillRuntimeComponentReason.unsupportedContract))
        #expect(harness.transport.callHistory().isEmpty)
        #expect(harness.runner.callHistory().isEmpty)
    }

    @Test func recordPlanNeverExecutesOrDownloads() async throws {
        let (harness, _, _, _, _) = try await makePreparedChain()
        #expect(harness.transport.callHistory().isEmpty)
        #expect(harness.runner.callHistory().isEmpty)
    }

    // MARK: End-to-end happy path

    @Test func prepareBindingsRunsTheFullTrustedChain() async throws {
        let (harness, component, staged, _, runID) = try await makePreparedChain()
        let bindings = await harness.center.prepareBindings(
            environmentID: staged.environmentID, runID: runID, cancellation: nil
        )
        let expectedEngine = expectedEngineGuestPath(component.descriptor.componentVersion)
        #expect(bindings?[SkillRuntimeComponentCenter.engineEnvironmentVariable] == expectedEngine)
        #expect(bindings?[SkillRuntimeComponentCenter.skillDirEnvironmentVariable] == staged.stagedGuestRoot)

        // Same-Y fetch through the GitHub-only transport, exactly once.
        let calls = harness.transport.callHistory()
        #expect(calls == [FakeTransportCall(
            owner: CuratedSkillHub.owner, repository: CuratedSkillHub.repository,
            ref: fixturePublicationY, path: component.descriptor.artifact.path
        )])

        // Fixed native verbs only, in order, no shell-tool recursion.
        let runs = harness.runner.callHistory()
        #expect(runs.map(\.argv) == [
            ["/bin/chmod", "0755", expectedEngine],
            [expectedEngine, "engine-probe"],
            [expectedEngine, "contract"]
        ])

        // Staged bytes in the environment write layer match the artifact.
        let stagedFile = stagedHostPath(layer: staged.layer, version: component.descriptor.componentVersion)
        #expect((try? Data(contentsOf: stagedFile)) == component.engineBytes)

        let state = await harness.center.state(environmentID: staged.environmentID, componentID: componentID)
        #expect(state.planRecorded && state.sourceAuthorized && state.cacheVerified && state.stagedVerified && state.probed)
        #expect(state.deferredReason == nil)
    }

    @Test func prepareBindingsWithoutPlanReturnsNothing() async throws {
        let harness = makeHarness(layers: ["env": makeTemporaryDirectory("layer")], pathMaps: [:])
        let bindings = await harness.center.prepareBindings(environmentID: "env", runID: UUID(), cancellation: nil)
        #expect(bindings == nil)
        let state = await harness.center.state(environmentID: "env", componentID: componentID)
        #expect(state.planRecorded == false)
        #expect(state.deferredReason == nil)
    }

    @Test func prepareBindingsNeverCrossesRunsOrEnvironments() async throws {
        let (harness, _, staged, _, runA) = try await makePreparedChain()
        let otherRun = await harness.center.prepareBindings(environmentID: staged.environmentID, runID: UUID(), cancellation: nil)
        let otherEnvironment = await harness.center.prepareBindings(environmentID: "env-other", runID: runA, cancellation: nil)
        #expect(otherRun == nil)
        #expect(otherEnvironment == nil)
        #expect(harness.transport.callHistory().isEmpty)
        #expect(harness.runner.callHistory().isEmpty)
    }

    // MARK: Cache/download negatives

    @Test func prepareBindingsRejectsTruncatedArtifact() async throws {
        let (harness, component, staged, _, runID) = try await makePreparedChain()
        let truncated = Data(component.engineBytes.dropLast(8))
        harness.transport.handler = { _ in truncated }
        let bindings = await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        #expect(bindings == nil)
        let state = await harness.center.state(environmentID: staged.environmentID, componentID: componentID)
        #expect(state.deferredReason == SkillRuntimeComponentReason.artifactSizeMismatch)
        #expect(state.stagedVerified == false && state.probed == false)
        // Nothing committed into the environment write layer.
        #expect(FileManager.default.fileExists(atPath: stagedHostPath(
            layer: staged.layer, version: component.descriptor.componentVersion
        ).path) == false)
    }

    @Test func prepareBindingsRejectsDigestMismatch() async throws {
        let component = try makeComponentFixture() // descriptor pins THESE bytes
        let different = makeELF64Bytes(eType: 3)     // same size, different sha
        let staged = try await makeStagedSkillFixture(descriptorBytes: component.descriptorBytes)
        let authority = makeAuthority(fixture: staged, descriptorBytes: component.descriptorBytes)
        let harness = makeHarness(
            layers: [staged.environmentID: staged.layer],
            pathMaps: [staged.environmentID: staged.pathMap]
        )
        harness.transport.handler = { _ in different }
        harness.setProvider { skillID in skillID == staged.skillID ? authority : nil }
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: staged.skillID, environmentID: staged.environmentID, workspaceRootURL: staged.workspace,
            runID: runID, stagedGuestRoot: staged.stagedGuestRoot, authority: authority
        )
        let bindings = await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        #expect(bindings == nil)
        let state = await harness.center.state(environmentID: staged.environmentID, componentID: componentID)
        #expect(state.deferredReason == SkillRuntimeComponentReason.artifactDigestMismatch)
    }

    @Test func prepareBindingsRejectsNonStaticELFBytes() async throws {
        // Bytes whose sha matches the descriptor but which are NOT an ELF.
        let notELF = Data("these are not elf bytes at all, but they are pinned".utf8)
        let component = try makeComponentFixture(engineBytes: notELF)
        let staged = try await makeStagedSkillFixture(descriptorBytes: component.descriptorBytes)
        let authority = makeAuthority(fixture: staged, descriptorBytes: component.descriptorBytes)
        let harness = makeHarness(
            layers: [staged.environmentID: staged.layer],
            pathMaps: [staged.environmentID: staged.pathMap]
        )
        harness.transport.handler = { _ in notELF }
        harness.setProvider { skillID in skillID == staged.skillID ? authority : nil }
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: staged.skillID, environmentID: staged.environmentID, workspaceRootURL: staged.workspace,
            runID: runID, stagedGuestRoot: staged.stagedGuestRoot, authority: authority
        )
        let bindings = await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        #expect(bindings == nil)
        let state = await harness.center.state(environmentID: staged.environmentID, componentID: componentID)
        #expect(state.deferredReason == SkillRuntimeComponentReason.artifactRejected)
    }

    @Test func prepareBindingsHonestDeferralWhenHubUnavailableWithoutCache() async throws {
        let (harness, _, staged, _, runID) = try await makePreparedChain()
        harness.transport.handler = { _ in
            throw NSError(domain: "offline", code: -1)
        }
        let bindings = await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        #expect(bindings == nil)
        let state = await harness.center.state(environmentID: staged.environmentID, componentID: componentID)
        #expect(state.deferredReason == SkillRuntimeComponentReason.hubUnavailable)
        #expect(state.cacheVerified == false)
    }

    @Test func prepareBindingsReusesVerifiedCacheOffline() async throws {
        // First center downloads and stages; a SECOND center (fresh plans)
        // with a throwing transport still succeeds from the verified cache.
        let component = try makeComponentFixture()
        let staged = try await makeStagedSkillFixture(descriptorBytes: component.descriptorBytes)
        let authority = makeAuthority(fixture: staged, descriptorBytes: component.descriptorBytes)
        let authorization = FakeComponentAuthorization { skillID in
            skillID == staged.skillID ? authority : nil
        }
        let transport = FakeComponentTransport()
        transport.handler = { _ in component.engineBytes }
        let cacheRoot = makeTemporaryDirectory("cache-shared")
        let makeCenter = {
            SkillRuntimeComponentCenter(
                environmentResolver: { _ in
                    SkillRuntimeComponentEnvironment(layerURL: staged.layer, isLinuxVM: true, isActive: true)
                },
                runner: FakeComponentRunner(),
                cacheRoot: cacheRoot,
                pathMapping: { _ in staged.pathMap },
                launchGeneration: { _ in 7 },
                appVersion: { "1.7.59" },
                bindings: SkillRuntimeComponentLateBindings(
                    transport: { owner, repository, ref, path in
                        try await transport.fetch(owner, repository, ref, path)
                    },
                    authorization: { skillID in
                        authorization.authorize(skillID)
                    }
                )
            )
        }
        let first = makeCenter()
        let runOne = UUID()
        _ = await first.recordPlan(
            skillID: staged.skillID, environmentID: staged.environmentID, workspaceRootURL: staged.workspace,
            runID: runOne, stagedGuestRoot: staged.stagedGuestRoot, authority: authority
        )
        let firstBindings = await first.prepareBindings(environmentID: staged.environmentID, runID: runOne, cancellation: nil)
        #expect(firstBindings != nil)

        transport.handler = { _ in
            throw NSError(domain: "offline", code: -1)
        }
        let second = makeCenter()
        let runTwo = UUID()
        _ = await second.recordPlan(
            skillID: staged.skillID, environmentID: staged.environmentID, workspaceRootURL: staged.workspace,
            runID: runTwo, stagedGuestRoot: staged.stagedGuestRoot, authority: authority
        )
        let secondBindings = await second.prepareBindings(environmentID: staged.environmentID, runID: runTwo, cancellation: nil)
        #expect(secondBindings?[SkillRuntimeComponentCenter.engineEnvironmentVariable]
                == expectedEngineGuestPath(component.descriptor.componentVersion))
    }

    // MARK: Staging negatives

    @Test func prepareBindingsPreservesForeignStagedEntryAndFailsClosed() async throws {
        let (harness, component, staged, _, runID) = try await makePreparedChain()
        let target = stagedHostPath(layer: staged.layer, version: component.descriptor.componentVersion)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("foreign-bytes").write(to: target, options: .atomic)
        let bindings = await harness.center.prepareBindings(
            environmentID: staged.environmentID, runID: runID, cancellation: nil
        )
        #expect(bindings == nil)
        #expect((try? Data(contentsOf: target)) == Data("foreign-bytes"))
        let state = await harness.center.state(environmentID: staged.environmentID, componentID: componentID)
        #expect(state.deferredReason == SkillRuntimeComponentReason.stagedPathBlocked)
    }

    @Test func prepareBindingsPreservesDamagedStagedEntryAndFailsClosed() async throws {
        let (harness, component, staged, _, runID) = try await makePreparedChain()
        var damaged = component.engineBytes
        damaged[64] = damaged[64] ^ 0xFF
        let target = stagedHostPath(layer: staged.layer, version: component.descriptor.componentVersion)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try damaged.write(to: target, options: .atomic)
        let bindings = await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        #expect(bindings == nil)
        #expect((try? Data(contentsOf: target)) == damaged)
        let state = await harness.center.state(environmentID: staged.environmentID, componentID: componentID)
        #expect(state.deferredReason == SkillRuntimeComponentReason.stagedPathBlocked)
        #expect(state.stagedVerified == false)
    }

    @Test func prepareBindingsFailsClosedOnReservedRootConflict() async throws {
        let (harness, _, staged, _, runID) = try await makePreparedChain()
        let rootFile = staged.layer.appendingPathComponent("runtime-components", isDirectory: false)
        try Data("not-a-directory").write(to: rootFile, options: .atomic)
        let bindings = await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        #expect(bindings == nil)
        #expect((try? Data(contentsOf: rootFile)) == Data("not-a-directory"))
        let state = await harness.center.state(environmentID: staged.environmentID, componentID: componentID)
        #expect(state.deferredReason == SkillRuntimeComponentReason.existingRootConflict)
    }

    @Test func prepareBindingsAdoptsAlreadyVerifiedStagedEntry() async throws {
        let (harness, component, staged, _, runID) = try await makePreparedChain()
        // Plant VERIFIED bytes at the staged path; the cache is empty, so
        // without adoption this would try to download (and fail).
        let target = stagedHostPath(layer: staged.layer, version: component.descriptor.componentVersion)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try component.engineBytes.write(to: target, options: .atomic)
        try FileManager.default.removeItem(at: harness.cacheRoot)
        harness.transport.handler = { _ in
            throw NSError(domain: "must-not-download", code: -1)
        }
        let bindings = await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        #expect(bindings?[SkillRuntimeComponentCenter.engineEnvironmentVariable]
                == expectedEngineGuestPath(component.descriptor.componentVersion))
        #expect(harness.transport.callHistory().isEmpty)
    }

    // MARK: Probe negatives + staged-vs-probed distinction

    @Test func prepareBindingsRejectsFailedChmodVerb() async throws {
        let (harness, component, staged, _, runID) = try await makePreparedChain()
        harness.runner.chmodExit = 7
        let bindings = await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        #expect(bindings == nil)
        let state = await harness.center.state(environmentID: staged.environmentID, componentID: componentID)
        #expect(state.deferredReason == SkillRuntimeComponentReason.probeFailed("chmod", exitCode: 7))
        #expect(state.stagedVerified == true)
        #expect(state.probed == false)
        let stagedFile = stagedHostPath(layer: staged.layer, version: component.descriptor.componentVersion)
        #expect((try? Data(contentsOf: stagedFile)) == component.engineBytes)
    }

    @Test func prepareBindingsRejectsWrongProbeHandshake() async throws {
        let (harness, _, staged, _, runID) = try await makePreparedChain()
        harness.runner.probeStdout = "impeccable-engine 9.9.9+floe.9.9.9\n"
        let bindings = await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        #expect(bindings == nil)
        let state = await harness.center.state(environmentID: staged.environmentID, componentID: componentID)
        #expect(state.deferredReason == SkillRuntimeComponentReason.probeStdoutMismatch)
        #expect(state.stagedVerified == true)
        #expect(state.probed == false)
    }

    @Test func prepareBindingsRejectsContractDigestMismatch() async throws {
        let (harness, _, staged, _, runID) = try await makePreparedChain()
        harness.runner.contractStdout = "{\"contract\":\"floe.impeccable.snapshot\",\"contractVersion\":1,\"tampered\":true}"
        let bindings = await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        #expect(bindings == nil)
        let state = await harness.center.state(environmentID: staged.environmentID, componentID: componentID)
        #expect(state.deferredReason == SkillRuntimeComponentReason.contractDigestMismatch)
        #expect(state.probed == false)
    }

    @Test func prepareBindingsRejectsFailingContractVerb() async throws {
        let (harness, _, staged, _, runID) = try await makePreparedChain()
        harness.runner.contractExit = 1
        let bindings = await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        #expect(bindings == nil)
        let state = await harness.center.state(environmentID: staged.environmentID, componentID: componentID)
        #expect(state.deferredReason == SkillRuntimeComponentReason.probeFailed("contract", exitCode: 1))
        #expect(state.stagedVerified == true)
        #expect(state.probed == false)
    }

    @Test func prepareBindingsRejectsUnsupportedContractBeforeDownload() async throws {
        // The pre-download gate fires even with a fully working chain.
        let component = try makeComponentFixture(contractVersion: 2)
        let staged = try await makeStagedSkillFixture(descriptorBytes: component.descriptorBytes)
        let authority = makeAuthority(fixture: staged, descriptorBytes: component.descriptorBytes)
        let harness = makeHarness(
            layers: [staged.environmentID: staged.layer],
            pathMaps: [staged.environmentID: staged.pathMap]
        )
        harness.transport.handler = { _ in component.engineBytes }
        harness.setProvider { skillID in skillID == staged.skillID ? authority : nil }
        let runID = UUID()
        _ = await harness.center.recordPlan(
            skillID: staged.skillID, environmentID: staged.environmentID, workspaceRootURL: staged.workspace,
            runID: runID, stagedGuestRoot: staged.stagedGuestRoot, authority: authority
        )
        let bindings = await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        #expect(bindings == nil)
        let state = await harness.center.state(environmentID: staged.environmentID, componentID: componentID)
        #expect(state.deferredReason == SkillRuntimeComponentReason.unsupportedContract)
        #expect(harness.transport.callHistory().isEmpty)
        #expect(harness.runner.callHistory().isEmpty)
    }

    @Test func prepareBindingsReportsMissingRunnerHonestly() async throws {
        let component = try makeComponentFixture()
        let staged = try await makeStagedSkillFixture(descriptorBytes: component.descriptorBytes)
        let authority = makeAuthority(fixture: staged, descriptorBytes: component.descriptorBytes)
        let transport = FakeComponentTransport()
        transport.handler = { _ in component.engineBytes }
        let center = SkillRuntimeComponentCenter(
            environmentResolver: { _ in
                SkillRuntimeComponentEnvironment(layerURL: staged.layer, isLinuxVM: true, isActive: true)
            },
            runner: nil,
            cacheRoot: makeTemporaryDirectory("cache"),
            pathMapping: { _ in staged.pathMap },
            launchGeneration: { _ in 7 },
            appVersion: { "1.7.59" },
            bindings: SkillRuntimeComponentLateBindings(
                transport: { owner, repository, ref, path in
                    try await transport.fetch(owner, repository, ref, path)
                },
                authorization: { _ in authority }
            )
        )
        let runID = UUID()
        _ = await center.recordPlan(
            skillID: staged.skillID, environmentID: staged.environmentID, workspaceRootURL: staged.workspace,
            runID: runID, stagedGuestRoot: staged.stagedGuestRoot, authority: authority
        )
        let bindings = await center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        #expect(bindings == nil)
        let state = await center.state(environmentID: staged.environmentID, componentID: componentID)
        #expect(state.deferredReason == SkillRuntimeComponentReason.probeUnavailable)
        #expect(state.stagedVerified == true)
        #expect(state.probed == false)
    }

    // MARK: Receipt reuse / generation binding

    @Test func prepareBindingsReusesReceiptWithoutReprobing() async throws {
        let (harness, _, staged, _, runID) = try await makePreparedChain()
        let first = await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        #expect(first != nil)
        #expect(harness.runner.callHistory().count == 3)
        harness.transport.handler = { _ in
            throw NSError(domain: "must-not-download", code: -1)
        }
        let second = await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        #expect(second == first)
        #expect(harness.runner.callHistory().count == 3)
    }

    @Test func prepareBindingsReprobesAfterGuestGenerationRotates() async throws {
        let (harness, _, staged, _, runID) = try await makePreparedChain()
        let first = await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        #expect(first != nil)
        #expect(harness.runner.callHistory().count == 3)
        harness.generation.set(8) // guest restarted: the registry rotates this
        let second = await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        #expect(second != nil)
        #expect(harness.runner.callHistory().count == 6)
        #expect(harness.transport.callHistory().count == 1) // staged bytes re-verified, not re-downloaded
    }

    @Test func prepareBindingsNeverReusesAcrossEnvironments() async throws {
        let component = try makeComponentFixture()
        let stagedA = try await makeStagedSkillFixture(descriptorBytes: component.descriptorBytes)
        let stagedB = try await makeStagedSkillFixture(descriptorBytes: component.descriptorBytes)
        let authorityA = makeAuthority(fixture: stagedA, descriptorBytes: component.descriptorBytes)
        let authorityB = makeAuthority(fixture: stagedB, descriptorBytes: component.descriptorBytes)
        let harness = makeHarness(
            layers: [stagedA.environmentID: stagedA.layer, stagedB.environmentID: stagedB.layer],
            pathMaps: [stagedA.environmentID: stagedA.pathMap, stagedB.environmentID: stagedB.pathMap]
        )
        harness.transport.handler = { _ in component.engineBytes }
        harness.setProvider { skillID in
            if skillID == stagedA.skillID { return authorityA }
            if skillID == stagedB.skillID { return authorityB }
            return nil
        }
        let runA = UUID(), runB = UUID()
        _ = await harness.center.recordPlan(
            skillID: stagedA.skillID, environmentID: stagedA.environmentID, workspaceRootURL: stagedA.workspace,
            runID: runA, stagedGuestRoot: stagedA.stagedGuestRoot, authority: authorityA
        )
        _ = await harness.center.recordPlan(
            skillID: stagedB.skillID, environmentID: stagedB.environmentID, workspaceRootURL: stagedB.workspace,
            runID: runB, stagedGuestRoot: stagedB.stagedGuestRoot, authority: authorityB
        )
        let bindingsA = await harness.center.prepareBindings(environmentID: stagedA.environmentID, runID: runA, cancellation: nil)
        let bindingsB = await harness.center.prepareBindings(environmentID: stagedB.environmentID, runID: runB, cancellation: nil)
        #expect(bindingsA != nil && bindingsB != nil)
        #expect(harness.runner.callHistory().count == 6)
        #expect((try? Data(contentsOf: stagedHostPath(
            layer: stagedA.layer, version: component.descriptor.componentVersion
        ))) == component.engineBytes)
        #expect((try? Data(contentsOf: stagedHostPath(
            layer: stagedB.layer, version: component.descriptor.componentVersion
        ))) == component.engineBytes)
    }

    // MARK: Revocation / cancellation

    @Test func prepareBindingsDropsPlanWhenAuthorizationRevoked() async throws {
        let (harness, _, staged, authority, runID) = try await makePreparedChain()
        harness.setProvider { _ in nil }
        let bindings = await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        #expect(bindings == nil)
        let state = await harness.center.state(environmentID: staged.environmentID, componentID: componentID)
        #expect(state.deferredReason == SkillRuntimeComponentReason.authorityRevoked)
        #expect(state.sourceAuthorized == false)
        // The plan was dropped: even with authority restored, no late ready.
        harness.setProvider { skillID in skillID == authority.skillID ? authority : nil }
        let again = await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        #expect(again == nil)
        #expect(harness.transport.callHistory().isEmpty)
        #expect(harness.runner.callHistory().isEmpty)
    }

    @Test func prepareBindingsRevocationMidDownloadCannotIssueLateReady() async throws {
        let (harness, component, staged, _, runID) = try await makePreparedChain()
        let gate = TransportGate()
        harness.transport.gate = gate
        let preparation = Task {
            await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        }
        while harness.transport.callHistory().isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        harness.setProvider { _ in nil } // disable mid-download
        await gate.openGate()
        let bindings = await preparation.value
        #expect(bindings == nil)
        let state = await harness.center.state(environmentID: staged.environmentID, componentID: componentID)
        #expect(state.deferredReason == SkillRuntimeComponentReason.authorityRevoked)
        // Staging never happened: the post-download reauthorization fenced it.
        #expect(FileManager.default.fileExists(atPath: stagedHostPath(
            layer: staged.layer, version: component.descriptor.componentVersion
        ).path) == false)
    }

    @Test func prepareBindingsCancellationDuringDownloadLeavesNoPartialReady() async throws {
        let (harness, component, staged, _, runID) = try await makePreparedChain()
        let gate = TransportGate()
        harness.transport.gate = gate
        let callerToken = CancellationToken()
        let preparation = Task {
            await harness.center.prepareBindings(
                environmentID: staged.environmentID, runID: runID, cancellation: callerToken
            )
        }
        while harness.transport.callHistory().isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        callerToken.cancel()
        await gate.openGate()
        let bindings = await preparation.value
        #expect(bindings == nil)
        let state = await harness.center.state(environmentID: staged.environmentID, componentID: componentID)
        #expect(state.deferredReason == SkillRuntimeComponentReason.cancelled)
        #expect(state.probed == false)
        #expect(FileManager.default.fileExists(atPath: stagedHostPath(
            layer: staged.layer, version: component.descriptor.componentVersion
        ).path) == false)
        // A fresh uncancelled run succeeds end to end: no partial ready, no
        // corrupted staging, and the cached download is reused.
        let retry = await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        #expect(retry != nil)
        #expect(harness.transport.callHistory().count == 1)
    }

    @Test func releaseEnvironmentCancelsAndJoinsOwnedPreparation() async throws {
        let (harness, _, staged, _, runID) = try await makePreparedChain()
        let gate = TransportGate()
        harness.transport.gate = gate
        let preparation = Task {
            await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        }
        while harness.transport.callHistory().isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        // releaseEnvironment must cancel + JOIN the in-flight preparation.
        await harness.center.releaseEnvironment(staged.environmentID)
        await gate.openGate()
        let bindings = await preparation.value
        #expect(bindings == nil)
        let state = await harness.center.state(environmentID: staged.environmentID, componentID: componentID)
        #expect(state.planRecorded == false)
        #expect(harness.runner.callHistory().isEmpty)
    }

    @Test func oneEnvironmentsCancellationNeverAbortsAnotherEnvironmentsSharedDownload() async throws {
        let component = try makeComponentFixture()
        let stagedA = try await makeStagedSkillFixture(descriptorBytes: component.descriptorBytes)
        let stagedB = try await makeStagedSkillFixture(descriptorBytes: component.descriptorBytes)
        let authorityA = makeAuthority(fixture: stagedA, descriptorBytes: component.descriptorBytes)
        let authorityB = makeAuthority(fixture: stagedB, descriptorBytes: component.descriptorBytes)
        let harness = makeHarness(
            layers: [stagedA.environmentID: stagedA.layer, stagedB.environmentID: stagedB.layer],
            pathMaps: [stagedA.environmentID: stagedA.pathMap, stagedB.environmentID: stagedB.pathMap]
        )
        harness.transport.handler = { _ in component.engineBytes }
        harness.setProvider { skillID in
            if skillID == stagedA.skillID { return authorityA }
            if skillID == stagedB.skillID { return authorityB }
            return nil
        }
        let runA = UUID(), runB = UUID()
        _ = await harness.center.recordPlan(
            skillID: stagedA.skillID, environmentID: stagedA.environmentID, workspaceRootURL: stagedA.workspace,
            runID: runA, stagedGuestRoot: stagedA.stagedGuestRoot, authority: authorityA
        )
        _ = await harness.center.recordPlan(
            skillID: stagedB.skillID, environmentID: stagedB.environmentID, workspaceRootURL: stagedB.workspace,
            runID: runB, stagedGuestRoot: stagedB.stagedGuestRoot, authority: authorityB
        )
        let gate = TransportGate()
        harness.transport.gate = gate
        let prepA = Task {
            await harness.center.prepareBindings(environmentID: stagedA.environmentID, runID: runA, cancellation: nil)
        }
        let prepB = Task {
            await harness.center.prepareBindings(environmentID: stagedB.environmentID, runID: runB, cancellation: nil)
        }
        // One shared download serves both environments.
        while harness.transport.callHistory().isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        await harness.center.releaseEnvironment(stagedA.environmentID)
        await gate.openGate()
        let bindingsA = await prepA.value
        let bindingsB = await prepB.value
        #expect(bindingsA == nil) // cancelled + joined
        #expect(bindingsB != nil) // the shared service-owned transfer completed
        #expect(harness.transport.callHistory().count == 1)
        #expect(harness.runner.callHistory().count == 3) // only B probed
        let stagedFileB = stagedHostPath(layer: stagedB.layer, version: component.descriptor.componentVersion)
        #expect((try? Data(contentsOf: stagedFileB)) == component.engineBytes)
    }

    // MARK: Staged bundle integrity

    @Test func prepareBindingsDetectsTamperedStagedSkillBundle() async throws {
        let (harness, _, staged, _, runID) = try await makePreparedChain()
        let skillFile = staged.stagedHostRoot.appendingPathComponent("SKILL.md", isDirectory: false)
        var bytes = try Data(contentsOf: skillFile)
        bytes[0] = bytes[0] == UInt8(ascii: "-") ? UInt8(ascii: "=") : UInt8(ascii: "-")
        try bytes.write(to: skillFile, options: .atomic)
        let bindings = await harness.center.prepareBindings(environmentID: staged.environmentID, runID: runID, cancellation: nil)
        #expect(bindings == nil)
        let state = await harness.center.state(environmentID: staged.environmentID, componentID: componentID)
        #expect(state.deferredReason == SkillRuntimeComponentReason.stagedBundleInvalid)
    }

    // MARK: SkillsCenter authority gate (verified installed snapshot + grants)

    @Test func runtimeComponentAuthorityAcceptsOnlyVerifiedInstalledSnapshots() async throws {
        let component = try makeComponentFixture()
        let staged = try await makeStagedSkillFixture(descriptorBytes: component.descriptorBytes)
        let row = try fixtureRow(staged: staged)
        let authority = SkillsCenter.runtimeComponentAuthority(
            row: row, snapshot: staged.snapshot, grantedCapabilities: []
        )
        #expect(authority != nil)
        #expect(authority?.publicationCommit == fixturePublicationY)
        #expect(authority?.contentDigest == staged.snapshot.package.canonicalSHA256)
    }

    @Test func runtimeComponentAuthorityRefusesDisabledEditedImportedForgedOrGrantRevokedRows() async throws {
        let component = try makeComponentFixture()
        let staged = try await makeStagedSkillFixture(descriptorBytes: component.descriptorBytes)
        func makeRow(status: String = "enabled", digest: String? = nil, report: String? = nil) throws -> PersistedSkill {
            try fixtureRow(staged: staged, status: status, digestOverride: digest, reportOverride: report)
        }
        // Disabled row.
        #expect(try SkillsCenter.runtimeComponentAuthority(
            row: makeRow(status: "disabled"), snapshot: staged.snapshot, grantedCapabilities: []
        ) == nil)
        // Edited row: digest no longer matches the pinned snapshot.
        #expect(try SkillsCenter.runtimeComponentAuthority(
            row: makeRow(digest: String(repeating: "f", count: 64)),
            snapshot: staged.snapshot, grantedCapabilities: []
        ) == nil)
        // Imported same-ID copy: no curated receipt at all.
        #expect(try SkillsCenter.runtimeComponentAuthority(
            row: makeRow(report: "{}"), snapshot: staged.snapshot, grantedCapabilities: []
        ) == nil)
        // Forged receipt: the receipt's contentDigest does not match the row.
        let forged = try curatedReceiptJSON(
            contentDigest: String(repeating: "f", count: 64),
            entryID: staged.skillID, entryVersion: staged.manifest.version
        )
        #expect(try SkillsCenter.runtimeComponentAuthority(
            row: makeRow(report: forged), snapshot: staged.snapshot, grantedCapabilities: []
        ) == nil)
        // Revoked declared grant: the pinned manifest declares a capability
        // the current persisted grants no longer cover.
        let capable = try await makeStagedSkillFixture(
            descriptorBytes: component.descriptorBytes,
            capabilities: [SkillCapability.remoteExecution.rawValue]
        )
        let capableRow = try fixtureRow(staged: capable)
        #expect(try SkillsCenter.runtimeComponentAuthority(
            row: capableRow, snapshot: capable.snapshot, grantedCapabilities: []
        ) == nil)
        #expect(try SkillsCenter.runtimeComponentAuthority(
            row: capableRow, snapshot: capable.snapshot,
            grantedCapabilities: [SkillCapability.remoteExecution.rawValue]
        ) != nil)
    }

    // MARK: Routing integration

    @Test func routingBackendExportsNativeBindingsForTheRunAndOverridesCallerValues() async {
        let runner = FakeComponentRunner()
        let native = StubNativeShellBackend()
        let expectedEngine = "/floe/env/runtime-components/impeccable-engine/0.1.17+floe.1.0.0/riscv64gc-unknown-linux-musl/floe-impeccable"
        let backend = RoutingLocalShellBackend(
            native: native,
            guests: runner,
            prepareLinux: nil,
            prepareNativeComponents: { _, _, _ in
                [
                    SkillRuntimeComponentCenter.engineEnvironmentVariable: expectedEngine,
                    SkillRuntimeComponentCenter.skillDirEnvironmentVariable: "/workspace/.floe/skills/impeccable@digest"
                ]
            }
        )
        let workspace = makeTemporaryDirectory("routing-workspace")
        FloePlatformServices.shared.setLinuxCommandService(runner)
        defer { FloePlatformServices.shared.setLinuxCommandService(nil) }
        let request = ShellRunRequest(
            command: "echo hi",
            cwd: ".",
            rootURL: workspace,
            environment: [
                SkillRuntimeComponentCenter.engineEnvironmentVariable: "/evil/override",
                "MARKER": "1"
            ],
            sessionID: "routing-session",
            toolEnvironment: ToolEnvironment(
                id: "env-routing", writableLayerURL: workspace, layerURLs: [], variables: [:]
            )
        )
        let outcome = await backend.run(request, cancellation: nil)
        guard case .exited(let code, _, _, _, _, _) = outcome else {
            Issue.record("expected a guest exit, got \(outcome)")
            return
        }
        #expect(code == 0)
        guard let command = runner.lastShellCommand() else {
            Issue.record("the guest never received the framed command")
            return
        }
        // The native verified binding overrides the caller-supplied value.
        #expect(command.contains("export FLOE_IMPECCABLE_ENGINE='\(expectedEngine)';"))
        #expect(!command.contains("/evil/override"))
        // Unrelated caller variables pass through unchanged.
        #expect(command.contains("export MARKER='1';"))
        #expect(command.contains("echo hi"))
    }

    // MARK: Temp pruning

    @Test func pruneStaleComponentTempsRemovesOnlyOwnAbandonedFiles() throws {
        let directory = makeTemporaryDirectory("prune")
        let oldDate = Date(timeIntervalSinceNow: -SkillRuntimeComponentCenter.staleTemporaryAge - 60)
        // Own abandoned temporaries (BOTH prefixes), old enough.
        for name in [
            SkillRuntimeComponentCenter.stagingPrefix + UUID().uuidString,
            SkillRuntimeComponentCenter.downloadPrefix + UUID().uuidString
        ] {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            try Data("x").write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        }
        // Foreign / current / symlink / content entries must survive.
        let foreign = directory.appendingPathComponent(".staging-component-not-a-uuid", isDirectory: false)
        try Data("foreign").write(to: foreign, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: foreign.path)
        let current = directory.appendingPathComponent(SkillRuntimeComponentCenter.downloadPrefix + UUID().uuidString, isDirectory: false)
        try Data("current").write(to: current, options: .atomic)
        let content = directory.appendingPathComponent("floe-impeccable", isDirectory: false)
        try Data("content").write(to: content, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: content.path)
        let symlink = directory.appendingPathComponent(SkillRuntimeComponentCenter.stagingPrefix + UUID().uuidString, isDirectory: false)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: content)

        SkillRuntimeComponentCenter.pruneStaleComponentTemps(in: directory)

        #expect(FileManager.default.fileExists(atPath: foreign.path))
        #expect(FileManager.default.fileExists(atPath: current.path))
        #expect(FileManager.default.fileExists(atPath: content.path))
        #expect(FileManager.default.fileExists(atPath: symlink.path)) // symlink never followed/removed
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remaining.count == 4)
    }
}

// MARK: - Shared row fixture

private func fixtureRow(
    staged: StagedSkillFixture,
    status: String = "enabled",
    digestOverride: String? = nil,
    reportOverride: String? = nil
) throws -> PersistedSkill {
    let report = reportOverride ?? curatedReceiptJSON(
        contentDigest: staged.snapshot.package.canonicalSHA256,
        entryID: staged.skillID,
        entryVersion: staged.manifest.version
    )
    return PersistedSkill(
        id: staged.skillID, name: "Impeccable Fixture", version: staged.manifest.version,
        status: status, skillMarkdown: "# Fixture",
        manifestJSON: String(decoding: try JSONEncoder().encode(staged.manifest), as: UTF8.self),
        rewrittenDigest: digestOverride ?? staged.snapshot.package.canonicalSHA256,
        compatibilityReportJSON: report
    )
}

/// Builds the hand-crafted curated receipt JSON a persisted row carries.
private func curatedReceiptJSON(contentDigest: String, entryID: String, entryVersion: String) -> String {
    let object: [String: Any] = [
        "receiptSchemaVersion": 1,
        "channel": "ios",
        "feedStatus": "production",
        "hubRepository": CuratedSkillHub.hubRepository,
        "publisher": CuratedSkillHub.publisher,
        "feedSignatureKeyID": CuratedSkillHub.productionKeyID,
        "auditedSourceCommit": String(repeating: "d", count: 40),
        "publicationCommit": fixturePublicationY,
        "catalogSHA256": String(repeating: "b", count: 64),
        "catalogByteCount": 100,
        "entryID": entryID,
        "entryVersion": entryVersion,
        "packagePath": "packages/\(entryID).zip",
        "packageSize": 1,
        "packageSHA256": String(repeating: "a", count: 64),
        "contentDigest": contentDigest,
        "containsScripts": false,
        "reviewPath": "reviews/\(entryID).json",
        "reviewSHA256": String(repeating: "c", count: 64),
        "reviewKeyID": CuratedSkillHub.productionKeyID,
        "reviewStage": "static-content-reviewed",
        "reviewDecision": "approve",
        "reviewedAt": "2026-10-26T00:00:00Z",
        "reviewer": "fixture",
        "permissionDelta": [
            "requiredCapabilities": [], "requiredTools": [], "requiredPythonPackageSpecs": [],
            "missingCapabilities": [], "missingTools": [], "missingPythonPackageSpecs": []
        ]
    ]
    let data = try! JSONSerialization.data(withJSONObject: ["curatedHubReceipt": object], options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}
#endif
