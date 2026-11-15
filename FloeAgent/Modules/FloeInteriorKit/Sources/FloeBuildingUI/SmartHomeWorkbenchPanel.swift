// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeBuildingSystems

struct SmartHomeWorkbenchPanel:BuildingLocalizedView {
    @Environment(\.locale) var buildingLocale
    let session:BuildingWorkspaceSession
    var body:some View {
        @Bindable var editor=session.editors.smartHome
        @Bindable var state=session
        let plan=session.currentSmartHomePlan()
        List {
            Section {
                Text(buildingText("规划点位、连接、场景与施工料单。图例不代表已选品牌；请按资料填写型号和端口参数。","Plan points, connections, scenes and construction bills. Legends do not select a brand; enter product and port data from evidence."))
                HStack{
                    Menu(buildingText("添加设备","Add equipment")){
                        ForEach(SystemLegendCatalog.presets){preset in
                            Button(buildingText(preset.nameZH,preset.nameEN)){
                                let device=SystemLegendCatalog.draft(from:preset,name:buildingText(preset.nameZH,preset.nameEN))
                                editor.value.equipment.append(device);session.selectedDeviceID=device.id
                            }
                        }
                    }.accessibilityIdentifier("building.smart.add")
                    Button(buildingText("检查连接","Check connections")){
                        guard session.numberInputs.commit(prefix:"smartHome") else{return}
                        session.editors.smartValidation=SmartHomePlanValidator.validate(session.currentSmartHomePlan())
                    }.accessibilityIdentifier("building.smart.check")
                    ShareLink(item:SmartHomeSchedules.bomCSV(plan)){Label(buildingText("料单","Bill"),systemImage:"square.and.arrow.up")}
                }
            }
            Section(buildingText("设备点位","Equipment points")){
                if editor.value.equipment.isEmpty{Text(buildingText("从图例添加设备，再填写型号与布置位置。","Add equipment from a legend, then set its product and position.")).foregroundStyle(.secondary)}
                ForEach($editor.value.equipment){$equipment in
                    VStack(alignment:.leading,spacing:8){
                        HStack{
                            Button{session.selectedDeviceID=equipment.id}label:{Image(systemName:session.selectedDeviceID==equipment.id ? "checkmark.circle.fill":"circle").frame(minWidth:44,minHeight:44)}.accessibilityLabel(buildingText("选择设备","Select equipment"))
                            TextField(buildingText("设备名称","Equipment name"),text:$equipment.name).font(.headline)
                        }
                        TextField(buildingText("品牌与准确型号","Brand and exact model"),text:$equipment.productReference)
                        TextField(buildingText("型号资料版本","Product data version"),text:$equipment.assetVersion)
                        Picker(buildingText("房间","Room"),selection:$equipment.roomID){
                            Text(buildingText("待分配","Unassigned")).tag(UUID?.none)
                            ForEach(session.snapshot?.rooms ?? []){room in Text(room.name).tag(Optional(room.id.rawValue))}
                        }
                        if equipment.positionMM != nil {
                            let position=Binding(get:{equipment.positionMM ?? .init(0,0,0)},set:{equipment.positionMM=$0})
                            BuildingNumberField(title:"X (mm)",value:position.x,inputs:session.numberInputs,id:"smartHome."+equipment.id.uuidString+".x")
                            BuildingNumberField(title:"Y (mm)",value:position.y,inputs:session.numberInputs,id:"smartHome."+equipment.id.uuidString+".y")
                            BuildingNumberField(title:"Z (mm)",value:position.z,inputs:session.numberInputs,id:"smartHome."+equipment.id.uuidString+".z")
                            Button(buildingText("清除位置","Clear position")){
                                _=session.numberInputs.discardPending(prefix:"smartHome."+equipment.id.uuidString);equipment.positionMM=nil
                            }
                        } else {Button(buildingText("设置设备位置","Set equipment position")){equipment.positionMM = .init(0,0,0)}}
                        DisclosureGroup(buildingText("端口与额定参数","Ports and ratings")){
                            Text(buildingText("留空表示未提供，不会按零值计算。","Empty means unspecified; it is not treated as zero.")).font(.caption).foregroundStyle(.secondary)
                            ForEach($equipment.ports){$port in
                                VStack(alignment:.leading,spacing:8){
                                    Text(port.label).font(.headline)
                                    TextField(buildingText("通信协议","Protocol"),text:optionalText($port.protocolName))
                                    TextField(buildingText("兼容配置","Compatibility profile"),text:optionalText($port.compatibilityProfile))
                                    BuildingOptionalNumberField(title:buildingText("额定电压 V","Nominal voltage V"),value:$port.nominalVoltageV,inputs:session.numberInputs,id:"smartHome."+equipment.id.uuidString+"."+port.id.uuidString+".voltage")
                                    BuildingOptionalNumberField(title:buildingText("允许最低电压 V","Minimum voltage V"),value:$port.minimumVoltageV,inputs:session.numberInputs,id:"smartHome."+equipment.id.uuidString+"."+port.id.uuidString+".minV")
                                    BuildingOptionalNumberField(title:buildingText("允许最高电压 V","Maximum voltage V"),value:$port.maximumVoltageV,inputs:session.numberInputs,id:"smartHome."+equipment.id.uuidString+"."+port.id.uuidString+".maxV")
                                    BuildingOptionalNumberField(title:buildingText("供电容量 A","Supply capacity A"),value:$port.maximumCurrentA,inputs:session.numberInputs,id:"smartHome."+equipment.id.uuidString+"."+port.id.uuidString+".capacity")
                                    BuildingOptionalNumberField(title:buildingText("负载电流 A","Load current A"),value:$port.demandCurrentA,inputs:session.numberInputs,id:"smartHome."+equipment.id.uuidString+"."+port.id.uuidString+".demand")
                                    TextField(buildingText("参数来源","Rating evidence"),text:optionalText($port.evidenceID))
                                }.padding(.vertical,6)
                            }
                        }
                    }.padding(.vertical,8)
                }
            }
            Section(buildingText("端口连接","Port connections")){
                Picker(buildingText("起点","From"),selection:$state.firstPortID){portOptions}
                Picker(buildingText("终点","To"),selection:$state.secondPortID){portOptions}
                Button(buildingText("添加连接","Add connection")){
                    guard let a=session.firstPortID,let b=session.secondPortID,a != b else{return}
                    editor.value.connections.append(.init(firstPortID:a,secondPortID:b))
                }.disabled(!canConnect)
                ForEach(editor.value.connections){connection in
                    Text(portLabel(connection.firstPortID)+" → "+portLabel(connection.secondPortID)).contextMenu{
                        Button(buildingText("移除连接","Remove connection"),role:.destructive){editor.value.connections.removeAll{$0.id==connection.id}}
                    }
                }
                ShareLink(item:SmartHomeSchedules.wiringCSV(plan)){Label(buildingText("分享接线表","Share wiring schedule"),systemImage:"square.and.arrow.up")}
            }
            Section(buildingText("场景计划","Scene plans")){
                TextField(buildingText("场景名称","Scene name"),text:$state.sceneNameDraft)
                TextField(buildingText("触发条件","Trigger"),text:$state.sceneTriggerDraft)
                TextField(buildingText("计划动作","Planned action"),text:$state.sceneActionDraft)
                DisclosureGroup(buildingText("关联设备","Related equipment")){
                    ForEach(editor.value.equipment){equipment in
                        Toggle(equipment.name,isOn:Binding(get:{session.sceneEquipmentIDs.contains(equipment.id)},set:{selected in
                            if selected{session.sceneEquipmentIDs.insert(equipment.id)}else{session.sceneEquipmentIDs.remove(equipment.id)}
                        }))
                    }
                }
                Button(buildingText("添加场景计划","Add scene plan")){
                    editor.value.scenes.append(.init(name:session.sceneNameDraft,triggerDescription:session.sceneTriggerDraft,
                        actionDescription:session.sceneActionDraft,equipmentIDs:Array(session.sceneEquipmentIDs).sorted{$0.uuidString<$1.uuidString}))
                    session.sceneNameDraft="";session.sceneTriggerDraft="";session.sceneActionDraft="";session.sceneEquipmentIDs=[]
                }.disabled(session.sceneNameDraft.isEmpty || session.sceneTriggerDraft.isEmpty || session.sceneActionDraft.isEmpty || session.sceneEquipmentIDs.isEmpty)
                ForEach(editor.value.scenes){scene in
                    VStack(alignment:.leading){Text(scene.name).font(.headline);Text(scene.triggerDescription+" → "+scene.actionDescription)}
                        .contextMenu{Button(buildingText("移除场景计划","Remove scene plan"),role:.destructive){editor.value.scenes.removeAll{$0.id==scene.id}}}
                }
                ShareLink(item:SmartHomeSchedules.scenesCSV(plan)){Label(buildingText("分享场景表","Share scene schedule"),systemImage:"square.and.arrow.up")}
            }
            if let validation=session.editors.smartValidation {
                Section(buildingText("检查结果","Check results")){
                    Text("\(validation.invalidCount) "+buildingText("项冲突","conflicts")+" · \(validation.needsInputCount) "+buildingText("项待补条件","missing inputs"))
                    ForEach(validation.issues){issue in
                        VStack(alignment:.leading){Text(buildingIssue(issue));DisclosureGroup(buildingText("详细信息","Details")){Text(issue.detail).font(.caption);Text(issue.code).font(.caption).foregroundStyle(.secondary)}}
                    }
                }
            }
            Section(buildingText("图例预设","Legend presets")){
                ForEach(SystemLegendCatalog.presets){preset in HStack{
                    SystemLegendGlyph(preset:preset).frame(width:64,height:55)
                    VStack(alignment:.leading){Text(buildingText(preset.nameZH,preset.nameEN));Text(preset.terminalLabels.joined(separator:" / ")).font(.caption).foregroundStyle(.secondary)}
                }}
            }
        }.buttonStyle(.borderless).disabled(session.busy)
        .onChange(of:editor.value){_,value in
            session.editors.smartValidation=nil
            if let selected=session.selectedDeviceID,!value.equipment.contains(where:{$0.id==selected}){session.selectedDeviceID=nil}
            let ports=Set(value.equipment.flatMap(\.ports).map(\.id))
            if let id=session.firstPortID,!ports.contains(id){session.firstPortID=nil}
            if let id=session.secondPortID,!ports.contains(id){session.secondPortID=nil}
            session.sceneEquipmentIDs.formIntersection(Set(value.equipment.map(\.id)))
        }
        .onChange(of:session.snapshot?.rooms){_,_ in session.editors.smartValidation=nil}
    }
    @ViewBuilder private var portOptions:some View {
        Text(buildingText("选择端口","Choose port")).tag(UUID?.none)
        ForEach(session.editors.smartHome.value.equipment){device in ForEach(device.ports){port in Text(device.name+" / "+port.label).tag(Optional(port.id))}}
    }
    private var canConnect:Bool {
        let ids=Set(session.editors.smartHome.value.equipment.flatMap(\.ports).map(\.id))
        guard let a=session.firstPortID,let b=session.secondPortID,a != b else{return false}
        return ids.contains(a) && ids.contains(b)
    }
    private func portLabel(_ id:UUID)->String {
        for device in session.editors.smartHome.value.equipment{if let port=device.ports.first(where:{$0.id==id}){return device.name+" / "+port.label}}
        return buildingText("端口已移除","Port removed")
    }
    private func optionalText(_ value:Binding<String?>)->Binding<String>{Binding(get:{value.wrappedValue ?? ""},set:{value.wrappedValue=$0.isEmpty ? nil:$0})}
}

private struct SystemLegendGlyph: View {
    let preset: SystemLegendPreset
    var body: some View {
        Canvas { context, size in
            for stroke in preset.strokes {
                var path = Path()
                for (index, point) in stroke.vertices.enumerated() {
                    let p = CGPoint(x: point.x / 52 * size.width, y: point.y / 52 * size.height)
                    if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                if stroke.closed { path.closeSubpath() }
                context.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
            }
        }
    }
}
