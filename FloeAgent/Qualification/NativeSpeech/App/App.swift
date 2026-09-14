import SwiftUI
import UIKit

final class SpeechDownloadDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task { await WhisperModelStore.shared.restoreInstallation() }
        return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier == WhisperDownloadCoordinator.identifier {
            WhisperDownloadCoordinator.shared.registerBackgroundCompletion(completionHandler)
        } else { completionHandler() }
    }
}

/// Actual production settings/store/download coordinator and pinned assets.
/// This target qualifies transfers, not Whisper model inference.
@main struct SpeechDownloadSmokeApp: App {
    @UIApplicationDelegateAdaptor(SpeechDownloadDelegate.self) private var delegate
    @State private var showSettings = false
    @State private var status = "尚未开始"
    @State private var verified = false
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section("语音下载验证") {
                        Button("语音识别设置") { showSettings = true }
                        Text(status)
                        Text("关闭设置页后，下载任务由生产 WhisperModelStore 继续持有。此验证不执行语音推理。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.navigationTitle("下载验证")
                    .navigationDestination(isPresented: $showSettings) { WhisperSettingsView() }
            }
            .task {
                var samples: [[String: Any]] = []
                let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("speech-download-evidence.json")
                while !Task.isCancelled {
                    let state = await WhisperModelStore.shared.installationState()
                    let installed = await WhisperModelStore.shared.isInstalled()
                    if state.running { verified = false }
                    if installed && !state.running && !verified {
                        do {
                            let (lease, _) = try await WhisperModelStore.shared.acquire()
                            await WhisperModelStore.shared.release(lease)
                            verified = true
                        } catch { status = "安装后校验失败：\(error.localizedDescription)" }
                    }
                    status = state.error ?? (verified ? "全部文件校验通过" : "\(state.running ? "下载中" : "等待下载") · \(state.completed) / \(state.total)")
                    samples.append(["date": ISO8601DateFormatter().string(from: Date()),
                        "settingsVisible": showSettings, "running": state.running,
                        "bytes": state.completed, "total": state.total, "installed": installed,
                        "verified": verified, "error": state.error ?? ""])
                    if samples.count > 1800 { samples.removeFirst() }
                    if let data = try? JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: destination, options: .atomic)
                    }
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                }
            }
        }
    }
}
