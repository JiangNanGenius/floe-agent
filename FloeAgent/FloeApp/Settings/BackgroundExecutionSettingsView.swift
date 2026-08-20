// FloeApp — Background execution preference settings.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

/// Lets the user choose how an agent run stays alive when the app is
/// backgrounded: standard lease + continued task, a Picture-in-Picture
/// progress video, or screen sharing with an operation guide.
struct BackgroundExecutionSettingsView: View {
    @ObservedObject var center: SettingsCenter
    @ObservedObject var videoService: BackgroundVideoService

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
            if center.backgroundExecution == .pictureInPicture {
                Section("画中画状态") {
                    Label(
                        videoService.isPiPActive ? "正在显示" :
                            (videoService.isPreparingPiP ? "正在准备" : "等待任务启动"),
                        systemImage: videoService.isPiPActive ? "pip.fill" : "pip"
                    )
                    if let error = videoService.lastError {
                        Text(error)
                            .foregroundStyle(FloeTheme.destructive)
                            .font(.footnote)
                    }
                }
            }
        }
        .navigationTitle("后台执行")
        .task { await center.loadBackgroundExecution() }
    }
}
#endif
