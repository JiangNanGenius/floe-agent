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
                    if let sheet=session.project.sheets.first(where:{sheet in sheet.symbols.contains{issue.objectIDs.contains($0.id) || issue.objectIDs.contains($0.componentID)} || sheet.wires.contains{issue.objectIDs.contains($0.id)} || sheet.buses.contains{bus in issue.objectIDs.contains(bus.id) || (bus.entries ?? []).contains{issue.objectIDs.contains($0.id)}}}){
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
        let names:[String:(String,String)]=["duplicate_reference":("元件编号重复","Duplicate reference"),"unannotated_component":("元件尚未编号","Unannotated component"),"missing_symbol":("缺少元件符号","Missing symbol"),"unplaced_component":("元件尚未放置","Unplaced component"),"duplicate_symbol_unit":("符号单元重复","Duplicate symbol unit"),"connected_no_connect":("不连接标记处已有连线","Connected no-connect marker"),"unconnected_pin":("引脚未连接","Unconnected pin"),"conflicting_outputs":("输出引脚冲突","Conflicting outputs"),"undriven_power":("电源引脚缺少驱动","Undriven power input"),"undriven_input":("输入引脚缺少驱动","Undriven input"),"geometry":("几何资料不完整","Incomplete geometry"),"copperClearance":("铜间净距","Copper clearance"),"trackWidth":("走线宽度","Track width"),"viaDiameter":("过孔直径","Via diameter"),"viaDrill":("过孔孔径","Via drill"),"viaAnnularWidth":("过孔焊环","Via annulus"),"boardEdge":("板边距离","Board edge clearance"),"keepout":("禁布区冲突","Keepout conflict"),"unconnectedNet":("网络尚未布通","Unrouted connection"),"bus_members_missing":("总线尚未声明成员","Bus members are not declared"),"bus_members_invalid":("总线成员名称不明确","Invalid bus member names"),"bus_entry_detached":("引出线未接到总线","Entry is detached from the bus"),"bus_entry_no_wire":("引出线尚未接线","Entry has no wire"),"bus_entry_ambiguous_nets":("引出端接触多个网络","Entry touches multiple nets"),"bus_entry_member_unidentified":("引出网络缺少成员标签","Entry net has no member label"),"bus_member_short":("不同总线成员已短接","Different bus members are shorted")]
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
    let onExportPreview:((EDAExchangeFile,UInt64)->Void)?
    @State private var files:[EDAExchangeFile]=[]
    @State private var limitations:[String]=[]
    @State private var exportIssues:[EDAManufacturingIssue]=[]
    @State private var selected:EDAExchangeFile?
    @State private var exporting=false
    @State private var boardID:UUID?
    @State private var variant=""
    @State private var sourceRevision:UInt64?
    @State private var generationID:UUID?
    @State private var generationTask:Task<Void,Never>?
    @State private var generating=false
    public init(session:EDWorkbenchSession,onExportPreview:((EDAExchangeFile,UInt64)->Void)?=nil){self.session=session;self.onExportPreview=onExportPreview}
    public var body:some View{List{
        Section{
            Picker("PCB",selection:$boardID){ForEach(session.project.boards){Text($0.name).tag(Optional($0.id))}}
            Picker(edText("装配变体","Assembly variant"),selection:$variant){ForEach(session.project.variants,id:\.self){Text($0).tag($0)}}
        }
        Section(edText("工程与网络","Project and connectivity")){outputButtons([.project,.netlist])}
        Section(edText("制造与装配","Fabrication and assembly")){outputButtons([.gerber,.excellon,.bom,.positions])}
        Section(edText("图纸","Drawings")){outputButtons([.boardSVG,.schematicSVG])}
        if generating{Section{ProgressView(edText("正在生成文件…","Generating files…"))}}
        if let revision=sourceRevision,revision != session.revision{Section{Text(edText("工程已修改，请重新生成导出文件。","The design changed. Generate the files again.")).foregroundStyle(.orange)}}
        if !files.isEmpty{Section(edText("已生成文件","Generated files")){ForEach(files.indices,id:\.self){i in outputRow(files[i])}}}
        if !exportIssues.isEmpty{Section(edText("需要补全的设计信息","Design data required")){ForEach(Array(exportIssues.enumerated()),id:\.offset){_,issue in
            VStack(alignment:.leading){Text(issueTitle(issue.code));DisclosureGroup(edText("定位详情","Location details")){Text(issue.path+(issue.objectID.map{" · "+$0.uuidString} ?? "")).font(.caption.monospaced()).textSelection(.enabled)}}
        }}}
        if !limitations.isEmpty{Section{DisclosureGroup(edText("导出范围与说明","Export scope and details")){ForEach(limitations,id:\.self){Text($0).font(.caption)}}}}
    }.onAppear{boardID=boardID ?? session.project.boards.first?.id;variant=session.project.variants.contains(variant) ? variant:(session.project.variants.contains("Default") ? "Default":session.project.variants.first ?? "")}
    .onDisappear{generationTask?.cancel();generationID=nil;generating=false}
    .fileExporter(isPresented:$exporting,document:EDAExportDocument(data:selected?.data ?? Data()),contentType:.data,defaultFilename:selected?.name ?? "Project.floeeda"){result in if case .failure(let error)=result{session.report(error,operation:"export")}}}
    // Matches the App's existing EngineeringPreviewKind.gerber extensions;
    // a component-only host keeps the original export action by default.
    private let previewExtensions:Set<String>=["gbr","ger","gerber","gtl","gbl","gts","gbs","gto","gbo","gko","gm1","gml","drl","xln"]
    @ViewBuilder private func outputRow(_ file:EDAExchangeFile)->some View{
        if let onExportPreview,previewExtensions.contains((file.name as NSString).pathExtension.lowercased()){
            HStack(spacing:8){
                Button{
                    guard let revision=sourceRevision,revision==session.revision else{return}
                    onExportPreview(file,revision)
                }label:{HStack{
                    Label(file.name,systemImage:"doc.viewfinder");Spacer()
                    VStack(alignment:.trailing){Text(edText("预览","Preview"));Text(ByteCountFormatter.string(fromByteCount:Int64(file.data.count),countStyle:.file)).font(.caption).foregroundStyle(.secondary)}
                }.frame(maxWidth:.infinity,minHeight:44).contentShape(Rectangle())}
                .buttonStyle(.plain)
                .accessibilityLabel(edText("预览 ","Preview ")+file.name)
                .accessibilityIdentifier("electronics.output.preview."+file.name)
                Button{selected=file;exporting=true}label:{Image(systemName:"square.and.arrow.up").frame(width:44,height:44).contentShape(Rectangle())}
                    .buttonStyle(.borderless)
                    .accessibilityLabel(edText("存储或分享 ","Save or share ")+file.name)
                    .accessibilityIdentifier("electronics.output.export."+file.name)
            }.disabled(sourceRevision != session.revision)
        }else{
            Button{selected=file;exporting=true}label:{HStack{Label(file.name,systemImage:"doc");Spacer();Text(ByteCountFormatter.string(fromByteCount:Int64(file.data.count),countStyle:.file)).foregroundStyle(.secondary)}.frame(minHeight:44)}
                .disabled(sourceRevision != session.revision)
                .accessibilityIdentifier("electronics.output.export."+file.name)
        }
    }
    private func outputButtons(_ formats:[EDAExportFormat])->some View{ForEach(formats,id:\.self){format in Button(title(format)){generate(format)}.disabled(generating)}}
    @MainActor private func generate(_ format:EDAExportFormat){
        generationTask?.cancel();let token=UUID();generationID=token;generating=true;files=[];exportIssues=[];limitations=[];sourceRevision=nil
        let targetBoard=boardID,targetVariant=variant
        generationTask=Task{
            defer{if generationID==token{generating=false}}
            do{
                try Task.checkCancellation()
                let bundle=try await session.export(format:format,boardID:targetBoard,variant:targetVariant)
                guard !Task.isCancelled,generationID==token,session.revision==bundle.revision else{return}
                files=bundle.files;limitations=bundle.limitations;sourceRevision=bundle.revision
            }catch{
                guard !Task.isCancelled,generationID==token else{return}
                if let failure=error as? EDAManufacturingFailure{exportIssues=failure.issues}
                session.report(error,operation:"export")
            }
        }
    }
    private func title(_ format:EDAExportFormat)->String{switch format{
        case .project:edText("可编辑工程","Editable project")
        case .netlist:edText("网表","Netlist")
        case .bom:edText("物料清单（BOM）","Bill of materials (BOM)")
        case .positions:edText("贴片坐标","Component placement")
        case .gerber:edText("Gerber 铜层与板框","Gerber copper layers and profile")
        case .excellon:edText("Excellon 钻孔与槽孔","Excellon drill and slot files")
        case .boardSVG:edText("PCB 图纸（SVG）","Board drawing (SVG)")
        case .schematicSVG:edText("原理图（SVG）","Schematic drawings (SVG)")}}
    private func issueTitle(_ code:String)->String{switch code{
        case "zone_fill_not_current":edText("铜区尚无当前有效填充。","A copper zone needs a current fill.")
        case "pad_drill_plating_unspecified":edText("请选择焊盘孔壁是否电镀。","Specify whether the pad hole is plated.")
        case "round_rectangle_radius_missing":edText("圆角焊盘尚缺圆角半径。","A rounded pad is missing its corner radius.")
        case "graphic_layer_unspecified":edText("图形尚未指定制造层。","A graphic has no assigned fabrication layer.")
        case "missing_footprint_definition":edText("缺少封装定义。","A footprint definition is missing.")
        case "no_drilling_geometry":edText("此板尚无钻孔或明确槽孔。","The board has no holes or explicit slots.")
        default:edText("这项设计信息尚不支持导出。","This design data is not supported for export yet.")}}
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
        let holes=board.holes.filter{$0.endPosition == nil}.map{($0.position,$0.diameter)}+board.vias.map{($0.position,$0.drill)}+board.footprints.flatMap{fp -> [(EDAPoint,Double)] in
            (project.footprints.first{$0.id==fp.definitionID}?.pads ?? []).compactMap{pad in pad.drill.map{(fp.point(pad.position),$0)}}
        }
        for (center,diameter) in holes{polygon((0..<48).reversed().map{let a=Double($0)*2*Double.pi/48;return center + .init(cos(a)*diameter/2,sin(a)*diameter/2)})}
        for hole in board.holes {
            guard let end=hole.endPosition else{continue}
            let angle=atan2(end.y-hole.position.y,end.x-hole.position.x),r=hole.diameter/2
            var contour:[EDAPoint]=[]
            for i in 0...24 {let a=angle-Double.pi/2+Double(i)*Double.pi/24;contour.append(end + EDAPoint(cos(a)*r,sin(a)*r))}
            for i in 0...24 {let a=angle+Double.pi/2+Double(i)*Double.pi/24;contour.append(hole.position + EDAPoint(cos(a)*r,sin(a)*r))}
            polygon(Array(contour.reversed()))
        }
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

