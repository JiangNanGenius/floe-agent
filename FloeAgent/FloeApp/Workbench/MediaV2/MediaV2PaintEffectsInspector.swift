// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import FloeWorkbench

struct MediaV2PaintEffectsInspector: View {
    @Bindable var session: MediaV2Session
    @State private var outline = 3.0
    @State private var shadow = true
    @State private var shadowRadius = 8.0
    @State private var shadowColor = Color.black.opacity(0.5)
    @State private var offsetX = 8.0
    @State private var offsetY = 8.0
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            if session.tool == "image.gradient" {
                ColorPicker(WorkbenchText.t("起点颜色", "Start color"),selection:colorBinding(\.colorHex),supportsOpacity:true).frame(minHeight:44)
                ColorPicker(WorkbenchText.t("终点颜色", "End color"),selection:colorBinding(\.gradientLastHex),supportsOpacity:true).frame(minHeight:44)
                Toggle(WorkbenchText.t("径向渐变", "Radial gradient"),isOn:$session.gradientRadial).frame(minHeight:44)
                MusicValueSlider(title:WorkbenchText.t("不透明度", "Opacity"),value:session.brushOpacity,range:0...1) { session.brushOpacity = $0 }
                Text(WorkbenchText.t("在画布上从起点拖到终点绘制渐变。", "Drag from the start to the end on the canvas.")).font(.caption).foregroundStyle(.secondary)
            } else if session.tool == "image.layer-effect" {
                ColorPicker(WorkbenchText.t("描边颜色", "Outline color"),selection:colorBinding(\.colorHex),supportsOpacity:true).frame(minHeight:44)
                MusicValueSlider(title:WorkbenchText.t("描边宽度", "Outline width"),value:outline,range:0...200,suffix:"px") { outline = $0 }
                Toggle(WorkbenchText.t("阴影", "Shadow"),isOn:$shadow).frame(minHeight:44)
                if shadow {
                    ColorPicker(WorkbenchText.t("阴影颜色", "Shadow color"),selection:$shadowColor,supportsOpacity:true).frame(minHeight:44)
                    MusicValueSlider(title:WorkbenchText.t("阴影模糊", "Shadow blur"),value:shadowRadius,range:0...200,suffix:"px") { shadowRadius = $0 }
                    MediaV2NumberField(title:WorkbenchText.t("水平偏移", "Horizontal offset"),value:$offsetX,suffix:"px")
                    MediaV2NumberField(title:WorkbenchText.t("垂直偏移", "Vertical offset"),value:$offsetY,suffix:"px")
                }
                Button(WorkbenchText.t("应用到所选图层", "Apply to selected layer"),action:applyEffect).frame(minHeight:44).disabled(session.selectedLayer == nil)
            } else if ["image.heal","image.patch"].contains(session.tool) {
                if session.tool == "image.heal" {
                    Button(session.clonePickSource ? WorkbenchText.t("点击画布选择取样点", "Tap the canvas to sample") : WorkbenchText.t("设置修复取样点", "Set healing sample")) { session.clonePickSource.toggle() }.frame(minHeight:44)
                    MusicValueSlider(title:WorkbenchText.t("画笔大小", "Brush size"),value:session.brushWidth,range:1...200,suffix:"px") { session.brushWidth = $0 }
                    Text(WorkbenchText.t("设置取样点后，涂抹需要修复的区域。", "Set a sample point, then brush over the area to repair.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(WorkbenchText.t("先选中目标区域，再将它拖向合适的取样区域。", "Select the target area, then drag it toward a suitable source area.")).font(.caption).foregroundStyle(.secondary)
                    if session.selection == nil { Text(WorkbenchText.t("请先用选区工具选择目标。", "Select the target with a selection tool first.")).font(.caption).foregroundStyle(.secondary) }
                }
                MusicValueSlider(title:WorkbenchText.t("修复强度", "Repair strength"),value:session.repairStrength,range:0...1) { session.repairStrength = $0 }
            } else if ["image.smudge","image.clone"].contains(session.tool) {
                if session.tool == "image.clone" {
                    Button(session.clonePickSource ? WorkbenchText.t("点击画布选择取样点", "Tap the canvas to sample") : WorkbenchText.t("设置取样点", "Set sample point")) { session.clonePickSource.toggle() }.frame(minHeight:44)
                    Toggle(WorkbenchText.t("对齐取样", "Aligned sampling"),isOn:$session.cloneAligned).frame(minHeight:44)
                    if let p = session.cloneSourcePoint { Text(String(format:WorkbenchText.t("取样点 %.0f%%, %.0f%%", "Sample %.0f%%, %.0f%%"),p.x*100,p.y*100)).font(.caption).monospacedDigit() }
                }
                MusicValueSlider(title:WorkbenchText.t("画笔大小", "Brush size"),value:session.brushWidth,range:1...200,suffix:"px") { session.brushWidth = $0 }
                MusicValueSlider(title:WorkbenchText.t("强度", "Strength"),value:session.sampleBrushStrength,range:0...1) { session.sampleBrushStrength = $0 }
                MusicValueSlider(title:WorkbenchText.t("硬度", "Hardness"),value:session.brushHardness,range:0...1) { session.brushHardness = $0 }
            } else {
                MusicValueSlider(title:WorkbenchText.t("画笔大小", "Brush size"),value:session.brushWidth,range:1...200,suffix:"px") { session.brushWidth = $0 }
                MusicValueSlider(title:session.tool == "image.blur-brush" ? WorkbenchText.t("模糊半径", "Blur radius") : WorkbenchText.t("锐化强度", "Sharpness"),
                    value:session.brushEffectAmount,range:0...100) { session.brushEffectAmount = $0 }
                MusicValueSlider(title:WorkbenchText.t("不透明度", "Opacity"),value:session.brushOpacity,range:0...1) { session.brushOpacity = $0 }
                Text(WorkbenchText.t("在画布上涂抹要处理的区域。", "Brush over the area to process.")).font(.caption).foregroundStyle(.secondary)
            }
            if session.processingTool { HStack { ProgressView();Button(WorkbenchText.t("取消", "Cancel")) { session.cancelToolProcessing() } }.frame(minHeight:44) }
        }.disabled(session.saving || session.selectedLayer?.isLocked == true)
    }
    private func colorBinding(_ key:ReferenceWritableKeyPath<MediaV2Session,String>) -> Binding<Color> {
        .init(get:{
            guard let c = try? PreparedVideoColor(hex:session[keyPath:key]) else { return .black }
            return Color(.sRGB,red:c.red,green:c.green,blue:c.blue,opacity:c.alpha)
        },set:{session[keyPath:key] = hex($0)})
    }
    private func hex(_ color:Color) -> String {
        var r:CGFloat = 0,g:CGFloat = 0,b:CGFloat = 0,a:CGFloat = 0
        UIColor(color).getRed(&r,green:&g,blue:&b,alpha:&a)
        return String(format:"#%02X%02X%02X%02X",Int((r*255).rounded()),Int((g*255).rounded()),Int((b*255).rounded()),Int((a*255).rounded()))
    }
    private func applyEffect() {
        var input = MediaV2ToolInput();input.objectID = session.selectedLayerID;input.expectedRevision = session.document.revision
        input.number = outline;input.secondary = shadowRadius;input.color = session.colorHex;input.text = hex(shadowColor);input.flag = shadow
        input.points = [.init(x:offsetX,y:offsetY)]
        Task { do { _ = try await session.performTool("image.layer-effect",input:input) } catch { session.diagnostic = error.localizedDescription } }
    }
}
#endif
