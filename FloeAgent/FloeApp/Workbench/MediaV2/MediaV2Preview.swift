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
                    else if let image = session.preview { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit) }
                    else if session.project.kind == .video {
                        VStack(spacing: 12) { Image(systemName: "film").font(.largeTitle); Text(WorkbenchText.t("导入素材开始剪辑", "Import media to start editing")).font(.callout) }.foregroundStyle(.secondary)
                    }
                    if session.project.kind == .image { interaction(size: size, canvas: canvas) }
                }
                .frame(width: size.width, height: size.height)
                .scaleEffect(session.zoom)
                .overlay { Rectangle().stroke(Color.secondary.opacity(0.25), lineWidth: 1) }
            }.clipped()
        }
        .onChange(of: session.tool) { _, _ in points = []; originalLayer = nil }
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
            if !points.isEmpty {
                if ["image.brush", "image.eraser", "image.pen"].contains(session.tool) {
                    let path = selectionPath(.lasso, points: points, size: bounds, close: false)
                    context.stroke(path, with: .color(session.tool == "image.eraser" ? .white.opacity(0.7) : .accentColor), style: .init(lineWidth: max(1, session.brushWidth * bounds.width / CGFloat(canvas.width)), lineCap: .round, lineJoin: .round))
                } else if session.tool != "move" {
                    context.stroke(selectionPath(session.tool == "image.ellipse" ? .ellipse : session.tool.contains("lasso") || session.tool.contains("polygon") ? .lasso : .rectangle, points: points, size: bounds), with: .color(.accentColor), style: .init(lineWidth: 1, dash: [5, 3]))
                }
            }
        }
        .contentShape(Rectangle())
        // UIKit owns ink: a parent SwiftUI drag/tap recognizer would cancel
        // its real Pencil touch sequence even if its callback returned early.
        .overlay {
            if MediaDrawingInputPolicy.isStrokeTool(session.tool) {
                WorkbenchPressureSurface(fingerDrawing: fingerDrawing, onChanged: { point, _ in
                    points.append(normalized(point, size: size))
                    if points.count > 10_000 { points.removeSubrange(1..<100) }
                }, onEnded: {
                    defer { points = []; originalLayer = nil }
                    guard !points.isEmpty, MediaDrawingInputPolicy.isStrokeTool(session.tool) else { return }
                    submitToolPoints()
                }, onCancelled: { points = []; originalLayer = nil })
            }
        }
        .gesture(MediaDrawingInputPolicy.isStrokeTool(session.tool) ? nil : DragGesture(minimumDistance: 3).onChanged { value in
            guard session.tool != "image.polygon" else { return }
            if points.isEmpty { originalLayer = session.selectedLayer; points.append(normalized(value.startLocation, size: size)) }
            points.append(normalized(value.location, size: size))
            if points.count > 10_000 { points.removeSubrange(1..<100) }
        }.onEnded { value in
            defer { points = []; originalLayer = nil }
            guard session.tool != "image.polygon", !points.isEmpty else { return }
            if session.tool == "move", let layer = originalLayer {
                var transform = layer.transform
                transform.centerX += Double(value.translation.width / size.width)
                transform.centerY += Double(value.translation.height / size.height)
                session.submit([.updateLayerTransform(id: layer.id, expectedRevision: layer.revision, transform: transform)])
            } else {
                submitToolPoints()
            }
        })
        .simultaneousGesture(MediaDrawingInputPolicy.isStrokeTool(session.tool) ? nil : SpatialTapGesture().onEnded { value in
            if session.tool == "image.polygon" {
                if session.polygonPoints.count < 2048 { session.polygonPoints.append(normalized(value.location, size: size)) }
            } else if session.tool == "image.eyedropper" {
                var input = MediaV2ToolInput(); input.points = [normalized(value.location, size: size)]
                Task { do { _ = try await session.performTool("image.eyedropper", input: input) } catch { session.diagnostic = error.localizedDescription } }
            }
        })
    }
    private func submitToolPoints() {
        guard let first = points.first, let last = points.last else { return }
        var input = MediaV2ToolInput(); input.expectedRevision = session.document.revision; input.number = session.brushWidth; input.color = session.colorHex
        let tool = session.tool == "image.feather" ? "image.rectangle" : session.tool
        input.points = ["image.rectangle", "image.ellipse", "image.crop"].contains(tool) ? [first, last] : points
        input.flag = session.tool == "image.eraser" ? session.eraserRestores : nil
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
    private var scale: CGFloat { 35 * session.timelineZoom }
    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - 110, CGFloat(max(20, session.duration + 3)) * scale)
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        Text(WorkbenchText.t("时间线", "Timeline")).font(.caption2.weight(.medium)).frame(height: 28)
                        ForEach(session.document.trackGraph.tracks) { track in
                            Button { session.select(track) } label: { Label(track.name, systemImage: track.kind == .audio ? "waveform" : track.kind == .caption ? "captions.bubble" : "film").font(.caption2).lineLimit(1).frame(width: 100, height: 54, alignment: .leading) }
                                .buttonStyle(.plain).padding(.leading, 8).background(session.selectedTrackID == track.id ? Color.accentColor.opacity(0.1) : .clear)
                        }
                    }.frame(width: 110)
                    Divider()
                    ScrollView(.horizontal) {
                        VStack(spacing: 0) {
                            SwiftUI.Canvas { context, size in
                                for seconds in stride(from: 0, through: Int(max(20, session.duration + 3)), by: 5) {
                                    context.draw(Text(MusicWorkbenchFormat.time(Double(seconds)).prefix(5)).font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: CGFloat(seconds) * scale + 20, y: 14))
                                }
                            }.frame(height: 28).contentShape(Rectangle()).gesture(SpatialTapGesture().onEnded { session.scrub(Double($0.location.x / scale)) })
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
                            }
                        }.frame(width: width)
                    }
                }
            }
        }.background(Color(uiColor: .secondarySystemBackground))
            .safeAreaInset(edge: .top, spacing: 0) { timelineToolbar }
            .accessibilityIdentifier("media.v2.timeline")
    }
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
    private var color: Color { track.kind == .audio ? .green : track.kind == .caption ? .purple : .blue }
    var body: some View {
        HStack(spacing: 5) {
            PersonalEditorAssetPreview(sourceID: "clip:\(session.id):\(session.document.revision):\(clip.id)",
                title: clip.captionText ?? WorkbenchText.t("片段", "Clip"), opensQuickPreview: false) { pixels in
                try await PersonalEditorPreviewRequests.mediaClip(session: session, track: track, clip: clip, pixels: pixels)
            }.frame(width: min(52, max(20, CGFloat(clip.timelineRange.durationSeconds) * scale * 0.3)), height: 30).allowsHitTesting(false)
            Text(clip.captionText ?? session.document.asset(clip.assetID ?? UUID())?.originalName ?? WorkbenchText.t("片段", "Clip")).lineLimit(1)
            Spacer(minLength: 0)
        }.font(.caption2).padding(.horizontal, 7).frame(width: max(44, CGFloat(clip.timelineRange.durationSeconds) * scale), height: 42)
            .background(color.opacity(0.22), in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).stroke(session.selectedClipID == clip.id ? color : color.opacity(0.3), lineWidth: session.selectedClipID == clip.id ? 2 : 1) }
            .overlay(alignment: .bottomLeading) { keyframes.allowsHitTesting(false) }
            .overlay(alignment: .leading) { MediaV2TrimHandle(session: session, track: track, clip: clip, leading: true, scale: scale) }
            .overlay(alignment: .trailing) { MediaV2TrimHandle(session: session, track: track, clip: clip, leading: false, scale: scale) }
            .offset(x: delta)
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                session.select(track, clip: clip)
                let time = clip.timelineRange.startSeconds + min(clip.timelineRange.durationSeconds, max(0, Double(value.location.x / scale)))
                session.scrub(time)
                if session.tool == "video.split" {
                    var input = MediaV2ToolInput(); input.objectID = clip.id; input.start = time; input.expectedRevision = session.document.revision
                    Task { do { _ = try await session.performTool("video.split", input: input) } catch { session.diagnostic = error.localizedDescription } }
                }
            })
            .gesture(DragGesture(minimumDistance: 6).onChanged { value in if original == nil { original = clip; session.select(track, clip: clip) }; delta = value.translation.width }.onEnded { value in
                defer { original = nil; delta = 0 }
                guard var next = original else { return }
                do { next.timelineRange = try MediaV2Session.range(start: session.snapTime(next.timelineRange.startSeconds + Double(value.translation.width / scale), excluding: clip.id), duration: next.timelineRange.durationSeconds); session.submit([.replaceClip(trackID: track.id, clipID: clip.id, expectedRevision: original!.revision, clip: next)]) }
                catch { session.diagnostic = error.localizedDescription }
            })
            .contextMenu {
                Button(WorkbenchText.t("复制", "Duplicate")) { var next = clip; next.id = UUID(); next.revision = 0; if let range = try? MediaV2Session.range(start: clip.timelineRange.endSeconds, duration: clip.timelineRange.durationSeconds) { next.timelineRange = range; session.submit([.insertClip(trackID: track.id, clip: next, index: nil)]) } }
                Button(WorkbenchText.t("删除", "Delete"), role: .destructive) { session.submit([.removeClip(trackID: track.id, clipID: clip.id, expectedRevision: clip.revision)]) }
            }
            .disabled(track.isLocked || session.saving)
    }
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
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.35)).frame(width: 3, height: 24)
            .frame(width: 22, height: 44).contentShape(Rectangle()).offset(x: delta)
            .highPriorityGesture(DragGesture(minimumDistance: 3).onChanged { value in
                if original == nil { original = clip; session.select(track, clip: clip) }; delta = value.translation.width
            }.onEnded { value in
                defer { original = nil; delta = 0 }
                guard let original else { return }
                let edge = leading ? original.timelineRange.startSeconds : original.timelineRange.endSeconds
                session.trimTimelineEdge(track: track, clip: original, leading: leading, to: edge + Double(value.translation.width / scale))
            })
            .accessibilityLabel(leading ? WorkbenchText.t("修剪入点", "Trim in") : WorkbenchText.t("修剪出点", "Trim out"))
    }
}
#endif
