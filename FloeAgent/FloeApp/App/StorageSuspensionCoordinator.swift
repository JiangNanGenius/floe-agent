#if canImport(UIKit)
import Foundation
import UIKit
import FloeCore
import FloeDocuments
import FloePersistence

/// Runs a main-actor lifecycle action synchronously when the caller is already
/// on the main thread (UIKit's normal delivery), with a safe queued fallback
/// for an unexpected off-main post. Synchronous delivery is required: a queued
/// Task or main OperationQueue hop can lose the race with suspension before
/// the protection assertion exists or document admission is fenced.
enum StorageMainActorDelivery {
    nonisolated static func perform(_ action: @escaping @MainActor () -> Void) {
        guard Thread.isMainThread else {
            Task { @MainActor in action() }
            return
        }
        MainActor.assumeIsolated { action() }
    }
}

/// Registers process lifecycle observers so a main-thread UIKit notification
/// performs its admission fence and finite assertion request before the
/// notification returns. The center is injectable for a focused
/// synchronous-delivery regression; production uses `.default`.
@MainActor
final class StorageLifecycleObserver {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    func observe(_ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in
            StorageMainActorDelivery.perform { action() }
        })
    }

    func stop() {
        for token in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }
}

/// One process owner, independent of scene focus. Inactive windows do not
/// suspend stores. Actual background/foreground notifications serialize the
/// owners' checkpoint/cancellation work without inventing permanent runtime.
@MainActor
final class StorageSuspensionCoordinator {
    static let shared = StorageSuspensionCoordinator()
    private struct Budget {
        let assertion: UIBackgroundTaskIdentifier
        let lease: StorageOperationLease
        /// The lease already completed while owners were still draining. Its
        /// system assertion must stay held until quiescence, otherwise the
        /// process can suspend before the document/shared owners release
        /// their kernel leases.
        var finishedWhileBackground = false
    }
    private var budgets: [UUID: Budget] = [:]
    private var lifecycle: StorageLifecycleObserver?
    private var transition: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var started = false
    private var isBackground = false
    private var needsForeground = false
    private var quiescenceComplete = false
    private var connectionsSuspended = false
    /// True while the final quiesced lease fences SQLite and drains its
    /// writer before returning the last system assertion. New background
    /// admissions are refused during this handoff so a fresh writer cannot
    /// race the fence; foreground admissions stay allowed.
    private var finalizingHandoffGeneration: UInt64?
    private var finalizingHandoff: Bool {
        StorageSuspensionHandoffOwnership.isCurrent(
            handoffGeneration: finalizingHandoffGeneration,
            currentGeneration: generation
        )
    }
    private weak var sharedDocuments: SharedDocumentsCenter?
    private weak var intake: DocumentIntakeCenter?
    private weak var shareIntake: ShareIntakeCenter?
    private weak var destinations: ImportDestinationCenter?

    /// Start before bootstrap opens/migrates stores; configure real owners
    /// afterwards. Packages/extensions keep the same APIs without UIKit.
    func start() {
        guard !started else { return }
        started = true
        isBackground = UIApplication.shared.applicationState == .background
        StorageOperationBudget.install { try await StorageSuspensionCoordinator.shared.beginOperation() }
        let lifecycle = StorageLifecycleObserver(center: .default)
        lifecycle.observe(UIApplication.didEnterBackgroundNotification) { [weak self] in
            self?.enterBackground()
        }
        lifecycle.observe(UIApplication.willEnterForegroundNotification) { [weak self] in
            self?.enterForeground()
        }
        self.lifecycle = lifecycle
        if isBackground { enterBackground() }
    }

    func configure(
        sharedDocuments: SharedDocumentsCenter,
        intake: DocumentIntakeCenter,
        shareIntake: ShareIntakeCenter,
        destinations: ImportDestinationCenter
    ) {
        self.sharedDocuments = sharedDocuments
        self.intake = intake
        self.shareIntake = shareIntake
        self.destinations = destinations
        if isBackground { enterBackground() }
    }

    /// Only the native notification-response ingress calls this. A new OS
    /// callback can provide a fresh finite execution opportunity after an old
    /// assertion expired; a saved setting or model argument cannot do so.
    func beginNotificationResponseOperation() throws -> StorageOperationLease {
        try beginOperation(authorizedSystemCallback: true)
    }

    private func beginOperation(authorizedSystemCallback: Bool = false) throws -> StorageOperationLease {
        let backgroundNow = isBackground || UIApplication.shared.applicationState == .background
        guard StorageSuspensionAdmission.permitsOperation(
            backgroundNow: backgroundNow,
            needsForeground: needsForeground,
            finalizingHandoff: finalizingHandoff,
            authorizedSystemCallback: authorizedSystemCallback
        ) else { throw CancellationError() }
        let id = UUID()
        let lease = StorageOperationLease { [weak self] in
            Task { @MainActor in self?.finishOperation(id) }
        }
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "Floe storage operation") { [weak self] in
            // UIKit documents this handler as @MainActor. Run the fence and
            // SQL interrupt synchronously before returning the expired
            // assertion; a Task hop can be suspended with the lock still held.
            self?.expireOperation(id)
        }
        if assertion == .invalid && backgroundNow {
            lease.finish()
            throw CancellationError()
        }
        budgets[id] = Budget(assertion: assertion, lease: lease)
        if authorizedSystemCallback { needsForeground = false }
        // A legitimate finite background write may reopen the SQLite writer;
        // its last lease suspends it again after quiescence. No VM/keepalive.
        if connectionsSuspended {
            DatabaseManager.resumeConnections()
            connectionsSuspended = false
        }
        return lease
    }

    private func finishOperation(_ id: UUID) {
        guard let budget = budgets[id] else { return }
        switch StorageSuspensionLeaseExit.decide(
            isBackground: isBackground,
            quiescenceComplete: quiescenceComplete,
            leaseCount: budgets.count,
            connectionsSuspended: connectionsSuspended,
            finalizingHandoff: finalizingHandoff
        ) {
        case .endNow:
            budgets.removeValue(forKey: id)
            if budget.assertion != .invalid { UIApplication.shared.endBackgroundTask(budget.assertion) }
            // A newer background transition can add a protection budget while
            // an earlier lease is deferred. Once that protection lease ends,
            // the deferred lease is the last one and must run its handoff.
            finalizeDeferredFinishedBudgetIfNeeded()
            suspendConnectionsIfIdle()
            return
        case .deferUntilQuiescence:
            // Owners are still draining. Keep this last assertion; the
            // background transition's quiescence step will run the final
            // handoff. Ending it here would make the process suspend while a
            // document/shared writer may still own a kernel lease.
            if var deferred = budgets[id] {
                deferred.finishedWhileBackground = true
                budgets[id] = deferred
            }
            return
        case .fenceThenEnd:
            break
        }
        // Do not give back the last execution assertion before SQLite is
        // fenced. GRDB's suspension notification only sets a flag and
        // interrupts; the lock-owning transaction unwinds later on the writer
        // queue. Keep the budget registered while draining so its expiration
        // handler can still return the assertion if the drain outlives it.
        let expected = generation
        finalizingHandoffGeneration = expected
        Task { @MainActor [weak self] in
            guard let self else { return }
            await StorageBackgroundAssertionHandoff.finish(
                fence: {
                    // A foreground/background transition may have won the
                    // race between scheduling and running this handoff. Only
                    // the generation that requested it may fence the pool.
                    guard StorageSuspensionHandoffOwnership.mayFence(
                        isBackground: self.isBackground,
                        startedGeneration: expected,
                        currentGeneration: self.generation
                    ) else { return }
                    // Post and record the suspension synchronously before the
                    // first await, then join the writer queues. A queued
                    // foreground admission that resumes the pool in between
                    // is corrected by beginOperation itself.
                    DatabaseManager.suspendConnections()
                    self.connectionsSuspended = true
                    await DatabaseManager.drainWriterQueues()
                    await NotesRepository.shared.drainWriterForSuspension()
                },
                endAssertion: {
                    // An older drain must neither block a newer background
                    // generation's protection request nor clear its handoff.
                    if self.finalizingHandoffGeneration == expected {
                        self.finalizingHandoffGeneration = nil
                    }
                    // Revalidate actual ownership after the await. If a newer
                    // background generation now owns the lifecycle but this
                    // stale handoff never fenced it, do not end the assertion
                    // unprotected: re-evaluate under the current state.
                    if self.isBackground, self.budgets[id] != nil,
                       !self.connectionsSuspended {
                        if self.quiescenceComplete {
                            self.finishOperation(id)
                        } else if var deferred = self.budgets[id] {
                            deferred.finishedWhileBackground = true
                            self.budgets[id] = deferred
                        }
                        return
                    }
                    // Foreground must never be left with a suspended pool.
                    if !self.isBackground {
                        DatabaseManager.resumeConnections()
                        self.connectionsSuspended = false
                    }
                    // expireOperation may already have removed the budget and
                    // returned this assertion; only the still-registered owner
                    // may end it (ending twice is not valid).
                    if self.budgets.removeValue(forKey: id) != nil,
                       budget.assertion != .invalid {
                        UIApplication.shared.endBackgroundTask(budget.assertion)
                    }
                    self.suspendConnectionsIfIdle()
                }
            )
        }
    }

    private func expireOperation(_ id: UUID) {
        guard let budget = budgets.removeValue(forKey: id) else { return }
        budget.lease.expire()
        if isBackground || UIApplication.shared.applicationState == .background {
            needsForeground = true
            // Synchronously fence admission/cancel actual owners and interrupt
            // SQL BEFORE returning the expired system assertion. File handles
            // close only after their owner drains; never force-unlock I/O.
            requestOwnerSuspension()
            DatabaseManager.suspendConnections()
            connectionsSuspended = true
            enterBackground()
        }
        if budget.assertion != .invalid { UIApplication.shared.endBackgroundTask(budget.assertion) }
    }

    private func enterBackground() {
        isBackground = true
        requestOwnerSuspension()
        quiescenceComplete = false
        generation &+= 1
        let expected = generation
        let previous = transition
        let protection = try? beginOperation()
        transition = Task { [weak self] in
            defer { protection?.finish() }
            await previous?.value
            guard let self, self.isBackground, self.generation == expected else { return }
            async let documents: Void = SecurityScopedDocumentWorkspace.suspendAllForBackground()
            async let shared: Void = self.sharedDocuments?.suspendStorageForBackground() ?? ()
            async let intake: Void = self.intake?.suspendForBackground() ?? ()
            async let share: Void = self.shareIntake?.suspendForBackground() ?? ()
            async let destinations: Void = self.destinations?.suspendForBackground() ?? ()
            _ = await (documents, shared, intake, share, destinations)
            guard self.isBackground, self.generation == expected else { return }
            self.quiescenceComplete = true
            self.finalizeDeferredFinishedBudgetIfNeeded()
            self.suspendConnectionsIfIdle()
        }
    }

    private func enterForeground() {
        isBackground = false
        needsForeground = false
        quiescenceComplete = false
        generation &+= 1
        let expected = generation
        // Resume the pool before returning any deferred assertion: ending the
        // last background task first can make the process suspend with the
        // pool still fenced.
        DatabaseManager.resumeConnections()
        connectionsSuspended = false
        endDeferredFinishedBudgets()
        let previous = transition
        transition = Task { [weak self] in
            await previous?.value
            guard let self, !self.isBackground, self.generation == expected else { return }
            let conflicts = await SecurityScopedDocumentWorkspace.resumeAllAfterSuspension()
            guard !self.isBackground, self.generation == expected else { return }
            await self.sharedDocuments?.resumeStorageAfterSuspension()
            await self.intake?.resumeAfterSuspension()
            await self.shareIntake?.resumeAfterSuspension()
            await self.destinations?.resumeAfterSuspension()
            if conflicts > 0 {
                FloeLogger(category: .app).info("documentOwnershipChangedAfterSuspension count=\(conflicts)")
            }
        }
    }

    /// Runs the final handoff for the lease that completed while owners were
    /// still draining. Only the last budget can be deferred, so quiescence
    /// makes it the final quiesced lease.
    private func finalizeDeferredFinishedBudgetIfNeeded() {
        guard isBackground, quiescenceComplete, !finalizingHandoff, budgets.count == 1,
              let id = budgets.first(where: { $0.value.finishedWhileBackground })?.key
        else { return }
        finishOperation(id)
    }

    /// Foreground work resumed before the background transition reached
    /// quiescence. The deferred lease no longer needs to protect a suspension
    /// window; return its assertion without touching storage ownership.
    private func endDeferredFinishedBudgets() {
        for (id, budget) in Array(budgets) where budget.finishedWhileBackground {
            budgets.removeValue(forKey: id)
            if budget.assertion != .invalid { UIApplication.shared.endBackgroundTask(budget.assertion) }
        }
    }

    private func suspendConnectionsIfIdle() {
        guard isBackground, quiescenceComplete, budgets.isEmpty, !connectionsSuspended else { return }
        DatabaseManager.suspendConnections()
        connectionsSuspended = true
    }

    private func requestOwnerSuspension() {
        SecurityScopedDocumentWorkspace.requestBackgroundSuspension()
        intake?.beginStorageSuspension()
        shareIntake?.beginStorageSuspension()
        destinations?.beginStorageSuspension()
    }
}
#endif
