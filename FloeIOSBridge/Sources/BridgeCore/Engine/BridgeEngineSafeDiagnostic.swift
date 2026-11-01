import Foundation

/// Fixed-shape diagnostics for SDK calls.
///
/// Exception descriptions from UIKit/XCTest can contain element values,
/// including text typed earlier. Product logs therefore carry only the
/// caller-supplied stage, a fixed kind, a numeric code and a sensitivity bit.
/// The error object is accepted solely to read its numeric code; its
/// description, domain and user-info are never formatted into the line.
public enum BridgeEngineSafeDiagnostic {
    public static func exceptionLine(stage: String,
                                     error: Error?,
                                     sensitive: Bool) -> String {
        let safeStage = sanitizedStage(stage)
        let code = (error as NSError?)?.code ?? -1
        return "rpc_exception stage=\(safeStage) sensitive=\(sensitive ? 1 : 0) kind=objc code=\(code)"
    }

    /// Stage names are code constants. Only known labels are emitted; an
    /// unknown or interpolated label becomes "unknown" so a future call site
    /// cannot accidentally pass argument or element text into a product log.
    private static let knownStages: Set<String> = [
        "activate", "activate-app", "activate-state", "activate-wait",
        "app-frame", "app-screenshot", "app-state",
        "clear-delete", "clear-delete-key", "clear-select-all",
        "continuous-drag", "double-tap", "drag", "element-value", "elements",
        "find-and-tap", "focused-field-read", "focused-field-value",
        "focused-fields", "home", "home-source-after", "home-source-before",
        "home-springboard-after", "home-springboard-before", "is-hittable",
        "keyboard-key", "keyboard-query", "keyboard-shift", "keyboard-shift-off",
        "passcode-key-check",
        "launch", "launch-app", "launch-wait", "live-identifier", "live-label",
        "long-press", "native-element-tap", "overlays", "page", "root-facts",
        "screen-capture", "screenshot", "scroll", "secure-fields", "secure-frame",
        "snapshot", "snapshot-render", "state", "submit", "swipe",
        "swipe-app-frame", "swipe-snapshot", "system-alert-check", "tap",
        "tap-app-frame", "tap-element", "tap-snapshot", "target-state",
        "terminate-app", "terminate-wait", "type", "type-app-frame",
        "type-focus", "type-focus-query", "type-initial-value",
        "type-live-enumerate", "type-live-identifier", "type-snapshot",
        "type-text", "type-value", "unlock-home", "wait-activate", "wait-launch",
        "window", "window-refresh",
    ]

    private static func sanitizedStage(_ stage: String) -> String {
        knownStages.contains(stage) ? stage : "unknown"
    }
}
