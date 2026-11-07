// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeBiologyCore
import FloeBiologyEngine

@MainActor public struct BiologyLibraryView:View {
    public let service:BiologyService
    public var onAI:BiologyAIHandler?
    public var onInsertInNotes:BiologyNotesHandler?
    public var executionOwner:(@MainActor @Sendable (UUID,UUID) async throws -> BiologyExecutionOwner)?
    public var makeTools:(@MainActor @Sendable (UUID) async throws -> BiologyToolSession)?
    @State private var projects:[BiologyProject]=[]
    @State private var title=""
    @State private var route:UUID?
    @State private var error:String?
    @State private var busy=false
    @State private var deleted:[BiologyDeletedProject]=[]
    @FocusState private var editingTitle:Bool
    public init(service:BiologyService,onAI:BiologyAIHandler? = nil,onInsertInNotes:BiologyNotesHandler? = nil,executionOwner:(@MainActor @Sendable (UUID,UUID) async throws -> BiologyExecutionOwner)? = nil,makeTools:(@MainActor @Sendable (UUID) async throws -> BiologyToolSession)? = nil) {
        self.service=service;self.onAI=onAI;self.onInsertInNotes=onInsertInNotes
        self.executionOwner=executionOwner;self.makeTools=makeTools
    }
    public var body:some View {
        NavigationStack {
            List {
                Section {
                    TextField(biologyText("Project name","项目名称"),text:$title).focused($editingTitle).accessibilityIdentifier("biology.projectName").biologyNamedInput(biologyText("Project name","项目名称"))
                    HStack(spacing:12) {
                        Button{Task{await create(examples:false)}}label:{Label(biologyText("Create project","新建项目"),systemImage:"plus").frame(maxWidth:.infinity,minHeight:44)}
                            .buttonStyle(BiologyPrimaryButtonStyle()).disabled(busy).accessibilityIdentifier("biology.create")
                        Button{Task{await create(examples:true)}}label:{Label(biologyText("Example project","示例项目"),systemImage:"play.rectangle").frame(maxWidth:.infinity)}
                            .buttonStyle(BiologyControlButtonStyle(expands:true)).disabled(busy).accessibilityIdentifier("biology.examples")
                    }
                } header:{Text(biologyText("New research project","新建研究项目"))}
                footer:{Text(biologyText("Keep sequences, structures, images, matrices and models together in one project.","在同一个项目中整理序列、结构、图像、矩阵和模型。"))}
                Section(biologyText("Projects","项目")) {
                    if projects.isEmpty {Text(biologyText("Create a project or open the example to get started.","新建项目或打开示例即可开始。")).foregroundStyle(.secondary).padding(.vertical,8)}
                    ForEach(projects) { p in
                        Button {route=p.id} label:{
                            HStack {
                                Image(systemName:"folder").foregroundStyle(.tint).frame(width:28)
                                VStack(alignment:.leading,spacing:4) {
                                    Text(p.title).foregroundStyle(.primary).font(.headline)
                                    Text("\(p.assets.count) "+biologyText("datasets","份数据")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer();Image(systemName:"chevron.right").foregroundStyle(.tertiary)
                            }.frame(minHeight:44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("biology.project."+p.id.uuidString)
                        .swipeActions {
                            Button(biologyText("Delete","删除"),role:.destructive) {Task{do{try await service.delete(p.id);try await reload()}catch{self.error=error.localizedDescription}}}
                        }
                    }
                }
                if !deleted.isEmpty {
                    Section(biologyText("Recently Deleted","最近删除")) {
                        ForEach(deleted) {p in
                            HStack {Text(p.title);Spacer();Button(biologyText("Restore","恢复")){Task{do{_=try await service.restoreDeleted(p.id,projectID:p.projectID);try await reload()}catch{self.error=error.localizedDescription}}}.buttonStyle(BiologyControlButtonStyle()).frame(minHeight:44).accessibilityIdentifier("biology.restoreDeleted."+p.projectID.uuidString)}
                        }
                    }
                }
                if let error {Section{Text(error).foregroundStyle(.red)}}
            }
            .listStyle(.insetGrouped).listSectionSpacing(24)
            .navigationTitle(biologyText("Biology workbench","生物工作台"))
            .navigationDestination(item:$route) { id in BiologyWorkbench(service:service,projectID:id,onAI:onAI,onInsertInNotes:onInsertInNotes,executionOwner:executionOwner,makeTools:makeTools) }
            .task {do{try await reload()}catch{self.error=error.localizedDescription}}
            .onChange(of:route){_,next in if next==nil{Task{do{try await reload()}catch{self.error=error.localizedDescription}}}}
        }
    }
    private func reload() async throws {projects=try await service.projects();deleted=try await service.deletedProjects()}
    private func create(examples:Bool) async {
        editingTitle=false
        busy=true;defer{busy=false}
        do {
            let name=title.trimmingCharacters(in:.whitespacesAndNewlines)
            let p=try await service.create(title:name.isEmpty ? biologyText("Biology research","生物研究"):name)
            if examples {
                let model=BiologyWorkbenchModel(service:service,projectID:p.id)
                for sample in [FloeBiologySamples.BiologySampleID.sequenceComparison,.ubiquitinPDB,.microscopy,.expressionCounts,.reactionNetwork,.phylogeneticTree,.densityVolume] {
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
