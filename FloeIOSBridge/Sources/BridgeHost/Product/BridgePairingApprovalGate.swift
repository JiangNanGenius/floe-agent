import Foundation

import BridgeCore

/// Owns the one central owner decision for a fresh pairing request.
///
/// A request may be admitted while Bridge is background (same-phone Safari or
/// another app); exactly one such request waits for the owner to reopen Bridge
/// and decide, until the existing request deadline. Approval itself always
/// requires a live foreground check, the real deadline and the owner button.
///
/// The authority separately enforces `request.timeout`; this gate withdraws
/// the visible prompt at the same deadline and resolves its checked
/// continuation exactly once for approve, deny, timeout, cancellation,
/// app inactivity/background and owner Stop. Late callbacks return `false`
/// and can never grant a client.
@MainActor
final class BridgePairingApprovalGate {
    private var continuation: CheckedContinuation<BridgeRPCApprovalDecision, Never>?
    private var timeoutTask: Task<Void, Never>?
    private(set) var pending: BridgeProductPendingApproval?

    /// Called on the main actor whenever the visible prompt appears or ends.
    var onPendingChanged: ((BridgeProductPendingApproval?) -> Void)?

    func request(_ request: BridgeRPCApprovalRequest) async -> BridgeRPCApprovalDecision {
        // Admission does not require foreground. A local browser may send
        // `/pair` while Bridge is background; queue this one bounded request
        // until the owner reopens Bridge or the existing deadline expires.
        guard BridgeProductApprovalPolicy.canQueue(hasPending: continuation != nil) else {
            return .deny
        }

        let prompt = BridgeProductApprovalPolicy.pending(for: request)
        let requestID = request.requestID
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                // The check above and this assignment both run on the main
                // actor; a concurrent prompt cannot slip between them.
                guard self.continuation == nil else {
                    continuation.resume(returning: .deny)
                    return
                }
                self.continuation = continuation
                self.pending = prompt
                self.onPendingChanged?(prompt)
                self.startTimeout(seconds: request.timeout)
            }
        }, onCancel: { [weak self] in
            // Cancellation is scoped to the request that registered it. A
            // delayed cancel for an already-resolved request must never deny
            // a newer prompt.
            Task { @MainActor [weak self] in
                self?.withdraw(requestID: requestID)
            }
        })
    }

    /// Approves only the visible request, after rechecking that the app is
    /// still foreground and the real deadline has not passed. A late or
    /// background callback resolves the request as denied instead of granting
    /// it; the authority keeps its independent request fence.
    @discardableResult
    func approve(requestID: String? = nil,
                 isForeground: @MainActor () -> Bool) -> Bool {
        guard continuation != nil,
              let active = pending,
              requestID == nil || requestID == active.id else {
            return false
        }
        guard isForeground(), Date() < active.deadline else {
            return resolve(.deny, matching: active.id)
        }
        // `resolve` re-reads the same continuation/pending pair; no other main
        // actor work can interleave between this check and the resume.
        return resolve(.approve, matching: active.id)
    }

    @discardableResult
    func deny(requestID: String? = nil) -> Bool {
        resolve(.deny, matching: requestID)
    }

    /// Resolves a visible prompt as denied. Owner Stop, app inactivity/
    /// background and model teardown pass `nil` to withdraw whatever is
    /// visible; a task-cancellation path passes its own request id so a late
    /// cancel cannot deny a newer prompt. It is safe when nothing is pending.
    @discardableResult
    func withdraw(requestID: String? = nil) -> Bool {
        resolve(.deny, matching: requestID)
    }

    @discardableResult
    private func resolve(_ decision: BridgeRPCApprovalDecision,
                         matching requestID: String?) -> Bool {
        guard let waiting = continuation,
              let active = pending,
              requestID == nil || requestID == active.id else {
            return false
        }
        // Clear all observable state before resuming so a re-entrant callback
        // cannot approve or leave a second checked continuation behind.
        continuation = nil
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        onPendingChanged?(nil)
        waiting.resume(returning: decision)
        return true
    }

    private func startTimeout(seconds: TimeInterval) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(
                for: .seconds(BridgeProductApprovalPolicy.promptInterval(seconds))
            )
            guard !Task.isCancelled else { return }
            self?.withdraw()
        }
    }
}
