// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

struct MediaV2ProviderConfigurationView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                NavigationLink { ProviderListView(center:environment.conversationCenter) } label: { Label(WorkbenchText.t("模型与服务商", "Models and providers"),systemImage:"cpu") }
                NavigationLink { AuxiliaryModelsView(center:environment.conversationCenter) } label: { Label(WorkbenchText.t("图像与辅助模型", "Image and auxiliary models"),systemImage:"photo.badge.plus") }
                NavigationLink { SpeechInputSettingsView() } label: { Label(WorkbenchText.t("语音识别", "Speech recognition"),systemImage:"waveform.badge.mic") }
            }.navigationTitle(WorkbenchText.t("媒体 AI 服务", "Media AI services"))
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button(WorkbenchText.t("完成", "Done")) { dismiss() } } }
        }
    }
}
#endif
