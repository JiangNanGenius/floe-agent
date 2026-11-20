// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeManufacturingCore
import FloeManufacturingNC
import FloeNCProgram

struct CAMNCPostView:View {
    let study:ManufacturingStudy
    let artifact:ManufacturingArtifact
    let directory:URL
    let export: @MainActor (ManufacturingNCOptions) async throws -> URL
    let onGenerated:(URL)->Void
    @State private var options=ManufacturingNCOptions()
    @State private var busy=false
    @State private var error=""
    @State private var revision=UUID()
    @State private var worker:Task<Void,Never>?
    @Environment(\.dismiss) private var dismiss
    private var turning:Bool { artifact.result.paths.allSatisfy { $0.kind.hasPrefix("turning-") } }
    private var toolIDs:[String] { Array(Set(artifact.result.paths.compactMap { $0.toolID ?? (turning ? study.turningToolID ?? "turning-default" : nil) })).sorted() }
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(L("工件","Workpiece"),value:study.name)
                    LabeledContent(L("来源刀路","Source paths"),value:"\(artifact.result.paths.count)")
                } footer: {
                    Text(L("预览包含连接和退刀路径。上机前请核对控制器、刀补和行程。","The preview includes links and retracts. Check the controller, tool offsets and machine travel before machining."))
                }
                Section {
                    number(L("缺省主轴转速（rpm）","Fallback spindle speed (rpm)"),value:$options.fallbackSpindleRPM)
                    number(L("连接进给（mm/min）","Link feed (mm/min)"),value:$options.connectionFeedMMPerMinute)
                    number(L("附加净空（mm）","Extra clearance (mm)"),value:$options.extraClearanceMM)
                    if turning { Toggle(L("X 使用直径编程（G7）","Program X as diameter (G7)"),isOn:$options.turningDiameterProgramming) }
                    Toggle(L("切削液","Flood coolant"),isOn:$options.floodCoolant)
                } header: {
                    Text(L("导出设置","Post settings"))
                } footer: {
                    Text(L("只有工序未指定转速时才使用缺省值。请按材料和刀具调整。","The fallback speed applies to operations without a spindle speed. Adjust it for the material and tool."))
                }
                Section(L("刀号映射","Tool numbers")) {
                    ForEach(Array(toolIDs.enumerated()),id:\.element) { index,id in
                        HStack {
                            Text(study.cam?.tools.first(where:{ $0.id == id })?.name ?? L("车刀","Turning tool"))
                            Spacer()
                            TextField("T",value:Binding(get:{ options.toolNumbers[id] ?? index+1 },set:{ options.toolNumbers[id]=$0 }),format:.number)
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width:80)
                        }
                    }
                }
                if !error.isEmpty { Section { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("nc.post.error") } }
            }.disabled(busy)
            .navigationTitle(L("生成 G-code","Generate G-code")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(L("取消","Cancel")) { cancel();dismiss() } }
                ToolbarItem(placement:.confirmationAction) {
                    if busy { ProgressView().accessibilityLabel(L("正在生成 G-code","Generating G-code")) }
                    else { Button(L("生成并预览","Generate and preview")) { generate() }.accessibilityIdentifier("nc.post.generate") }
                }
            }
        }
        .task {
            let url=directory.appendingPathComponent("post-options.json")
            if let size=try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size <= 32768,
               let data=try? Data(contentsOf:url),data.count <= 32768,let value=try? JSONDecoder().decode(ManufacturingNCOptions.self,from:data) { options=value }
        }
        .onDisappear { cancel() }
    }
    private func number(_ name:String,value:Binding<Double>)->some View {
        HStack { Text(name);Spacer();TextField(name,value:value,format:.number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width:100) }
    }
    private func cancel() { worker?.cancel();worker=nil;revision=UUID();busy=false }
    private func generate() {
        cancel();busy=true;error=""
        let revision=self.revision
        var draft=options
        // Freeze the displayed map, including default entries, into the receipt.
        for (index,id) in toolIDs.enumerated() where draft.toolNumbers[id] == nil { draft.toolNumbers[id]=index+1 }
        let selected=draft
        worker=Task {
            do {
                let url = try await export(selected)
                guard self.revision == revision, !Task.isCancelled else { return }
                busy=false;worker=nil;onGenerated(url)
            } catch {
                guard self.revision == revision,!Task.isCancelled else { return }
                busy=false;worker=nil
                if !(error is CancellationError) { self.error=error.localizedDescription }
            }
        }
    }
}
#endif
