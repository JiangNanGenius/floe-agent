// FloeExecutionTests — New time policy (2026-10-26): default-unlimited
// execution deadlines, bare-number advisory hints, explicit hard deadlines,
// checked representability, and the no-implicit-cap request → backend →
// runner propagation. Complements the staged-script, gate and receipt
// coverage in LocalShellLargeScriptTests / feedback_RuntimeShellGateTests.

import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

/// Records the EXACT deadline that reaches the runner seam, proving the
/// whole request → service → backend → runner chain carries the resolved
/// policy with no implicit cap and no silent conversion of `.unlimited`.
private final class DeadlineCapturingRunner: LinuxCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var deadlines: [ShellExecutionDeadline] = []

    var recorded: [ShellExecutionDeadline] {
        lock.lock()
        defer { lock.unlock() }
        return deadlines
    }

    func supports(environmentID: String) async -> Bool { true }
    func ownsLinuxEnvironment(environmentID: String) async -> Bool { true }

    func run(environmentID: String, argv: [String], workingDirectory: String?, standardInput: String?,
             timeout: TimeInterval, maxOutputBytes: Int, cancellation: CancellationToken?) async throws -> LinuxCommandResult {
        lock.withLock { deadlines.append(.seconds(timeout)) }
        return LinuxCommandResult(stdout: "ok", stderr: "", exitCode: 0)
    }

    func run(environmentID: String, argv: [String], workingDirectory: String?, standardInput: String?,
             deadline: ShellExecutionDeadline, maxOutputBytes: Int, cancellation: CancellationToken?) async throws -> LinuxCommandResult {
        lock.withLock { deadlines.append(deadline) }
        return LinuxCommandResult(stdout: "ok", stderr: "", exitCode: 0)
    }
}

@Suite("Shell execution deadline policy")
struct ShellExecutionDeadlinePolicyTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFixture() throws -> (LocalShellTool, DeadlineCapturingRunner, URL) {
        let root = try makeRoot()
        let runner = DeadlineCapturingRunner()
        let service = LocalShellService(
            backend: LinuxGuestShellBackend(runner: runner),
            rootProvider: { root }
        )
        return (LocalShellTool(shell: service), runner, root)
    }

    private func makeContext(root: URL, toolCallID: String = "deadline-policy") -> ToolContext {
        ToolContext(runID: UUID(), toolCallID: toolCallID, workspaceRootURL: root,
            cancellation: CancellationToken(), environmentID: "own",
            environment: ToolEnvironment(id: "own", writableLayerURL: root, layerURLs: [root], variables: [:]))
    }

    // MARK: typed value honesty

    @Test("Unlimited is a typed case: JSON-safe, never infinity or a fake huge cap")
    func unlimitedIsTypedAndJSONSafe() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(ShellExecutionDeadline.unlimited)
        #expect(String(decoding: data, as: UTF8.self) == "\"unlimited\"")
        #expect(try JSONDecoder().decode(ShellExecutionDeadline.self, from: data) == .unlimited)

        let seconds = try encoder.encode(ShellExecutionDeadline.seconds(90))
        #expect(String(decoding: seconds, as: UTF8.self) == "90")
        #expect(try JSONDecoder().decode(ShellExecutionDeadline.self, from: seconds) == .seconds(90))

        #expect(throws: (any Error).self) { try encoder.encode(ShellExecutionDeadline.seconds(.infinity)) }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ShellExecutionDeadline.self, from: Data("1e999".utf8))
        }
        #expect(ShellExecutionDeadline.unlimited.receiptText == "unlimited")
    }

    @Test("Checked representability rejects invalid and unrepresentable values, honors real ones")
    func validatedRepresentability() {
        #expect(ShellExecutionDeadline.validated(seconds: 0) == nil)
        #expect(ShellExecutionDeadline.validated(seconds: -5) == nil)
        #expect(ShellExecutionDeadline.validated(seconds: .nan) == nil)
        #expect(ShellExecutionDeadline.validated(seconds: .infinity) == nil)
        #expect(ShellExecutionDeadline.validated(
            seconds: ShellExecutionDeadline.maximumRepresentableSeconds + 1) == nil)
        // A genuine finite user deadline is honored at its exact value — no
        // product-duration cap is applied.
        #expect(ShellExecutionDeadline.validated(seconds: 86_400) == .seconds(86_400))
        #expect(ShellExecutionDeadline.validated(seconds: 30 * 86_400) == .seconds(30 * 86_400))
    }

    // MARK: service resolution matrix

    @Test("Omitted and bare numbers stay unlimited; only hard is a real deadline")
    func serviceResolutionMatrix() throws {
        let (_, runner, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LocalShellService(
            backend: LinuxGuestShellBackend(runner: runner), rootProvider: { root })
        // Omitted → policy default (unlimited).
        #expect(service.resolvedDeadline(nil, policy: .advisory).deadline == .unlimited)
        #expect(service.resolvedDeadline(nil, policy: .advisory).clampReason == "default")
        // ANY bare number is advisory — including every old taught hint.
        for legacy in [10.0, 120.0, 600.0, 1800.0] {
            let resolved = service.resolvedDeadline(legacy, policy: .advisory)
            #expect(resolved.deadline == .unlimited)
            #expect(resolved.clampReason == "advisoryDefault")
            #expect(resolved.requestedSeconds == legacy)
        }
        // Non-finite never becomes a surprise kill: it maps to the default.
        #expect(service.resolvedDeadline(.infinity, policy: .advisory).deadline == .unlimited)
        #expect(service.resolvedDeadline(.nan, policy: .hard).deadline == .unlimited)
        // Hard: exact value, guest 1-second floor, unrepresentable → fail
        // safe to the default policy with an honest reason (tool validation
        // refuses it first).
        #expect(service.resolvedDeadline(600, policy: .hard).deadline == .seconds(600))
        #expect(service.resolvedDeadline(600, policy: .hard).clampReason == "none")
        #expect(service.resolvedDeadline(0.01, policy: .hard).deadline == .seconds(1))
        #expect(service.resolvedDeadline(0.01, policy: .hard).clampReason == "minimumFloor")
        #expect(service.resolvedDeadline(1e12, policy: .hard).clampReason == "invalidHard")
        #expect(service.resolvedDeadline(1e12, policy: .hard).deadline == .unlimited)
        _ = runner
    }

    // MARK: end-to-end propagation and receipts

    @Test("Default call reaches the runner as unlimited: no implicit cap anywhere")
    func defaultIsUnlimitedEndToEnd() async throws {
        let (tool, runner, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await tool.execute(.init(command: "printf ok"), context: makeContext(root: root))
        #expect(result.exitStatus == 0)
        #expect(runner.recorded == [.unlimited])
        #expect(result.summary.contains("timeoutRequestedSeconds=none"))
        #expect(result.summary.contains("timeoutPolicy=default"))
        #expect(result.summary.contains("effectiveTimeoutSeconds=unlimited"))
        #expect(result.summary.contains("timeoutClamp=default"))
    }

    @Test("Legacy bare 600 is an advisory hint, never the old default kill")
    func legacy600IsAdvisory() async throws {
        let (tool, runner, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await tool.execute(
            .init(command: "printf ok", timeout: 600), context: makeContext(root: root))
        #expect(result.exitStatus == 0)
        #expect(runner.recorded == [.unlimited])
        #expect(result.summary.contains("timeoutRequestedSeconds=600.0"))
        #expect(result.summary.contains("timeoutPolicy=advisory"))
        #expect(result.summary.contains("effectiveTimeoutSeconds=unlimited"))
        #expect(result.summary.contains("timeoutClamp=advisoryDefault"))
        // A background (jobs-wrapped) legacy 600 behaves identically.
        let backgroundContext = makeContext(root: root, toolCallID: "jobs.\(UUID().uuidString)")
        let jobResult = try await tool.execute(
            .init(command: "printf ok", timeout: 600), context: backgroundContext)
        #expect(jobResult.summary.contains("effectiveTimeoutSeconds=unlimited"))
        #expect(runner.recorded == [.unlimited, .unlimited])
    }

    @Test("Explicit hard deadline is real and exact end to end")
    func hardDeadlineIsReal() async throws {
        let (tool, runner, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await tool.execute(
            .init(command: "printf ok", timeout: 1800, timeoutPolicy: "hard"),
            context: makeContext(root: root))
        #expect(result.exitStatus == 0)
        #expect(runner.recorded == [.seconds(1800)])
        #expect(result.summary.contains("timeoutPolicy=hard"))
        #expect(result.summary.contains("effectiveTimeoutSeconds=1800.0"))
        #expect(result.summary.contains("timeoutClamp=none"))
    }

    @Test("Staged large-script path keeps the unlimited deadline and its cleanup contract")
    func stagedPathCarriesUnlimited() async throws {
        let (tool, runner, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // Beyond the 32 KiB guest command envelope: the body is staged as a
        // file in the workspace share and executed through the tiny wrapper.
        let hugeBody = "printf staged\\n" + String(repeating: "# padding\\n", count: 40_000)
        let result = try await tool.execute(
            .init(command: hugeBody), context: makeContext(root: root, toolCallID: "staged-unlimited"))
        #expect(result.exitStatus == 0)
        #expect(runner.recorded == [.unlimited])
        #expect(result.summary.contains("effectiveTimeoutSeconds=unlimited"))
        // Staging cleanup on the success path: no staged pair is left behind.
        let staging = root.appendingPathComponent(".floe-shell")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    // MARK: validation refusals

    @Test("Invalid deadline requests are refused, never silently reinterpreted")
    func invalidRequestsAreRefused() throws {
        let (tool, _, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // Hard requires a number.
        #expect(throws: (any Error).self) {
            try tool.validate(.init(command: "printf ok", timeoutPolicy: "hard"))
        }
        // Unknown policy strings are refused.
        #expect(throws: (any Error).self) {
            try tool.validate(.init(command: "printf ok", timeout: 30, timeoutPolicy: "soft"))
        }
        // Invalid numbers keep the existing refusal for every policy.
        for invalid in [Double.nan, .infinity, -1.0, 0.0] {
            #expect(throws: (any Error).self) {
                try tool.validate(.init(command: "printf ok", timeout: invalid))
            }
        }
        // Beyond the representability horizon: refused with the conversion
        // reason, not clamped to an arbitrary product cap.
        #expect(throws: (any Error).self) {
            try tool.validate(.init(command: "printf ok",
                timeout: ShellExecutionDeadline.maximumRepresentableSeconds + 1,
                timeoutPolicy: "hard"))
        }
        // Conflicting aliases stay refused (existing contract).
        #expect(throws: (any Error).self) {
            try tool.validate(.init(command: "printf ok", timeout: 30, timeoutSeconds: 60))
        }
    }
}
