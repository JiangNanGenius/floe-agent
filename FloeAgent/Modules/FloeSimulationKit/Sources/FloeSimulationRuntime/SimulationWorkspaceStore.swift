import Foundation
import FloeSimulationCore

public struct SimulationWorkspaceSnapshot: Codable, Equatable, Sendable {
    public var document: SimulationWorkspaceDocument
    public var generation: UInt64
}

/// One committed workspace is shared by UI and Studio tools. UI drafts commit
/// with a generation comparison, so an AI edit cannot silently overwrite them.
public actor SimulationWorkspaceStore {
    private var document: SimulationWorkspaceDocument
    private var generation: UInt64 = 0
    private var writing = false
    private var closed = false
    private var idleWaiters: [CheckedContinuation<Void,Never>] = []
    private let archive: SimulationArchiveStore
    private let coordinator: SimulationCoordinator
    private var observers: [UUID:AsyncStream<SimulationWorkspaceSnapshot>.Continuation] = [:]
    public init(document: SimulationWorkspaceDocument, archive: SimulationArchiveStore, coordinator: SimulationCoordinator) {
        self.document = document; self.archive = archive; self.coordinator = coordinator
    }
    public func snapshot() -> SimulationWorkspaceSnapshot { .init(document:document,generation:generation) }
    public func requireOpen() throws { guard !closed else { throw SimulationError.invalidInput("Reopen this simulation workspace before using it.") } }
    public func close() async {
        closed = true
        if writing { await withCheckedContinuation { idleWaiters.append($0) } }
        for observer in observers.values { observer.finish() }; observers.removeAll()
    }
    private func finishWriting() {
        writing = false
        let waiting = idleWaiters; idleWaiters = []; for continuation in waiting { continuation.resume() }
    }
    public func activate() async throws {
        try requireOpen()
        guard !writing else { throw SimulationError.invalidInput("A workspace save is in progress.") }
        writing = true; defer { finishWriting() }
        try await coordinator.setCurrentSource(document.source)
        for study in document.studies { await coordinator.invalidateStudy(study.id,source:document.source,revision:study.revision) }
    }
    public func start(studyID: UUID, expectedStudyRevision: UInt64, expectedGeneration: UInt64, backendID: String? = nil, budget: SimulationBudget = .init()) async throws -> UUID {
        try requireOpen()
        guard !writing, expectedGeneration == generation,
              let study = document.studies.first(where:{ $0.id == studyID }), study.revision == expectedStudyRevision else { throw SimulationError.staleSource }
        writing = true; defer { finishWriting() }
        let mesh = study.meshID.flatMap { id in document.meshes.first { $0.id == id } }
        try await coordinator.setCurrentSource(document.source)
        return try await coordinator.start(.init(source:document.source,study:study,mesh:mesh,materials:document.materials,budget:budget),backendID:backendID)
    }
    public func updates() -> AsyncStream<SimulationWorkspaceSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            if closed { continuation.yield(snapshot()); continuation.finish(); return }
            observers[id] = continuation; continuation.yield(snapshot())
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    @discardableResult public func commit(_ candidate: SimulationWorkspaceDocument, expectedGeneration: UInt64) async throws -> SimulationWorkspaceSnapshot {
        try requireOpen()
        guard !writing else { throw SimulationError.invalidInput("A workspace save is in progress. Retry after it completes.") }
        guard expectedGeneration == generation, generation < UInt64.max else { throw SimulationError.staleSource }
        guard candidate.source.projectID == document.source.projectID, candidate.source.documentID == document.source.documentID else { throw SimulationError.staleSource }
        let previous = document
        guard candidate.source.revision >= previous.source.revision,
              candidate.source.revision != previous.source.revision || candidate.source == previous.source else { throw SimulationError.staleSource }
        for study in candidate.studies {
            if let old = previous.studies.first(where:{ $0.id == study.id }), old != study {
                guard study.revision > old.revision else { throw SimulationError.invalidInput("An edited study must advance its revision.") }
            }
            if let old = previous.studies.first(where:{ $0.id == study.id }), candidate.source == previous.source {
                let meshChanged = old.meshID.map { id in previous.meshes.first { $0.id == id } != candidate.meshes.first { $0.id == id } } ?? false
                let materialChanged = previous.materials.contains { material in
                    previous.usesMaterial(material.id,in:old) && candidate.materials.first { $0.id == material.id } != material
                }
                if meshChanged || materialChanged {
                    guard study.revision > old.revision else { throw SimulationError.invalidInput("Changing a shared mesh or material must advance every affected study.") }
                }
            }
        }
        writing = true; defer { finishWriting() }
        try await archive.saveDocument(candidate)
        document = candidate; generation += 1
        try await coordinator.setCurrentSource(candidate.source)
        for study in candidate.studies { await coordinator.invalidateStudy(study.id,source:candidate.source,revision:study.revision) }
        for removed in previous.studies where !candidate.studies.contains(where:{ $0.id == removed.id }) { await coordinator.invalidateStudy(removed.id,source:previous.source,revision:UInt64.max) }
        let value = snapshot(); for observer in observers.values { observer.yield(value) }; return value
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey:id) }
}

public extension SimulationWorkspaceDocument {
    func usesMaterial(_ materialID: UUID, in study: SimulationStudy) -> Bool {
        var pending = Array(study.materialAssignments.values), visited = Set<UUID>()
        while let id = pending.popLast() {
            if id == materialID { return true }
            guard visited.insert(id).inserted else { continue }
            pending.append(contentsOf:materials.first { $0.id == id }?.layers.map(\.materialID) ?? [])
        }
        return false
    }
}
