// FloeApp — Optional local recognition model preload policy.
//
// SPDX-License-Identifier: MPL-2.0
//
// Foundation-only on purpose: this file has no UIKit, Speech or WhisperKit
// dependency, so the exact production bytes run in the host harness. The UI,
// scene-phase hook and provider/profile selectors are owned by the app root;
// they call the small API below.
//
// Settled user-facing rules:
// - Preload is OFF for every recognition method and provider by default. The
//   absence of a stored value is false; there is no route-specific opt-in.
// - Changing the PRIMARY recognition route (method, or the primary cloud
//   provider/profile) resets the toggle to OFF. A route change is observed
//   through `observePrimaryIdentity(_:)`; language, decoding/model parameters
//   and credentials are not part of that identity and therefore never reset
//   the toggle.
// - An explicit user ON persists in UserDefaults across relaunch and across
//   entering/leaving the settings screen. It does not survive a primary
//   route change. Returning to the previous route remains OFF: the reset is
//   not automatically re-enabled.
// - The policy only answers whether preload is allowed. It never downloads,
//   records audio, requests Apple speech authorization or mounts a model.

import Foundation

enum VoiceRecognitionPreloadPolicy {
    /// Stored explicit user choice. Missing or false both mean OFF.
    static let enabledDefaultsKey = "voice.recognition.preload.enabled.v1"
    /// Last primary route observed by the policy. Used only to detect a
    /// primary route change; parameters that are not primary identity are
    /// intentionally excluded.
    static let primaryIdentityDefaultsKey = "voice.recognition.preload.primaryIdentity.v1"

    /// Result of reconciling the current primary route with the stored one.
    enum PrimaryIdentityUpdate: Equatable, Sendable {
        /// Same route as the last observation; the toggle is untouched.
        case unchanged
        /// First observation (or a different route while already OFF); the
        /// route was recorded and the toggle remains OFF.
        case recorded
        /// The primary route changed while preload was ON; the toggle was
        /// reset to OFF exactly once.
        case reset
    }

    /// Whether the user explicitly enabled preload. Defaults to false for
    /// every route. Safe to read when no value was ever written.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledDefaultsKey)
    }

    static func primaryIdentity(defaults: UserDefaults = .standard) -> String? {
        normalized(defaults.string(forKey: primaryIdentityDefaultsKey))
    }

    /// Builds the stable primary-route identity. Only method plus primary
    /// provider/profile belong here. Language, model parameters and
    /// credentials must NOT be added: changing them is explicitly not a
    /// reset. Nil/empty components normalize to an empty field.
    static func primaryIdentity(method: String,
                                provider: String? = nil,
                                profile: String? = nil) -> String {
        [method, provider ?? "", profile ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\u{1F}")
    }

    /// Records an explicit user toggle. Enabling records the current primary
    /// identity so a later route change can reset it; disabling keeps the
    /// last identity so a route changed while OFF is still recorded by the
    /// next observation.
    ///
    /// Callers that own the setting must pass the actual current primary
    /// route when enabling. Passing nil enables the choice but cannot bind it
    /// to a route yet; the first real observation then resets it to OFF
    /// (conservative default-off behavior).
    static func setEnabled(_ enabled: Bool,
                           primaryIdentity: String?,
                           defaults: UserDefaults = .standard) {
        if enabled {
            if let identity = normalized(primaryIdentity) {
                defaults.set(identity, forKey: primaryIdentityDefaultsKey)
            }
            defaults.set(true, forKey: enabledDefaultsKey)
        } else {
            // Keep the route binding fresh when the caller knows it, so a
            // later change is still detected while the toggle is OFF.
            if let identity = normalized(primaryIdentity) {
                defaults.set(identity, forKey: primaryIdentityDefaultsKey)
            }
            defaults.set(false, forKey: enabledDefaultsKey)
        }
    }

    /// Convenience for disabling from a settings control; the route binding
    /// is preserved.
    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        if enabled {
            defaults.set(true, forKey: enabledDefaultsKey)
        } else {
            defaults.set(false, forKey: enabledDefaultsKey)
        }
    }

    /// Reconciles the current primary route at startup, before/at settings
    /// entry, and after a primary method/provider/profile change. Returns
    /// `.reset` exactly when an ON toggle was turned OFF by this call.
    @discardableResult
    static func observePrimaryIdentity(_ identity: String?,
                                       defaults: UserDefaults = .standard) -> PrimaryIdentityUpdate {
        let candidate = normalized(identity)
        let previous = normalized(defaults.string(forKey: primaryIdentityDefaultsKey))
        if previous == candidate {
            // An ON choice with no route binding is not valid: bind it before
            // enabling, or the next observation resets it. This keeps the
            // default OFF for every route even with a stale stored value.
            if candidate == nil, defaults.bool(forKey: enabledDefaultsKey) {
                defaults.set(false, forKey: enabledDefaultsKey)
                return .reset
            }
            return .unchanged
        }
        if let candidate {
            defaults.set(candidate, forKey: primaryIdentityDefaultsKey)
        } else {
            defaults.removeObject(forKey: primaryIdentityDefaultsKey)
        }
        // A first observation never enables preload. If a stale ON value is
        // present without a bound route (or the primary route changed), the
        // safe result is OFF.
        if defaults.bool(forKey: enabledDefaultsKey) {
            defaults.set(false, forKey: enabledDefaultsKey)
            return .reset
        }
        return .recorded
    }

    /// Pure scheduling decision for the root hook. `isReady` covers persisted
    /// settings/foreground readiness and `isInstalled` must come from the
    /// verified installed-model check; neither may be assumed here. Preload
    /// never downloads or starts a recording.
    static func shouldWarm(isEnabled: Bool,
                           isForeground: Bool,
                           isInstalled: Bool,
                           isReady: Bool = true) -> Bool {
        isEnabled && isForeground && isInstalled && isReady
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
