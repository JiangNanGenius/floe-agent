// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeWorkbench

struct MediaV2HDRInspector: View {
    @Bindable var session: MediaV2Session
    @State private var profile = "standard"
    var body: some View {
        VStack(alignment: .leading,spacing: 14) {
            Label(WorkbenchText.t("视频颜色格式", "Video color format"),systemImage: "circle.lefthalf.filled").font(.subheadline.weight(.semibold))
            Picker(WorkbenchText.t("颜色格式", "Color format"),selection: $profile) {
                Text(WorkbenchText.t("标准 SDR", "Standard SDR")).tag("standard")
                Text("Rec.709").tag(MediaVideoColorProfile.rec709.rawValue)
                Text("HDR · HLG").tag(MediaVideoColorProfile.rec2020HLG.rawValue)
                Text("HDR · PQ").tag(MediaVideoColorProfile.rec2020PQ.rawValue)
            }.frame(minHeight: 44).disabled(busy)
            VStack(alignment: .leading,spacing: 8) {
                if MediaVideoColorProfile(rawValue: profile)?.isHDR == true {
                    Label(WorkbenchText.t("高动态范围", "High dynamic range"),systemImage: "sun.max.fill")
                    LabeledContent(WorkbenchText.t("色域", "Color gamut"),value: "Rec.2020")
                    LabeledContent(WorkbenchText.t("导出", "Export"),value: "HEVC · 10-bit")
                } else {
                    Label(WorkbenchText.t("标准动态范围", "Standard dynamic range"),systemImage: "sun.max")
                    LabeledContent(WorkbenchText.t("导出", "Export"),value: "H.264 · 8-bit")
                }
            }.font(.caption).foregroundStyle(.secondary)
            Text(WorkbenchText.t("预览与导出使用同一颜色格式，原素材保持不变。", "Preview and export use the same color format. Original media is preserved."))
                .font(.caption).foregroundStyle(.secondary)
            if session.processingTool {
                ProgressView(session.providerStatus ?? WorkbenchText.t("正在设置…", "Applying…"))
                Button(WorkbenchText.t("取消", "Cancel"),systemImage: "xmark.circle") { session.cancelToolProcessing() }.frame(minHeight: 44)
            } else {
                MediaV2InspectorApplyButton(title: WorkbenchText.t("应用到整个视频", "Apply to video"),isWorking: session.saving) { run(profile) }
                    .disabled(busy || profile == current).accessibilityIdentifier("media.v2.hdr.apply")
                Button(WorkbenchText.t("匹配所选素材", "Match selected source"),systemImage: "viewfinder") { run("source") }
                    .frame(minHeight: 44).disabled(busy || session.selectedClip?.clip.assetID == nil)
            }
        }.onAppear { profile = current }
            .onChange(of: current) { _,value in profile = value }
    }
    private var busy: Bool { session.processingTool || session.saving || session.rendering }
    private var current: String { session.document.canvas?.videoColorProfile?.rawValue ?? "standard" }
    private func run(_ value: String) {
        var input = MediaV2ToolInput();input.expectedRevision = session.document.revision;input.property = value
        if value == "source" { input.objectID = session.selectedClipID }
        Task { do { _ = try await session.performTool("video.hdr",input: input) } catch { session.diagnostic = error.localizedDescription } }
    }
}
#endif
