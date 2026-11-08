// SPDX-License-Identifier: MPL-2.0
//
// Service-owned Android policy cache for the signed GitHub transport mirror
// list (CONTRACT_V1). Ported VERBATIM in behaviour from the reviewed iOS
// main source
//   FloeAgent/Sources/FloeSkills/GitHubTransportMirrorManifest.swift
//     (GitHubTransportMirrorPolicyStore, main @ 2ce48570a, fixed git object).
//
// The store — not any view or task — owns the atomic last-good record and
// the monotonic generation floor. A stale/invalid/expired refresh can never
// replace the accepted state, cannot roll the floor back, and a
// same-generation refresh with different bytes is refused. One in-flight
// refresh at a time; normal use may re-attempt after six hours; discovery
// (bootstrap) uses compiled routes only and never this store, so a
// downloaded policy cannot recursively bootstrap. Storage is a single
// atomic JSON commit; a corrupt/unreadable record is PRESERVED on disk and
// degrades to bundled defaults without resetting a potentially higher
// persisted floor.
import Foundation
import FloeSkills

/// App-owned policy cache. It outlives individual downloads/views; rejected
/// refreshes never modify the last verified record or the generation floor.
public actor AndroidHubMirrorPolicyStore {
    public struct Downloaded: Sendable {
        public let payload: Data
        public let signature: Data
        public init(payload: Data, signature: Data) { self.payload = payload; self.signature = signature }
    }
    public struct Snapshot: Sendable {
        public let roles: AndroidHubMirrorRoles
        public let generation: Int64?
        public let highestGeneration: Int64
        public let usesBundledDefaults: Bool
        public let diagnostic: AndroidHubMirrorManifestFailure?
    }
    private struct Record: Codable {
        let schemaVersion: Int
        let highestGeneration: Int64
        let payload: Data
        let signature: Data
    }
    private struct Flight: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }
    private let persistenceURL: URL?
    private let trustMode: CuratedSkillTrustMode
    private let clock: @Sendable () -> Date
    private var loaded = false
    private var persistenceBlocked = false
    private var highestGeneration: Int64 = 0
    private var verified: AndroidHubTransportMirrorManifest.Verified?
    private var lastAttempt: Date?
    private var diagnostic: AndroidHubMirrorManifestFailure?
    private var flight: Flight?

    public init(persistenceURL: URL?, mode: CuratedSkillTrustMode = .production,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.persistenceURL = persistenceURL; self.trustMode = mode; self.clock = clock
    }

    public func snapshot() -> Snapshot {
        loadOnce()
        let now = clock()
        if let verified, verified.expiry > now, verified.issued.timeIntervalSince(now) <= 300 {
            return Snapshot(roles: verified.manifest.roles, generation: verified.manifest.generation,
                            highestGeneration: highestGeneration, usesBundledDefaults: false,
                            diagnostic: diagnostic)
        }
        return Snapshot(roles: .bundled, generation: nil, highestGeneration: highestGeneration,
                        usesBundledDefaults: true, diagnostic: diagnostic)
    }

    /// Nonblocking normal-use refresh; discovery must use compiled routes,
    /// never this store, so a downloaded policy cannot recursively bootstrap.
    public func policyRefreshingIfNeeded(
        download: @escaping @Sendable () async throws -> Downloaded
    ) -> Snapshot {
        let current = snapshot()
        let now = clock()
        if flight == nil, lastAttempt == nil || now.timeIntervalSince(lastAttempt!) >= 6 * 3_600
            || lastAttempt!.timeIntervalSince(now) > 300 {
            lastAttempt = now
            let id = UUID()
            let task = Task { [weak self] in
                do {
                    let bytes = try await download()
                    try Task.checkCancellation()
                    await self?.finish(id: id, bytes: bytes)
                } catch {
                    await self?.fail(id: id, failure: error is CancellationError ? .cancelled : .unavailable)
                }
            }
            flight = Flight(id: id, task: task)
        }
        return current
    }

    public func cancelRefresh() async {
        guard let current = flight else { return }
        current.task.cancel()
        await current.task.value
        if flight?.id == current.id { flight = nil }
    }

    deinit { flight?.task.cancel() }

    // Internal qualification hook; production reads do not wait on refresh.
    func waitForRefresh() async { await flight?.task.value }

    private func loadOnce() {
        guard !loaded else { return }; loaded = true
        guard let persistenceURL else { persistenceBlocked = true; diagnostic = .storage; return }
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        do {
            guard (try persistenceURL.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw AndroidHubMirrorManifestFailure.storage
            }
            let handle = try FileHandle(forReadingFrom: persistenceURL)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 65_537) ?? Data()
            guard data.count <= 65_536 else { throw AndroidHubMirrorManifestFailure.storage }
            let record = try JSONDecoder().decode(Record.self, from: data)
            guard record.schemaVersion == 1 else { throw AndroidHubMirrorManifestFailure.storage }
            let item = try AndroidHubTransportMirrorManifest.verify(payload: record.payload,
                signature: record.signature, now: clock(), mode: trustMode, allowExpiredHistory: true)
            guard record.highestGeneration == item.manifest.generation else {
                throw AndroidHubMirrorManifestFailure.storage
            }
            highestGeneration = record.highestGeneration; verified = item
        } catch {
            // Preserve a corrupt/unreadable record rather than silently
            // resetting a potentially higher persisted floor.
            persistenceBlocked = true; diagnostic = .storage
        }
    }

    private func finish(id: UUID, bytes: Downloaded) {
        guard flight?.id == id else { return }
        defer { flight = nil }
        guard !Task.isCancelled else { diagnostic = .cancelled; return }
        do {
            let item = try AndroidHubTransportMirrorManifest.verify(payload: bytes.payload,
                signature: bytes.signature, now: clock(), mode: trustMode)
            guard item.manifest.generation >= highestGeneration else { throw AndroidHubMirrorManifestFailure.rollback }
            if item.manifest.generation == highestGeneration {
                guard let verified, verified.payload == bytes.payload else {
                    throw AndroidHubMirrorManifestFailure.generationReused
                }
                diagnostic = nil; return // byte-identical refresh is a no-op
            }
            guard !persistenceBlocked, let persistenceURL else { throw AndroidHubMirrorManifestFailure.storage }
            let record = Record(schemaVersion: 1, highestGeneration: item.manifest.generation,
                                payload: bytes.payload, signature: bytes.signature)
            do {
                try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try JSONEncoder().encode(record).write(to: persistenceURL, options: .atomic)
            } catch {
                persistenceBlocked = true
                throw AndroidHubMirrorManifestFailure.storage
            }
            // No suspension between durable commit and publishing the new
            // floor/LKG. Cancellation cannot interleave a half-adoption.
            highestGeneration = item.manifest.generation; verified = item; diagnostic = nil
        } catch {
            diagnostic = (error as? AndroidHubMirrorManifestFailure) ?? .storage
        }
    }

    private func fail(id: UUID, failure: AndroidHubMirrorManifestFailure) {
        guard flight?.id == id else { return }
        flight = nil; diagnostic = failure
    }
}
