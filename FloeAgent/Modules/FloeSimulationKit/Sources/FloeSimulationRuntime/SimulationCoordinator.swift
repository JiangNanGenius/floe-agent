import Foundation
import FloeSimulationCore

public enum SimulationJobStatus: String, Codable, Sendable {
    case queued, running, cancelling, cancelled, completed, failed, stale, interrupted
    public var isTerminal: Bool { ![Self.queued, .running, .cancelling].contains(self) }
}

public struct SimulationJobSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var source: SimulationSourceRef
    public var studyID: UUID
    public var backendID: String
    public var status: SimulationJobStatus
    public var progress: SimulationProgress
    public var resultID: UUID?
    public var error: String?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var createdAt = Date()
}

/// Owns workers independently of views. Cancelling does not release the queue
/// until the underlying worker has actually returned.
public actor SimulationCoordinator {
    private var backends: [String: any SimulationBackend] = [:]
    private var jobs: [UUID: SimulationJobSnapshot] = [:]
    private var requests: [UUID: SimulationRequest] = [:]
    private var results: [UUID: SimulationResult] = [:]
    private var currentSources: [String: SimulationSourceRef] = [:]
    private var studyRevisions: [String: UInt64] = [:]
    private var invalidatedJobs = Set<UUID>()
    private var queue: [UUID] = []
    private var runningID: UUID?
    private var worker: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<[SimulationJobSnapshot]>.Continuation] = [:]
    private let archive: SimulationArchiveStore?
    private let validateSource: SimulationSourceValidator?
    private var closed = false

    public init(backends: [any SimulationBackend] = [], archive: SimulationArchiveStore? = nil, validateSource: SimulationSourceValidator? = nil) {
        for backend in backends { self.backends[backend.descriptor.id] = backend }
        self.archive = archive
        self.validateSource = validateSource
    }

    public func register(_ backend: any SimulationBackend) throws {
        guard !closed else { throw SimulationError.invalidInput("The simulation workspace is closed.") }
        guard runningID == nil, queue.isEmpty else { throw SimulationError.invalidInput("Wait for active simulations before changing backends.") }
        backends[backend.descriptor.id] = backend
    }

    public func capabilities() -> [SimulationBackendDescriptor] { backends.values.map(\.descriptor).sorted { $0.id < $1.id } }
    public func snapshots() -> [SimulationJobSnapshot] { jobs.values.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt } }
    public func result(_ id: UUID) async throws -> SimulationResult {
        if let result = results[id] { return result }
        guard let archive else { throw SimulationError.invalidInput("The result is unavailable.") }
        return try await archive.readResult(id)
    }

    public func updates() -> AsyncStream<[SimulationJobSnapshot]> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            if closed, jobs.values.allSatisfy({ $0.status.isTerminal }) { continuation.yield(snapshots()); continuation.finish(); return }
            observers[id] = continuation; continuation.yield(snapshots())
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }

    public func setCurrentSource(_ source: SimulationSourceRef) throws {
        guard !closed else { throw SimulationError.invalidInput("The simulation workspace is closed.") }
        try source.validate()
        let key = sourceKey(source)
        if let previous = currentSources[key] {
            guard source.revision >= previous.revision,
                  source.revision != previous.revision || source == previous else { throw SimulationError.staleSource }
        }
        if currentSources[key] != source { studyRevisions = studyRevisions.filter { !$0.key.hasPrefix(key+"/") } }
        currentSources[key] = source
        for id in Array(queue) where requests[id].map({ sourceKey($0.source) == key && $0.source != source }) ?? false {
            queue.removeAll { $0 == id }; jobs[id]?.status = .stale; jobs[id]?.finishedAt = Date(); requests.removeValue(forKey: id)
        }
        if let runningID, let request = requests[runningID], sourceKey(request.source) == key, request.source != source {
            jobs[runningID]?.status = .cancelling; worker?.cancel()
        }
        publish()
    }

    public func invalidateStudy(_ studyID: UUID, source: SimulationSourceRef, revision: UInt64) {
        guard currentSources[sourceKey(source)] == nil || currentSources[sourceKey(source)] == source else { return }
        let key = sourceKey(source)+"/"+studyID.uuidString
        studyRevisions[key] = max(revision,studyRevisions[key] ?? 0)
        for id in Array(queue) {
            guard let request = requests[id], request.source == source, request.study.id == studyID, request.study.revision < revision else { continue }
            queue.removeAll { $0 == id }; jobs[id]?.status = .stale; jobs[id]?.finishedAt = Date(); requests.removeValue(forKey:id)
        }
        if let runningID, let request = requests[runningID], request.source == source, request.study.id == studyID, request.study.revision < revision {
            invalidatedJobs.insert(runningID); jobs[runningID]?.status = .cancelling; worker?.cancel()
        }
        publish()
    }

    @discardableResult public func start(_ request: SimulationRequest, backendID: String? = nil) throws -> UUID {
        guard !closed else { throw SimulationError.invalidInput("The simulation workspace is closed.") }
        try request.validate()
        guard jobs[request.id] == nil else { throw SimulationError.invalidInput("This run identity has already been used.") }
        if let current = currentSources[sourceKey(request.source)], current != request.source { throw SimulationError.staleSource }
        let studyKey = sourceKey(request.source)+"/"+request.study.id.uuidString
        guard request.study.revision >= studyRevisions[studyKey,default:0] else { throw SimulationError.staleSource }
        let candidates = backends.values.filter { $0.descriptor.isAvailable && $0.descriptor.supportedStudies.contains(request.study.kind) }.sorted { $0.descriptor.id < $1.descriptor.id }
        let backend: any SimulationBackend
        if let backendID {
            guard let selected = backends[backendID] else { throw SimulationError.backendUnavailable(backendID) }; backend = selected
        } else {
            var compatible: (any SimulationBackend)?
            var unsupported: (any Error)?
            for candidate in candidates {
                do { try candidate.validate(request); compatible = candidate; break }
                catch let failure as SimulationError {
                    switch failure {
                    case .unsupported, .backendUnavailable: unsupported = failure
                    default: throw failure
                    }
                }
            }
            guard let compatible else { throw unsupported ?? SimulationError.backendUnavailable("No installed backend supports these study settings.") }
            backend = compatible
        }
        try backend.validate(request)
        invalidateStudy(request.study.id,source:request.source,revision:request.study.revision)
        if jobs.count >= 256 {
            let removable = snapshots().filter { $0.status.isTerminal }.prefix(jobs.count-255)
            for job in removable { jobs.removeValue(forKey:job.id) }
            guard jobs.count < 256 else { throw SimulationError.resourceLimit("The simulation queue is full.") }
        }
        currentSources[sourceKey(request.source)] = request.source
        requests[request.id] = request
        jobs[request.id] = .init(id: request.id, source: request.source, studyID: request.study.id, backendID: backend.descriptor.id, status: .queued, progress: .init(stage: "queued"))
        queue.append(request.id); publish(); launchNext()
        return request.id
    }

    public func cancel(_ id: UUID) {
        guard let job = jobs[id], !job.status.isTerminal else { return }
        if runningID == id { jobs[id]?.status = .cancelling; worker?.cancel() }
        else { queue.removeAll { $0 == id }; requests.removeValue(forKey: id); jobs[id]?.status = .cancelled; jobs[id]?.finishedAt = Date() }
        publish()
    }

    public func cancelAll() { for id in jobs.keys { cancel(id) } }
    public func close() { closed = true; cancelAll(); publish() }

    private func sourceKey(_ source: SimulationSourceRef) -> String { source.projectID.uuidString + "/" + source.documentID.uuidString }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func publish() {
        let values = snapshots(); for observer in observers.values { observer.yield(values) }
        if closed, values.allSatisfy({ $0.status.isTerminal }) { for observer in observers.values { observer.finish() }; observers.removeAll() }
    }

    private func launchNext() {
        guard runningID == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        guard let request = requests[id], let backendID = jobs[id]?.backendID, let backend = backends[backendID] else { launchNext(); return }
        runningID = id; jobs[id]?.status = .running; jobs[id]?.startedAt = Date(); publish()
        let coordinator = self, validateSource = self.validateSource
        worker = Task.detached {
            do {
                try Task.checkCancellation()
                try await validateSource?(request.source)
                let result = try await backend.solve(request) { progress in await coordinator.recordProgress(progress, id: id) }
                try Task.checkCancellation()
                try result.validate(for: request)
                await coordinator.finish(id, result: result, failure: nil)
            } catch { await coordinator.finish(id, result: nil, failure: error) }
        }
    }

    private func recordProgress(_ progress: SimulationProgress, id: UUID) {
        guard runningID == id, jobs[id]?.status == .running else { return }
        jobs[id]?.progress = progress; publish()
    }

    private func finish(_ id: UUID, result: SimulationResult?, failure: (any Error)?) async {
        guard runningID == id, let request = requests[id] else { return }
        let stale = currentSources[sourceKey(request.source)] != request.source || invalidatedJobs.contains(id)
        let cancelled = jobs[id]?.status == .cancelling || failure is CancellationError || (failure as? SimulationError) == .cancelled
        if stale || (failure as? SimulationError) == .staleSource { jobs[id]?.status = .stale }
        else if cancelled { jobs[id]?.status = .cancelled }
        else if let failure { jobs[id]?.status = .failed; jobs[id]?.error = failure.localizedDescription }
        else if let result {
            do {
                try await validateSource?(request.source)
                if let archive { try await archive.saveResult(result, request: request) }
                try await validateSource?(request.source)
                // The actor may have received a source change or cancellation while saving.
                if currentSources[sourceKey(request.source)] != request.source || invalidatedJobs.contains(id) { jobs[id]?.status = .stale }
                else if jobs[id]?.status == .cancelling { jobs[id]?.status = .cancelled }
                else {
                    if archive != nil, results.count >= 2, let oldest = snapshots().compactMap(\.resultID).first(where:{ results[$0] != nil }) { results.removeValue(forKey:oldest) }
                    results[result.id] = result; jobs[id]?.resultID = result.id; jobs[id]?.status = .completed
                }
            } catch SimulationError.staleSource { jobs[id]?.status = .stale }
            catch { jobs[id]?.status = .failed; jobs[id]?.error = error.localizedDescription }
        } else { jobs[id]?.status = .failed; jobs[id]?.error = "The backend returned no result." }
        jobs[id]?.finishedAt = Date(); requests.removeValue(forKey: id)
        invalidatedJobs.remove(id)
        runningID = nil; worker = nil; publish(); launchNext()
    }
}
