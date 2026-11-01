import UIKit
import BridgeCore

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        BridgePaths.prepare()
        BridgeLog.shared.configure(url: BridgePaths.hostLogFile)
        // A marker from a previous process is not evidence for this launch.
        try? FileManager.default.removeItem(at: BridgePaths.engineReadyFile)
        try? FileManager.default.removeItem(at: BridgePaths.engineHeartbeatFile)
        try? FileManager.default.removeItem(at: BridgePaths.engineEntryConfirmedFile)
        BridgeLivenessMonitor.shared.start()
        BridgeLivenessMonitor.shared.recordAppTransition("app-did-finish-launching")
        BridgeLog.shared.append(
            "host_launch pid=\(ProcessInfo.processInfo.processIdentifier) " +
            "bundle=\(Bundle.main.bundleIdentifier ?? "<missing>") " +
            "version=\(BridgeBuild.marketingVersion) build=\(BridgeBuild.buildNumber)"
        )
        _ = BridgeAppModel.shared
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        BridgeLivenessMonitor.shared.recordAppTransition("app-will-resign-active")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        BridgeLivenessMonitor.shared.recordAppTransition("app-did-become-active")
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        BridgeLivenessMonitor.shared.recordAppTransition("app-did-enter-background")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        BridgeLivenessMonitor.shared.recordAppTransition("app-will-enter-foreground")
    }
}
