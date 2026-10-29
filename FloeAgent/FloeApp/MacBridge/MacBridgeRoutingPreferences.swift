import Foundation

/// Explicit backup choice affects only subsequent unbound tasks. The current
/// run and unknown command receipts keep their original Mac ownership.
@MainActor
enum MacBridgeRoutingPreferences {
    static var preferMacForNewTasks: Bool {
        get {
            let defaults = UserDefaults.standard
            let key = "floe.macBridge.preferForNewTasks.v1"
            return defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: "floe.macBridge.preferForNewTasks.v1") }
    }
}
