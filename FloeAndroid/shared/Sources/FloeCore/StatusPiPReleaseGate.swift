// FloeCore — Release gate for the opt-in status Picture-in-Picture surface.
//
// Status PiP (the floating progress/status window for Linux sessions and
// tasks) is an *opt-in* surface. It must never be the thing that keeps work
// alive: the compliant path for explicit user work remains the system
// continued-processing/Live Activity background mode plus the bounded
// completion lease. This gate lets a release configuration disable status
// PiP entirely (e.g. while the App Store review posture for the
// sample-buffer PiP source is being settled) without touching the compliant
// system background path.
//
// Configuration sources, in priority order:
//   1. A build-time `-DFLOE_STATUS_PIP_DISABLED` compilation condition.
//   2. UserDefaults key `statusPiPReleaseEnabled` (settable per build/QA).
// Default is enabled; a release build may flip the default below or inject
// the compilation condition in project.yml.

import Foundation

public enum StatusPiPReleaseGate {
    public static let userDefaultsKey = "statusPiPReleaseEnabled"

    /// Release default. Change to `false` (or set FLOE_STATUS_PIP_DISABLED)
    /// to ship a build where status PiP controls are hidden and no PiP
    /// controller is created, while standard background processing remains.
    public static let releaseDefaultEnabled = true

    public static var isEnabled: Bool {
        #if FLOE_STATUS_PIP_DISABLED
        return false
        #else
        if let override = UserDefaults.standard.object(forKey: userDefaultsKey) as? Bool {
            return override
        }
        return releaseDefaultEnabled
        #endif
    }

    /// Test/QA override.
    public static func setEnabled(_ enabled: Bool?) {
        if let enabled {
            UserDefaults.standard.set(enabled, forKey: userDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        }
    }

    /// Pure degradation rule: when status PiP is disabled, the user's PiP
    /// choice falls back to the standard compliant path (30s completion lease
    /// plus system continued processing) instead of creating a PiP controller.
    /// Every other preference is honored unchanged.
    public static func effectivePreference(
        _ requested: BackgroundExecutionPreference,
        statusPiPEnabled: Bool
    ) -> BackgroundExecutionPreference {
        guard requested == .pictureInPicture, !statusPiPEnabled else { return requested }
        return .standard
    }
}
