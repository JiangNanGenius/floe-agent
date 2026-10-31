// FloeApp — Primary recognition route resolution and preload route binding.
//
// SPDX-License-Identifier: MPL-2.0
//
// Pure, Foundation-only policy shared by dictation, continuous voice, file
// tools and the settings UI. It answers two separate questions:
//
// 1. Which recognizer a request should use for the current primary method
//    (explicit cloud, cloud-first automatic, local enhanced, or Apple system).
// 2. Which stable primary-route identity the default-off local-preload toggle
//    is bound to.
//
// ROUTE IDENTITY is metadata-only and deliberately INDEPENDENT of credential
// readiness: a temporarily missing key, a Keychain lock or an invalid field
// must not masquerade as a primary-provider change (which would reset a
// deliberate preload ON). It contains method + provider + billing route +
// profile UUID. Editing a model, endpoint/URL, language or key never changes
// it; selecting a different billing route inside the same profile DOES (that
// is a provider/plan change).
//
// SELECTION RULES:
// - A selected primary profile is honored even when it is not currently
//   ready. It is never silently replaced by a different ready cloud profile
//   (that could bill another provider/plan).
// - Only when no primary selection exists at all does the deterministic first
//   profile supply metadata/selection.
// - Automatic falls back locally while the selected primary is unusable;
//   explicit cloud returns a normal configuration error instead.
//
// No type here performs an account/membership probe. A configured cloud
// profile is selectable by definition; actual provider errors use the normal
// redacted failure/fallback path.

import Foundation
import FloeCore

enum CloudASRMethod {
    static let automatic = "automatic"
    static let system = "system"
    static let enhanced = "enhanced"
    static let cloud = "cloud"
}

enum CloudASRRecognizerRoute: Equatable, Sendable {
    /// The selected, currently usable cloud profile.
    case cloud(ASRProfile)
    /// On-device Whisper (explicit enhanced, or automatic while the selected
    /// cloud is unusable/absent).
    case localWhisper
    /// Apple system recognition (explicit system).
    case apple
    /// Explicit cloud was requested but the selected profile is unusable.
    /// This is a normal actionable configuration state, never a silent local
    /// switch and never a different billing route.
    case cloudUnavailable
}

struct CloudASRRouteResolution: Equatable, Sendable {
    let route: CloudASRRecognizerRoute
    let identity: String

    var cloudProfile: ASRProfile? {
        if case .cloud(let profile) = route { return profile }
        return nil
    }

    var isCloud: Bool {
        if case .cloud = route { return true }
        return false
    }
}

enum CloudASRRouteResolver {
    static func resolve(
        method: String,
        profiles: [ASRProfile],
        primaryProfileID: UUID?,
        readyProfileIDs: Set<UUID>
    ) -> CloudASRRouteResolution {
        // Metadata selection is independent of readiness and never replaced by
        // a different ready profile.
        let selected: ASRProfile? = {
            if let primaryProfileID,
               let selected = profiles.first(where: { $0.id == primaryProfileID }) {
                return selected
            }
            // No primary selection exists at all (for example a fresh store
            // before the first selection): the deterministic first profile is
            // the only automatic metadata choice.
            if primaryProfileID == nil { return profiles.first }
            return nil
        }()
        let ready = selected.flatMap { readyProfileIDs.contains($0.id) ? $0 : nil }

        switch method {
        case CloudASRMethod.cloud:
            guard let ready else {
                return CloudASRRouteResolution(
                    route: .cloudUnavailable,
                    identity: identity(method: method, profile: selected))
            }
            return CloudASRRouteResolution(
                route: .cloud(ready),
                identity: identity(method: method, profile: selected))
        case CloudASRMethod.enhanced:
            return CloudASRRouteResolution(
                route: .localWhisper,
                identity: identity(method: method, profile: nil))
        case CloudASRMethod.system:
            return CloudASRRouteResolution(
                route: .apple,
                identity: identity(method: method, profile: nil))
        case CloudASRMethod.automatic, "":
            if let ready {
                return CloudASRRouteResolution(
                    route: .cloud(ready),
                    identity: identity(method: CloudASRMethod.automatic, profile: selected))
            }
            return CloudASRRouteResolution(
                route: .localWhisper,
                identity: identity(method: CloudASRMethod.automatic, profile: selected))
        default:
            return CloudASRRouteResolution(
                route: .localWhisper,
                identity: identity(method: method, profile: selected))
        }
    }

    /// Stable preload-route identity. Provider + billing route + profile UUID
    /// participate; model, endpoint, language and credential do not.
    static func identity(method: String, profile: ASRProfile?) -> String {
        [method,
         profile?.provider.rawValue ?? "",
         profile?.billingRoute.rawValue ?? "",
         profile?.id.uuidString ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\u{1F}")
    }
}
