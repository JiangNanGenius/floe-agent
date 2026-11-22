// FloeMacTerminal — lifecycle and PTY readiness tests.
//
// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import FloeMacTerminal
import SwiftTerm

/// Headless delegate for the pinned SwiftTerm `LocalProcess` PTY probe.
final class PTYProbe: LocalProcessDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var didTerminate = false
    private var status: Int32?

    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    var terminated: Bool { lock.lock(); defer { lock.unlock() }; return didTerminate }
    var exitCode: Int32? { lock.lock(); defer { lock.unlock() }; return status }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        lock.lock(); didTerminate = true; status = exitCode; lock.unlock()
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        lock.lock(); buffer.append(contentsOf: slice); lock.unlock()
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    }
}

@MainActor
final class MacTerminalLifecycleTests: XCTestCase {

    /// PTY readiness fixture: the pinned SwiftTerm LocalProcess can spawn a
    /// child on a real pseudo-terminal on this host and we observe its output.
    func testLocalProcessPTYReadiness() async throws {
        let probe = PTYProbe()
        let process = LocalProcess(delegate: probe)
        process.startProcess(executable: "/bin/sh", args: ["-c", "printf mac-terminal-pty-ready"])

        for _ in 0..<100 where !probe.terminated {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(probe.terminated, "child on the PTY was not reaped in time")
        XCTAssertEqual(probe.exitCode, 0)
        let text = String(data: probe.data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("mac-terminal-pty-ready"), "unexpected PTY output: \(text)")
    }

    /// Manual-only contract: a fresh session owns no child process and no
    /// terminal view until the user explicitly starts it.
    func testFreshSessionStartsNoProcess() {
        let session = MacTerminalSession()
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.isRunning)
        XCTAssertNil(session.terminalView)
        XCTAssertNil(session.shellPID)
    }

    func testTerminalSurfaceSendsInputToItsPTY() async throws {
        let session = MacTerminalSession()
        try session.start(executable: "/bin/sh", arguments: ["-c", """
            IFS= read -r line && [ "$line" = "Floe terminal input" ]
            """], workingDirectory: nil)
        let view = try XCTUnwrap(session.terminalView)
        for _ in 0..<60 where !view.process.running {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(view.process.running)
        view.send(data: ArraySlice("Floe terminal input\n".utf8))
        let received = await raceTermination(of: session, timeout: .seconds(3))
        if !received { _ = await session.close() }
        XCTAssertTrue(received)
        XCTAssertEqual(session.state, .exited(0))
    }

    /// Start → drain: the exit is observed and the drain awaitable completes.
    func testSessionStartAndDrain() async throws {
        let session = MacTerminalSession()
        try session.start(executable: "/bin/sh", arguments: ["-c", "exit 3"], workingDirectory: nil)
        XCTAssertTrue(session.isRunning)

        let drained = await raceTermination(of: session, timeout: .seconds(5))
        XCTAssertTrue(drained, "session drain did not complete in time")
        guard case .exited(let code) = session.state else {
            XCTFail("expected .exited, got \(session.state)")
            return
        }
        // The Subprocess backend reports the real exit status; the forkpty
        // backend reports a raw wait status. Both are non-zero for exit 3.
        XCTAssertNotNil(code)
        XCTAssertNotEqual(code, 0)
    }

    /// Close reaps a long-running child promptly instead of leaking it.
    func testCloseReapsLongRunningChild() async throws {
        let session = MacTerminalSession()
        try session.start(executable: "/bin/sh", arguments: ["-c", "sleep 30"], workingDirectory: nil)
        for _ in 0..<40 where session.terminalView?.process.running != true {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(session.isRunning)

        let closed = await session.close(timeout: .seconds(5))
        XCTAssertTrue(closed, "close did not reap the child in time")
        guard case .exited = session.state else {
            XCTFail("expected .exited after close, got \(session.state)")
            return
        }
    }

    /// After exit, reset returns to idle and a new session can start.
    func testResetAllowsNewSession() async throws {
        let session = MacTerminalSession()
        try session.start(executable: "/bin/sh", arguments: ["-c", "exit 0"], workingDirectory: nil)
        _ = await raceTermination(of: session, timeout: .seconds(5))
        session.reset()
        XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.terminalView)
    }

    /// Concurrent toolbox teardown (`stop()`) and the in-view close button
    /// (`close()`) must not lose the single terminal acknowledgment: both
    /// callers return reaped, the state ends `.exited` exactly once, and the
    /// drain still completes for a late awaiter.
    func testConcurrentCloseAndStopDeliverSingleAck() async throws {
        let session = MacTerminalSession()
        try session.start(executable: "/bin/sh", arguments: ["-c", "sleep 30"], workingDirectory: nil)
        for _ in 0..<40 where session.terminalView?.process.running != true {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(session.isRunning)

        async let closeResult: Bool = session.close(timeout: .seconds(5))
        async let stopResult: Bool = session.stop(timeout: .seconds(5))
        let (closed, stopped) = await (closeResult, stopResult)
        XCTAssertTrue(closed, "close did not observe the reap")
        XCTAssertTrue(stopped, "stop did not observe the reap")
        guard case .exited = session.state else {
            XCTFail("expected .exited after concurrent close/stop, got \(session.state)")
            return
        }
        // The late drain awaiter still observes completion.
        let lateDrain = await raceTermination(of: session, timeout: .seconds(1))
        XCTAssertTrue(lateDrain)
    }

    func testCancellingOneExitWaitKeepsTheOtherAttached() async throws {
        let session = MacTerminalSession()
        try session.start(executable: "/bin/sleep", arguments: ["30"], workingDirectory: nil)
        let abandoned = Task { await session.termination }
        await Task.yield()
        abandoned.cancel()
        await abandoned.value
        XCTAssertEqual(session.state, .running)

        let observer = Task {
            await session.termination
            return session.state
        }
        await Task.yield()
        let closed = await session.close()
        XCTAssertTrue(closed)
        if !closed { observer.cancel() }
        let observed = await observer.value
        guard case .exited = observed else {
            return XCTFail("The remaining waiter completed before the process exited.")
        }
    }

    func testSSHDestinationFollowsTheOptionTerminator() throws {
        let host = try MacSSHHost.validated(host: "floe.example.test", user: "qa", port: 2222)
        XCTAssertEqual(host.argv(), ["-tt", "-p", "2222", "--", "qa@floe.example.test"])
        XCTAssertThrowsError(try MacSSHHost.validated(host: "-G"))
        XCTAssertThrowsError(try MacSSHHost.validated(host: "floe.example.test", port: 0))
    }

    /// Scope validation accepts real folders and rejects missing ones.
    func testScopeValidation() throws {
        let temp = NSTemporaryDirectory()
        let scope = try MacTerminalScope.validatedDirectory(temp)
        XCTAssertEqual(scope, .directory((temp as NSString).standardizingPath))
        XCTAssertThrowsError(try MacTerminalScope.validatedDirectory("/no/such/floe-mac-terminal-path")) { error in
            guard case MacTerminalScopeError.notADirectory = error else {
                XCTFail("unexpected error: \(error)")
                return
            }
        }
    }

    /// The user's shell resolves to an executable path.
    func testResolvedUserShellIsExecutable() {
        let shell = MacTerminalSession.resolvedUserShell()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shell))
    }

    // MARK: Helpers

    /// Waits for the session drain with a bounded timeout.
    private func raceTermination(of session: MacTerminalSession, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await session.termination
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
