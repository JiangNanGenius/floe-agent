import Foundation
import Observation
import FloeSimulationCore
import FloeSimulationRuntime
import FloeSimulationGeometry
import FloeSimulationEngineering
import FloeSimulationPhysics
import FloeSimulationFields
import FloeSimulationAnimation

public struct SimulationSourceObject: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var restTransform: SimulationAnimationTransform
    public init(id: String, name: String, restTransform: SimulationAnimationTransform) { self.id = id; self.name = name; self.restTransform = restTransform }
}

@MainActor @Observable public final class SimulationWorkbenchModel {
    public private(set) var document: SimulationWorkspaceDocument
    public var selectedStudyID: UUID? {
        didSet { if oldValue != selectedStudyID { result = nil; exportURL = nil; frameIndex = 0; selectedFieldID = nil; errorDetails = nil } }
    }
    public private(set) var jobs: [SimulationJobSnapshot] = []
    public private(set) var meshJobs: [SimulationMeshJobSnapshot] = []
    public private(set) var result: SimulationResult?
    public private(set) var savedResults: [SimulationSavedResult] = []
    public var selectedFieldID: String?
    public var frameIndex = 0
    public var probeIndex = 0
    public var deformationScale = 1.0
    public private(set) var exportURL: URL?
    public private(set) var errorDetails: String?
    public private(set) var saving = false
    public private(set) var hasUnsavedChanges = false
    public private(set) var hasExternalChanges = false
    public private(set) var isClosed = false
    public private(set) var sourceAvailable = true
    public private(set) var sourceObjects: [SimulationSourceObject] = []
    public private(set) var animationPreviewRevision: UInt64 = 0
    public var displaysAnimation = false
    public var animationTimeSeconds = 0.0
    public private(set) var animationPose: SimulationAnimationPose?
    public private(set) var baking = false
    public private(set) var bakeProgress: SimulationProgress?
    public private(set) var bakeCancelling = false
    private var bakeTask: Task<SimulationAnimationBake, any Error>?
    private var closingTask: Task<Void,Never>?
    private var bakeEndWaiters: [CheckedContinuation<Void,Never>] = []
    @ObservationIgnored private var particleSceneCache: (UUID,UInt64,PhysicsSimulationConfiguration)?
    private var generation: UInt64 = 0
    public let coordinator: SimulationCoordinator
    public let archive: SimulationArchiveStore
    public let workspace: SimulationWorkspaceStore
    public let meshing: SimulationMeshingService?

    public init(document: SimulationWorkspaceDocument, coordinator: SimulationCoordinator, archive: SimulationArchiveStore, workspace: SimulationWorkspaceStore? = nil, meshing: SimulationMeshingService? = nil) {
        self.document = document; self.coordinator = coordinator; self.archive = archive
        self.workspace = workspace ?? SimulationWorkspaceStore(document:document,archive:archive,coordinator:coordinator)
        self.meshing = meshing
        selectedStudyID = document.studies.first?.id
    }
    public var selectedStudy: SimulationStudy? { document.studies.first { $0.id == selectedStudyID } }
    public var meshSettings: SimulationMeshSettings {
        get { document.meshSettings ?? .init() }
        set { document.meshSettings = newValue; hasUnsavedChanges = true }
    }
    public func generateMesh() async {
        guard !isClosed, sourceAvailable else { return }
        if hasUnsavedChanges, !(await save()) { return }
        guard let study = selectedStudy, let meshing else { return }
        do { _ = try await meshing.start(studyID:study.id,source:document.source,expectedGeneration:generation,settings:meshSettings); errorDetails = nil }
        catch { errorDetails = error.localizedDescription }
    }
    public func cancelMesh(_ id: UUID) async { await meshing?.cancel(id) }
    @discardableResult public func refreshSource(_ source: SimulationSourceRef) async -> Bool {
        guard !isClosed else { return false }
        if hasUnsavedChanges, !(await save()) { return false }
        guard source != document.source else { sourceAvailable = true; return true }
        do {
            var candidate = document; candidate.source = source; candidate.meshes = []
            for index in candidate.studies.indices { candidate.studies[index].meshID = nil; try candidate.studies[index].touch() }
            let committed = try await workspace.commit(candidate,expectedGeneration:generation)
            document = committed.document; generation = committed.generation; hasUnsavedChanges = false; hasExternalChanges = false
            sourceAvailable = true; animationPose = nil; cancelBake(); result = nil; exportURL = nil; errorDetails = nil; return true
        } catch { errorDetails = error.localizedDescription; return false }
    }
    /// Called synchronously by the live CAD owner before awaiting a new snapshot.
    public func invalidateLiveSource() {
        sourceAvailable = false; result = nil; animationPose = nil; exportURL = nil; cancelBake()
        Task { await coordinator.cancelAll(); for job in await meshing?.snapshots() ?? [] where !job.status.isTerminal { await meshing?.cancel(job.id) } }
    }
    public var activeMesh: SimulationMesh? {
        if let meshID = selectedStudy?.meshID { return document.meshes.first { $0.id == meshID && $0.source == document.source } }
        return document.meshes.last { $0.source == document.source }
    }
    public func setSourceObjects(_ objects: [SimulationSourceObject]) {
        guard !isClosed, objects.count <= 256, Set(objects.map(\.id)).count == objects.count else { return }
        sourceObjects = objects
    }
    public var currentFrame: SimulationResultFrame? { result.flatMap { $0.frames.indices.contains(frameIndex) ? $0.frames[frameIndex] : $0.frames.first } }
    public var currentField: SimulationResultField? { currentFrame.flatMap { frame in frame.fields.first { $0.id == selectedFieldID } ?? frame.fields.first } }
    public var engineering: EngineeringSimulationConfiguration { (try? selectedStudy?.configuration(as:EngineeringSimulationConfiguration.self)) ?? .init() }
    public var physics: PhysicsSimulationConfiguration {
        guard let study = selectedStudy else { return .init() }
        if study.kind == .particles {
            if let cache = particleSceneCache, cache.0 == study.id, cache.1 == study.revision { return cache.2 }
            guard let configuration = try? particles.physicsConfiguration(budget:.init()) else { return .init() }
            particleSceneCache = (study.id,study.revision,configuration); return configuration
        }
        return (try? study.configuration(as:PhysicsSimulationConfiguration.self)) ?? .init()
    }
    public var flow: FlowSimulationConfiguration { (try? selectedStudy?.configuration(as:FlowSimulationConfiguration.self)) ?? .init() }
    public var acoustics: AcousticSimulationConfiguration { (try? selectedStudy?.configuration(as:AcousticSimulationConfiguration.self)) ?? .init() }
    public var electromagnetics: ElectromagneticSimulationConfiguration { (try? selectedStudy?.configuration(as:ElectromagneticSimulationConfiguration.self)) ?? .init() }
    public var particles: ParticleSimulationConfiguration { (try? selectedStudy?.configuration(as:ParticleSimulationConfiguration.self)) ?? .init() }
    public var coupling: CoupledSimulationConfiguration? { try? selectedStudy?.configuration(as:CoupledSimulationConfiguration.self) }
    public var animationGraph: SimulationAnimationGraph { document.animationGraphData.flatMap { try? JSONDecoder().decode(SimulationAnimationGraph.self,from:$0) } ?? .init(source:document.source) }
    public func writeAnimationGraph(_ graph: SimulationAnimationGraph) {
        do {
            guard graph.source == document.source else { throw SimulationError.staleSource }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; document.animationGraphData = try encoder.encode(graph); hasUnsavedChanges = true
        } catch { errorDetails = error.localizedDescription }
    }
    public func previewAnimation() {
        animationPreviewRevision &+= 1
        guard !isClosed, sourceAvailable else { animationPose = nil; return }
        do { let graph = animationGraph; guard graph.source == document.source else { throw SimulationError.staleSource }; animationPose = try SimulationAnimationEvaluator.evaluate(graph,timeSeconds:animationTimeSeconds,physics:graph.physicsResultID == nil ? nil : result); errorDetails = nil }
        catch { animationPose = nil; errorDetails = error.localizedDescription }
    }
    public func bakeAnimation() async {
        guard !baking, !isClosed, sourceAvailable else { return }; baking = true; bakeCancelling = false
        exportURL = nil; errorDetails = nil
        defer {
            baking = false; bakeTask = nil; bakeCancelling = false
            let waiting = bakeEndWaiters; bakeEndWaiters = []; for waiter in waiting { waiter.resume() }
        }
        if hasUnsavedChanges, !(await save()) { return }
        guard sourceAvailable, !isClosed else { return }
        let capturedGeneration = await workspace.snapshot().generation
        let graph = animationGraph, physics = graph.physicsResultID == nil ? nil : result
        do {
            let progress: SimulationProgressHandler = { [weak self] value in await self?.recordBakeProgress(value) }
            let task = Task.detached { try await SimulationAnimationBaker.bake(graph,physics:physics,progress:progress) }
            bakeTask = task
            let bake = try await task.value
            guard !isClosed, sourceAvailable, !bakeCancelling, document.source == graph.source, animationGraph == graph,
                  await workspace.snapshot().generation == capturedGeneration else { throw SimulationError.staleSource }
            let url = try await archive.saveAttachment(bake,id:UUID(),fileExtension:"animation.json")
            guard !isClosed, sourceAvailable, document.source == graph.source, animationGraph == graph,
                  await workspace.snapshot().generation == capturedGeneration else { throw SimulationError.staleSource }
            exportURL = url
        } catch is CancellationError { return } catch { errorDetails = error.localizedDescription }
    }
    public func cancelBake() { guard baking else { return }; bakeCancelling = true; bakeTask?.cancel() }
    private func recordBakeProgress(_ progress: SimulationProgress) { bakeProgress = progress }

    public func createStudy(_ kind: SimulationStudyKind) {
        var study = SimulationStudy(name:kind.simulationDisplayName,kind:kind)
        study.meshID = activeMesh?.id
        study.materialAssignments = Dictionary(uniqueKeysWithValues:(activeMesh.map { Set($0.elements.map(\.regionID)).sorted() } ?? []).compactMap { region in document.materials.first.map { (region,$0.id) } })
        do {
            try SimulationStudyDefaults.configure(&study)
            document.studies.append(study); selectedStudyID = study.id; result = nil; errorDetails = nil
            hasUnsavedChanges = true
        } catch { errorDetails = error.localizedDescription }
    }
    public func writeConfiguration<T: Encodable>(_ configuration: T) {
        guard let index = document.studies.firstIndex(where: { $0.id == selectedStudyID }) else { return }
        do {
            try document.studies[index].setConfiguration(configuration)
            hasUnsavedChanges = true
        } catch { errorDetails = error.localizedDescription }
    }
    public func renameStudy(_ name: String) {
        guard let index = document.studies.firstIndex(where: { $0.id == selectedStudyID }) else { return }
        do { try document.studies[index].touch(); document.studies[index].name = name; hasUnsavedChanges = true } catch { errorDetails = error.localizedDescription }
    }
    public func assignMaterial(_ materialID: UUID, regionID: String) {
        guard document.materials.contains(where: { $0.id == materialID }), let index = document.studies.firstIndex(where: { $0.id == selectedStudyID }) else { return }
        document.studies[index].materialAssignments[regionID] = materialID
        do { try document.studies[index].touch(); hasUnsavedChanges = true } catch { errorDetails = error.localizedDescription }
    }
    public func updateMaterial(_ material: SimulationMaterial) {
        if let index = document.materials.firstIndex(where: { $0.id == material.id }) { document.materials[index] = material }
        else { document.materials.append(material) }
        for index in document.studies.indices where document.usesMaterial(material.id,in:document.studies[index]) {
            do { try document.studies[index].touch(); hasUnsavedChanges = true } catch { errorDetails = error.localizedDescription }
        }
        hasUnsavedChanges = true
    }
    public func setMesh(_ mesh: SimulationMesh) throws {
        try mesh.validate(); guard mesh.source == document.source else { throw SimulationError.staleSource }
        document.meshes.removeAll { $0.id == mesh.id }; document.meshes.append(mesh)
        if let index = document.studies.firstIndex(where: { $0.id == selectedStudyID }) { document.studies[index].meshID = mesh.id }
        for index in document.studies.indices where document.studies[index].meshID == mesh.id { try document.studies[index].touch() }
        hasUnsavedChanges = true
    }
    public func observe() async {
        guard !isClosed else { return }
        do { try await workspace.activate() } catch { errorDetails = error.localizedDescription }
        await withTaskGroup(of:Void.self) { group in
            group.addTask { await self.observeJobs() }
            group.addTask { await self.observeWorkspace() }
            group.addTask { await self.observeMeshes() }
            await group.waitForAll()
        }
    }
    private func observeMeshes() async {
        guard let meshing else { return }
        for await values in await meshing.updates() {
            if Task.isCancelled { break }
            meshJobs = values
            if let failed = values.last(where:{ $0.status == .failed }) { errorDetails = failed.error }
        }
    }
    private func observeWorkspace() async {
        for await snapshot in await workspace.updates() {
            if Task.isCancelled { break }
            guard snapshot.generation != generation else { continue }
            if hasUnsavedChanges { if !saving { hasExternalChanges = true }; continue }
            document = snapshot.document; generation = snapshot.generation
            if !document.studies.contains(where:{ $0.id == selectedStudyID }) { selectedStudyID = document.studies.first?.id }
        }
    }
    private func observeJobs() async {
        let stream = await coordinator.updates()
        for await jobs in stream {
            if Task.isCancelled { break }
            self.jobs = jobs.filter { $0.source.projectID == document.source.projectID && $0.source.documentID == document.source.documentID }
            if let failed = self.jobs.last(where:{ $0.studyID == selectedStudyID && $0.status == .failed }) { errorDetails = failed.error }
            if let finished = self.jobs.last(where: { $0.studyID == selectedStudyID && $0.source == document.source && $0.status == .completed }), let id = finished.resultID, id != result?.id { await showResult(id,requireCurrent:true) }
        }
    }
    public func run() async {
        guard !isClosed, sourceAvailable else { return }
        if hasUnsavedChanges, !(await save()) { return }
        guard let study = selectedStudy else { return }
        do {
            errorDetails = nil
            _ = try await workspace.start(studyID:study.id,expectedStudyRevision:study.revision,expectedGeneration:generation)
        } catch { errorDetails = error.localizedDescription }
    }
    public func cancel(_ id: UUID) async { await coordinator.cancel(id) }
    @discardableResult public func save() async -> Bool {
        guard !saving, !isClosed else { return false }; saving = true; defer { saving = false }
        let candidate = document
        do {
            let committed = try await workspace.commit(candidate,expectedGeneration:generation)
            generation = committed.generation; hasUnsavedChanges = document != candidate; hasExternalChanges = false; errorDetails = nil; return true
        } catch { errorDetails = error.localizedDescription; return false }
    }
    public func reopen() async {
        do {
            let restored = try await archive.readDocument(), current = await workspace.snapshot()
            guard restored == current.document else { throw SimulationError.corruptArchive("The saved workspace changed outside its current session.") }
            document = restored; generation = current.generation; hasUnsavedChanges = false; hasExternalChanges = false; selectedStudyID = restored.studies.first?.id; result = nil; errorDetails = nil
        }
        catch { errorDetails = error.localizedDescription }
    }
    public func showResult(_ id: UUID, requireCurrent: Bool = false) async {
        let source = document.source, selection = selectedStudyID
        do {
            let value = try await coordinator.result(id)
            guard document.source == source, selectedStudyID == selection, value.studyID == selection else { return }
            if requireCurrent, value.source != document.source || value.studyRevision != selectedStudy?.revision { return }
            result = value; frameIndex = 0; probeIndex = 0; selectedFieldID = value.frames.first?.fields.first?.id
            if !document.resultIDs.contains(id) { document.resultIDs.append(id); hasUnsavedChanges = true }
            try await loadSavedResults()
        } catch { errorDetails = error.localizedDescription }
    }
    public func export() async {
        guard let result else { return }
        do { let url = try await archive.exportCSV(result); guard self.result?.id == result.id else { return }; exportURL = url } catch { errorDetails = error.localizedDescription }
    }
    public func clearError() { errorDetails = nil }
    public func close() async {
        if let closingTask { await closingTask.value; return }
        guard !isClosed else { return }
        isClosed = true; cancelBake()
        let task = Task { @MainActor in
            await workspace.close(); await coordinator.close(); await meshing?.close()
            for await values in await coordinator.updates() { if values.allSatisfy({ $0.status.isTerminal }) { break } }
            if let meshing { for await values in await meshing.updates() { if values.allSatisfy({ $0.status.isTerminal }) { break } } }
            if baking { await withCheckedContinuation { bakeEndWaiters.append($0) } }
        }
        closingTask = task; await task.value; closingTask = nil
    }
    public func loadSavedResults() async throws {
        savedResults = try await archive.savedResults().filter { $0.source.projectID == document.source.projectID && $0.source.documentID == document.source.documentID }
    }
    public func showSavedResult(_ summary: SimulationSavedResult) async {
        guard document.studies.contains(where:{ $0.id == summary.studyID }) else { return }
        selectedStudyID = summary.studyID; await showResult(summary.id)
    }
}

func simulationText(_ english: String, _ chinese: String) -> String { Locale.current.language.languageCode?.identifier == "zh" ? chinese : english }
public extension SimulationStudyKind {
    var simulationDisplayName: String {
        let words: (String,String) = switch self {
        case .rigidBody: ("Rigid bodies","刚体动力学")
        case .skeletalPhysics: ("Skeletal physics","骨骼物理")
        case .cloth: ("Cloth","布料")
        case .rope: ("Rope","绳索")
        case .softBody: ("Soft bodies","软体")
        case .particles: ("Particles","粒子与力场")
        case .structuralStatic: ("Static structure","结构静力")
        case .beamShell: ("Beams and shells","梁与壳")
        case .laminate: ("Laminated composites","铺层复材")
        case .modal: ("Modal analysis","模态")
        case .buckling: ("Buckling","屈曲")
        case .nonlinearContact: ("Nonlinear contact","非线性与接触")
        case .thermalSteady: ("Steady heat","稳态热")
        case .thermalTransient: ("Transient heat","瞬态热")
        case .thermalStress: ("Thermal stress","热应力")
        case .incompressibleFlow: ("Incompressible flow","不可压缩流")
        case .compressibleFlow: ("Compressible flow","可压缩流")
        case .turbulentFlow: ("Turbulent flow","湍流")
        case .conjugateHeatTransfer: ("Conjugate heat transfer","共轭传热")
        case .fluidStructure: ("Fluid–structure interaction","流固耦合")
        case .pressureAcoustics: ("Pressure acoustics","压力声学")
        case .structuralAcoustics: ("Structural acoustics","结构声学")
        case .electrostatic: ("Electrostatics","静电")
        case .magnetostatic: ("Magnetostatics","静磁")
        case .eddyCurrent: ("Eddy currents","涡流")
        case .radioFrequency: ("Radio frequency","射频")
        case .electromagneticModes: ("EM modes","电磁模态")
        case .antenna: ("Antenna","天线")
        }
        return simulationText(words.0,words.1)
    }
}
