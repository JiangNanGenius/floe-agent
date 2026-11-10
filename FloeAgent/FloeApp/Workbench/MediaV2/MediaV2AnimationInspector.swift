// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import FloeWorkbench

struct MediaV2AnimationInspector: View {
    @Bindable var session: MediaV2Session
    @State private var preset = MediaAnimationPreset.fade
    @State private var title = ""
    @State private var titleColor = Color.white
    @State private var fontSize = 48.0
    @State private var start = 0.0
    @State private var duration = 3.0
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            if session.tool == "video.motion-path" {
                Text(WorkbenchText.t("在预览画面上画出片段中心的运动路线。", "Draw the clip center's route on the preview."))
                    .font(.caption).foregroundStyle(.secondary)
                MediaFingerDrawingToggle()
                Text(WorkbenchText.t("鼠标和 Apple Pencil 可直接绘制。", "Mouse and Apple Pencil draw directly."))
                    .font(.caption2).foregroundStyle(.secondary)
                Button(WorkbenchText.t("清除运动路径", "Clear motion path")) {
                    guard let selected = session.selectedClip else { return }
                    let keys = selected.clip.keyframeTracks.filter { !["centerX","centerY"].contains($0.property.replacingOccurrences(of:"transform.",with:"")) }
                    session.submit([.replaceClipKeyframes(trackID:selected.track.id,clipID:selected.clip.id,expectedRevision:selected.clip.revision,keyframeTracks:keys)])
                }.frame(minHeight:44).disabled(session.selectedClip?.track.kind != .visual)
            } else {
                Picker(WorkbenchText.t("动画", "Animation"),selection:$preset) {
                    ForEach(MediaAnimationPreset.allCases,id:\.self) { value in Text(name(value)).tag(value) }
                }
                if session.tool == "video.motion-title" {
                    TextField(WorkbenchText.t("标题文字", "Title text"),text:$title,axis:.vertical).textFieldStyle(.roundedBorder)
                    MediaV2NumberField(title:WorkbenchText.t("字号", "Font size"),value:$fontSize,suffix:"px")
                    ColorPicker(WorkbenchText.t("文字颜色", "Text color"),selection:$titleColor,supportsOpacity:true).frame(minHeight:44)
                    MediaV2NumberField(title:WorkbenchText.t("开始", "Start"),value:$start,suffix:"s")
                    MediaV2NumberField(title:WorkbenchText.t("时长", "Duration"),value:$duration,suffix:"s")
                    Button(session.selectedClip?.clip.motionTitle == nil ? WorkbenchText.t("添加标题", "Add title") : WorkbenchText.t("更新标题", "Update title")) { applyTitle() }
                        .frame(minHeight:44).disabled(title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                } else {
                    Text(WorkbenchText.t("预设会替换相应属性的关键帧。其他动画保留。", "Replaces keyframes for the preset's properties. Other animation stays."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(WorkbenchText.t("应用到所选片段", "Apply to selected clip")) {
                        var input = MediaV2ToolInput();input.objectID = session.selectedClipID;input.text = preset.rawValue
                        run("video.preset-motion",input:input)
                    }.frame(minHeight:44).disabled(session.selectedClip?.track.kind != .visual)
                }
            }
        }.disabled(session.saving || session.selectedClip?.track.isLocked == true)
            .onAppear(perform:load).onChange(of:session.selectedClipID) { _,_ in load() }
    }
    private func load() {
        let clip = session.selectedClip?.clip
        title = clip?.motionTitle?.text ?? ""; fontSize = clip?.motionTitle?.fontSize ?? 48
        if let color = try? PreparedVideoColor(hex:clip?.motionTitle?.colorHex ?? "#FFFFFF") {
            titleColor = Color(.sRGB,red:color.red,green:color.green,blue:color.blue,opacity:color.alpha)
        }
        start = clip?.motionTitle == nil ? session.playhead : clip?.timelineRange.startSeconds ?? session.playhead
        duration = clip?.timelineRange.durationSeconds ?? 3
    }
    private func name(_ preset: MediaAnimationPreset) -> String {
        switch preset {
        case .fade: WorkbenchText.t("淡入淡出", "Fade in and out")
        case .slideLeft: WorkbenchText.t("从左滑入", "Slide in from left")
        case .rise: WorkbenchText.t("上升", "Rise")
        case .zoomIn: WorkbenchText.t("放大进入", "Zoom in")
        case .pulse: WorkbenchText.t("轻微缩放", "Pulse")
        case .spin: WorkbenchText.t("旋转一周", "Full turn")
        }
    }
    private func applyTitle() {
        var input = MediaV2ToolInput()
        if session.selectedClip?.clip.motionTitle != nil { input.objectID = session.selectedClipID }
        input.text = title;input.number = fontSize;input.start = start;input.duration = duration;input.property = preset.rawValue
        var red:CGFloat = 0,green:CGFloat = 0,blue:CGFloat = 0,alpha:CGFloat = 0
        UIColor(titleColor).getRed(&red,green:&green,blue:&blue,alpha:&alpha)
        input.color = String(format:"#%02X%02X%02X%02X",Int((red*255).rounded()),Int((green*255).rounded()),Int((blue*255).rounded()),Int((alpha*255).rounded()))
        run("video.motion-title",input:input)
    }
    private func run(_ id:String,input:MediaV2ToolInput) {
        var input = input;input.expectedRevision = session.document.revision
        Task { do { _ = try await session.performTool(id,input:input) } catch { session.diagnostic = error.localizedDescription } }
    }
}

struct MediaV2BezierCurveEditor: View {
    @Binding var curve: MediaCubicBezier
    var body: some View {
        GeometryReader { geometry in
            let width = max(1,geometry.size.width-32), height = max(1,geometry.size.height-32)
            ZStack {
                SwiftUI.Canvas { context,_ in
                    let origin = CGPoint(x:16,y:height+16), end = CGPoint(x:width+16,y:16)
                    func point(_ p:ImageFreehandStroke.Point) -> CGPoint { .init(x:16+p.x*width,y:16+(1-p.y)*height) }
                    var grid = Path()
                    for step in 0...4 {
                        let t = Double(step)/4
                        grid.move(to:.init(x:16+t*width,y:16));grid.addLine(to:.init(x:16+t*width,y:height+16))
                        grid.move(to:.init(x:16,y:16+t*height));grid.addLine(to:.init(x:width+16,y:16+t*height))
                    }
                    context.stroke(grid,with:.color(.secondary.opacity(0.2)),lineWidth:1)
                    var handles = Path();handles.move(to:origin);handles.addLine(to:point(curve.control1));handles.move(to:end);handles.addLine(to:point(curve.control2))
                    context.stroke(handles,with:.color(.secondary),style:.init(lineWidth:1,dash:[3,3]))
                    var path = Path();path.move(to:origin);path.addCurve(to:end,control1:point(curve.control1),control2:point(curve.control2))
                    context.stroke(path,with:.color(.accentColor),lineWidth:2)
                }
                handle(1,width:width,height:height)
                handle(2,width:width,height:height)
            }.coordinateSpace(name:"media.curve.editor")
        }.frame(height:160).background(Color.secondary.opacity(0.05),in:RoundedRectangle(cornerRadius:8))
            .accessibilityLabel(WorkbenchText.t("拖动控制点调整时间曲线", "Drag handles to shape the timing curve"))
    }
    private func handle(_ index:Int,width:Double,height:Double) -> some View {
        let p = index == 1 ? curve.control1 : curve.control2
        return Circle().fill(index == 1 ? Color.accentColor : Color.orange).frame(width:14,height:14)
            .frame(width:44,height:44).contentShape(Circle())
            .position(x:16+p.x*width,y:16+(1-p.y)*height)
            .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named("media.curve.editor")).onChanged { value in
                let point = ImageFreehandStroke.Point(x:max(0,min(1,(value.location.x-16)/width)),y:max(0,min(1,1-(value.location.y-16)/height)))
                if index == 1 { curve.control1 = point } else { curve.control2 = point }
            })
    }
}
#endif
