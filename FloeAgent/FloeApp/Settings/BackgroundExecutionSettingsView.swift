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
                Picker("后台执行方式", selection: Binding(
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
                        Text("此版本未启用状态画中画：选择画中画会改用普通后台任务（持续处理 + 检查点恢复）。")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if center.backgroundExecution == .pictureInPicture, statusPiPEnabled {
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
                    Text("任务运行时，画面只嵌在任务或画布工具栏内；离开 Floe 时，系统会自动进入画中画，也可在工具栏手动启动或关闭。Floe 在前台时不会创建独立悬浮卡片。")
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
