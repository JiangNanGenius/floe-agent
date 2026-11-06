#if DEBUG
import SwiftUI

/// Silent fixture host for previews: records events, produces no sound.
/// Preset names are neutral placeholders so the preview never advertises a
/// soundbank it does not have.
@MainActor
@Observable
private final class PreviewKeyboardHost {
    let sink = RecordingKeyboardSink()
    let controller: KeyboardPerformanceController

    var selectedPreset: String? = "tone-a"
    var volume: Float = 0.8
    var filter: Float = 0.5

    init() {
        controller = KeyboardPerformanceController(
            owner: KeyboardOwnerToken("preview-track"),
            sink: sink
        )
    }

    var toneSurface: KeyboardToneControlSurface {
        KeyboardToneControlSurface(
            presets: [
                KeyboardPresetDescriptor(id: "tone-a", displayName: "Tone A", detail: "Preview fixture"),
                KeyboardPresetDescriptor(id: "tone-b", displayName: "Tone B", detail: "Preview fixture")
            ],
            selectedPresetID: Binding(
                get: { [weak self] in self?.selectedPreset },
                set: { [weak self] in self?.selectedPreset = $0 }
            ),
            volume: KeyboardParameterControl(value: Binding(
                get: { [weak self] in self?.volume ?? 0 },
                set: { [weak self] in self?.volume = $0 }
            )),
            filterCutoff: KeyboardParameterControl(value: Binding(
                get: { [weak self] in self?.filter ?? 0 },
                set: { [weak self] in self?.filter = $0 }
            ))
        )
    }
}

@MainActor
private struct PreviewEventLog: View {
    let sink: RecordingKeyboardSink

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recorded events (silent fixture)")
                .font(.caption.bold())
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(sink.events.enumerated().reversed().prefix(12)), id: \.offset) { _, event in
                        Text(String(describing: event))
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxHeight: 140)
        }
        .padding(8)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

@MainActor
private struct PreviewPanel: View {
    @State private var host = PreviewKeyboardHost()
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 16) {
            ElectronicKeyboardPanel(
                controller: host.controller,
                configuration: .default,
                toneSurface: host.toneSurface,
                onExpand: { isExpanded = true }
            )
            PreviewEventLog(sink: host.sink)
        }
        .padding()
        .keyboardPreviewPresentation(isPresented: $isExpanded) {
            VStack {
                ElectronicKeyboardPanel(
                    controller: host.controller,
                    configuration: KeyboardPanelConfiguration(keyCount: 37),
                    toneSurface: host.toneSurface,
                    onCollapse: { isExpanded = false }
                )
                PreviewEventLog(sink: host.sink)
            }
            .padding()
            .background(.background)
        }
    }
}

@MainActor
private extension View {
    @ViewBuilder
    func keyboardPreviewPresentation<Content: View>(isPresented: Binding<Bool>,
                                                    @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(macOS)
        sheet(isPresented: isPresented, content: content)
        #else
        fullScreenCover(isPresented: isPresented, content: content)
        #endif
    }
}

#Preview("Default — iPad") {
    PreviewPanel()
        .frame(width: 820, height: 480)
}

#Preview("Compact — iPhone") {
    PreviewPanel()
        .frame(width: 390, height: 420)
}

#Preview("Dark") {
    PreviewPanel()
        .frame(width: 820, height: 480)
        .preferredColorScheme(.dark)
}
#endif
