// FloeApp — wire contract for the Mac task-owned browser lane.
//
// This file is the shared, platform-neutral contract between the Mac task
// browser session, the compiled `browser.*` tools and the visible workbench
// browser surface. FloeMac compiles it directly into the unified Mac app
// target next to BrowserDownloadService.swift (FloeTools is available there,
// unlike the toolbox package); it deliberately stays Foundation/SwiftUI/
// WebKit-only and is excluded from UIKit builds, so the iPad app never gains
// a second, divergent browser protocol. Model-supplied JSON decodes into
// these values; every command still carries the runtime-issued sessionID and
// the tool layer selects the calling task's session from the ToolContext, so
// model input can never address another task's browser.

#if canImport(SwiftUI) && canImport(WebKit) && !canImport(UIKit)
import Foundation

/// Typed control refusal raised by the Mac task browser. Tool callers turn
/// these into an honest needsUser/refusal result instead of touching the
/// page; they never carry page data.
enum MacBrowserControlError: Error, LocalizedError, Equatable {
    case heldByAnotherRun
    case needsUser(String)

    var errorDescription: String? {
        switch self {
        case .heldByAnotherRun:
            return "This browser is being used by another run; continue with other authorized work"
        case .needsUser(let message):
            return message
        }
    }
}

enum MacBrowserAction: Sendable, Codable, Hashable {
    case protocolInfo
    case create
    case navigate(url: String)
    case back
    case forward
    case reload
    case observe(cursor: Int?)
    case click(MacBrowserTarget)
    case type(MacBrowserTarget, text: String, submit: Bool)
    case scroll(deltaX: Double, deltaY: Double)
    case wait(MacBrowserWaitCondition)
    case events(afterSequence: Int?, limit: Int)
    case listTabs
    case activateTab(UUID)
    case closeTab(UUID)
    case takeover
}

/// Public-WebKit approximation of CDP wait primitives, mirroring the iPad
/// task browser. Network idle means main-frame loading has stopped and the
/// DOM has stayed unchanged for the requested interval.
enum MacBrowserWaitCondition: Sendable, Codable, Hashable {
    case load
    case domContentLoaded
    case selector(String)
    case text(String)
    case documentChanged(from: String)
    case idle(milliseconds: Int)
}

/// Ordinary authorized interactions only: a stable element reference from a
/// same-document observation. Deliberately no coordinate/visual fallback and
/// no arbitrary script surface on the Mac lane.
enum MacBrowserTarget: Sendable, Codable, Hashable {
    case element(ref: String, documentID: String)
}

struct MacBrowserCommand: Sendable, Codable, Hashable {
    var version: Int = 1
    var requestID: UUID = UUID()
    var sessionID: UUID
    var tabID: UUID?
    var expectedDocumentID: String?
    var timeoutMilliseconds: Int = 15_000
    var action: MacBrowserAction
}

struct MacBrowserNode: Sendable, Codable, Hashable, Identifiable {
    var id: String { ref }
    var ref: String
    var role: String
    var name: String
    var text: String
    var value: String?
    var state: [String: Bool]
    var bounds: MacBrowserBounds
}

struct MacBrowserBounds: Sendable, Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

/// A bounded lifecycle/DOM event for the task's own browser. Method names
/// intentionally mirror CDP domains where the semantics match.
struct MacBrowserProtocolEvent: Sendable, Codable, Hashable, Identifiable {
    var id: Int { sequence }
    var sequence: Int
    var timestamp: Date
    var tabID: UUID
    var documentID: String
    var method: String
    var detail: String?
    var revision: Int?
}

struct MacBrowserTabSnapshot: Sendable, Codable, Hashable, Identifiable {
    var id: UUID
    var url: String
    var title: String
    var isActive: Bool
}

struct MacBrowserPageSnapshot: Sendable, Codable, Hashable {
    var documentID: String
    var revision: Int
    var url: String
    var title: String
    var isLoading: Bool
    var viewportWidth: Double
    var viewportHeight: Double
    var tabs: [MacBrowserTabSnapshot]
    var nodes: [MacBrowserNode]
    var nextCursor: Int?
}

struct MacBrowserFailure: Sendable, Codable, Hashable {
    var code: String
    var message: String
}

struct MacBrowserResult: Sendable, Codable, Hashable {
    enum Status: String, Sendable, Codable, Hashable {
        case ok, stale, blocked, needsUser, timeout, failed
    }

    var requestID: UUID
    var status: Status
    var page: MacBrowserPageSnapshot?
    var message: String?
    var error: MacBrowserFailure?
    var events: [MacBrowserProtocolEvent] = []
    var nextEventSequence: Int?
    var protocolVersion: String?
}

/// One model run's control of this task's browser. `runID` is the
/// runtime-issued logical owner (the parent run when a delegated child acts
/// for it); `id` is the token only `browser.release` must present; `epoch`
/// fences a completion once control has been released, re-acquired or handed
/// to the user.
struct MacBrowserControlLease: Sendable, Equatable, Hashable {
    let id: UUID
    let runID: UUID
    let epoch: Int
}

enum MacBrowserControlAcquisition: Equatable {
    case acquired(MacBrowserControlLease)
    case heldByAnotherRun
    case needsUser(String)
}

enum MacBrowserControlReleaseOutcome: Equatable {
    case released
    /// Repeating the same release, or presenting a token from an earlier
    /// holding period, has no effect on the current holder.
    case alreadyReleased
    case heldByAnotherRun
}

/// Publicly safe description of the last model action for the visible
/// status strip. It never carries page text, typed content, credentials or
/// coordinates.
struct MacBrowserModelActivity: Equatable {
    enum Kind: String {
        case observing, navigating, clicking, typing, scrolling, waiting, downloading
    }
    var kind: Kind
    /// Public label of the exact target this executed action addressed (for
    /// example a button's visible text). Absent whenever the action cannot
    /// prove a same-document target; the UI then stays generic.
    var detail: String?
    var at: Date
}
#endif
