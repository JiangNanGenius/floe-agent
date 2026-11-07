// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeBiologyCore
import FloeBiologyEngine

@MainActor struct BiologyToolConsole:View {
    let projectID:UUID
    let makeTools:(@MainActor @Sendable (UUID) async throws -> BiologyToolSession)?
    @Environment(\.dismiss) private var dismiss
    @State private var session:BiologyToolSession?
    @State private var descriptors:[BiologyToolDescriptor]=[]
    @State private var name="biology.describe"
    @State private var arguments="{}"
    @State private var output=""
    @State private var error:String?
    @State private var task:Task<Void,Never>?
    @State private var requestID=UUID().uuidString
    @State private var choosingTool=false
    @State private var phase=""
    @FocusState private var editingArguments:Bool
    var body:some View {
        NavigationStack {
            Form {
                if session != nil {
                    Button{choosingTool=true}label:{HStack{Text(biologyText("Tool","工具"));Spacer();Text(name).foregroundStyle(.secondary);Image(systemName:"chevron.right").foregroundStyle(.tertiary)}.frame(minHeight:44)}.buttonStyle(BiologyControlButtonStyle()).accessibilityIdentifier("biology.toolName")
                    if let descriptor=descriptors.first(where:{$0.name==name}) {
                        DisclosureGroup(biologyText("Contract","调用说明")) {Text(descriptor.description).font(.caption);Text(String(decoding:(try? BiologyCoding.encode(descriptor.parameters)) ?? Data(),as:UTF8.self)).font(.system(.caption,design:.monospaced)).textSelection(.enabled)}
                    }
                    Section {
                        TextEditor(text:$arguments).focused($editingArguments).font(.system(.callout,design:.monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never).frame(minHeight:140).biologyInputSurface().accessibilityIdentifier("biology.toolArguments")
                    }header:{HStack{Text(biologyText("Arguments · JSON","参数 · JSON"));Spacer();Button{editingArguments=false;arguments=""}label:{Text(biologyText("Clear","清空")).frame(minWidth:44,minHeight:44)}.buttonStyle(BiologyControlButtonStyle()).accessibilityIdentifier("biology.clearToolArguments")}}
                    HStack {
                        Button(biologyText("Run tool","执行工具")){run()}.buttonStyle(BiologyPrimaryButtonStyle()).disabled(task != nil).frame(minHeight:44).accessibilityIdentifier("biology.toolRun")
                        Spacer()
                        if task != nil {ProgressView();Button(biologyText("Stop waiting","停止等待")){task?.cancel()}.buttonStyle(BiologyControlButtonStyle())}
                    }.frame(minHeight:44)
                    if !phase.isEmpty {Text(phase).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("biology.toolPhase")}
                } else {Text(biologyText("Connect the host's task tools to operate this project.","接通宿主的任务工具后，可在这里操作项目。")).foregroundStyle(.secondary)}
                if let error {Section{Text(error).foregroundStyle(.secondary).textSelection(.enabled)}}
                if !output.isEmpty {Section(biologyText("Actual response","实际返回")){
                    ScrollView{Text(output).font(.system(.callout,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("biology.toolResponse")}
                        .frame(height:300).biologyInputSurface()
                }}
            }.navigationTitle(biologyText("Automation tools","自动化工具")).navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented:$choosingTool){List(descriptors,id:\.name){item in Button{name=item.name;choosingTool=false}label:{HStack{Text(item.name);Spacer();if item.name==name{Image(systemName:"checkmark")}}.frame(minHeight:44)}.accessibilityIdentifier("biology.toolChoice."+item.name)}.navigationTitle(biologyText("Choose tool","选择工具"))}
            .toolbar{ToolbarItem(placement:.confirmationAction){Button(biologyText("Done","完成")){dismiss()}}}
            .toolbar{ToolbarItemGroup(placement:.keyboard){Spacer();Button(biologyText("Finish editing","完成输入")){editingArguments=false}.accessibilityIdentifier("biology.finishToolEditing")}}
        }.task {
            guard let makeTools else {return}
            do{let tools=try await makeTools(projectID);session=tools;descriptors=await tools.descriptors()}catch{self.error=error.localizedDescription}
        }.onChange(of:name){_,_ in arguments=name=="biology.describe" || name=="biology.projects" || name=="biology.deleted" ? "{}":"{\"projectID\":\""+projectID.uuidString+"\"}";output=""}
        .onChange(of:arguments){_,_ in requestID=UUID().uuidString}
        .onDisappear{task?.cancel()}
    }
    private func run() {
        guard let session else{return};editingArguments=false;error=nil;phase=biologyText("Preparing request","准备请求")
        let name=name,arguments=arguments,request=requestID
        task=Task {
            defer{task=nil;phase=""}
            do {let value=try JSONDecoder().decode(JSONValue.self,from:Data(arguments.utf8));phase=biologyText("Running ","正在执行 ")+name;let result=try await session.invoke(name:name,arguments:value,requestID:request);phase=biologyText("Preparing response","整理返回结果");output=String(decoding:try BiologyCoding.encode(result),as:UTF8.self)}
            catch is CancellationError {error=biologyText("Waiting stopped. Inspect the saved calculation state before retrying.","等待已停止，请先查看保存的计算状态再重试。")}
            catch{self.error=error.localizedDescription}
        }
    }
}

@MainActor struct BiologyLargeImageView:View {
    let model:BiologyWorkbenchModel
    let asset:BiologyAsset
    let executionOwner:(@MainActor @Sendable (UUID,UUID) async throws -> BiologyExecutionOwner)?
    @State private var environment=""
    @State private var series=0
    @State private var level=0
    @State private var channel=0
    @State private var slice=0
    @State private var frame=0
    @State private var x=0
    @State private var y=0
    @State private var size=512
    @State private var image:MicroscopyImage?
    @State private var busy=false
    @State private var error:String?
    private var environments:[String] {model.methods.keys.filter{model.methods[$0]?.contains("micro.tile")==true}.sorted()}
    private var selection:JSONValue? {model.project?.selections?[asset.id.uuidString]}
    private var savedTile:BiologyRun? {model.project?.runs.last(where:{$0.assetID==asset.id && $0.assetRevision==asset.revision && $0.method=="micro.tile" && $0.status == .succeeded})}
    var body:some View {
        VStack {
            Form {
                if !environments.isEmpty {BiologyChoiceField(title:biologyText("Compute environment","计算环境"),selection:$environment,value:environment){ForEach(environments,id:\.self){Text($0).tag($0)}}}
                HStack {Stepper(biologyText("Series ","序列 ")+String(series+1),value:$series,in:0...1024);Stepper(biologyText("Level ","层级 ")+String(level),value:$level,in:0...64)}
                HStack {Stepper("C \(channel+1)",value:$channel,in:0...31);Stepper("Z \(slice+1)",value:$slice,in:0...511);Stepper("T \(frame+1)",value:$frame,in:0...511)}
                HStack {TextField("X",value:$x,format:.number).biologyNamedInput("X");TextField("Y",value:$y,format:.number).biologyNamedInput("Y");BiologyChoiceField(title:biologyText("Tile size","图块大小"),selection:$size,value:String(size)){ForEach([128,256,512,1024],id:\.self){Text(String($0)).tag($0)}}}
                Button(biologyText("Read region","读取区域")){Task{await read()}}.buttonStyle(BiologyPrimaryButtonStyle()).disabled(busy || environment.isEmpty || executionOwner==nil)
                if environment.isEmpty || executionOwner==nil {Text(biologyText("Connect a compute environment to read this image. The original is saved.","接通计算环境后即可读取图像，原件已保存。")).foregroundStyle(.secondary)}
                if let error {Text(error).font(.caption).textSelection(.enabled)}
            }.frame(maxHeight:300)
            if busy {ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity)}
            else if let image {BiologyMicroscopyView(image:image,result:nil,channel:.constant(0),slice:.constant(0),frame:.constant(0))}
            else {ContentUnavailableView(biologyText("Choose an image region","选择图像区域"),systemImage:"viewfinder")}
        }.task{environment=environments.first ?? "";applySelection();showSavedTile()}
        .onChange(of:selection){_,_ in applySelection()}
        .onChange(of:savedTile?.id){_,_ in showSavedTile()}
        .onChange(of:environments){_,names in if !names.contains(environment){environment=names.first ?? ""}}
    }
    private func applySelection(){guard let selected=selection else{return};series=Int(selected["series"]?.number ?? 0);level=Int(selected["level"]?.number ?? 0);channel=Int(selected["channel"]?.number ?? 0);slice=Int(selected["slice"]?.number ?? 0);frame=Int(selected["frame"]?.number ?? 0);if let region=selected["region"]?.array,region.count==4{x=Int(region[0].number ?? 0);y=Int(region[1].number ?? 0);size=min(1024,Int(region[2].number ?? 512))}}
    private func showSavedTile(){guard let text=savedTile?.result?.text else{return};do{let decoded=try JSONDecoder().decode(MicroscopyImage.self,from:Data(text.utf8));try decoded.validate();image=decoded}catch{self.error=error.localizedDescription}}
    private func read() async {
        guard let executionOwner else{return};busy=true;defer{busy=false};error=nil
        do {
            let owner=try await executionOwner(model.projectID,asset.id)
            let options:JSONValue = .object(["series":.number(Double(series)),"level":.number(Double(level)),"channel":.number(Double(channel)),"slice":.number(Double(slice)),"frame":.number(Double(frame)),"region":.array([x,y,size,size].map{.number(Double($0))})])
            let run=try await model.service.start(model.projectID,assetID:asset.id,expectedAssetRevision:asset.revision,method:"micro.tile",options:options,environmentID:environment,owner:owner)
            let completed=try await model.service.wait(model.projectID,runID:run.id)
            guard completed.status == .succeeded,let text=completed.result?.text else {throw BiologyError.unavailable(completed.error ?? "Image region was not read.")}
            let decoded=try JSONDecoder().decode(MicroscopyImage.self,from:Data(text.utf8));try decoded.validate();image=decoded
            await model.refresh()
        }catch{self.error=error.localizedDescription}
    }
}
#endif
