// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import SceneKit
import FloeNCProgram

public struct NCProgramWorkbenchView:View {
    private let directory:URL
    private let initialFile:URL?
    @State private var session=NCLocalSession()
    @State private var importing=false
    @State private var share:NCShare?
    @State private var notice=""
    @State private var position=0.0
    @State private var playing=false
    @State private var camera="iso"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    public init(directory:URL,initialFile:URL? = nil) { self.directory=directory;self.initialFile=initialFile }
    public var body:some View {
        NavigationStack {
            Group {
                if sizeClass == .regular { HStack(spacing:0) { sourcePanel.frame(width:340);Divider();previewPanel } }
                else { VStack(spacing:0) { sourcePanel.frame(maxHeight:290);Divider();previewPanel } }
            }
            .navigationTitle(L("G-code 轨迹","G-code trajectory"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(L("完成","Done")) { dismiss() }.accessibilityIdentifier("nc.done") }
                ToolbarItemGroup(placement:.primaryAction) {
                    if session.busy { Button(L("取消","Cancel"),systemImage:"stop.circle") { playing=false;session.cancel() }.accessibilityIdentifier("nc.cancel") }
                    else { Button(L("解码并核对","Interpret and verify"),systemImage:"play.rectangle") { playing=false;position=0;session.calculate() }.buttonStyle(.borderedProminent).accessibilityIdentifier("nc.decode") }
                    Menu {
                        Button(L("圆弧与样条例","Arcs and splines")) { loadSmooth() }.accessibilityIdentifier("nc.sample.smooth")
                        Button(L("直径模式车削例","Diameter-mode turning")) { replace(NCSamples.turning) }.accessibilityIdentifier("nc.sample.turning")
                        Button(L("导入 G-code","Import G-code")) { importing=true }
                        Divider()
                        Button(L("导出 G-code","Export G-code")) { export() }.disabled(session.program == nil || session.busy).accessibilityIdentifier("nc.export")
                        Button(L("保存工程","Save project")) { save() }.disabled(session.program == nil || session.busy).accessibilityIdentifier("nc.save")
                        Button(L("重新打开","Reopen")) { notice="";playing=false;position=0;session.reopen(archive) }.accessibilityIdentifier("nc.reopen")
                    } label: { Image(systemName:"ellipsis.circle").frame(width:44,height:44) }.accessibilityIdentifier("nc.menu")
                }
            }
        }
        .fileImporter(isPresented:$importing,allowedContentTypes:[.plainText,.data]) { result in
            do {
                try load(try result.get())
            } catch { notice=error.localizedDescription }
        }
        .sheet(item:$share) { item in ShareFile(url:item.url) }
        .onChange(of:session.revision) { _,_ in playing=false;position=0 }
        .onDisappear { playing=false;session.cancel() }
        .task {
            if let initialFile { do { try load(initialFile);session.calculate() } catch { notice=error.localizedDescription } }
            else if session.source.isEmpty { loadSmooth() }
        }
        .task(id:playing) {
            guard playing else { return }
            if position >= 1 { position=0 }
            while !Task.isCancelled && playing && position < 1 {
                try? await Task.sleep(for:.milliseconds(40));if Task.isCancelled { break }
                position=min(1,position+0.004)
            }
            if !Task.isCancelled { playing=false }
        }
    }
    private var sourcePanel:some View {
        VStack(alignment:.leading,spacing:10) {
            Text(L("程序","Program")).font(.headline)
            TextEditor(text:Binding(get:{ session.source },set:{ replace($0) }))
                .font(.system(.caption,design:.monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never)
                .accessibilityIdentifier("nc.source")
            Text(L("弦高公差（mm）","Chord tolerance (mm)")).font(.caption).foregroundStyle(.secondary)
            Picker(L("弦高公差","Chord tolerance"),selection:Binding(get:{ session.configuration.chordToleranceMM },set:{ session.setTolerance($0) })) {
                Text("0.1").tag(0.1);Text("0.02").tag(0.02);Text("0.005").tag(0.005)
            }.pickerStyle(.segmented)
            Text(L("圆弧和样条保留原始定义；直线保持直线。","Arcs and splines retain their definitions; lines remain straight."))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }
    private var previewPanel:some View {
        VStack(spacing:0) {
            HStack {
                Text(L("轨迹预览","Trajectory preview")).font(.headline)
                Spacer()
                Picker(L("视角","View"),selection:$camera) {
                    Text(L("等轴","ISO")).tag("iso");Text(L("俯视","Top")).tag("top");Text(L("前视","Front")).tag("front")
                }.pickerStyle(.segmented).frame(maxWidth:260)
            }.padding(16)
            ZStack(alignment:.topLeading) {
                NCPathViewport(paths:session.paths,revision:session.revision,position:position,camera:camera)
                if session.busy { ProgressView(L("解码与回读核对…","Interpreting and checking round-trip…")).padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:8)).padding() }
            }.frame(minHeight:160,maxHeight:.infinity)
            HStack {
                Button(playing ? L("暂停","Pause") : L("播放","Play"),systemImage:playing ? "pause.fill" : "play.fill") { playing.toggle() }
                    .disabled(session.program == nil).accessibilityIdentifier("nc.play")
                Slider(value:$position,in:0...1).disabled(session.program == nil).accessibilityIdentifier("nc.position")
                Text(L("路径进度","Path progress")).font(.caption)
            }.padding(12)
            VStack(alignment:.leading,spacing:6) {
                Text(status).font(.callout).accessibilityIdentifier("nc.status")
                if let error=session.error { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("nc.error") }
                if !notice.isEmpty { Text(notice).foregroundStyle(.secondary).accessibilityIdentifier("nc.notice") }
                Text(L("按程序坐标预览；未提供毛坯、刀具总成和机床链，不计算去料、碰撞或加工用时。","Preview uses program coordinates. Stock, tool assembly and machine chain are not supplied; removal, collision and machining time are unavailable."))
                    .font(.caption).foregroundStyle(.secondary)
                if let p=session.program,!p.finalPosition.unresolvedAxes.isEmpty {
                    Text(L("未给定轴：","Unspecified axes: ")+p.finalPosition.unresolvedAxes+L("。未知直线轴按参考平面显示。",". Unknown linear axes are shown in a reference plane."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth:.infinity,alignment:.leading).padding(16)
        }
    }
    private var status:String {
        guard let report=session.report else { return L("导入或编辑程序后，解码并核对。","Import or edit a program, then interpret and verify.") }
        return L("回读一致","Round-trip verified")+" · \(report.motions) "+L("段","motions")+" · \(report.sampledPoints) "+L("点","points")
    }
    private var archive:URL { directory.appendingPathComponent("trajectory.floenc") }
    private func replace(_ text:String) { session.replaceSource(text);notice="" }
    private func load(_ url:URL) throws {
        let access=url.startAccessingSecurityScopedResource();defer { if access { url.stopAccessingSecurityScopedResource() } }
        if url.pathExtension.lowercased() == "floenc" {
            let value=try NCArchive.open(url);session.replaceSource(value.source,configuration:value.program.configuration);notice="";return
        }
        let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max
        guard size <= session.configuration.maximumBytes else { throw NCError("G-code byte budget exceeded") }
        let data=try Data(contentsOf:url)
        guard data.count <= session.configuration.maximumBytes,let text=String(data:data,encoding:.utf8) else { throw NCError("Expected bounded UTF-8 G-code text") }
        replace(text)
    }
    private func loadSmooth() { do { replace(NCCodec.encode(try NCSamples.smooth())) } catch { notice=error.localizedDescription } }
    private func save() { do { try session.save(to:archive);notice=L("已保存工程","Project saved") } catch { notice=error.localizedDescription } }
    private func export() {
        do { let url=directory.appendingPathComponent("trajectory.nc");try session.export(to:url);notice=L("已导出并核对 G-code","G-code exported and verified");share = .init(url:url) }
        catch { notice=error.localizedDescription }
    }
}
private struct NCShare:Identifiable { let id=UUID();let url:URL }

private struct NCPathViewport:UIViewRepresentable {
    let paths:[NCSampledPath]
    let revision:UUID
    let position:Double
    let camera:String
    @MainActor final class Coordinator {
        var revision:UUID?
        var camera=""
        var points=[NCVector]()
        let root=SCNNode(),marker=SCNNode(),cameraNode=SCNNode()
        var center=NCVector(0,0,0),span=1.0
    }
    func makeCoordinator()->Coordinator { .init() }
    func makeUIView(context:Context)->SCNView {
        let view=SCNView(),c=context.coordinator
        view.scene=SCNScene();view.backgroundColor=UIColor(white:0.94,alpha:1)
        view.antialiasingMode = .multisampling4X;view.allowsCameraControl=true
        view.scene!.rootNode.addChildNode(c.root);view.scene!.rootNode.addChildNode(c.marker)
        c.cameraNode.camera=SCNCamera();c.cameraNode.camera?.usesOrthographicProjection=true
        view.scene!.rootNode.addChildNode(c.cameraNode);view.pointOfView=c.cameraNode
        view.isAccessibilityElement=true;view.accessibilityIdentifier="nc.viewport"
        view.accessibilityLabel=L("G-code 三维轨迹，可旋转和缩放","G-code 3D trajectory; rotate and zoom")
        return view
    }
    func updateUIView(_ view:SCNView,context:Context) {
        let c=context.coordinator
        if c.revision != revision || c.points.isEmpty && paths.contains(where:{ !$0.samples.isEmpty }) {
            c.revision=revision;c.camera="";c.root.childNodes.forEach { $0.removeFromParentNode() }
            c.points=paths.flatMap { $0.samples.map(\.point) }
            for path in paths where path.samples.count >= 2 {
                let points=path.samples.map { SCNVector3($0.point.x,$0.point.y,$0.point.z) }
                let indices=(1..<points.count).flatMap { [Int32($0-1),Int32($0)] }
                let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:points)],elements:[SCNGeometryElement(indices:indices,primitiveType:.line)])
                geometry.firstMaterial?.lightingModel = .constant
                geometry.firstMaterial?.diffuse.contents=path.rapid ? UIColor.systemOrange : UIColor(red:0.1,green:0.32,blue:0.64,alpha:1)
                c.root.addChildNode(SCNNode(geometry:geometry))
            }
            if let first=c.points.first {
                var lo=first,hi=first
                for p in c.points { for axis in 0..<3 { lo[axis]=min(lo[axis],p[axis]);hi[axis]=max(hi[axis],p[axis]) } }
                c.center=(lo+hi)*0.5;c.span=max(1,max(hi.x-lo.x,max(hi.y-lo.y,hi.z-lo.z)))
            }
            c.marker.geometry=SCNSphere(radius:c.span*0.006)
            c.marker.geometry?.firstMaterial?.lightingModel = .constant
            c.marker.geometry?.firstMaterial?.diffuse.contents=UIColor.systemGreen
        }
        if c.camera != camera {
            c.camera=camera;let p=c.center,s=c.span
            switch camera {
            case "top":c.cameraNode.position=SCNVector3(p.x,p.y,p.z+s*2)
            case "front":c.cameraNode.position=SCNVector3(p.x,p.y-s*2,p.z)
            default:c.cameraNode.position=SCNVector3(p.x+s*1.2,p.y-s*1.3,p.z+s*1.6)
            }
            c.cameraNode.look(at:SCNVector3(p.x,p.y,p.z))
            c.cameraNode.camera?.orthographicScale=s*0.75;c.cameraNode.camera?.zNear=0.001;c.cameraNode.camera?.zFar=max(1000,s*20)
        }
        c.marker.isHidden=c.points.isEmpty
        if !c.points.isEmpty { let p=c.points[min(c.points.count-1,Int(position*Double(c.points.count-1)))];c.marker.position=SCNVector3(p.x,p.y,p.z) }
        view.accessibilityValue="\(paths.count) motions; \(c.points.count) points; fraction \(String(format:"%.3f",position))"
        view.setNeedsDisplay()
    }
}
#endif
