// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXCore
import FloeLaTeXParsing
import FloeLaTeXEngine

/// The existing build service still owns snapshot, cancellation, terminal
/// state, PDF validation and publication. This adapter retries only a known,
/// stopped compiler whose new missing resources have actually been prepared.
struct LaTeXPreparedEngine: LaTeXEngineRunning {
    let plan: LaTeXDependencyPlan
    let initialReceipt: LaTeXPreparationReceipt
    let initialEngine: any LaTeXEngineRunning
    let preparer: LaTeXDependencyPreparer
    let makeEngine: @Sendable () async throws -> any LaTeXEngineRunning
    let preparationProgress: @Sendable (LaTeXPreparationProgress) -> Void

    func capabilities() async -> [LaTeXEngineCapability] { await initialEngine.capabilities() }
    func run(_ request: LaTeXEngineRequest, progress: @escaping @Sendable (String) -> Void) async throws -> LaTeXEngineOutput {
        guard request.executionOwner == preparer.transport.owner,
              request.snapshot.manifest.id == plan.projectID, request.snapshot.manifest.revision == plan.revision,
              request.snapshot.manifest.engine == plan.engine, request.snapshot.manifest.mainFile == plan.mainFile,
              LaTeXDigest.hash(try LaTeXDigest.encode(request.snapshot.manifest)) == plan.inputDigest,
              initialReceipt.projectID == plan.projectID, initialReceipt.revision == plan.revision,
              initialReceipt.inputDigest == plan.inputDigest, initialReceipt.environmentID == request.executionOwner?.environmentID else {
            throw LaTeXError.unavailable("The project or execution environment changed during preparation. Retry typesetting the current revision.")
        }
        try FileManager.default.createDirectory(at: request.outputRoot, withIntermediateDirectories: true)
        try save(initialReceipt, name: "DependencyPreparation-initial.json", root: request.outputRoot)
        var currentPlan = plan, currentEngine = initialEngine, savedMessages = [String]()
        let started = ContinuousClock.now
        for attempt in 1...4 {
            try Task.checkCancellation()
            let elapsed = started.duration(to: .now).components.seconds
            let remaining = Int64(request.configuration.timeoutSeconds) - elapsed
            guard remaining > 0 else { throw LaTeXEngineFailure("Typesetting reached its time limit.", messages: savedMessages) }
            var operation = request
            operation.configuration.timeoutSeconds = min(request.configuration.timeoutSeconds, Int(remaining))
            operation.outputRoot = request.outputRoot.appendingPathComponent(String(format: "attempt-%02d", attempt), isDirectory: true)
            guard !FileManager.default.fileExists(atPath: operation.outputRoot.path) else { throw LaTeXError.invalidOperation("The build attempt already exists. Its recoverable output was preserved.") }
            preparationProgress(.init(stage: .compiling))
            do {
                var output = try await currentEngine.run(operation, progress: progress)
                output.messages = Array((savedMessages + output.messages).prefix(4096))
                return output
            } catch let failure as LaTeXEngineFailure {
                let messages = [failure.message] + failure.messages
                do {
                    try save(FailedAttempt(attempt: attempt, message: failure.message, messages: failure.messages,
                        workerStopped: failure.workerStopped, cancelled: failure.cancelled),
                        name: String(format: "DependencyFailure-%02d.json", attempt), root: request.outputRoot)
                } catch {
                    // A local receipt write failure cannot turn an unconfirmed
                    // remote worker into a stopped one or release its lease.
                    throw LaTeXEngineFailure(failure.message, messages: failure.messages + [error.localizedDescription],
                        cancelled: failure.cancelled, workerStopped: failure.workerStopped)
                }
                savedMessages += messages.map { String($0.suffix(65536)) }
                guard failure.workerStopped, !failure.cancelled, !Task.isCancelled, attempt < 4 else {
                    throw LaTeXEngineFailure(failure.message, messages: savedMessages, cancelled: failure.cancelled, workerStopped: failure.workerStopped)
                }
                let supplemented = try LaTeXDependencyPlanner.supplement(currentPlan, compilerMessages: messages)
                guard Set(supplemented.requirements.map(\.id)) != Set(currentPlan.requirements.map(\.id)) else {
                    throw LaTeXEngineFailure(failure.message, messages: savedMessages)
                }
                progress("Preparing additional resources reported by the compiler")
                let receipt: LaTeXPreparationReceipt
                do {
                    receipt = try await preparer.prepare(supplemented, offline: request.configuration.offline, progress: preparationProgress)
                } catch let preparationFailure as LaTeXEngineFailure {
                    throw LaTeXEngineFailure(preparationFailure.message, messages: savedMessages + preparationFailure.messages,
                        cancelled: preparationFailure.cancelled, workerStopped: preparationFailure.workerStopped)
                } catch {
                    if error is CancellationError { throw error }
                    throw LaTeXEngineFailure(error.localizedDescription, messages: savedMessages)
                }
                try save(receipt, name: String(format: "DependencyPreparation-%02d.json", attempt), root: request.outputRoot)
                guard receipt.changedResources else { throw LaTeXEngineFailure(failure.message, messages: savedMessages) }
                currentPlan = supplemented
                currentEngine = try await makeEngine()
            }
        }
        throw LaTeXEngineFailure("Typesetting could not resolve further dependencies.", messages: savedMessages)
    }
    private struct FailedAttempt: Encodable {
        var attempt: Int; var message: String; var messages: [String]; var workerStopped: Bool; var cancelled: Bool
    }
    private func save<T: Encodable>(_ value: T, name: String, root: URL) throws {
        let url = root.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw LaTeXError.invalidOperation("The preparation receipt already exists and was preserved.") }
        try LaTeXDigest.encode(value).write(to: url, options: .atomic)
    }
}
