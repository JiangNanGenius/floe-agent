// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeWorkbench

struct MediaV2MotionPathOverlay: View {
    @Bindable var session: MediaV2Session
    @AppStorage(MediaDrawingInputPolicy.preferenceKey) private var fingerDrawing = false
    @State private var points: [ImageFreehandStroke.Point] = []
    @State private var revision: Int64?
    @State private var clipID: UUID?
    @State private var revoked = false
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                SwiftUI.Canvas { context,size in
                    let route = points.isEmpty ? savedRoute : points
                    guard let first = route.first else { return }
                    var line = Path();line.move(to:.init(x:first.x*size.width,y:first.y*size.height))
                    for p in route.dropFirst() { line.addLine(to:.init(x:p.x*size.width,y:p.y*size.height)) }
                    context.stroke(line,with:.color(.white),lineWidth:3)
                    context.stroke(line,with:.color(.accentColor),style:.init(lineWidth:1.5,dash:[5,3]))
                    for p in [first,route.last!] {
                        context.fill(Path(ellipseIn:.init(x:p.x*size.width-4,y:p.y*size.height-4,width:8,height:8)),with:.color(.accentColor))
                    }
                }.allowsHitTesting(false)
                WorkbenchPressureSurface(fingerDrawing:fingerDrawing,onChanged:{ point,_ in
                    guard !revoked else { return }
                    if revision == nil {
                        revision = session.document.revision;clipID = session.selectedClipID
                        session.scrub(session.playhead)
                    }
                    guard let selected = session.selectedClip,selected.track.kind == .visual,!selected.track.isLocked else {
                        revoked = true;return
                    }
                    let p = ImageFreehandStroke.Point(x:max(0,min(1,point.x/max(1,geometry.size.width))),
                        y:max(0,min(1,point.y/max(1,geometry.size.height))))
                    if let last = points.last,last == p { return }
                    guard points.count < 512 else {
                        revoked = true;session.diagnostic = WorkbenchText.t("路线太长，请画短一些。", "The path is too long. Draw a shorter route.");return
                    }
                    points.append(p)
                },onEnded:commit,onCancelled:reset)
            }
        }.onChange(of:session.document.revision) { _,_ in if revision != nil { revoked = true } }
            .onChange(of:session.selectedClipID) { _,_ in if revision != nil { revoked = true } }
            .onDisappear(perform:reset)
            .accessibilityLabel(WorkbenchText.t("绘制运动路径", "Draw motion path"))
    }
    private var savedRoute: [ImageFreehandStroke.Point] {
        guard let clip = session.selectedClip?.clip,
              let x = clip.keyframeTracks.first(where:{$0.property == "centerX" || $0.property == "transform.centerX"}),
              let y = clip.keyframeTracks.first(where:{$0.property == "centerY" || $0.property == "transform.centerY"}) else { return [] }
        return (0...64).compactMap { index in
            let at = clip.timelineRange.durationSeconds*Double(index)/64
            guard let a = session.evaluatedKeyframe(x,at:at),let b = session.evaluatedKeyframe(y,at:at) else { return nil }
            return .init(x:a,y:b)
        }
    }
    private func commit() {
        defer { reset() }
        guard !revoked,points.count >= 2,let revision,revision == session.document.revision,
              let clipID,clipID == session.selectedClipID else { return }
        var input = MediaV2ToolInput();input.objectID = clipID;input.expectedRevision = revision;input.points = points
        Task { do { _ = try await session.performTool("video.motion-path",input:input) } catch { session.diagnostic = error.localizedDescription } }
    }
    private func reset() { points = [];revision = nil;clipID = nil;revoked = false }
}
#endif
