// FloeExecutionTests — dependency-aware exec.shell invocation seam + guest
// apt verbs.
//
// The shell-side half is the acceptance boundary Main owns: with `skillID`
// ABSENT the tool must be byte-for-byte the ordinary path (verification code
// never runs, the impeccable component hook semantics are untouched, and a
// refused skill cannot take the ordinary shell down); with `skillID` present
// the gate's answer decides — refusal never reaches the backend, a proceed
// annotation is prepended to the command result, an unwired gate or missing
// approval grant fails honestly, and the runtime-issued context values (not
// model-invented strings) are what the gate receives. The guest half locks
// the exact-pin apt transaction shape, dpkg readback parsing and the fixed
// CJK probe — validated argv, never arbitrary strings from JSON.
//
// None of these tests is a device/guest claim: the real TinyEMU runs remain
// Main-owned qualification.

import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

// MARK: - Recording backend

private final class ShellCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func record(_ command: String) { lock.withLock { entries.append(command) } }
    var calls: [String] { lock.withLock { entries } }
}

private final class RecordingShellBackend: LocalShellBackend, @unchecked Sendable {
    let recorder = ShellCallRecorder()
    func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        recorder.record(request.command)
        return .exited(code: 0, stdout: "ran", stderr: "", truncated: false, stderrTruncated: false, durationMs: 1)
    }
    func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
        throw FloeError.invalidConfiguration("not used")
    }
    func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
        throw FloeError.invalidConfiguration("not used")
    }
    func closeSession(sessionID: String) async {}
}

// MARK: - Gate fake

private final class ScriptedGate: SkillDependencyInvocationGating, @unchecked Sendable {
    struct Received: Sendable {
        let skillID: String
        let environmentID: String?
        let runID: UUID
        let approvalGrantID: UUID?
    }
    private let lock = NSLock()
    private var receivedCalls: [Received] = []
    var decision: SkillDependencyInvocationDecision = .proceed(annotation: "skillDependencies=verified")
    var calls: [Received] { lock.withLock { receivedCalls } }
    func dependencyInvocationDecision(
        skillID: String, environmentID: String?, runID: UUID,
        approvalGrantID: UUID?, cancellation: CancellationToken?
    ) async -> SkillDependencyInvocationDecision {
        lock.withLock { receivedCalls.append(.init(skillID: skillID, environmentID: environmentID, runID: runID, approvalGrantID: approvalGrantID)) }
        return decision
    }
}

private func makeWorkspace() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-shell-dep-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeService(backend: RecordingShellBackend) -> LocalShellService {
    LocalShellService(backend: backend, journal: ShellOperationJournal(), rootProvider: { nil })
}

private func makeContext(root: URL, environmentID: String? = "env-1", grant: UUID? = UUID()) -> ToolContext {
    var context = ToolContext(
        runID: UUID(),
        workspaceRootURL: root,
        cancellation: CancellationToken()
    )
    context.environmentID = environmentID
    context.approvalGrantID = grant
    return context
}

@Suite("FloeExecution.SkillDependencyShell", .serialized)
struct SkillDependencyShellTests {
    @Test func noSkillIDNeverTouchesTheGate() async throws {
        let backend = RecordingShellBackend()
        let gate = ScriptedGate()
        gate.decision = .refused(reason: "would-be refusal")
        let tool = LocalShellTool(shell: makeService(backend: backend), dependencyGate: gate)
        let root = makeWorkspace()
        let output = try await tool.execute(LocalShellTool.Arguments(command: "echo ordinary"), context: makeContext(root: root))
        #expect(output.summary.contains("ran"))
        #expect(backend.recorder.calls == ["echo ordinary"])
        #expect(gate.calls.isEmpty)
    }

    @Test func refusedDecisionIsNotExecutedAndNamesTheSkill() async throws {
        let backend = RecordingShellBackend()
        let gate = ScriptedGate()
        gate.decision = .refused(reason: "required dependency pip:pypdf is not ready: conflict")
        let tool = LocalShellTool(shell: makeService(backend: backend), dependencyGate: gate)
        let context = makeContext(root: makeWorkspace())
        let output = try await tool.execute(
            LocalShellTool.Arguments(command: "python3 build.py", skillID: "dep-skill"),
            context: context
        )
        #expect(output.summary.contains("status=skillDependencyNotReady"))
        #expect(output.summary.contains("skillID=dep-skill"))
        #expect(output.summary.contains("exit=75"))
        #expect(backend.recorder.calls.isEmpty)
        // Runtime-issued facts — never model-minted — reach the gate.
        #expect(gate.calls.count == 1)
        #expect(gate.calls[0].environmentID == "env-1")
        #expect(gate.calls[0].runID == context.runID)
        #expect(gate.calls[0].approvalGrantID == context.approvalGrantID)
    }

    @Test func proceedAnnotationPrependsAndCommandRuns() async throws {
        let backend = RecordingShellBackend()
        let gate = ScriptedGate()
        gate.decision = .proceed(annotation: "skillDependencies=verified pip:pypdf@5.4.0=venv 5.4.0")
        let tool = LocalShellTool(shell: makeService(backend: backend), dependencyGate: gate)
        let output = try await tool.execute(
            LocalShellTool.Arguments(command: "python3 build.py", skillID: "dep-skill"),
            context: makeContext(root: makeWorkspace())
        )
        #expect(backend.recorder.calls == ["python3 build.py"])
        #expect(output.summary.contains("--- skill dependencies ---"))
        #expect(output.summary.contains("pip:pypdf@5.4.0=venv 5.4.0"))
        #expect(output.summary.contains("exit=0"))
    }

    @Test func unavailableRefusesHonestlyAndMissingGrantRefusesBeforeTheGate() async throws {
        let backend = RecordingShellBackend()
        let gate = ScriptedGate()
        gate.decision = .unavailable(reason: "the resolved environment is unavailable")
        let tool = LocalShellTool(shell: makeService(backend: backend), dependencyGate: gate)
        let output = try await tool.execute(
            LocalShellTool.Arguments(command: "echo x", skillID: "dep-skill"),
            context: makeContext(root: makeWorkspace())
        )
        #expect(output.summary.contains("status=skillDependencyUnavailable"))
        #expect(output.summary.contains("exit=75"))
        #expect(backend.recorder.calls.isEmpty)

        let noGrant = try await tool.execute(
            LocalShellTool.Arguments(command: "echo x", skillID: "dep-skill"),
            context: makeContext(root: makeWorkspace(), grant: nil)
        )
        #expect(noGrant.summary.contains("approval grant"))
        #expect(gate.calls.count == 1) // the grant-less call never reached the gate
    }

    @Test func unwiredGateRefusesSkillIDButOrdinaryPathStillRuns() async throws {
        let backend = RecordingShellBackend()
        let tool = LocalShellTool(shell: makeService(backend: backend))
        let gated = try await tool.execute(
            LocalShellTool.Arguments(command: "echo x", skillID: "dep-skill"),
            context: makeContext(root: makeWorkspace())
        )
        #expect(gated.summary.contains("status=skillDependencyUnavailable"))
        #expect(gated.summary.contains("not configured"))
        #expect(backend.recorder.calls.isEmpty)
        let ordinary = try await tool.execute(
            LocalShellTool.Arguments(command: "echo x"),
            context: makeContext(root: makeWorkspace())
        )
        #expect(ordinary.summary.contains("exit=0"))
        #expect(backend.recorder.calls == ["echo x"])
    }

    @Test func argumentShapeAndParametersJSON() throws {
        let backend = RecordingShellBackend()
        let tool = LocalShellTool(shell: makeService(backend: backend))
        #expect(throws: (any Error).self) {
            try tool.validate(LocalShellTool.Arguments(command: "echo x", skillID: "Bad ID"))
        }
        #expect(throws: (any Error).self) {
            try tool.validate(LocalShellTool.Arguments(command: "echo x", skillID: "1leading"))
        }
        try tool.validate(LocalShellTool.Arguments(command: "echo x", skillID: "dep-skill"))
        // Absent/blank keep the ordinary behavior.
        try tool.validate(LocalShellTool.Arguments(command: "echo x"))
        try tool.validate(LocalShellTool.Arguments(command: "echo x", skillID: "   "))
        let schema = try #require(JSONSerialization.jsonObject(with: Data(LocalShellTool.parametersJSON.utf8)) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(properties["skillID"] != nil)
        #expect((schema["additionalProperties"] as? Bool) == false)
    }
}

// MARK: - Guest apt verbs (exact pins; fixed argv; honest readback)

@Suite("FloeExecution.LinuxGuestAptVerbs", .serialized)
struct LinuxGuestAptVerbTests {
    private func environment() -> ToolEnvironment {
        ToolEnvironment(
            id: "env-apt-\(UUID().uuidString)",
            writableLayerURL: FileManager.default.temporaryDirectory,
            layerURLs: [],
            variables: [:]
        )
    }

    @Test func exactPinRunsTheSingleSignedTransaction() async throws {
        let runner = ScriptedLinuxCommandRunner { _, _, _ in LinuxCommandResult(stdout: "", stderr: "", exitCode: 0) }
        let packages = LinuxGuestLanguagePackages(runner: runner)
        let env = environment()
        _ = try await packages.aptInstallExact(
            identity: "python3-scipy", version: "1.15.3-1", environment: env, cancellation: nil
        )
        let joined = runner.calls.map { $0.argv.joined(separator: " ") }
        #expect(joined.count == 2)
        #expect(joined[0] == "apt-get update")
        #expect(joined[1] == "apt-get install -y --no-install-recommends python3-scipy=1.15.3-1")
    }

    @Test func exactFontPinCarriesEpochAndRepackIntoTheTransaction() async throws {
        let runner = ScriptedLinuxCommandRunner { _, _, _ in LinuxCommandResult(stdout: "", stderr: "", exitCode: 0) }
        let packages = LinuxGuestLanguagePackages(runner: runner)
        _ = try await packages.aptInstallExact(
            identity: "fonts-noto-cjk", version: "1:20240730+repack1-1", environment: environment(), cancellation: nil
        )
        let install = runner.calls.last?.argv ?? []
        #expect(install.last == "fonts-noto-cjk=1:20240730+repack1-1")
    }

    @Test func malformedIdentityOrVersionNeverReachesArgv() async {
        let runner = ScriptedLinuxCommandRunner { _, _, _ in LinuxCommandResult(stdout: "", stderr: "", exitCode: 0) }
        let packages = LinuxGuestLanguagePackages(runner: runner)
        for bad in ["python3 scipy", "scipy;rm -rf /", "-lead", ""] {
            await #expect(throws: (any Error).self) {
                _ = try await packages.aptInstallExact(identity: bad, version: "1.0-1", environment: environment(), cancellation: nil)
            }
        }
        for bad in ["latest", "1:latest", ">=1.0", ""] {
            await #expect(throws: (any Error).self) {
                _ = try await packages.aptInstallExact(identity: "python3-scipy", version: bad, environment: environment(), cancellation: nil)
            }
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func readbackParsesExactDpkgLineAndTreatsUnknownAsAbsent() async throws {
        let runner = ScriptedLinuxCommandRunner { _, _, _ in
            LinuxCommandResult(stdout: "python3-scipy 1.15.3-1\n", stderr: "", exitCode: 0)
        }
        let packages = LinuxGuestLanguagePackages(runner: runner)
        let found = try await packages.aptReadback(identity: "python3-scipy", environment: environment(), cancellation: nil)
        #expect(found == "1.15.3-1")
        let missing = ScriptedLinuxCommandRunner { _, _, _ in
            LinuxCommandResult(stdout: "", stderr: "no packages found matching", exitCode: 1)
        }
        let absent = try await LinuxGuestLanguagePackages(runner: missing).aptReadback(
            identity: "python3-scipy", environment: environment(), cancellation: nil
        )
        #expect(absent == nil)
    }

    @Test func cjkProbeIsAFixedBooleanVerb() async throws {
        let yes = ScriptedLinuxCommandRunner { _, _, _ in LinuxCommandResult(stdout: "", stderr: "", exitCode: 0) }
        #expect(try await LinuxGuestLanguagePackages(runner: yes).cjkFontProbe(environment: environment(), cancellation: nil))
        let no = ScriptedLinuxCommandRunner { _, _, _ in LinuxCommandResult(stdout: "", stderr: "", exitCode: 1) }
        #expect(!(try await LinuxGuestLanguagePackages(runner: no).cjkFontProbe(environment: environment(), cancellation: nil)))
        let broken = CJKProbeThrowingRunner()
        #expect(!(try await LinuxGuestLanguagePackages(runner: broken).cjkFontProbe(environment: environment(), cancellation: nil)))
        // The intentional verb: the guest's own stdlib Python ctypes against
        // FreeType — open a face, nonzero Chinese+Japanese glyph indices,
        // render at 32 px, then tear down. Frozen paths only; the readiness
        // evidence is an actual glyph render, not a path listing.
        let argv = yes.calls.last?.argv ?? []
        #expect(argv.count == 3)
        #expect(argv[0] == "python3")
        #expect(argv[1] == "-c")
        let script = argv[2]
        #expect(script.contains("import ctypes"))
        #expect(script.contains("FT_Init_FreeType"))
        #expect(script.contains("FT_New_Face"))
        #expect(script.contains("FT_Get_Char_Index"))
        #expect(script.contains("FT_Set_Pixel_Sizes(face, 0, 32)"))
        #expect(script.contains("FT_Load_Char"))
        #expect(script.contains("FT_Done_Face"))
        #expect(script.contains("FT_Done_FreeType"))
        #expect(script.contains("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"))
        #expect(script.contains("/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc"))
        #expect(!script.contains("fc-list"))
        #expect(!script.contains("ls /usr/share/fonts"))
    }
}

/// A guest whose fixed probe command itself errors answers honest
/// not-ready(false), never a thrown failure that blocks unrelated work.
private final class CJKProbeThrowingRunner: LinuxCommandRunning, @unchecked Sendable {
    func supports(environmentID: String) async -> Bool { true }
    func ownsLinuxEnvironment(environmentID: String) async -> Bool { true }
    func run(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        standardInput: String?,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        throw FloeError.invalidConfiguration("guest channel closed")
    }
}
