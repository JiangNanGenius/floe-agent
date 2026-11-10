// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import FloeWorkbench

struct MediaV2CompositeInspector: View {
    @Bindable var session: MediaV2Session
    let onImport: () -> Void
    @State private var key = MediaVideoChromaKey()
    @State private var keyEnabled = false
    @State private var mode = MediaVideoBlendMode.normal
    @State private var opacity = 1.0
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            MediaV2VisualClipTarget(session: session, onImport: onImport)
            if session.selectedClip?.track.kind == .visual {
                Group {
                if session.tool == "video.chroma" {
                    Toggle(isOn:$keyEnabled) {
                        Label(WorkbenchText.t("启用抠像", "Enable chroma key"), systemImage: "person.and.background.dotted")
                    }.frame(minHeight:44)
                    if keyEnabled {
                        ColorPicker(WorkbenchText.t("取样色", "Key color"),selection:Binding(get:{
                            let c = (try? PreparedVideoColor(hex:key.colorHex)) ?? .white
                            return Color(.sRGB,red:c.red,green:c.green,blue:c.blue)
                        },set:{key.colorHex = hex($0)}),supportsOpacity:false).frame(minHeight:44)
                        HStack(spacing: 12) {
                            Button(WorkbenchText.t("绿幕", "Green screen")) { key.colorHex = "#00FF00" }.frame(minHeight: 44)
                            Button(WorkbenchText.t("蓝幕", "Blue screen")) { key.colorHex = "#0000FF" }.frame(minHeight: 44)
                        }.buttonStyle(.bordered).controlSize(.regular)
                        MusicValueSlider(title:WorkbenchText.t("容差", "Tolerance"),value:key.tolerance,range:0...1) { key.tolerance = $0 }
                        MusicValueSlider(title:WorkbenchText.t("边缘柔化", "Edge softness"),value:key.softness,range:0...1) { key.softness = $0 }
                        MusicValueSlider(title:WorkbenchText.t("去除溢色", "Spill suppression"),value:key.spillSuppression,range:0...1) { key.spillSuppression = $0 }
                    }
                    Text(WorkbenchText.t("取样色会变为透明，显示下方轨道或画布背景。", "The key color becomes transparent, revealing the tracks or canvas below."))
                        .font(.caption).foregroundStyle(.secondary)
                    MediaV2InspectorApplyButton(title: keyEnabled ? WorkbenchText.t("应用抠像", "Apply key") : WorkbenchText.t("移除抠像", "Remove key"), isWorking: session.saving, action: applyKey)
                        .disabled(!keyEnabled && session.selectedClip?.clip.chromaKey == nil)
                } else {
                    Picker(WorkbenchText.t("混合模式", "Blend mode"),selection:$mode) {
                        ForEach(MediaVideoBlendMode.allCases,id:\.self) { value in Text(name(value)).tag(value) }
                    }
                    MusicValueSlider(title:WorkbenchText.t("不透明度", "Opacity"),value:opacity,range:0...1) { opacity = $0 }
                    Text(WorkbenchText.t("与下方轨道混合；降低不透明度可叠加画面。", "Blend with lower tracks; reduce opacity to overlay the image."))
                        .font(.caption).foregroundStyle(.secondary)
                    MediaV2InspectorApplyButton(title: WorkbenchText.t("应用到所选片段", "Apply to selected clip"), isWorking: session.saving, action: applyBlend)
                }
                }.disabled(session.selectedClip?.track.isLocked == true)
            }
        }.disabled(session.saving)
            .onAppear(perform:load).onChange(of:session.selectedClipID) { _,_ in load() }
            .onChange(of:session.selectedClip?.clip.revision) { _,_ in load() }
            .onChange(of:session.tool) { _,_ in load() }
    }
    private func load() {
        key = session.selectedClip?.clip.chromaKey ?? .init()
        keyEnabled = session.selectedClip?.clip.chromaKey != nil
        mode = session.selectedClip?.clip.blendMode ?? .normal;opacity = session.selectedClip?.clip.visualOpacity ?? 1
    }
    private func name(_ mode:MediaVideoBlendMode) -> String {
        switch mode {
        case .normal: WorkbenchText.t("正常", "Normal")
        case .multiply: WorkbenchText.t("正片叠底", "Multiply")
        case .screen: WorkbenchText.t("滤色", "Screen")
        case .overlay: WorkbenchText.t("叠加", "Overlay")
        case .darken: WorkbenchText.t("变暗", "Darken")
        case .lighten: WorkbenchText.t("变亮", "Lighten")
        case .add: WorkbenchText.t("线性减淡（添加）", "Linear dodge (add)")
        case .difference: WorkbenchText.t("差值", "Difference")
        }
    }
    private func hex(_ color:Color) -> String {
        var r:CGFloat = 0,g:CGFloat = 0,b:CGFloat = 0,a:CGFloat = 0
        UIColor(color).getRed(&r,green:&g,blue:&b,alpha:&a)
        return String(format:"#%02X%02X%02X",Int((r*255).rounded()),Int((g*255).rounded()),Int((b*255).rounded()))
    }
    private func applyKey() {
        var input = MediaV2ToolInput();input.chromaKey = key;input.flag = keyEnabled;run("video.chroma",input:input)
    }
    private func applyBlend() {
        var input = MediaV2ToolInput();input.property = mode.rawValue;input.number = opacity;run("video.video-blend",input:input)
    }
    private func run(_ id:String,input:MediaV2ToolInput) {
        var input = input;input.objectID = session.selectedClipID;input.expectedRevision = session.document.revision
        Task { do { _ = try await session.performTool(id,input:input) } catch { session.diagnostic = error.localizedDescription } }
    }
}
#endif
