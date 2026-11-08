// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeElectronicsCore

enum EDBusInspectorSelection:Equatable,Sendable {
    case bus(EDABus),entry(busID:UUID,EDABusEntry)
    static func read(_ project:EDAProject,sheetID:UUID,objectIDs:Set<UUID>)->Self? {
        guard let sheet=project.sheets.first(where:{$0.id==sheetID}) else{return nil}
        for bus in sheet.buses {
            if objectIDs.contains(bus.id){return .bus(bus)}
            if let entry=bus.entries?.first(where:{objectIDs.contains($0.id)}){return .entry(busID:bus.id,entry)}
        }
        return nil
    }
}
enum EDBusInspectorEdits {
    static func bus(_ value:EDABus,sheetID:UUID,project:EDAProject)throws->[EDAEdit]{
        guard project.sheets.first(where:{$0.id==sheetID})?.buses.contains(where:{$0.id==value.id})==true else{throw EDAError.missing("selected bus")}
        guard value.name.utf8.count<=4096,value.members.count<=10_000,value.members.allSatisfy({$0.utf8.count<=4096}) else{throw EDAError.invalid("bus name/member limits")}
        return [.putBus(sheet:sheetID,value)]
    }
    static func entry(_ value:EDABusEntry,busID:UUID,sheetID:UUID,project:EDAProject)throws->[EDAEdit]{
        guard var bus=project.sheets.first(where:{$0.id==sheetID})?.buses.first(where:{$0.id==busID}),let index=bus.entries?.firstIndex(where:{$0.id==value.id}) else{throw EDAError.missing("selected bus entry")}
        bus.entries![index]=value
        return [.putBus(sheet:sheetID,bus)]
    }
}
enum EDBusMemberPage {
    static let size=50
    static func range(count:Int,page:Int)->Range<Int>{
        guard count>0 else{return 0..<0}
        let start=min(max(0,page),(count-1)/size)*size
        return start..<min(start+size,count)
    }
}
struct EDBusProperties:View {
    let session:EDWorkbenchSession
    let sheetID:UUID
    let value:EDABus
    @State private var page=0
    var body:some View {
        EDInspectorEditor(session:session,value:value,
            source:{$0.sheets.first(where:{$0.id==sheetID})?.buses.first(where:{$0.id==value.id})},
            edits:{try EDBusInspectorEdits.bus($0,sheetID:sheetID,project:$1)},
            duplicate:{value,project in try EDCanvasInteraction.edits(for:.duplicate,project:project,context:.schematic(sheetID:sheetID),objectIDs:[value.id])},
            delete:{value,project in try EDCanvasInteraction.edits(for:.delete,project:project,context:.schematic(sheetID:sheetID),objectIDs:[value.id])}) {draft in
                Text(edText("总线","Bus")).font(.headline)
                EDInspectorTextField(edText("名称","Name"),text:draft.name)
                DisclosureGroup(edText("成员名称","Member names")){
                    let count=draft.wrappedValue.members.count,range=EDBusMemberPage.range(count:count,page:page)
                    Text(edText("每项是一个完整网络名称。","Each entry is a complete net name.")).font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(range),id:\.self){i in
                        HStack(alignment:.bottom){
                            EDInspectorTextField("\(i+1)",text:draft.members[i])
                            Button(role:.destructive){draft.wrappedValue.members.remove(at:i)}label:{Image(systemName:"minus.circle").frame(width:44,height:44)}.accessibilityLabel(edText("移除此成员","Remove member"))
                        }
                    }
                    if count>EDBusMemberPage.size{
                        HStack{
                            Button{page=max(0,range.lowerBound/EDBusMemberPage.size-1)}label:{Image(systemName:"chevron.left").frame(width:44,height:44)}.disabled(range.lowerBound==0).accessibilityLabel(edText("上一页","Previous page"))
                            Text("\(range.lowerBound+1)–\(range.upperBound) / \(count)").font(.caption.monospacedDigit())
                            Button{page=range.lowerBound/EDBusMemberPage.size+1}label:{Image(systemName:"chevron.right").frame(width:44,height:44)}.disabled(range.upperBound>=count).accessibilityLabel(edText("下一页","Next page"))
                        }
                    }
                    Button(edText("添加成员","Add member")){draft.wrappedValue.members.append("");page=(draft.wrappedValue.members.count-1)/EDBusMemberPage.size}.disabled(count>=10_000)
                }
            }
    }
}
struct EDBusEntryProperties:View {
    let session:EDWorkbenchSession
    let sheetID:UUID
    let busID:UUID
    let value:EDABusEntry
    var body:some View {
        EDInspectorEditor(session:session,value:value,
            source:{$0.sheets.first(where:{$0.id==sheetID})?.buses.first(where:{$0.id==busID})?.entries?.first(where:{$0.id==value.id})},
            edits:{try EDBusInspectorEdits.entry($0,busID:busID,sheetID:sheetID,project:$1)},
            duplicate:{value,project in try EDCanvasInteraction.edits(for:.duplicate,project:project,context:.schematic(sheetID:sheetID),objectIDs:[value.id])},
            delete:{value,project in try EDCanvasInteraction.edits(for:.delete,project:project,context:.schematic(sheetID:sheetID),objectIDs:[value.id])}){draft in
                Text(edText("总线引出线","Bus entry")).font(.headline)
                EDInspectorPointFields(draft.busPosition,prefix:edText("总线端 ","Bus end "))
                EDInspectorPointFields(draft.wirePosition,prefix:edText("连线端 ","Wire end "))
                Text(edText("这里只调整引出线图形。网络由连线和标签决定。","This adjusts the entry drawing. Wires and labels determine the net.")).font(.caption).foregroundStyle(.secondary)
            }
    }
}
