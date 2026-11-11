import Foundation
import Observation
import FloeChemistryCore
import FloeChemistryEngine
import FloeChemistrySketch

public func chemistryText(_ english: String, _ chinese: String) -> String {
    Locale.current.language.languageCode?.identifier == "zh" ? chinese : english
}
extension ChemicalKind {
    var displayTitle: String {
        switch self {
        case .molecule: chemistryText("Molecule", "分子")
        case .crystal: chemistryText("Crystal", "晶体")
        case .biomolecule: chemistryText("Biomolecular structure", "生物结构")
        case .reaction: chemistryText("Reaction", "反应")
        case .spectrum: chemistryText("Spectrum", "谱图")
        case .trajectory: chemistryText("Trajectory", "轨迹")
        case .note: chemistryText("Text", "文字")
        }
    }
}
extension ChemicalObject {
    var requiresPreparation: Bool { facts?["preparationRequired"] == .bool(true) }
    var displaySummary: String {
        requiresPreparation ? chemistryText("Awaiting processing", "待处理") : (facts?["formula"]?.string ?? kind.displayTitle)
    }
}
extension ChemistryRunStatus {
    var displayTitle: String {
        switch self {
        case .queued: chemistryText("Queued", "等待执行")
        case .running: chemistryText("Running", "计算中")
        case .succeeded: chemistryText("Completed", "已完成")
        case .failed: chemistryText("Failed", "失败")
        case .cancelled: chemistryText("Cancelled", "已停止")
        case .interrupted: chemistryText("Interrupted", "已中断")
        }
    }
}
func chemistryEnvironmentTitle(_ id: String) -> String { id == "native.local" ? chemistryText("On this device", "本机") : chemistryText("Configured environment", "已配置环境") }
func chemistryMethodTitle(_ id: String) -> String {
    switch id {
    case "uff.optimize": chemistryText("UFF · optimize geometry", "UFF · 几何优化")
    case "uff.energy": chemistryText("UFF · evaluate energy", "UFF · 能量计算")
    case "analyze": chemistryText("Structure analysis", "结构分析")
    case "measure": chemistryText("Distance, angle and dihedral", "距离、角度与二面角")
    case "trajectory.frame": chemistryText("Trajectory frame", "轨迹帧")
    case "crystal.supercell": chemistryText("Crystal supercell", "晶体超胞")
    case "rdkit.embed": chemistryText("3D structure generation", "三维结构生成")
    case "rdkit.conformers": chemistryText("Conformer search", "构象搜索")
    case "rdkit.describe": chemistryText("Molecular descriptors", "分子描述符")
    case "rdkit.similarity": chemistryText("Molecular similarity", "分子相似性")
    case "rdkit.substructure": chemistryText("Substructure search", "子结构检索")
    case "rdkit.reaction": chemistryText("Reaction rules", "反应规则")
    case "gemmi.crystal": chemistryText("Crystal structure", "晶体结构")
    case "gemmi.diffraction": chemistryText("X-ray diffraction", "X 射线衍射")
    case "gemmi.structure": chemistryText("Biomolecular structure analysis", "生物结构分析")
    case "openmm.lennardJones": chemistryText("Lennard-Jones particle dynamics", "Lennard-Jones 粒子动力学")
    case "openmm.system": chemistryText("OpenMM dynamics · supplied system", "OpenMM 动力学 · 指定体系")
    case "xtb.singlepoint": chemistryText("xTB single-point energy", "xTB 单点能")
    case "xtb.optimize": chemistryText("xTB geometry optimization", "xTB 几何优化")
    default: id
    }
}

@MainActor @Observable
public final class ChemistryEditorState {
    public let service: ChemistryService
    public let projectID: UUID
    public var project: ChemistryProject?
    public var availableEnvironments: [String: [String]] = [:]
    /// Native host labels for presentation only; execution still uses IDs.
    public var environmentDisplayNames: [String: String] = [:]
    public func environmentTitle(_ id: String) -> String {
        if id == "native.local" { return chemistryText("On this device", "本机") }
        if let name = environmentDisplayNames[id]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty, name != id, UUID(uuidString: name) == nil { return name }
        return chemistryText("Configured environment", "已配置环境")
    }
    public var selectedID: UUID?
    public var error: String?
    public var busy = false
    public var drafts: [UUID: String] = [:]
    public var sketchStatuses: [UUID: ChemistrySketchStatus] = [:]
    private var baselines: [UUID: String] = [:]
    private var saves: [UUID: Task<Void, Never>] = [:]
    private var savingBlocks: Set<UUID> = []
    @ObservationIgnored private lazy var structureProcessor = ChemistryStructureProcessor()
    @ObservationIgnored private var drawingSessions: [UUID:NativeDrawingSession] = [:]
    /// Trusted host callbacks retain Floe's resolved environment/jobs authorization and ownership.
    /// Omitting them keeps the standalone native calculation path.
    @ObservationIgnored public var calculationHandler: (@MainActor @Sendable (UUID, String, JSONValue) async throws -> UUID)?
    @ObservationIgnored public var cancellationHandler: (@MainActor @Sendable (UUID) async throws -> Void)?
    public init(service: ChemistryService, projectID: UUID) { self.service = service; self.projectID = projectID }
    public var selected: ChemicalObject? { project?.objects.first(where: { $0.id == selectedID }) }
    func drawingSession(for object:ChemicalObject) -> NativeDrawingSession {
        if let existing = drawingSessions[object.id] { return existing }
        let value = NativeDrawingSession(editor:self,object:object,processor:structureProcessor)
        drawingSessions[object.id] = value; return value
    }
    public var hasPendingEdits: Bool {
        if busy || !drafts.isEmpty || !savingBlocks.isEmpty { return true }
        for (id, status) in sketchStatuses {
            switch status {
            case .editing, .saving: return true
            case .failed:
                // A load failure never dirtied the drawing: it must not lock
                // the editor open. A failed save of real edits still does.
                if failedSketchIsPending(id) { return true }
            default: break
            }
        }
        return false
    }
    /// A `.failed` sketch blocks exit only when its session holds unsaved
    /// work; a clean load failure has no session edits and is not pending.
    func failedSketchIsPending(_ id: UUID) -> Bool { drawingSessions[id]?.blocksExit ?? true }
    /// Test seam for the focused lifecycle host: register a session built
    /// with an injected processor. Production uses `drawingSession(for:)`.
    func registerDrawingSession(_ session: NativeDrawingSession) {
        drawingSessions[session.objectID] = session
    }
    public var saveStatus: String {
        if let id = selectedID, sketchStatuses[id] == .loading { return chemistryText("Opening editor…", "正在打开绘图器…") }
        let failedIDs = sketchStatuses.compactMap { id, status -> UUID? in
            if case .failed = status { return id }
            return nil
        }
        if !failedIDs.isEmpty {
            return failedIDs.allSatisfy { !failedSketchIsPending($0) }
                ? chemistryText("A drawing could not be opened", "有绘图无法打开")
                : chemistryText("Unsaved changes", "有未保存的修改")
        }
        return hasPendingEdits ? (error == nil ? chemistryText("Saving…", "保存中…") : chemistryText("Unsaved changes", "有未保存的修改")) : chemistryText("Saved", "已保存")
    }
    /// Removing this object would discard local edits that are not saved yet.
    public func hasUnsavedEdits(for objectID: UUID) -> Bool {
        if let status = sketchStatuses[objectID] {
            switch status {
            case .editing, .saving: return true
            case .failed: if failedSketchIsPending(objectID) { return true }
            default: break
            }
        }
        let blockIDs = project?.blocks.filter { $0.objectID == objectID }.map(\.id) ?? []
        return blockIDs.contains { drafts[$0] != nil || saves[$0] != nil || savingBlocks.contains($0) }
    }
    public func refresh() async {
        do {
            await refreshCapabilities()
            project = try await service.project(projectID)
            if selectedID == nil { selectedID = project?.objects.first?.id }
            let liveBlocks = Set(project?.blocks.map(\.id) ?? [])
            for id in Array(drafts.keys) where !liveBlocks.contains(id) && saves[id] == nil {
                drafts.removeValue(forKey: id); baselines.removeValue(forKey: id)
            }
            for block in project?.blocks ?? [] where drafts[block.id] == nil { baselines[block.id] = block.text }
        } catch { self.error = error.localizedDescription }
    }
    public func refreshCapabilities() async { availableEnvironments = await service.capabilities() }
    public func perform(_ operation: @MainActor () async throws -> Void) async {
        busy = true; error = nil
        defer { busy = false }
        do { try await operation(); await refresh() }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    public func importSource(title: String, kind: ChemicalKind, format: String, source: String, deferPreparation: Bool = false) async {
        await perform {
            selectedID = try await service.importObject(projectID, title: title, kind: kind, format: format,
                source: source, deferPreparation: deferPreparation).id
        }
    }
    public func createDrawing() async {
        await perform { selectedID = try await service.createDrawing(projectID, title: chemistryText("Untitled molecule", "未命名分子")).id }
    }
    /// Remove one object and its document references. Unsaved local edits for
    /// that object are discarded only after the removal commits; if removal
    /// fails, every pending edit and recovery draft is preserved.
    public func removeObject(_ objectID: UUID) async {
        guard !busy, let object = project?.objects.first(where: { $0.id == objectID }) else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            _ = try await service.removeObject(projectID, objectID: objectID, expectedObjectRevision: object.revision)
            let removedBlockIDs = project?.blocks.filter { $0.objectID == objectID }.map(\.id) ?? []
            for blockID in removedBlockIDs {
                saves[blockID]?.cancel(); saves.removeValue(forKey: blockID)
                drafts.removeValue(forKey: blockID); baselines.removeValue(forKey: blockID); savingBlocks.remove(blockID)
            }
            // Quiesce the drawing session before dropping its status: the
            // fence joins the in-flight save, so a late failure cannot
            // resurrect a `.failed` status for the removed object and
            // re-lock exit (no session remains to prove it is clean).
            if let session = drawingSessions.removeValue(forKey: objectID) { await session.discard() }
            sketchStatuses.removeValue(forKey: objectID)
            if selectedID == objectID { selectedID = project?.objects.first(where: { $0.id != objectID })?.id }
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    public func saveSketch(_ snapshot: ChemistrySketchSnapshot, objectID: UUID, revision: String) async throws -> String {
        guard let expected = UInt64(revision) else { throw ChemistryError.invalid("Invalid drawing revision.") }
        let object = try await service.saveSketch(projectID, objectID: objectID, expectedObjectRevision: expected,
                                                  ket: snapshot.ket, format: snapshot.format, source: snapshot.source, smiles: snapshot.smiles, properties: snapshot.properties)
        await refresh()
        return String(object.revision)
    }
    public func run(method: String, options: JSONValue = .object([:])) async {
        guard let selectedID else { return }
        await perform {
            if let calculationHandler { _ = try await calculationHandler(selectedID, method, options) }
            else { _ = try await service.start(projectID, objectID: selectedID, method: method, options: options) }
        }
    }
    public func generate3D(environmentID: String) async {
        guard let selectedID, availableEnvironments[environmentID]?.contains("rdkit.embed") == true else { return }
        await perform {
            _ = try await service.setEnvironment(projectID, environmentID: environmentID)
            if let calculationHandler { _ = try await calculationHandler(selectedID, "rdkit.embed", .object([:])) }
            else { _ = try await service.start(projectID, objectID: selectedID, method: "rdkit.embed", environmentID: environmentID) }
        }
    }
    public func cancel(runID: UUID) async {
        await perform {
            if let cancellationHandler { try await cancellationHandler(runID) }
            else { try await service.cancel(projectID, runID: runID) }
        }
    }
    public func setText(_ id: UUID, text: String) {
        if baselines[id] == nil { baselines[id] = project?.blocks.first(where: { $0.id == id })?.text ?? "" }
        drafts[id] = text
        guard !savingBlocks.contains(id) else { return }
        saves[id]?.cancel()
        saves[id] = Task {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await persistText(id)
        }
    }
    private func persistText(_ id: UUID) async {
        guard !savingBlocks.contains(id) else { return }
        savingBlocks.insert(id)
        defer { savingBlocks.remove(id); saves.removeValue(forKey: id) }
        if drafts[id] == baselines[id] { drafts.removeValue(forKey: id) }
        while let text = drafts[id], text != baselines[id] {
            do {
                project = try await service.updateText(projectID, blockID: id, expectedText: baselines[id] ?? "", text: text)
                baselines[id] = text
                if drafts[id] == text { drafts.removeValue(forKey: id) }
            } catch { self.error = error.localizedDescription; return }
        }
    }
    public func flush() async {
        for id in Array(drafts.keys) { await persistText(id) }
        for session in Array(drawingSessions.values) { await session.flush() }
    }
}
