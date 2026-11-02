import Foundation

@MainActor
final class CADTwoCopyMergeService {
    private final class Plan {
        weak var owner: FloeCADDocument?
        let source: URL
        let current: CADTwoCopyMergeSnapshot
        let incoming: CADTwoCopyMergeSnapshot
        let baseline: CADTwoCopyMergeSnapshot
        let changeCount: Int
        let review: CADTwoCopyMergeReview
        let expires = Date().addingTimeInterval(15 * 60)
        init(owner: FloeCADDocument, source: URL, current: CADTwoCopyMergeSnapshot,
             incoming: CADTwoCopyMergeSnapshot, baseline: CADTwoCopyMergeSnapshot,
             review: CADTwoCopyMergeReview) {
            self.owner = owner; self.source = source; self.current = current
            self.incoming = incoming; self.baseline = baseline
            self.changeCount = owner.liveChangeCount; self.review = review
        }
    }
    private static var plans: [UUID: Plan] = [:]
    let document: FloeCADDocument

    init(document: FloeCADDocument) { self.document = document }

    func compare(source: URL, baseVersionID: UUID) async throws -> CADTwoCopyMergeReview {
        try requireCurrent()
        guard !document.hasUnsavedChanges else {
            throw fail("unsaved", "cad.merge.saveFirst", "Save your changes before comparing copies.")
        }
        let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path
        let targetPath = document.url.standardizedFileURL.resolvingSymlinksInPath().path
        guard source.pathExtension.lowercased() == "floecad", sourcePath != targetPath,
              !sourcePath.hasPrefix(targetPath + "/"), !targetPath.hasPrefix(sourcePath + "/") else {
            throw fail("source", "cad.merge.otherCopy", "Choose a different design copy.")
        }
        let revision = document.revision, content = document.contentSHA256, generation = document.liveChangeCount
        let target = document.url
        async let a = Self.read(target, baseVersionID: baseVersionID)
        async let b = Self.read(source, baseVersionID: baseVersionID)
        let (current, incoming) = try await (a, b)
        try Task.checkCancellation()
        try requireCurrent()
        guard generation == document.liveChangeCount, revision == document.revision,
              content == document.contentSHA256, current.manifest.contentSHA256 == content else {
            throw fail("stale", "cad.merge.stale", "A copy changed. Compare again before merging.")
        }
        // UUID/name are only selectors. A common base is established by its
        // complete verified canonical model AND exact content identity in
        // BOTH copied checkpoint packages, never by matching names or dates.
        guard current.base.modelSHA256 == incoming.base.modelSHA256,
              current.base.manifest.contentSHA256 == incoming.base.manifest.contentSHA256 else {
            throw fail("base_mismatch", "cad.merge.noSharedBase", "These copies do not share this design version.")
        }
        let base = CADTwoCopyMergeSnapshot(
            manifest: current.base.manifest, record: current.base.document,
            modelSHA256: current.base.modelSHA256, resourceSHA256: current.base.resourceSHA256, base: current.base)
        let rows = try CADTwoCopyMergeCore.rows(base: base, current: current, incoming: incoming)
        let review = CADTwoCopyMergeReview(
            id: UUID(), baseVersionID: baseVersionID, baseName: current.base.name,
            baseModelSHA256: base.modelSHA256, baseContentSHA256: base.manifest.contentSHA256,
            baseRevision: base.manifest.revision, currentRevision: revision,
            currentContentSHA256: content, currentModelSHA256: current.modelSHA256,
            incomingRevision: incoming.manifest.revision,
            incomingContentSHA256: incoming.manifest.contentSHA256, incomingModelSHA256: incoming.modelSHA256,
            rows: rows, conflictIDs: rows.filter { $0.status == "conflict" }.map(\.id),
            unsupportedIDs: rows.filter { $0.status == "unsupported" }.map(\.id))
        Self.plans = Self.plans.filter { $0.value.owner != nil && $0.value.expires > Date() && $0.value.owner !== document }
        // Bounded process RAM only; a plan is not an authorization token.
        if Self.plans.count >= 8, let oldest = Self.plans.min(by: { $0.value.expires < $1.value.expires })?.key {
            Self.plans.removeValue(forKey: oldest)
        }
        try Task.checkCancellation()
        Self.plans[review.id] = Plan(owner: document, source: source, current: current,
                                    incoming: incoming, baseline: base, review: review)
        return review
    }

    func cancel(_ id: UUID) {
        guard Self.plans[id]?.owner === document else { return }
        Self.plans.removeValue(forKey: id)
    }

    func apply(_ id: UUID, resolutions: [String: String]) async throws -> CADTwoCopyMergeResult {
        try requireCurrent(writable: true)
        guard let plan = Self.plans[id], plan.owner === document, plan.expires > Date() else {
            throw fail("expired", "cad.merge.expired", "Compare the copies again before merging.")
        }
        let features = try CADTwoCopyMergeCore.mergedFeatures(
            base: plan.baseline, current: plan.current, incoming: plan.incoming,
            rows: plan.review.rows, resolutions: resolutions)
        try validateLive(plan)
        let target = document.url
        // Re-read both current packages and their common checkpoints. A plan
        // cannot bless a changed file, a replaced source, a deleted checkpoint,
        // or a target whose CAS identity moved after the review.
        async let a = Self.read(target, baseVersionID: plan.review.baseVersionID)
        async let b = Self.read(plan.source, baseVersionID: plan.review.baseVersionID)
        let (current, incoming) = try await (a, b)
        try Task.checkCancellation()
        try requireCurrent(writable: true)
        try validateLive(plan)
        guard current.manifest.contentSHA256 == plan.current.manifest.contentSHA256,
              current.modelSHA256 == plan.current.modelSHA256,
              incoming.manifest.contentSHA256 == plan.incoming.manifest.contentSHA256,
              incoming.modelSHA256 == plan.incoming.modelSHA256,
              current.base.modelSHA256 == plan.baseline.modelSHA256,
              incoming.base.modelSHA256 == plan.baseline.modelSHA256,
              current.base.manifest.contentSHA256 == plan.baseline.manifest.contentSHA256,
              incoming.base.manifest.contentSHA256 == plan.baseline.manifest.contentSHA256 else {
            throw fail("stale", "cad.merge.stale", "A copy changed. Compare again before merging.")
        }
        // A cancel/second comparison may have won while file verification
        // awaited. Check exact plan registration before consuming it.
        guard Self.plans[id] === plan else {
            throw fail("expired", "cad.merge.expired", "Compare the copies again before merging.")
        }
        Self.plans.removeValue(forKey: id)
        let encodedBefore = try cadRecordEncoder().encode(document.session.document.features.nodes)
        if encodedBefore == (try cadRecordEncoder().encode(features)) {
            return result(applied: false)
        }
        let receipt = try document.store.withActiveOwnerWriteLease {
            document.session.performTwoCopyMerge(features)
        }
        guard let receipt else {
            throw fail("rebuild_failed", "cad.merge.rebuildFailed", "These feature changes cannot be rebuilt together. Nothing was merged.")
        }
        // Exact owned-command rollback includes the original Undo/Redo and
        // derived caches. It never blindly undoes an intervening user edit.
        let saved = await document.save()
        if !saved.succeeded {
            let rollback = document.session.rollbackOwnedCommand(token: receipt.token)
            if rollback == .alreadyCommitted { return result(applied: true) }
            throw CADDocumentError(code: "merge_save_failed", message: saved.error
                ?? FloeCADStrings.text("cad.merge.saveFailed", "The merge could not be saved."),
                details: ["rollback": String(describing: rollback)])
        }
        return result(applied: true)
    }

    private func result(applied: Bool) -> CADTwoCopyMergeResult {
        CADTwoCopyMergeResult(applied: applied, revision: document.revision,
                              contentSHA256: document.contentSHA256, modelSHA256: document.modelSHA256)
    }

    private func validateLive(_ plan: Plan) throws {
        guard !document.hasUnsavedChanges,
              document.liveChangeCount == plan.changeCount,
              document.revision == plan.review.currentRevision,
              document.contentSHA256 == plan.review.currentContentSHA256 else {
            throw fail("stale", "cad.merge.stale", "A copy changed. Compare again before merging.")
        }
    }

    private func requireCurrent(writable: Bool = false) throws {
        // The native owner lease is authoritative even for a previously
        // created plan. A plan never re-opens a document closed/deleted by its
        // real owner. Read-only comparison uses the same live owner check.
        try document.store.requireActiveOwnerWriteLease()
        if writable, let block = document.session.writeBlock {
            throw CADDocumentError(code: block.code, message: block.message)
        }
        if writable, document.isReadOnly {
            throw fail("read_only", "cad.merge.readOnly", "This design is read-only.")
        }
    }

    private nonisolated static func read(_ url: URL, baseVersionID: UUID) async throws -> CADTwoCopyMergeSnapshot {
        let task = Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try Task.checkCancellation()
            CADPackageGate.acquire(url)
            defer { CADPackageGate.release(url) }
            let store = FileCADDocumentStore(packageURL: url)
            let verified = try store.verifiedPackage(at: url)
            let base: CADNamedVersionPackage
            do { base = try CADNamedVersionStore(packageURL: url).load(baseVersionID) }
            catch {
                throw CADTwoCopyMergeCore.failure("base_unreadable", "cad.merge.baseUnreadable", "The shared design version could not be read.")
            }
            guard verified.manifest.schemaVersion <= Project.currentFormatVersion,
                  !verified.formatAssessment.isOpaqueReadOnly,
                  !base.state.isOpaqueForWrite,
                  !base.modelSHA256.hasPrefix("content:"),
                  base.manifest.schemaVersion <= Project.currentFormatVersion,
                  let model = verified.modelSHA256 else {
                throw CADTwoCopyMergeCore.failure("unsupported", "cad.merge.unsupported", "These changes cannot be merged yet.")
            }
            try Task.checkCancellation()
            let thinBase = CADTwoCopyMergeBase(manifest: base.manifest, document: base.document,
                modelSHA256: base.modelSHA256,
                resourceSHA256: CADTwoCopyMergeCore.resources(base.document, blobs: base.blobs), name: base.record.name)
            return CADTwoCopyMergeSnapshot(manifest: verified.manifest, record: verified.document,
                modelSHA256: model, resourceSHA256: CADTwoCopyMergeCore.resources(verified.document, blobs: verified.blobs), base: thinBase)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private func fail(_ code: String, _ key: String, _ fallback: String) -> CADDocumentError {
        CADTwoCopyMergeCore.failure(code, key, fallback)
    }
}

public extension FloeCADDocument {
    func compareCopy(at source: URL, baseVersionID: UUID) async throws -> CADTwoCopyMergeReview {
        try await CADTwoCopyMergeService(document: self).compare(source: source, baseVersionID: baseVersionID)
    }
    func mergeCopy(planID: UUID, resolutions: [String: String] = [:]) async throws -> CADTwoCopyMergeResult {
        try await CADTwoCopyMergeService(document: self).apply(planID, resolutions: resolutions)
    }
    func cancelCopyMerge(planID: UUID) { CADTwoCopyMergeService(document: self).cancel(planID) }

    /// sourceURL is resolved by the App host, never parsed from model payload.
    func handleCopyMergeAction(_ action: String, args: [String: Any], sourceURL: URL?) async throws -> String {
        let service = CADTwoCopyMergeService(document: self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        switch action {
        case "merge_compare":
            guard let sourceURL, let raw = args["base_version_id"] as? String, let base = UUID(uuidString: raw) else {
                throw CADTwoCopyMergeCore.failure("arguments", "cad.merge.chooseBase", "Choose the shared starting version and the other copy.")
            }
            data = try encoder.encode(try await service.compare(source: sourceURL, baseVersionID: base))
        case "merge_apply", "merge_cancel":
            guard let raw = args["plan_id"] as? String, let id = UUID(uuidString: raw) else {
                throw CADTwoCopyMergeCore.failure("expired", "cad.merge.expired", "Compare the copies again before merging.")
            }
            if action == "merge_cancel" { service.cancel(id); return "{\"ok\":true,\"cancelled\":true}" }
            let resolutions: [String: String]
            if let raw = args["resolutions"] {
                guard let parsed = raw as? [String: String] else {
                    throw CADTwoCopyMergeCore.failure("conflicts", "cad.merge.resolveConflicts", "Choose a copy for each conflict.")
                }
                resolutions = parsed
            } else { resolutions = [:] }
            data = try encoder.encode(try await service.apply(id, resolutions: resolutions))
        default:
            throw CADTwoCopyMergeCore.failure("arguments", "cad.merge.expired", "Compare the copies again before merging.")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
