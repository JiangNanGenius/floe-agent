// FloeAppTests — notification tap routing through the real bridge.
//
// These regressions drive the real `NotificationResponseIntake` with the real
// `BackgroundRunCoordinator` conformance (the production `routing:` target of
// the delegate bridge) and the real `AppEnvironment`, so the duplicate
// suppression, cold-launch deferral, generation ownership and authoritative
// target lookup all run exactly as they do for a system notification tap:
//
//   * a tap that arrives during a cold launch is deferred, keeps its own
//     conversation, and routes once the database, an active scene and the
//     mounted root-view subscribers are ready (`handleScenePhase` +
//     `reconcileSchedulesAfterLaunch`, both production entry points);
//   * repeat taps of the same alert route once while every tap still completes;
//   * two taps for different conversations never cross-route;
//   * a newer tap supersedes a deferred route instead of letting it replay;
//   * a tap whose target is gone answers honestly (banner, no dead route) and
//     never claims a delivery that did not happen;
//   * the completion handler is delivered before the route's asynchronous
//     reload/target work, never held across it.
//
// Build 271 context and the honest limits of this suite are recorded in
// `Local/Private/capability-closure-20261014/crash/CRASH-271-SYMBOLICATED.md`
// and `INTEGRATION-NOTIFICATION.md`: no window scene exists in this bundle, so
// the App-hosted regressions pin the environment-owned persistence fact
// (DEBUG-only coordinator seam) while the scene phase and the mounted
// subscribers still come from the real API. Physical-device notification-tap
// acceptance stays with the full-App qualification owner.

#if canImport(SwiftUI) && canImport(UIKit) && DEBUG
import Foundation
import Testing
import SwiftUI
import UIKit
import UserNotifications
import FloePersistence
@testable import FloeApp

/// One-shot awaitable signal that can be fired from any thread.
private final class RouteSignal: @unchecked Sendable {
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

/// Thread-safe completion counter.
private final class TapCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Real deep-link subscribers: observes the two production navigation
/// notifications the coordinator posts.
private final class RouteCapture: @unchecked Sendable {
    struct Routed: Sendable, Equatable {
        var channel: String
        var conversationID: UUID?
        var workKind: String?
        var environmentID: String?
    }

    private let lock = NSLock()
    private var events: [Routed] = []
    private var tokens: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(
            forName: .floeOpenConversation, object: nil, queue: nil
        ) { [weak self] note in
            self?.append(Routed(
                channel: "conversation",
                conversationID: note.userInfo?["conversationID"] as? UUID,
                workKind: nil,
                environmentID: nil
            ))
        })
        tokens.append(center.addObserver(
            forName: .floeOpenExecutionEnvironment, object: nil, queue: nil
        ) { [weak self] note in
            self?.append(Routed(
                channel: "environment",
                conversationID: nil,
                workKind: note.userInfo?["workKind"] as? String,
                environmentID: note.userInfo?["environmentID"] as? String
            ))
        })
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    private func append(_ event: Routed) {
        lock.lock(); events.append(event); lock.unlock()
    }

    var routes: [Routed] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    var count: Int { routes.count }
}

/// Ordered evidence of when the completion ran relative to navigation.
private final class OrderTrail: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func record(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return events }
}

@Suite("FloeApp.BackgroundWorkNotificationRoute", .serialized)
@MainActor
struct BackgroundWorkNotificationRouteTests {

    private func makeEnvironment() async throws -> AppEnvironment {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        return environment
    }

    @discardableResult
    private func saveConversation(
        _ environment: AppEnvironment,
        title: String
    ) async throws -> UUID {
        let conversationID = UUID()
        try await environment.conversationStore.saveConversation(ConversationRecord(
            id: conversationID,
            title: title,
            createdAt: Date(),
            updatedAt: Date()
        ))
        return conversationID
    }

    private func modelRunPayload(conversationID: UUID) -> [AnyHashable: Any] {
        [
            "workKind": "modelRun",
            "conversationID": conversationID.uuidString,
            "runID": UUID().uuidString
        ]
    }

    /// The real readiness boundary of the app. The App-hosted bundle has no
    /// window scene, so only the environment-owned persistence fact is pinned
    /// (DEBUG-only seam); the active scene and the mounted root-view
    /// subscribers come from the production `handleScenePhase` /
    /// `reconcileSchedulesAfterLaunch` entry points.
    private func becomeReady(
        coordinator: BackgroundRunCoordinator,
        sceneID: String = "notification-route-tests"
    ) async {
        coordinator.setNotificationRoutePersistenceOverrideForTesting(true)
        coordinator.handleScenePhase(.active, sceneID: sceneID)
        await coordinator.reconcileSchedulesAfterLaunch()
    }

    private func waitForRoutes(_ capture: RouteCapture, count: Int) async {
        let deadline = Date().addingTimeInterval(8)
        while capture.count < count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    @Test("A tap that launches the app defers, then opens its own conversation")
    func coldLaunchDefersThenRoutes() async throws {
        let environment = try await makeEnvironment()
        let coordinator = environment.backgroundRunCoordinator
        let capture = RouteCapture()
        let conversationID = try await saveConversation(environment, title: "Cold launch target")
        let signal = RouteSignal()
        let taps = TapCounter()

        NotificationResponseIntake.accept(
            identifier: "floe.tests.cold",
            payload: modelRunPayload(conversationID: conversationID),
            completion: { taps.record(); signal.fire() },
            routing: coordinator
        )
        await signal.wait()
        #expect(taps.count == 1)
        #expect(capture.count == 0, "a cold tap must not navigate before the app is ready")

        await becomeReady(coordinator: coordinator)
        await waitForRoutes(capture, count: 1)
        #expect(capture.count == 1)
        #expect(capture.routes.first?.channel == "conversation")
        #expect(capture.routes.first?.conversationID == conversationID)
    }

    @Test("Repeat taps of one alert route once while every tap completes")
    func duplicateTapsRouteOnce() async throws {
        let environment = try await makeEnvironment()
        let coordinator = environment.backgroundRunCoordinator
        await becomeReady(coordinator: coordinator)
        let capture = RouteCapture()
        let conversationID = try await saveConversation(environment, title: "Repeat target")
        let taps = TapCounter()

        // The same alert, tapped twice: identical identifier and payload
        // produce the same dedup key, which is exactly how the system
        // redelivers an already-presented notification response.
        let payload = modelRunPayload(conversationID: conversationID)
        for _ in 0..<2 {
            let signal = RouteSignal()
            NotificationResponseIntake.accept(
                identifier: "floe.tests.repeat",
                payload: payload,
                completion: { taps.record(); signal.fire() },
                routing: coordinator
            )
            await signal.wait()
        }
        await waitForRoutes(capture, count: 1)
        await settle()
        #expect(taps.count == 2, "every tap owns a completion")
        #expect(capture.count == 1, "the duplicate window suppresses the second navigation")
        #expect(capture.routes.first?.conversationID == conversationID)
    }

    @Test("Two taps for different conversations never cross-route")
    func distinctConversationsRouteIndependently() async throws {
        let environment = try await makeEnvironment()
        let coordinator = environment.backgroundRunCoordinator
        await becomeReady(coordinator: coordinator)
        let capture = RouteCapture()
        let first = try await saveConversation(environment, title: "First target")
        let second = try await saveConversation(environment, title: "Second target")

        // Sequential isolation: each tap must have ROUTED before the next one
        // arrives, so this test measures per-target isolation instead of the
        // documented latest-tap supersession (which has its own regression
        // below and intentionally drops a superseded deferred tap).
        for (index, conversationID) in [first, second].enumerated() {
            let signal = RouteSignal()
            NotificationResponseIntake.accept(
                identifier: "floe.tests.distinct.\(index)",
                payload: modelRunPayload(conversationID: conversationID),
                completion: { signal.fire() },
                routing: coordinator
            )
            await signal.wait()
            await waitForRoutes(capture, count: index + 1)
        }
        #expect(capture.count == 2)
        #expect(Set(capture.routes.compactMap(\.conversationID)) == [first, second])
        #expect(capture.routes.allSatisfy { $0.channel == "conversation" })
    }

    @Test("A newer tap supersedes a deferred route instead of replaying it")
    func newerTapSupersedesDeferredRoute() async throws {
        let environment = try await makeEnvironment()
        let coordinator = environment.backgroundRunCoordinator
        let capture = RouteCapture()
        let first = try await saveConversation(environment, title: "Older target")
        let second = try await saveConversation(environment, title: "Newer target")

        for (index, conversationID) in [first, second].enumerated() {
            let signal = RouteSignal()
            NotificationResponseIntake.accept(
                identifier: "floe.tests.supersede.\(index)",
                payload: modelRunPayload(conversationID: conversationID),
                completion: { signal.fire() },
                routing: coordinator
            )
            await signal.wait()
        }
        await becomeReady(coordinator: coordinator)
        await waitForRoutes(capture, count: 1)
        await settle()
        #expect(capture.count == 1, "only the newest deferred tap may route")
        #expect(capture.routes.first?.conversationID == second)
    }

    @Test("A tap for a deleted task answers honestly and claims no delivery")
    func missingTargetNeverClaimsDelivery() async throws {
        let environment = try await makeEnvironment()
        let coordinator = environment.backgroundRunCoordinator
        await becomeReady(coordinator: coordinator)
        let capture = RouteCapture()
        let taps = TapCounter()
        TaskBannerCenter.shared.dismiss()

        let signal = RouteSignal()
        NotificationResponseIntake.accept(
            identifier: "floe.tests.missing",
            payload: modelRunPayload(conversationID: UUID()),
            completion: { taps.record(); signal.fire() },
            routing: coordinator
        )
        await signal.wait()
        await settle()

        #expect(taps.count == 1)
        #expect(capture.count == 0, "a deleted target must not open a dead conversation")
        #expect(TaskBannerCenter.shared.banner != nil, "the user is told why the tap cannot open")
        TaskBannerCenter.shared.dismiss()
    }

    @Test("The completion is delivered before the route's asynchronous work starts")
    func completionPrecedesRouteWork() async throws {
        let environment = try await makeEnvironment()
        let coordinator = environment.backgroundRunCoordinator
        await becomeReady(coordinator: coordinator)
        let conversationID = try await saveConversation(environment, title: "Order target")
        let trail = OrderTrail()
        let capture = RouteCapture()
        let signal = RouteSignal()
        let observation = NotificationCenter.default.addObserver(
            forName: .floeOpenConversation, object: nil, queue: nil
        ) { _ in trail.record("route") }
        defer { NotificationCenter.default.removeObserver(observation) }

        NotificationResponseIntake.accept(
            identifier: "floe.tests.order",
            payload: modelRunPayload(conversationID: conversationID),
            completion: { trail.record("completion"); signal.fire() },
            routing: coordinator
        )
        await signal.wait()
        await waitForRoutes(capture, count: 1)
        // Navigation is posted synchronously by the production observer; the
        // order therefore proves the completion returned before the route's
        // reload/target-resolution work posted the deep link.
        #expect(trail.values == ["completion", "route"])
        #expect(capture.count == 1)
    }
}
#endif
