// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — the REAL Android creative-document owner adapter.
//
// This is the Android port of the approved public iOS adapter
// (`FloeAgent/FloeApp/Workspace/DesignHostAdapters.swift`
// `AppCreativeDocumentPort`, public baseline 10fc0083). It is an adapter over
// EXISTING authorities — it invents no project, request database, canvas alias
// or first-project fallback:
//
//  * `G09CreativeAssetHost` / `CreativeAssetStore` own the canonical asset row
//    and the actual contained bytes under `<acceptedRoot>/FloeAgent/Materials`;
//  * `G09R2DesignOwnerProjectStore` is the SAME owner envelope store the shared
//    `DesignOwnerWorkflow` uses (no parallel request store);
//  * `SQLiteRunStore` resolves a RUN to its durable task;
//  * `MediaGenerationJobStore` owns the durable job→asset (`local_asset_id`)
//    and job→run (`origin_run_id`) linkage.
//
// A trusted in-app UI (runID == nil) may select a REAL retained asset; the
// bytes are still verified against the row digest before they are accepted.
// An agent RUN must additionally prove a durable link to its OWN task: either
// the asset is the committed local result of a job submitted by that run /
// owned by its task, or a persisted owner envelope binds that exact asset as
// the first result with trusted-UI provenance for the run's task and a digest
// that still matches the live row. A model-authored owner/source string is
// never authority.
import Foundation
import FloeCore
import FloePersistence

/// Durable run→task and job→asset authority for the creative port. Constructed
/// from the SAME `DatabaseManager` as the accepted creative generation; nil
/// when the Domain owner has not injected it yet (RUN access then fails closed
/// instead of treating an unverifiable claim as trusted UI).
public struct G09R2DesignCreativeRunAuthority: Sendable {
    let runs: SQLiteRunStore
    let jobs: MediaGenerationJobStore

    public init(database: DatabaseManager) {
        self.runs = SQLiteRunStore(database: database)
        self.jobs = MediaGenerationJobStore(database: database)
    }

    func task(for runID: UUID) async -> UUID? {
        guard let record = try? await runs.run(id: runID) else { return nil }
        return record.conversationID
    }

    /// Minimal read of the durable generation payload's origin provenance.
    /// `G09R2GenerationService` stores owner `.document(projectID)` and the
    /// real origin context in `requestJSON` before any provider call; the
    /// origin owner is the originating conversation/task for a chat route.
    private struct GenerationOriginProof: Decodable {
        var originKind: String?
        var originOwnerID: UUID?
    }

    /// The ONE durable material-link rule: the exact asset is the committed
    /// local result of a media job submitted by this run, of a job owned by
    /// the run's own conversation/task, or of a job whose durable payload
    /// records the run task as its chat origin. `localAssetID` is the stored
    /// job→asset link; a caller-supplied owner string never participates.
    func assetIsLinked(assetID: UUID, runID: UUID, task: UUID) async -> Bool {
        guard let linkedJobs = try? await jobs.jobs(localAssetID: assetID) else {
            return false
        }
        return linkedJobs.contains { owned in
            guard owned.job.localAssetID == assetID else { return false }
            if owned.originRunID == runID { return true }
            if owned.owner.kind == .conversation && owned.owner.id == task {
                return true
            }
            guard let proof = try? JSONDecoder().decode(
                GenerationOriginProof.self, from: owned.job.requestJSON) else {
                return false
            }
            return proof.originKind == "chat" && proof.originOwnerID == task
        }
    }
}

public struct G09R2DesignCreativeDocumentPort: DesignCreativeDocumentPort {
    /// Same 64 MiB design-source ceiling as the shared workspace/file port and
    /// the approved iOS adapter. Enforced on the real on-disk size BEFORE any
    /// read, then again on the loaded bytes.
    public static let maximumSourceBytes = G09R2CreativeLimits.designSourceBytes

    let assets: G09CreativeAssetHost
    let envelopes: G09R2DesignOwnerProjectStore
    let runAuthority: G09R2DesignCreativeRunAuthority?

    public init(
        assets: G09CreativeAssetHost,
        envelopes: G09R2DesignOwnerProjectStore,
        runAuthority: G09R2DesignCreativeRunAuthority?
    ) {
        self.assets = assets
        self.envelopes = envelopes
        self.runAuthority = runAuthority
    }

    // MARK: - Material read

    public func resolve(
        ownerID: String,
        creationID: String,
        environmentID: String?,
        runID: UUID?
    ) async throws -> DesignResolvedFile {
        if let runID {
            // A RUN material read requires a REAL stored link. Presenting its
            // own task as the owner proves nothing about where the bytes came
            // from; the request's model-authored source identity is never
            // accepted as authorization.
            guard await materialIsLinked(
                ownerID: ownerID, reference: creationID,
                environmentID: environmentID, runID: runID) else {
                throw DesignTargetError.notAuthorized(
                    "the creative asset is not linked to the run's own task")
            }
        }
        return try await verifiedAssetBytes(creationID: creationID)
    }

    // MARK: - Pending request authorization

    public func requestIsAuthorized(
        ownerID: String,
        requestID: String,
        environmentID: String?,
        runID: UUID?
    ) async -> Bool {
        // Trusted in-app UI: the user acting in-app. The service layer only
        // passes nil after a registered editor-session check, never from a
        // model-authored request field.
        guard let runID else { return true }
        guard let authority = runAuthority,
              let task = await authority.task(for: runID) else { return false }
        // The explicitly approved owner-task namespace for a not-yet-
        // materialized request: the run may begin/continue a creative request
        // under its OWN task identity. It grants no access to existing bytes;
        // material reads/binds go through `materialIsLinked` below.
        if ownerID.caseInsensitiveCompare(task.uuidString) == .orderedSame {
            return true
        }
        return await envelopeLinksTask(reference: requestID, task: task)
    }

    // MARK: - Bound first result

    public func boundResult(
        targetKey: String,
        ownerID: String,
        requestID: String,
        environmentID: String?,
        runID: UUID?
    ) async throws -> DesignResolvedFile? {
        guard let envelope = try await envelopes.load(targetKey: targetKey),
              let request = envelope.project.creativeRequest,
              request.state == .firstResultBound,
              let boundID = request.boundResultID else { return nil }
        let resolved = try await verifiedAssetBytes(creationID: boundID)
        // The retained bytes must still BE the recorded first result: a
        // binding whose recorded digest/format no longer match the live asset
        // fails closed instead of silently returning those bytes.
        guard let recorded = request.boundContentSHA256, !recorded.isEmpty,
              resolved.contentSHA256.caseInsensitiveCompare(recorded)
                == .orderedSame else {
            throw DesignTargetError.unverifiable(
                "the retained asset no longer matches the recorded first-result digest")
        }
        if let boundFormat = request.boundFormat, !boundFormat.isEmpty,
           boundFormat.caseInsensitiveCompare(resolved.format) != .orderedSame {
            throw DesignTargetError.unverifiable(
                "the retained asset format no longer matches the recorded first result")
        }
        if let runID {
            guard let authority = runAuthority,
                  let runTask = await authority.task(for: runID) else {
                throw DesignTargetError.notAuthorized("run is not bound to a task")
            }
            let ownerMatches = ownerID.caseInsensitiveCompare(
                runTask.uuidString) == .orderedSame
            let originMatches = request.originConversationID?
                .caseInsensitiveCompare(runTask.uuidString) == .orderedSame
            guard ownerMatches || originMatches else {
                throw DesignTargetError.notAuthorized(
                    "the creative request belongs to a different task")
            }
            switch envelope.creativeFirstResultProvenance {
            case .trustedUIManualImport:
                break
            case .generationJob:
                guard let assetUUID = UUID(uuidString: boundID),
                      await authority.assetIsLinked(
                        assetID: assetUUID, runID: runID, task: runTask) else {
                    throw DesignTargetError.notAuthorized(
                        "the bound result's durable generation link is no longer held by the run's task")
                }
            case nil:
                throw DesignTargetError.notAuthorized(
                    "the creative first-result binding has no verified provenance")
            }
        }
        return resolved
    }

    // MARK: - First-result binding authority

    public func verifyFirstResultBinding(
        ownerID: String,
        requestID: String,
        environmentID: String?,
        boundResultID: String,
        bytes: Data,
        format: String,
        runID: UUID?
    ) async throws -> DesignCreativeResultProvenance {
        guard let assetUUID = UUID(uuidString: boundResultID) else {
            throw DesignTargetError.invalidReference(
                "boundResultID is not a creative asset UUID")
        }
        let resolved = try await verifiedAssetBytes(creationID: boundResultID)
        // The proposed payload must BE the asset — not a different payload
        // that merely names it.
        guard resolved.data == bytes else {
            throw DesignTargetError.unverifiable(
                "the proposed first-result bytes are not the retained creative asset \(boundResultID)")
        }
        guard resolved.format.caseInsensitiveCompare(format) == .orderedSame else {
            throw DesignTargetError.unverifiable(
                "the proposed first-result format '\(format)' is not the retained asset format '\(resolved.format)'")
        }
        guard let runID else {
            // Trusted in-app UI: the user explicitly selected/imported this
            // REAL retained asset. The verification above is what makes the
            // recorded provenance authoritative.
            return .trustedUIManualImport
        }
        guard let authority = runAuthority,
              let runTask = await authority.task(for: runID) else {
            throw DesignTargetError.notAuthorized("run is not bound to a task")
        }
        guard await authority.assetIsLinked(
            assetID: assetUUID, runID: runID, task: runTask) else {
            throw DesignTargetError.notAuthorized(
                "the bound creative asset is not the committed result of a durable job owned by the run's task")
        }
        return .generationJob
    }

    // MARK: - Verified bytes

    /// Resolves one creative asset through the existing content-addressed
    /// store. The encoded byte cap is enforced on the REAL on-disk file size
    /// BEFORE any read, the path is contained under the artifact root, and the
    /// read bytes are digest-verified against the stored content hash.
    func verifiedAssetBytes(creationID: String) async throws -> DesignResolvedFile {
        guard let assetUUID = UUID(uuidString: creationID) else {
            throw DesignTargetError.invalidReference(
                "creative creation id is not a UUID")
        }
        let verified: G09CreativeVerifiedLocalBytes
        do {
            verified = try await assets.verifiedLocalBytes(
                id: assetUUID, maximumBytes: Self.maximumSourceBytes)
        } catch let error as G09CreativeError {
            throw Self.mapAssetError(error)
        } catch {
            throw DesignTargetError.unverifiable(
                "creative asset bytes could not be verified")
        }
        return DesignResolvedFile(
            data: verified.data,
            format: verified.format,
            displayName: verified.displayName,
            contentSHA256: verified.contentSHA256,
            // Creative assets are content-addressed: the revision is the
            // asset id plus its content hash. A new edit is a NEW asset, so an
            // in-place update stays false.
            baseRevisionToken:
                "creative:\(verified.assetID.uuidString.lowercased()):sha:\(verified.contentSHA256)",
            allowsInPlaceUpdate: false)
    }

    // MARK: - Linkage

    /// The ONE ownership rule for existing creative material: the asset/
    /// request must be linked to the run's OWN durable task through a real
    /// record — a media generation job that produced/owns the asset, or a
    /// persisted owner envelope whose bound first result IS this reference
    /// and whose origin is the run's task. The request's model-authored
    /// `sourceID` is deliberately NOT accepted: it would let a run read any
    /// existing asset it merely named.
    private func materialIsLinked(
        ownerID: String,
        reference: String,
        environmentID: String?,
        runID: UUID
    ) async -> Bool {
        guard let authority = runAuthority,
              let runTask = await authority.task(for: runID) else { return false }
        // 1) Durable job origin: the exact asset was committed as the local
        //    result of a job this run submitted (or one owned by the task).
        if let assetUUID = UUID(uuidString: reference),
           await authority.assetIsLinked(
            assetID: assetUUID, runID: runID, task: runTask) {
            return true
        }
        // 2) A REAL stored owner envelope whose STRICTLY BOUND first result is
        //    this exact reference, recorded under the run's own task, with
        //    trusted-UI provenance and a digest that still matches the live
        //    asset row. A legacy/model-authored binding has nil provenance and
        //    is refused here.
        for envelope in await envelopes.envelopes(matchingReference: reference) {
            guard let request = envelope.project.creativeRequest,
                  let origin = request.originConversationID,
                  origin.caseInsensitiveCompare(runTask.uuidString) == .orderedSame,
                  request.state == .firstResultBound,
                  request.boundResultID == reference else { continue }
            guard envelope.creativeFirstResultProvenance
                == .trustedUIManualImport else { continue }
            guard let recorded = request.boundContentSHA256, !recorded.isEmpty,
                  await assetRecordDigest(reference) == recorded.lowercased()
            else { continue }
            return true
        }
        return false
    }

    private func assetRecordDigest(_ creationID: String) async -> String? {
        guard let uuid = UUID(uuidString: creationID),
              let record = await assets.record(id: uuid) else { return nil }
        return record.contentHash.lowercased()
    }

    /// Pending-request linkage: a stored envelope records this task as the
    /// request origin. The identity fields are matched against what is STORED
    /// — never a guessed output kind.
    private func envelopeLinksTask(reference: String, task: UUID) async -> Bool {
        for envelope in await envelopes.envelopes(matchingReference: reference) {
            guard let request = envelope.project.creativeRequest,
                  let origin = request.originConversationID,
                  origin.caseInsensitiveCompare(task.uuidString) == .orderedSame
            else { continue }
            guard request.state == .awaitingFirstResult
                    || request.boundResultID == reference
                    || envelope.target.sourceID == reference else { continue }
            return true
        }
        return false
    }

    // MARK: - Error mapping

    private static func mapAssetError(_ error: G09CreativeError) -> DesignTargetError {
        switch error {
        case .assetMissing:
            return .notFound("creative asset has no readable local bytes")
        case .assetEmpty:
            return .unverifiable("creative asset bytes are empty")
        case .assetTooLarge:
            return .unverifiable(
                "creative asset exceeds the \(maximumSourceBytes)-byte design source cap")
        case .assetDigestMismatch:
            return .unverifiable(
                "creative asset bytes do not match the recorded content hash")
        case .assetReferenceInvalid:
            return .unverifiable("creative asset path is not a safe contained relative path")
        case .assetStagingUnavailable:
            return .unverifiable("creative asset bytes could not be read")
        default:
            return .notFound("creative asset is unavailable")
        }
    }
}
