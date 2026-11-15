// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeAndroidShellTools

/// Exercises the public tool/service path. Only the actual process backend is
/// replaced: the context determines background ownership, and the real service
/// must pass the correct budget to that backend. No sleep or device is used.
final class LocalShellBackgroundBudgetTests: XCTestCase {
    func testServiceOwnedBackgroundJobUsesBackgroundDefault() async throws {
        let request = try await capture(background: true)
        XCTAssertEqual(request.timeout, 600)
    }

    func testForegroundDefaultStaysShort() async throws {
        let request = try await capture(background: false)
        XCTAssertEqual(request.timeout, 10)
    }

    func testExplicitShortBackgroundDeadlineIsHonored() async throws {
        let request = try await capture(background: true, timeout: 0.5)
        XCTAssertEqual(request.timeout, 0.5)
    }

    func testBackgroundCeilingIsNotRaised() async throws {
        let request = try await capture(background: true, timeout: 6_000)
        XCTAssertEqual(request.timeout, 600)
    }

    func testForegroundCeilingIsNotRaised() async throws {
        let request = try await capture(background: false, timeout: 6_000)
        XCTAssertEqual(request.timeout, 120)
    }

    func testConfiguredBackgroundBudgetRemainsAuthoritative() async throws {
        let request = try await capture(
            background: true,
            configuration: .init(backgroundTimeout: 45)
        )
        XCTAssertEqual(request.timeout, 45)
    }

    private func capture(
        background: Bool,
        timeout: Double? = nil,
        configuration: LocalShellService.Configuration = .init()
    ) async throws -> ShellRunRequest {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-background-budget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = BudgetRecordingBackend()
        let service = LocalShellService(
            backend: backend,
            configuration: configuration,
            rootProvider: { root }
        )
        let tool = LocalShellTool(shell: service)
        let callID = background ? "jobs.\(UUID().uuidString)" : "call_foreground"
        let context = ToolContext(
            runID: UUID(), toolCallID: callID, scope: .local,
            workspaceRootURL: root, cancellation: CancellationToken()
        )
        let arguments = LocalShellTool.Arguments(command: "sleep 12", timeout: timeout)
        try tool.validate(arguments)
        let output = try await tool.execute(arguments, context: context)
        XCTAssertEqual(output.exitStatus, 0)
        let requests = await backend.requests
        XCTAssertEqual(requests.count, 1)
        return try XCTUnwrap(requests.first)
    }
}

private actor BudgetRecordingBackend: LocalShellBackend {
    var requests: [ShellRunRequest] = []

    func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        requests.append(request)
        return .exited(code: 0, stdout: "", stderr: "", truncated: false,
                       stderrTruncated: false, durationMs: 0)
    }

    func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
        throw UnexpectedSessionUse.notPartOfBudgetProbe
    }

    func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
        throw UnexpectedSessionUse.notPartOfBudgetProbe
    }

    func closeSession(sessionID: String) async {}

    private enum UnexpectedSessionUse: Error { case notPartOfBudgetProbe }
}
