#if canImport(UIKit)
import Foundation
import UIKit
import FloeCore
import FloeDocuments
import FloePersistence

/// One process owner, independent of scene focus. Inactive windows do not
/// suspend stores. Actual background/foreground notifications serialize the
/// owners' checkpoint/cancellation work without inventing permanent runtime.
@MainActor
final class StorageSuspensionCoordinator {
    static let shared = StorageSuspensionCoordinator()
    private struct Budget {
        let assertion: UIBackgroundTaskIdentifier
        let lease: StorageOperationLease
    }
    private var budgets: [UUID: Budget] = [:]
    private var observers: [NSObjectProtocol] = []
    private var transition: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var started = false
    private var isBackground = false
    private var needsForeground = false
    private var quiescenceComplete = false
    private var connectionsSuspended = false
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
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.enterBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.enterForeground() }
        })
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

    private func beginOperation() throws -> StorageOperationLease {
        let backgroundNow = isBackground || UIApplication.shared.applicationState == .background
        if backgroundNow && needsForeground { throw CancellationError() }
        let id = UUID()
        let lease = StorageOperationLease { [weak self] in
            Task { @MainActor in self?.finishOperation(id) }
        }
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "Floe storage operation") { [weak self] in
            Task { @MainActor in self?.expireOperation(id) }
        }
        if assertion == .invalid && backgroundNow {
            lease.finish()
            throw CancellationError()
        }
        budgets[id] = Budget(assertion: assertion, lease: lease)
        // A legitimate finite background write may reopen the SQLite writer;
        // its last lease suspends it again after quiescence. No VM/keepalive.
        if connectionsSuspended {
            DatabaseManager.resumeConnections()
            connectionsSuspended = false
        }
        return lease
    }

    private func finishOperation(_ id: UUID) {
        guard let budget = budgets.removeValue(forKey: id) else { return }
        if budget.assertion != .invalid { UIApplication.shared.endBackgroundTask(budget.assertion) }
        suspendConnectionsIfIdle()
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
            self.suspendConnectionsIfIdle()
        }
    }

    private func enterForeground() {
        isBackground = false
        needsForeground = false
        quiescenceComplete = false
        generation &+= 1
        let expected = generation
        DatabaseManager.resumeConnections()
        connectionsSuspended = false
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
