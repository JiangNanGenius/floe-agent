import AppKit
import Darwin
import Sparkle

// The fixture invokes the real updater delegate and activity ledger. It
// replaces the service only because no production store or Keychain is used.
final class BridgeService: Sendable {
    let updateActivity = BridgeUpdateActivity()
    func reserveUpdateInstallationIfIdle() -> BridgeUpdateActivity.Installation? {
        updateActivity.reserveInstallationIfIdle()
    }
}

@MainActor
final class FixtureApp: NSObject, NSApplicationDelegate {
    private let root: URL
    private let release: String
    private let activity = BridgeUpdateActivity()
    private let driver = FixtureDriver()
    private var reservation: BridgeUpdateInstallation?
    private var updaterDelegate: BridgeUpdaterDelegate?
    private var updater: SPUUpdater?
    private var lease: BridgeUpdateActivity.Lease?
    private var settling = false
    private var passedAdmissionTest = false

    init(root: URL, release: String) {
        self.root = root
        self.release = release
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        record("pid:" + String(getpid()))
        record("launch:" + release)
        let marker = root.appendingPathComponent("state.txt")
        if release == "10" {
            let preserved = (try? String(contentsOf: marker, encoding: .utf8)) == "fixture-state"
            record(preserved ? "preserved-state" : "lost-state")
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }

        try? "fixture-state".write(to: marker, atomically: true, encoding: .utf8)
        lease = try? activity.begin(.job)
        let installation = BridgeUpdateInstallation(activity: activity)
        reservation = installation
        installation.stateChanged = { [weak self] in self?.installationStateChanged() }
        let delegate = BridgeUpdaterDelegate(installation: installation)
        updaterDelegate = delegate
        driver.event = { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.record(event)
                if event.hasPrefix("error:"),
                   let admitted = try? self.activity.begin(.request) {
                    self.activity.finish(admitted)
                    self.record("work-still-admitted")
                }
            }
        }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: delegate)
        self.updater = updater
        do {
            try updater.start()
            updater.checkForUpdates()
        } catch {
            record("updater-start-error:" + error.localizedDescription)
        }
    }

    private func installationStateChanged() {
        guard let reservation, reservation.waitingForIdle, !settling else { return }
        settling = true
        record("deferred-for-job")
        Task {
            try? await Task.sleep(for: .milliseconds(1_400))
            let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
            let fields = (try? Data(contentsOf: plist)).flatMap {
                try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
            }
            passedAdmissionTest = fields?["CFBundleVersion"] as? String == "9"
                && activity.activityCount == 1 && !activity.isAdmissionClosed
            record(passedAdmissionTest ? "old-version-held-while-busy" : "admission-test-failed")
            if let lease { activity.finish(lease); self.lease = nil }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard release == "9" else { return .terminateNow }
        guard passedAdmissionTest, reservation?.reserveForTerminationIfIdle() == true else {
            record("quit-refused")
            return .terminateCancel
        }
        record("quit-with-closed-admission")
        return .terminateNow
    }

    private func record(_ value: String) {
        let log = root.appendingPathComponent("events.log")
        let handle = try? FileHandle(forWritingTo: log)
        defer { try? handle?.close() }
        _ = try? handle?.seekToEnd()
        try? handle?.write(contentsOf: Data((value + "\n").utf8))
    }
}

@main
@MainActor
enum Main {
    static func main() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard Bundle.main.bundleIdentifier?.hasPrefix("org.floeagent.sparkle-fixture.") == true,
              let directory = info["FloeFixtureRoot"] as? String, directory.hasPrefix("/private/tmp/floe-ota-"),
              let release = info["CFBundleVersion"] as? String, release == "9" || release == "10" else { exit(2) }
        let app = NSApplication.shared
        let delegate = FixtureApp(root: URL(fileURLWithPath: directory), release: release)
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
