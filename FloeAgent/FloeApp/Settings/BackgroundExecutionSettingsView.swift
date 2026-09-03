// FloeApp — Background execution preference settings.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

/// Lets the user choose how an agent run stays alive when the app is
/// backgrounded: continued processing, optional user-started PiP progress,
/// or screen sharing with an operation guide.
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
                        videoService.preparationState.localizedDescription,
                        systemImage: videoService.isPiPActive ? "pip.fill" : "pip"
                    )
                    if let error = videoService.lastError {
                        Text(error)
                            .foregroundStyle(FloeTheme.destructive)
                            .font(.footnote)
                    }
                    Text("画中画不会因切换应用自动弹出。任务运行时，请从任务或画布工具栏手动启动；普通后台任务仍由系统后台处理继续。")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("后台执行")
        .task { await center.loadBackgroundExecution() }
    }
}
#endif
