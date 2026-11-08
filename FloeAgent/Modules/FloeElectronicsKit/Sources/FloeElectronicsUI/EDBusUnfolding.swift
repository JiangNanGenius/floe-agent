// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeElectronicsCore

/// A wire gesture remains bound to the exact original that supplied the member.
/// Entry placement projects onto an actual bus segment, never a bounding box.
struct EDBusUnfoldDraft: Sendable {
    let source: EDAProject
    let sheetID: UUID
    let busID: UUID
    let member: String
    let busPosition: EDAPoint
    init(project: EDAProject, sheetID: UUID, busID: UUID, member: String, at point: EDAPoint) throws {
        guard point.isValid, let bus=project.sheets.first(where:{$0.id==sheetID})?.buses.first(where:{$0.id==busID}),
              !member.isEmpty,member.utf8.count<=4096,bus.members.filter({$0==member}).count==1 else {
            throw EDAError.invalid("choose one declared bus member")
        }
        var best: (EDAPoint, Double)?
        for (a,b) in zip(bus.points,bus.points.dropFirst()) {
            let delta=b-a,length=delta.x*delta.x+delta.y*delta.y
            guard length>0,length.isFinite else{continue}
            let ratio=max(0,min(1,((point.x-a.x)*delta.x+(point.y-a.y)*delta.y)/length))
            let projected=EDAPoint(a.x+ratio*delta.x,a.y+ratio*delta.y),distance=projected.distance(to:point)
            if best == nil || distance<best!.1{best=(projected,distance)}
        }
        guard let position=best?.0,position.isValid else{throw EDAError.invalid("bus has no nonzero segment")}
        source=project;self.sheetID=sheetID;self.busID=busID;self.member=member;busPosition=position
    }
    func plan(wirePoints:[EDAPoint],cancelled:@Sendable ()->Bool={false}) throws -> EDABusUnfold.Plan {
        try EDABusUnfold.newWire(project:source,sheetID:sheetID,busID:busID,member:member,busPosition:busPosition,wirePoints:wirePoints,cancelled:cancelled)
    }
}

struct EDBusMemberPicker:View {
    let bus:EDABus
    let choose:(String)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var search=""
    private var counts:[String:Int]{Dictionary(bus.members.map{($0,1)},uniquingKeysWith:+)}
    var body:some View {
        NavigationStack{
            Group{
            if bus.members.count>10_000{
                ContentUnavailableView(edText("成员数量过多","Too many members"),systemImage:"exclamationmark.triangle")
            }else{
                let names=counts
                List{
                    if bus.members.isEmpty{Text(edText("请先为总线声明成员名称。","Declare the bus member names first."))}
                    ForEach(Array(bus.members.enumerated()).filter{search.isEmpty || $0.element.localizedCaseInsensitiveContains(search)},id:\.offset){item in
                        Button{choose(item.element)}label:{Text(item.element.isEmpty ? edText("空名称","Empty name"):item.element)}
                            .disabled(item.element.isEmpty || item.element.utf8.count>4096 || names[item.element] != 1)
                    }
                }.searchable(text:$search,prompt:edText("选择成员","Choose a member"))
            }
            }.navigationTitle(edText("展开总线成员","Unfold bus member"))
                .toolbar{ToolbarItem(placement:.cancellationAction){Button(edText("取消","Cancel")){dismiss()}}}
        }
            .frame(minWidth:280,minHeight:300)
    }
}
