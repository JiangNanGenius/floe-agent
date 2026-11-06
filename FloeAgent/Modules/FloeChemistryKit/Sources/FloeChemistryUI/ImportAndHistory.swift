import SwiftUI
import UniformTypeIdentifiers
import FloeChemistryCore

public enum ChemistryExamples {
    public static let water = "3\nwater\nO 0 0 0\nH 1.2 0 0\nH -0.2 1.1 0\n"
    public static let crystal = "{\"chemicalJson\":1,\"atoms\":{\"elements\":{\"number\":[55,17]},\"coords\":{\"3d\":[0,0,0,2.06,2.06,2.06]}},\"unitCell\":{\"a\":4.12,\"b\":4.12,\"c\":4.12,\"alpha\":90,\"beta\":90,\"gamma\":90}}"
    public static let reaction = "{\"reactants\":[\"C2H6\",\"O2\"],\"products\":[\"CO2\",\"H2O\"]}"
    public static let spectrum = "x,y\n0,0\n1,0.3\n2,1\n3,0.2\n4,0.1\n5,0.8\n6,0\n"
}

@MainActor struct ChemistryImportSheet: View {
    let state: ChemistryEditorState
    @Environment(\.dismiss) private var dismiss
    @State private var title = chemistryText("Water", "水")
    @State private var kind: ChemicalKind = .molecule
    @State private var format = "xyz"
    @State private var source = ChemistryExamples.water
    @State private var importing = false
    @State private var deferPreparation = false
    private var supportsDeferredPreparation: Bool {
        [.molecule, .crystal, .biomolecule, .reaction].contains(kind) &&
        ["smi", "smiles", "mol", "sdf", "pdb", "xyz", "cjson", "cif", "mmcif", "reaction.json"].contains(format)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(chemistryText("Name", "名称"), text: $title)
                    Picker(chemistryText("Object type", "对象类型"), selection: $kind) {
                        ForEach(ChemicalKind.allCases, id: \.self) { Text($0.displayTitle).tag($0) }
                    }
                    Picker(chemistryText("Input format", "输入格式"), selection: $format) {
                        ForEach(["smi","xyz","sdf","mol","pdb","cif","mmcif","cjson","vasp","qcschema","molden","cube","orca","csv","reaction.json","text"], id: \.self) { Text($0.uppercased()).tag($0) }
                    }
                    Button(chemistryText("Choose file", "选择文件"), systemImage: "doc") { importing = true }
                    if supportsDeferredPreparation {
                        Toggle(chemistryText("Keep original, process later", "保留原始结构，稍后处理"), isOn: $deferPreparation)
                            .accessibilityIdentifier("chemistry.import.deferPreparation")
                        if deferPreparation {
                            Text(chemistryText("The original is saved. Properties and a structure preview appear after processing.", "原始内容会保存，处理完成后再显示属性和结构预览。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section(chemistryText("Examples", "示例")) {
                    Button(chemistryText("Water · XYZ", "水 · XYZ")) { title = chemistryText("Water", "水"); kind = .molecule; format = "xyz"; source = ChemistryExamples.water }
                    Button(chemistryText("Ethanol · SMILES", "乙醇 · SMILES")) { title = chemistryText("Ethanol", "乙醇"); kind = .molecule; format = "smi"; source = "CCO" }
                    Button(chemistryText("CsCl unit cell", "CsCl 晶胞")) { title = chemistryText("CsCl crystal", "CsCl 晶体"); kind = .crystal; format = "cjson"; source = ChemistryExamples.crystal }
                    Button(chemistryText("Combustion reaction", "燃烧反应")) { title = chemistryText("Ethane combustion", "乙烷燃烧"); kind = .reaction; format = "reaction.json"; source = ChemistryExamples.reaction }
                    Button(chemistryText("Example spectrum", "示例谱图")) { title = chemistryText("Example spectrum", "示例谱图"); kind = .spectrum; format = "csv"; source = ChemistryExamples.spectrum }
                }
                Section(chemistryText("Source", "原始内容")) { TextEditor(text: $source).font(.system(.body, design: .monospaced)).frame(minHeight: 230) }
                if let error = state.error { Section(chemistryText("Details", "详情")) { Text(error).font(.caption).foregroundStyle(.red) } }
            }
            .navigationTitle(chemistryText("Import or create", "导入或新建"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(chemistryText("Cancel", "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(chemistryText("Add", "添加")) {
                    Task {
                        await state.importSource(title: title, kind: kind, format: format, source: source,
                            deferPreparation: supportsDeferredPreparation && deferPreparation)
                        if state.error == nil { dismiss() }
                    }
                }.disabled(state.busy || title.isEmpty) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .text]) { result in
                switch result {
                case .failure(let error): state.error = error.localizedDescription
                case .success(let url):
                    Task {
                        do {
                            let bytes = try await Task.detached {
                                let scoped = url.startAccessingSecurityScopedResource()
                                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                                let data = try file.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
                                guard data.count <= 16 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw ChemistryError.invalid("File exceeds the import limit or is not UTF-8 text.") }
                                return text
                            }.value
                            source = bytes; title = url.deletingPathExtension().lastPathComponent
                            format = url.pathExtension.lowercased()
                            if format == "pdb" || format == "mmcif" { kind = .biomolecule }
                            if format == "cif" { kind = .crystal }
                            if format == "csv" { kind = .spectrum }
                        } catch { state.error = error.localizedDescription }
                    }
                }
            }
            .onChange(of: format) { _, value in
                if ["cif", "mmcif"].contains(value) { deferPreparation = true }
                else if !supportsDeferredPreparation { deferPreparation = false }
            }
        }.frame(minWidth: 320, minHeight: 500)
    }
}

@MainActor struct ChemistryHistorySheet: View {
    let state: ChemistryEditorState
    @Environment(\.dismiss) private var dismiss
    @State private var history: [ChemistryRevision] = []
    @State private var recoveries: [ChemistryDrawingRecovery] = []
    var body: some View {
        NavigationStack {
            List {
            if !recoveries.isEmpty {
                Section(chemistryText("Unsaved drawings", "未提交的绘图")) {
                    ForEach(recoveries) { draft in
                        Button(chemistryText("Recover a copy", "恢复为副本") + " · " + draft.object.title) {
                            Task { await state.perform { state.selectedID = try await state.service.recoverDrawing(state.projectID, recoveryID: draft.id).id }; if state.error == nil { dismiss() } }
                        }
                    }
                }
            }
            Section(chemistryText("Saved versions", "历史版本")) {
            ForEach(history, id: \.digest) { item in
                Button(chemistryText("Restore revision", "恢复版本") + " \(item.revision)") {
                    Task { await state.perform {
                        _ = try await state.service.restore(item, expectedRevision: state.project?.revision ?? 0)
                    }; if state.error == nil { dismiss() } }
                }.disabled(state.busy || state.project?.runs.contains(where: { [.queued, .running].contains($0.status) }) == true)
            }
            }
            }
            .navigationTitle(chemistryText("History", "历史版本"))
            .toolbar { Button(chemistryText("Done", "完成")) { dismiss() } }
            .task { do { history = try await state.service.history(state.projectID); recoveries = try await state.service.drawingRecoveries(state.projectID) } catch { state.error = error.localizedDescription } }
        }
    }
}
