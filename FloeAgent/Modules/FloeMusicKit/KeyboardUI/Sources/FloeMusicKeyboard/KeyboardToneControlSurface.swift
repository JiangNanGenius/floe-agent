import Foundation
import SwiftUI

/// A host-supplied preset/tone choice shown in the panel's control surface.
/// The descriptor names the choice only; producing the sound is always the
/// host's job, so the panel never advertises soundbanks it cannot license.
public struct KeyboardPresetDescriptor: Hashable, Sendable, Identifiable {
    public var id: String
    /// Short localized name, e.g. "Grand Piano" / "三角钢琴".
    public var displayName: String
    /// Optional secondary line, e.g. the providing source ("AUv3", "Sampler").
    public var detail: String?

    public init(id: String, displayName: String, detail: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
    }
}

/// Optional tone parameter exposed to the panel. `nil` means unsupported —
/// the panel hides the control instead of showing a fake knob.
@MainActor
public struct KeyboardParameterControl {
    public var value: Binding<Float>

    public init(value: Binding<Float>) {
        self.value = value
    }
}

/// Host-injected tone control surface for the upper panel row.
///
/// Availability is explicit: every control is optional and only rendered when
/// the host provides a binding. Parameter values are normalized 0...1 unless
/// documented otherwise by the host; the panel does not invent synth
/// semantics.
@MainActor
public struct KeyboardToneControlSurface {
    /// Selectable presets, in display order.
    public var presets: [KeyboardPresetDescriptor]
    /// Currently selected preset, if any.
    public var selectedPresetID: Binding<String?>
    /// Normalized 0...1.
    public var volume: KeyboardParameterControl?
    /// Normalized 0...1.
    public var filterCutoff: KeyboardParameterControl?
    /// Normalized 0...1.
    public var attack: KeyboardParameterControl?
    /// Normalized 0...1.
    public var release: KeyboardParameterControl?
    /// Normalized 0...1.
    public var effectMix: KeyboardParameterControl?

    public init(
        presets: [KeyboardPresetDescriptor] = [],
        selectedPresetID: Binding<String?> = .constant(nil),
        volume: KeyboardParameterControl? = nil,
        filterCutoff: KeyboardParameterControl? = nil,
        attack: KeyboardParameterControl? = nil,
        release: KeyboardParameterControl? = nil,
        effectMix: KeyboardParameterControl? = nil
    ) {
        self.presets = presets
        self.selectedPresetID = selectedPresetID
        self.volume = volume
        self.filterCutoff = filterCutoff
        self.attack = attack
        self.release = release
        self.effectMix = effectMix
    }

    /// A surface with no controls; the panel then hides the whole tone row.
    public static let unavailable = KeyboardToneControlSurface()
}
