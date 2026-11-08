// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import UniformTypeIdentifiers
import SceneKit
import FloeElectronicsCore
#if canImport(UIKit)
import UIKit
private typealias EDABezierPath=UIBezierPath
#elseif canImport(AppKit)
import AppKit
private typealias EDABezierPath=NSBezierPath
#endif

public struct EDAChecksView:View {
    @Bindable var session:EDWorkbenchSession
    let onFocus:((EDAFocusRequest)->Void)?
    @State private var boardID:UUID?
    public init(session:EDWorkbenchSession,onFocus:((EDAFocusRequest)->Void)?=nil){self.session=session;self.onFocus=onFocus}
    public var body:some View {List{
        Section{
            Button(edText("原理图电气检查","Check schematic")){Task{await session.runCheck()}}
            Picker("PCB",selection:$boardID){ForEach(session.project.boards){Text($0.name).tag(Optional($0.id))}}
            Button(edText("PCB 规则检查","Check board rules")){guard let id=boardID ?? session.project.boards.first?.id else{return};Task{await session.runCheck(boardID:id)}}
            if session.isChecking{HStack{ProgressView();Text(edText("正在检查…","Checking…"));Spacer();Button(edText("停止","Stop")){session.cancelCheck()}}}
        }.disabled(session.busy)
        if let report=session.ercReport {
            Section(edText("原理图检查结果","Schematic results")){
                if report.revision != session.revision{Text(edText("工程已修改，请重新检查。","The design changed. Run the check again.")).foregroundStyle(.orange)}
                if report.issues.isEmpty{Text(edText("本次检查未发现电气问题。","No electrical issues were found by this check."))}
                ForEach(report.issues){issue in Button{
                    if let sheet=session.project.sheets.first(where:{sheet in sheet.symbols.contains{issue.objectIDs.contains($0.id) || issue.objectIDs.contains($0.componentID)} || sheet.wires.contains{issue.objectIDs.contains($0.id)}}){
                        let request=EDAFocusRequest(context:.schematic(sheetID:sheet.id),positionMillimetres:issue.position ?? .zero,objectIDs:Set(issue.objectIDs));session.requestFocus(request);onFocus?(request)
                    }
                }label:{VStack(alignment:.leading){Text(issueTitle(issue.code));Text(issue.severity.rawValue).font(.caption).foregroundStyle(.secondary)}}}
            }
        }
        if let report=session.drcReport {
            Section(edText("PCB 检查结果","Board results")){
                if report.revision != session.revision{Text(edText("工程已修改，请重新检查。","The design changed. Run the check again.")).foregroundStyle(.orange)}
                if report.issues.isEmpty{Text(edText("本次已支持的规则未发现问题。","No issues were found by the supported rules."))}
                ForEach(report.issues){issue in Button{
                    let ids=Set(issue.objects.map{$0.footprintID ?? $0.objectID}),request=EDAFocusRequest(context:.board(boardID:report.boardID),positionMillimetres:issue.position,objectIDs:ids);session.requestFocus(request);onFocus?(request)
                }label:{VStack(alignment:.leading){Text(issueTitle(issue.rule.rawValue));if let measured=issue.measured,let required=issue.required{Text(String(format:edText("实测 %.3f mm · 要求 %.3f mm","Measured %.3f mm · required %.3f mm"),measured,required)).font(.caption)}}}}
                DisclosureGroup(edText("检查范围与详细结果","Coverage and details")){Text(json(report)).font(.caption.monospaced()).textSelection(.enabled)}
            }
        }
    }.onAppear{boardID=boardID ?? session.project.boards.first?.id}}
    private func json<T:Encodable>(_ value:T)->String{let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];return (try? encoder.encode(value)).flatMap{String(data:$0,encoding:.utf8)} ?? ""}
    private func issueTitle(_ code:String)->String {
        let names:[String:(String,String)]=["duplicate_reference":("元件编号重复","Duplicate reference"),"unannotated_component":("元件尚未编号","Unannotated component"),"missing_symbol":("缺少元件符号","Missing symbol"),"unplaced_component":("元件尚未放置","Unplaced component"),"duplicate_symbol_unit":("符号单元重复","Duplicate symbol unit"),"connected_no_connect":("不连接标记处已有连线","Connected no-connect marker"),"unconnected_pin":("引脚未连接","Unconnected pin"),"conflicting_outputs":("输出引脚冲突","Conflicting outputs"),"undriven_power":("电源引脚缺少驱动","Undriven power input"),"undriven_input":("输入引脚缺少驱动","Undriven input"),"geometry":("几何资料不完整","Incomplete geometry"),"copperClearance":("铜间净距","Copper clearance"),"trackWidth":("走线宽度","Track width"),"viaDiameter":("过孔直径","Via diameter"),"viaDrill":("过孔孔径","Via drill"),"viaAnnularWidth":("过孔焊环","Via annulus"),"boardEdge":("板边距离","Board edge clearance"),"keepout":("禁布区冲突","Keepout conflict"),"unconnectedNet":("网络尚未布通","Unrouted connection")]
        if let name=names[code]{return edText(name.0,name.1)}
        return edText("需要检查的项目","Item requiring review")
    }
}

private struct EDAExportDocument:FileDocument {
    static var readableContentTypes:[UTType]{[.data]}
    var data:Data
    init(data:Data){self.data=data}
    init(configuration:ReadConfiguration)throws{guard let data=configuration.file.regularFileContents else{throw EDAError.invalid("export data")};self.data=data}
    func fileWrapper(configuration:WriteConfiguration)throws->FileWrapper{FileWrapper(regularFileWithContents:data)}
}
public struct EDAOutputsView:View {
    @Bindable var session:EDWorkbenchSession
    @State private var files:[EDAExchangeFile]=[]
    @State private var limitations:[String]=[]
    @State private var selected:EDAExchangeFile?
    @State private var exporting=false
    @State private var boardID:UUID?
    @State private var variant=""
    public init(session:EDWorkbenchSession){self.session=session}
    public var body:some View{List{
        Section{
            Picker("PCB",selection:$boardID){ForEach(session.project.boards){Text($0.name).tag(Optional($0.id))}}
            Picker(edText("装配变体","Assembly variant"),selection:$variant){ForEach(session.project.variants,id:\.self){Text($0).tag($0)}}
            ForEach(EDAExportFormat.allCases,id:\.self){format in Button(title(format)){do{
                let bundle=try EDAExchange.export(session.project,format:format,boardID:boardID,variant:variant);files=bundle.files;limitations=bundle.limitations
            }catch{session.report(error,operation:"export")}}}
        }
        if !files.isEmpty{Section(edText("已生成文件","Generated files")){ForEach(files.indices,id:\.self){i in Button{selected=files[i];exporting=true}label:{HStack{Label(files[i].name,systemImage:"doc");Spacer();Text(ByteCountFormatter.string(fromByteCount:Int64(files[i].data.count),countStyle:.file)).foregroundStyle(.secondary)}}}}}
        if !limitations.isEmpty{Section(edText("导出说明","Export details")){ForEach(limitations,id:\.self){Text($0).font(.caption)}}}
    }.onAppear{boardID=boardID ?? session.project.boards.first?.id;variant=session.project.variants.contains(variant) ? variant:(session.project.variants.contains("Default") ? "Default":session.project.variants.first ?? "")}
    .fileExporter(isPresented:$exporting,document:EDAExportDocument(data:selected?.data ?? Data()),contentType:.data,defaultFilename:selected?.name ?? "Project.floeeda"){result in if case .failure(let error)=result{session.report(error,operation:"export")}}}
    private func title(_ format:EDAExportFormat)->String{switch format{case .project:edText("导出可编辑工程","Export editable project");case .netlist:edText("导出网表","Export netlist");case .bom:edText("导出物料清单","Export BOM");case .positions:edText("导出贴片坐标","Export placement positions");case .boardSVG:edText("导出 PCB 图纸（SVG）","Export board drawing (SVG)");case .schematicSVG:edText("导出原理图（SVG）","Export schematic drawings (SVG)")}}
}

public struct EDABoard3DView:View {
    let project:EDAProject
    let boardID:UUID?
    public init(project:EDAProject,boardID:UUID?=nil){self.project=project;self.boardID=boardID}
    public var body:some View{VStack(spacing:0){
        SceneView(scene:scene(),options:[.allowsCameraControl,.autoenablesDefaultLighting])
        Text(edText("三维显示实际板形、开孔与厚度；尚未加载元件三维模型。","3D shows the actual board outline, holes and thickness. Component 3D models are not loaded.")).font(.caption).foregroundStyle(.secondary).padding(8)
    }}
    private func scene()->SCNScene {
        let scene=SCNScene()
        guard let board=project.boards.first(where:{$0.id==boardID}) ?? project.boards.first,!board.outline.isEmpty else{return scene}
        let path=EDABezierPath()
        func polygon(_ points:[EDAPoint]){guard let first=points.first else{return};path.move(to:.init(x:first.x,y:first.y));for p in points.dropFirst(){
#if canImport(UIKit)
            path.addLine(to:.init(x:p.x,y:p.y))
#else
            path.line(to:.init(x:p.x,y:p.y))
#endif
        };path.close()}
        polygon(board.outline)
        for points in board.cutouts{polygon(Array(points.reversed()))}
        let holes=board.holes.map{($0.position,$0.diameter)}+board.vias.map{($0.position,$0.drill)}+board.footprints.flatMap{fp -> [(EDAPoint,Double)] in
            (project.footprints.first{$0.id==fp.definitionID}?.pads ?? []).compactMap{pad in pad.drill.map{(fp.point(pad.position),$0)}}
        }
        for (center,diameter) in holes{polygon((0..<48).reversed().map{let a=Double($0)*2*Double.pi/48;return center + .init(cos(a)*diameter/2,sin(a)*diameter/2)})}
        let thickness=board.layers.reduce(0){$0+$1.thickness}
        let shape=SCNShape(path:path,extrusionDepth:CGFloat(max(0.01,thickness)))
#if canImport(UIKit)
        shape.firstMaterial?.diffuse.contents=UIColor.systemGreen
#elseif canImport(AppKit)
        shape.firstMaterial?.diffuse.contents=NSColor.systemGreen
#endif
        let node=SCNNode(geometry:shape);scene.rootNode.addChildNode(node)
        let center=EDAPoint(board.outline.map(\.x).reduce(0,+)/Double(board.outline.count),board.outline.map(\.y).reduce(0,+)/Double(board.outline.count))
        let camera=SCNNode();camera.camera=SCNCamera();camera.camera?.zFar=100_000
        camera.position=SCNVector3(Float(center.x),Float(center.y-120),140);camera.look(at:SCNVector3(Float(center.x),Float(center.y),0));scene.rootNode.addChildNode(camera)
        return scene
    }
}

