import Foundation
import FloeSimulationCore
import FloeSimulationGeometry

/// The CAD host captures the current immutable representation. AI input supplies
/// settings, never a substitute geometry snapshot or an arbitrary host path.
public typealias SimulationGeometryProvider = @Sendable (SimulationSourceRef) async throws -> SimulationGeometrySnapshot

public struct SimulationMeshJobSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var source: SimulationSourceRef
    public var studyID: UUID
    public var settings: SimulationMeshSettings
    public var status: SimulationJobStatus
    public var progress: SimulationProgress
    public var meshID: UUID?
    public var error: String?
}

/// A mesh continues independently of the view that requested it. A save uses
/// the same generation comparison as UI and AI edits, so an old native result
/// cannot replace a newer workspace.
public actor SimulationMeshingService {
    public nonisolated let isAvailable: Bool
    private let workspace: SimulationWorkspaceStore
    private let mesher: NativeSimulationMesher
    private let geometry: SimulationGeometryProvider
    private var activeID: UUID?
    private var committing = false
    private var closed = false
    private var worker: Task<Void,Never>?
    private var sourceObserver: Task<Void,Never>?
    private var stale = Set<UUID>()
    private var jobs: [SimulationMeshJobSnapshot] = []
    private var observers: [UUID:AsyncStream<[SimulationMeshJobSnapshot]>.Continuation] = [:]

    public init(workspace: SimulationWorkspaceStore, mesher: NativeSimulationMesher, geometry: @escaping SimulationGeometryProvider) {
        self.workspace = workspace; self.mesher = mesher; self.geometry = geometry; isAvailable = mesher.isAvailable
    }
    public func snapshots() -> [SimulationMeshJobSnapshot] { jobs }
    public func updates() -> AsyncStream<[SimulationMeshJobSnapshot]> {
        let id = UUID()
        return AsyncStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            if closed, jobs.allSatisfy({ $0.status.isTerminal }) { continuation.yield(jobs); continuation.finish(); return }
            observers[id] = continuation; continuation.yield(jobs)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    @discardableResult public func start(studyID: UUID, source: SimulationSourceRef, expectedGeneration: UInt64, settings: SimulationMeshSettings, budget: SimulationBudget = .init()) async throws -> UUID {
        try source.validate(); try settings.validate(); try budget.validate()
        guard isAvailable else { throw SimulationError.backendUnavailable("The native mesher is unavailable.") }
        guard !closed else { throw SimulationError.invalidInput("The simulation workspace is closed.") }
        guard activeID == nil else { throw SimulationError.invalidInput("Wait for the current mesh to finish.") }
        let id = UUID(); activeID = id
        do {
            let snapshot = await workspace.snapshot()
            try await workspace.requireOpen()
            guard !closed, snapshot.generation == expectedGeneration, snapshot.document.source == source,
                  snapshot.document.studies.contains(where:{ $0.id == studyID }) else { throw SimulationError.staleSource }
            if jobs.count >= 32 { jobs.removeFirst(jobs.count-31) }
            jobs.append(.init(id:id,source:source,studyID:studyID,settings:settings,status:.running,progress:.init(stage:"preparing"))); publish()
            let mesher = self.mesher, geometry = self.geometry, workspace = self.workspace
            sourceObserver = Task { [weak self] in
                for await current in await workspace.updates() {
                    if Task.isCancelled { break }
                    if current.generation != expectedGeneration || current.document.source != source { await self?.invalidate(id); break }
                }
            }
            let owner = self
            worker = Task.detached {
                do {
                    let captured = try await geometry(source)
                    guard captured.source == source else { throw SimulationError.staleSource }
                    try Task.checkCancellation()
                    let mesh = try await mesher.mesh(captured,settings:settings,budget:budget) { value in await owner.record(value,id:id) }
                    try Task.checkCancellation()
                    await owner.finish(id,mesh:mesh,expectedGeneration:expectedGeneration,failure:nil)
                } catch { await owner.finish(id,mesh:nil,expectedGeneration:expectedGeneration,failure:error) }
            }
            return id
        } catch { activeID = nil; throw error }
    }
    public func cancel(_ id: UUID) {
        guard activeID == id, !committing else { return }
        update(id) { $0.status = .cancelling }; worker?.cancel(); publish()
    }
    public func close() { closed = true; if let activeID { cancel(activeID) }; publish() }
    private func invalidate(_ id: UUID) {
        guard activeID == id, !committing else { return }
        stale.insert(id); cancel(id)
    }
    private func finish(_ id: UUID, mesh: SimulationMesh?, expectedGeneration: UInt64, failure: (any Error)?) async {
        guard activeID == id, let job = jobs.first(where:{ $0.id == id }) else { return }
        sourceObserver?.cancel(); sourceObserver = nil
        defer { stale.remove(id); activeID = nil; worker = nil; committing = false; publish() }
        if stale.contains(id) || (failure as? SimulationError) == .staleSource { update(id) { $0.status = .stale }; return }
        if job.status == .cancelling || failure is CancellationError || (failure as? SimulationError) == .cancelled { update(id) { $0.status = .cancelled }; return }
        if let failure { update(id) { $0.status = .failed; $0.error = failure.localizedDescription }; return }
        guard let mesh else { update(id) { $0.status = .failed; $0.error = "The native mesher returned no mesh." }; return }
        committing = true; update(id) { $0.progress = .init(stage:"saving") }; publish()
        do {
            var snapshot = await workspace.snapshot()
            guard snapshot.generation == expectedGeneration, snapshot.document.source == job.source,
                  let study = snapshot.document.studies.firstIndex(where:{ $0.id == job.studyID }) else { throw SimulationError.staleSource }
            snapshot.document.meshes.removeAll { $0.id == mesh.id }; snapshot.document.meshes.append(mesh)
            snapshot.document.studies[study].meshID = mesh.id
            snapshot.document.meshSettings = job.settings
            for index in snapshot.document.studies.indices where snapshot.document.studies[index].meshID == mesh.id { try snapshot.document.studies[index].touch() }
            _ = try await workspace.commit(snapshot.document,expectedGeneration:expectedGeneration)
            update(id) { $0.meshID = mesh.id; $0.status = .completed; $0.progress = .init(stage:"complete",completed:1,total:1) }
        } catch SimulationError.staleSource { update(id) { $0.status = .stale } }
        catch { update(id) { $0.status = .failed; $0.error = error.localizedDescription } }
    }
    private func record(_ value: SimulationProgress, id: UUID) { guard activeID == id else { return }; update(id) { $0.progress = value }; publish() }
    private func update(_ id: UUID, _ body: (inout SimulationMeshJobSnapshot) -> Void) { if let index = jobs.firstIndex(where:{ $0.id == id }) { body(&jobs[index]) } }
    private func publish() {
        for observer in observers.values { observer.yield(jobs) }
        if closed, jobs.allSatisfy({ $0.status.isTerminal }) { for observer in observers.values { observer.finish() }; observers.removeAll() }
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey:id) }
}
