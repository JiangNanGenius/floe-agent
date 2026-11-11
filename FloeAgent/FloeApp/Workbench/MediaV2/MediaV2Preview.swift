// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVKit
import SwiftUI
import FloeWorkbench

struct MediaV2Preview: View {
    @Bindable var session: MediaV2Session
    @AppStorage(MediaDrawingInputPolicy.preferenceKey) private var fingerDrawing = false
    @State private var points: [ImageFreehandStroke.Point] = []
    @State private var originalLayer: MediaPreparedLayer?
    @State private var strokeRevision: Int64?
    var body: some View {
        GeometryReader { geometry in
            let canvas = session.document.canvas ?? .init(width: 1600, height: 1200)
            let fit = min(max(1, geometry.size.width - 28) / CGFloat(canvas.width), max(1, geometry.size.height - 28) / CGFloat(canvas.height))
            let size = CGSize(width: CGFloat(canvas.width) * fit, height: CGFloat(canvas.height) * fit)
            ZStack {
                Color(uiColor: .secondarySystemBackground)
                ZStack {
                    checkerboard
                    if let player = session.player { VideoPlayer(player: player) }
                    else if let image = session.imageWarpPreview ?? (session.colorShowsOriginal ? session.preview : session.colorPreview ?? session.preview) { Image(decorative: image, scale: 1).allowedDynamicRange(session.project.kind == .video && session.document.canvas?.videoColorProfile?.isHDR == true ? .high : nil).resizable().aspectRatio(contentMode: .fit) }
                    else if session.project.kind == .video {
                        VStack(spacing: 12) { Image(systemName: "film").font(.largeTitle); Text(WorkbenchText.t("导入素材开始剪辑", "Import media to start editing")).font(.callout) }.foregroundStyle(.secondary)
                    }
                    if session.project.kind == .image {
                        Group {
                            if MediaV2Session.imageWarpToolIDs.contains(session.tool) { MediaV2ImageWarpCanvasOverlay(session: session) }
                            else { interaction(size: size, canvas: canvas) }
                        }.allowsHitTesting(!session.canvasLayoutInProgress && !session.processingTool)
                    }
                    else if session.tool == "video.motion-path" { MediaV2MotionPathOverlay(session:session) }
                    if session.project.kind == .video,session.tool == "video.tracking" { MediaV2TrackingOverlay(session:session) }
                }
                .frame(width: size.width, height: size.height)
                .scaleEffect(session.zoom)
                .overlay { Rectangle().stroke(Color.secondary.opacity(0.25), lineWidth: 1) }
            }.clipped().overlay(alignment: .bottom) {
                if session.project.kind == .image, MediaV2Session.imageWarpToolIDs.contains(session.tool) { MediaV2ImageWarpActionBar(session: session) }
            }
        }
        .onChange(of:session.selectedLayerID) { _,_ in session.cloneSourcePoint = nil;session.cloneDestinationOrigin = nil;session.clonePickSource = false }
        .onChange(of: session.tool) { _, tool in
            points = []; originalLayer = nil; strokeRevision = nil
            if !MediaV2Session.imageWarpToolIDs.contains(tool) { session.discardImageWarpDraft() }
        }
        .accessibilityIdentifier("media.v2.canvas")
    }
    private var checkerboard: some View {
        SwiftUI.Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for row in 0...Int(size.height / 12) {
                for column in 0...Int(size.width / 12) where (row + column) % 2 == 0 {
                    context.fill(Path(CGRect(x: column * 12, y: row * 12, width: 12, height: 12)), with: .color(.black.opacity(0.07)))
                }
            }
        }.accessibilityHidden(true)
    }
    private func interaction(size: CGSize, canvas: MediaCanvas) -> some View {
        SwiftUI.Canvas { context, bounds in
            if session.showSelection, let selection = session.selection {
                for shape in selection.shapes {
                    let path = selectionPath(shape.kind, points: shape.points, size: bounds)
                    context.stroke(path, with: .color(.white), lineWidth: 2)
                    context.stroke(path, with: .color(.accentColor), style: .init(lineWidth: 1, dash: [5, 3]))
                }
            }
            if !session.polygonPoints.isEmpty {
                context.stroke(selectionPath(.lasso, points: session.polygonPoints, size: bounds, close: false),
                    with: .color(.accentColor), style: .init(lineWidth: 1.5, dash: [4, 3]))
                for point in session.polygonPoints {
                    context.fill(Path(ellipseIn: CGRect(x: point.x * bounds.width - 3, y: point.y * bounds.height - 3, width: 6, height: 6)), with: .color(.accentColor))
                }
            }
            if ["image.clone","image.heal"].contains(session.tool),let source = session.cloneSourcePoint {
                let origin = session.cloneDestinationOrigin ?? points.first
                let current = points.last
                let x = source.x + (session.cloneAligned ? (current?.x ?? origin?.x ?? 0)-(origin?.x ?? 0) : 0)
                let y = source.y + (session.cloneAligned ? (current?.y ?? origin?.y ?? 0)-(origin?.y ?? 0) : 0)
                var marker = Path();marker.move(to:.init(x:x*bounds.width-7,y:y*bounds.height));marker.addLine(to:.init(x:x*bounds.width+7,y:y*bounds.height))
                marker.move(to:.init(x:x*bounds.width,y:y*bounds.height-7));marker.addLine(to:.init(x:x*bounds.width,y:y*bounds.height+7))
                context.stroke(marker,with:.color(.white),lineWidth:3);context.stroke(marker,with:.color(.accentColor),lineWidth:1)
            }
            if !points.isEmpty {
                if session.tool == "image.patch",let first = points.first,let last = points.last,let selection = session.selection {
                    var ghost = context
                    ghost.translateBy(x:(last.x-first.x)*bounds.width,y:(last.y-first.y)*bounds.height)
                    for shape in selection.shapes {
                        ghost.stroke(selectionPath(shape.kind,points:shape.points,size:bounds),with:.color(.orange),style:.init(lineWidth:1.5,dash:[4,3]))
                    }
                } else if MediaV2Session.usesDirectStroke(session.tool) {
                    let displayed = session.tool == "image.gradient" ? [points.first!,points.last!] : points
                    let path = selectionPath(.lasso, points: displayed, size: bounds, close: false)
                    context.stroke(path, with: .color(session.tool == "image.eraser" ? .white.opacity(0.7) : .accentColor), style: .init(lineWidth: max(1, session.brushWidth * bounds.width / CGFloat(canvas.width)), lineCap: .round, lineJoin: .round))
                } else if session.tool != "move" {
                    context.stroke(selectionPath(session.tool == "image.ellipse" ? .ellipse : session.tool.contains("lasso") || session.tool.contains("polygon") ? .lasso : .rectangle, points: points, size: bounds), with: .color(.accentColor), style: .init(lineWidth: 1, dash: [5, 3]))
                }
            }
        }
        .contentShape(Rectangle())
        .overlay { if session.showSelection,let selection=session.selection,selection.bitmap != nil { MediaV2BitmapSelectionOverlay(selection:selection,canvas:canvas) } }
        .overlay {
            if session.tool == "image.patch",session.showSelection,let selection = session.selection,selection.bitmap != nil,
               let first = points.first,let last = points.last {
                MediaV2BitmapSelectionOverlay(selection:selection,canvas:canvas).opacity(0.6)
                    .offset(x:(last.x-first.x)*size.width,y:(last.y-first.y)*size.height)
            }
        }
        // UIKit owns ink: a parent SwiftUI drag/tap recognizer would cancel
        // its real Pencil touch sequence even if its callback returned early.
        .overlay {
            if MediaV2Session.usesDirectStroke(session.tool) {
                WorkbenchPressureSurface(fingerDrawing: fingerDrawing, onChanged: { point, pressure in
                    if points.isEmpty { originalLayer = session.selectedLayer;strokeRevision = session.document.revision }
                    var sample = normalized(point, size: size)
                    sample.pressure = pressure
                    points.append(sample)
                    if points.count > 10_000 { points.removeSubrange(1..<100) }
                }, onEnded: {
                    defer { points = []; originalLayer = nil;strokeRevision = nil }
                    guard !points.isEmpty, MediaV2Session.usesDirectStroke(session.tool) else { return }
                    submitToolPoints()
                }, onCancelled: { points = []; originalLayer = nil;strokeRevision = nil })
            }
        }
        .gesture(MediaV2Session.usesDirectStroke(session.tool) ? nil : DragGesture(minimumDistance: 3).onChanged { value in
            guard session.tool != "image.polygon",!session.canvasLayoutInProgress else { return }
            if points.isEmpty { originalLayer = session.selectedLayer;strokeRevision = session.document.revision; points.append(normalized(value.startLocation, size: size)) }
            points.append(normalized(value.location, size: size))
            if points.count > 10_000 { points.removeSubrange(1..<100) }
        }.onEnded { value in
            defer { points = []; originalLayer = nil;strokeRevision = nil }
            guard session.tool != "image.polygon", !points.isEmpty else { return }
            if session.tool == "move", let layer = originalLayer,let revision=strokeRevision {
                session.moveDisplayedLayer(layer,delta:.init(x:Double(value.translation.width/size.width),y:Double(value.translation.height/size.height)),revision:revision)
            } else {
                submitToolPoints()
            }
        })
        .simultaneousGesture(MediaV2Session.usesDirectStroke(session.tool) ? nil : SpatialTapGesture().onEnded { value in
            if session.tool == "image.wand" {
                var input=MediaV2ToolInput();input.points=[normalized(value.location,size:size)];input.number=session.wandTolerance;input.property=session.selectionMode.rawValue;input.expectedRevision=session.document.revision
                Task{do{_=try await session.performTool("image.wand",input:input)}catch{session.diagnostic=error.localizedDescription}}
            } else if session.tool == "image.polygon" {
                if session.polygonPoints.count < 2048 { session.polygonPoints.append(normalized(value.location, size: size)) }
            } else if session.tool == "image.eyedropper" {
                var input = MediaV2ToolInput(); input.points = [normalized(value.location, size: size)]
                Task { do { _ = try await session.performTool("image.eyedropper", input: input) } catch { session.diagnostic = error.localizedDescription } }
            }
        })
    }
    private func submitToolPoints() {
        guard let first = points.first, let last = points.last else { return }
        if MediaV2Session.usesDirectStroke(session.tool),session.selectedLayerID != originalLayer?.id {
            session.diagnostic = MediaPreparedCoreError.documentChanged.localizedDescription;return
        }
        var input = MediaV2ToolInput(); input.expectedRevision = strokeRevision ?? session.document.revision
        if MediaV2Session.usesDirectStroke(session.tool) { input.objectID = originalLayer?.id }
        input.number = session.brushWidth; input.color = session.colorHex
        let tool = session.tool == "image.feather" ? "image.rectangle" : session.tool
        input.points = ["image.rectangle", "image.ellipse", "image.crop"].contains(tool) ? [first, last] : points
        if tool == "image.wand"{input.number=session.wandTolerance;input.property=session.selectionMode.rawValue}
        input.flag = session.tool == "image.eraser" ? session.eraserRestores : nil
        if ["image.clone","image.heal"].contains(tool) {
            if session.clonePickSource { session.cloneSourcePoint = first;session.cloneDestinationOrigin = nil;session.clonePickSource = false;return }
            guard var source = session.cloneSourcePoint else { session.diagnostic = WorkbenchText.t("请先设置取样点。", "Set a sample point first.");return }
            if session.cloneAligned {
                if let origin = session.cloneDestinationOrigin { source.x += first.x-origin.x;source.y += first.y-origin.y }
                else { session.cloneDestinationOrigin = first }
            }
            input.points = [source]+points;input.secondary = tool == "image.heal" ? session.repairStrength : session.sampleBrushStrength
        } else if tool == "image.patch" {
            guard hypot(last.x-first.x,last.y-first.y)>=0.001 else { return }
            input.points = [first,last];input.secondary = session.repairStrength
        } else if tool == "image.smudge" {
            guard points.count>=2 else { return };input.secondary = session.sampleBrushStrength
        } else if tool == "image.gradient" {
            input.points = [first,last];input.number = session.brushOpacity;input.text = session.gradientLastHex;input.flag = session.gradientRadial
        } else if ["image.blur-brush","image.sharpen-brush"].contains(tool) { input.secondary = session.brushEffectAmount }
        if tool == "image.crop" { input.property = "canvas" }
        else if ["image.rectangle", "image.ellipse", "image.lasso"].contains(tool) { input.property = session.selectionMode.rawValue }
        Task { do { _ = try await session.performTool(tool, input: input) } catch { session.diagnostic = error.localizedDescription } }
    }
    private func normalized(_ point: CGPoint, size: CGSize) -> ImageFreehandStroke.Point {
        .init(x: min(1, max(0, Double(point.x / max(1, size.width)))), y: min(1, max(0, Double(point.y / max(1, size.height)))))
    }
    private func selectionPath(_ kind: ImageSelectionKind, points: [ImageFreehandStroke.Point], size: CGSize, close: Bool = true) -> Path {
        guard let first = points.first, let last = points.last else { return Path() }
        let a = CGPoint(x: first.x * size.width, y: first.y * size.height), b = CGPoint(x: last.x * size.width, y: last.y * size.height)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        if kind == .ellipse { return Path(ellipseIn: rect) }
        if kind == .rectangle { return Path(rect) }
        return Path { path in path.move(to: a); for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height)) }; if close { path.closeSubpath() } }
    }
}

struct MediaV2Timeline: View {
    @Bindable var session: MediaV2Session
    @State private var rulerOrigin:CGFloat=0
    @State private var headOrigin=0.0
    private var scale:CGFloat{MediaTimelineViewportMath.scale(zoom:session.timelineZoom)}
    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - 110, CGFloat(max(20, session.duration + 3)) * scale)
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        Text(WorkbenchText.t("时间线", "Timeline")).font(.caption2.weight(.medium)).frame(height: 44)
                        ForEach(session.document.trackGraph.tracks) { track in
                            Button { session.select(track) } label: { Label(track.name, systemImage: track.kind == .audio ? "waveform" : track.kind == .caption ? "captions.bubble" : "film").font(.caption2).lineLimit(1).frame(width: 100, height: 54, alignment: .leading) }
                                .buttonStyle(.plain).padding(.leading, 8).background(session.selectedTrackID == track.id ? Color.accentColor.opacity(0.1) : .clear)
                        }
                    }.frame(width: 110)
                    Divider()
                    ScrollView(.horizontal) {
                        VStack(spacing: 0) {
                            ZStack(alignment:.topLeading){
                                SwiftUI.Canvas{context,_ in
                                    let step=[0.1,0.2,0.5,1,2,5,10,30,60,120,300].first{$0*Double(scale)>=80} ?? 300
                                    for seconds in stride(from:0.0,through:max(20,session.duration+3),by:step){
                                        let x=CGFloat(seconds)*scale
                                        context.draw(Text(MusicWorkbenchFormat.time(seconds)).font(.system(size:10)).foregroundColor(.secondary),at:.init(x:x+4,y:9),anchor:.topLeading)
                                        var tick=Path();tick.move(to:.init(x:x,y:31));tick.addLine(to:.init(x:x,y:44));context.stroke(tick,with:.color(.secondary.opacity(0.6)),lineWidth:1)
                                    }
                                }
                                MediaV2TimelineTouchSurface(mode:.ruler,identifier:"media.v2.timeline.ruler",onTap:{x in seek(x)},onBegin:{x in rulerOrigin=x;seek(x)},onChange:{dx in seek(rulerOrigin+dx)},onEnd:{dx in seek(rulerOrigin+dx)})
                                TimelineView(.periodic(from:.now,by:0.1)){_ in
                                    let current=session.player?.currentTime().seconds ?? session.playhead
                                    let time=current.isFinite ? max(0,current):0
                                    Image(systemName:"triangle.fill").rotationEffect(.degrees(180)).font(.system(size:14)).foregroundStyle(Color.accentColor)
                                        .frame(width:44,height:44,alignment:.bottom)
                                        .overlay{MediaV2TimelineTouchSurface(mode:.playhead,identifier:"media.v2.timeline.playhead",onBegin:{_ in headOrigin=time},onChange:{dx in session.scrub(headOrigin+Double(dx/scale))},onEnd:{dx in session.scrub(headOrigin+Double(dx/scale))})}
                                        .offset(x:CGFloat(time)*scale-22)
                                }
                            }.frame(height:44).accessibilityElement(children:.contain)
                                .accessibilityLabel(WorkbenchText.t("时间标尺", "Time ruler"))
                                .accessibilityAdjustableAction{direction in session.scrub(session.playhead+(direction == .increment ? 1:-1))}
                            ZStack(alignment: .topLeading) {
                                VStack(spacing: 0) {
                                    ForEach(session.document.trackGraph.tracks) { track in
                                        ZStack(alignment: .leading) {
                                            Rectangle().fill(Color.secondary.opacity(0.05))
                                            ForEach(track.clips) { clip in MediaV2TimelineClip(session: session, track: track, clip: clip, scale: scale).offset(x: CGFloat(clip.timelineRange.startSeconds) * scale) }
                                        }.frame(height: 54).overlay(alignment: .bottom) { Divider() }
                                    }
                                }
                                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                                    let time = session.player?.currentTime().seconds ?? session.playhead
                                    Rectangle().fill(Color.accentColor).frame(width: 1.5).offset(x: CGFloat(time.isFinite ? time : 0) * scale).allowsHitTesting(false)
                                }
                            }.frame(height:max(54,CGFloat(session.document.trackGraph.tracks.count)*54))
                        }.frame(width:width)
                            .background{MediaV2TimelinePinchBridge(zoom:$session.timelineZoom).frame(width:1,height:1)}
                    }
                }
            }
        }.background(Color(uiColor: .secondarySystemBackground))
            .safeAreaInset(edge: .top, spacing: 0) { timelineToolbar }
            .accessibilityIdentifier("media.v2.timeline")
    }
    private func seek(_ x:CGFloat){session.scrub(MediaTimelineViewportMath.time(contentX:Double(x),zoom:session.timelineZoom,duration:session.duration))}
    private var timelineToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button { command("video.split") } label: { Label(WorkbenchText.t("分割", "Split"), systemImage: "scissors").frame(minHeight: 44) }.disabled(session.selectedClip == nil)
                Button { session.timelineSnap.toggle() } label: { Image(systemName: session.timelineSnap ? "link.circle.fill" : "link").frame(width: 44, height: 44).background(session.timelineSnap ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5)) }.accessibilityLabel(WorkbenchText.t("时间线吸附", "Timeline snapping"))
                Toggle(WorkbenchText.t("本轨波纹", "Ripple track"), isOn: $session.rippleCurrentTrack).toggleStyle(.button).frame(minHeight: 44)
                Button { session.tool = "video.keyframes" } label: { Label(WorkbenchText.t("关键帧", "Keyframes"), systemImage: "diamond").frame(minHeight: 44) }
                Menu {
                    Button(WorkbenchText.t("视频轨", "Video track")) { session.addTrack(.visual) }
                    Button(WorkbenchText.t("音频轨", "Audio track")) { session.addTrack(.audio) }
                    Button(WorkbenchText.t("字幕轨", "Caption track")) { session.addTrack(.caption) }
                } label: { Image(systemName: "plus.rectangle.on.rectangle").frame(width: 44, height: 44) }
                Divider().frame(height: 24)
                Text(WorkbenchText.t("时间线缩放", "Timeline zoom")).font(.caption)
                Slider(value: $session.timelineZoom, in: 0.5...6).frame(width: 120, height: 44)
            }.font(.caption).padding(.horizontal, 8)
        }.background(Color(uiColor: .secondarySystemBackground)).overlay(alignment: .bottom) { Divider() }
    }
    private func command(_ id: String) {
        var input = MediaV2ToolInput(); input.expectedRevision = session.document.revision
        Task { do { _ = try await session.performTool(id, input: input) } catch { session.diagnostic = error.localizedDescription } }
    }
}

private struct MediaV2TimelineClip: View {
    @Bindable var session: MediaV2Session
    let track: MediaPreparedTrack
    let clip: MediaPreparedClip
    let scale: CGFloat
    @State private var delta: CGFloat = 0
    @State private var original: MediaPreparedClip?
    @State private var dragRevision:Int64?
    private var color: Color { track.kind == .audio ? .green : track.kind == .caption ? .purple : .blue }
    var body: some View {
        HStack(spacing: 5) {
            PersonalEditorAssetPreview(sourceID: "clip:\(session.id):\(session.document.revision):\(clip.id)",
                title: clip.motionTitle?.text ?? clip.captionText ?? WorkbenchText.t("片段", "Clip"), opensQuickPreview: false) { pixels in
                try await PersonalEditorPreviewRequests.mediaClip(session: session, track: track, clip: clip, pixels: pixels)
            }.frame(width: min(52, max(20, CGFloat(clip.timelineRange.durationSeconds) * scale * 0.3)), height: 30).allowsHitTesting(false)
            Text(clip.motionTitle?.text ?? clip.captionText ?? session.document.asset(clip.assetID ?? UUID())?.originalName ?? WorkbenchText.t("片段", "Clip")).lineLimit(1)
            Spacer(minLength: 0)
        }.font(.caption2).padding(.horizontal, 7).frame(width: max(44, CGFloat(clip.timelineRange.durationSeconds) * scale), height: 42)
            .background(color.opacity(0.22), in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).stroke((session.selectedClipID == clip.id || session.selectedClipIDs.contains(clip.id)) ? color : color.opacity(0.3), lineWidth: session.selectedClipID == clip.id ? 2 : 1) }
            .overlay(alignment: .bottomLeading) { keyframes.allowsHitTesting(false) }
            .overlay { MediaV2TimelineTouchSurface(mode:.clip,identifier:"media.v2.timeline.clip.\(clip.id)",onTap:tap,onBegin:{_ in beginMove()},onChange:move,onEnd:finishMove,onCancel:cancelMove) }
            .overlay(alignment:.leading){if session.selectedClipID==clip.id{MediaV2TrimHandle(session:session,track:track,clip:clip,leading:true,scale:scale)}}
            .overlay(alignment:.trailing){if session.selectedClipID==clip.id{MediaV2TrimHandle(session:session,track:track,clip:clip,leading:false,scale:scale)}}
            .offset(x: delta)
            .contextMenu {
                Button(session.selectedClipIDs.contains(clip.id) ? WorkbenchText.t("取消选择", "Deselect") : WorkbenchText.t("加入多选", "Add to selection")) { session.toggleCompoundSelection(clip,in:track) }
                if clip.compound != nil { Button(WorkbenchText.t("编辑内部片段", "Edit contents")) { Task { do { try await session.openCompound(clip.id) } catch { session.diagnostic=error.localizedDescription } } } }
                Button(WorkbenchText.t("复制", "Duplicate")) { session.duplicateTimelineClip(clip,in:track) }
                Button(WorkbenchText.t("删除", "Delete"), role: .destructive) { session.deleteTimelineClip(clip,in:track) }
            }
            .disabled(track.isLocked || session.saving || session.processingTool)
    }
    private func tap(_ x:CGFloat){
        session.select(track,clip:clip)
        let time=clip.timelineRange.startSeconds+min(clip.timelineRange.durationSeconds,max(0,Double(x/scale)))
        session.scrub(time)
        if session.tool=="video.split"{var input=MediaV2ToolInput();input.objectID=clip.id;input.start=time;input.expectedRevision=session.document.revision;Task{do{_=try await session.performTool("video.split",input:input)}catch{session.diagnostic=error.localizedDescription}}}
    }
    private func beginMove(){guard !track.isLocked,!session.saving,!session.multipleClipSelection else{return};original=clip;dragRevision=session.document.revision;session.select(track,clip:clip)}
    private func move(_ dx:CGFloat){guard let original else{return};let target=session.snapTime(MediaTimelineViewportMath.movedStart(original.timelineRange.startSeconds,translation:Double(dx),zoom:session.timelineZoom),excluding:clip.id);delta=CGFloat(target-original.timelineRange.startSeconds)*scale}
    private func finishMove(_ dx:CGFloat){
        defer{cancelMove()};guard var next=original,let revision=dragRevision else{return}
        let target=session.snapTime(MediaTimelineViewportMath.movedStart(next.timelineRange.startSeconds,translation:Double(dx),zoom:session.timelineZoom),excluding:clip.id)
        guard abs(target-next.timelineRange.startSeconds)>0.000_001 else{return}
        do{next.timelineRange=try MediaV2Session.range(start:target,duration:next.timelineRange.durationSeconds);session.commitTimelineGesture([.replaceClip(trackID:track.id,clipID:clip.id,expectedRevision:original!.revision,clip:next)],revision:revision)}catch{session.diagnostic=error.localizedDescription}
    }
    private func cancelMove(){original=nil;dragRevision=nil;delta=0}
    private var keyframes: some View {
        SwiftUI.Canvas { context, size in
            let times = Set(clip.keyframeTracks.flatMap { $0.keyframes.map { $0.time.seconds } }).sorted()
            for time in times {
                let x = CGFloat(time) * scale
                var path = Path(); path.move(to: CGPoint(x: x, y: size.height - 11))
                path.addLine(to: CGPoint(x: x + 4, y: size.height - 7)); path.addLine(to: CGPoint(x: x, y: size.height - 3))
                path.addLine(to: CGPoint(x: x - 4, y: size.height - 7)); path.closeSubpath()
                context.fill(path, with: .color(color))
            }
        }
    }
}
private struct MediaV2TrimHandle: View {
    @Bindable var session: MediaV2Session
    let track: MediaPreparedTrack
    let clip: MediaPreparedClip
    let leading: Bool
    let scale: CGFloat
    @State private var original: MediaPreparedClip?
    @State private var delta: CGFloat = 0
    @State private var dragRevision:Int64?
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.35)).frame(width: 3, height: 24)
            .frame(width: 22, height: 44).contentShape(Rectangle()).offset(x: delta)
            .overlay{MediaV2TimelineTouchSurface(mode:.edge,identifier:leading ? "media.v2.timeline.trim-in":"media.v2.timeline.trim-out",onBegin:{_ in original=clip;dragRevision=session.document.revision;session.select(track,clip:clip)},onChange:{dx in delta=clampedDelta(dx)},onEnd:{dx in
                defer{original=nil;dragRevision=nil;delta=0}
                guard let original,let revision=dragRevision else{return}
                let edge=leading ? original.timelineRange.startSeconds:original.timelineRange.endSeconds
                session.trimTimelineEdge(track:track,clip:original,leading:leading,to:edge+Double(clampedDelta(dx)/scale),expectedRevision:revision)
            },onCancel:{original=nil;dragRevision=nil;delta=0})}
            .accessibilityLabel(leading ? WorkbenchText.t("修剪入点", "Trim in") : WorkbenchText.t("修剪出点", "Trim out"))
    }
    private func clampedDelta(_ dx:CGFloat)->CGFloat{
        guard let original else{return 0}
        let edge=leading ? original.timelineRange.startSeconds:original.timelineRange.endSeconds
        let result=session.timelineTrimTarget(edge+Double(dx/scale),clip:original,leading:leading)
        return CGFloat(result-edge)*scale
    }

}
#endif
