// FloeApp — app-facing decision surface for the heavy-runtime arbiter.
//
// SPDX-License-Identifier: MPL-2.0
//
// `HeavyRuntimeArbiter` never stops a Linux guest on its own: when a local
// model is about to start and Linux work is active, it calls the app's
// decision handler with the exact snapshot. This center is that handler's UI
// half — it publishes one pending conflict and suspends the local-model
// request until the user answers the alert in `FloeAgentApp`. Cancellation
// resolves as "defer", so a stopped or backgrounded run never leaves the
// alert (or the continuation) dangling.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore

@MainActor
final class HeavyRuntimeConflictCenter: ObservableObject {
    /// One conflict shown to the user. Environment identifiers are opaque
    /// Floe IDs; nothing here contains paths, prompts or credentials.
    struct PendingConflict: Identifiable, Equatable {
        let id = UUID()
        let guestEnvironmentIDs: [String]
        let localServices: [String]

        var guestCount: Int { guestEnvironmentIDs.count }
        var serviceCount: Int { localServices.count }
    }

    @Published private(set) var pending: PendingConflict?

    private var continuation: CheckedContinuation<HeavyRuntimeArbiter.ConflictDecision, Never>?
    private var decisionToken: UUID?

    var hasPendingDecision: Bool { continuation != nil }

    /// Suspends until the user answers. A second concurrent request defers
    /// immediately instead of replacing the visible alert. Cancellation that
    /// lands before the continuation registers still resolves as "defer" and
    /// clears the token, so neither the alert nor the decision state can
    /// dangle.
    func requestDecision(
        _ activity: HeavyRuntimeArbiter.LinuxActivity
    ) async -> HeavyRuntimeArbiter.ConflictDecision {
        guard continuation == nil else { return .deferLocalModel }
        let token = UUID()
        decisionToken = token
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    if decisionToken == token { decisionToken = nil }
                    continuation.resume(returning: .deferLocalModel)
                    return
                }
                self.continuation = continuation
                self.pending = PendingConflict(
                    guestEnvironmentIDs: activity.guestEnvironmentIDs,
                    localServices: activity.localServices
                )
                FloeLogger(category: .providers).info(
                    "heavyRuntimeConflictPresented \(activity.summary)"
                )
            }
        } onCancel: {
            Task { @MainActor in
                self.resolveIfCurrent(token: token)
            }
        }
    }

    /// Answers the pending conflict. Idempotent: a dismissal after the button
    /// action cannot resume the same continuation twice.
    func resolve(_ decision: HeavyRuntimeArbiter.ConflictDecision) {
        guard let continuation else { return }
        self.continuation = nil
        decisionToken = nil
        pending = nil
        FloeLogger(category: .providers).info(
            "heavyRuntimeConflictResolved decision=\(decision == .stopGuestsAndProceed ? "stopGuests" : "defer")"
        )
        continuation.resume(returning: decision)
    }

    private func resolveIfCurrent(token: UUID) {
        guard decisionToken == token else { return }
        resolve(.deferLocalModel)
    }
}
#endif
