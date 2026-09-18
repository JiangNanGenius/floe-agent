// FloeApp — UI-free intent queue for one native Office document session.
//
// SPDX-License-Identifier: MPL-2.0
//
// The Office session owns exactly one working copy, so exactly one operation
// may own it at a time. `open`, `requestEditing`, `save`, attachment insertion
// and close all serialize through `OfficeFileSession.operating`; this type
// decides what happens to a new *document intent* that arrives while the
// session is busy:
//
//   • an explicit `.edit` intent is never superseded by an automatic `.preview`
//     reopen (the previous root cause of "tapping Edit does nothing"),
//   • a newer explicit intent supersedes an older queued one, whose waiter is
//     cancelled instead of hanging,
//   • release/close cancels the queued intent so a continuation can never
//     outlive the session.
//
// It is deliberately free of UIKit/SwiftUI so the lifecycle rules can be
// unit-tested directly (see Local/Private/build191-feedback/ide/tests).

import Foundation

struct OfficeEditIntentQueue {
    enum Intent: String, Equatable, Sendable {
        case preview
        case edit
    }

    struct Ticket: Equatable, Sendable {
        let intent: Intent
        let token: Int
        /// Token of the queued intent that was replaced, if any. Its waiter
        /// must be resumed with `false`.
        let supersededToken: Int?
    }

    enum Decision: Equatable, Sendable {
        /// The session is idle: run this intent immediately.
        case runNow(token: Int)
        /// The session is busy: the intent is queued under `ticket`.
        case queued(Ticket)
        /// An automatic preview reopen must not displace a queued edit.
        case ignorePreview
    }

    private var nextToken = 0
    private var pending: (intent: Intent, token: Int)?

    /// True while this queue holds a queued (not yet running) intent.
    var hasPending: Bool { pending != nil }

    mutating func begin(_ intent: Intent, isBusy: Bool) -> Decision {
        if isBusy {
            if let pending, pending.intent == .edit, intent == .preview {
                return .ignorePreview
            }
            let superseded = pending?.token
            let token = allocate()
            pending = (intent, token)
            return .queued(Ticket(intent: intent, token: token, supersededToken: superseded))
        }
        return .runNow(token: allocate())
    }

    /// Takes the queued intent for execution after the owning operation
    /// settles. The caller owns the returned ticket until it runs or is
    /// restored.
    mutating func takePending() -> (intent: Intent, token: Int)? {
        guard let pending else { return nil }
        self.pending = nil
        return pending
    }

    /// Cancels the queued intent (release/close). Returns its token so the
    /// session can resume the waiter with `false`.
    mutating func cancelPending() -> Int? {
        guard let pending else { return nil }
        self.pending = nil
        return pending.token
    }

    /// Puts an intent back when the session was taken by a newer operation
    /// between `takePending` and execution. Never clobbers a newer queued
    /// intent.
    mutating func restoreIfEmpty(intent: Intent, token: Int) {
        guard pending == nil else { return }
        pending = (intent, token)
    }

    /// Token for an intent that was never queued (defensive restore path).
    mutating func allocateToken() -> Int { allocate() }

    private mutating func allocate() -> Int {
        nextToken += 1
        return nextToken
    }
}
