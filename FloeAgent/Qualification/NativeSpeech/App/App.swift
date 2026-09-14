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
                if ProcessInfo.processInfo.arguments.contains("--cancel-retry") {
                    Task { await qualifyCancellation() }
                }
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
    @MainActor private func qualifyCancellation() async {
        var evidence: [String: Any] = ["operation": "cancel running production download, retry and verify"]
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("speech-cancel-evidence.json")
        do {
            await WhisperModelStore.shared.beginInstallation()
            var started = false
            for _ in 0..<60 {
                let state = await WhisperModelStore.shared.installationState()
                if state.running && state.completed > 1_000_000 { started = true; evidence["bytesBeforeCancel"] = state.completed; break }
                if let error = state.error { throw NSError(domain: "SpeechQualification", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
                try await Task.sleep(for: .milliseconds(500))
            }
            guard started else { throw NSError(domain: "SpeechQualification", code: 2, userInfo: [NSLocalizedDescriptionKey: "Download did not enter a cancellable state"]) }
            await WhisperModelStore.shared.cancelInstallation()
            var stopped = false
            for _ in 0..<40 {
                if !(await WhisperModelStore.shared.installationState()).running { stopped = true; break }
                try await Task.sleep(for: .milliseconds(250))
            }
            evidence["cancellationStopped"] = stopped
            guard stopped else { throw NSError(domain: "SpeechQualification", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cancellation did not finish"]) }
            await WhisperModelStore.shared.beginInstallation()
            for _ in 0..<360 {
                let state = await WhisperModelStore.shared.installationState()
                if !state.running {
                    if let error = state.error { throw NSError(domain: "SpeechQualification", code: 4, userInfo: [NSLocalizedDescriptionKey: error]) }
                    let (lease, _) = try await WhisperModelStore.shared.acquire()
                    await WhisperModelStore.shared.release(lease)
                    evidence["retryVerified"] = true
                    evidence["completedBytes"] = state.completed
                    break
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            if evidence["retryVerified"] == nil { throw NSError(domain: "SpeechQualification", code: 5, userInfo: [NSLocalizedDescriptionKey: "Retry did not finish before deadline"]) }
        } catch { evidence["error"] = error.localizedDescription }
        evidence["date"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: destination, options: .atomic)
        }
    }

}
