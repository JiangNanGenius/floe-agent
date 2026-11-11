import SwiftUI
import UniformTypeIdentifiers
import FloeChemistryCore

struct ChemistryTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .data] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents, bytes.count <= 16 * 1024 * 1024,
              let text = String(data: bytes, encoding: .utf8) else { throw ChemistryError.invalid("Invalid text document.") }
        self.text = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

@MainActor struct ChemistryInspector: View {
    let state: ChemistryEditorState
    let selectedAtoms: [Int]
    var onPrepareStructure: (@MainActor (UUID) -> Void)? = nil
    @State private var preparationEnvironment: String?
    @State private var iterations = 200
    @State private var tolerance = 0.0001
    @State private var method = "uff.optimize"
    private var environments: [String: [String]] { state.availableEnvironments }
    @State private var a = 2
    @State private var b = 2
    @State private var c = 2
    @State private var atomicNumber = 6
    @State private var x = 0.0
    @State private var y = 0.0
    @State private var z = 0.0
    @State private var bondOrder = 1
    @State private var exportFormat = "xyz"
    @State private var exportDocument: ChemistryTextDocument?
    @State private var exporting = false
    @State private var scene = ChemistryScene()
    @State private var sceneGeneration:UInt64=0
    @State private var advancedOptions = "{}"
    @State private var confirmingRemoval = false
    var body: some View {
        Form {
            if let object = state.selected {
                Section(object.title) {
                    if object.requiresPreparation {
                        LabeledContent(chemistryText("Status", "状态"), value: chemistryText("Awaiting processing", "待处理"))
                    } else {
                    LabeledContent(object.facts?["compositionOnly"] == .bool(true) ? chemistryText("Explicit composition", "显式原子组成") : chemistryText("Formula", "分子式"), value: object.facts?["formula"]?.string ?? "—")
                    if let mass = object.facts?["mass"]?.number { LabeledContent(object.facts?["compositionOnly"] == .bool(true) ? chemistryText("Explicit atom mass", "显式原子质量") : chemistryText("Molar mass", "摩尔质量"), value: mass.formatted() + " g/mol") }
                    if let count = object.facts?["atomCount"]?.number { LabeledContent(chemistryText("Atoms", "原子"), value: Int(count).description) }
                    if let count = object.facts?["residueCount"]?.number, count > 0 { LabeledContent(chemistryText("Residues", "残基"), value: Int(count).description) }
                    }
                    Text(chemistryText("Object revision", "对象版本") + " \(object.revision)").font(.caption).foregroundStyle(.secondary)
                }
                if ![.note, .spectrum].contains(object.kind) {
                    Section(chemistryText("Calculation", "计算")) {
                        Picker(chemistryText("Environment", "执行环境"), selection: Binding(get: { state.project?.defaultEnvironmentID ?? "native.local" }, set: { value in
                            Task { await state.perform { _ = try await state.service.setEnvironment(state.projectID, environmentID: value) } }
                        })) { ForEach(environments.keys.sorted(), id: \.self) { Text(state.environmentTitle($0)).tag($0) } }
                        Picker(chemistryText("Method", "方法"), selection: $method) {
                            ForEach((environments[state.project?.defaultEnvironmentID ?? "native.local"] ?? []).filter { !["parse","export","edit","reaction.balance","spectrum.analyze"].contains($0) }, id: \.self) { Text(chemistryMethodTitle($0)).tag($0) }
                        }
                        if needsPrepared3D {
                            Text(ChemistryError.requiresPrepared3DStructure.localizedDescription)
                                .font(.callout).foregroundStyle(.secondary)
                                .accessibilityIdentifier("chemistry.preparation.required")
                            if preparationEnvironments.isEmpty {
                                Text(chemistryText("Choose an environment with 3D structure generation, or import a prepared 3D structure. Your drawing is kept.", "选择支持三维结构生成的运行环境，或导入已准备好的三维结构。原绘图会保留。"))
                                    .font(.footnote).foregroundStyle(.secondary)
                                if let onPrepareStructure {
                                    Button(chemistryText("Set up 3D generation", "设置三维结构生成"), systemImage: "cube") {
                                        onPrepareStructure(object.id)
                                    }.accessibilityIdentifier("chemistry.preparation.configure")
                                }
                            } else {
                                Picker(chemistryText("3D generation environment", "三维生成环境"), selection: $preparationEnvironment) {
                                    Text(chemistryText("Choose environment", "选择运行环境")).tag(nil as String?)
                                    ForEach(preparationEnvironments, id: \.self) { id in
                                        Text(state.environmentTitle(id)).tag(Optional(id))
                                    }
                                }
                                Button(chemistryText("Generate 3D with hydrogens", "生成含氢三维结构"), systemImage: "cube") {
                                    guard let id = preparationEnvironment else { return }
                                    Task { await state.generate3D(environmentID: id) }
                                }.disabled(state.busy || preparationEnvironment == nil)
                                    .accessibilityIdentifier("chemistry.preparation.generate")
                                Text(chemistryText("When generation finishes, choose Apply structure in Calculations, then run the force-field calculation.", "生成完成后，在“计算任务”中点“应用结构”，再运行力场计算。"))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        LabeledContent(chemistryText("Iterations", "迭代次数")) { TextField("", value: $iterations, format: .number).multilineTextAlignment(.trailing).accessibilityLabel(chemistryText("Iterations", "迭代次数")) }
                        LabeledContent(chemistryText("Gradient tolerance", "梯度阈值")) { TextField("", value: $tolerance, format: .number).multilineTextAlignment(.trailing).accessibilityLabel(chemistryText("Gradient tolerance", "梯度阈值")) }
                        DisclosureGroup(chemistryText("Advanced method parameters · JSON", "高级方法参数 · JSON")) {
                            TextEditor(text: $advancedOptions).font(.system(.caption, design: .monospaced)).frame(minHeight: 100)
                        }
                    }
                    if !object.requiresPreparation && object.kind != .reaction {
                    Section(chemistryText("Atoms and bonds", "原子与化学键")) {
                        Text(chemistryText("Tap atoms in the canvas to select them.", "点按画布中的原子进行选择。"))
                        Text(selectedAtoms.map { String($0 + 1) }.joined(separator: ", ")).font(.caption.monospaced())
                        LabeledContent(chemistryText("Atomic number", "原子序数")) { TextField("", value: $atomicNumber, format: .number).multilineTextAlignment(.trailing).accessibilityLabel(chemistryText("Atomic number", "原子序数")) }
                        HStack {
                            Text("x"); TextField("x", value: $x, format: .number)
                            Text("y"); TextField("y", value: $y, format: .number)
                            Text("z"); TextField("z", value: $z, format: .number)
                        }
                        Button(chemistryText("Add atom", "添加原子")) { edit(.object(["op": .string("atom.add"), "atomicNumber": .number(Double(atomicNumber)), "position": .array([.number(x),.number(y),.number(z)])])) }
                        if let index = selectedAtoms.first {
                            Button(chemistryText("Change element", "修改元素")) { edit(.object(["op": .string("atom.replace"), "index": .number(Double(index)), "atomicNumber": .number(Double(atomicNumber))])) }
                            Button(chemistryText("Set coordinates", "设置坐标")) { edit(.object(["op": .string("atom.position"), "index": .number(Double(index)), "position": .array([.number(x),.number(y),.number(z)])])) }
                            Button(chemistryText("Remove selected atom", "删除所选原子"), role: .destructive) { edit(.object(["op": .string("atom.remove"), "index": .number(Double(index))])) }
                        }
                        if selectedAtoms.count == 2 {
                            Stepper(chemistryText("Bond order", "键级") + ": \(bondOrder)", value: $bondOrder, in: 1...3)
                            Button(chemistryText("Add bond", "添加化学键")) { edit(.object(["op": .string("bond.add"), "a": .number(Double(selectedAtoms[0])), "b": .number(Double(selectedAtoms[1])), "order": .number(Double(bondOrder))])) }
                            Button(chemistryText("Remove bond", "删除化学键")) { edit(.object(["op": .string("bond.remove"), "a": .number(Double(selectedAtoms[0])), "b": .number(Double(selectedAtoms[1]))])) }
                            if scene.isThreeDimensional, selectedAtoms.allSatisfy(scene.atoms.indices.contains) {
                                let p = scene.atoms[selectedAtoms[0]], q = scene.atoms[selectedAtoms[1]]
                                let distance = sqrt(pow(p.x-q.x,2)+pow(p.y-q.y,2)+pow(p.zc-q.zc,2))
                                LabeledContent(chemistryText("Distance", "距离"), value: distance.formatted() + " Å")
                            }
                        }
                    }
                    Section(chemistryText("Crystal supercell", "晶体超胞")) {
                        Stepper("a × \(a)", value: $a, in: 1...100)
                        Stepper("b × \(b)", value: $b, in: 1...100)
                        Stepper("c × \(c)", value: $c, in: 1...100)
                        Button(chemistryText("Build supercell", "构建超胞")) { Task { await state.run(method: "crystal.supercell", options: .object(["a": .number(Double(a)), "b": .number(Double(b)), "c": .number(Double(c))])) } }
                    }
                    }
                }
                Section(chemistryText("Export", "导出")) {
                    Picker(chemistryText("Format", "格式"), selection: $exportFormat) {
                        ForEach(["xyz","sdf","mol","pdb","smi","smiles","cif","mmcif","cjson","qcschema","rxn","ket","csv","reaction.json","text"], id: \.self) { Text($0.uppercased()).tag($0) }
                    }
                    Button(chemistryText("Export file", "导出文件"), systemImage: "square.and.arrow.up") {
                        Task { await state.perform {
                            exportDocument = ChemistryTextDocument(text: try await state.service.export(state.projectID, objectID: object.id, format: exportFormat)); exporting = true
                        } }
                    }
                }
                Section {
                    Button(chemistryText("Remove this object", "移除此对象"), systemImage: "trash", role: .destructive) {
                        confirmingRemoval = true
                    }.accessibilityIdentifier("chemistry.object.remove.confirm")
                }
                if let error = state.error { Section(chemistryText("Operation incomplete · details", "操作未完成 · 详情")) { Text(error).font(.caption).foregroundStyle(.red) } }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let object = state.selected, ![.note, .spectrum].contains(object.kind) {
                runButton.buttonStyle(.borderedProminent).padding().frame(maxWidth: .infinity).background(.regularMaterial)
            }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .plainText, defaultFilename: (state.selected?.title ?? "structure") + "." + exportFormat) { result in
            if case .failure(let error) = result { state.error = error.localizedDescription }
        }
        .confirmationDialog(chemistryText("Remove this object?", "移除这个对象？"), isPresented: $confirmingRemoval) {
            Button(chemistryText("Remove", "移除"), role: .destructive) {
                guard let object = state.selected else { return }
                Task { await state.removeObject(object.id) }
            }
            Button(chemistryText("Cancel", "取消"), role: .cancel) {}
        } message: {
            if let object = state.selected, state.hasUnsavedEdits(for: object.id) {
                Text(chemistryText("“\(object.title)” has unsaved edits that will be discarded. Content already saved can be restored from History.", "“\(object.title)”有未保存的修改，移除后会丢弃这些修改；已保存的内容可在历史版本中恢复。"))
            } else if let object = state.selected {
                Text(chemistryText("“\(object.title)” will be removed. Content already saved can be restored from History.", "将移除“\(object.title)”。已保存的内容可在历史版本中恢复。"))
            }
        }
        .task { await state.refreshCapabilities() }
        .onChange(of: environments) { _, _ in selectAvailableMethod() }
        .onChange(of: state.project?.defaultEnvironmentID) { _, _ in
            selectAvailableMethod()
        }
        .task(id: "\(state.selectedID?.uuidString ?? "")-\(state.selected?.revision ?? 0)") {
            guard !Task.isCancelled else { return }
            scene=ChemistryScene()
            guard let object=state.selected else { return }
            if object.requiresPreparation { exportFormat=object.format;return }
            do {
                let parsed=try await ChemistryScene.load(object.facts?["cjson"]?.string ?? (object.format == "cjson" ? object.source : "{}"))
                guard !Task.isCancelled,state.selectedID == object.id,state.selected?.revision == object.revision else { return }
                scene=parsed;sceneGeneration &+= 1
            } catch is CancellationError { } catch {
                guard !Task.isCancelled,state.selectedID == object.id,state.selected?.revision == object.revision else { return }
                scene=ChemistryScene()
            }
        }
        .onChange(of:selectedAtoms.first) { _,_ in updateSelectedAtom() }
        // This callback receives the current selection, not the immutable
        // View value captured before the background parse suspended.
        .onChange(of:sceneGeneration) { _,_ in updateSelectedAtom() }
    }
    private func updateSelectedAtom() {
        guard let index=selectedAtoms.first,scene.atoms.indices.contains(index) else { return }
        let atom=scene.atoms[index];atomicNumber=atom.z
        if scene.isThreeDimensional { x=atom.x;y=atom.y;z=atom.zc }
    }
    private func selectAvailableMethod() {
        let methods = (environments[state.project?.defaultEnvironmentID ?? "native.local"] ?? [])
            .filter { !["parse", "edit", "export", "reaction.balance", "spectrum.analyze"].contains($0) }
        if !methods.contains(method) { method = methods.first ?? "analyze" }
    }
    private var needsPrepared3D: Bool {
        state.selected?.requires3DPreparation == true && ["uff.energy", "uff.optimize"].contains(method)
    }
    private var preparationEnvironments: [String] {
        environments.keys.filter { environments[$0]?.contains("rdkit.embed") == true }.sorted()
    }
    private var runButton: some View {
        Button(chemistryText("Run calculation", "开始计算"), systemImage: "play.fill") {
            Task {
                do {
                    let value = try JSONDecoder().decode(JSONValue.self, from: Data(advancedOptions.utf8))
                    guard case .object(var options) = value else { throw ChemistryError.invalid("Method parameters must be a JSON object.") }
                    if options["iterations"] == nil { options["iterations"] = .number(Double(iterations)) }
                    if options["tolerance"] == nil { options["tolerance"] = .number(tolerance) }
                    await state.run(method: method, options: .object(options))
                } catch { state.error = error.localizedDescription }
            }
        }.disabled(state.busy || needsPrepared3D)
    }
    private func edit(_ value: JSONValue) {
        guard let object = state.selected else { return }
        Task { await state.perform { _ = try await state.service.editObject(state.projectID, objectID: object.id, expectedObjectRevision: object.revision, edits: .array([value])) } }
    }
}

@MainActor struct ChemistryInspectorSheet: View {
    let state: ChemistryEditorState
    let selectedAtoms: [Int]
    var onPrepareStructure: (@MainActor (UUID) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ChemistryInspector(state: state, selectedAtoms: selectedAtoms, onPrepareStructure: onPrepareStructure)
                .navigationTitle(chemistryText("Properties and methods", "属性与方法"))
                .toolbar { Button(chemistryText("Done", "完成")) { dismiss() } }
        }
    }
}
