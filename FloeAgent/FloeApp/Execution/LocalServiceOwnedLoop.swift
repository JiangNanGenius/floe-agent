// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools
import FloeExecution
import FloePersistence

/// Keeps the caller's job/port/environment lease until the captured service
/// is confirmed stopped. A stop ACK or a failed probe is not termination.
enum LocalServiceOwnedLoop {
    static func run(
        controller: any LinuxGuestLocalServiceControlling,
        handle: LinuxGuestLocalServiceHandle,
        jobID: UUID,
        runtime: String,
        cancellation: CancellationToken,
        store: BackgroundJobStore,
        previewURL: String,
        isReady: @escaping @Sendable () async -> Bool = { false },
        setPreviewAuthorized: @escaping @Sendable (Bool) -> Void = { _ in },
        onServiceReady: (@Sendable (UUID) async -> Void)? = nil,
        pollInterval: Duration = .seconds(2),
        stopRetryInterval: Duration = .seconds(10)
    ) async throws -> ToolExecutionOutput {
        precondition(pollInterval > .zero && stopRetryInterval >= pollInterval)
        return try await withTaskCancellationHandler {
            // This handle never escapes and is never cancelled. In particular,
            // parent Task cancellation cannot cancel its sleep or controller
            // calls: it only requests a stop through the job's existing token.
            let cleanup = Task.detached(priority: .utility) {
                var snapshot = LocalServiceProgress(state: "starting", runtime: runtime,
                    stdout: "", stderr: "", truncated: false)
                var stopRequested = false
                var announcedReady = false
                var nextStopAttempt: ContinuousClock.Instant?
                var persistenceFailure: (any Error)?
                while true {
                    stopRequested = stopRequested || cancellation.isCancelled
                    if stopRequested {
                        setPreviewAuthorized(false)
                        if nextStopAttempt.map({ ContinuousClock.now >= $0 }) ?? true {
                            // The production controller bounds each attempt
                            // to 15s; retry only this exact captured handle.
                            await controller.stopLocalService(handle)
                            nextStopAttempt = ContinuousClock.now.advanced(by: stopRetryInterval)
                        }
                    }
                    let guest = await controller.localServiceSnapshot(handle)
                    snapshot.state = guest.state
                    snapshot.stdout = guest.stdout
                    snapshot.stderr = guest.stderr
                    snapshot.truncated = guest.truncated
                    if let error = guest.lastError, !error.isEmpty, guest.state != "stopped" {
                        snapshot.stderr += (snapshot.stderr.isEmpty ? "" : "\n") + error
                    }
                    let terminal = !guest.alive && (guest.state == "stopped" || guest.state == "notFound")
                    if terminal {
                        snapshot.previewURL = nil
                        setPreviewAuthorized(false)
                        snapshot.boundAndRedact()
                        do { try await store.updateProgress(id: jobID, data: JSONEncoder().encode(snapshot)) }
                        catch { if persistenceFailure == nil { persistenceFailure = error } }
                        // A save error requests cleanup but must not become a
                        // successful stop, even if a later save recovers.
                        if let persistenceFailure { throw persistenceFailure }
                        return ToolExecutionOutput(
                            digesting: String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self),
                            exitStatus: cancellation.isCancelled ? 0 : 1)
                    }
                    // Unknown/old-capability/error responses and contradictory
                    // "stopped but alive" snapshots retain ownership and stop.
                    if !guest.alive || (guest.state != "running" && guest.state != "starting") {
                        stopRequested = true
                    }
                    stopRequested = stopRequested || cancellation.isCancelled
                    if stopRequested {
                        snapshot.state = "stopping"
                        snapshot.previewURL = nil
                        setPreviewAuthorized(false)
                    } else if guest.state == "running", await isReady(), !cancellation.isCancelled {
                        snapshot.previewURL = previewURL
                        setPreviewAuthorized(true)
                        if !announcedReady {
                            announcedReady = true
                            await onServiceReady?(jobID)
                        }
                    } else {
                        snapshot.previewURL = nil
                        setPreviewAuthorized(false)
                    }
                    snapshot.boundAndRedact()
                    do { try await store.updateProgress(id: jobID, data: JSONEncoder().encode(snapshot)) }
                    catch {
                        if persistenceFailure == nil { persistenceFailure = error }
                        stopRequested = true
                        setPreviewAuthorized(false)
                    }
                    // This detached cleanup is never cancelled. Unlike the
                    // caller's old try? sleep, parent cancellation cannot turn
                    // this bounded polling interval into a busy loop.
                    try await Task.sleep(for: pollInterval)
                }
            }
            // Await even when our parent is cancelled: the enclosing runner
            // still owns its job, reserved port and routing lease until join.
            return try await cleanup.value
        } onCancel: {
            cancellation.cancel()
        }
    }
}
