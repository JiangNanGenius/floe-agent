// SPDX-License-Identifier: MPL-2.0
#if canImport(FloeExecution) && canImport(FloeTools) && canImport(FloePersistence)
import Foundation
import FloeCore
import FloeExecution
import FloePersistence
import FloeTools
import FloeGameCore
import FloeGameExecutionBridge

/// Concrete `GameShellRunning` over Main's existing shell and environment
/// routing. It never mints a run, conversation or environment identity:
/// `GameExecutionAuthority` must come from a real saved `RunRecord` whose
/// `TaskExecutionBinding` matches the project workspace/environment.
public actor MainLocalShellRunner: GameShellRunning {
    private let shell: LocalShellService
    private let runs: any RunStore

    public init(shell: LocalShellService, runs: any RunStore) {
        self.shell = shell
        self.runs = runs
    }

    public func run(_ command: GameShellCommand,
                    context: GameShellContext) async throws -> GameShellResult {
        guard let environmentID = context.environmentID else {
            throw GameExecutionError.prerequisite(
                "This game project has no resolved execution environment. Select or restore the project's Linux environment first.")
        }
        guard let run = try await runs.run(id: context.runID) else {
            throw GameExecutionError.prerequisite(
                "No saved task run exists for this game build. Start the project assistant/native-service run (or a chat run in this workspace) before building.")
        }
        guard run.conversationID == context.conversationID else {
            throw GameExecutionError.prerequisite(
                "The saved run belongs to a different conversation; the game build was not started.")
        }
        guard let binding = run.executionBinding,
              binding.conversationID == run.conversationID,
              binding.target.environmentID == environmentID else {
            throw GameExecutionError.prerequisite(
                "The saved run has no matching execution binding for this workspace/environment. Re-select the task's execution location.")
        }
        if let expected = context.executionBindingGeneration,
           expected != binding.generation {
            throw GameExecutionError.prerequisite(
                "The task execution binding changed since this game build was requested. Re-run from the current saved state.")
        }

        let cancellation = CancellationToken()
        var toolContext = ToolContext(
            runID: context.runID,
            toolCallID: "jobs.game-build",
            toolIdempotencyKey: UUID().uuidString.lowercased(),
            scope: .local,
            workspaceRootURL: context.workspaceRoot,
            cancellation: cancellation,
            environmentID: environmentID,
            executionBindingGeneration: binding.generation,
            conversationID: context.conversationID)
        // This is the same routing decision as the real exec.shell tool, so
        // environment pins, backend selection and leases are revalidated by the
        // existing coordinator rather than by this adapter.
        toolContext.executionToolName = "exec.shell"

        let lease: ToolEnvironmentLease
        do {
            lease = try await withTaskCancellationHandler {
                try await ToolEnvironmentRouting.shared.acquire(toolContext)
            } onCancel: {
                cancellation.cancel()
            }
        } catch is CancellationError {
            throw GameExecutionError.cancelled
        } catch {
            throw GameExecutionError.prerequisite(
                "The task execution environment could not be acquired: \(error.localizedDescription)")
        }
        guard lease.context.environmentID == environmentID else {
            await lease.finish()
            throw GameExecutionError.prerequisite(
                "The acquired execution lease does not match the saved run's environment; the build was not started.")
        }

        let result: LocalShellService.RunResult
        do {
            result = await withTaskCancellationHandler {
                await shell.run(
                    command: command.shellLine,
                    cwd: command.cwd,
                    environment: command.environment,
                    skillConfiguration: nil,
                    stdin: command.stdin,
                    requestedTimeout: nil,
                    timeoutPolicy: .advisory,
                    maxOutputBytes: 256 * 1_024,
                    isBackground: true,
                    context: lease.context)
            } onCancel: {
                cancellation.cancel()
            }
        } catch {
            await lease.finish()
            throw error
        }
        await lease.finish()
        return try Self.map(result)
    }

    private static func map(_ result: LocalShellService.RunResult) throws -> GameShellResult {
        switch result {
        case .blocked(let verdict):
            throw GameExecutionError.commandBlocked(
                verdict.reason ?? verdict.matchedPatternID ?? "shell policy")
        case .outcome(let outcome):
            switch outcome {
            case .exited(let code, let stdout, let stderr, let truncated, _, _):
                return .init(exitCode: code,
                             stdout: Data(stdout.utf8),
                             stderr: Data(stderr.utf8),
                             truncated: truncated)
            case .timedOut(let stdout, let stderr, _):
                throw GameExecutionError.commandTimedOut(
                    "command exceeded its deadline; stdout=\(stdout.prefix(512)) stderr=\(stderr.prefix(512))")
            case .cancelled:
                throw GameExecutionError.cancelled
            case .notStarted(let reason):
                throw GameExecutionError.commandNotStarted(reason)
            case .linuxUpgradePending(let pending):
                throw GameExecutionError.commandNotStarted(pending.localizedDescription)
            case .outcomeUnknown(let jobID, let message):
                throw GameExecutionError.outcomeUnknown("job \(jobID): \(message)")
            case .failed(let message):
                throw GameExecutionError.commandFailed(message)
            }
        }
    }
}

/// Resolves a real saved run and its execution binding. Root supplies the
/// actual project assistant/native-service run ID for Space; a missing run is
/// an explicit error, never a generated UUID.
public struct MainGameExecutionAuthorityResolver: Sendable {
    private let runs: any RunStore

    public init(runs: any RunStore) {
        self.runs = runs
    }

    public func resolve(context: GameProjectContext, runID: UUID) async throws -> GameExecutionAuthority {
        guard let run = try await runs.run(id: runID) else {
            throw GameExecutionError.prerequisite(
                "No saved run \(runID.uuidString.lowercased()) exists for this game project.")
        }
        guard let binding = run.executionBinding,
              binding.conversationID == run.conversationID else {
            throw GameExecutionError.prerequisite(
                "The saved run has no execution binding; open the project assistant/native-service run and choose its environment again.")
        }
        if let environmentID = context.environmentID,
           environmentID != binding.target.environmentID {
            throw GameExecutionError.prerequisite(
                "The saved run's environment does not match this game project. Re-select the task's execution location.")
        }
        return .init(runID: run.id, conversationID: run.conversationID,
                     environmentID: binding.target.environmentID,
                     executionBindingGeneration: binding.generation)
    }
}
#endif
