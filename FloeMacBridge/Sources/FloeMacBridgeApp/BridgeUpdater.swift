#if os(macOS)
import AppKit
import Combine
import Foundation
import Sparkle

/// Exact Objective-C selectors are pinned to Sparkle 2.10.1 public headers.
/// This delegate can be contract-tested without starting an updater or UI.
@MainActor
final class BridgeUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    let installation: BridgeUpdateInstallation
    var failed: (() -> Void)?
    init(installation: BridgeUpdateInstallation) { self.installation = installation }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock handler: @escaping () -> Void) -> Bool {
        installation.postpone(handler); return true
    }
    // Automatic downloads can be staged for installation on quit without the
    // relaunch callback. Own that standard path too, using the same admission.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock handler: @escaping () -> Void) -> Bool {
        installation.postpone(handler); return true
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        installation.abort(); failed?()
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor check: SPUUpdateCheck, error: Error?) {
        // A successful cycle may have handed off to an installer. It must not
        // reopen admission in the gap before the process actually terminates.
        if error != nil { installation.abort() }
    }
}

@MainActor
final class BridgeUpdaterModel: ObservableObject {
    let installation: BridgeUpdateInstallation
    private let delegate: BridgeUpdaterDelegate
    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    private var started = false
    @Published private(set) var failed = false

    init(activity: BridgeUpdateActivity) {
        let installation = BridgeUpdateInstallation(activity: activity)
        self.installation = installation
        self.delegate = BridgeUpdaterDelegate(installation: installation)
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
        installation.stateChanged = { [weak self] in self?.objectWillChange.send() }
        delegate.failed = { [weak self] in self?.failed = true }
        let updater = controller.updater
        func observe<Value>(_ keyPath: KeyPath<SPUUpdater, Value>) -> NSKeyValueObservation {
            updater.observe(keyPath, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.objectWillChange.send() }
            }
        }
        observations = [observe(\.canCheckForUpdates), observe(\.automaticallyChecksForUpdates),
                        observe(\.automaticallyDownloadsUpdates), observe(\.allowsAutomaticUpdates)]
    }
    var updater: SPUUpdater { controller.updater }
    var canCheckForUpdates: Bool { started && updater.canCheckForUpdates }
    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticallyDownloads: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }
    var allowsAutomaticDownloads: Bool { updater.allowsAutomaticUpdates }
    func start() {
        guard !started else { return }
        do { try updater.start(); started = true }
        catch { failed = true }
        objectWillChange.send()
    }
    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        failed = false; controller.checkForUpdates(nil)
    }
}
#endif
