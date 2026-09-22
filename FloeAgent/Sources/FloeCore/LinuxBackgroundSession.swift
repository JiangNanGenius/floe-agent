// FloeCore — Per-environment Linux "allow background running" preference and
// the Picture-in-Picture hold policy that it governs.
//
// One preference per environment is the single user-owned switch: while a
// *running* VM is background-eligible, the app may prepare (and arm the
// automatic Home/app-switch transition for) the supported PiP status surface
// when it backgrounds. The preference never changes by itself; in particular a
// user closing the PiP window ends only the current background hold — the VM
// for that hold is stopped and flushed safely — and leaves the preference
// exactly as the user set it.
//
// The policy is pure value logic so the app target and the tests share one
// implementation. It does not claim unlimited background execution: iOS still
// decides how long any process survives, and a relaunch always starts from the
// durable environment disk.

import Foundation

/// Durable, user-owned per-environment preference. The environment id is the
/// identity; nothing is inferred from the app's current frontmost screen.
public struct LinuxBackgroundRunPreference: Sendable, Codable, Hashable, Identifiable {
    public var id: String { environmentID }
    public var environmentID: String
    /// "允许后台运行": the user explicitly allowed this environment to keep
    /// running (and to hold the PiP status surface) while Floe is backgrounded.
    public var isEnabled: Bool
    public var updatedAt: Date

    public init(
        environmentID: String,
        isEnabled: Bool,
        updatedAt: Date = Date()
    ) {
        self.environmentID = environmentID
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
    }
}

/// Persistence codec for the per-environment preferences. Static functions
/// with an injected `UserDefaults` follow the existing FloeCore convention
/// (`CanvasPreferences`), which keeps the owner of the in-memory state in the
/// app layer and keeps this type free of shared mutable state.
public enum LinuxBackgroundRunPreferences {
    /// Current storage key. Build 221 used `linuxBackgroundSessions.v1` (a bare
    /// array of environment ids); that list is migrated once and then removed.
    public static let defaultsKey = "linuxBackgroundRunPreferences.v2"
    public static let legacyDefaultsKey = "linuxBackgroundSessions.v1"

    public static func load(
        from defaults: UserDefaults = .standard
    ) -> [String: LinuxBackgroundRunPreference] {
        guard let data = defaults.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode(
                [LinuxBackgroundRunPreference].self, from: data
              ) else { return [:] }
        var preferences: [String: LinuxBackgroundRunPreference] = [:]
        for record in records where !record.environmentID.isEmpty {
            preferences[record.environmentID] = record
        }
        return preferences
    }

    public static func save(
        _ preferences: [String: LinuxBackgroundRunPreference],
        to defaults: UserDefaults = .standard
    ) {
        let records = preferences.values
            .filter { !$0.environmentID.isEmpty }
            .sorted { $0.environmentID < $1.environmentID }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Reads one environment's preference. A missing record is disabled: the
    /// user must explicitly allow background running.
    public static func isEnabled(
        environmentID: String,
        in preferences: [String: LinuxBackgroundRunPreference]
    ) -> Bool {
        preferences[environmentID]?.isEnabled == true
    }

    /// Enabled environment ids in a stable order.
    public static func enabledEnvironmentIDs(
        in preferences: [String: LinuxBackgroundRunPreference]
    ) -> [String] {
        preferences.values
            .filter(\.isEnabled)
            .map(\.environmentID)
            .sorted()
    }

    /// Imports the pre-Build-222 environment list exactly once. Returns true
    /// when the stored preferences changed. The legacy key is removed only
    /// after the import is written, so an interrupted migration is retried
    /// instead of losing the user's choice.
    @discardableResult
    public static func migrateLegacyIfNeeded(
        from defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> Bool {
        let legacy = defaults.array(forKey: legacyDefaultsKey) as? [String] ?? []
        guard !legacy.isEmpty else { return false }
        var preferences = load(from: defaults)
        var changed = false
        for environmentID in legacy where !environmentID.isEmpty {
            if preferences[environmentID] == nil {
                preferences[environmentID] = LinuxBackgroundRunPreference(
                    environmentID: environmentID,
                    isEnabled: true,
                    updatedAt: now
                )
                changed = true
            } else if preferences[environmentID]?.isEnabled == false {
                // An explicit current decision always wins over the legacy
                // hint; never re-enable a preference the user turned off.
                continue
            }
        }
        if changed { save(preferences, to: defaults) }
        defaults.removeObject(forKey: legacyDefaultsKey)
        return changed
    }
}

/// What the app must do with the supported PiP status surface. The policy owns
/// the *decision*; the app owns AVKit, the guest stop and the flush.
public enum LinuxBackgroundHoldDecision: Sendable, Equatable {
    /// No lifecycle change: keep the current surface/hold as it is.
    case none
    /// A background hold began (or now owns a different VM): prepare the
    /// supported PiP status surface and arm the automatic inline transition.
    case prepareSurface(environmentID: String)
    /// The user closed PiP: end the current hold and safely stop/flush this VM.
    /// The per-environment preference is preserved.
    case endHoldAndStop(environmentID: String)
    /// The app returned to the foreground: retract the floating surface but
    /// keep the VM running and the preference untouched.
    case retractSurface
}

/// State machine for the Linux background hold. "Eligible" means: the guest is
/// actually running *and* the user's per-environment preference is enabled.
/// Ordering comes from the caller so the same environment is always page one.
public struct LinuxBackgroundHoldPolicy: Sendable, Equatable {
    /// Environment ids currently in the hold, in presentation order.
    public private(set) var heldEnvironmentIDs: [String] = []
    /// The environment the surface currently shows, when one does.
    public private(set) var surfacedEnvironmentID: String?
    /// Environments whose PiP window the user closed during this background
    /// hold. Suppression is per hold and per environment: once that VM is
    /// observed stopped it is forgotten, so an explicit later restart plus a
    /// new background transition legitimately prepares the surface again.
    public private(set) var endedHoldEnvironmentIDs: Set<String> = []
    /// True between a background transition and the matching foreground
    /// transition while at least one environment is eligible.
    public private(set) var isBackgroundHeld = false

    public init() {}

    public var hasActiveHold: Bool {
        isBackgroundHeld && !heldEnvironmentIDs.isEmpty
    }

    /// Reconciles the currently eligible environments (running + preference
    /// enabled) on every background transition, start/stop and preference
    /// change. This is the only entry point that may begin a hold.
    public mutating func updateEligibleEnvironmentIDs(
        _ environmentIDs: [String]
    ) -> LinuxBackgroundHoldDecision {
        // Forget close-suppression for environments that are no longer
        // eligible (normally: the VM the user's PiP close stopped).
        endedHoldEnvironmentIDs.formIntersection(environmentIDs)
        let eligible = environmentIDs.filter { !endedHoldEnvironmentIDs.contains($0) }
        guard !eligible.isEmpty else {
            heldEnvironmentIDs = []
            surfacedEnvironmentID = nil
            isBackgroundHeld = false
            return .none
        }
        if isBackgroundHeld, heldEnvironmentIDs == eligible {
            return .none
        }
        let previous = heldEnvironmentIDs
        heldEnvironmentIDs = eligible
        if isBackgroundHeld,
           let surfaced = surfacedEnvironmentID,
           eligible.contains(surfaced) {
            // The set changed but the shown VM is still eligible: keep it.
            _ = previous
            return .none
        }
        isBackgroundHeld = true
        let first = eligible[0]
        surfacedEnvironmentID = first
        return .prepareSurface(environmentID: first)
    }

    /// Foreground reconciliation: keeps which VMs belong to the hold current
    /// without claiming a background hold. The next background transition
    /// therefore prepares the surface again, while a user's PiP close keeps
    /// suppressing its environment.
    public mutating func updateForegroundEligibleEnvironmentIDs(
        _ environmentIDs: [String]
    ) {
        endedHoldEnvironmentIDs.formIntersection(environmentIDs)
        let eligible = environmentIDs.filter { !endedHoldEnvironmentIDs.contains($0) }
        heldEnvironmentIDs = eligible
        if let surfacedEnvironmentID, eligible.contains(surfacedEnvironmentID) {
            // Keep the page the user was on.
        } else {
            self.surfacedEnvironmentID = eligible.first
        }
        if eligible.isEmpty { isBackgroundHeld = false }
    }

    /// Foreground transition. The hold ends, the floating surface is
    /// retracted, and every VM keeps running.
    public mutating func enteredForeground() -> LinuxBackgroundHoldDecision {
        let wasHolding = isBackgroundHeld
        isBackgroundHeld = false
        guard wasHolding else { return .none }
        return .retractSurface
    }

    /// The user closed the PiP window. Exactly one VM — the one the surface was
    /// showing — is released; the preference is never touched here.
    public mutating func userClosedPictureInPicture() -> LinuxBackgroundHoldDecision {
        guard let environmentID = surfacedEnvironmentID ?? heldEnvironmentIDs.first else {
            return .none
        }
        endedHoldEnvironmentIDs.insert(environmentID)
        heldEnvironmentIDs.removeAll { $0 == environmentID }
        surfacedEnvironmentID = heldEnvironmentIDs.first
        if heldEnvironmentIDs.isEmpty {
            isBackgroundHeld = false
        }
        return .endHoldAndStop(environmentID: environmentID)
    }

    /// A VM stopped (user action, guest failure or host stop): drop it from
    /// the hold without inventing a surface.
    public mutating func environmentStopped(_ environmentID: String) {
        heldEnvironmentIDs.removeAll { $0 == environmentID }
        endedHoldEnvironmentIDs.remove(environmentID)
        if surfacedEnvironmentID == environmentID {
            surfacedEnvironmentID = heldEnvironmentIDs.first
        }
        if heldEnvironmentIDs.isEmpty {
            isBackgroundHeld = false
        }
    }

    /// The user turned the preference off. That is not a stop; the app stops
    /// the VM separately and this only removes it from the hold.
    public mutating func preferenceDisabled(_ environmentID: String) {
        environmentStopped(environmentID)
    }

    /// Records which eligible environment the surface currently shows (for
    /// example after paging through several VMs).
    public mutating func surfaceChanged(to environmentID: String?) {
        guard let environmentID, heldEnvironmentIDs.contains(environmentID) else {
            surfacedEnvironmentID = heldEnvironmentIDs.first
            return
        }
        surfacedEnvironmentID = environmentID
    }

    /// The next page for a multi-VM hold, wrapping deterministically.
    public func nextEnvironment(after environmentID: String?) -> String? {
        guard !heldEnvironmentIDs.isEmpty else { return nil }
        guard let environmentID,
              let index = heldEnvironmentIDs.firstIndex(of: environmentID) else {
            return heldEnvironmentIDs.first
        }
        return heldEnvironmentIDs[(index + 1) % heldEnvironmentIDs.count]
    }
}
