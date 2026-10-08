// FloeApp — Background execution preference settings.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

/// Lets the user choose how an agent run stays alive when the app is
/// backgrounded: continued processing, inline-to-system PiP progress, or
/// screen sharing with an operation guide.
///
/// The default path is the compliant system continued-processing task (the
/// system Live Activity). Status Picture-in-Picture is an *opt-in* surface
/// behind `StatusPiPReleaseGate`; when the gate disables it, the PiP row is
/// hidden and a PiP choice degrades to standard processing instead of
/// creating a controller.
struct BackgroundExecutionSettingsView: View {
    @ObservedObject var center: SettingsCenter
    @ObservedObject var videoService: BackgroundVideoService

    private var statusPiPEnabled: Bool { StatusPiPReleaseGate.isEnabled }

    private var availablePreferences: [BackgroundExecutionPreference] {
        BackgroundExecutionPreference.allCases.filter {
            $0 != .pictureInPicture || statusPiPEnabled
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("agent.background_execution", selection: Binding(
                    get: { center.backgroundExecution },
                    set: { preference in
                        Task { await center.setBackgroundExecution(preference) }
                    }
                )) {
                    ForEach(availablePreferences, id: \.self) { preference in
                        Text(preference.title).tag(preference)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("agent.background_execution")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(center.backgroundExecution.subtitle)
                    if !statusPiPEnabled {
                        Text("background.pip_unavailable")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if center.backgroundExecution == .pictureInPicture, statusPiPEnabled {
                Section {
                    Label(
                        videoService.preparationState.localizedDescription,
                        systemImage: videoService.isPiPActive ? "pip.fill" : "pip"
                    )
                    if let error = videoService.lastError {
                        Text(error)
                            .foregroundStyle(FloeTheme.destructive)
                            .font(.footnote)
                    }
                    Text("background.pip_note")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                } header: {
                    Text("background.pip_section")
                }
            }
        }
        .navigationTitle(FloeL10n.l("background.settings.title"))
        .task { await center.loadBackgroundExecution() }
    }
}
#endif
