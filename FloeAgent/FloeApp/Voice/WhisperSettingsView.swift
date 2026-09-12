// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

struct WhisperSettingsView: View {
    @State private var installed = false
    @State private var completed: Int64 = 0
    @State private var total: Int64 = 0
    @State private var operation: Task<Void, Never>?
    @State private var failure: String?
    var body: some View {
        Form {
            Section("本地识别") {
                Label("Whisper Small · 多语言", systemImage: "waveform")
                Text("英语、普通话及混合语音优先使用本地 Whisper；模型不可用或识别失败时回退 Apple 语音识别。")
                Text(installed ? "模型已安装，运行时仍需检查能否加载。" : "尚未安装，当前使用 Apple 语音识别。")
                    .font(.caption).foregroundStyle(.secondary)
                if let operation {
                    ProgressView(value: Double(completed), total: Double(max(1, total)))
                    Text("已校验 \(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                        .font(.caption)
                    Button("取消下载", role: .cancel) { operation.cancel() }
                } else {
                    Button(installed ? "重新下载模型" : "下载模型") {
                        operation = Task {
                            defer { operation = nil }
                            do {
                                failure = nil; completed = 0
                                try await WhisperModelStore.shared.install { done, expected in
                                    Task { @MainActor in completed = done; total = expected }
                                }
                                installed = await WhisperModelStore.shared.isInstalled()
                            } catch is CancellationError {} catch { failure = error.localizedDescription }
                        }
                    }
                    if installed {
                        Button("移除模型", role: .destructive) {
                            Task {
                                do { try await WhisperModelStore.shared.remove(); installed = false }
                                catch { failure = error.localizedDescription }
                            }
                        }
                    }
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            Section {
                Text("下载会占用约 500 MB 空间。音频不会上传给 Whisper 服务；Apple 回退路径遵循系统语音服务和权限设置。长录音的识别速度取决于设备性能。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("语音识别")
            .task {
                installed = await WhisperModelStore.shared.isInstalled()
                if let manifest = try? await WhisperModelStore.shared.manifest() { total = manifest.files.reduce(0) { $0 + $1.byteCount } }
            }
            .onDisappear { operation?.cancel() }
    }
}
#endif
