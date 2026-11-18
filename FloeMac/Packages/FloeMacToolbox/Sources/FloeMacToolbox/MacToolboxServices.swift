import AppKit
import Combine
import Foundation
import FloeToolboxUtilities
import FloeToolboxWorkbenches
import FloeMacMediaSystem
import FloeMacInstruments
import FloeMacNetwork

public enum MacScannerTerminationStatus: Equatable { case ready, pending, draft }

/// App-owned service graph for the Mac toolbox. One instance is created by
/// the host and shared by its auxiliary toolbox window, so calculator history
/// and timers survive closing that window. The default root matches the
/// existing Floe toolbox storage and can be redirected for isolated tests.
@MainActor
public final class MacToolboxServices: ObservableObject {
    public let storageRoot: URL
    let calculatorHistoryCoordinator: MacCalculatorHistoryCoordinator
    public let timekeeping: ToolboxTimekeepingService
    public let notifications: MacTimerNotificationController
    public let reminderBridge: ToolboxTimerReminderBridge
    public let mediaEnvironment: MacToolboxMediaEnvironment
    public let instrumentActivity: MacInstrumentActivityCoordinator
    public let networkOwner: MacManualNetworkOwner
    let instrumentModels: MacInstrumentModels
    private var ownedSilentTimekeeping: MacSilentTimekeeping?
    private enum TerminationState { case active, preparing, terminal }
    private var terminationState: TerminationState = .active
    private let silentTimers: MacSilentTimerCoordinator
    private let startup = MacToolboxStartupGate()
    private var lifecycleObservers = Set<AnyCancellable>()

    public init(storageRoot: URL? = nil,
                notificationGateway: (any MacUserNotificationGateway)? = nil,
                mediaEnvironment: MacToolboxMediaEnvironment? = nil) {
        let root = storageRoot ?? Self.defaultStorageRoot()
        self.mediaEnvironment = mediaEnvironment ?? .shared
        self.storageRoot = root
        let instrumentActivity = MacInstrumentActivityCoordinator()
        let locationArchive = ToolboxLocationArchive(url: root.appendingPathComponent("MacInstruments/locations.json"))
        let rulerStore = MacRulerCalibrationStore(url: root.appendingPathComponent("MacInstruments/ruler.json"))
        self.instrumentActivity = instrumentActivity
        self.networkOwner = MacManualNetworkOwner()
        self.instrumentModels = MacInstrumentModels(activity: instrumentActivity, archive: locationArchive, rulerStore: rulerStore)
        self.calculatorHistoryCoordinator = MacCalculatorHistoryCoordinator(
            baseURL: root.appendingPathComponent("Everyday/CalculatorHistory.json")
        )
        let timekeeping = ToolboxTimekeepingService(
            store: ToolboxTimekeepingStore(url: root.appendingPathComponent("Timekeeping/state.json"))
        )
        self.timekeeping = timekeeping
        self.silentTimers = MacSilentTimerCoordinator(service: timekeeping)
        let notifications = MacTimerNotificationController(
            gateway: notificationGateway ?? MacSystemNotificationGateway()
        )
        self.notifications = notifications
        self.reminderBridge = notifications.reminderBridge
    }

    public static func defaultStorageRoot() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return root.appendingPathComponent("FloeToolbox", isDirectory: true)
    }

    func silentTimekeeping() -> MacSilentTimekeeping {
        if let ownedSilentTimekeeping { return ownedSilentTimekeeping }
        let store = MacSilentClockStore(root: storageRoot.appendingPathComponent("MacTimekeeping", isDirectory: true))
        let service = MacSilentTimekeeping(store: store)
        if terminationState != .active { service.closeAdmissions() }
        ownedSilentTimekeeping = service
        return service
    }

    /// Timer startup remains disabled until the shared timekeeping service
    /// supports cancellation and shutdown of its own in-flight load, store
    /// writes, reminder pruning, and reconciliation. Other toolbox tools do
    /// not need timer startup. The gate permanently fences late callers.
    public func start() async {
        await startup.start(prepare: {}, load: {}, activate: {})
    }

    /// Shutdown is terminal even when no start task has run yet.
    public func shutdown() {
        terminationState = .terminal
        ownedSilentTimekeeping?.closeAdmissions()
        networkOwner.closeAdmissions()
        instrumentActivity.closeAdmissions()
        mediaEnvironment.soundOwner.shutdown()
        mediaEnvironment.scannerDraft.shutdown()
        mediaEnvironment.cameraRegistry.commitTermination()
        startup.shutdown()
        silentTimers.stop()
        lifecycleObservers.removeAll()
    }

    public func closeAdmissionsForTermination() {
        guard terminationState == .active else { return }
        terminationState = .preparing
        ownedSilentTimekeeping?.closeAdmissions()
        networkOwner.closeAdmissions()
        instrumentActivity.closeAdmissions()
        calculatorHistoryCoordinator.closeAdmissions()
        mediaEnvironment.soundOwner.beginTermination()
        mediaEnvironment.scannerDraft.beginTermination()
        _ = mediaEnvironment.cameraRegistry.beginTerminationPreparation()
    }

    public func drainForTermination() async -> Bool {
        guard await drainNonScannerForTermination() else { return false }
        return await mediaEnvironment.scannerDraft.drain()
    }

    /// Kept separate so an unsaved scan can receive a specific user choice
    /// without treating another toolbox failure as permission to discard it.
    public func drainNonScannerForTermination() async -> Bool {
        guard await calculatorHistoryCoordinator.drain() else { return false }
        guard await instrumentActivity.drain() else { return false }
        guard await networkOwner.drain() else { return false }
        guard await mediaEnvironment.soundOwner.drain() else { return false }
        if let ownedSilentTimekeeping { return await ownedSilentTimekeeping.drain() }
        return true
    }

    public func drainCameraForTermination() async -> Bool { await mediaEnvironment.cameraRegistry.waitForAllStopped() }

    public func scannerTerminationStatus() async -> MacScannerTerminationStatus {
        let draft = mediaEnvironment.scannerDraft
        if await draft.drain() { return .ready }
        if draft.hasPendingWork { return .pending }
        return draft.hasDraft ? .draft : .pending
    }

    public func discardScannerDraftForTermination() async -> Bool {
        let draft = mediaEnvironment.scannerDraft
        guard draft.allowExitDiscardingDraft() else { return false }
        return await draft.drain()
    }

    public func resumeAfterCancelledTermination() {
        guard terminationState == .preparing else { return }
        terminationState = .active
        ownedSilentTimekeeping?.resumeAfterCancelledTermination()
        networkOwner.resumeAfterCancelledTermination()
        instrumentActivity.resumeAfterCancelledTermination()
        mediaEnvironment.soundOwner.cancelTermination()
        mediaEnvironment.scannerDraft.cancelTermination()
        mediaEnvironment.cameraRegistry.cancelTerminationPreparation()
        calculatorHistoryCoordinator.resumeAfterCancelledTermination()
    }

    private func observeLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.silentTimers.wake() }
            }
            .store(in: &lifecycleObservers)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.silentTimers.wake() }
            }
            .store(in: &lifecycleObservers)
    }
}
