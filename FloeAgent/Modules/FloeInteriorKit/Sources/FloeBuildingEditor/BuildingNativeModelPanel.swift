// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import SwiftUI
import FloeCAD
import FloeBuildingRecords

struct BuildingNativeRoomOption:Identifiable,Equatable {
    let id:UUID
    let name:String
    let storeyID:UUID
    let storeyName:String
}

struct BuildingNativeModelPanel:View {
    private enum Mode:String,CaseIterable {case walls,native}
    @Bindable var project:BuildingEditorProjectSession
    @Environment(\.locale) private var locale
    @State private var choosingRooms=false
    @State private var mode=Mode.walls
    private func copy(_ zh:String,_ en:String)->String {locale.language.languageCode?.identifier=="zh" ? zh:en}
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:10) {
                Picker(copy("模型工作台","Model workspace"),selection:$mode) {
                    Text(copy("墙体平面","Wall plan")).tag(Mode.walls)
                    Text(copy("原生建筑","Native building")).tag(Mode.native)
                }.pickerStyle(.segmented).frame(maxWidth:360)
                .accessibilityIdentifier("building.model.mode")
                Spacer()
                Button {choosingRooms=true} label:{Label(copy("关联房间资料","Link room records"),systemImage:"link")}
                    .accessibilityIdentifier("building.rooms.link")
            }.padding(.horizontal,12).padding(.vertical,8)
            Divider()
            if mode == .walls {
                BuildingWallPlanEditor(project:project)
                    .disabled(project.busy)
            } else {
                FloeBuildingWorkbenchView(document:project.nativeDocument,hostOwnsProjectSave:true)
                    .disabled(project.busy)
            }
        }
        .sheet(isPresented:$choosingRooms){BuildingRoomLinkSheet(project:project)}
    }
}

private struct BuildingRoomLinkSheet:View {
    @Bindable var project:BuildingEditorProjectSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var recordsID:RoomID?
    @State private var nativeID:UUID?
    @State private var width = "4000"
    @State private var depth = "3000"
    @State private var height = "2700"
    @State private var wall = "200"
    @State private var operation:Task<Void,Never>?
    @State private var failure:String?
    private func copy(_ zh:String,_ en:String)->String {locale.language.languageCode?.identifier=="zh" ? zh:en}
    var body:some View {
        NavigationStack {
            Form {
                Section(copy("房间资料","Room records")) {
                    if project.roomOptions.isEmpty {
                        Text(copy("先在“工程与房间”中创建房间资料。","Create a room record in Project & rooms first."))
                    } else {
                        Picker(copy("资料中的房间","Recorded room"),selection:$recordsID) {
                            Text(copy("请选择","Choose a room")).tag(Optional<RoomID>.none)
                            ForEach(project.roomOptions){Text($0.name).tag(Optional($0.id))}
                        }
                    }
                }
                Section(copy("模型中的房间","Model room")) {
                    Picker(copy("选择房间","Choose a room"),selection:$nativeID) {
                        Text(copy("请选择","Choose a room")).tag(Optional<UUID>.none)
                        ForEach(project.nativeRoomOptions){Text($0.storeyName+" · "+$0.name).tag(Optional($0.id))}
                    }
                    Button(copy("建立关联","Link rooms")) {
                        guard let recordsID,let nativeID else{return}
                        run{try await project.linkRoom(recordsRoomID:recordsID,nativeRoomID:nativeID)}
                    }.disabled(recordsID==nil || nativeID==nil)
                }
                if (try? project.cad.building()) == nil {
                    Section(copy("创建初始矩形房间（毫米）","Create initial rectangular room (mm)")) {
                        TextField(copy("宽度","Width"),text:$width).keyboardType(.decimalPad)
                        TextField(copy("进深","Depth"),text:$depth).keyboardType(.decimalPad)
                        TextField(copy("层高","Height"),text:$height).keyboardType(.decimalPad)
                        TextField(copy("墙厚","Wall thickness"),text:$wall).keyboardType(.decimalPad)
                        Button(copy("从所选资料创建房间","Create room from selected record")) {
                            guard let recordsID,let w=Double(width),let d=Double(depth),let h=Double(height),let t=Double(wall) else {
                                failure=copy("请填写完整尺寸并选择房间。","Choose a room and complete all dimensions.");return
                            }
                            run{try await project.createInitialRoom(recordsRoomID:recordsID,widthMM:w,depthMM:d,heightMM:h,wallThicknessMM:t)}
                        }.disabled(recordsID==nil)
                    }
                }
                Section(copy("已有关联","Linked rooms")) {
                    ForEach(project.state.roomLinks,id:\.recordsRoomID) { link in
                        VStack(alignment:.leading,spacing:8) {
                            Text(project.roomOptions.first{$0.id==link.recordsRoomID}?.name ?? link.lastSyncedName)
                            if let native=project.nativeRoomOptions.first(where:{$0.id==link.nativeRoomID}) {
                                Text(native.storeyName+" · "+native.name).font(.caption).foregroundStyle(.secondary)
                                Button(copy("采用模型房间名称","Use model room name")){run{try await project.useNativeRoomName(link.recordsRoomID)}}
                                Button(copy("采用资料房间名称","Use recorded room name")){run{try await project.useRecordedRoomName(link.recordsRoomID)}}
                            } else {Text(copy("模型房间已不存在，请重新关联。","This model room is missing. Link it again."))}
                            Button(copy("解除关联","Unlink"),role:.destructive){run{try project.unlinkRoom(link.recordsRoomID)}}
                        }
                    }
                }
                if let failure {Section {Text(failure).font(.caption).textSelection(.enabled)}}
            }.disabled(project.busy || operation != nil)
            .navigationTitle(copy("房间关联","Room links")).navigationBarTitleDisplayMode(.inline)
            .toolbar {ToolbarItem(placement:.confirmationAction){Button(copy("完成","Done")){dismiss()}.disabled(operation != nil)}}
        }.task {do {try await project.refreshRoomOptions()} catch {failure=error.localizedDescription}}
        .interactiveDismissDisabled(operation != nil)
    }
    private func run(_ work:@escaping @MainActor () async throws -> Void) {
        guard operation==nil else{return};failure=nil
        operation=Task {@MainActor in
            defer{operation=nil}
            do{try await work()}catch{failure=error.localizedDescription}
        }
    }
}
#endif
