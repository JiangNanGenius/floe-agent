// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeAgentRuntime

/// App-owned daemon. Indexed content never supplies access, grants or an execution target.
actor GlobalSourceMemoryService {
    private let index: GlobalSourceIndexStore
    private let memories: SQLiteIntelligenceStore
    private let candidates: MemoryCandidatePipeline
    private let providers: [String: any GlobalSourceProvider]
    private let embedding: (any MemoryEmbeddingProvider)?
    private let summary: (any GlobalSourceSummaryGenerator)?
    private let maintenance: GlobalMemoryNaturalMaintenance?
    private let localTextFallback: (any GlobalSourceSummaryGenerator)?
    private var worker: Task<Void, Never>?
    private var pass: Task<Void, Never>?
    private var lastPass: Date?
    private var stopped = true
    private var prepared = false
    private func prepareIfNeeded() async throws { if !prepared { try await index.prepare(); prepared = true } }
    init(index: GlobalSourceIndexStore, memories: SQLiteIntelligenceStore, candidates: MemoryCandidatePipeline,
         providers: [any GlobalSourceProvider], embedding: (any MemoryEmbeddingProvider)?,
         summary: (any GlobalSourceSummaryGenerator)?, maintenance: GlobalMemoryNaturalMaintenance? = nil, localTextFallback: (any GlobalSourceSummaryGenerator)? = nil) {
        self.index = index; self.memories = memories; self.candidates = candidates
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.embedding = embedding; self.summary = summary; self.maintenance = maintenance; self.localTextFallback = localTextFallback
    }
    func start() async throws {
        try await prepareIfNeeded()
        guard worker == nil else { return }; stopped = false
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !(await self.stopped) else { return }
                await self.runPass()
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
    }
    /// Native mutation hooks coalesce into one pass; editors never await indexing or a model.
    func changed() {
        guard !stopped, pass == nil else { return }
        pass = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            await self?.runPass(); await self?.clearPendingPass()
        }
    }
    private func clearPendingPass() { pass = nil }
    func stop() { stopped = true; worker?.cancel(); pass?.cancel(); worker = nil; pass = nil }
    func runBackgroundPass() async { if stopped { try? await start() }; await runPass() }
    func sourceRemoved(_ sourceID: String) async throws { try await index.removeSource(sourceID); changed() }
    func exclude(_ sourceID: String, excluded: Bool) async throws { try await index.exclude(sourceID, excluded: excluded); changed() }
    func controls(paused: Bool, localTextFallback: Bool) async throws { try await index.setControls(paused: paused, localText: localTextFallback); if !paused { changed() } }
    func status() async throws -> GlobalSourceStatus {
        try await prepareIfNeeded()
        var value = try await index.status(); value.lastPass = lastPass
        value.semanticModel = embedding.map { $0.modelIdentifier + " · " + $0.modelRevision }
        #if canImport(NaturalLanguage)
        if let local = embedding as? AppleLocalSemanticEmbeddingProvider { value.semanticChinese = local.supportsChinese }
        #endif
        return value
    }
    private var runningPass = false
    private func runPass() async {
        guard !runningPass, !stopped else { return }; runningPass = true; defer { runningPass = false }
        do {
            let control = try await index.controls(); guard !control.paused else { return }
            for provider in providers.values {
                try Task.checkCancellation()
                let token = UUID().uuidString
                var cursor: String?, pages = 0
                var unavailableOwners = Set<String>()
                do {
                    repeat {
                        let page = try await provider.inventory(cursor: cursor, limit: 64)
                        unavailableOwners.formUnion(page.unavailableOwners)
                        for descriptor in page.sources {
                            guard descriptor.providerID == provider.id, !descriptor.id.isEmpty, !descriptor.ownerID.isEmpty else { continue }
                            if try await index.isExcluded(descriptor.id) { _ = try await index.touch(descriptor, token: token); continue }
                            let changed = try await index.touch(descriptor, token: token)
                            let reembed: Bool
                            if let embedding { reembed = try await index.needsVectors(sourceID: descriptor.id, model: embedding.modelIdentifier, revision: embedding.modelRevision) }
                            else { reembed = false }
                            guard changed || reembed else { continue }
                            do {
                                let snapshot = try await provider.read(descriptor)
                                guard snapshot.source.id == descriptor.id, snapshot.source.revision == descriptor.revision, snapshot.source.ownerID == descriptor.ownerID else { throw GlobalSourceJobError.sourceChanged }
                                var chunks = GlobalSourceTextPolicy.chunks(snapshot)
                                if let embedding {
                                    for i in chunks.indices {
                                        try Task.checkCancellation()
                                        if let vector = try? await embedding.embedding(for: chunks[i].text), !vector.isEmpty {
                                            chunks[i].vector = vector; chunks[i].vectorModel = embedding.modelIdentifier; chunks[i].vectorRevision = embedding.modelRevision
                                        }
                                    }
                                }
                                try await index.replace(snapshot, chunks: chunks, seenToken: token, queueSummary: changed)
                            } catch { try? await index.removeSource(descriptor.id) }
                        }
                        cursor = page.nextCursor; pages += 1
                        guard pages < 10_000 else { throw GlobalSourceJobError.unavailable }
                        await Task.yield()
                    } while cursor != nil
                    // A failed/incomplete inventory never implies that unseen sources were deleted.
                    try await index.markMissing(provider: provider.id, seenToken: token, unavailableOwners: unavailableOwners)
                } catch { continue }
            }
            await refreshMemoryVectors()
            await processSummaryJobs(localEnabled: control.localText)
            try await memories.maintainMemoryLifecycle()
            lastPass = Date()
            try? await maintenance?.run()
        } catch { /* Retry through the durable queue; no raw text or credentials enter logs. */ }
    }
    private func refreshMemoryVectors() async {
        guard let embedding else { return }
        do {
            var cursor: String?
            repeat {
                let page = try await memories.listMemories(.init(status: .active, cursor: cursor, limit: 100))
                for memory in page.entries {
                    try Task.checkCancellation()
                    let digest = MemoryContentDigest.make(memory.content)
                    if try await memories.embeddingNeedsRefresh(memoryID: memory.id, modality: .text, modelIdentifier: embedding.modelIdentifier, modelRevision: embedding.modelRevision, contentDigest: digest),
                       let vector = try? await embedding.embedding(for: memory.content) {
                        try await memories.saveEmbedding(.init(memoryID: memory.id, modality: .text, modelIdentifier: embedding.modelIdentifier, modelRevision: embedding.modelRevision, values: vector, contentDigest: digest))
                    }
                }
                cursor = page.nextCursor
            } while cursor != nil
        } catch { /* Index preparation is not user recall and never reinforces a memory. */ }
    }
    /// Read the actual memory store, not the derived source index. Lifecycle
    /// maintenance keeps pin, owner retention and expiry policy authoritative;
    /// all canonical scopes admitted by hybrid recall remain candidates.
    private func activeMemoryCorpusIsEmpty(now: Date) async throws -> Bool {
        try await memories.maintainMemoryLifecycle(now: now)
        var cursor: String?
        repeat {
            try Task.checkCancellation()
            let page = try await memories.listMemories(.init(status: .active, cursor: cursor, limit: 100))
            if page.entries.contains(where: { $0.expiresAt.map { $0 > now } ?? true }) { return false }
            // An expired pinned row may remain active. Finish every real page
            // before concluding that no unexpired candidate remains.
            cursor = page.nextCursor
        } while cursor != nil
        return true
    }
    func recallMemories(_ query: String, context: GlobalSourceSearchContext) async throws -> [HybridMemoryRecallItem] {
        let now = Date()
        if embedding != nil, try await activeMemoryCorpusIsEmpty(now: now) { return [] }
        let vector = try? await embedding?.embedding(for: query)
        return try await memories.hybridRecall(.init(query: query, workspaceID: context.workspaceID, conversationID: context.conversationID,
            queryEmbedding: vector ?? nil, modelIdentifier: embedding?.modelIdentifier, modelRevision: embedding?.modelRevision, limit: context.limit), now: now)
    }
    func browseMemories(_ query: String, context: GlobalSourceSearchContext) async throws -> [HybridMemoryRecallItem] {
        let now = Date()
        if embedding != nil, try await activeMemoryCorpusIsEmpty(now: now) { return [] }
        let vector = try? await embedding?.embedding(for: query)
        return try await memories.browseMemories(.init(query: query, workspaceID: context.workspaceID,
            conversationID: context.conversationID, queryEmbedding: vector ?? nil,
            modelIdentifier: embedding?.modelIdentifier, modelRevision: embedding?.modelRevision, limit: context.limit), now: now)
    }
    func recordMemoryUse(_ ids: [UUID], runID: UUID) async { await memories.recordMemoryUse(ids, runID: runID) }
    func readSource(_ id: String, offset: Int = 0, limit: Int = 4_000) async throws -> GlobalSourceHit {
        try await prepareIfNeeded()
        guard offset >= 0, let descriptor = try await index.source(id), !(try await index.isExcluded(id)), let provider = providers[descriptor.providerID] else { throw GlobalSourceJobError.unavailable }
        let snapshot = try await provider.read(descriptor)
        let body = Array(GlobalSourceTextPolicy.safeText(snapshot.text))
        guard offset <= body.count else { throw GlobalSourceJobError.unavailable }
        return .init(id: id + ":\(offset)", source: snapshot.source, excerpt: String(body[offset..<min(body.count, offset + min(8_000, max(1, limit)))]), offset: offset, score: 1, semantic: false, sourceAvailable: true)
    }
    private func processSummaryJobs(localEnabled: Bool) async {
        guard let jobs = try? await index.jobs(limit: 4) else { return }
        for (descriptor, revision) in jobs {
            do {
                try Task.checkCancellation()
                guard descriptor.revision == revision, let provider = providers[descriptor.providerID], !(try await index.isExcluded(descriptor.id)) else { throw GlobalSourceJobError.excluded }
                let snapshot = try await provider.read(descriptor)
                guard snapshot.source.revision == revision, snapshot.source.availability == .available else { throw GlobalSourceJobError.unavailable }
                let prior = try await memories.listMemories(.init(status: .active, limit: 100)).entries
                let result: GlobalSourceSummaryResult
                if let summary {
                    do { result = try await summary.summarize(snapshot, prior: prior) }
                    catch GlobalSourceJobError.textModelUnavailable {
                        guard localEnabled, let localTextFallback else { throw GlobalSourceJobError.textModelUnavailable }
                        result = try await localTextFallback.summarize(snapshot, prior: prior)
                    }
                } else {
                    guard localEnabled, let localTextFallback else { throw GlobalSourceJobError.textModelUnavailable }
                    result = try await localTextFallback.summarize(snapshot, prior: prior)
                }
                // Re-read native ownership/revision after the model finishes. Imported/model text grants nothing.
                guard try await provider.read(descriptor).source.revision == revision else { throw GlobalSourceJobError.sourceChanged }
                for proposed in result.candidates.prefix(3) {
                    guard !proposed.quote.isEmpty, snapshot.text.contains(proposed.quote), proposed.quote.count <= 512,
                          !proposed.content.isEmpty, !(try await index.suppressed(proposed.content)), !(try await index.suppressed(proposed.quote)) else { continue }
                    let normalized = GlobalSourceIndexStore.suppressionDigest(proposed.content)
                    let candidateID = GlobalSourceTextPolicy.memoryID(source: descriptor.id, content: proposed.content)
                    if let existing = try await memories.memory(id: candidateID), existing.status == .active {
                        try await index.link(memoryID: existing.id, source: descriptor, quote: proposed.quote); continue
                    }
                    if prior.contains(where: { GlobalSourceIndexStore.suppressionDigest($0.content) == normalized }) { continue }
                    let sourceEvidence = MemorySourceEvidence(sourceID: descriptor.id, revision: revision, ownerID: descriptor.ownerID, locator: descriptor.locator)
                    let evidence = MemoryEvidenceReference(messageID: descriptor.messageID, excerpt: proposed.quote, source: sourceEvidence)
                    let candidate = MemoryCandidate(id: candidateID, scope: .agentGlobal, content: proposed.content,
                        confidence: proposed.confidence, stability: proposed.stability, importance: proposed.importance,
                        sensitivity: proposed.sensitivity, origin: .automaticTurnReview, evidence: [evidence],
                        originConversationID: descriptor.conversationID, originWorkspaceID: descriptor.workspaceID)
                    try await index.link(memoryID: candidate.id, source: descriptor, quote: proposed.quote)
                    _ = try await candidates.submit(candidate, modelDisposition: .activate)
                }
                try await index.finishJob(descriptor, success: true)
            } catch GlobalSourceJobError.textModelUnavailable { try? await index.finishJob(descriptor, success: false, missingModel: true) }
            catch { try? await index.finishJob(descriptor, success: false) }
        }
    }
    func search(_ query: String, context: GlobalSourceSearchContext) async throws -> [GlobalSourceHit] {
        try await prepareIfNeeded()
        let query = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8_000))
        guard !query.isEmpty else { return [] }
        let lexical = try await index.lexical(query)
        var ranked: [String: (GlobalSourceDescriptor, GlobalSourceChunk, Double, Bool)] = [:]
        for (rank, value) in lexical.enumerated() { ranked[value.1.id] = (value.0, value.1, 1 / Double(60 + rank + 1), false) }
        if let embedding {
            let candidates = try await index.semanticCandidates(model: embedding.modelIdentifier, revision: embedding.modelRevision)
            if !candidates.isEmpty, let vector = try? await embedding.embedding(for: query) {
                let ordered = candidates.compactMap { source, chunk -> (GlobalSourceDescriptor, GlobalSourceChunk, Double)? in
                    guard let stored = chunk.vector, let similarity = MemoryVectorMath.cosineSimilarity(vector, stored), similarity > 0.2 else { return nil }
                    return (source, chunk, similarity)
                }.sorted { $0.2 > $1.2 }.prefix(80)
                for (rank, value) in ordered.enumerated() {
                    let previous = ranked[value.1.id]
                    ranked[value.1.id] = (value.0, value.1, (previous?.2 ?? 0) + 1 / Double(60 + rank + 1), true)
                }
            }
        }
        let ordered = ranked.values.sorted { lhs, rhs in
            func score(_ value: (GlobalSourceDescriptor, GlobalSourceChunk, Double, Bool)) -> Double {
                value.2 + (value.0.conversationID == context.conversationID && context.conversationID != nil ? 0.003 : 0)
                    + (value.0.workspaceID == context.workspaceID && context.workspaceID != nil ? 0.002 : 0)
            }
            return score(lhs) > score(rhs)
        }
        var result = [GlobalSourceHit]()
        for (source, chunk, score, semantic) in ordered {
            guard result.count < min(20, max(1, context.limit)), let provider = providers[source.providerID],
                  !(try await index.isExcluded(source.id)), await provider.isAccessible(source) else { continue }
            guard let current = try? await provider.read(source), current.source.revision == chunk.revision,
                  GlobalSourceTextPolicy.safeText(current.text).contains(chunk.text) else { continue }
            result.append(.init(id: chunk.id, source: source, excerpt: String(chunk.text.prefix(1_400)), offset: chunk.offset, score: score, semantic: semantic, sourceAvailable: true))
        }
        return result
    }
    /// Explicit Forget persists suppression before removing a memory. Linked original
    /// sources are conservatively excluded until the user restores them; originals remain untouched.
    func forget(memoryID: UUID) async throws {
        try await prepareIfNeeded()
        guard let memory = try await memories.memory(id: memoryID) else { return }
        try await index.forget(memory.content)
        try await index.forgetLinkedSources(memoryID: memoryID)
        var ids: Set<UUID> = [memoryID]
        var cursor: String?
        repeat {
            let page = try await memories.listMemories(.init(cursor: cursor, limit: 100))
            for entry in page.entries where GlobalSourceIndexStore.suppressionDigest(entry.content) == GlobalSourceIndexStore.suppressionDigest(memory.content) { ids.insert(entry.id) }
            cursor = page.nextCursor
        } while cursor != nil
        try await memories.deleteMemories(ids: ids, syncRevision: Int64(Date().timeIntervalSince1970 * 1_000))
    }
}
#endif
