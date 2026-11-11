import Foundation
import Observation
import FloeChemistryCore
import FloeChemistryEngine
import FloeChemistrySketch

enum ChemicalDrawTool: String,CaseIterable { case bond, atom, select, erase, chargePlus, chargeMinus, arrow, reactionPlus, text, ring, pan
    var title: String { switch self {
    case .bond: chemistryText("Bond", "化学键"); case .atom: chemistryText("Atom", "原子"); case .select: chemistryText("Select", "选择")
    case .erase: chemistryText("Erase", "擦除"); case .chargePlus: chemistryText("Increase charge", "增加电荷"); case .chargeMinus: chemistryText("Decrease charge", "减少电荷")
    case .arrow: chemistryText("Reaction arrow", "反应箭头"); case .reactionPlus: chemistryText("Reaction plus", "反应加号"); case .text: chemistryText("Text", "文字"); case .ring: chemistryText("Ring template", "环模板"); case .pan: chemistryText("Pan", "平移") } }
    var symbol: String { switch self { case .bond: "line.diagonal"; case .atom: "atom"; case .select: "lasso"; case .erase: "eraser"; case .chargePlus: "plus.circle"; case .chargeMinus: "minus.circle"; case .arrow: "arrow.right"; case .reactionPlus: "plus"; case .text: "textformat"; case .ring: "hexagon"; case .pan: "hand.draw" } }
}
enum ChemicalBondStyle: String,CaseIterable { case single, double, triple, wedge, hashed, either, aromatic
    var title: String { switch self { case .single: chemistryText("Single", "单键"); case .double: chemistryText("Double", "双键"); case .triple: chemistryText("Triple", "三键"); case .wedge: chemistryText("Solid wedge", "实楔键"); case .hashed: chemistryText("Hashed wedge", "虚楔键"); case .either: chemistryText("Either stereochemistry", "未指定立体键"); case .aromatic: chemistryText("Aromatic", "芳香键") } }
    var order: Int { switch self { case .double: 2; case .triple: 3; case .aromatic: 4; default: 1 } }
    var stereo: Int { switch self { case .wedge: 1; case .hashed: 6; case .either: 4; default: 0 } }
}

@MainActor public protocol ChemistryStructureProcessing: Sendable {
    func evaluate(_ source: String, layout: Bool) async throws -> ChemistrySketchSnapshot
}
public extension ChemistryStructureProcessing {
    func evaluate(_ source: String) async throws -> ChemistrySketchSnapshot { try await evaluate(source, layout: false) }
}
extension ChemistryStructureProcessor: ChemistryStructureProcessing {}

@MainActor @Observable final class NativeDrawingSession {
    let objectID: UUID
    private let projectID: UUID
    private let service: ChemistryService
    private let processor: any ChemistryStructureProcessing
    private weak var editor: ChemistryEditorState?
    var document = try! ChemicalDrawing2D()
    var selection: Set<ChemicalAtomID> = []
    var tool = ChemicalDrawTool.bond
    var previousTool = ChemicalDrawTool.atom
    var element = "C"
    var bondStyle = ChemicalBondStyle.single
    var ringSize = 6
    var aromaticRing = true
    var rectangleSelection = false
    var drawWithFinger = UserDefaults.standard.bool(forKey: "floe.chemistry.fingerDrawing.enabled") {
        didSet { UserDefaults.standard.set(drawWithFinger, forKey: "floe.chemistry.fingerDrawing.enabled") }
    }
    var fitToken = UUID()
    var loaded = false
    var warning: String?
    var generation: UInt64 = 0
    /// Set when the owning object is removed: every save/conversion/loading
    /// continuation re-checks this after its awaits, so a late callback can
    /// never resurrect statuses or publish to a removed object.
    private(set) var discarded = false
    private(set) var expectedRevision: UInt64
    private var savedGeneration: UInt64 = 0
    private var undoStack: [ChemicalDrawing2D] = []
    private var redoStack: [ChemicalDrawing2D] = []
    private var saveTask: Task<Void,Never>?
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isDirty: Bool { generation != savedGeneration }
    /// Only a real unsaved generation (or a save still in flight) is pending
    /// work. A load failure never dirties the document, so it must not block
    /// leaving the editor; a failed save of real edits still does.
    var blocksExit: Bool { isDirty || saveTask != nil }

    init(editor: ChemistryEditorState, object: ChemicalObject, processor: any ChemistryStructureProcessing) {
        self.editor = editor; service = editor.service; projectID = editor.projectID
        objectID = object.id; expectedRevision = object.revision; self.processor = processor
        if let ket = object.sketchDocument, let value = try? ChemicalDrawing2D(ket) { document = value; loaded = true }
    }
    func load(_ object: ChemicalObject) async {
        guard !discarded else { return }
        if loaded { externalUpdate(object); return }
        editor?.sketchStatuses[objectID] = .loading
        do {
            let source:String
            if let ket = object.sketchDocument {source = ket}
            else {source = try await service.export(projectID,objectID:objectID,format:"mol")}
            let result = try await processor.evaluate(source)
            guard !loaded, !discarded else { return }
            document = try ChemicalDrawing2D(result.ket); loaded = true; fitToken = UUID()
            editor?.sketchStatuses[objectID] = .saved
        } catch {
            guard !discarded else { return }
            warning = error.localizedDescription; editor?.sketchStatuses[objectID] = .failed(error.localizedDescription)
        }
    }
    func externalUpdate(_ object: ChemicalObject) {
        guard !discarded else { return }
        guard object.revision != expectedRevision else { return }
        guard !isDirty, saveTask == nil else { warning = chemistryText("The saved structure changed. Your drawing is retained; save conflicts are available in History.", "已保存的结构发生变化。当前绘图会保留，保存冲突可在历史版本中恢复。"); return }
        if let ket = object.sketchDocument, let updated = try? ChemicalDrawing2D(ket) {
            document = updated; expectedRevision = object.revision; undoStack = []; redoStack = []; fitToken = UUID()
        }
    }
    func choose(_ value: ChemicalDrawTool) { if value != tool { previousTool = tool; tool = value } }
    func toggleEraser() { let target = tool == .erase ? previousTool : .erase; choose(target == .erase && tool == .erase ? .bond : target) }
    func togglePrevious() { let target = previousTool; previousTool = tool; tool = target }
    func commit(_ action: (inout ChemicalDrawing2D) throws -> Void) {
        guard loaded, !discarded else { return }
        do {
            var next = document; try action(&next)
            let text = try next.encoded()
            guard text.utf8.count <= 16 * 1024 * 1024 else { throw ChemistryError.invalid("Drawing exceeds its size limit.") }
            guard next != document else { return }
            undoStack.append(document); redoStack = []
            trimHistory(); document = next; changed()
        } catch { warning = error.localizedDescription }
    }
    private func trimHistory() {
        while undoStack.count > 80 { undoStack.removeFirst() }
        var bytes = 0
        for i in undoStack.indices.reversed() {
            bytes += (try? undoStack[i].encoded().utf8.count) ?? 0
            if bytes > 32 * 1024 * 1024 { undoStack.removeFirst(i+1); break }
        }
    }
    func undo() { guard let value = undoStack.popLast() else { return }; redoStack.append(document); document = value; changed() }
    func redo() { guard let value = redoStack.popLast() else { return }; undoStack.append(document); document = value; changed() }
    private func changed() {
        guard !discarded else { return }
        generation += 1; warning = nil
        let ids = Set(document.atoms.map(\.id)); selection.formIntersection(ids)
        editor?.sketchStatuses[objectID] = .editing
        schedule()
    }
    private func schedule() {
        guard saveTask == nil, !discarded else { return }
        saveTask = Task { [self] in
            // Cancellation must actually exit: a discarded session never drains.
            do { try await Task.sleep(for:.milliseconds(200)) } catch { return }
            await drain(); saveTask = nil
        }
    }
    private func publish(_ snapshot: ChemistrySketchSnapshot) async throws {
        let saved = try await service.saveSketch(projectID,objectID:objectID,expectedObjectRevision:expectedRevision,ket:snapshot.ket,format:snapshot.format,source:snapshot.source,smiles:snapshot.smiles,properties:snapshot.properties)
        expectedRevision = saved.revision
        if let editor { await editor.refresh() }
    }
    /// Internal (not private) so the focused lifecycle host can prove a late
    /// drain continuation writes nothing after discard.
    func drain() async {
        while generation != savedGeneration, !discarded, !Task.isCancelled {
            let current = generation
            do {
                let ket = try document.encoded()
                guard !discarded, !Task.isCancelled else { return }
                editor?.sketchStatuses[objectID] = .saving
                // Persist raw drawing first. Validation/conversion is independent of
                // durability and cannot discard Pencil work if the engine stops.
                try await publish(ChemistrySketchSnapshot(ket:ket,format:nil,source:nil,smiles:nil))
                guard !discarded, !Task.isCancelled else { return }
                savedGeneration = current
                do {
                    var result = try await processor.evaluate(ket)
                    guard !discarded, !Task.isCancelled else { return }
                    if generation == current {
                        result.ket = ket
                        try await publish(result)
                        guard !discarded, !Task.isCancelled else { return }
                    }
                } catch {
                    guard !discarded else { return }
                    warning = error.localizedDescription
                }
                editor?.sketchStatuses[objectID] = generation == current ? .saved : .editing
            } catch {
                // The object may have been removed while this save was in
                // flight; never resurrect its status after discard.
                guard !discarded, !Task.isCancelled else { return }
                warning = error.localizedDescription
                editor?.sketchStatuses[objectID] = .failed(error.localizedDescription)
                return
            }
        }
    }
    func flush() async {
        if let task = saveTask { await task.value }
        if isDirty { await drain() }
    }
    /// The owning object is being removed: fence first so no continuation can
    /// write statuses or publish after this point, then join the in-flight
    /// save task before the editor drops this session. Saved content remains
    /// recoverable from the project's History.
    func discard() async {
        discarded = true
        generation = savedGeneration
        saveTask?.cancel()
        if let task = saveTask { await task.value }
        saveTask = nil
        undoStack = []; redoStack = []; selection = []; warning = nil
    }
    func cleanLayout() async {
        do {
            let originalGeneration = generation
            let result = try await processor.evaluate(document.encoded(),layout:true)
            guard generation == originalGeneration else { throw ChemistryError.invalid("The drawing changed during layout; your edits are retained.") }
            let updated = try ChemicalDrawing2D(result.ket)
            commit { $0 = updated }; fitToken = UUID()
        } catch {
            guard !discarded else { return }
            warning = error.localizedDescription
        }
    }
    func pasteDrawing(_ text: String) async {
        do {
            let originalGeneration = generation
            let result = try await processor.evaluate(text,layout:true)
            guard generation == originalGeneration else { throw ChemistryError.invalid("The drawing changed during paste; your edits are retained.") }
            let updated = try ChemicalDrawing2D(result.ket); commit {try $0.insert(updated)}; fitToken = UUID()
        } catch {
            guard !discarded else { return }
            warning = error.localizedDescription
        }
    }
}
