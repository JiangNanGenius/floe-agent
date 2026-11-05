#if os(macOS)
import AppKit

@MainActor
final class BridgeApplicationDelegate: NSObject, NSApplicationDelegate {
    static weak var model: BridgeAppModel?
    func applicationDidFinishLaunching(_ notification: Notification) { Self.model?.applicationDidFinishLaunching() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.model?.openSettings()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "floe-bridge" && $0.host == "connect" }) {
            Self.model?.openSettings()
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        guard model.updates.installation.reserveForTerminationIfIdle() else {
            model.error = String(localized: "Floe Bridge is finishing work. Try again when it is idle.")
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { Self.model?.stopListenerForTermination() }
}
#endif
