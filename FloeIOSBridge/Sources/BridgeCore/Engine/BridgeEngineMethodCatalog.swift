import Foundation

/// Runtime-only capabilities that decide whether a method can be advertised.
/// They are computed from actual class/selector availability, never from a
/// build flag alone.
public enum BridgeEnginePrivateCapability: String, CaseIterable, Sendable {
    case redactedTyping
    case continuousDrag
    case lockButton
    case lockState
    case foregroundHelper
    case installedApps
    case openURL
    case appState
}

public enum BridgeEngineMethodCatalog {
    /// All methods implemented by the embedded executor. Host-owned methods
    /// (`config`, `logs`, `stream_ticket`) are deliberately absent.
    public static let implementedMethods: Set<String> = [
        "device_info",
        "page_source",
        "screen_text",
        "reset",
        "screenshot",
        "tap",
        "double_tap",
        "long_press",
        "swipe",
        "page",
        "collect",
        "scroll_to_element",
        "scroll",
        "type",
        "clear_text",
        "home",
        "lock",
        "unlock",
        "is_locked",
        "list_apps",
        "resolve_app",
        "open_url",
        "launch_app",
        "activate_app",
        "terminate_app",
        "find_element",
        "tap_element",
        "find_and_tap",
        "drag",
        "wait",
    ]

    /// Removes methods whose only real implementation is an unavailable
    /// private API. `open_url` also has a public fallback, so it stays. `drag`
    /// keeps its public two-point path even when the continuous private path
    /// is absent; the path form reports `method_not_available` at call time.
    public static func supportedMethods(capabilities: Set<BridgeEnginePrivateCapability>) -> Set<String> {
        var methods = implementedMethods
        if !capabilities.contains(.redactedTyping) {
            // Never fall back to a typing path that can log raw text.
            methods.remove("type")
            methods.remove("clear_text")
        }
        if !capabilities.contains(.lockButton) || !capabilities.contains(.lockState) {
            methods.remove("lock")
        }
        if !capabilities.contains(.lockState) {
            methods.remove("unlock")
            methods.remove("is_locked")
        }
        if !capabilities.contains(.openURL) {
            methods.remove("open_url")
        }
        // list_apps has an opened-history fallback; resolve_app has a built-in
        // table. home/unlock use public XCUIDevice buttons.
        return methods
    }

    public static func isHostHandled(_ method: String) -> Bool {
        method == "config" || method == "logs" || method == "stream_ticket"
    }
}
