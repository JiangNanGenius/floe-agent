// FloeCore — shared AlarmKit Live Activity attributes (App + Widget).
//
// SPDX-License-Identifier: MPL-2.0
//
// Single source of truth for the alarm/timer Live Activity contract between
// the App (which schedules through AlarmKit) and the FloeWidgets extension
// (which renders the Live Activity). The system matches the widget
// extension's `ActivityConfiguration` to a scheduled alarm by the exact
// attributes type, so both processes MUST reference the same metadata and
// attributes instantiation — hence this shared definition.
//
// Guard rationale (verified against the installed iOS 27 SDK swiftinterface):
// AlarmKit is `@available(iOS 26.0, *)` and `macCatalyst unavailable`, so the
// whole shape is compiled out where AlarmKit cannot be imported. FloeCore
// stays pure Foundation everywhere else; no ActivityKit/AlarmKit symbols leak
// outside this guard.

#if canImport(AlarmKit) && !targetEnvironment(macCatalyst)
import AlarmKit

/// Live Activity metadata payload for one Floe alarm/timer. Holds only a
/// bounded opaque owner reference — never the raw prompt text — so the
/// activity payload stays privacy-safe. The user-facing title travels in the
/// `AlarmPresentation` (as Apple's model intends); the ledger keeps only an
/// opaque label digest.
public struct FloeSystemAlarmMetadata: AlarmMetadata {
    /// Bounded opaque owner reference (task/run descriptor), not free text.
    public var ownerReference: String

    public init(ownerReference: String) {
        self.ownerReference = ownerReference
    }
}

/// The exact attributes type the App schedules with and the widget renders.
/// `AlarmAttributes` already conforms to `ActivityKit.ActivityAttributes`
/// with `ContentState == AlarmPresentationState`; the system drives the
/// scheduled → countdown → paused → alerting transitions itself.
public typealias FloeSystemAlarmActivityAttributes =
    AlarmAttributes<FloeSystemAlarmMetadata>
#endif
