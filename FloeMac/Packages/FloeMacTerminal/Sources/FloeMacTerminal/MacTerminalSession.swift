// FloeMacTerminal — lifecycle owner for one interactive local PTY session.
//
// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import Foundation
import SwiftTerm

/// Lifecycle state of one terminal session.
public enum MacTerminalSessionState: Equatable, Sendable {
    /// No child process; the view is showing the start screen.
    case idle
    /// The child shell is running and attached to the terminal view.
    case running
    /// A stop was requested and the child is being reaped.
    case stopping
    /// The child terminated; carries the exit code when known.
    case exited(Int32?)
}

/// Externally awaitable owner of one local PTY session.
///
/// Lifecycle vocabulary for the toolbox:
/// - start: ``start(scope:)``, triggered only by the user's start button.
/// - close: ``close(timeout:)`` terminates the child and confirms the reap;
///   call it before an OTA update or when the user ends the session.
/// - drain: ``termination`` (async) completes once the child is reaped.
/// - resume: while the state is `.running`, a rebuilt tool view simply
///   re-attaches ``terminalView``; nothing is restarted and no output is lost.
///
/// There is deliberately no public API to write into or execute commands
/// on the PTY: user input goes through the on-screen terminal view only,
/// so no model-authored code path can reach the child process.
@MainActor
public final class MacTerminalSession: ObservableObject {

    /// Current lifecycle state, published for the UI.
    @Published public private(set) var state: MacTerminalSessionState = .idle

    /// Terminal title reported by the child shell (OSC sequences).
    @Published public private(set) var terminalTitle = ""

    /// Last directory reported by the child shell, when it publishes one.
    @Published public private(set) var currentDirectory: String?

    /// Whether a child process is currently attached.
    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// The child PID, when the process backend reports one.
    public var shellPID: pid_t? {
        guard let pid = terminalView?.process.shellPid, pid > 0 else { return nil }
        return pid
    }

    /// The terminal view hosting the PTY, created on start and released
    /// on exit. Internal so only the package's NSViewRepresentable can
    /// attach it to the view hierarchy.
    private(set) var terminalView: LocalProcessTerminalView?

    private var terminationContinuation: AsyncStream<Void>.Continuation?
    private var terminationStream: AsyncStream<Void>?
    /// Guards the single terminate() fan-out so concurrent close/stop
    /// callers cannot double-signal the child; every caller still drains.
    private var terminateRequested = false

    public init() {}

    isolated deinit {
        // Abandoned without close(): best-effort teardown. The normal path
        // is `await close()`, which also confirms the reap.
        terminalView?.process.terminate()
    }

    /// Starts the user's interactive login shell in the scoped directory.
    /// - Parameter scope: validated working directory chosen by the user.
    public func start(scope: MacTerminalScope) throws {
        try start(
            executable: MacTerminalSession.resolvedUserShell(),
            arguments: ["-i"],
            workingDirectory: scope.path
        )
    }

    /// Completes once the child process has been reaped. Safe to await from
    /// anywhere; stays completed after exit so late awaiters return immediately.
    public var termination: Void {
        get async {
            guard let stream = terminationStream else { return }
            for await _ in stream { return }
        }
    }

    /// Closes the session: terminate the child (SIGTERM + PTY close, which
    /// delivers SIGHUP to the session), drain the reap, and report whether
    /// the child exited within `timeout`.
    /// - Returns: `true` when the child was reaped in time, `false` when it
    ///   outlived the timeout (state remains `.stopping`).
    ///
    /// Cleanup-semantics limitation: on the SwiftTerm Subprocess backend
    /// (macOS 15+/Swift 6 toolchains) `LocalProcess` exposes no child PID,
    /// so escalation is limited to Subprocess task cancellation plus the PTY
    /// close, which delivers SIGHUP to the session foreground group; a
    /// grandchild that escaped into its own session (`setsid`) can outlive
    /// the close. The forkpty backend escalates to SIGKILL on the whole
    /// process group via the known PID.
    @discardableResult
    public func close(timeout: Duration = .seconds(3)) async -> Bool {
        guard state == .running || state == .stopping else { return true }
        state = .stopping
        if !terminateRequested {
            terminateRequested = true
            terminalView?.process.terminate()
        }
        let reaped = await withTimeout(timeout) { await self.termination }
        if !reaped {
            // On the forkpty backend escalate to SIGKILL on the whole session
            // group; on the Subprocess backend task cancellation plus the PTY
            // close above already delivered SIGHUP/SIGKILL semantics, and no
            // PID is exposed, so there is nothing further to signal.
            if let pid = shellPID {
                kill(-pid, SIGKILL)
                _ = await withTimeout(.seconds(1)) { await self.termination }
            }
        }
        if case .exited = state {
            return true
        }
        return false
    }

    /// Alias kept for call sites that phrase the action as "stop".
    @discardableResult
    public func stop(timeout: Duration = .seconds(3)) async -> Bool {
        await close(timeout: timeout)
    }

    /// Resets an exited session back to idle so the user can start a new one.
    public func reset() {
        guard case .exited = state else { return }
        terminalView = nil
        state = .idle
        terminalTitle = ""
        currentDirectory = nil
        terminationContinuation = nil
        terminationStream = nil
        terminateRequested = false
    }

    /// Resolves the user's shell from `$SHELL`, falling back to /bin/zsh.
    static func resolvedUserShell() -> String {
        let candidates = [
            ProcessInfo.processInfo.environment["SHELL"],
            "/bin/zsh",
            "/bin/bash",
        ].compactMap { $0 }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/bin/zsh"
    }

    /// Internal entry point used by ``start(scope:)`` and the package tests.
    func start(executable: String, arguments: [String], workingDirectory: String?) throws {
        guard state == .idle || state.exited else { return }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw MacTerminalScopeError.notADirectory(executable)
        }
        reset()

        let view = LocalProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480)
        )
        view.processDelegate = self
        terminalView = view

        let stream = AsyncStream<Void> { continuation in
            terminationContinuation = continuation
        }
        terminationStream = stream

        state = .running
        view.startProcess(
            executable: executable,
            args: arguments,
            environment: nil,
            currentDirectory: workingDirectory
        )
    }

    private func childTerminated(exitCode: Int32?) {
        state = .exited(exitCode)
        terminationContinuation?.finish()
        terminationContinuation = nil
    }

    private func withTimeout(
        _ timeout: Duration,
        _ body: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await body()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

extension MacTerminalSessionState {
    fileprivate var exited: Bool {
        if case .exited = self { return true }
        return false
    }
}

// MARK: - SwiftTerm process delegate
//
// SwiftTerm delivers every callback on the main thread (its default
// dispatch queue is DispatchQueue.main, and the Subprocess backend posts
// termination through MainActor.run), so assumeIsolated is safe here.
extension MacTerminalSession: LocalProcessTerminalViewDelegate {
    public nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            self.childTerminated(exitCode: exitCode)
        }
    }

    public nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // SwiftTerm already pushed the new winsize to the PTY; nothing else.
    }

    public nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        MainActor.assumeIsolated {
            self.terminalTitle = title
        }
    }

    public nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        MainActor.assumeIsolated {
            self.currentDirectory = directory
        }
    }
}
