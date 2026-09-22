// FloeCoreTests — Build 222 per-environment Linux background preference and the
// PiP hold policy it governs.
//
// The properties that matter: exactly one durable preference per environment,
// background preparation of the supported PiP surface for an eligible running
// VM, multi-VM holds that do not reopen PiP after the user closes it, and a
// user PiP close that ends only the current hold — never the preference.

import Foundation
import Testing
@testable import FloeCore

private func ephemeralDefaults(_ label: String) -> UserDefaults {
    let name = "floe.tests.\(label).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("FloeCore.LinuxBackgroundPreference")
struct LinuxBackgroundPreferenceTests {

    @Test("A missing record means background running is not allowed")
    func missingRecordIsDisabled() {
        let preferences = LinuxBackgroundRunPreferences.load(
            from: ephemeralDefaults("pref.missing")
        )
        #expect(preferences.isEmpty)
        #expect(!LinuxBackgroundRunPreferences.isEnabled(
            environmentID: "env-1", in: preferences
        ))
        #expect(LinuxBackgroundRunPreferences.enabledEnvironmentIDs(in: preferences).isEmpty)
    }

    @Test("The per-environment preference round-trips through storage")
    func roundTrip() {
        let defaults = ephemeralDefaults("pref.roundtrip")
        var preferences: [String: LinuxBackgroundRunPreference] = [:]
        preferences["env-1"] = LinuxBackgroundRunPreference(environmentID: "env-1", isEnabled: true)
        preferences["env-2"] = LinuxBackgroundRunPreference(environmentID: "env-2", isEnabled: false)
        LinuxBackgroundRunPreferences.save(preferences, to: defaults)

        let loaded = LinuxBackgroundRunPreferences.load(from: defaults)
        #expect(loaded.count == 2)
        #expect(LinuxBackgroundRunPreferences.isEnabled(environmentID: "env-1", in: loaded))
        #expect(!LinuxBackgroundRunPreferences.isEnabled(environmentID: "env-2", in: loaded))
        #expect(LinuxBackgroundRunPreferences.enabledEnvironmentIDs(in: loaded) == ["env-1"])
    }

    @Test("The legacy keep-alive list migrates once without re-enabling a refusal")
    func legacyMigration() {
        let defaults = ephemeralDefaults("pref.legacy")
        defaults.set(["env-a", "env-b"], forKey: LinuxBackgroundRunPreferences.legacyDefaultsKey)
        // The user already refused background running for env-b in the new
        // model: the migration must not override that explicit decision.
        LinuxBackgroundRunPreferences.save([
            "env-b": LinuxBackgroundRunPreference(environmentID: "env-b", isEnabled: false)
        ], to: defaults)

        #expect(LinuxBackgroundRunPreferences.migrateLegacyIfNeeded(from: defaults))
        let loaded = LinuxBackgroundRunPreferences.load(from: defaults)
        #expect(loaded["env-a"]?.isEnabled == true)
        #expect(loaded["env-b"]?.isEnabled == false)
        // The legacy key is gone, so the migration cannot run twice.
        #expect(defaults.array(forKey: LinuxBackgroundRunPreferences.legacyDefaultsKey) == nil)
        #expect(!LinuxBackgroundRunPreferences.migrateLegacyIfNeeded(from: defaults))
    }

    @Test("A preference that is off stays off across save/load")
    func disabledPreferencePersists() {
        let defaults = ephemeralDefaults("pref.disabled")
        LinuxBackgroundRunPreferences.save([
            "env-1": LinuxBackgroundRunPreference(environmentID: "env-1", isEnabled: true)
        ], to: defaults)
        LinuxBackgroundRunPreferences.save([
            "env-1": LinuxBackgroundRunPreference(environmentID: "env-1", isEnabled: false)
        ], to: defaults)
        let loaded = LinuxBackgroundRunPreferences.load(from: defaults)
        #expect(!LinuxBackgroundRunPreferences.isEnabled(environmentID: "env-1", in: loaded))
    }
}

@Suite("FloeCore.LinuxBackgroundHold")
struct LinuxBackgroundHoldPolicyTests {

    @Test("A background transition prepares the surface for the eligible VM")
    func backgroundPrepares() {
        var policy = LinuxBackgroundHoldPolicy()
        let decision = policy.updateEligibleEnvironmentIDs(["env-1"])
        #expect(decision == .prepareSurface(environmentID: "env-1"))
        #expect(policy.hasActiveHold)
        #expect(policy.surfacedEnvironmentID == "env-1")
        // Re-running the same reconciliation must not restart the surface.
        #expect(policy.updateEligibleEnvironmentIDs(["env-1"]) == .none)
    }

    @Test("No eligible VM means no hold and no surface")
    func noEligibleEnvironment() {
        var policy = LinuxBackgroundHoldPolicy()
        #expect(policy.updateEligibleEnvironmentIDs([]) == .none)
        #expect(!policy.hasActiveHold)
        #expect(policy.surfacedEnvironmentID == nil)
        // A stop leaves no hold behind either.
        _ = policy.updateEligibleEnvironmentIDs(["env-1"])
        policy.environmentStopped("env-1")
        #expect(!policy.hasActiveHold)
        #expect(policy.surfacedEnvironmentID == nil)
    }

    @Test("Foreground retracts the surface but keeps the VM held and running")
    func foregroundRetractsOnly() {
        var policy = LinuxBackgroundHoldPolicy()
        _ = policy.updateEligibleEnvironmentIDs(["env-1"])
        #expect(policy.enteredForeground() == .retractSurface)
        #expect(!policy.isBackgroundHeld)
        // The VM is still eligible (still running); only the floating surface
        // was retracted, so a new background transition prepares it again.
        #expect(policy.heldEnvironmentIDs == ["env-1"])
        #expect(policy.updateEligibleEnvironmentIDs(["env-1"])
            == .prepareSurface(environmentID: "env-1"))
    }

    @Test("A user PiP close ends the hold and stops exactly that VM")
    func closeEndsCurrentHold() {
        var policy = LinuxBackgroundHoldPolicy()
        _ = policy.updateEligibleEnvironmentIDs(["env-1", "env-2"])
        #expect(policy.surfacedEnvironmentID == "env-1")

        let close = policy.userClosedPictureInPicture()
        #expect(close == .endHoldAndStop(environmentID: "env-1"))
        #expect(policy.heldEnvironmentIDs == ["env-2"])
        #expect(policy.surfacedEnvironmentID == "env-2")

        // The VM is still running in the caller's view, but the user's close
        // suppresses reopening for the rest of this hold.
        #expect(policy.updateEligibleEnvironmentIDs(["env-1", "env-2"]) == .none)

        // Once the stopped VM is observed stopped the suppression is
        // forgotten; env-2 is still the page the user did not close.
        #expect(policy.updateEligibleEnvironmentIDs(["env-2"]) == .none)
        #expect(policy.updateEligibleEnvironmentIDs(["env-1", "env-2"]) == .none)
        #expect(policy.heldEnvironmentIDs == ["env-1", "env-2"])

        // A fresh foreground -> background cycle begins a new hold and may
        // prepare the surface again.
        #expect(policy.enteredForeground() == .retractSurface)
        #expect(policy.updateEligibleEnvironmentIDs(["env-1", "env-2"])
            == .prepareSurface(environmentID: "env-1"))
    }

    @Test("A single-VM hold re-arms after that VM is stopped and restarted")
    func singleVMRestartReArms() {
        var policy = LinuxBackgroundHoldPolicy()
        _ = policy.updateEligibleEnvironmentIDs(["env-1"])
        #expect(policy.userClosedPictureInPicture() == .endHoldAndStop(environmentID: "env-1"))
        #expect(!policy.hasActiveHold)
        // The stop has not landed yet: the close still suppresses reopening.
        #expect(policy.updateEligibleEnvironmentIDs(["env-1"]) == .none)
        // Observed stopped, then explicitly restarted: a new hold prepares.
        #expect(policy.updateEligibleEnvironmentIDs([]) == .none)
        #expect(policy.updateEligibleEnvironmentIDs(["env-1"])
            == .prepareSurface(environmentID: "env-1"))
    }

    @Test("A close without a hold is a no-op")
    func closeWithoutHold() {
        var policy = LinuxBackgroundHoldPolicy()
        #expect(policy.userClosedPictureInPicture() == .none)
    }

    @Test("The preference is not part of the hold state")
    func preferenceIsNeverTouchedByHold() {
        var preferences: [String: LinuxBackgroundRunPreference] = [:]
        preferences["env-1"] = LinuxBackgroundRunPreference(environmentID: "env-1", isEnabled: true)

        var policy = LinuxBackgroundHoldPolicy()
        _ = policy.updateEligibleEnvironmentIDs(["env-1"])
        _ = policy.userClosedPictureInPicture()
        _ = policy.enteredForeground()

        // Closing PiP stops the VM through the caller; the preference record
        // is untouched and still enabled.
        #expect(LinuxBackgroundRunPreferences.isEnabled(environmentID: "env-1", in: preferences))
    }

    @Test("A preference turned off removes the environment from the hold")
    func preferenceDisabledRemovesHold() {
        var policy = LinuxBackgroundHoldPolicy()
        _ = policy.updateEligibleEnvironmentIDs(["env-1", "env-2"])
        policy.preferenceDisabled("env-1")
        #expect(policy.heldEnvironmentIDs == ["env-2"])
        #expect(policy.surfacedEnvironmentID == "env-2")
        policy.preferenceDisabled("env-2")
        #expect(!policy.hasActiveHold)
    }

    @Test("Foreground reconciliation keeps membership without preparing")
    func foregroundReconciliation() {
        var policy = LinuxBackgroundHoldPolicy()
        // Membership known while foreground: nothing is prepared and no hold
        // is claimed.
        policy.updateForegroundEligibleEnvironmentIDs(["env-1", "env-2"])
        #expect(policy.heldEnvironmentIDs == ["env-1", "env-2"])
        #expect(!policy.isBackgroundHeld)
        #expect(policy.surfacedEnvironmentID == "env-1")
        // The first background transition then prepares the surface.
        #expect(policy.updateEligibleEnvironmentIDs(["env-1", "env-2"])
            == .prepareSurface(environmentID: "env-1"))
        #expect(policy.isBackgroundHeld)
        // Foreground again: the hold ends, membership stays, and a user's
        // close suppression still applies to its environment.
        #expect(policy.enteredForeground() == .retractSurface)
        policy.updateForegroundEligibleEnvironmentIDs(["env-2"])
        #expect(policy.heldEnvironmentIDs == ["env-2"])
        #expect(!policy.isBackgroundHeld)
        #expect(policy.updateEligibleEnvironmentIDs(["env-2"])
            == .prepareSurface(environmentID: "env-2"))
    }

    @Test("Paging cycles deterministically across held VMs")
    func pagingOrder() {
        var policy = LinuxBackgroundHoldPolicy()
        _ = policy.updateEligibleEnvironmentIDs(["env-1", "env-2", "env-3"])
        #expect(policy.nextEnvironment(after: "env-1") == "env-2")
        #expect(policy.nextEnvironment(after: "env-3") == "env-1")
        #expect(policy.nextEnvironment(after: nil) == "env-1")
        #expect(policy.nextEnvironment(after: "missing") == "env-1")
        policy.surfaceChanged(to: "env-2")
        #expect(policy.surfacedEnvironmentID == "env-2")
        // An environment that is not held cannot become the shown page.
        policy.surfaceChanged(to: "env-9")
        #expect(policy.surfacedEnvironmentID == "env-1")
    }
}
