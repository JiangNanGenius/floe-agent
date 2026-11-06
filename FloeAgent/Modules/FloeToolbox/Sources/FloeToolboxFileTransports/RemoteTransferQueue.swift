import Foundation
import FloeToolboxCore
import FloeToolboxRemoteFiles

public enum TransferQueuePhase: String,Codable,Sendable { case queued,running,cancelling,completed,cancelled,conflict,failed,needsReview }
public struct RemoteTransferRequest: Codable,Equatable,Sendable {
    public let sourceMachine: MachineReference
    public let destinationMachine: MachineReference
    public let source: RemoteFilePath
    public let destination: RemoteFilePath
    public let conflict: RemoteTransferConflictPolicy
    public init(sourceMachine: MachineReference,destinationMachine: MachineReference,source: RemoteFilePath,destination: RemoteFilePath,conflict: RemoteTransferConflictPolicy = .failIfExists) {
        self.sourceMachine = sourceMachine; self.destinationMachine = destinationMachine; self.source = source; self.destination = destination; self.conflict = conflict
    }
}
public struct TransferQueueEntry: Codable,Equatable,Sendable,Identifiable {
    public let id: UUID
    public let request: RemoteTransferRequest
    public var phase: TransferQueuePhase
    public var transfer: RemoteTransferSnapshot?
    public var resumeCheckpoint: RemoteTransferCheckpoint?
    public var attempt: UUID
}
public struct TransferQueueState: Codable,Sendable {
    public let ownerID: UUID
    public var revision: UInt64
    public var entries: [TransferQueueEntry]
    public init(ownerID: UUID,revision: UInt64 = 0,entries: [TransferQueueEntry] = []) { self.ownerID = ownerID; self.revision = revision; self.entries = entries }
}
/// The App implements this on its existing job/database transaction owner. Implementations
/// must atomically compare revision and save; failures never grant authority to run a job.
public protocol TransferQueueRepository: Sendable {
    func load(ownerID: UUID) async throws -> TransferQueueState?
    func save(_ state: TransferQueueState,expectedRevision: UInt64) async throws
}
public struct TransferSessionPair: Sendable {
    public let source: RemoteFileSession; public let destination: RemoteFileSession
    public init(source: RemoteFileSession,destination: RemoteFileSession) { self.source = source; self.destination = destination }
}
public typealias TransferSessionResolver = @Sendable (UUID,RemoteTransferRequest) async throws -> TransferSessionPair

/// A single, bounded queue owned by the host's job service. No credentials or remote
/// connection body is persisted. Interrupted temporary machines require host resolution.
public actor RemoteTransferQueue {
    public nonisolated let ownerID: UUID
    private let repository: any TransferQueueRepository
    private let resolve: TransferSessionResolver
    private var state: TransferQueueState
    private var saving = false, closed = false
    private var storeWaiters: [CheckedContinuation<Void,Never>] = []
    private var worker: Task<Void,Never>?
    private var runningID: UUID?
    private var lastProgressSave: ContinuousClock.Instant = .now
    public init(ownerID: UUID,repository: any TransferQueueRepository,resolve: @escaping TransferSessionResolver) {
        self.ownerID = ownerID; self.repository = repository; self.resolve = resolve; state = TransferQueueState(ownerID:ownerID)
    }
    public func restore() async throws {
        guard worker == nil, !saving, state.entries.isEmpty else { throw RemoteFileError.busy }
        saving = true; defer { saving = false; let waiting = storeWaiters; storeWaiters.removeAll(); waiting.forEach { $0.resume() } }
        guard var saved = try await repository.load(ownerID:ownerID) else { return }
        guard saved.ownerID == ownerID, saved.entries.count <= 128, Set(saved.entries.map(\.id)).count == saved.entries.count else { throw RemoteFileError.malformedResponse }
        for index in saved.entries.indices {
            _ = try saved.entries[index].request.source.validated(); _ = try saved.entries[index].request.destination.validated()
            if [.running,.cancelling].contains(saved.entries[index].phase) { saved.entries[index].phase = .needsReview }
        }
        state = saved // Recovery does not automatically reconnect or replay a write.
    }
    public func snapshot() -> TransferQueueState { state }
    private func persist(_ candidate: TransferQueueState) async throws {
        guard !saving, !closed, state.revision < UInt64.max else { throw RemoteFileError.busy }
        saving = true; defer { saving = false; let waiting = storeWaiters; storeWaiters.removeAll(); waiting.forEach { $0.resume() } }
        let expected = state.revision; var next = candidate; next.revision = expected+1
        guard next.ownerID == ownerID, next.entries.count <= 128 else { throw RemoteFileError.limit }
        try await repository.save(next,expectedRevision:expected)
        guard !closed else { throw RemoteFileError.staleSession }; state = next
    }
    @discardableResult public func enqueue(_ request: RemoteTransferRequest) async throws -> UUID {
        guard !closed, !saving, state.entries.count < 128 else { throw RemoteFileError.busy }
        _ = try request.source.validated(); _ = try request.destination.validated()
        guard request.sourceMachine != request.destinationMachine || request.source != request.destination else { throw RemoteFileError.conflict }
        var next = state; let id = UUID()
        next.entries.append(TransferQueueEntry(id:id,request:request,phase:.queued,transfer:nil,resumeCheckpoint:nil,attempt:UUID()))
        try await persist(next); kick(); return id
    }
    public func start() { if !closed { kick() } }
    private func kick() {
        guard worker == nil, !closed, state.entries.contains(where:{$0.phase == .queued}) else { return }
        worker = Task { await self.runNext() }
    }
    private func runNext() async {
        defer { runningID = nil; worker = nil; if !closed { kick() } }
        guard !closed, let entry = state.entries.first(where:{$0.phase == .queued}) else { return }
        do {
            var next = state; guard let index = next.entries.firstIndex(where:{$0.id == entry.id}) else { return }
            next.entries[index].phase = .running; try await persist(next); runningID = entry.id
            try Task.checkCancellation()
            let sessions = try await resolve(ownerID,entry.request)
            guard sessions.source.lease.ownerID == ownerID, sessions.destination.lease.ownerID == ownerID,
                  sessions.source.machine == entry.request.sourceMachine, sessions.destination.machine == entry.request.destinationMachine else { throw RemoteFileError.staleSession }
            try Task.checkCancellation()
            let transfer = RemoteFileTransfer(id:entry.resumeCheckpoint?.id ?? UUID())
            let result: RemoteTransferSnapshot
            do {
                result = try await transfer.copy(source:sessions.source,path:entry.request.source,destination:sessions.destination,to:entry.request.destination,
                    conflict:entry.request.conflict,resume:entry.resumeCheckpoint,observer:{ [weak self] snapshot in await self?.progress(entry.id,attempt:entry.attempt,snapshot:snapshot) })
                await finish(entry.id,attempt:entry.attempt,phase:.completed,transfer:result)
            } catch {
                let actual = await transfer.snapshot
                let phase: TransferQueuePhase
                if [.completed,.completedAfterInvalidation].contains(actual.phase) { phase = .completed }
                else if actual.phase == .needsReview { phase = .needsReview }
                else if error is CancellationError || actual.phase == .cancelled { phase = .cancelled }
                else if case RemoteFileError.conflict = error { phase = .conflict }
                else { phase = .failed }
                await finish(entry.id,attempt:entry.attempt,phase:phase,transfer:actual)
            }
        } catch { await finish(entry.id,attempt:entry.attempt,phase:error is CancellationError ? .cancelled : .failed,transfer:nil) }
    }
    private func progress(_ id: UUID,attempt: UUID,snapshot: RemoteTransferSnapshot) async {
        guard !closed, !saving, let index = state.entries.firstIndex(where:{$0.id == id && $0.attempt == attempt}) else { return }
        var next = state; next.entries[index].transfer = snapshot
        // Keep current progress in RAM; durable checkpoints use the host repository. A stale
        // checkpoint is verified by RemoteFileTransfer before any subsequent resume.
        let terminal = [.completed,.completedAfterInvalidation,.cancelled,.failed,.needsReview].contains(snapshot.phase)
        if terminal || snapshot.phase != state.entries[index].transfer?.phase || lastProgressSave.duration(to:.now) >= .seconds(1) {
            do { try await persist(next); lastProgressSave = .now } catch { worker?.cancel() }
        } else { state = next }
    }
    private func finish(_ id: UUID,attempt: UUID,phase: TransferQueuePhase,transfer: RemoteTransferSnapshot?) async {
        if saving { await withCheckedContinuation { storeWaiters.append($0) } }
        guard !closed, let index = state.entries.firstIndex(where:{$0.id == id && $0.attempt == attempt}) else { return }
        var next = state; next.entries[index].phase = phase; if let transfer { next.entries[index].transfer = transfer }
        do { try await persist(next) }
        catch { next.entries[index].phase = phase == .completed ? .completed : .needsReview; state = next; closed = true }
    }
    public func cancel(_ id: UUID) async throws {
        if runningID == id { worker?.cancel(); return }
        guard !saving, let index = state.entries.firstIndex(where:{$0.id == id}) else { throw RemoteFileError.busy }
        guard state.entries[index].phase == .queued else { return }
        var next = state; next.entries[index].phase = .cancelled; try await persist(next)
    }
    public func retry(_ id: UUID,resume: Bool) async throws {
        guard !saving, let index = state.entries.firstIndex(where:{$0.id == id}), [.failed,.cancelled,.conflict,.needsReview].contains(state.entries[index].phase) else { throw RemoteFileError.busy }
        var next = state; let checkpoint = resume ? next.entries[index].transfer?.checkpoint : nil
        if resume, checkpoint == nil { throw RemoteFileError.unsupported }
        next.entries[index].resumeCheckpoint = checkpoint; next.entries[index].attempt = UUID(); next.entries[index].phase = .queued
        try await persist(next); kick()
    }
    public func close() { closed = true; worker?.cancel(); let waiting = storeWaiters; storeWaiters.removeAll(); waiting.forEach { $0.resume() } }
}
