import Keyboard
import SwiftUI
import Tonic

/// Static layout configuration for `ElectronicKeyboardPanel`.
public struct KeyboardPanelConfiguration: Hashable, Sendable {
    /// Lowest key of the panel, as a MIDI note number. Default C3 (48).
    public var lowestNote: UInt8
    /// Number of keys shown. Default 25 — two octaves plus the root, matching
    /// the accepted design. Clamped to 7...61.
    public var keyCount: Int
    public var showsPitchBendWheel: Bool
    public var showsModulationWheel: Bool
    public var showsSustainControl: Bool
    public var showsToneControls: Bool
    public var showsExpandControl: Bool

    public init(
        lowestNote: UInt8 = 48,
        keyCount: Int = 25,
        showsPitchBendWheel: Bool = true,
        showsModulationWheel: Bool = true,
        showsSustainControl: Bool = true,
        showsToneControls: Bool = true,
        showsExpandControl: Bool = true
    ) {
        self.lowestNote = lowestNote
        self.keyCount = keyCount
        self.showsPitchBendWheel = showsPitchBendWheel
        self.showsModulationWheel = showsModulationWheel
        self.showsSustainControl = showsSustainControl
        self.showsToneControls = showsToneControls
        self.showsExpandControl = showsExpandControl
    }

    public static let `default` = KeyboardPanelConfiguration()

    var keyRange: ClosedRange<Pitch> {
        let low = min(115, max(0, Int(lowestNote)))
        let count = min(61, max(7, keyCount))
        return Pitch(intValue: low) ... Pitch(intValue: min(127, low + count - 1))
    }
}

/// Reusable electronic-keyboard performance panel.
///
/// Compose this inside a host detail pane. The panel renders the upstream
/// AudioKit `Keyboard` keys plus a left pitch-bend / modulation rail and an
/// upper tone-control surface, and forwards performance to the injected
/// controller's sink. It owns no audio engine, no audio session and no
/// storage; expanding/collapsing and preset wiring are host-driven.
public struct ElectronicKeyboardPanel: View {
    @Bindable private var controller: KeyboardPerformanceController
    private var configuration: KeyboardPanelConfiguration
    private var toneSurface: KeyboardToneControlSurface
    private var onExpand: (() -> Void)?
    private var onCollapse: (() -> Void)?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(
        controller: KeyboardPerformanceController,
        configuration: KeyboardPanelConfiguration = .default,
        toneSurface: KeyboardToneControlSurface = .unavailable,
        onExpand: (() -> Void)? = nil,
        onCollapse: (() -> Void)? = nil
    ) {
        self._controller = Bindable(controller)
        self.configuration = configuration
        self.toneSurface = toneSurface
        self.onExpand = onExpand
        self.onCollapse = onCollapse
    }

    public var body: some View {
        VStack(spacing: 12) {
            if configuration.showsToneControls {
                controlSurface
            }
            HStack(spacing: 10) {
                if configuration.showsPitchBendWheel || configuration.showsModulationWheel {
                    wheelRail
                }
                keybed
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, configuration.showsToneControls ? 12 : 10)
        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("floe.music.keyboard.panel")
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                controller.releaseAll(reason: .sceneBecameInactive)
            }
        }
        .onDisappear {
            controller.releaseAll(reason: .panelClosed)
        }
    }

    // MARK: - Control surface

    private var controlSurface: some View {
        HStack(spacing: 12) {
            presetMenu
            if horizontalSizeClass == .regular {
                parameterRow
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    parameterRow
                }
            }
            if configuration.showsSustainControl {
                Toggle(kbLocalized("keyboard.sustain"), isOn: $controller.sustain)
                    .toggleStyle(.button)
                    .fixedSize()
                    .accessibilityIdentifier("floe.music.keyboard.sustain")
            }
            if configuration.showsExpandControl, let collapse = onCollapse {
                Button(action: collapse) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .accessibilityLabel(kbLocalized("keyboard.collapse"))
                .accessibilityIdentifier("floe.music.keyboard.expand")
            } else if configuration.showsExpandControl, let expand = onExpand {
                Button(action: expand) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel(kbLocalized("keyboard.expand"))
                .accessibilityIdentifier("floe.music.keyboard.expand")
            }
        }
        .frame(minHeight: 44)
    }

    private var presetMenu: some View {
        Menu {
            if toneSurface.presets.isEmpty {
                Text(kbLocalized("keyboard.noPresets"))
            } else {
                ForEach(toneSurface.presets) { preset in
                    Button {
                        toneSurface.selectedPresetID.wrappedValue = preset.id
                        controller.presetDidChange()
                    } label: {
                        HStack {
                            Text(preset.displayName)
                            if toneSurface.selectedPresetID.wrappedValue == preset.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            Label(selectedPresetName, systemImage: "pianokeys")
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("floe.music.keyboard.preset")
    }

    private var selectedPresetName: String {
        guard let id = toneSurface.selectedPresetID.wrappedValue,
              let preset = toneSurface.presets.first(where: { $0.id == id })
        else { return kbLocalized("keyboard.tone") }
        return preset.displayName
    }

    private var parameterRow: some View {
        HStack(spacing: 16) {
            if let volume = toneSurface.volume {
                parameterSlider(title: kbLocalized("keyboard.volume"), value: volume.value)
            }
            if let filter = toneSurface.filterCutoff {
                parameterSlider(title: kbLocalized("keyboard.filter"), value: filter.value)
            }
            if let attack = toneSurface.attack {
                parameterSlider(title: kbLocalized("keyboard.attack"), value: attack.value)
            }
            if let release = toneSurface.release {
                parameterSlider(title: kbLocalized("keyboard.release"), value: release.value)
            }
            if let effect = toneSurface.effectMix {
                parameterSlider(title: kbLocalized("keyboard.effect"), value: effect.value)
            }
        }
    }

    private func parameterSlider(title: String, value: Binding<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).lineLimit(1)
            Slider(value: value, in: 0...1)
                .frame(width: 120)
                .accessibilityLabel(title)
        }
        .frame(minHeight: 44)
    }

    // MARK: - Wheels

    private var wheelRail: some View {
        HStack(spacing: 8) {
            if configuration.showsPitchBendWheel {
                PerformanceWheel(value: $controller.pitchBend, range: -1 ... 1, behavior: .springToCenter)
                    .frame(width: 44)
                    .accessibilityLabel(kbLocalized("keyboard.pitchbend"))
                    .accessibilityIdentifier("floe.music.keyboard.pitchBend")
            }
            if configuration.showsModulationWheel {
                PerformanceWheel(value: $controller.modulation, range: 0 ... 1, behavior: .latch)
                    .frame(width: 44)
                    .accessibilityLabel(kbLocalized("keyboard.modulation"))
                    .accessibilityIdentifier("floe.music.keyboard.modulation")
            }
        }
        .frame(minHeight: 120)
        .layoutPriority(-1)
    }

    // MARK: - Keybed

    private var keybed: some View {
        Keyboard(
            layout: .piano(pitchRange: configuration.keyRange),
            latching: false,
            noteOn: { pitch, point in
                controller.keyDown(sourcePitch: pitch.intValue, normalizedPoint: point)
            },
            noteOff: { pitch in
                controller.keyUp(sourcePitch: pitch.intValue)
            }
        ) { pitch, isActivated in
            KeyboardKey(
                pitch: pitch,
                isActivated: isActivated,
                whiteKeyColor: .white,
                blackKeyColor: Color(.black),
                pressedColor: .accentColor,
                flatTop: true,
                alignment: .bottom
            )
            .overlay {
                if pitch.note(in: .C).accidental == .natural {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.black.opacity(0.24), lineWidth: 1)
                        .padding(.trailing, 0.5)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(pitch.note(in: .C).description)
            .accessibilityIdentifier("floe.music.keyboard.key.\(pitch.intValue)")
        }
        // Reset the upstream model whenever the key range or the controller
        // identity changes, so no stale touch state survives the swap.
        .id("\(configuration.lowestNote)-\(configuration.keyCount)-\(ObjectIdentifier(controller))")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("floe.music.keyboard.keybed")
    }
}
