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

public struct SimulationAnimationExportRequest:Sendable {
    public var format:SimulationAnimationExportFormat
    public var graph:SimulationAnimationGraph
    public var bake:SimulationAnimationBake
    public var physics:SimulationResult?
    public var physicsConfiguration:PhysicsSimulationConfiguration
    public var outputURL:URL
    public var progress:SimulationProgressHandler
}
public typealias SimulationAnimationExportHandler = @Sendable (SimulationAnimationExportRequest) async throws -> Void

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
    public private(set) var sourceMeshes: [SimulationSourceMesh] = []
    public private(set) var sourceAnimationGraph:SimulationAnimationGraph?
    public private(set) var sourceAnimationMessage:String?
    public internal(set) var preparingSourceMesh = false
    @ObservationIgnored var sourceMeshTask: Task<SimulationPhysicsMesh,any Error>?
    @ObservationIgnored var sourceBindingTask: Task<SimulationAnimationMeshBinding,any Error>?
    public private(set) var animationPreviewRevision: UInt64 = 0
    public var displaysAnimation = false
    public var animationTimeSeconds = 0.0
    public private(set) var animationPose: SimulationAnimationPose?
    public private(set) var baking = false
    public private(set) var bakeProgress: SimulationProgress?
    public private(set) var bakeCancelling = false
    public var animationExportFormat:SimulationAnimationExportFormat = .motionJSON
    public var animationFramesPerSecond = 30
    public private(set) var savedAnimationExports:[SimulationSavedAnimationExport] = []
    @ObservationIgnored public var animationExportHandler:SimulationAnimationExportHandler?
    public var availableAnimationExportFormats:[SimulationAnimationExportFormat] { animationExportHandler == nil ? [.motionJSON]:SimulationAnimationExportFormat.allCases }
    private var bakeTask: Task<SimulationAnimationBake, any Error>?
    private var animationExportTask:Task<Void,any Error>?
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
        sourceMeshTask?.cancel(); sourceBindingTask?.cancel()
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
    public func setSourceMeshes(_ meshes:[SimulationSourceMesh]) {
        guard !isClosed, meshes.count <= 256 else { return }; sourceMeshes = meshes
    }
    public func setSourceAnimationGraph(_ graph:SimulationAnimationGraph?,message:String? = nil) {
        guard !isClosed, graph == nil || graph?.source == document.source else { return }
        sourceAnimationGraph = graph; sourceAnimationMessage = message
    }
    public func importSourceAnimation() {
        guard let graph = sourceAnimationGraph, graph.source == document.source else { return }
        writeAnimationGraph(graph); clearError()
    }
    func recordSourceError(_ error:any Error) { errorDetails = error.localizedDescription }
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
    public func bakeAnimation(format:SimulationAnimationExportFormat = .motionJSON,framesPerSecond:Int = 30) async {
        guard !baking, !isClosed, sourceAvailable else { return }; baking = true; bakeCancelling = false
        exportURL = nil; errorDetails = nil
        defer {
            baking = false; bakeTask = nil; animationExportTask = nil; bakeCancelling = false
            let waiting = bakeEndWaiters; bakeEndWaiters = []; for waiter in waiting { waiter.resume() }
        }
        guard (1...240).contains(framesPerSecond), format != .mp4 || framesPerSecond <= 60 else { errorDetails = simulationText("Choose a valid frame rate (video: up to 60 fps).","选择有效帧率，视频最高支持 60 fps。"); return }
        if hasUnsavedChanges, !(await save()) { return }
        guard sourceAvailable, !isClosed else { return }
        let capturedGeneration = await workspace.snapshot().generation
        let graph = animationGraph, physics = graph.physicsResultID == nil ? nil : result
        let physicsConfiguration = self.physics
        let attachmentID = UUID()
        do {
            let progress: SimulationProgressHandler = { [weak self] value in await self?.recordBakeProgress(value) }
            let task = Task.detached { try await SimulationAnimationBaker.bake(graph,physics:physics,framesPerSecond:framesPerSecond,progress:progress) }
            bakeTask = task
            let bake = try await task.value
            guard !isClosed, sourceAvailable, !bakeCancelling, document.source == graph.source, animationGraph == graph,
                  await workspace.snapshot().generation == capturedGeneration else { throw SimulationError.staleSource }
            let staged = try await archive.beginAnimationExport(id:attachmentID,format:format)
            if format == .motionJSON {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(bake)
                guard data.count <= 256_000_000 else { throw SimulationError.resourceLimit("Reduce the animation export size.") }
                try data.write(to:staged,options:.atomic)
            } else {
                guard let handler = animationExportHandler else { throw SimulationError.backendUnavailable("The host has not connected this animation export format.") }
                let request = SimulationAnimationExportRequest(format:format,graph:graph,bake:bake,physics:physics,physicsConfiguration:physicsConfiguration,outputURL:staged,progress:progress)
                let exporter = Task { try await handler(request) }; animationExportTask = exporter
                try await withTaskCancellationHandler { try await exporter.value } onCancel: { exporter.cancel() }
            }
            guard !isClosed, sourceAvailable, !bakeCancelling, document.source == graph.source, animationGraph == graph,
                  await workspace.snapshot().generation == capturedGeneration else { throw SimulationError.staleSource }
            let frameCount = format == .mp4 ? Int(ceil(graph.durationSeconds*Double(framesPerSecond))):bake.frames.count
            let record = try await archive.commitAnimationExport(id:attachmentID,format:format,source:graph.source,graphSHA256:bake.graphSHA256,physicsResultID:bake.physicsResultID,framesPerSecond:framesPerSecond,frameCount:frameCount,durationSeconds:graph.durationSeconds)
            guard !isClosed, sourceAvailable, document.source == graph.source, animationGraph == graph,
                  await workspace.snapshot().generation == capturedGeneration else { throw SimulationError.staleSource }
            exportURL = try await archive.animationExportURL(id:record.id,source:document.source)
            savedAnimationExports = try await archive.savedAnimationExports(source:document.source)
        } catch is CancellationError { /* The service still drains and removes its staging below. */ }
        catch { errorDetails = error.localizedDescription }
        try? await archive.discardAnimationExport(id:attachmentID)
    }
    public func cancelBake() { guard baking else { return }; bakeCancelling = true; bakeTask?.cancel(); animationExportTask?.cancel() }
    private func recordBakeProgress(_ progress: SimulationProgress) { bakeProgress = progress }
    public func shareAnimationExport(_ id:UUID) async {
        do { exportURL = try await archive.animationExportURL(id:id,source:document.source); errorDetails = nil }
        catch { errorDetails = error.localizedDescription }
    }
    public func attachCurrentPhysicsCache() {
        guard let result, result.source == document.source,
              ["floe.rapier","floe.particles"].contains(result.backend.id), let duration = result.frames.last?.timeSeconds else { return }
        var graph = animationGraph
        guard graph.durationSeconds.isFinite,graph.durationSeconds>0,duration.isFinite,duration>0 else { return }
        do { try graph.fitDuration(to:duration) }
        catch { recordSourceError(error); return }
        graph.physicsResultID = result.id
        animationTimeSeconds = min(animationTimeSeconds,duration)
        let ids = (result.diagnostics["bodyIDs"] ?? "").split(separator:",").compactMap { UUID(uuidString:String($0)) }
        graph.physicsBindings.removeAll { !ids.contains($0.bodyID) }
        let sources = result.diagnostics["bodySourceObjectIDs"].flatMap { try? JSONDecoder().decode([String].self,from:Data($0.utf8)) }
        for (index,id) in ids.enumerated() {
            let target = sources.flatMap { $0.indices.contains(index) ? $0[index]:nil } ?? id.uuidString.lowercased()
            if !graph.physicsBindings.contains(where: { $0.targetID == target || $0.bodyID == id }) { graph.physicsBindings.append(.init(targetID:target,bodyID:id)) }
        }
        writeAnimationGraph(graph)
    }

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
        isClosed = true; cancelBake(); sourceMeshTask?.cancel(); sourceBindingTask?.cancel()
        let task = Task { @MainActor in
            await workspace.close(); await coordinator.close(); await meshing?.close()
            for await values in await coordinator.updates() { if values.allSatisfy({ $0.status.isTerminal }) { break } }
            if let meshing { for await values in await meshing.updates() { if values.allSatisfy({ $0.status.isTerminal }) { break } } }
            if baking { await withCheckedContinuation { bakeEndWaiters.append($0) } }
            _ = try? await sourceMeshTask?.value; _ = try? await sourceBindingTask?.value
        }
        closingTask = task; await task.value; closingTask = nil
    }
    public func loadSavedResults() async throws {
        savedResults = try await archive.savedResults().filter { $0.source.projectID == document.source.projectID && $0.source.documentID == document.source.documentID }
        savedAnimationExports = try await archive.savedAnimationExports(source:document.source)
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
