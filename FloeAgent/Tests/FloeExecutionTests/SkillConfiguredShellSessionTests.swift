import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

private actor ConfigurationAuthority {
    var allowed = true
    func revoke() { allowed = false }
    func check() throws { if !allowed { throw FloeError.unauthorized } }
}

private actor ConfiguredSessionBackend: LocalShellBackend {
    private(set) var runs = 0
    private(set) var opens = 0
    private(set) var exchanges = 0
    private(set) var closes = 0
    private(set) var receivedOrdinary: [String: String] = [:]
    private(set) var receivedSensitiveNames: [String] = []
    nonisolated func supportsSensitiveProcessEnvironment(for environment: ToolEnvironment?) -> Bool { true }
    func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        runs += 1; receivedOrdinary = request.environment
        receivedSensitiveNames = request.sensitiveEnvironment?.names ?? []
        return .exited(code: 0, stdout: "ok", stderr: "", truncated: false, stderrTruncated: false, durationMs: 1)
    }
    func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
        opens += 1
        receivedOrdinary = request.environment
        receivedSensitiveNames = request.sensitiveEnvironment?.names ?? []
        return .init(sessionID: request.sessionID, initialOutput: "fixture-only-TOKEN", alive: true)
    }
    func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
        exchanges += 1
        return .init(output: "fixture-only-TOKEN", alive: true, failure: "fixture-only-TOKEN")
    }
    func closeSession(sessionID: String) async { closes += 1 }
}

@Suite("Configured interactive Skill sessions")
struct SkillConfiguredShellSessionTests {
    private func configuration(_ authority: ConfigurationAuthority) throws -> SkillProcessConfiguration {
        let redactor = SensitiveValueRedactor(values: ["fixture-only-TOKEN"])
        return .init(environment: ["SKILL_REGION": "test"],
                     sensitiveEnvironment: try .init(["SKILL_TOKEN": "fixture-only-TOKEN"]),
                     configuredEnvironmentNames: ["SKILL_REGION", "SKILL_TOKEN"],
                     revalidate: { try await authority.check() },
                     sanitizeOutput: { redactor.redactComplete($0) })
    }

    @Test func configuredCommandsPreserveNativeRuntimePaths() async throws {
        let root = FileManager.default.temporaryDirectory
        let authority = ConfigurationAuthority(), backend = ConfiguredSessionBackend()
        let native = ["PATH": "/runtime/bin", "HOME": "/runtime/home", "TMPDIR": "/runtime/tmp"]
        let shell = LocalShellService(backend: backend, environmentDefaults: native, rootProvider: { root })
        let result = try await shell.run(command: "echo ok", cwd: ".", environment: [:],
            skillConfiguration: configuration(authority), stdin: nil, requestedTimeout: nil,
            maxOutputBytes: 1024, isBackground: false,
            context: ToolContext(runID: UUID(), scope: .local, cancellation: CancellationToken()))
        guard case .outcome(.exited(let code, _, _, _, _, _)) = result else {
            Issue.record("Configured command was blocked by native runtime defaults"); return
        }
        #expect(code == 0)
        #expect(await backend.runs == 1)
        let received = await backend.receivedOrdinary
        for (key, value) in native { #expect(received[key] == value) }
        #expect(received["SKILL_REGION"] == "test")
        #expect(await backend.receivedSensitiveNames == ["SKILL_TOKEN"])
    }

    @Test func configurationCannotReplaceProtectedRuntimePaths() async throws {
        let root = FileManager.default.temporaryDirectory, backend = ConfiguredSessionBackend()
        let shell = LocalShellService(backend: backend, environmentDefaults: ["PATH": "/runtime/bin"], rootProvider: { root })
        let configuration = SkillProcessConfiguration(environment: ["PATH": "/untrusted/bin"],
            sensitiveEnvironment: nil, configuredEnvironmentNames: ["PATH"], revalidate: {}, sanitizeOutput: { $0 })
        _ = await shell.run(command: "echo ok", cwd: ".", environment: [:], skillConfiguration: configuration,
            stdin: nil, requestedTimeout: nil, maxOutputBytes: 1024, isBackground: false,
            context: ToolContext(runID: UUID(), scope: .local, cancellation: CancellationToken()))
        #expect(await backend.runs == 0)
    }

    @Test func environmentIsNativeAndRevocationClosesBeforeFurtherInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = ConfigurationAuthority(), backend = ConfiguredSessionBackend()
        let center = ShellSessionCenter(backend: backend), run = UUID()
        let opened = try await center.open(command: "", cwd: ".", environment: [:], columns: 80, rows: 24,
            runID: run, rootURL: root, cancellation: nil, skillConfiguration: configuration(authority))
        #expect(!opened.initialOutput.contains("fixture-only-TOKEN"))
        #expect(await backend.receivedOrdinary == ["SKILL_REGION": "test"])
        #expect(await backend.receivedSensitiveNames == ["SKILL_TOKEN"])
        let first = try await center.exchange(sessionID: opened.sessionID, input: "echo ok\n", waitMs: 50,
                                              maxBytes: 1024, runID: run, cancellation: nil)
        #expect(!first.output.contains("fixture-only-TOKEN"))
        #expect(first.failure?.contains("fixture-only-TOKEN") == false)
        await authority.revoke()
        await #expect(throws: (any Error).self) {
            try await center.exchange(sessionID: opened.sessionID, input: "echo blocked\n", waitMs: 50,
                                      maxBytes: 1024, runID: run, cancellation: nil)
        }
        #expect(await backend.exchanges == 1)
        #expect(await backend.closes == 1)
        #expect(await center.activeSessionIDs(runID: run).isEmpty)
    }

    @Test func overridesFailBeforeOpeningAnyBackend() async throws {
        let authority = ConfigurationAuthority(), backend = ConfiguredSessionBackend()
        let center = ShellSessionCenter(backend: backend)
        await #expect(throws: (any Error).self) {
            try await center.open(command: "", cwd: ".", environment: ["SKILL_TOKEN": "override"],
                columns: 80, rows: 24, runID: UUID(), rootURL: FileManager.default.temporaryDirectory,
                cancellation: nil, skillConfiguration: configuration(authority))
        }
        #expect(await backend.opens == 0)
    }
}
