// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeCAD
import FloeWorkbench

/// App-host chrome only; FloeCAD selection, storage and viewport remain authoritative.
@MainActor
struct CADBasicMachiningEntry: ViewModifier {
    let document:FloeCADDocument
    let selection:CADSelectionContext?
    @ObservedObject var workspace:WorkspaceCenter
    let root:URL?
    let workspaceID:UUID?
    let conversationID:UUID?
    @EnvironmentObject private var environment:AppEnvironment
    @State private var canPrepare=false
    @State private var presented=false
    func body(content:Content)->some View {
        content.toolbar {
            if canPrepare {
                Button {presented=true} label:{Label(CADBasicMachiningText.title,systemImage:"cube.transparent")}
                    .accessibilityIdentifier("cad.basicMachining.open")
            }
        }
        .task(id:"\(conversationID?.uuidString ?? ""):\(document.url.path)") {
            canPrepare=await environment.basicMachiningCenter.uiAvailable(conversationID:conversationID,root:root)
        }
        .sheet(isPresented:$presented) {
            if let root,let workspaceID,let conversationID {
                CADBasicMachiningView(document:document,selection:selection,workspace:workspace,root:root,workspaceID:workspaceID,conversationID:conversationID)
            }
        }
    }
}

@MainActor
private struct CADBasicMachiningView:View {
    let document:FloeCADDocument
    let selection:CADSelectionContext?
    @ObservedObject var workspace:WorkspaceCenter
    let root:URL
    let workspaceID:UUID
    let conversationID:UUID
    @EnvironmentObject private var environment:AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var h=1.0
    @State private var radius=2.0
    @State private var length=6.0
    @State private var x0=0.0
    @State private var y0=0.0
    @State private var z=0.0
    @State private var x1=6.0
    @State private var y1=0.0
    @State private var study:CADBasicMachiningStudy?
    @State private var message:String?
    @State private var starting=false
    @State private var showingResult=false
    private func t(_ zh:String,_ en:String)->String {CADBasicMachiningText.t(zh,en)}
    private var part:CADSelectionContext.Body? {guard let selection,selection.bodies.count==1,selection.bodies[0].analyticBRep else{return nil};return selection.bodies[0]}
    private var running:Bool {starting || study.map{[.preparingEnvironment,.simulating,.cancelling].contains($0.state)} == true}
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    Text(part?.name ?? t("先在模型中选中一个实体零件","Select one solid part in the model first"))
                    Text(t("以零件包围盒为毛坯，沿固定 Z 的直线使用平底刀具。结果为体素近似网格。","Uses the part's bounding box as stock and one fixed-Z straight flat-end-mill cut. The result is an approximate voxel mesh."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(t("刀具与毛坯 · mm","Tool and stock · mm")) {
                    Picker(t("体素大小","Voxel size"),selection:$h) {ForEach([0.25,0.5,1.0,2.0],id:\.self){v in Text(v,format:.number).tag(v)}}
                    number(t("刀具半径","Tool radius"),$radius)
                    number(t("刀具长度","Tool length"),$length)
                }.disabled(running)
                Section(t("刀尖直线路径 · mm","Straight tool-tip path · mm")) {
                    number(t("起点 X","Start X"),$x0);number(t("起点 Y","Start Y"),$y0)
                    number(t("终点 X","End X"),$x1);number(t("终点 Y","End Y"),$y1)
                    number(t("固定 Z","Fixed Z"),$z)
                }.disabled(running)
                Section {
                    if let study {
                        Label(stateText(study.state),systemImage:study.state == .ready ? "checkmark.circle":"clock")
                        if running {ProgressView()}
                        if let error=study.error {Text(error).font(.footnote).textSelection(.enabled)}
                        if study.state == .ready,study.artifact != nil {
                            if let removed=study.removedMM3 {LabeledContent(t("去除体积 · mm³","Removed volume · mm³"),value:removed.formatted(.number.precision(.fractionLength(3))))}
                            if let remaining=study.remainingMM3 {LabeledContent(t("剩余体积 · mm³","Remaining volume · mm³"),value:remaining.formatted(.number.precision(.fractionLength(3))))}
                            Button(t("查看毛坯","View stock")){showingResult=true}.accessibilityIdentifier("cad.basicMachining.result")
                        }
                        if [.preparingEnvironment,.simulating,.cancelling].contains(study.state) {
                            Button(t("取消","Cancel"),role:.cancel){Task{do{self.study=try await environment.basicMachiningCenter.cancel(study.id)}catch{message=error.localizedDescription}}}
                                .disabled(study.state == .cancelling)
                        }
                    }
                    if let message {Text(message).font(.footnote).foregroundStyle(.secondary)}
                    Button(study == nil ? t("准备环境并开始","Prepare and start"):t("新建仿真","New simulation")) {start()}
                        .disabled(running || part==nil || document.isReadOnly)
                        .accessibilityIdentifier("cad.basicMachining.start")
                    Text(t("首次准备会在当前任务的 Mac 环境下载约 29 MB 依赖；可在任务中查看进度。","First use downloads about 29 MB into this task's Mac environment. Progress is available in Jobs."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(CADBasicMachiningText.title)
            .toolbar{ToolbarItem(placement:.cancellationAction){Button(t("完成","Done")){dismiss()}}}
            .task {
                if let p=part,p.bounds.count==2,p.bounds.allSatisfy({$0.count==3}) {
                    let lo=p.bounds[0],hi=p.bounds[1];let cx=(lo[0]+hi[0])/2,cy=(lo[1]+hi[1])/2
                    x0=cx-min(3,(hi[0]-lo[0])/4);x1=cx+min(3,(hi[0]-lo[0])/4);y0=cy;y1=cy;z=hi[2]-min(10,(hi[2]-lo[2])/2)
                }
                study=environment.basicMachiningCenter.latest(documentURL:document.url,conversationID:conversationID,root:root)
            }
            .task(id:study?.id) {
                guard let id=study?.id else{return}
                while !Task.isCancelled {
                    do {let refreshed=try await environment.basicMachiningCenter.refreshFromUI(id);study=refreshed
                        guard environment.basicMachiningCenter.isRunning(id) || [.preparingEnvironment,.simulating,.cancelling].contains(refreshed.state) else{return}
                        try await Task.sleep(for:.seconds(1))
                    }catch{if !Task.isCancelled{message=error.localizedDescription};return}
                }
            }
            .sheet(isPresented:$showingResult) {
                if let artifact=study?.artifact,root.standardizedFileURL==workspace.currentRootURL?.standardizedFileURL {
                    NavigationStack {FilePreviewView(relativePath:artifact.workspacePath,center:workspace,conversationID:conversationID,allowsIDEExpansion:false,allowsDesignPage:false)
                        .navigationTitle(t("毛坯","Stock"))
                        .toolbar{ToolbarItem(placement:.cancellationAction){Button(t("完成","Done")){showingResult=false}}}}
                }else{Text(t("重新打开所属工作区以查看产物","Reopen the owning workspace to view this result"))}
            }
        }
    }
    private func number(_ title:String,_ value:Binding<Double>)->some View {
        HStack {Text(title);Spacer();TextField(title,value:value,format:.number).multilineTextAlignment(.trailing).frame(maxWidth:140)}
    }
    private func start() {
        guard let part,let id=UUID(uuidString:part.id),let selection,selection.documentRevision==Int64(document.revision) else{message=t("模型选中状态已变化，请重新选择零件","The selection changed. Select the part again.");return}
        starting=true;message=nil
        let parameters=CadBasicMachiningParameters(resolutionMM:h,radiusMM:radius,lengthMM:length,startTipMM:[x0,y0,z],endTipMM:[x1,y1,z])
        Task {defer{starting=false};do {
            let operation=try await environment.basicMachiningCenter.startFromUI(documentURL:document.url,bodyID:id,parameters:parameters,workspaceRoot:root,workspaceID:workspaceID,conversationID:conversationID)
            study=try environment.basicMachiningCenter.study(operation)
        }catch{message=error.localizedDescription}}
    }
    private func stateText(_ state:CADBasicMachiningStudy.State)->String {
        switch state {
        case .prepared:return t("等待环境准备","Waiting for environment preparation")
        case .preparingEnvironment:return t("正在准备环境","Preparing environment")
        case .environmentReady:return t("环境已准备，等待计算","Environment prepared; awaiting computation")
        case .simulating:return t("正在计算毛坯","Computing stock")
        case .ready:return t("毛坯已生成","Stock generated")
        case .cancelling:return t("正在取消","Cancelling")
        case .cancelled:return t("已取消","Cancelled")
        case .failed:return t("未完成，可查看任务后重试","Not completed; inspect the job before retrying")
        case .interrupted:return t("任务已中断，请重新开始","Interrupted; start a new simulation")
        case .stale:return t("零件已变化，请重新仿真","The part changed; run a new simulation")
        }
    }
}
