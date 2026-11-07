// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation

nonisolated struct PersonalContentPreviewKey: Hashable, Sendable {
    let ownerID: String
    let objectID: String
    let revision: String
    let variant: String
    let maximumPixelSize: Int

    init(ownerID: String, objectID: String, revision: String, variant: String = "content", maximumPixelSize: Int = 640) {
        self.ownerID = ownerID; self.objectID = objectID; self.revision = revision; self.variant = variant
        self.maximumPixelSize = min(1_024, max(64, maximumPixelSize))
    }
}

nonisolated enum PersonalContentPreviewError: Error, Equatable {
    case unavailable, notPrepared, unsupported, sourceChanged, tooLarge, queueFull, timedOut
}

nonisolated struct PersonalContentPreviewArtifact: Sendable {
    enum Provenance: String, Sendable {
        case originalImage, videoFrame, audioWaveform, readableText, pdfPage
        case officePage, officeContentSummary, notePage, savedCADViewport, chemicalDrawing, spectrum, moduleSnapshot
    }
    struct Waveform: Sendable {
        struct Channel: Sendable { let minimum: [Double]; let maximum: [Double] }
        let channels: [Channel]
        let durationSeconds: Double
        let startSeconds: Double
        let endSeconds: Double
    }
    enum Content: Sendable { case image(Data), text(String), waveform(Waveform) }
    let content: Content
    let provenance: Provenance
    /// A real subset (first page, selected frame or measured audio window), never a claim of complete content.
    let detail: String?

    init(_ content: Content, provenance: Provenance, detail: String? = nil) {
        self.content = content; self.provenance = provenance; self.detail = detail
    }
    var byteCost: Int {
        switch content {
        case .image(let bytes): bytes.count
        case .text(let text): text.utf8.count
        case .waveform(let value): value.channels.reduce(0) { $0 + ($1.minimum.count + $1.maximum.count) * MemoryLayout<Double>.size }
        }
    }
}

/// Native presentation input, not a tool permission or a model-authored path.
/// The owner retains its existing document/resource lease while the producer
/// runs. Validation is required on cache hits as well as before/after a render.
@MainActor struct PersonalContentPreviewRequest {
    let key: PersonalContentPreviewKey
    let validate: @MainActor @Sendable () async throws -> Void
    let produce: @MainActor @Sendable () async throws -> PersonalContentPreviewArtifact
}

/// Shared by Files, recent works and editor material rows. No disk cache,
/// editor session, analysis/calculation, original write or global selection.
@MainActor final class PersonalContentPreviewService {
    static let shared = PersonalContentPreviewService()
    private struct CacheEntry { let value: PersonalContentPreviewArtifact; var visit: UInt64 }
    private final class Flight {
        let id = UUID()
        let request: PersonalContentPreviewRequest
        var waiters: [UUID: CheckedContinuation<PersonalContentPreviewArtifact, Error>] = [:]
        var worker: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        init(_ request: PersonalContentPreviewRequest) { self.request = request }
    }
    private let maximumBytes: Int
    private let maximumEntries: Int
    private let maximumWorkers: Int
    private let maximumQueued: Int
    private let deadline: Duration
    private var cache: [PersonalContentPreviewKey: CacheEntry] = [:]
    private var flights: [PersonalContentPreviewKey: Flight] = [:]
    private var queue: [PersonalContentPreviewKey] = []
    private var running = 0
    private var visit: UInt64 = 0

    init(maximumBytes: Int = 16 * 1_024 * 1_024, maximumEntries: Int = 64,
         maximumWorkers: Int = 2, maximumQueued: Int = 32, deadline: Duration = .seconds(15)) {
        self.maximumBytes = max(1, maximumBytes); self.maximumEntries = max(1, maximumEntries)
        self.maximumWorkers = max(1, min(2, maximumWorkers)); self.maximumQueued = max(0, min(64, maximumQueued))
        self.deadline = deadline
    }

    func preview(_ request: PersonalContentPreviewRequest) async throws -> PersonalContentPreviewArtifact {
        try Task.checkCancellation()
        try await request.validate()
        try Task.checkCancellation()
        if var hit = cache[request.key] {
            visit &+= 1; hit.visit = visit; cache[request.key] = hit
            return hit.value
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if let flight = flights[request.key] {
                    // An abandoned/expired worker still owns a native slot;
                    // do not attach a new request to its late result.
                    guard !flight.waiters.isEmpty else { continuation.resume(throwing: PersonalContentPreviewError.queueFull); return }
                    flight.waiters[waiterID] = continuation
                } else {
                    guard queue.count < maximumQueued || running < maximumWorkers else {
                        continuation.resume(throwing: PersonalContentPreviewError.queueFull); return
                    }
                    let flight = Flight(request); flight.waiters[waiterID] = continuation
                    flights[request.key] = flight; queue.append(request.key)
                    flight.deadline = Task { [weak self, flight, deadline] in
                        do { try await Task.sleep(for: deadline) } catch { return }
                        guard let self, self.flights[request.key]?.id == flight.id else { return }
                        self.abandon(key: request.key, flight: flight, error: PersonalContentPreviewError.timedOut)
                    }
                    drain()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(key: request.key, waiterID: waiterID) }
        }
    }

    func invalidate(ownerID: String) {
        cache = cache.filter { $0.key.ownerID != ownerID }
        for key in Array(flights.keys) where key.ownerID == ownerID {
            if let flight = flights[key] { abandon(key: key, flight: flight, error: PersonalContentPreviewError.sourceChanged) }
        }
    }
    func removeCachedPreviews() { cache.removeAll() }
    var cachedByteCount: Int { cache.values.reduce(0) { $0 + $1.value.byteCost } }
    var cachedEntryCount: Int { cache.count }

    private func drain() {
        while running < maximumWorkers, !queue.isEmpty {
            let key = queue.removeFirst()
            guard let flight = flights[key], !flight.waiters.isEmpty else { continue }
            running += 1
            flight.worker = Task { [weak self, flight] in
                let result: Result<PersonalContentPreviewArtifact, Error>
                do {
                    try Task.checkCancellation(); try await flight.request.validate()
                    let value = try await flight.request.produce()
                    try Task.checkCancellation(); try await flight.request.validate(); try Task.checkCancellation()
                    guard value.byteCost > 0, value.byteCost <= 8 * 1_024 * 1_024 else { throw PersonalContentPreviewError.tooLarge }
                    result = .success(value)
                } catch { result = .failure(error) }
                self?.complete(key: key, id: flight.id, result: result)
            }
        }
    }
    private func cancel(key: PersonalContentPreviewKey, waiterID: UUID) {
        guard let flight = flights[key], let waiter = flight.waiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(throwing: CancellationError())
        if flight.waiters.isEmpty { abandon(key: key, flight: flight, error: CancellationError()) }
    }
    private func abandon(key: PersonalContentPreviewKey, flight: Flight, error: Error) {
        let waiters = flight.waiters; flight.waiters.removeAll()
        for waiter in waiters.values { waiter.resume(throwing: error) }
        flight.deadline?.cancel(); flight.deadline = nil
        if let worker = flight.worker {
            // Keep capacity and ownership until the native producer actually
            // finishes, even if its backend ignores cooperative cancellation.
            worker.cancel()
        } else { flights.removeValue(forKey: key); queue.removeAll { $0 == key }; drain() }
    }
    private func complete(key: PersonalContentPreviewKey, id: UUID, result: Result<PersonalContentPreviewArtifact, Error>) {
        guard let flight = flights[key], flight.id == id else { return }
        flight.deadline?.cancel()
        flights.removeValue(forKey: key); running -= 1
        let waiters = flight.waiters; flight.waiters.removeAll()
        if !waiters.isEmpty, case .success(let value) = result {
            // Superseded revisions of this same object do not accumulate.
            cache = cache.filter { $0.key.ownerID != key.ownerID || $0.key.objectID != key.objectID || $0.key == key }
            visit &+= 1; cache[key] = .init(value: value, visit: visit)
            while cache.count > maximumEntries || cachedByteCount > maximumBytes {
                guard let oldest = cache.min(by: { $0.value.visit < $1.value.visit })?.key else { break }
                cache.removeValue(forKey: oldest)
            }
        }
        for waiter in waiters.values { waiter.resume(with: result) }
        drain()
    }
}
#endif
