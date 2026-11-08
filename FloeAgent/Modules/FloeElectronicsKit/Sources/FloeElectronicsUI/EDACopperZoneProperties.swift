// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeElectronicsCore

struct EDCopperZonesSection: View {
    let session: EDWorkbenchSession
    let boardID: UUID
    @State private var netID = ""
    @State private var layer = "F.Cu"
    private var board: EDABoard? { session.project.boards.first { $0.id == boardID } }
    private var nets: [EDANet] { (try? session.netlist().nets) ?? [] }
    var body: some View {
        Section(edText("铜区", "Copper zones")) {
            if let board {
                ForEach(board.zones) { zone in
                    Button {
                        session.selection = .init(context:.board(boardID:boardID),objectIDs:[zone.id])
                    } label: {
                        VStack(alignment:.leading) {
                            Text((nets.first { $0.id == zone.netID }?.name ?? edText("未连接", "Unconnected")) + " · " + zone.layer)
                            Text(edaCopperFillStatus(zone,revision:session.revision)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Picker(edText("网络", "Net"),selection:$netID) {
                    Text(edText("未连接", "Unconnected")).tag("")
                    ForEach(nets,id:\.id) { Text($0.name).tag($0.id) }
                }
                Picker(edText("铜层", "Copper layer"),selection:$layer) {
                    ForEach(board.layers.filter { $0.kind == .copper },id:\.id) { Text($0.id).tag($0.id) }
                }
                Button(edText("添加铜区", "Add copper zone")) {
                    let revision = session.revision
                    Task { do {
                        try await session.createCopperZone(boardID:boardID,netID:netID,layer:layer,outline:board.outline,expectedRevision:revision)
                    } catch { session.report(error) } }
                }.disabled(session.busy || session.isFilling)
                Button(edText("重填铜区", "Refill copper zones")) {
                    let revision = session.revision
                    Task { do { try await session.refillCopper(boardID:boardID,expectedRevision:revision) } catch { session.report(error,operation:"refillCopper") } }
                }.disabled(session.busy || session.isFilling || board.zones.isEmpty)
            }
        }.onAppear { if let board, !board.layers.contains(where: { $0.id == layer && $0.kind == .copper }) { layer = board.layers.first { $0.kind == .copper }?.id ?? "" } }
    }
}

struct EDCopperZoneProperties: View {
    let session: EDWorkbenchSession
    let boardID: UUID
    @State var value: EDAZone
    @State private var revision: UInt64?
    @State private var loadedDesign: EDAZone?
    private var current: EDAZone? { session.project.boards.first { $0.id == boardID }?.zones.first { $0.id == value.id } }
    private var nets: [EDANet] { (try? session.netlist().nets) ?? [] }
    private func design(_ source: EDAZone) -> EDAZone {
        var copy = source; copy.filledPolygons = []; copy.fillRevision = nil; copy.fillState = nil; return copy
    }
    private var pending: Bool { loadedDesign.map { design(value) != $0 } ?? false }
    var body: some View { Form {
        Section(edText("铜区", "Copper zone")) {
            Picker(edText("网络", "Net"),selection:$value.netID) {
                Text(edText("未连接", "Unconnected")).tag("")
                if !value.netID.isEmpty && !nets.contains(where:{$0.id==value.netID}) {
                    Text(edText("未解析网络", "Unresolved net")).tag(value.netID)
                }
                ForEach(nets,id:\.id) { Text($0.name).tag($0.id) }
            }
            TextField(edText("铜层", "Copper layer"),text:$value.layer)
            TextField(edText("优先级", "Priority"),value:$value.priority,format:.number)
            TextField(edText("净距 (mm)", "Clearance (mm)"),value:$value.clearance,format:.number)
            Toggle(edText("热焊连接", "Thermal relief"),isOn:$value.thermal)
            if let current { Text(edaCopperFillStatus(current,revision:session.revision)).font(.caption).foregroundStyle(.secondary) }
        }
        if value.thermal {
            Section(edText("热焊设置", "Thermal relief settings")) {
                if value.thermalRelief != nil {
                    TextField(edText("间隙 (mm)", "Gap (mm)"),value:relief(\.gap),format:.number)
                    TextField(edText("辐条宽度 (mm)", "Spoke width (mm)"),value:relief(\.spokeWidth),format:.number)
                    TextField(edText("方向 (°，板坐标)", "Direction (°, board axes)"),value:relief(\.spokeAngleDegrees),format:.number)
                    TextField(edText("辐条数", "Spoke count"),value:Binding(get:{value.thermalRelief!.spokeCount},set:{value.thermalRelief?.spokeCount=$0}),format:.number)
                    Text(edText("当前支持四条辐条。应用设置后重填。", "Four spokes are supported. Apply settings before refilling.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(edText("请先设置热焊尺寸。", "Set the thermal relief dimensions first."))
                    Button(edText("使用默认热焊设置", "Use default thermal relief")) { value.thermalRelief = .creationDefault }
                }
            }
        }
        Section(edText("边界顶点 (mm)", "Outline vertices (mm)")) {
            ForEach(value.outline.indices,id:\.self) { i in
                HStack {
                    TextField("X",value:$value.outline[i].x,format:.number)
                    TextField("Y",value:$value.outline[i].y,format:.number)
                    Button(role:.destructive) { value.outline.remove(at:i) } label:{Image(systemName:"minus.circle")}.disabled(value.outline.count<=3)
                }
            }
            Button(edText("添加顶点", "Add vertex")) { value.outline.append((value.outline.last ?? .zero) + .init(1,1)) }
        }
        Section {
            Button(edText("应用修改", "Apply changes")) { commit() }.disabled(session.busy || !pending)
            Button(edText("重填铜区", "Refill copper zones")) {
                let expected = revision
                Task { do { try await session.refillCopper(boardID:boardID,expectedRevision:expected) } catch { session.report(error,operation:"refillCopper") } }
            }.disabled(pending || revision != session.revision || session.busy || session.isFilling)
            if revision != session.revision && pending {
                Text(edText("原件已改变，待应用的设置仍保留。", "The original changed. Your pending settings are retained.")).font(.caption)
                Button(edText("重新载入设置", "Reload settings")) { reload() }
            }
            Button(edText("删除铜区", "Delete copper zone"),role:.destructive) {
                Task { do { try await session.apply([.removeBoardObject(board:boardID,object:value.id)],expectedRevision:revision) } catch { session.report(error) } }
            }
        }
        if !session.copperFillIssues.isEmpty {
            Section {
                DisclosureGroup(edText("重填详情", "Refill details")) {
                    ForEach(session.copperFillIssues.indices,id:\.self) { i in
                        let issue = session.copperFillIssues[i]
                        Text(issue.code).font(.caption)
                        Text(issue.path).font(.caption2).foregroundStyle(.secondary)
                        ForEach(issue.details.keys.sorted(),id:\.self) { key in Text(key + ": " + issue.details[key]!).font(.caption2) }
                    }
                }
            }
        }
    }.onAppear { reload() }
      .onChange(of:session.revision) { _,_ in if !pending { reload() } }
    }
    private func relief(_ path: WritableKeyPath<EDAThermalRelief,Double>) -> Binding<Double> {
        Binding(get:{value.thermalRelief![keyPath:path]},set:{value.thermalRelief?[keyPath:path]=$0})
    }
    private func reload() { if let current { value=current;loadedDesign=design(current);revision=session.revision } }
    private func commit() {
        let edit=value, expected=revision
        Task { do { try await session.apply([.putZone(board:boardID,edit)],expectedRevision:expected);reload() } catch { session.report(error) } }
    }
}

func edaCopperFillStatus(_ zone: EDAZone, revision: UInt64) -> String {
    guard zone.fillRevision == revision else { return edText("需要重填", "Needs refill") }
    if zone.fillState == .empty { return edText("已计算：此区域无铜", "Computed: no copper in this zone") }
    if !zone.filledPolygons.isEmpty { return edText("已有填充", "Fill available") }
    return edText("需要重填", "Needs refill")
}
