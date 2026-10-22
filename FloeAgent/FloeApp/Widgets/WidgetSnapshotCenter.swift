// FloeApp — Widget snapshot owner.
//
// AppEnvironment owns one center. It observes the live conversation/run
// projections and refreshes the App Group snapshot on real changes: a run
// starts or changes state, a title changes, a conversation is deleted, a
// temporary session starts/ends, or the App returns to the foreground.
// There is no background timer and no synthetic "running" state.
//
// Refresh coalescing: one drain task is in flight at a time. A change that
// arrives while a write is in flight sets `refreshRequested`; the loop runs
// again with the latest actual state. A deletion therefore cannot be lost
// behind an older write.

import Foundation
import Combine
import UIKit
import WidgetKit
import FloeCore
import FloePersistence

@MainActor
final class WidgetSnapshotCenter: ObservableObject {
    enum RefreshReason: String, Sendable {
        case launch
        case foreground
        case runState
        case conversationList
        case temporarySession
        case external
    }

    /// Last persistence failure. A successful publish clears it; a failed
    /// publish leaves the previous valid file in place and never reports a
    /// new `lastPublishedAt`.
    @Published private(set) var lastError: WidgetSnapshotPublishFailure?
    @Published private(set) var lastPublishedAt: Date?
    @Published private(set) var isPublishing = false

    private let publisher: any WidgetSnapshotPublishing
    private let observesAppActivation: Bool
    private let reloadWidgets: @MainActor () -> Void
    private weak var conversationCenter: ConversationCenter?
    private var cancellables: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    private var refreshRequested = false
    private var drainGeneration: UInt64 = 0

    init(
        publisher: any WidgetSnapshotPublishing,
        observesAppActivation: Bool = true,
        reloadWidgets: (@MainActor () -> Void)? = nil
    ) {
        let defaultReload: @MainActor () -> Void = {
            WidgetCenter.shared.reloadAllTimelines()
        }
        self.publisher = publisher
        self.observesAppActivation = observesAppActivation
        self.reloadWidgets = reloadWidgets ?? defaultReload
    }

    convenience init(
        runStore: any RunStore,
        conversationStore: any ConversationStore,
        store: WidgetTaskSnapshotStore?
    ) {
        self.init(
            publisher: WidgetSnapshotProducer(
                store: store.map { $0 as any WidgetSnapshotStoring },
                runSource: RunStoreWidgetSnapshotSource(store: runStore),
                conversationSource: ConversationStoreWidgetSnapshotSource(store: conversationStore)
            )
        )
    }

    /// Idempotent launch hook. Observes only already-published projections;
    /// it does not reload stores or start any task.
    func start(observing center: ConversationCenter) {
        guard conversationCenter == nil else { return }
        conversationCenter = center

        center.$activeRuns
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshNow(reason: .runState)
                }
            }
            .store(in: &cancellables)

        center.$conversations
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshNow(reason: .conversationList)
                }
            }
            .store(in: &cancellables)

        center.$temporarySession
            .dropFirst()
            .map { $0?.incarnation }
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshNow(reason: .temporarySession)
                }
            }
            .store(in: &cancellables)

        if observesAppActivation {
            NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification
            )
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshNow(reason: .foreground)
                }
            }
            .store(in: &cancellables)
        }

        refreshNow(reason: .launch)
    }

    /// Explicit hook for the primary integration (cold launch ready, run
    /// terminal events, rename/delete completion). Safe to call repeatedly.
    func refreshNow(reason: RefreshReason = .external) {
        refreshRequested = true
        guard refreshTask == nil else { return }
        drainGeneration &+= 1
        let generation = drainGeneration

        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.refreshRequested, !Task.isCancelled, self.drainGeneration == generation {
                self.refreshRequested = false
                self.isPublishing = true
                let excluded = self.excludedConversationIDs
                let outcome = await self.publisher.publish(
                    now: Date(),
                    excludingConversationIDs: excluded
                )
                guard !Task.isCancelled, self.drainGeneration == generation else { break }
                self.apply(outcome, reason: reason)
            }
            guard self.drainGeneration == generation else { return }
            self.isPublishing = false
            self.refreshTask = nil
        }
    }

    @discardableResult
    func stop() -> Task<Void, Never>? {
        let stopped = refreshTask
        drainGeneration &+= 1
        refreshRequested = false
        refreshTask?.cancel()
        refreshTask = nil
        isPublishing = false
        cancellables.removeAll()
        conversationCenter = nil
        return stopped
    }

    /// Test seam: awaits the current drain task, including a second pass
    /// requested while the first write was in flight.
    func waitForIdleForTesting() async {
        while let task = refreshTask {
            await task.value
        }
    }

    private var excludedConversationIDs: Set<UUID> {
        guard let session = conversationCenter?.temporarySession else { return [] }
        return [session.conversation.id]
    }

    private func apply(
        _ outcome: WidgetSnapshotPublishOutcome,
        reason: RefreshReason
    ) {
        switch outcome {
        case .cancelled:
            break
        case .published(let result):
            lastError = nil
            lastPublishedAt = result.publishedAt
            // WidgetKit rate-limits reloads; this is a request, not a
            // promise that the system redraws immediately.
            reloadWidgets()
        case .failed(let failure):
            lastError = failure
            FloeLogger(category: .app).warning(
                "widgetSnapshotPublishFailed reason=\(reason.rawValue) kind=\(failure.logKind)"
            )
        }
    }
}
