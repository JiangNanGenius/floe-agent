import Foundation
import Testing
@testable import FloeCore

// FloeCoreTests — 制作/修改/重构 shared contract (T1):
// - WorkIntent round-trip + legacy migration defaults
// - trusted preservation confirmation (model cannot mint it)
// - restructure propose/adopt gating in the shared owner workflow
// - owner identity unchanged by the new optional fields
// - stale candidate after a manual edit (variant/regenerate, never overwrite)
// - idempotent replay of intent-carrying proposals
// - real capability matrix (missing → false with reason, live veto, capture ≠ generation)
// - Canvas layout objects are composition, never webpage

// MARK: - In-memory doubles (file-owner based)

private actor IntentOwnerStore: DesignOwnerProjectStore {
    private var envelopes: [String: DesignOwnerEnvelope] = [:]

    init(seed: DesignOwnerEnvelope? = nil) {
        if let seed { envelopes[seed.target.stableKey] = seed }
    }

    func load(targetKey: String) async throws -> DesignOwnerEnvelope? {
        envelopes[targetKey]
    }

    @discardableResult
    func save(
        _ envelope: DesignOwnerEnvelope,
        targetKey: String,
        expectedRevision: Int64?
    ) async throws -> Int64 {
        if let existing = envelopes[targetKey], let expectedRevision,
           existing.revision != expectedRevision {
            throw FloeError.validationFailed(
                "owner conflict expected \(expectedRevision) actual \(existing.revision)"
            )
        }
        var next = envelope
        next.revision = (expectedRevision ?? 0) + 1
        envelopes[targetKey] = next
        return next.revision
    }
}

private final class IntentPayloadStore: DesignOwnerPayloadStore, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var blobs: [String: Data] = [:]

    var stagedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return blobs.count
    }

    func store(
        ownerKey: String,
        revisionID: String,
        bytes: Data,
        expectedContentSHA256: String
    ) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard FloeDigest.sha256Hex(bytes) == expectedContentSHA256.lowercased() else {
            throw FloeError.validationFailed("digest mismatch")
        }
        blobs["\(ownerKey)/\(revisionID)"] = bytes
        return "DesignRevisions/owners/\(ownerKey)/revisions/\(revisionID).payload"
    }

    func verifiedBytes(
        ownerKey: String,
        revisionID: String,
        expectedContentSHA256: String
    ) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let data = blobs["\(ownerKey)/\(revisionID)"],
              FloeDigest.sha256Hex(data) == expectedContentSHA256.lowercased() else {
            throw FloeError.storageCorrupted("payload unavailable")
        }
        return data
    }

    func abandon(ownerKey: String, revisionID: String) {
        lock.lock(); defer { lock.unlock() }
        blobs.removeValue(forKey: "\(ownerKey)/\(revisionID)")
    }
}

private final class IntentFilePort: DesignWorkspaceFilePort, @unchecked Sendable {
    var files: [String: Data] = [:]
    var format = "pptx"

    func resolve(
        workspaceID: String,
        reference: String,
        environmentID: String?,
        runID: UUID?
    ) async throws -> DesignResolvedFile {
        guard let data = files[reference] else {
            throw DesignTargetError.notFound("stub missing \(reference)")
        }
        return DesignResolvedFile(
            data: data,
            format: format,
            displayName: (reference as NSString).lastPathComponent,
            contentSHA256: FloeDigest.sha256Hex(data),
            baseRevisionToken: "workspace:\(workspaceID):sha:\(FloeDigest.sha256Hex(data))",
            allowsInPlaceUpdate: true
        )
    }

    func isAuthorized(
        workspaceID: String,
        reference: String,
        environmentID: String?,
        runID: UUID?
    ) async -> Bool { true }

    func exists(workspaceID: String, reference: String, environmentID: String?) async -> Bool {
        files[reference] != nil
    }
}

private final class IntentCommitPort: DesignOwnerCommitPort, @unchecked Sendable {
    private(set) var committedBytes: Data?
    private(set) var commitCount = 0
    private(set) var claimCount = 0

    func canCommit(_ target: DesignTarget) -> Bool { true }

    func commit(
        target: DesignTarget,
        reference: String,
        bytes: Data,
        format: String,
        baseRevisionToken: String
    ) async throws -> String {
        commitCount += 1
        committedBytes = bytes
        return "workspace:stub:sha:\(FloeDigest.sha256Hex(bytes))"
    }

    func verify(
        target: DesignTarget,
        reference: String,
        proposedContentSHA256: String,
        baseRevisionToken: String
    ) async throws -> DesignCommitVerification {
        .matchesProposed
    }
}

private final class IntentClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func burn() { lock.lock(); count += 1; lock.unlock() }
    var burnedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

private func intentOutbox() -> DesignDecisionOutbox {
    DesignDecisionOutbox(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("design-intent-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("outbox.json"))
}

private func makeIntentWorkflow(
    filePort: IntentFilePort = IntentFilePort(),
    commitPort: IntentCommitPort = IntentCommitPort(),
    store: IntentOwnerStore = IntentOwnerStore(),
    payloads: IntentPayloadStore = IntentPayloadStore()
) -> (DesignTargetService, DesignOwnerWorkflow, IntentFilePort, IntentCommitPort, IntentPayloadStore) {
    let adapter = DesignFileOwnerAdapter(port: filePort)
    let service = DesignTargetService(adapters: [adapter])
    let workflow = DesignOwnerWorkflow(
        targets: service,
        store: store,
        payloads: payloads,
        commitPorts: [.fileDocument: commitPort],
        outbox: intentOutbox()
    )
    return (service, workflow, filePort, commitPort, payloads)
}

private func deckTarget() -> DesignTarget {
    DesignTarget(
        kind: .fileDocument,
        ownerID: "workspace-1",
        documentID: "",
        sourceID: "deck.pptx"
    )
}

private func restructureIntent(
    operationID: String,
    preservation: DesignPreservationConstraints = DesignPreservationConstraints(
        content: ["keep slide 2 chart"],
        data: ["keep Q4 numbers"]
    )
) -> DesignWorkIntent {
    DesignWorkIntent(
        mode: .restructure,
        actualDesiredFormat: "pptx",
        scope: DesignWorkScope(pageIndexes: [0, 1]),
        preservation: preservation,
        confirmation: DesignPreservationConfirmation(constraints: preservation),
        operationID: operationID
    )
}

/// Trusted-authority double: counts invocations like a real claim burn and
/// returns a receipt for the service-built request, unless `override`
/// forges one (stale/wrong-owner/wrong-digest simulation).
private func trustedAuthority(
    claims: IntentClaim,
    override: (@Sendable (DesignRestructureAuthorityRequest) -> DesignRestructureAuthorityRequest)? = nil
) -> DesignRestructureAuthorityHandler {
    { request in
        claims.burn()
        return DesignRestructureAuthorityReceipt(
            request: override?(request) ?? request,
            claimID: UUID()
        )
    }
}

/// Mint the receipt a trusted service would return for an engine-path call.
private func engineReceipt(
    for intent: DesignWorkIntent,
    nodeID: String,
    baseRevisionID: String?
) throws -> DesignRestructureAuthorityReceipt {
    DesignRestructureAuthorityReceipt(
        request: try DesignRestructureAuthority.request(
            for: intent, targetKey: nodeID, baseRevisionID: baseRevisionID
        ),
        claimID: UUID()
    )
}

// MARK: - Work intent contract

@Suite("Design work intent contract")
struct DesignWorkIntentTests {

    @Test func intentRoundTripsThroughCodable() throws {
        let intent = DesignWorkIntent(
            mode: .restructure,
            actualDesiredFormat: "pptx",
            scope: DesignWorkScope(
                objectIDs: ["shape-1"],
                pageIndexes: [0, 2],
                region: .init(x: 1, y: 2, width: 30, height: 40),
                timeRange: .init(startSeconds: 1.5, endSeconds: 9)
            ),
            preservation: DesignPreservationConstraints(
                content: ["a"], data: ["b"], behavior: ["c"], formatBounds: ["d"]
            ),
            frozenRevisionID: "rev-1",
            originalTaskOwnerID: "conv-1",
            confirmation: DesignPreservationConfirmation(
                constraints: DesignPreservationConstraints(content: ["a"])
            ),
            operationID: "op-1"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(intent)
        let decoded = try JSONDecoder().decode(DesignWorkIntent.self, from: data)
        #expect(decoded == intent)
        #expect(decoded.confirmation?.isValid == true)
    }

    @Test func scopeValidationRejectsMalformedLocators() throws {
        #expect(throws: DesignWorkIntentError.self) {
            _ = try DesignWorkScope(pageIndexes: [-1]).validated()
        }
        #expect(throws: DesignWorkIntentError.self) {
            _ = try DesignWorkScope(objectIDs: ["  "]).validated()
        }
        #expect(throws: DesignWorkIntentError.self) {
            _ = try DesignWorkScope(timeRange: .init(startSeconds: 5, endSeconds: 2)).validated()
        }
        #expect(throws: DesignWorkIntentError.self) {
            _ = try DesignWorkScope(region: .init(x: 0, y: 0, width: 0, height: 4)).validated()
        }
        let empty = DesignWorkScope()
        #expect(empty.isEmpty)
        #expect(try empty.validated().isEmpty)
    }

    @Test func restructureRequiresValidTrustedConfirmation() throws {
        let preservation = DesignPreservationConstraints(content: ["keep cover"])
        // No confirmation at all.
        #expect(throws: DesignWorkIntentError.preservationConfirmationRequired) {
            _ = try DesignWorkIntent(
                mode: .restructure, actualDesiredFormat: "pptx",
                preservation: preservation, operationID: "op"
            ).validated(family: .presentation)
        }
        // Empty preservation constraints are not confirmable.
        #expect(throws: DesignWorkIntentError.preservationConfirmationRequired) {
            _ = try DesignWorkIntent(
                mode: .restructure, actualDesiredFormat: "pptx",
                preservation: DesignPreservationConstraints(),
                confirmation: DesignPreservationConfirmation(
                    constraints: DesignPreservationConstraints()
                ),
                operationID: "op"
            ).validated(family: .presentation)
        }
        // A confirmation over DIFFERENT constraints (model re-attach) is invalid.
        #expect(throws: DesignWorkIntentError.self) {
            _ = try DesignWorkIntent(
                mode: .restructure, actualDesiredFormat: "pptx",
                preservation: preservation,
                confirmation: DesignPreservationConfirmation(
                    constraints: DesignPreservationConstraints(content: ["something else"])
                ),
                operationID: "op"
            ).validated(family: .presentation)
        }
        // Digest tampering fails closed.
        var tampered = DesignPreservationConfirmation(constraints: preservation)
        tampered.constraintsDigest = "0".repeated(toLength: tampered.constraintsDigest.count)
        #expect(tampered.isValid == false)
        // Valid confirmation passes.
        let intent = DesignWorkIntent(
            mode: .restructure, actualDesiredFormat: "pptx",
            preservation: preservation,
            confirmation: DesignPreservationConfirmation(constraints: preservation),
            operationID: "op"
        )
        #expect(try intent.validated(family: .presentation) == intent)
    }

    @Test func actualDesiredFormatMustMapToArtifactFamily() throws {
        let scope = DesignWorkScope(objectIDs: ["chart"])
        #expect(throws: DesignWorkIntentError.formatFamilyMismatch(format: "png", family: .presentation)) {
            _ = try DesignWorkIntent(
                mode: .modify, actualDesiredFormat: "png", scope: scope,
                operationID: "op"
            ).validated(family: .presentation)
        }
        #expect(throws: DesignWorkIntentError.self) {
            _ = try DesignWorkIntent(
                mode: .modify, actualDesiredFormat: "exe", scope: scope,
                operationID: "op"
            ).validated(family: .presentation)
        }
        #expect(try DesignWorkIntent(
            mode: .modify, actualDesiredFormat: "pptx", scope: scope,
            operationID: "op"
        ).validated(family: .presentation).actualDesiredFormat == "pptx")
    }

    @Test func engineProposeStampsWorkModeAndDigest() throws {
        var project = DesignWorkflowEngine.createProject(
            nodeID: "node", contentType: .presentation
        )
        let artifact = DesignArtifact(
            contentType: .presentation,
            identity: DesignArtifactIdentity(name: "Deck", positionX: 0, positionY: 0, width: 0, height: 0)
        )
        DesignWorkflowEngine.addArtifact(artifact, to: &project)
        let base = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifact.id, contentSHA256: "sha-base", origin: .importFile
        )
        let preservation = DesignPreservationConstraints(content: ["keep chart"])
        let intent = DesignWorkIntent(
            mode: .restructure, actualDesiredFormat: "pptx",
            scope: DesignWorkScope(pageIndexes: [1]),
            preservation: preservation,
            frozenRevisionID: base.id, originalTaskOwnerID: "conv-9",
            confirmation: DesignPreservationConfirmation(constraints: preservation),
            operationID: "op-restructure"
        )
        let candidate = try DesignWorkflowEngine.proposeCandidate(
            in: &project, artifactID: artifact.id,
            proposedContentSHA256: "sha-proposed", summary: "reorder",
            workIntent: intent,
            restructureReceipt: try engineReceipt(
                for: intent, nodeID: "node", baseRevisionID: base.id
            )
        )
        #expect(candidate.workMode == DesignWorkMode.restructure)
        #expect(candidate.preservationDigest == preservation.canonicalDigest)

        let modifyCandidate = try DesignWorkflowEngine.proposeCandidate(
            in: &project, artifactID: artifact.id,
            baseRevisionID: candidate.proposedRevisionID,
            proposedContentSHA256: "sha-proposed-2", summary: "tweak",
            workIntent: DesignWorkIntent(
                mode: .modify, actualDesiredFormat: "pptx",
                scope: DesignWorkScope(objectIDs: ["shape-1"]), operationID: "op-modify"
            )
        )
        #expect(modifyCandidate.workMode == DesignWorkMode.modify)
        #expect(modifyCandidate.preservationDigest == nil)

        // The frozen run records the actual desired format.
        #expect(project.frozenRun?.desiredFormat == "pptx")
    }

    @Test func engineProposeRejectsRestructureWithoutConfirmationAndStaysClean() throws {
        var project = DesignWorkflowEngine.createProject(
            nodeID: "node", contentType: .presentation
        )
        let artifact = DesignArtifact(
            contentType: .presentation,
            identity: DesignArtifactIdentity(name: "Deck", positionX: 0, positionY: 0, width: 0, height: 0)
        )
        DesignWorkflowEngine.addArtifact(artifact, to: &project)
        _ = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifact.id, contentSHA256: "sha-base", origin: .importFile
        )
        let revisionCount = project.artifact(artifact.id)?.revisions.count
        #expect(throws: DesignWorkIntentError.preservationConfirmationRequired) {
            _ = try DesignWorkflowEngine.proposeCandidate(
                in: &project, artifactID: artifact.id,
                proposedContentSHA256: "sha-proposed", summary: "reorder",
                workIntent: DesignWorkIntent(
                    mode: .restructure, actualDesiredFormat: "pptx",
                    preservation: DesignPreservationConstraints(content: ["x"]),
                    operationID: "op-bad"
                )
            )
        }
        // Fail-closed: no revision, no candidate, no recorded operation.
        #expect(project.artifact(artifact.id)?.revisions.count == revisionCount)
        #expect(project.candidates.isEmpty)
        #expect(project.hasApplied(operationID: "op-bad") == false)
    }

    @Test func legacyCandidateAndFrozenRunDecodeWithDefaults() throws {
        let legacyCandidate = """
        {"id":"c1","artifactID":"a1","baseRevisionID":"b1","proposedRevisionID":"p1",\
        "feedbackIDs":[],"summary":"s","diff":[],"status":"pending","createdAt":600000000}
        """
        let candidate = try JSONDecoder().decode(
            DesignCandidate.self, from: Data(legacyCandidate.utf8)
        )
        #expect(candidate.workMode == nil)
        #expect(candidate.preservationDigest == nil)
        #expect(candidate.proposalOperationID == nil)
        // Re-encode keeps the payload decodable with the same defaults.
        let reencoded = try JSONEncoder().encode(candidate)
        let rereadec = try JSONDecoder().decode(DesignCandidate.self, from: reencoded)
        #expect(rereadec.workMode == nil)
        #expect(rereadec.preservationDigest == nil)
        #expect(rereadec == candidate)

        let legacyFrozen = """
        {"operationID":"op","inputRevisionID":"r1","frozenAt":600000000}
        """
        let frozen = try JSONDecoder().decode(
            DesignRunFrozen.self, from: Data(legacyFrozen.utf8)
        )
        #expect(frozen.desiredFormat == nil)
        #expect(frozen.workMode == nil)
        #expect(frozen.preservationDigest == nil)

        let legacyEnvelope = """
        {"schemaVersion":1,"target":{"kind":"fileDocument","ownerID":"w",\
        "documentID":"","sourceID":"deck.pptx","requestedOutputKind":null},\
        "revision":3,"project":{"nodeID":"n","contentType":"webpage",\
        "createdAt":600000000,"updatedAt":600000000},\
        "createdAt":600000000,"updatedAt":600000000}
        """
        let envelope = try JSONDecoder().decode(
            DesignOwnerEnvelope.self, from: Data(legacyEnvelope.utf8)
        )
        #expect(envelope.revision == 3)
        #expect(envelope.creativeFirstResultProvenance == nil)
    }

    @Test func newCandidateFieldsDoNotChangeOwnerIdentity() throws {
        let target = deckTarget()
        var project = DesignWorkflowEngine.createProject(
            nodeID: target.stableKey, contentType: .presentation
        )
        let artifact = DesignArtifact(
            contentType: .presentation,
            identity: DesignArtifactIdentity(name: "Deck", positionX: 0, positionY: 0, width: 0, height: 0)
        )
        DesignWorkflowEngine.addArtifact(artifact, to: &project)
        let base = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifact.id, contentSHA256: "sha-base", origin: .importFile
        )
        let preservation = DesignPreservationConstraints(content: ["x"])
        let stamped = DesignWorkIntent(
            mode: .restructure, actualDesiredFormat: "pptx",
            preservation: preservation,
            confirmation: DesignPreservationConfirmation(constraints: preservation),
            operationID: "op"
        )
        _ = try DesignWorkflowEngine.proposeCandidate(
            in: &project, artifactID: artifact.id,
            proposedContentSHA256: "sha-proposed", summary: "reorder",
            workIntent: stamped,
            restructureReceipt: try engineReceipt(
                for: stamped, nodeID: target.stableKey, baseRevisionID: base.id
            )
        )
        // The store/envelope identity key is untouched by candidate extras.
        #expect(target.stableKey == deckTarget().stableKey)
        #expect(target.isSameSource(as: deckTarget()))
        let redecoded = try JSONDecoder().decode(
            DesignOwnerEnvelope.self,
            from: JSONEncoder().encode(DesignOwnerEnvelope(target: target, project: project))
        )
        #expect(redecoded.target.stableKey == target.stableKey)
    }
}

// MARK: - Restructure gating in the shared owner workflow

@Suite("Design owner workflow restructure gate")
struct DesignRestructureGateTests {

    @Test func restructureAdoptWithoutTrustedClaimFailsClosed() async throws {
        let (service, workflow, filePort, _, _) = makeIntentWorkflow()
        _ = service
        filePort.files["deck.pptx"] = Data("original deck".utf8)
        let target = deckTarget()
        let frozen = try await workflow.freezeInput(
            target: target, operationID: "op-freeze", expectedOwnerRevision: nil
        )
        let proposed = Data("restructured deck".utf8)
        let proposal = try await workflow.propose(
            target: target, operationID: "op-propose",
            expectedOwnerRevision: frozen.envelope.revision,
            artifactID: frozen.revision.artifactID,
            baseRevisionID: frozen.revision.id,
            bytes: proposed, format: "pptx", summary: "reorder narrative",
            workIntent: restructureIntent(operationID: "op-propose"),
            restructureAuthority: trustedAuthority(claims: IntentClaim())
        )
        #expect(proposal.candidate.workMode == .restructure)
        #expect(proposal.candidate.preservationDigest != nil)

        // Adopt WITHOUT the trusted-UI claim hook: fail closed, zero effects.
        var thrown: Error?
        do {
            _ = try await workflow.adopt(
                target: target.freezing(revision: frozen.source.baseRevisionToken),
                operationID: "op-adopt",
                expectedOwnerRevision: proposal.envelope.revision,
                candidateID: proposal.candidate.id,
                mode: .updateOriginal,
                verifyReopen: { _, _, _ in }
            )
        } catch {
            thrown = error
        }
        guard let error = thrown else {
            Issue.record("expected restructureRequiresTrustedConfirmation")
            return
        }
        guard case DesignOwnerWorkflowError.restructureRequiresTrustedConfirmation = error else {
            Issue.record("unexpected error \(error)")
            return
        }
        let state = try await workflow.state(target)
        #expect(state?.project.candidate(proposal.candidate.id)?.status == .pending)
        // The proposal operation is recorded, the adoption is not.
        #expect(state?.project.hasApplied(operationID: "op-adopt") == false)
    }

    @Test func restructureAdoptWithTrustedClaimSucceedsOnce() async throws {
        let (service, workflow, filePort, commitPort, _) = makeIntentWorkflow()
        _ = service
        filePort.files["deck.pptx"] = Data("original deck".utf8)
        let target = deckTarget()
        let frozen = try await workflow.freezeInput(
            target: target, operationID: "op-freeze", expectedOwnerRevision: nil
        )
        let proposed = Data("restructured deck".utf8)
        let proposal = try await workflow.propose(
            target: target, operationID: "op-propose",
            expectedOwnerRevision: frozen.envelope.revision,
            artifactID: frozen.revision.artifactID,
            baseRevisionID: frozen.revision.id,
            bytes: proposed, format: "pptx", summary: "reorder narrative",
            workIntent: restructureIntent(operationID: "op-propose"),
            restructureAuthority: trustedAuthority(claims: IntentClaim())
        )
        let claim = IntentClaim()
        let frozenTarget = target.freezing(revision: frozen.source.baseRevisionToken)
        let result = try await workflow.adopt(
            target: frozenTarget,
            operationID: "op-adopt",
            expectedOwnerRevision: proposal.envelope.revision,
            candidateID: proposal.candidate.id,
            mode: .updateOriginal,
            claimAuthorization: {
                claim.burn()
            },
            verifyReopen: { bytes, format, family in
                #expect(bytes == proposed)
                #expect(format == "pptx")
                #expect(family == .presentation)
            }
        )
        #expect(result.replayed == false)
        #expect(claim.burnedCount == 1)
        #expect(commitPort.committedBytes == proposed)
        #expect(result.envelope.project.candidate(proposal.candidate.id)?.status == .adopted)

        // Idempotent replay does NOT burn a second claim.
        let replay = try await workflow.adopt(
            target: frozenTarget,
            operationID: "op-adopt",
            expectedOwnerRevision: result.envelope.revision,
            candidateID: proposal.candidate.id,
            mode: .updateOriginal,
            claimAuthorization: {
                claim.burn()
            },
            verifyReopen: { _, _, _ in }
        )
        #expect(replay.replayed == true)
        #expect(claim.burnedCount == 1)
        #expect(commitPort.commitCount == 1)
    }

    @Test func intentCarryingProposalReplaysOnlyWithMatchingIntent() async throws {
        let (service, workflow, filePort, _, _) = makeIntentWorkflow()
        _ = service
        filePort.files["deck.pptx"] = Data("original deck".utf8)
        let target = deckTarget()
        let frozen = try await workflow.freezeInput(
            target: target, operationID: "op-freeze", expectedOwnerRevision: nil
        )
        let intent = restructureIntent(operationID: "op-propose")
        let claims = IntentClaim()
        let proposal = try await workflow.propose(
            target: target, operationID: "op-propose",
            expectedOwnerRevision: frozen.envelope.revision,
            artifactID: frozen.revision.artifactID,
            baseRevisionID: frozen.revision.id,
            bytes: Data("restructured deck".utf8), format: "pptx",
            summary: "reorder narrative", workIntent: intent,
            restructureAuthority: trustedAuthority(claims: claims)
        )
        #expect(claims.burnedCount == 1)
        // Exact replay (same operationID, same bytes/summary/intent) is
        // idempotent and does NOT invoke the authority hook again.
        let replay = try await workflow.propose(
            target: target, operationID: "op-propose",
            expectedOwnerRevision: proposal.envelope.revision,
            artifactID: frozen.revision.artifactID,
            baseRevisionID: frozen.revision.id,
            bytes: Data("restructured deck".utf8), format: "pptx",
            summary: "reorder narrative", workIntent: intent
        )
        #expect(replay.replayed == true)
        #expect(replay.candidate.id == proposal.candidate.id)
        #expect(claims.burnedCount == 1)

        // A replay carrying DIFFERENT preservation requirements is a mismatch,
        // never a silent re-attach of the confirmation (and no second claim).
        let differentPreservation = DesignPreservationConstraints(content: ["keep everything else"])
        var mismatched = false
        do {
            _ = try await workflow.propose(
                target: target, operationID: "op-propose",
                expectedOwnerRevision: proposal.envelope.revision,
                artifactID: frozen.revision.artifactID,
                baseRevisionID: frozen.revision.id,
                bytes: Data("restructured deck".utf8), format: "pptx",
                summary: "reorder narrative",
                workIntent: restructureIntent(
                    operationID: "op-propose",
                    preservation: differentPreservation
                )
            )
        } catch DesignOwnerWorkflowError.replayMismatch {
            mismatched = true
        }
        #expect(mismatched)
        #expect(claims.burnedCount == 1)
        let state = try await workflow.state(target)
        #expect(state?.project.candidates.count == 1)
    }

    @Test func manualEditMakesCandidateStaleAndVariantDoesNotOverwrite() async throws {
        let (service, workflow, filePort, commitPort, _) = makeIntentWorkflow()
        _ = service
        filePort.files["deck.pptx"] = Data("original deck".utf8)
        let target = deckTarget()
        let frozen = try await workflow.freezeInput(
            target: target, operationID: "op-freeze", expectedOwnerRevision: nil
        )
        let proposed = Data("ai restructured deck".utf8)
        let proposal = try await workflow.propose(
            target: target, operationID: "op-propose",
            expectedOwnerRevision: frozen.envelope.revision,
            artifactID: frozen.revision.artifactID,
            baseRevisionID: frozen.revision.id,
            bytes: proposed, format: "pptx", summary: "reorder",
            workIntent: restructureIntent(operationID: "op-propose"),
            restructureAuthority: trustedAuthority(claims: IntentClaim())
        )
        // A manual editor save moves the artifact past the candidate base.
        let manual = try await workflow.registerEdit(
            target: target, operationID: "op-manual",
            expectedOwnerRevision: proposal.envelope.revision,
            artifactID: frozen.revision.artifactID,
            bytes: Data("user manual edit".utf8), format: "pptx",
            origin: .edit
        )
        let frozenTarget = target.freezing(revision: frozen.source.baseRevisionToken)
        // update-original on the stale candidate is rejected — never overwrite.
        var staleRejected = false
        do {
            _ = try await workflow.adopt(
                target: frozenTarget,
                operationID: "op-adopt",
                expectedOwnerRevision: manual.envelope.revision,
                candidateID: proposal.candidate.id,
                mode: .updateOriginal,
                claimAuthorization: {},
                verifyReopen: { _, _, _ in }
            )
        } catch DesignWorkflowError.revisionConflict {
            staleRejected = true
        }
        #expect(staleRejected)

        // Variant adoption still works: it branches without touching the
        // newer manual revision.
        let variant = try await workflow.adopt(
            target: frozenTarget,
            operationID: "op-adopt-variant",
            expectedOwnerRevision: manual.envelope.revision,
            candidateID: proposal.candidate.id,
            mode: .variant,
            claimAuthorization: {},
            verifyReopen: { _, _, _ in }
        )
        #expect(variant.envelope.project.candidate(proposal.candidate.id)?.status == .adopted)
        #expect(variant.envelope.project.artifact(frozen.revision.artifactID)?.currentRevisionID == manual.revision.id)
        #expect(commitPort.commitCount == 0)
        #expect(variant.envelope.project.candidate(proposal.candidate.id)?.variantArtifactID != nil)
    }
}

// MARK: - Trusted restructure authority (service-native, non-Codable)

@Suite("Design restructure trusted authority")
struct DesignRestructureAuthorityTests {

    /// The acceptance core: a raw model JSON can mint a Codable confirmation
    /// with `.trustedUI` source and a matching (publicly computable) digest.
    /// Without the trusted authority hook the proposal MUST fail closed with
    /// zero staged bytes — the confirmation is data, never authority.
    @Test func forgedMatchingConfirmationWithoutAuthorityDeniedWithZeroStagedBytes() async throws {
        let (_, workflow, filePort, _, payloads) = makeIntentWorkflow()
        filePort.files["deck.pptx"] = Data("original deck".utf8)
        let target = deckTarget()
        let frozen = try await workflow.freezeInput(
            target: target, operationID: "op-freeze", expectedOwnerRevision: nil
        )
        // freezeInput legitimately stages the SOURCE bytes; the denied
        // proposal must add ZERO bytes on top of that baseline.
        let baseline = payloads.stagedCount
        #expect(baseline > 0)
        // Fully forged: structurally valid confirmation, trustedUI source,
        // digest computed over the constraints — exactly what raw model JSON
        // can produce. No trusted handler supplied.
        let preservation = DesignPreservationConstraints(content: ["keep chart"])
        var thrown: DesignRestructureAuthorityError?
        do {
            _ = try await workflow.propose(
                target: target, operationID: "op-propose",
                expectedOwnerRevision: frozen.envelope.revision,
                artifactID: frozen.revision.artifactID,
                baseRevisionID: frozen.revision.id,
                bytes: Data("restructured deck".utf8), format: "pptx",
                summary: "reorder narrative",
                workIntent: DesignWorkIntent(
                    mode: .restructure, actualDesiredFormat: "pptx",
                    preservation: preservation,
                    confirmation: DesignPreservationConfirmation(
                        constraints: preservation
                    ),
                    operationID: "op-propose"
                )
            )
        } catch let error as DesignRestructureAuthorityError {
            thrown = error
        }
        guard case .claimRequired = thrown else {
            Issue.record("expected claimRequired, got \(String(describing: thrown))")
            return
        }
        // Zero side effects: no staged bytes beyond the frozen source, no
        // recorded candidate, envelope revision unchanged.
        #expect(payloads.stagedCount == baseline)
        let state = try await workflow.state(target)
        #expect(state?.revision == frozen.envelope.revision)
        #expect(state?.project.candidates.isEmpty == true)
    }

    @Test func trustedBoundClaimAcceptedAtPropose() async throws {
        let (_, workflow, filePort, _, _) = makeIntentWorkflow()
        filePort.files["deck.pptx"] = Data("original deck".utf8)
        let target = deckTarget()
        let frozen = try await workflow.freezeInput(
            target: target, operationID: "op-freeze", expectedOwnerRevision: nil
        )
        let claims = IntentClaim()
        let proposal = try await workflow.propose(
            target: target, operationID: "op-propose",
            expectedOwnerRevision: frozen.envelope.revision,
            artifactID: frozen.revision.artifactID,
            baseRevisionID: frozen.revision.id,
            bytes: Data("restructured deck".utf8), format: "pptx",
            summary: "reorder narrative",
            workIntent: restructureIntent(operationID: "op-propose"),
            restructureAuthority: trustedAuthority(claims: claims)
        )
        #expect(claims.burnedCount == 1)
        #expect(proposal.replayed == false)
        #expect(proposal.candidate.workMode == .restructure)
        #expect(proposal.candidate.preservationDigest != nil)
    }

    @Test func staleWrongOwnerOrMismatchedReceiptRefusedBeforeStaging() async throws {
        let preservation = DesignPreservationConstraints(content: ["keep chart"])
        let forgeries: [(String, @Sendable (DesignRestructureAuthorityRequest) -> DesignRestructureAuthorityRequest)] = [
            ("wrong owner", { r in
                DesignRestructureAuthorityRequest(
                    targetKey: "someone-else", operationID: r.operationID,
                    originalTaskOwnerID: r.originalTaskOwnerID,
                    baseRevisionID: r.baseRevisionID,
                    preservationDigest: r.preservationDigest)
            }),
            ("stale base revision", { r in
                DesignRestructureAuthorityRequest(
                    targetKey: r.targetKey, operationID: r.operationID,
                    originalTaskOwnerID: r.originalTaskOwnerID,
                    baseRevisionID: "rev-old",
                    preservationDigest: r.preservationDigest)
            }),
            ("re-bound constraints digest", { r in
                DesignRestructureAuthorityRequest(
                    targetKey: r.targetKey, operationID: r.operationID,
                    originalTaskOwnerID: r.originalTaskOwnerID,
                    baseRevisionID: r.baseRevisionID,
                    preservationDigest: DesignPreservationConstraints(content: ["other"]).canonicalDigest)
            }),
            ("different operation", { r in
                DesignRestructureAuthorityRequest(
                    targetKey: r.targetKey, operationID: "op-other",
                    originalTaskOwnerID: r.originalTaskOwnerID,
                    baseRevisionID: r.baseRevisionID,
                    preservationDigest: r.preservationDigest)
            }),
            ("wrong original task", { r in
                DesignRestructureAuthorityRequest(
                    targetKey: r.targetKey, operationID: r.operationID,
                    originalTaskOwnerID: "task-other",
                    baseRevisionID: r.baseRevisionID,
                    preservationDigest: r.preservationDigest)
            }),
        ]
        for (label, override) in forgeries {
            let (_, workflow, filePort, _, payloads) = makeIntentWorkflow()
            filePort.files["deck.pptx"] = Data("original deck".utf8)
            let target = deckTarget()
            let frozen = try await workflow.freezeInput(
                target: target, operationID: "op-freeze", expectedOwnerRevision: nil
            )
            let baseline = payloads.stagedCount
            var thrown: DesignRestructureAuthorityError?
            do {
                _ = try await workflow.propose(
                    target: target, operationID: "op-propose",
                    expectedOwnerRevision: frozen.envelope.revision,
                    artifactID: frozen.revision.artifactID,
                    baseRevisionID: frozen.revision.id,
                    bytes: Data("restructured deck".utf8), format: "pptx",
                    summary: "reorder narrative",
                    workIntent: DesignWorkIntent(
                        mode: .restructure, actualDesiredFormat: "pptx",
                        preservation: preservation,
                        confirmation: DesignPreservationConfirmation(
                            constraints: preservation
                        ),
                        operationID: "op-propose"
                    ),
                    restructureAuthority: trustedAuthority(
                        claims: IntentClaim(), override: override
                    )
                )
            } catch let error as DesignRestructureAuthorityError {
                thrown = error
            }
            guard case .claimMismatch = thrown else {
                Issue.record("\(label): expected claimMismatch, got \(String(describing: thrown))")
                continue
            }
            #expect(payloads.stagedCount == baseline)
            let state = try await workflow.state(target)
            #expect(state?.project.candidates.isEmpty == true)
        }

        // A trusted store that refuses the grant (expired/revoked/unknown)
        // propagates the refusal with zero staged bytes.
        let (_, workflow, filePort, _, payloads) = makeIntentWorkflow()
        filePort.files["deck.pptx"] = Data("original deck".utf8)
        let target = deckTarget()
        let frozen = try await workflow.freezeInput(
            target: target, operationID: "op-freeze", expectedOwnerRevision: nil
        )
        let baseline = payloads.stagedCount
        var refused = false
        do {
            _ = try await workflow.propose(
                target: target, operationID: "op-propose",
                expectedOwnerRevision: frozen.envelope.revision,
                artifactID: frozen.revision.artifactID,
                baseRevisionID: frozen.revision.id,
                bytes: Data("restructured deck".utf8), format: "pptx",
                summary: "reorder narrative",
                workIntent: restructureIntent(operationID: "op-propose"),
                restructureAuthority: { _ in
                    throw FloeError.validationFailed("grant store refused the claim")
                }
            )
        } catch FloeError.validationFailed {
            refused = true
        }
        #expect(refused)
        #expect(payloads.stagedCount == baseline)
    }

    @Test func engineProposeRejectsRestructureWithoutTrustedReceipt() throws {
        var project = DesignWorkflowEngine.createProject(
            nodeID: "node", contentType: .presentation
        )
        let artifact = DesignArtifact(
            contentType: .presentation,
            identity: DesignArtifactIdentity(name: "Deck", positionX: 0, positionY: 0, width: 0, height: 0)
        )
        DesignWorkflowEngine.addArtifact(artifact, to: &project)
        let base = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifact.id, contentSHA256: "sha-base", origin: .importFile
        )
        let preservation = DesignPreservationConstraints(content: ["keep chart"])
        let intent = DesignWorkIntent(
            mode: .restructure, actualDesiredFormat: "pptx",
            preservation: preservation,
            confirmation: DesignPreservationConfirmation(constraints: preservation),
            operationID: "op-restructure"
        )
        var thrown: DesignRestructureAuthorityError?
        do {
            _ = try DesignWorkflowEngine.proposeCandidate(
                in: &project, artifactID: artifact.id,
                proposedContentSHA256: "sha-proposed", summary: "reorder",
                workIntent: intent
            )
        } catch let error as DesignRestructureAuthorityError {
            thrown = error
        }
        guard case .claimRequired = thrown else {
            Issue.record("expected claimRequired, got \(String(describing: thrown))")
            return
        }
        // Fail closed with zero side effects: no revision, no candidate, and
        // not even the frozen-run desired-format stamping leaked.
        #expect(project.artifact(artifact.id)?.revisions.count == 1)
        #expect(project.artifact(artifact.id)?.revisions.first?.id == base.id)
        #expect(project.candidates.isEmpty)
        #expect(project.frozenRun == nil)
    }

    @Test func engineProposeRejectsForgedReceiptAndStaysClean() throws {
        var project = DesignWorkflowEngine.createProject(
            nodeID: "node", contentType: .presentation
        )
        let artifact = DesignArtifact(
            contentType: .presentation,
            identity: DesignArtifactIdentity(name: "Deck", positionX: 0, positionY: 0, width: 0, height: 0)
        )
        DesignWorkflowEngine.addArtifact(artifact, to: &project)
        _ = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifact.id, contentSHA256: "sha-base", origin: .importFile
        )
        let preservation = DesignPreservationConstraints(content: ["keep chart"])
        let intent = DesignWorkIntent(
            mode: .restructure, actualDesiredFormat: "pptx",
            preservation: preservation,
            confirmation: DesignPreservationConfirmation(constraints: preservation),
            operationID: "op-restructure"
        )
        // A receipt minted for a DIFFERENT operation/constraints/node — the
        // model layer cannot mint one at all, but a stale or cross-target
        // receipt from elsewhere must still be refused.
        let other = DesignWorkIntent(
            mode: .restructure, actualDesiredFormat: "pptx",
            preservation: DesignPreservationConstraints(content: ["other constraints"]),
            confirmation: DesignPreservationConfirmation(
                constraints: DesignPreservationConstraints(content: ["other constraints"])
            ),
            operationID: "op-other"
        )
        let forged = try engineReceipt(for: other, nodeID: "node", baseRevisionID: nil)
        var thrown: DesignRestructureAuthorityError?
        do {
            _ = try DesignWorkflowEngine.proposeCandidate(
                in: &project, artifactID: artifact.id,
                proposedContentSHA256: "sha-proposed", summary: "reorder",
                workIntent: intent, restructureReceipt: forged
            )
        } catch let error as DesignRestructureAuthorityError {
            thrown = error
        }
        guard case .claimMismatch = thrown else {
            Issue.record("expected claimMismatch, got \(String(describing: thrown))")
            return
        }
        #expect(project.candidates.isEmpty)
        #expect(project.frozenRun == nil)
    }

    @Test func engineProposeAcceptsBoundReceipt() throws {
        var project = DesignWorkflowEngine.createProject(
            nodeID: "node", contentType: .presentation
        )
        let artifact = DesignArtifact(
            contentType: .presentation,
            identity: DesignArtifactIdentity(name: "Deck", positionX: 0, positionY: 0, width: 0, height: 0)
        )
        DesignWorkflowEngine.addArtifact(artifact, to: &project)
        let base = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifact.id, contentSHA256: "sha-base", origin: .importFile
        )
        let preservation = DesignPreservationConstraints(content: ["keep chart"])
        let intent = DesignWorkIntent(
            mode: .restructure, actualDesiredFormat: "pptx",
            preservation: preservation,
            confirmation: DesignPreservationConfirmation(constraints: preservation),
            operationID: "op-restructure"
        )
        let candidate = try DesignWorkflowEngine.proposeCandidate(
            in: &project, artifactID: artifact.id,
            proposedContentSHA256: "sha-proposed", summary: "reorder",
            workIntent: intent,
            restructureReceipt: try engineReceipt(
                for: intent, nodeID: "node", baseRevisionID: base.id
            )
        )
        #expect(candidate.workMode == .restructure)
        #expect(candidate.preservationDigest == preservation.canonicalDigest)
        #expect(project.frozenRun?.desiredFormat == "pptx")
    }

    @Test func freezeSeamValidatesTrustedClaimBeforeGeneration() throws {
        var project = DesignWorkflowEngine.createProject(
            nodeID: "node", contentType: .presentation
        )
        let artifact = DesignArtifact(
            contentType: .presentation,
            identity: DesignArtifactIdentity(name: "Deck", positionX: 0, positionY: 0, width: 0, height: 0)
        )
        DesignWorkflowEngine.addArtifact(artifact, to: &project)
        let base = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifact.id, contentSHA256: "sha-base", origin: .importFile
        )
        let preservation = DesignPreservationConstraints(content: ["keep chart"])
        let intent = DesignWorkIntent(
            mode: .restructure, actualDesiredFormat: "pptx",
            preservation: preservation,
            confirmation: DesignPreservationConfirmation(constraints: preservation),
            operationID: "op-restructure"
        )
        // Wrong receipt: the run is NOT frozen — confirmation happens before
        // generation, not after.
        let other = DesignWorkIntent(
            mode: .restructure, actualDesiredFormat: "pptx",
            preservation: DesignPreservationConstraints(content: ["other"]),
            confirmation: DesignPreservationConfirmation(
                constraints: DesignPreservationConstraints(content: ["other"])
            ),
            operationID: "op-restructure"
        )
        var denied = false
        do {
            _ = try DesignWorkflowEngine.freezeRun(
                operationID: "op-freeze", in: &project,
                workIntent: intent,
                restructureReceipt: try engineReceipt(
                    for: other, nodeID: "node", baseRevisionID: base.id
                ),
                inputRevisionID: base.id
            )
        } catch DesignRestructureAuthorityError.claimMismatch {
            denied = true
        }
        #expect(denied)
        #expect(project.frozenRun == nil)

        // The genuine bound claim freezes the run with auditable evidence.
        let frozen = try DesignWorkflowEngine.freezeRun(
            operationID: "op-freeze", in: &project,
            workIntent: intent,
            restructureReceipt: try engineReceipt(
                for: intent, nodeID: "node", baseRevisionID: base.id
            ),
            inputRevisionID: base.id
        )
        #expect(frozen.workMode == .restructure)
        #expect(frozen.preservationDigest == preservation.canonicalDigest)
        #expect(frozen.desiredFormat == "pptx")
        #expect(frozen.inputRevisionID == base.id)
    }

    @Test func createAndModifyProposeWithoutAnyAuthority() async throws {
        // Owner path: a modify intent needs no trusted claim.
        let (_, workflow, filePort, _, _) = makeIntentWorkflow()
        filePort.files["deck.pptx"] = Data("original deck".utf8)
        let target = deckTarget()
        let frozen = try await workflow.freezeInput(
            target: target, operationID: "op-freeze", expectedOwnerRevision: nil
        )
        let proposal = try await workflow.propose(
            target: target, operationID: "op-propose",
            expectedOwnerRevision: frozen.envelope.revision,
            artifactID: frozen.revision.artifactID,
            baseRevisionID: frozen.revision.id,
            bytes: Data("tweaked deck".utf8), format: "pptx",
            summary: "tweak title",
            workIntent: DesignWorkIntent(
                mode: .modify, actualDesiredFormat: "pptx",
                scope: DesignWorkScope(objectIDs: ["title"]),
                operationID: "op-propose"
            )
        )
        #expect(proposal.candidate.workMode == .modify)
        #expect(proposal.candidate.preservationDigest == nil)

        // Engine path: create/modify proposals never consult authority, even
        // if a stray receipt parameter were supplied.
        var project = DesignWorkflowEngine.createProject(
            nodeID: "node", contentType: .presentation
        )
        let artifact = DesignArtifact(
            contentType: .presentation,
            identity: DesignArtifactIdentity(name: "Deck", positionX: 0, positionY: 0, width: 0, height: 0)
        )
        DesignWorkflowEngine.addArtifact(artifact, to: &project)
        let base = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifact.id, contentSHA256: "sha-base", origin: .importFile
        )
        let modify = DesignWorkIntent(
            mode: .modify, actualDesiredFormat: "pptx",
            scope: DesignWorkScope(objectIDs: ["title"]),
            operationID: "op-modify"
        )
        let candidate = try DesignWorkflowEngine.proposeCandidate(
            in: &project, artifactID: artifact.id,
            baseRevisionID: base.id,
            proposedContentSHA256: "sha-tweaked", summary: "tweak",
            workIntent: modify
        )
        #expect(candidate.workMode == .modify)
        #expect(candidate.preservationDigest == nil)
    }
}

// MARK: - Real capability matrix

@Suite("Design capability matrix")
struct DesignCapabilityMatrixTests {

    @Test func disconnectedMatrixReportsEveryCombinationUnavailable() {
        let matrix = DesignCapabilityMatrix(registry: .disconnected())
        let all = matrix.assessAll()
        #expect(all.isEmpty == false)
        #expect(all.allSatisfy { $0.available == false })
        #expect(all.allSatisfy { $0.reason?.isEmpty == false })
        // No static "ready": even the create×generate corner is false here.
        let create = matrix.assess(DesignCapabilityQuery(
            mode: .create, family: .presentation, operation: .generate
        ))
        #expect(create.available == false)
        #expect(create.reason != nil)
    }

    @Test func liveProbeVetoesStaticWiringWithHonestReason() {
        let registry = DesignCapabilityRegistry(capabilities: [
            .presentation: DesignAdapterCapability(
                contentType: .presentation,
                available: [.generate, .preview, .verifiedExport]
            )
        ])
        // Office-style session gate: static wiring exists, the live session
        // is what actually decides.
        let matrix = DesignCapabilityMatrix(registry: registry) { query in
            if query.family == .presentation,
               query.environment[DesignCapabilityEnvironmentKey.officeEngineSession.rawValue] != "connected" {
                return .unavailable(
                    reason: "the Office engine session is not connected",
                    recovery: "open the document in the editor"
                )
            }
            return .available()
        }
        let offline = matrix.assess(DesignCapabilityQuery(
            mode: .create, family: .presentation, operation: .generate
        ))
        #expect(offline.available == false)
        #expect(offline.reason?.contains("Office engine session") == true)
        #expect(offline.recovery != nil)

        let online = matrix.assess(DesignCapabilityQuery(
            mode: .create, family: .presentation, operation: .generate,
            environment: [DesignCapabilityEnvironmentKey.officeEngineSession.rawValue: "connected"]
        ))
        #expect(online.available == true)
        #expect(online.reason == nil)

        // An operation with no static wiring stays false even when live is fine.
        let unwired = matrix.assess(DesignCapabilityQuery(
            mode: .create, family: .presentation, operation: .editRegion,
            environment: [DesignCapabilityEnvironmentKey.officeEngineSession.rawValue: "connected"]
        ))
        #expect(unwired.available == false)
        #expect(unwired.reason != nil)
    }

    @Test func captureOperationsAreFlaggedSeparatelyFromGeneration() {
        let registry = DesignCapabilityRegistry(capabilities: [
            .webpage: DesignAdapterCapability(
                contentType: .webpage,
                available: [.generate, .importSource, .preview]
            )
        ])
        let matrix = DesignCapabilityMatrix(registry: registry, live: { _ in .available() })
        let capture = matrix.assess(DesignCapabilityQuery(
            mode: .create, family: .webpage, operation: .importSource
        ))
        #expect(capture.available == true)
        #expect(capture.isCaptureOperation == true)
        let generate = matrix.assess(DesignCapabilityQuery(
            mode: .create, family: .webpage, operation: .generate
        ))
        #expect(generate.isCaptureOperation == false)
    }

    @Test func workModesOfferDistinctOperationSets() {
        #expect(DesignCapabilityMatrix.operations(for: .create).contains(.generate))
        #expect(DesignCapabilityMatrix.operations(for: .create).contains(.importSource))
        #expect(DesignCapabilityMatrix.operations(for: .create).contains(.editRegion) == false)
        #expect(DesignCapabilityMatrix.operations(for: .modify).contains(.editRegion))
        #expect(DesignCapabilityMatrix.operations(for: .modify).contains(.generate) == false)
        #expect(DesignCapabilityMatrix.operations(for: .restructure).contains(.compareAdopt))
        #expect(DesignCapabilityMatrix.operations(for: .restructure).contains(.generate) == false)
    }
}

// MARK: - Canvas source classification (layout is never webpage)

@Suite("Canvas source classification")
struct DesignSourceClassificationTests {

    @Test func layoutNodesAreCompositionNotWebpage() {
        for kind in [CanvasNodeKind.card, .shape, .group, .audio, .generationTask] {
            #expect(DesignContentTypeMapper.contentType(for: kind) == .composition)
            #expect(DesignContentTypeMapper.contentType(for: kind) != .webpage)
        }
        // Real content kinds keep their typed families.
        #expect(DesignContentTypeMapper.contentType(for: .image) == .image)
        #expect(DesignContentTypeMapper.contentType(for: .text) == .notes)
        #expect(DesignContentTypeMapper.contentType(for: .file) == .pdf)
        #expect(DesignContentTypeMapper.contentType(for: .scene3D) == .cad)
    }

    @Test func builtinTextPluginsKeepRealTypes() {
        #expect(DesignContentTypeMapper.classification(
            format: nil, kind: .card,
            metadata: [DesignContentTypeMapper.builtinPluginMetadataKey: "markdown"]
        ) == .typed(.notes))
        #expect(DesignContentTypeMapper.classification(
            format: nil, kind: .card,
            metadata: [DesignContentTypeMapper.builtinPluginMetadataKey: "html"]
        ) == .typed(.webpage))
        #expect(DesignContentTypeMapper.classification(
            format: nil, kind: .card,
            metadata: [DesignContentTypeMapper.builtinPluginMetadataKey: "svg"]
        ) == .typed(.webpage))
        // An unknown plugin on a card is a layout object, not a webpage.
        #expect(DesignContentTypeMapper.classification(
            format: nil, kind: .card,
            metadata: [DesignContentTypeMapper.builtinPluginMetadataKey: "mystery"]
        ) == .composition)
        #expect(DesignContentTypeMapper.effectiveContentType(
            existing: nil, kind: .card,
            metadata: [DesignContentTypeMapper.builtinPluginMetadataKey: "html"]
        ) == .webpage)
        #expect(DesignContentTypeMapper.effectiveContentType(
            existing: nil, kind: .shape, metadata: [:]
        ) == .composition)
    }

    @Test func formatsClassifyTypedUnsupportedOrUnknown() {
        #expect(DesignContentTypeMapper.classification(
            format: "pptx", kind: nil, metadata: nil
        ) == .typed(.presentation))
        #expect(DesignContentTypeMapper.classification(
            format: "PPTX", kind: nil, metadata: nil
        ) == .typed(.presentation))
        #expect(DesignContentTypeMapper.classification(
            format: "zip", kind: nil, metadata: nil
        ) == .unsupported(format: "zip"))
        #expect(DesignContentTypeMapper.classification(
            format: "not-a-format", kind: nil, metadata: nil
        ) == .unknown)
        #expect(DesignContentTypeMapper.classification(
            format: nil, kind: .image, metadata: nil
        ) == .typed(.image))
        #expect(DesignContentTypeMapper.classification(
            format: nil, kind: nil, metadata: nil
        ) == .unknown)
    }

    @Test func captureOriginsAreNotGeneration() {
        #expect(DesignRevisionOrigin.importFile.isCapture)
        #expect(DesignRevisionOrigin.currentNode.isCapture)
        #expect(DesignRevisionOrigin.importFile.isGeneration == false)
        #expect(DesignRevisionOrigin.currentNode.isGeneration == false)
        #expect(DesignRevisionOrigin.generate.isGeneration)
        #expect(DesignRevisionOrigin.generate.isCapture == false)
        #expect(DesignRevisionOrigin.edit.isGeneration == false)
        #expect(DesignRevisionOrigin.edit.isCapture == false)
        #expect(DesignRevisionOrigin.variant.isCapture == false)
    }
}

private extension String {
    func repeated(toLength length: Int) -> String {
        guard length > 0 else { return "" }
        var result = ""
        while result.count < length { result += self }
        return String(result.prefix(length))
    }
}
