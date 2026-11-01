import Foundation

/// The privacy decision for one text-input operation.
///
/// Ordinary non-secure input into a third-party App (or an ordinary Apple App
/// page) is available to an authorized paired client. A focused secure field in
/// a third-party App additionally requires the per-client owner grant. Secure
/// input in an Apple-owned App and all system lock/passcode/authorization input
/// is refused, even with a grant.
public struct BridgeEngineInputDecision: Equatable, Sendable {
    public enum Outcome: String, Equatable, Sendable {
        case allowed
        case denied
    }

    public var outcome: Outcome
    public var reason: String
    public var requiresSensitiveGrant: Bool
    public var usesRedactedTyping: Bool

    public init(outcome: Outcome,
                reason: String,
                requiresSensitiveGrant: Bool,
                usesRedactedTyping: Bool) {
        self.outcome = outcome
        self.reason = reason
        self.requiresSensitiveGrant = requiresSensitiveGrant
        self.usesRedactedTyping = usesRedactedTyping
    }

    public var allowed: Bool { outcome == .allowed }
}

public enum BridgeEngineInputPolicy {
    /// Bundle identifiers that represent a system authorization, passcode or
    /// lock surface. These are refused for every kind of input, even with the
    /// owner grant: the grant covers third-party App passwords only.
    public static let systemAuthorizationBundleIdentifiers: Set<String> = [
        "com.apple.springboard",
        "com.apple.AuthKitUI",
        "com.apple.security",
        "com.apple.PasscodeSettings",
    ]

    /// True for every Apple-owned app bundle. Ordinary (non-secure) text and
    /// touches in Settings/Safari/Notes remain available; secure input in an
    /// Apple-owned app is refused below because the owner grant is limited to
    /// third-party Apps.
    public static func isSystemOwnedApp(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return true }
        return bundleIdentifier.lowercased().hasPrefix("com.apple.")
    }

    /// True for the system surfaces that own lock, passcode or account
    /// authorization UI. A nil/empty identifier cannot be established and is
    /// treated as a system surface.
    public static func isSystemAuthorizationSurface(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return true }
        if systemAuthorizationBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }
        let lower = bundleIdentifier.lowercased()
        if lower.hasPrefix("com.apple.authkit")
            || lower.hasPrefix("com.apple.localauthentication")
            || lower.hasPrefix("com.apple.authenticationservices")
            || lower.hasPrefix("com.apple.passcode")
            || lower.hasPrefix("com.apple.coreauth")
            || lower.hasPrefix("com.apple.authorizationservices") {
            return true
        }
        return false
    }

    /// Kept for the existing callers: the old name meant exactly the
    /// lock/passcode/authorization surfaces, not every Apple-owned app.
    public static func isSystemSurface(bundleIdentifier: String?) -> Bool {
        isSystemAuthorizationSurface(bundleIdentifier: bundleIdentifier)
    }

    /// Apple apps whose visible secure fields make a generic tap ambiguous
    /// with a passcode/keypad surface. Generic touches are refused while such
    /// a field exists; ordinary pages without secure fields stay available.
    public static func isSystemSecureSettingsSurface(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return true }
        let lower = bundleIdentifier.lowercased()
        return lower == "com.apple.preferences"
            || lower == "com.apple.springboard"
            || isSystemAuthorizationSurface(bundleIdentifier: bundleIdentifier)
    }

    /// `focusedEditable` means at least one editable field currently has
    /// keyboard focus. `focusedSecure` is true only when at least one of those
    /// focused fields is a secure text field. A focus state that cannot be
    /// inspected is not treated as focus.
    public static func decide(screenLocked: Bool,
                              bundleIdentifier: String?,
                              focusedEditable: Bool,
                              focusedSecure: Bool,
                              sensitiveInputGranted: Bool,
                              redactedTypingAvailable: Bool) -> BridgeEngineInputDecision {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return BridgeEngineInputDecision(
                outcome: .denied,
                reason: "The foreground app could not be established; input is refused.",
                requiresSensitiveGrant: false,
                usesRedactedTyping: false
            )
        }
        if screenLocked {
            return BridgeEngineInputDecision(
                outcome: .denied,
                reason: "The screen is locked. System passcode and lock-screen input is never automated.",
                requiresSensitiveGrant: false,
                usesRedactedTyping: false
            )
        }
        if isSystemAuthorizationSurface(bundleIdentifier: bundleIdentifier) {
            return BridgeEngineInputDecision(
                outcome: .denied,
                reason: "System authorization, passcode and SpringBoard input is never automated.",
                requiresSensitiveGrant: false,
                usesRedactedTyping: false
            )
        }
        guard focusedEditable else {
            return BridgeEngineInputDecision(
                outcome: .denied,
                reason: "No editable field currently has keyboard focus. Tap the field first.",
                requiresSensitiveGrant: false,
                usesRedactedTyping: false
            )
        }
        if focusedSecure {
            if isSystemOwnedApp(bundleIdentifier: bundleIdentifier) {
                return BridgeEngineInputDecision(
                    outcome: .denied,
                    reason: "Secure input in an Apple system app is never automated, even with the owner grant.",
                    requiresSensitiveGrant: false,
                    usesRedactedTyping: false
                )
            }
            guard sensitiveInputGranted else {
                return BridgeEngineInputDecision(
                    outcome: .denied,
                    reason: "The focused secure field requires the device owner's per-client sensitive-input grant.",
                    requiresSensitiveGrant: true,
                    usesRedactedTyping: false
                )
            }
            guard redactedTypingAvailable else {
                return BridgeEngineInputDecision(
                    outcome: .denied,
                    reason: "Secure input is unavailable because the SDK's redacted typing path is absent; plaintext fallback is refused.",
                    requiresSensitiveGrant: true,
                    usesRedactedTyping: false
                )
            }
            return BridgeEngineInputDecision(
                outcome: .allowed,
                reason: "Secure third-party field input is allowed by the owner grant and uses the redacted typing path.",
                requiresSensitiveGrant: true,
                usesRedactedTyping: true
            )
        }
        return BridgeEngineInputDecision(
            outcome: .allowed,
            reason: "Ordinary non-secure input is allowed.",
            requiresSensitiveGrant: false,
            usesRedactedTyping: true
        )
    }

    /// Text that must never be echoed into a result, receipt or log. Only
    /// non-secret structural facts (byte counts, booleans) may be reported.
    public static func isSecretBearing(focusedSecure: Bool) -> Bool {
        focusedSecure
    }
}
