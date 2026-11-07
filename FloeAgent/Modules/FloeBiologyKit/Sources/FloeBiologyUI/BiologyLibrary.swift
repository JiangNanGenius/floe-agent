// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeBiologyCore
import FloeBiologyEngine

@MainActor public struct BiologyLibraryView:View {
    public let service:BiologyService
    public var onAI:BiologyAIHandler?
    public var onInsertInNotes:BiologyNotesHandler?
    @State private var projects:[BiologyProject]=[]
    @State private var title=""
    @State private var route:UUID?
    @State private var error:String?
    @State private var busy=false
    public init(service:BiologyService,onAI:BiologyAIHandler? = nil,onInsertInNotes:BiologyNotesHandler? = nil) {
        self.service=service;self.onAI=onAI;self.onInsertInNotes=onInsertInNotes
    }
    public var body:some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField(biologyText("Project name","项目名称"),text:$title).accessibilityIdentifier("biology.projectName")
                        Button(biologyText("Create","新建"),systemImage:"plus") {Task{await create(examples:false)}}
                            .disabled(busy).frame(minWidth:60,minHeight:44).accessibilityIdentifier("biology.create")
                    }
                    Button(biologyText("Open a complete example project","打开完整示例项目"),systemImage:"play.rectangle") {Task{await create(examples:true)}}
                        .frame(minHeight:44).disabled(busy).accessibilityIdentifier("biology.examples")
                    Text(biologyText("Import your own data, or explore sequence, structure, image, matrix and network examples.","导入自己的数据，或体验序列、结构、图像、矩阵和网络示例。")).foregroundStyle(.secondary)
                }
                Section(biologyText("Projects","项目")) {
                    ForEach(projects) { p in
                        Button {route=p.id} label:{
                            HStack {
                                Image(systemName:"folder")
                                VStack(alignment:.leading,spacing:4) {
                                    Text(p.title)
                                    Text("\(p.assets.count) "+biologyText("datasets","份数据")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer();Image(systemName:"chevron.right").foregroundStyle(.tertiary)
                            }.frame(minHeight:44)
                        }.accessibilityIdentifier("biology.project."+p.id.uuidString)
                        .swipeActions {
                            Button(biologyText("Delete","删除"),role:.destructive) {Task{do{try await service.delete(p.id);try await reload()}catch{self.error=error.localizedDescription}}}
                        }
                    }
                }
                if let error {Section{Text(error).foregroundStyle(.red)}}
            }
            .navigationTitle(biologyText("Biology workbench","生物工作台"))
            .navigationDestination(item:$route) { id in BiologyWorkbench(service:service,projectID:id,onAI:onAI,onInsertInNotes:onInsertInNotes) }
            .task {do{try await reload()}catch{self.error=error.localizedDescription}}
        }
    }
    private func reload() async throws {projects=try await service.projects()}
    private func create(examples:Bool) async {
        busy=true;defer{busy=false}
        do {
            let name=title.trimmingCharacters(in:.whitespacesAndNewlines)
            let p=try await service.create(title:name.isEmpty ? biologyText("Biology research","生物研究"):name)
            if examples {
                let model=BiologyWorkbenchModel(service:service,projectID:p.id)
                for sample in [FloeBiologySamples.BiologySampleID.sequenceComparison,.ubiquitinPDB,.microscopy,.expressionCounts,.reactionNetwork] {
                    await model.addSample(sample)
                    if let error=model.error {throw BiologyError.invalid(error)}
                }
            }
            try await reload();route=p.id;title=""
        } catch {self.error=error.localizedDescription}
    }
}
import FloeBiologySamples
#endif
