// SPDX-License-Identifier: MPL-2.0

import FloeMacToolbox
import Foundation
import SwiftUI

/// Owns the workbench browser surface of the Agent window. Browser state is
/// bound to the task it was opened from, mirroring the iPad model: every
/// owner conversation gets its own isolated session (its own non-persistent
/// store, so pages and cookies never leak across tasks), returning to the
/// same task preserves that task's page, and opening the browser from a
/// different task can never show a prior task's content. The task draft is
/// owned by the existing draft store and is untouched by browsing.
///
/// Requests are nonce-tagged so a menu drive or a repeated link open is
/// observed even when the URL repeats.
@MainActor
final class MacBrowserWorkbenchController: ObservableObject {
    enum Presentation: Equatable {
        case empty, url(URL)
    }

    struct Request: Equatable {
        let presentation: Presentation
        let nonce: UUID
    }

    /// Mirrors the iPad task-browser bound; older unused task sessions are
    /// stopped and evicted past this count.
    static let taskSessionLimit = 6

    private var generalSession: MacBrowserSession?
    private var taskSessions: [UUID: MacBrowserSession] = [:]
    private var taskRecency: [UUID] = []

    @Published private(set) var presentRequest: Request?
    @Published private(set) var returnRequest: UUID?
    #if FLOE_MAC_HOST_SMOKE
    /// Observable mirror of the workbench destination for UnifiedMacSmoke.
    @Published var isPresented = false
    #endif

    /// Session for an owner conversation; nil is the shared general session
    /// used outside a saved task. Materializes lazily and recency-orders the
    /// task sessions without ever reusing one task's session for another.
    func session(for owner: UUID?) -> MacBrowserSession {
        guard let owner else {
            if let generalSession { return generalSession }
            let session = MacBrowserSession()
            generalSession = session
            return session
        }
        if let existing = taskSessions[owner] {
            touch(owner)
            return existing
        }
        while taskRecency.count >= Self.taskSessionLimit, let evicted = taskRecency.first {
            taskRecency.removeFirst()
            taskSessions.removeValue(forKey: evicted)?.stop()
        }
        let session = MacBrowserSession()
        taskSessions[owner] = session
        touch(owner)
        return session
    }

    /// The task-bound session for smoke and diagnostics; nil only for owners
    /// that never presented.
    func existingTaskSession(for owner: UUID) -> MacBrowserSession? { taskSessions[owner] }

    func discard(owner: UUID) {
        taskRecency.removeAll { $0 == owner }
        taskSessions.removeValue(forKey: owner)?.stop()
    }

    /// Show the browser workbench without changing the page.
    func present() {
        presentRequest = Request(presentation: .empty, nonce: UUID())
    }

    /// Show the browser workbench and navigate to a chat-supplied link; the
    /// scheme guard stays authoritative for the final navigation.
    func present(url: URL) {
        presentRequest = Request(presentation: .url(url), nonce: UUID())
    }

    /// Ask the workbench to return to the destination it was opened from.
    func returnToTask() {
        returnRequest = UUID()
    }

    func reset() {
        generalSession?.stop()
        generalSession = nil
        for session in taskSessions.values { session.stop() }
        taskSessions.removeAll()
        taskRecency.removeAll()
        presentRequest = nil
        returnRequest = nil
        #if FLOE_MAC_HOST_SMOKE
        isPresented = false
        #endif
    }

    private func touch(_ owner: UUID) {
        taskRecency.removeAll { $0 == owner }
        taskRecency.append(owner)
    }
}
