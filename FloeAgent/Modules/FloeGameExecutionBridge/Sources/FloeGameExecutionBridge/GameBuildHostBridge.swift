// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameBuildKit
import FloeGameCore

/// `GameBuildHostPort` over the host's existing shell service. It adds no
/// process executor: `GameShellRunning` is implemented by the Main binding over
/// `LocalShellService` + `ToolEnvironmentRouting`.
///
/// The coordinator's only non-workspace command is `unzip -tq <staged zip>`.
/// That archive is already app-owned and outside the guest's workspace share,
/// so the bridge validates it through the reviewed archive exchange instead of
/// handing a host path to the guest.
public actor GameBuildHostBridge: GameBuildHostPort {
    private let shell: any GameShellRunning
    private let contextProvider: GameShellContextProvider
    private var active: [String: Task<GameShellResult, any Error>] = [:]

    public init(shell: any GameShellRunning, contextProvider: @escaping GameShellContextProvider) {
        self.shell = shell
        self.contextProvider = contextProvider
    }

    public func run(_ command: GameHostCommand) async throws -> GameHostResult {
        if Self.isArchivePreflight(command) {
            guard let path = command.arguments.last else {
                throw GameBuildError.io("archive preflight has no path")
            }
            do {
                try Self.verifyArchivePreflight(URL(fileURLWithPath: path))
            } catch {
                throw GameBuildError.dispatchFailed("host archive preflight rejected the staged source")
            }
            return .init(exitCode: 0, stdout: Data(), stderr: Data())
        }

        let jobID = UUID().uuidString.lowercased()
        let shellCommand = GameShellCommand(
            executable: command.executable,
            arguments: command.arguments,
            cwd: command.workingDirectory ?? ".")
        let context = try await contextProvider()
        let task = Task { [shell] in
            try await shell.run(shellCommand, context: context)
        }
        active[jobID] = task
        defer { active.removeValue(forKey: jobID) }
        let result: GameShellResult
        do {
            result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            throw GameBuildError.cancelled
        } catch let error as GameExecutionError {
            throw GameBuildError.dispatchFailed(error.localizedDescription)
        } catch {
            throw GameBuildError.dispatchFailed(String(describing: error))
        }
        return .init(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
    }

    public func terminate(jobID: String) async throws {
        active.removeValue(forKey: jobID)?.cancel()
    }

    private static func isArchivePreflight(_ command: GameHostCommand) -> Bool {
        command.executable == "unzip"
            && command.arguments.count == 2
            && command.arguments[0] == "-tq"
    }

    private static func verifyArchivePreflight(_ url: URL) throws {
        guard url.isFileURL, !url.path.isEmpty else {
            throw GameArchiveError.invalidTarget
        }
        let exchange = GameArchiveExchange()
        let listing = try exchange.inspect(archive: url)
        guard !listing.entries.isEmpty else {
            throw GameArchiveError.invalidTarget
        }
        for entry in listing.entries where entry.kind == .symlink {
            throw GameArchiveError.symlinkEntry(entry.path)
        }
    }
}
