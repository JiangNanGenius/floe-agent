// FloeAppTests — the notification-response completion bridge.
//
// Build 271 (internal TestFlight, iOS 27.0.1) aborted with an uncaught
// exception on the thread executing the compiler-generated Objective-C bridge
// of the coordinator's `async` notification delegate. The production delegate
// now implements the completion-handler selector directly and this bridge owns
// the contract: parse on the callback thread, run the route gate and the
// completion handler on the main actor, and deliver the completion exactly
// once for every outcome. These regressions drive the real
// `NotificationResponseIntake` / `NotificationResponseCompletion`; the only
// stand-in is a recording `NotificationResponseRouting` conformance (the
// production conformance is `BackgroundRunCoordinator`, covered by
// `BackgroundWorkNotificationRouteTests`).
//
// The Build 271 symbolication is retained privately in
// `Local/Private/capability-closure-20261014/crash/CRASH-271-SYMBOLICATED.md`;
// this suite locks the bridge behavior and the content-free stage trail, not a
// claim that the framework's own exception is caught.

#if canImport(UIKit) && DEBUG
import Foundation
import Testing
import UIKit
import UserNotifications
import FloeCore
@testable import FloeApp

/// One-shot awaitable signal that can be fired from any thread.
private final class BridgeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var continuation: CheckedContinuation<Void, Never>?

    func fire() {
        lock.lock()
        done = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if done {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

/// Recording conformance of the real routing protocol.
@MainActor
private final class RecordingRouting: NotificationResponseRouting {
    private(set) var keys: [String] = []
    private(set) var links: [BackgroundWorkDeepLink] = []
    private(set) var identifiers: [String] = []
    private(set) var deliveredOnMainThread: [Bool] = []

    func routeNotificationResponse(
        key: String,
        link: BackgroundWorkDeepLink,
        identifier: String
    ) {
        keys.append(key)
        links.append(link)
        identifiers.append(identifier)
        deliveredOnMainThread.append(Thread.isMainThread)
    }
}

/// Thread-safe completion counter.
private final class DeliveryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var mainThreadObservation: [Bool] = []

    func record() {
        lock.lock()
        value += 1
        mainThreadObservation.append(Thread.isMainThread)
        lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    var threads: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return mainThreadObservation
    }
}

@Suite("FloeApp.NotificationResponseBridge", .serialized)
@MainActor
struct NotificationResponseBridgeTests {

    /// The delegate entry the system calls is the completion-handler selector.
    /// Implementing it directly is what keeps the compiler-generated `async`
    /// continuation bridge off this callback path.
    @Test("The coordinator implements the completion-handler delegate selector")
    func delegateSelectorIsExplicit() {
        #expect(BackgroundRunCoordinator.instancesRespond(
            to: NSSelectorFromString(
                "userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:"
            )
        ))
    }

    @Test("A completion handler is delivered exactly once, even under concurrent finishes")
    func completionDeliversExactlyOnce() {
        let counter = DeliveryCounter()
        let completion = NotificationResponseCompletion { counter.record() }
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            _ = completion.finish()
        }
        #expect(counter.count == 1)
        #expect(completion.hasDelivered)
        // A second delivery attempt after the fact is refused, not forwarded.
        #expect(!completion.finish())
        #expect(counter.count == 1)
    }

    @Test("A valid tap routes on the main actor and completes exactly once on the main thread")
    func acceptedTapRoutesAndCompletes() async {
        let routing = RecordingRouting()
        let signal = BridgeSignal()
        let deliveries = DeliveryCounter()
        let conversationID = UUID()
        let runID = UUID()

        NotificationResponseIntake.accept(
            identifier: "floe.tests.accepted",
            payload: [
                "workKind": "modelRun",
                "conversationID": conversationID.uuidString,
                "runID": runID.uuidString
            ],
            completion: {
                deliveries.record()
                signal.fire()
            },
            routing: routing
        )
        await signal.wait()

        #expect(deliveries.count == 1)
        #expect(deliveries.threads == [true])
        #expect(routing.links.count == 1)
        #expect(routing.links.first?.kind == .modelRun)
        #expect(routing.links.first?.conversationID == conversationID)
        #expect(routing.links.first?.runID == runID)
        #expect(routing.identifiers == ["floe.tests.accepted"])
        #expect(routing.deliveredOnMainThread == [true])
        #expect(routing.keys == [
            NotificationResponseIntake.routeKey(
                identifier: "floe.tests.accepted",
                link: BackgroundWorkDeepLink(
                    kind: .modelRun,
                    conversationID: conversationID,
                    runID: runID
                )
            )
        ])
    }

    @Test("A tap handed over from a background thread still routes and completes on the main actor")
    func backgroundThreadHandOff() async {
        let routing = RecordingRouting()
        let signal = BridgeSignal()
        let deliveries = DeliveryCounter()
        let conversationID = UUID()

        Task.detached {
            NotificationResponseIntake.accept(
                identifier: "floe.tests.background",
                payload: [
                    "workKind": "modelRun",
                    "conversationID": conversationID.uuidString
                ],
                completion: {
                    deliveries.record()
                    signal.fire()
                },
                routing: routing
            )
        }
        await signal.wait()

        #expect(deliveries.threads == [true])
        #expect(routing.deliveredOnMainThread == [true])
        #expect(routing.links.first?.conversationID == conversationID)
    }

    @Test("An unparseable payload completes exactly once and never routes")
    func unparseablePayloadStillCompletes() async {
        let routing = RecordingRouting()
        let signal = BridgeSignal()
        let deliveries = DeliveryCounter()

        NotificationResponseIntake.accept(
            identifier: "floe.tests.invalid",
            payload: ["unexpected": "value"],
            completion: {
                deliveries.record()
                signal.fire()
            },
            routing: routing
        )
        await signal.wait()

        #expect(deliveries.count == 1)
        #expect(routing.keys.isEmpty)
    }

    @Test("A released owner completes exactly once and never routes")
    func releasedOwnerStillCompletes() async {
        let signal = BridgeSignal()
        let deliveries = DeliveryCounter()

        NotificationResponseIntake.accept(
            identifier: "floe.tests.released",
            payload: [
                "workKind": "modelRun",
                "conversationID": UUID().uuidString
            ],
            completion: {
                deliveries.record()
                signal.fire()
            },
            routing: nil
        )
        await signal.wait()

        #expect(deliveries.count == 1)
    }

    @Test("Every repeat tap owns its own completion; suppression is the route gate's job")
    func repeatTapsCompleteIndividually() async {
        let routing = RecordingRouting()
        let first = BridgeSignal()
        let second = BridgeSignal()
        let deliveries = DeliveryCounter()
        let payload: [AnyHashable: Any] = [
            "workKind": "modelRun",
            "conversationID": UUID().uuidString
        ]

        NotificationResponseIntake.accept(
            identifier: "floe.tests.repeat",
            payload: payload,
            completion: { deliveries.record(); first.fire() },
            routing: routing
        )
        await first.wait()
        NotificationResponseIntake.accept(
            identifier: "floe.tests.repeat",
            payload: payload,
            completion: { deliveries.record(); second.fire() },
            routing: routing
        )
        await second.wait()

        #expect(deliveries.count == 2)
        #expect(routing.keys.count == 2)
        #expect(routing.keys.first == routing.keys.last)
    }

    @Test("The durable stage trail is fixed, bounded and free of notification content")
    func stageTrailIsContentFree() async {
        let identifier = "floe.tests.trail.\(UUID().uuidString)"
        let conversationID = UUID()
        let signal = BridgeSignal()
        NotificationResponseIntake.accept(
            identifier: identifier,
            payload: [
                "workKind": "modelRun",
                "conversationID": conversationID.uuidString
            ],
            completion: { signal.fire() },
            routing: RecordingRouting()
        )
        await signal.wait()

        let trail = FloeLogger.buffer.recentEntries
            .map(\.message)
            .filter { $0.hasPrefix("notificationResponseStage=") }
        #expect(trail.contains("notificationResponseStage=received"))
        #expect(trail.contains("notificationResponseStage=completionDispatching"))
        #expect(trail.contains("notificationResponseStage=completionDelivered"))
        #expect(!trail.contains(where: { $0.contains(identifier) }))
        #expect(!trail.contains(where: { $0.contains(conversationID.uuidString) }))
        #expect(!trail.contains(where: { $0.count > 80 }))
        let allowed = Set(NotificationResponseStage.allCases.map {
            "notificationResponseStage=\($0.rawValue)"
        })
        #expect(trail.allSatisfy { line in
            allowed.contains(where: { line.hasPrefix($0) })
        })
    }
}
#endif
