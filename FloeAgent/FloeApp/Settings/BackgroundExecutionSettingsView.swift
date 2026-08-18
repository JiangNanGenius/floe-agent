// FloeApp — Background execution preference settings.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

/// Lets the user choose how an agent run stays alive when the app is
/// backgrounded: standard lease + continued task, a Picture-in-Picture
/// progress video, or screen sharing with an operation guide.
struct BackgroundExecutionSettingsView: View {
    @ObservedObject var center: SettingsCenter

    var body: some View {
        Form {
            Section {
                Picker("后台执行方式", selection: Binding(
                    get: { center.backgroundExecution },
                    set: { preference in
                        Task { await center.setBackgroundExecution(preference) }
                    }
                )) {
                    ForEach(BackgroundExecutionPreference.allCases, id: \.self) { preference in
                        Text(preference.title).tag(preference)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("agent.background_execution")
            } footer: {
                Text(center.backgroundExecution.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("后台执行")
        .task { await center.loadBackgroundExecution() }
    }
}
#endif
