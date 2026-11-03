// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeCAD
import FloeWorkbench

/// Existing CAD selection and BasicMachiningCenter own the operation, snapshot, jobs and result.
@MainActor
struct CADMultiAxisPreviewView:View {
    let document:FloeCADDocument
    let selection:CADSelectionContext?
    @ObservedObject var workspace:WorkspaceCenter
    let root:URL
    let workspaceID:UUID
    let conversationID:UUID
    @EnvironmentObject private var environment:AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var resolution=1.0
    @State private var radius=2.0
    @State private var length=10.0
    @State private var start=[0.0,0.0,0.0]
    @State private var end=[4.0,2.0,1.0]
    @State private var axis0=[0.0,0.0,1.0]
    @State private var axis1=[0.5,-0.4330127018922193,0.75]
    @State private var checkFixture=false
    @State private var holderRadius=3.0
    @State private var holderLength=6.0
    @State private var holderOffset=10.0
    @State private var fixtureMin=[20.0,20.0,20.0]
    @State private var fixtureMax=[22.0,22.0,22.0]
    @State private var study:CADBasicMachiningStudy?
    @State private var starting=false
    @State private var message:String?
    @State private var showingPath:String?
    private func t(_ zh:String,_ en:String)->String {CADBasicMachiningText.t(zh,en)}
    private var part:CADSelectionContext.Body? {guard let selection,selection.bodies.count==1,selection.bodies[0].analyticBRep else{return nil};return selection.bodies[0]}
    private var running:Bool {starting || study.map{[.preparingEnvironment,.simulating,.cancelling].contains($0.state)} == true}
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    Text(part?.name ?? t("先选中一个已保存的实体零件","Select one saved solid part first"))
                    Text(t("以零件外框为毛坯，预览刀具移动与倾转后的去料。","Preview material removal from a blank around the part as the tool moves and tilts."))
                        .font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup(t("预览范围","Preview scope")) {
                        Text(t("结果为近似网格及体积范围，不生成加工程序。夹具检测仅覆盖所设的圆柱刀柄和盒状夹具。","Results include approximate meshes and a volume range. No machining program is generated. Fixture checks cover the configured cylindrical holder and box fixture."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section(t("刀具与毛坯 · mm","Tool and stock · mm")) {
                    Picker(t("体素大小","Voxel size"),selection:$resolution) {ForEach([0.25,0.5,1.0],id:\.self){Text($0,format:.number).tag($0)}}
                    number(t("刀具半径","Tool radius"),$radius);number(t("切削长度","Cutting length"),$length)
                }.disabled(running)
                Section(t("刀尖与刀轴方向","Tool tip and axis toward spindle")) {
                    vector(t("起点 · mm","Start · mm"),$start);vector(t("终点 · mm","End · mm"),$end)
                    vector(t("起点刀轴 IJK","Start axis IJK"),$axis0);vector(t("终点刀轴 IJK","End axis IJK"),$axis1)
                }.disabled(running)
                Section(t("刀柄与夹具","Holder and fixture")) {
                    Toggle(t("检查一个圆柱刀柄与盒状夹具","Check one cylindrical holder and box fixture"),isOn:$checkFixture)
                    if checkFixture {number(t("刀柄半径 · mm","Holder radius · mm"),$holderRadius);number(t("刀柄长度 · mm","Holder length · mm"),$holderLength);number(t("距刀尖 · mm","Offset from tip · mm"),$holderOffset);vector(t("夹具最小坐标 · mm","Fixture minimum · mm"),$fixtureMin);vector(t("夹具最大坐标 · mm","Fixture maximum · mm"),$fixtureMax)
                        Text(t("显示“需细化”时，可减小体素大小后重新预览。","If refinement is needed, choose a smaller voxel size and preview again.")).font(.footnote).foregroundStyle(.secondary)
                    }
                }.disabled(running)
                Section {
                    if running {ProgressView(t("正在准备或计算，可在任务中查看进度","Preparing or computing; progress is available in Jobs"))}
                    if let study {
                        Text(stateText(study.state)).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("cad.multiAxis.state")
                        if let error=study.error {DisclosureGroup(t("错误详情","Error details")){Text(error).font(.footnote).textSelection(.enabled)}}
                        if study.state == .ready,let summary=study.previewSummary,let artifact=study.artifact {
                            if let volume=study.remainingMM3 {LabeledContent(t("名义剩余体积 · mm³","Nominal remaining · mm³"),value:volume.formatted(.number.precision(.fractionLength(3))))}
                            Text(t("连续剩余体积范围：","Continuous remaining volume: ")+summary.continuousRemainingLowerMM3.formatted(.number.precision(.fractionLength(3)))+" – "+summary.continuousRemainingUpperMM3.formatted(.number.precision(.fractionLength(3)))+" mm³")
                            ForEach(summary.fixtures,id:\.id){f in LabeledContent(f.id,value:fixtureText(f.state))}
                            Button(t("查看名义毛坯","View nominal stock")){showingPath=artifact.workspacePath}.accessibilityIdentifier("cad.multiAxis.nominal")
                            Button(t("查看剩余下界","View remaining lower bound")){showingPath=study.relativeDirectory+"/output/motion/remaining-lower.stl"}
                            Button(t("查看剩余上界","View remaining upper bound")){showingPath=study.relativeDirectory+"/output/motion/remaining-upper.stl"}
                        }
                        if [.preparingEnvironment,.simulating,.cancelling].contains(study.state) {Button(t("取消","Cancel"),role:.cancel){Task{do{self.study=try await environment.basicMachiningCenter.cancel(study.id)}catch{message=error.localizedDescription}}}.disabled(study.state == .cancelling)}
                    }
                    if let message {Text(message).font(.footnote).textSelection(.enabled)}
                    Button(t("准备环境并预览","Prepare and preview")){startPreview()}.disabled(running||part==nil||document.isReadOnly).accessibilityIdentifier("cad.multiAxis.start")
                    Text(t("使用当前任务的 Mac。首次使用会下载约 29 MB，可在任务中查看进度。","Uses this task's Mac. First use downloads about 29 MB; progress is available in Jobs.")).font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle(t("多轴去料预览","Multi-axis Stock Preview"))
                .toolbar{ToolbarItem(placement:.cancellationAction){Button(t("完成","Done")){dismiss()}}}
                .task {
                    if let p=part,p.bounds.count==2,p.bounds.allSatisfy({$0.count==3}) {let lo=p.bounds[0],hi=p.bounds[1],cx=(lo[0]+hi[0])/2,cy=(lo[1]+hi[1])/2,cz=hi[2]-min(10,(hi[2]-lo[2])/2);start=[cx-min(3,(hi[0]-lo[0])/4),cy-1,cz];end=[cx+min(3,(hi[0]-lo[0])/4),cy+1,cz+1];fixtureMin=[hi[0]+4,hi[1]+4,hi[2]+4];fixtureMax=fixtureMin.map{$0+2}}
                    study=environment.basicMachiningCenter.latest(documentURL:document.url,conversationID:conversationID,root:root,preview:true)
                }
                .task(id:study?.id) {guard let id=study?.id else{return};while !Task.isCancelled {do{let s=try await environment.basicMachiningCenter.refreshFromUI(id);study=s;guard environment.basicMachiningCenter.isRunning(id)||[.preparingEnvironment,.simulating,.cancelling].contains(s.state) else{return};try await Task.sleep(for:.seconds(1))}catch{if !Task.isCancelled{message=error.localizedDescription};return}}}
                .sheet(isPresented:Binding(get:{showingPath != nil},set:{if !$0{showingPath=nil}})) {
                    if let path=showingPath,root.standardizedFileURL==workspace.currentRootURL?.standardizedFileURL {NavigationStack{FilePreviewView(relativePath:path,center:workspace,conversationID:conversationID,allowsIDEExpansion:false,allowsDesignPage:false).toolbar{ToolbarItem(placement:.cancellationAction){Button(t("完成","Done")){showingPath=nil}}}}}
                }
        }
    }
    private func number(_ title:String,_ binding:Binding<Double>)->some View {HStack{Text(title);Spacer();TextField(title,value:binding,format:.number).multilineTextAlignment(.trailing).frame(maxWidth:140)}}
    private func vector(_ title:String,_ binding:Binding<[Double]>)->some View {VStack(alignment:.leading){Text(title);HStack{ForEach(0..<3,id:\.self){i in TextField(["X / I","Y / J","Z / K"][i],value:Binding(get:{binding.wrappedValue[i]},set:{binding.wrappedValue[i]=$0}),format:.number).multilineTextAlignment(.trailing)}}}}
    private func stateText(_ state:CADBasicMachiningStudy.State)->String {
        switch state {
        case .prepared:return t("等待环境准备","Waiting for preparation")
        case .preparingEnvironment:return t("正在准备环境","Preparing environment")
        case .environmentReady:return t("环境已准备","Environment prepared")
        case .simulating:return t("正在计算毛坯","Computing stock")
        case .ready:return t("毛坯已生成","Stock generated")
        case .cancelling:return t("正在取消","Cancelling")
        case .cancelled:return t("已取消","Cancelled")
        case .failed:return t("未完成，可查看任务后重试","Not completed; inspect the job before retrying")
        case .interrupted:return t("任务已中断，请重新开始","Interrupted; start a new preview")
        case .stale:return t("零件已变化，请重新预览","The part changed; run a new preview")
        }
    }
    private func fixtureText(_ state:String)->String {switch state{case "intersecting":return t("已相交","Intersecting");case "clear":return t("避让通过","Clearance certified");default:return t("需细化，未证明避让","Refine; clearance unproved")}}
    private func startPreview(){guard let part,let id=UUID(uuidString:part.id),let selection,selection.documentRevision==Int64(document.revision) else{message=t("选中状态已变化，请重新选择零件","Selection changed; select the part again");return}
        let preview=CadMultiAxisPreviewParameters(poses:[.init(tipMM:start,axisTowardSpindle:axis0),.init(tipMM:end,axisTowardSpindle:axis1)],holder:checkFixture ? .init(radiusMM:holderRadius,lengthMM:holderLength,offsetFromTipMM:holderOffset):nil,fixtures:checkFixture ? [.init(id:"fixture-1",minMM:fixtureMin,maxMM:fixtureMax,resolutionMM:0.25)]:[])
        let parameters=CadBasicMachiningParameters(resolutionMM:resolution,radiusMM:radius,lengthMM:length,startTipMM:start,endTipMM:end,preview:preview)
        starting=true;message=nil;Task{defer{starting=false};do{let id=try await environment.basicMachiningCenter.startFromUI(documentURL:document.url,bodyID:id,parameters:parameters,workspaceRoot:root,workspaceID:workspaceID,conversationID:conversationID);study=try environment.basicMachiningCenter.study(id)}catch{message=error.localizedDescription}}
    }
}
