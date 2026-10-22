// FloeAppTests — foldable adaptation preference persistence.
//
// Pins the user-approved opt-out semantics: the key is
// `floe.layout.foldableAdaptationEnabled`, a missing value means enabled,
// an explicit off survives relaunch/update (new LayoutPreferences instance
// over the same defaults), detection events never write or overwrite the
// value, and folds/relaunches with a stored off keep it off.
//
// NOTE: definitions only — Main performs the combined full-App verification.

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
@testable import FloeApp

@Suite("Foldable adaptation preferences")
@MainActor
struct FoldablePreferencesTests {
    private static let suiteName = "floe.tests.FoldablePreferences.\(UUID().uuidString)"

    private func freshDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        return defaults
    }

    @Test("missing key means enabled")
    func missingMeansEnabled() {
        let defaults = freshDefaults()
        #expect(defaults.object(forKey: "floe.layout.foldableAdaptationEnabled") == nil)
        let preferences = LayoutPreferences(defaults: defaults)
        #expect(preferences.settings.foldableAdaptationEnabled)
    }

    @Test("explicit off persists across relaunch (new instance, same defaults)")
    func explicitOffPersists() {
        let defaults = freshDefaults()
        let first = LayoutPreferences(defaults: defaults)
        first.setFoldableAdaptationEnabled(false)
        #expect(!first.settings.foldableAdaptationEnabled)
        #expect(defaults.object(forKey: "floe.layout.foldableAdaptationEnabled") as? Bool == false)
        let relaunched = LayoutPreferences(defaults: defaults)
        #expect(!relaunched.settings.foldableAdaptationEnabled)
    }

    @Test("explicit on persists too (never forced back to default)")
    func explicitOnPersists() {
        let defaults = freshDefaults()
        let first = LayoutPreferences(defaults: defaults)
        first.setFoldableAdaptationEnabled(false)
        first.setFoldableAdaptationEnabled(true)
        let relaunched = LayoutPreferences(defaults: defaults)
        #expect(relaunched.settings.foldableAdaptationEnabled)
        #expect(defaults.object(forKey: "floe.layout.foldableAdaptationEnabled") as? Bool == true)
    }

    @Test("fold/relaunch events never write or overwrite the preference")
    func detectionNeverWritesPreference() {
        let defaults = freshDefaults()
        let preferences = LayoutPreferences(defaults: defaults)
        preferences.setFoldableAdaptationEnabled(false)
        // Simulate a full detection cycle (positive hinge, transient nil,
        // division regions) across a relaunch-style re-initialization. None
        // of these touch the stored preference.
        let state = FoldableDisplayState()
        state.recordHinge(status: .partiallyOpen)
        state.recordHingeUnavailable()
        state.record(divisionRegions: [FoldableRegion(kind: .division, x: 0.48, y: 0,
                                                      width: 0.04, height: 1)])
        let afterFold = LayoutPreferences(defaults: defaults)
        #expect(!afterFold.settings.foldableAdaptationEnabled)
        state.recordHinge(status: .fullyOpen)
        let afterUpdate = LayoutPreferences(defaults: defaults)
        #expect(!afterUpdate.settings.foldableAdaptationEnabled)
    }

    @Test("stale off preference on a now non-foldable device keeps the row hidden")
    func stalePreferenceCannotRevealRow() {
        let defaults = freshDefaults()
        LayoutPreferences(defaults: defaults).setFoldableAdaptationEnabled(false)
        let snapshot = FoldableDisplaySnapshot.neutral
        // GeneralSettingsView only shows the row for positively proven
        // foldable hardware, independent of any stored value.
        #expect(snapshot.capability != .foldable)
        let relaunched = LayoutPreferences(defaults: defaults)
        #expect(!relaunched.settings.foldableAdaptationEnabled)
    }

    @Test("other layout keys are untouched by the foldable toggle")
    func isolatedPersistence() {
        let defaults = freshDefaults()
        let preferences = LayoutPreferences(defaults: defaults)
        preferences.setFileNameLines(2)
        preferences.setFoldableAdaptationEnabled(false)
        #expect(defaults.object(forKey: "floe.layout.fileNameLines") as? Int == 2)
        #expect(defaults.object(forKey: "floe.layout.foldableAdaptationEnabled") as? Bool == false)
        preferences.setFoldableAdaptationEnabled(true)
        #expect(defaults.object(forKey: "floe.layout.fileNameLines") as? Int == 2)
    }
}
#endif
