import SwiftUI
import Observation
import CryptoKit
import FloeMoleculePreviewNative
import FloeChemistryCore
import FloeChemistryEngine
import FloeChemistryUI

private func t(_ en: String, _ zh: String) -> String { Locale.current.language.languageCode?.identifier == "zh" ? zh : en }
private struct Sample: Codable, Identifiable, Sendable {
    let id: String
    let smiles: String
    let file: String
    let sha256: String
    var title: String {
        switch id {
        case "ethanol": t("Ethanol", "乙醇")
        case "benzene": t("Benzene", "苯")
        case "cyclohexane": t("Cyclohexane", "环己烷")
        case "lactic-R": t("Lactic acid · A", "乳酸 · A")
        case "lactic-S": t("Lactic acid · B", "乳酸 · B")
        case "aspirin": t("Aspirin", "阿司匹林")
        default: id
        }
    }
}

/// This separate host owns its own originals, derived cache and native worker.
/// It never grants access to the Floe App, Linux or external environments.
@MainActor @Observable private final class PreviewHostModel {
    var samples: [Sample] = []
    var selected = "ethanol"
    var editor: ChemistryEditorState?
    var original: ChemicalObject?
    var drawing: ChemistryScene?
    var preview: ChemicalObject?
    var result: MoleculePreviewResult?
    var busy = false
    var cached = false
    var error: String?
    private var service: ChemistryService?
    private var projectID: UUID?
    private var generation = UUID()
    private var worker: Task<Void, Never>?
    private var token: MoleculePreviewCancellation?
    let root = URL.applicationSupportDirectory.appendingPathComponent("NativeMoleculePreview", isDirectory: true)
    private var digest: String {
        SHA256.hash(data: Data((MoleculePreviewNative.version + "\n" + (original?.source ?? "")).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func open() async {
        guard service == nil else { return }
        do {
            guard let index = Bundle.main.url(forResource: "index", withExtension: "json") else { throw CocoaError(.fileNoSuchFile) }
            samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: index))
            let store = try ChemistryProjectStore(root: root.appendingPathComponent("Originals", isDirectory: true))
            let service = try ChemistryService(store: store, authorize: { _ in })
            self.service = service
            let existing = try await service.projects()
            let project: ChemistryProject
            if let first = existing.first { project = first }
            else { project = try await service.create(title: "Native preview qualification") }
            projectID = project.id
            editor = ChemistryEditorState(service: service, projectID: project.id)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Previews"), withIntermediateDirectories: true)
            await load("ethanol")
        } catch { self.error = error.localizedDescription }
    }
    func stop() async {
        generation = UUID()
        token?.cancel(); worker?.cancel()
        if let worker { await worker.value }
        worker = nil; token = nil; busy = false
    }
    func load(_ id: String) async {
        await stop()
        let current = generation
        selected = id; original = nil; drawing = nil; preview = nil; result = nil; error = nil; cached = false
        do {
            guard let service, let projectID, let sample = samples.first(where: { $0.id == id }) else { return }
            let project = try await service.project(projectID)
            let object: ChemicalObject
            if let saved = project.objects.first(where: { $0.title == id }) { object = saved }
            else {
                guard let url = Bundle.main.url(forResource: sample.id, withExtension: "mol") else { throw CocoaError(.fileNoSuchFile) }
                let data = try Data(contentsOf: url)
                guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sample.sha256 else { throw CocoaError(.fileReadCorruptFile) }
                object = try await service.importObject(projectID, title: sample.id, format: "mol", source: String(decoding: data, as: UTF8.self))
            }
            guard generation == current else { return }
            original = object
            if let source = object.facts?["cjson"]?.string { drawing = try await ChemistryScene.load(source) }
            guard generation == current else { return }
            await editor?.refresh(); editor?.selectedID = object.id
        } catch { if generation == current { self.error = error.localizedDescription } }
    }
    func reloadDrawing() async {
        guard let service, let projectID, let id = original?.id else { return }
        do {
            await editor?.flush()
            let project = try await service.project(projectID)
            guard let object = project.objects.first(where: { $0.id == id }) else { return }
            if object.source != original?.source {
                await stop(); preview = nil; result = nil; cached = false
                original = object
                if let source = object.facts?["cjson"]?.string { drawing = try await ChemistryScene.load(source) }
            }
        } catch { self.error = error.localizedDescription }
    }
    func generate() {
        guard !busy, let original else { return }
        let id = UUID(); generation = id
        busy = true; error = nil
        worker = Task { [self] in
            defer { if generation == id { busy = false; worker = nil; token = nil } }
            do {
                let key = digest, source = original.source
                let cache = root.appendingPathComponent("Previews").appendingPathComponent(key+".json")
                let value: MoleculePreviewResult
                if let bytes = try? Data(contentsOf: cache), bytes.count <= 4*1024*1024,
                   let saved = try? JSONDecoder().decode(MoleculePreviewResult.self, from: bytes) {
                    value = saved; cached = true
                } else {
                    let cancellation = try MoleculePreviewCancellation(); token = cancellation
                    value = try await MoleculePreviewNative.generate(input: source, format: .mol, cancellation: cancellation)
                    try Task.checkCancellation()
                    guard generation == id, digest == key else { return }
                    try JSONEncoder().encode(value).write(to: cache, options: .atomic)
                    cached = false
                }
                try Task.checkCancellation()
                guard generation == id, digest == key else { return }
                result = value
                // A derived view object: the service's original is never replaced.
                preview = ChemicalObject(title: original.title, format: "cjson", source: value.cjson,
                    facts: .object(["cjson": .string(value.cjson), "atomCount": .number(Double(value.atomCount))]))
                let receipt: [String: Any] = ["inputSHA256": key, "inputRevision": original.revision,
                    "originalSourceSHA256": SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined(),
                    "cached": cached, "nativeMilliseconds": value.totalMilliseconds, "atomCount": value.atomCount,
                    "engine": value.engine, "method": value.method, "originalUnchanged": self.original == original]
                try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: root.appendingPathComponent("LAST_PREVIEW.json"), options: .atomic)
            } catch is CancellationError {} catch {
                if generation == id { self.error = error.localizedDescription }
            }
        }
    }
}

@main @MainActor struct NativeMoleculePreviewApp: App {
    @State private var model = PreviewHostModel()
    var body: some Scene { WindowGroup { PreviewHost(model: model) } }
}

private struct Editing: Identifiable { let id = UUID() }
@MainActor private struct PreviewHost: View {
    let model: PreviewHostModel
    @State private var selectedAtoms: [Int] = []
    @State private var editing: Editing?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Menu {
                        ForEach(model.samples) { sample in
                            Button(sample.title) { Task { selectedAtoms = []; await model.load(sample.id) } }
                                .accessibilityIdentifier("sample."+sample.id)
                        }
                    } label: { Label(model.samples.first(where: { $0.id == model.selected })?.title ?? t("Choose molecule", "选择分子"), systemImage: "atom") }
                        .accessibilityIdentifier("preview.samples")
                    Spacer()
                    if model.busy {
                        Button(t("Cancel", "取消")) { Task { await model.stop() } }.accessibilityIdentifier("preview.cancel")
                    }
                    Button(t("3D preview", "三维预览"), systemImage: "cube") { model.generate() }
                        .buttonStyle(.borderedProminent).disabled(model.busy || model.original == nil)
                        .accessibilityIdentifier("preview.generate")
                }.padding(12)
                Divider()
                GeometryReader { geometry in
                    if geometry.size.width >= 700 {
                        HStack(spacing: 0) {
                            inputPanel.frame(width: (geometry.size.width-1)/2)
                            Divider()
                            outputPanel.frame(width: (geometry.size.width-1)/2)
                        }.frame(width: geometry.size.width, height: geometry.size.height)
                    } else {
                        VStack(spacing: 0) {
                            inputPanel.frame(height: (geometry.size.height-1)/2)
                            Divider()
                            outputPanel.frame(height: (geometry.size.height-1)/2)
                        }.frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                if let error = model.error {
                    DisclosureGroup(t("Unable to generate · details", "暂时无法生成 · 详情")) { Text(error).font(.caption).textSelection(.enabled) }.padding()
                }
            }
            .navigationTitle(t("2D to 3D · Research", "二维转三维 · 预研"))
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.open() }
            .sheet(item: $editing, onDismiss: { Task { await model.reloadDrawing() } }) { _ in
                if let editor = model.editor {
                    NavigationStack {
                        ChemistryWorkbench(state: editor)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button(t("Done drawing", "完成绘图")) {
                                        Task {
                                            await editor.flush()
                                            if !editor.hasPendingEdits { await model.reloadDrawing(); editing = nil }
                                        }
                                    }.accessibilityIdentifier("preview.drawing.done")
                                }
                            }
                    }.interactiveDismissDisabled(editor.hasPendingEdits)
                }
            }
        }
    }
    private var inputPanel: some View {
        VStack(spacing: 12) {
            HStack {
                Text(t("2D structure", "二维结构")).font(.headline)
                Spacer()
                Button(t("Edit drawing", "编辑绘图"), systemImage: "pencil") { editing = Editing() }
                    .disabled(model.busy || model.editor == nil).accessibilityIdentifier("preview.edit")
            }.padding(.horizontal, 16).padding(.top, 12)
            if let drawing = model.drawing { FlatMolecule(scene: drawing).accessibilityIdentifier("preview.2d") }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            Text(t("Keep drawing, then tap 3D preview.", "画好结构，再点“三维预览”。")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center).padding(.bottom, 16)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var outputPanel: some View {
        VStack(spacing: 0) {
            if let preview = model.preview {
                GeometryReader { geometry in
                    // Keep the molecular camera viewport near square on a tall
                    // split pane, so the whole conformer fits at first display.
                    ChemistryMoleculeView(object: preview, selectedAtoms: $selectedAtoms)
                        .frame(width: geometry.size.width, height: min(geometry.size.height, geometry.size.width+100))
                        .frame(maxHeight: .infinity)
                }.accessibilityIdentifier("preview.viewport")
                Label(model.cached ? t("Saved preview", "已恢复预览") : t("3D preview ready", "三维预览已就绪"), systemImage: "checkmark.circle")
                    .font(.subheadline).foregroundStyle(.secondary).padding(12).accessibilityIdentifier("preview.ready")
                if let result = model.result {
                    DisclosureGroup(t("Generation details", "生成详情")) {
                        Text(result.engine+" · "+result.method+" · "+String(format: "%.1f ms", result.totalMilliseconds)+" · "+result.optimizationStatus)
                            .font(.caption).textSelection(.enabled)
                    }.padding(.horizontal, 16).padding(.bottom, 8)
                }
            } else if model.busy {
                ProgressView(t("Generating 3D preview…", "正在生成三维预览…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(t("See the molecule in 3D", "看看分子的三维形态"), systemImage: "cube.transparent",
                    description: Text(t("Tap 3D preview. Drag to rotate and pinch to zoom.", "点“三维预览”，即可拖动旋转、捏合缩放。")))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FlatMolecule: View {
    let scene: ChemistryScene
    var body: some View {
        Canvas { context, size in
            guard !scene.atoms.isEmpty else { return }
            let xs = scene.atoms.map(\.x), ys = scene.atoms.map(\.y)
            let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
            let scale = min(72, min((size.width-72)/max(2, maxX-minX), (size.height-72)/max(2, maxY-minY)))
            func point(_ i: Int) -> CGPoint { .init(x: size.width/2+(scene.atoms[i].x-(minX+maxX)/2)*scale, y: size.height/2-(scene.atoms[i].y-(minY+maxY)/2)*scale) }
            for bond in scene.bonds {
                let a = point(bond.a), b = point(bond.b), dx = b.x-a.x, dy = b.y-a.y, length = max(1, hypot(dx,dy))
                for line in 0..<max(1, min(3, bond.order)) {
                    let offset = CGFloat(line)-CGFloat(max(1, min(3,bond.order))-1)/2
                    let q = CGVector(dx: -dy/length*offset*5, dy: dx/length*offset*5)
                    var path = Path(); path.move(to: CGPoint(x: a.x+q.dx, y: a.y+q.dy)); path.addLine(to: CGPoint(x: b.x+q.dx, y: b.y+q.dy))
                    context.stroke(path, with: .foreground, lineWidth: 2)
                }
            }
            for (i, atom) in scene.atoms.enumerated() where atom.z != 6 {
                let symbol = [1:"H",7:"N",8:"O",9:"F",15:"P",16:"S",17:"Cl"][atom.z] ?? String(atom.z)
                let p = point(i)
                context.fill(Path(ellipseIn: CGRect(x:p.x-14,y:p.y-14,width:28,height:28)), with: .color(Color(uiColor:.systemBackground)))
                context.draw(Text(symbol).font(.title2.bold()).foregroundStyle(atom.z==8 ? Color.red : Color.blue), at:p)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(12)
    }
}
