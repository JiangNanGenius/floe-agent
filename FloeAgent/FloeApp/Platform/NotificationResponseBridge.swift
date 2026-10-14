// FloeApp — explicit notification-response completion bridge.
//
// Build 271 (internal TestFlight, iOS 27.0.1) terminated with an uncaught
// exception on the thread executing
// `BackgroundRunCoordinator.userNotificationCenter(_:didReceive:)`. The
// UUID-matched symbolication of that thread
// (Local/Private/capability-closure-20261014/crash/CRASH-271-SYMBOLICATED.md)
// resolves the top app frame to `@objc closure #1 in ...(_:didReceive:)` — the
// compiler-generated Objective-C bridge of the Swift `async` delegate
// convenience — with UIKitCore/Foundation above it and the exception raised
// from Foundation. The delegate now implements the completion-handler selector
// directly; this file owns the parse -> main-actor hand-off -> exactly-once
// completion contract that implementation uses.
//
// The bridge deliberately does NOT try to catch the framework's exception or
// to install a process-wide handler: an Objective-C exception raised inside
// the system's own completion path is not catchable from Swift, and the
// llama/ggml terminate handler seen in the crash log is mechanism, not cause.
//
// Privacy: the stage vocabulary below is fixed, bounded and content-free. The
// notification `userInfo` dictionary, alert identifiers, conversation/run/
// environment ids and any exception text never reach this trail, so the next
// internal trial can name the exact stage from a crash without the log
// becoming a notification-data leak.

import Foundation
import FloeCore

/// Fixed stage vocabulary for one notification-response delivery.
enum NotificationResponseStage: String, Sendable, CaseIterable {
    /// The delegate selector was entered and the payload is about to be read.
    case received
    /// The payload is not a deep link this build understands.
    case rejectedPayload
    /// The route gate accepted the tap and navigation was posted.
    case routed
    /// The route was held for a cold launch / pre-ready transition.
    case deferred
    /// Duplicate tap or a route a newer tap superseded.
    case suppressed
    /// The target is gone, stopped or unverifiable: the safe prompt ran.
    case unreachableTarget
    /// The coordinator was released before the main-actor hand-off ran.
    case ownerReleased
    /// The system completion handler is being invoked right now. A crash
    /// log whose LAST recorded stage is this one brackets the completion
    /// invocation; it is the last recorded stage, not conclusive proof of
    /// the root cause (nested, reentrant or other concurrent work can also
    /// be in flight).
    case completionDispatching
    /// The completion handler returned.
    case completionDelivered
    /// A second delivery attempt was refused (the system handler must be
    /// called exactly once).
    case completionSuppressed
}

/// Durable redacted stage trail for the notification-response path.
///
/// Warning level on purpose: the shared log ring buffer persists warnings and
/// errors synchronously, so a crash inside the framework's completion path
/// cannot lose the last stage that was actually reached. The number of marks
/// per response is bounded (one `received`, at most one outcome, two completion
/// marks); a repeat tap adds two more.
enum NotificationResponseTrace {
    static func mark(_ stage: NotificationResponseStage, kind: BackgroundWorkKind? = nil) {
        let suffix = kind.map { " kind=\($0.rawValue)" } ?? ""
        FloeLogger(category: .app).warning(
            "notificationResponseStage=\(stage.rawValue)\(suffix)"
        )
    }
}

/// Exactly-once delivery of one `UNUserNotificationCenter` response completion
/// handler.
///
/// `UNUserNotificationCenter` requires the handler to be called. It is invoked
/// at most once — a second attempt is refused and recorded — and production
/// call sites always invoke it on the main actor, as soon as the synchronous
/// route gate has accepted, deferred or suppressed the tap. It is never held
/// across the route's own reload/target-resolution work.
final class NotificationResponseCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    var hasDelivered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handler == nil
    }

    /// Delivers the completion handler at most once and reports whether this
    /// call was the one that delivered it.
    @discardableResult
    func finish() -> Bool {
        lock.lock()
        let handler = self.handler
        self.handler = nil
        lock.unlock()
        guard let handler else {
            NotificationResponseTrace.mark(.completionSuppressed)
            return false
        }
        NotificationResponseTrace.mark(.completionDispatching)
        handler()
        NotificationResponseTrace.mark(.completionDelivered)
        return true
    }
}

/// The main-actor receiver of one parsed notification route.
///
/// The production conformance is `BackgroundRunCoordinator`, which applies the
/// existing duplicate/cold-launch/generation gates and the authoritative
/// target lookup. The focused regressions conform a recorder, so the same
/// intake code drives production and tests.
@MainActor
protocol NotificationResponseRouting: AnyObject, Sendable {
    func routeNotificationResponse(
        key: String,
        link: BackgroundWorkDeepLink,
        identifier: String
    )
}

/// Real intake for one `UNNotificationResponse`, shared by the delegate bridge
/// and the regressions.
enum NotificationResponseIntake {
    /// Stable identity for duplicate suppression: the notification identifier
    /// plus the deep-link payload, so repeat taps of the same alert collapse
    /// while distinct alerts never do.
    static func routeKey(identifier: String, link: BackgroundWorkDeepLink) -> String {
        let payload = link.userInfo
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        return "\(identifier)|\(payload)"
    }

    /// Parses the payload on the callback thread — the raw `Any`-valued
    /// dictionary and the `UNNotificationResponse` never cross an actor
    /// boundary — then runs the route gate and the completion handler on the
    /// main actor.
    ///
    /// The completion is delivered exactly once for every outcome:
    /// - a valid route, after the gate ran (routed / deferred / suppressed);
    /// - an unparseable payload, without touching routing;
    /// - a released owner, without touching routing.
    static func accept(
        identifier: String,
        payload: [AnyHashable: Any],
        completion: @escaping () -> Void,
        routing: (any NotificationResponseRouting)?
    ) {
        let completion = NotificationResponseCompletion(completion)
        NotificationResponseTrace.mark(.received)
        guard let link = BackgroundWorkDeepLink.parse(payload) else {
            NotificationResponseTrace.mark(.rejectedPayload)
            Task { @MainActor in
                completion.finish()
            }
            return
        }
        let key = routeKey(identifier: identifier, link: link)
        Task { @MainActor [weak routing] in
            guard let routing else {
                NotificationResponseTrace.mark(.ownerReleased)
                completion.finish()
                return
            }
            routing.routeNotificationResponse(key: key, link: link, identifier: identifier)
            completion.finish()
        }
    }
}
