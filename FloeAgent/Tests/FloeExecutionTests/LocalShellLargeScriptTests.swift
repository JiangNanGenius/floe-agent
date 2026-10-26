// FloeExecutionTests — uncapped command transport, timeout alias and
// large-script staging ownership.
//
// What these tests pin, without a guest image:
//  * exec.shell has no application-level command-length cap: a multi-megabyte
//    script body validates and reaches the backend;
//  * small commands keep the exact inline `/bin/sh -c <command>` transport;
//  * oversized bodies are staged inside the task workspace, executed through
//    a tiny `.` wrapper as guest /bin/sh code, and the staged pair is removed
//    on success, timeout and concurrency;
//  * stdin stays an independent channel and the guest argv never carries the
//    script text;
//  * a symlinked staging entrypoint is refused without writing through it and
//    unrelated user files in the staging directory are never touched;
//  * `timeoutSeconds` works as a documented alias, equal duplicates pass,
//    disagreements fail loudly, and the receipt names requested/effective/
//    policy and clamp reason (bare hints stay unlimited; a real hard
//    deadline floors to the Linux guest's documented 1-second minimum).

import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

// MARK: - Recording runner

/// Records every invocation. When `readStagedBytes` is set the runner resolves
/// the guest `/workspace/...` path back to the host staging file and captures
/// its bytes at execution time, proving the file exists while the command is
/// running.
private final class RecordingLinuxRunner: LinuxCommandRunning, @unchecked Sendable {
    struct Invocation: Sendable {
        var argv: [String]
        var workingDirectory: String?
        var stdin: String?
        var deadline: ShellExecutionDeadline
        var timeout: TimeInterval? {
            guard case .seconds(let value) = deadline else { return nil }
            return value
        }
        var stagedBytes: Data?
        var stagedExists: Bool
    }

    private let lock = NSLock()
    private var invocations: [Invocation] = []

    var workspaceRoot: URL
    var exitCode: Int32 = 0
    var thrownError: Error?
    /// Delay inside `run` so concurrent commands overlap on purpose.
    var holdFor: TimeInterval = 0

    init(workspaceRoot: URL) {
        self.workspaceRoot = workspaceRoot
    }

    var recorded: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }

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
        try await run(environmentID: environmentID, argv: argv,
                      workingDirectory: workingDirectory, standardInput: standardInput,
                      deadline: .seconds(timeout), maxOutputBytes: maxOutputBytes,
                      cancellation: cancellation)
    }

    func run(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        standardInput: String?,
        deadline: ShellExecutionDeadline,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        var staged: Data?
        var exists = false
        if argv.count == 3, argv[0] == "/bin/sh", argv[1] == "-c",
           argv[2].hasPrefix(". '"), argv[2].hasSuffix("'") {
            let guest = String(argv[2].dropFirst(3).dropLast(1))
            let prefix = "/workspace/"
            if guest.hasPrefix(prefix) {
                let host = workspaceRoot
                    .appendingPathComponent(String(guest.dropFirst(prefix.count)))
                exists = FileManager.default.fileExists(atPath: host.path)
                staged = try? Data(contentsOf: host)
            }
        }
        let invocation = Invocation(
            argv: argv,
            workingDirectory: workingDirectory,
            stdin: standardInput,
            deadline: deadline,
            stagedBytes: staged,
            stagedExists: exists
        )
        lock.withLock { invocations.append(invocation) }
        if holdFor > 0, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(holdFor * 1_000_000_000))
        }
        if let thrownError { throw thrownError }
        return LinuxCommandResult(stdout: "ok", stderr: "", exitCode: exitCode)
    }
}

// MARK: - Fixtures

private struct Fixture {
    let root: URL
    let tool: LocalShellTool
    let runner: RecordingLinuxRunner
    let service: LocalShellService

    init(root: URL, runner: RecordingLinuxRunner, journalRoot: URL) {
        self.root = root
        self.runner = runner
        self.service = LocalShellService(
            backend: LinuxGuestShellBackend(runner: runner),
            journal: ShellOperationJournal(rootURL: journalRoot),
            rootProvider: { root }
        )
        self.tool = LocalShellTool(shell: service)
    }
}

private func makeFixture(runner: RecordingLinuxRunner) throws -> Fixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-shell-transport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return Fixture(root: root, runner: runner, journalRoot: root)
}

private func makeContext(_ root: URL) -> ToolContext {
    ToolContext(
        runID: UUID(),
        toolCallID: "call_\(UUID().uuidString)",
        workspaceRootURL: root,
        cancellation: CancellationToken(),
        environmentID: "own",
        environment: ToolEnvironment(id: "own", writableLayerURL: root, layerURLs: [root], variables: [:])
    )
}

private func makeScript(bytes: Int, prefix: String = "# floe large script\n") -> String {
    var body = prefix
    body.reserveCapacity(bytes + 64)
    let line = "# 中文注释 unicode payload — keep bytes stable\n"
    while body.utf8.count < bytes { body += line }
    body += "exit 7\n"
    return body
}

private func stagingEntries(in root: URL) -> [String] {
    let dir = root.appendingPathComponent(".floe-shell", isDirectory: true)
    return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
}

final class LocalShellLargeScriptTests: XCTestCase {
    // MARK: tool-level contract

    func testCommandValidationHasNoApplicationLengthCeilingAndRejectsNUL() throws {
        let runner = RecordingLinuxRunner(workspaceRoot: URL(fileURLWithPath: NSTemporaryDirectory()))
        let tool = LocalShellTool(shell: LocalShellService(
            backend: LinuxGuestShellBackend(runner: runner),
            rootProvider: { URL(fileURLWithPath: NSTemporaryDirectory()) }
        ))
        // 3 MiB of unicode script validates: no 16 KiB (or any application)
        // command-length ceiling remains.
        let huge = makeScript(bytes: 3 * 1024 * 1024)
        XCTAssertNoThrow(try tool.validate(.init(command: huge)))
        XCTAssertThrowsError(try tool.validate(.init(command: "printf 'a\u{0}b'")))
    }

    func testTwentyKiBCommandStaysInlineAndMultiMegabyteScriptIsStaged() async throws {
        let runner = RecordingLinuxRunner(workspaceRoot: URL(fileURLWithPath: NSTemporaryDirectory()))
        let fixture = try makeFixture(runner: runner)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        runner.workspaceRoot = fixture.root
        // The recording runner stands in for a real guest /bin/sh: both
        // scripted bodies end with `exit 7`, so arm the fake with that exit
        // status BEFORE the first execution. Setting it after the inline run
        // made the first assertion observe the fake's default 0.
        runner.exitCode = 7

        let inlineBody = makeScript(bytes: 20 * 1024)
        let inline = try await fixture.tool.execute(
            .init(command: inlineBody, timeout: 30),
            context: makeContext(fixture.root)
        )
        XCTAssertEqual(inline.exitStatus, 7)
        XCTAssertEqual(runner.recorded.count, 1)
        // Inline path: the whole command rides argv, exactly as before.
        let first = try XCTUnwrap(runner.recorded.first)
        XCTAssertEqual(first.deadline, .unlimited)
        XCTAssertEqual(first.argv.count, 3)
        XCTAssertTrue(first.argv[2].hasSuffix(inlineBody))
        XCTAssertTrue(stagingEntries(in: fixture.root).isEmpty)

        let hugeBody = makeScript(bytes: 2 * 1024 * 1024)
        let staged = try await fixture.tool.execute(
            .init(command: hugeBody, timeout: 60, timeoutPolicy: "hard"),
            context: makeContext(fixture.root)
        )
        XCTAssertEqual(staged.exitStatus, 7)
        XCTAssertEqual(runner.recorded.count, 2)
        let second = try XCTUnwrap(runner.recorded.dropFirst().first)
        XCTAssertEqual(second.argv.count, 3)
        XCTAssertTrue(second.argv[2].hasPrefix(". '"), second.argv[2])
        XCTAssertLessThan(second.argv[2].utf8.count, 200)
        XCTAssertEqual(second.workingDirectory, "/workspace")
        // The staged file existed during the run and carries the exact script
        // body (the environment preamble is prepended, so compare the suffix).
        XCTAssertTrue(second.stagedExists)
        let stagedData = try XCTUnwrap(second.stagedBytes)
        XCTAssertGreaterThanOrEqual(stagedData.count, hugeBody.utf8.count)
        XCTAssertTrue(String(decoding: stagedData, as: UTF8.self).hasSuffix(hugeBody))
        // Cleanup on the success path: no staged pair (and, usually, no
        // staging directory) is left behind.
        XCTAssertTrue(stagingEntries(in: fixture.root).isEmpty)
        XCTAssertTrue(staged.summary.contains("timeoutRequestedSeconds=60"))
        XCTAssertTrue(staged.summary.contains("timeoutClamp=none"))
    }

    func testStdinStaysIndependentFromTheScriptBody() async throws {
        let runner = RecordingLinuxRunner(workspaceRoot: URL(fileURLWithPath: NSTemporaryDirectory()))
        let fixture = try makeFixture(runner: runner)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        runner.workspaceRoot = fixture.root
        let body = makeScript(bytes: 512 * 1024)
        _ = try await fixture.tool.execute(
            .init(command: body, stdin: "line-1\n中文 stdin\n", timeout: 30, timeoutPolicy: "hard"),
            context: makeContext(fixture.root)
        )
        let invocation = try XCTUnwrap(runner.recorded.first)
        XCTAssertEqual(invocation.stdin, "line-1\n中文 stdin\n")
        XCTAssertTrue(invocation.argv[2].hasPrefix(". '"))
        XCTAssertFalse(invocation.argv.joined().contains("中文 stdin"))
    }

    // MARK: timeout alias and receipt

    func testTimeoutSecondsAliasIsApplied() async throws {
        let runner = RecordingLinuxRunner(workspaceRoot: URL(fileURLWithPath: NSTemporaryDirectory()))
        let fixture = try makeFixture(runner: runner)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        runner.workspaceRoot = fixture.root
        let result = try await fixture.tool.execute(
            .init(command: "printf ok", timeoutSeconds: 60, timeoutPolicy: "hard"),
            context: makeContext(fixture.root)
        )
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(runner.recorded.first?.timeout ?? 0, 60, accuracy: 0.001)
        XCTAssertTrue(result.summary.contains("timeoutRequestedSeconds=60"))
        XCTAssertTrue(result.summary.contains("timeoutClamp=none"))
    }

    func testConflictingTimeoutAliasesAreRejected() throws {
        let runner = RecordingLinuxRunner(workspaceRoot: URL(fileURLWithPath: NSTemporaryDirectory()))
        let tool = LocalShellTool(shell: LocalShellService(
            backend: LinuxGuestShellBackend(runner: runner),
            rootProvider: { URL(fileURLWithPath: NSTemporaryDirectory()) }
        ))
        XCTAssertThrowsError(
            try tool.validate(.init(command: "printf ok", timeout: 30, timeoutSeconds: 60))
        ) { error in
            XCTAssertTrue("\(error)".contains("disagree"))
        }
        // Equal duplicates are the same value, not a conflict.
        XCTAssertNoThrow(
            try tool.validate(.init(command: "printf ok", timeout: 60, timeoutSeconds: 60))
        )
    }

    func testTimeoutReceiptNamesHardDeadlinesAndTheMinimumFloor() async throws {
        let runner = RecordingLinuxRunner(workspaceRoot: URL(fileURLWithPath: NSTemporaryDirectory()))
        let fixture = try makeFixture(runner: runner)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        runner.workspaceRoot = fixture.root
        // An explicit hard deadline is honored at its exact value: the old
        // foreground 120 s application ceiling no longer exists.
        let clamped = try await fixture.tool.execute(
            .init(command: "printf ok", timeout: 300, timeoutPolicy: "hard"),
            context: makeContext(fixture.root)
        )
        XCTAssertEqual(runner.recorded.first?.timeout ?? 0, 300, accuracy: 0.001)
        XCTAssertTrue(clamped.summary.contains("timeoutRequestedSeconds=300"))
        XCTAssertTrue(clamped.summary.contains("timeoutPolicy=hard"))
        XCTAssertTrue(clamped.summary.contains("effectiveTimeoutSeconds=300.0"))
        XCTAssertTrue(clamped.summary.contains("timeoutClamp=none"))

        let floored = try await fixture.tool.execute(
            .init(command: "printf ok", timeout: 0.01, timeoutPolicy: "hard"),
            context: makeContext(fixture.root)
        )
        // The Linux guest runner documents a 1-second minimum real deadline
        // (LinuxGuestLimits.executionDeadline, LinuxGuestService.swift):
        // the service's generic 0.05 floor applies first, then the backend
        // clamps to its real floor — that clamped value is the deadline the
        // command actually receives and the receipt must name it.
        XCTAssertEqual(runner.recorded.last?.timeout ?? 0, 1, accuracy: 0.001)
        XCTAssertTrue(floored.summary.contains("timeoutRequestedSeconds=0.01"))
        XCTAssertTrue(floored.summary.contains("effectiveTimeoutSeconds=1.0"))
        XCTAssertTrue(floored.summary.contains("timeoutClamp=minimumFloor"))
    }

    // MARK: staging ownership and cleanup

    func testSymlinkedStagingEntrypointIsRefusedWithoutWritingThroughIt() async throws {
        let runner = RecordingLinuxRunner(workspaceRoot: URL(fileURLWithPath: NSTemporaryDirectory()))
        let fixture = try makeFixture(runner: runner)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        runner.workspaceRoot = fixture.root
        let foreign = fixture.root.appendingPathComponent("foreign-target", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent(".floe-shell"),
            withDestinationURL: foreign
        )
        let result = try await fixture.tool.execute(
            .init(command: makeScript(bytes: 256 * 1024), timeout: 30),
            context: makeContext(fixture.root)
        )
        XCTAssertEqual(result.exitStatus, 125)
        XCTAssertTrue(result.summary.contains("not a plain directory"), result.summary)
        XCTAssertTrue(runner.recorded.isEmpty)
        // Nothing was written through the alias.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: foreign.path).count, 0)
    }

    func testUnrelatedStagingDirectoryContentsAreNeverTouched() async throws {
        let runner = RecordingLinuxRunner(workspaceRoot: URL(fileURLWithPath: NSTemporaryDirectory()))
        let fixture = try makeFixture(runner: runner)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        runner.workspaceRoot = fixture.root
        let dir = fixture.root.appendingPathComponent(".floe-shell", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keep = dir.appendingPathComponent("keep-user-file.txt")
        try Data("user content".utf8).write(to: keep)
        let keepLink = dir.appendingPathComponent("keep-link")
        try FileManager.default.createSymbolicLink(at: keepLink, withDestinationURL: keep)

        _ = try await fixture.tool.execute(
            .init(command: makeScript(bytes: 128 * 1024), timeout: 30),
            context: makeContext(fixture.root)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
        XCTAssertEqual(try String(contentsOf: keep, encoding: .utf8), "user content")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keepLink.path))
        let remaining = Set(stagingEntries(in: fixture.root))
        XCTAssertEqual(remaining, ["keep-user-file.txt", "keep-link"])
    }

    func testConcurrentLargeScriptsUseDistinctStageFilesAndCleanBoth() async throws {
        let runner = RecordingLinuxRunner(workspaceRoot: URL(fileURLWithPath: NSTemporaryDirectory()))
        let fixture = try makeFixture(runner: runner)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        runner.workspaceRoot = fixture.root
        runner.holdFor = 0.2
        async let first = fixture.tool.execute(
            .init(command: makeScript(bytes: 256 * 1024, prefix: "# first\n"), timeout: 30),
            context: makeContext(fixture.root)
        )
        async let second = fixture.tool.execute(
            .init(command: makeScript(bytes: 320 * 1024, prefix: "# second\n"), timeout: 30),
            context: makeContext(fixture.root)
        )
        let results = try await [first, second]
        XCTAssertEqual(results.map(\.exitStatus), [0, 0])
        let invocations = runner.recorded
        XCTAssertEqual(invocations.count, 2)
        XCTAssertTrue(invocations.allSatisfy { $0.deadline == .unlimited })
        XCTAssertEqual(Set(invocations.map(\.argv[2])).count, 2, "each invocation stages its own file")
        XCTAssertTrue(invocations.allSatisfy { $0.stagedExists })
        XCTAssertTrue(stagingEntries(in: fixture.root).isEmpty)
    }

    func testCleanupPreservesDirectoryHeldByAnotherInvocation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("staging-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try LinuxGuestShellBackend.stageScript("true", root: root, runID: UUID(), cancellation: nil)
        let held = dup(first.directoryFD)
        XCTAssertGreaterThanOrEqual(held, 0)
        defer { if held >= 0 { close(held) } }
        // Another invocation opened the directory but has not created its
        // first file yet. Cleanup must not unlink its still-empty directory.
        LinuxGuestShellBackend.closeStaged(first)
        let pending = openat(held, "pending.sh", O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        XCTAssertGreaterThanOrEqual(pending, 0)
        if pending >= 0 { close(pending) }
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            root.appendingPathComponent(".floe-shell/pending.sh").path))
    }

    func testTimeoutAndCancellationCleanUpStagedFiles() async throws {
        let runner = RecordingLinuxRunner(workspaceRoot: URL(fileURLWithPath: NSTemporaryDirectory()))
        let fixture = try makeFixture(runner: runner)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        runner.workspaceRoot = fixture.root
        runner.thrownError = LinuxGuestCommandTimeout(
            seconds: 30,
            partialStdout: "partial",
            partialStderr: "boom",
            outputTruncated: false
        )
        let timedOut = try await fixture.tool.execute(
            .init(command: makeScript(bytes: 256 * 1024), timeout: 30),
            context: makeContext(fixture.root)
        )
        XCTAssertEqual(timedOut.exitStatus, 124)
        XCTAssertTrue(stagingEntries(in: fixture.root).isEmpty, "timeout must remove the staged pair")

        // Use a fresh workspace: a pre-cancelled command creates nothing.
        let cancelledRoot = fixture.root.appendingPathComponent("pre-cancelled")
        try FileManager.default.createDirectory(at: cancelledRoot, withIntermediateDirectories: true)
        let cancellation = CancellationToken()
        cancellation.cancel()
        let backend = LinuxGuestShellBackend(runner: runner)
        let request = ShellRunRequest(
            command: makeScript(bytes: 256 * 1024),
            cwd: ".",
            rootURL: cancelledRoot,
            deadline: .seconds(30),
            sessionID: "cancel-\(UUID().uuidString)",
            runID: UUID(),
            toolEnvironment: ToolEnvironment(
                id: "own",
                writableLayerURL: cancelledRoot,
                layerURLs: [cancelledRoot],
                variables: [:]
            )
        )
        let outcome = await backend.run(request, cancellation: cancellation)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cancelledRoot.appendingPathComponent(".floe-shell").path)
        )
    }

    func testLimitsPinBothBoundsInsideTheRunnerEnvelope() {
        let limits = LinuxGuestLimits(maxCommandBytes: 512 * 1024, maxEnvelopeBytes: 1024 * 1024)
        XCTAssertEqual(limits.maxCommandBytes, 256 * 1024)
        XCTAssertEqual(limits.maxEnvelopeBytes, 256 * 1024)
        let small = LinuxGuestLimits(maxCommandBytes: 8 * 1024, maxEnvelopeBytes: 16 * 1024)
        XCTAssertEqual(small.maxCommandBytes, 8 * 1024)
        XCTAssertEqual(small.maxEnvelopeBytes, 16 * 1024)
        // An envelope below the command bound is lifted to it, never pinned
        // above the runner ceiling.
        let inverted = LinuxGuestLimits(maxCommandBytes: 64 * 1024, maxEnvelopeBytes: 0)
        XCTAssertEqual(inverted.maxEnvelopeBytes, 64 * 1024)
    }
}
