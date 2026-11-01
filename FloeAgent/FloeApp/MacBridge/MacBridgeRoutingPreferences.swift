import Foundation
import FloeCore

/// Explicit backup choice affects only subsequent unbound tasks. The current
/// run and unknown command receipts keep their original Mac ownership.
@MainActor
enum MacBridgeRoutingPreferences {
    static var preferMacForNewTasks: Bool {
        get {
            guard LocalBridgePlatform.current.supportsMacBridge else { return false }
            let defaults = UserDefaults.standard
            let key = "floe.macBridge.preferForNewTasks.v1"
            return defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
        }
        set {
            guard LocalBridgePlatform.current.supportsMacBridge else { return }
            UserDefaults.standard.set(newValue, forKey: "floe.macBridge.preferForNewTasks.v1")
        }
    }
}
