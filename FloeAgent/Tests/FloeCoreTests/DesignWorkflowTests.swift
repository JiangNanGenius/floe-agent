import Foundation
import Testing
@testable import FloeCore

@Suite("Design workflow")
struct DesignWorkflowTests {

    private func makeProject() -> DesignProject {
        DesignWorkflowEngine.createProject(
            nodeID: "node-1",
            contentType: .webpage,
            brief: DesignBrief(goal: "Landing page for Floe", audience: "iPad developers"),
            spec: DesignSpec(palette: ["#111111", "#FFFFFF"], typography: "SF Pro")
        )
    }

    private func makeArtifact() -> DesignArtifact {
        DesignArtifact(
            contentType: .webpage,
            identity: DesignArtifactIdentity(name: "Hero", positionX: 10, positionY: 20, width: 300, height: 200, connections: ["node-b"])
        )
    }

    @Test func freezeRunPinsSpecAndInputs() throws {
        var project = makeProject()
        let artifact = makeArtifact()
        DesignWorkflowEngine.addArtifact(artifact, to: &project)
        let revision = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifact.id, contentSHA256: "sha-a", origin: .importFile
        )
        let frozen = DesignWorkflowEngine.freezeRun(
            operationID: "op-1", in: &project, inputRevisionID: revision.id, targetRevisionID: artifact.id
        )
        #expect(frozen.specSHA256 == project.spec?.sha256)
        #expect(frozen.inputRevisionID == revision.id)
        #expect(project.frozenRun == frozen)
    }

    @Test func candidateDoesNotApplyUntilAdopted() throws {
        var project = makeProject()
        let artifact = makeArtifact()
        DesignWorkflowEngine.addArtifact(artifact, to: &project)
        let base = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifact.id, contentSHA256: "sha-base", origin: .importFile
        )
        let candidate = try DesignWorkflowEngine.proposeCandidate(
            in: &project, artifactID: artifact.id, proposedContentSHA256: "sha-proposed", summary: "AI edit"
        )
        // Still on the base revision until the user adopts.
        #expect(project.artifact(artifact.id)?.currentRevisionID == base.id)
        #expect(project.candidate(candidate.id)?.status == .pending)

        let adopted = try DesignWorkflowEngine.adoptCandidate(in: &project, candidateID: candidate.id)
        #expect(adopted.identity == artifact.identity)
        #expect(adopted.currentRevisionID == candidate.proposedRevisionID)
        #expect(adopted.revision(candidate.proposedRevisionID)?.origin == .adopt)
        #expect(project.candidate(candidate.id)?.status == .adopted)
    }

    @Test func proposeWithoutChangeIsRejected() throws {
        var project = makeProject()
        let artifact = makeArtifact()
        DesignWorkflowEngine.addArtifact(artifact, to: &project)
        _ = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifact.id, contentSHA256: "same", origin: .importFile
        )
        #expect(throws: DesignWorkflowError.noActualChange) {
            try DesignWorkflowEngine.proposeCandidate(
                in: &project, artifactID: artifact.id, proposedContentSHA256: "same", summary: "noop"
            )
        }
    }

    @Test func variantAdoptionBranchesWithoutTouchingOriginal() throws {
        var project = makeProject()
        let artifact = makeArtifact()
        DesignWorkflowEngine.addArtifact(artifact, to: &project)
        let base = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifact.id, contentSHA256: "sha-base", origin: .importFile
        )
        let candidate = try DesignWorkflowEngine.proposeCandidate(
            in: &project, artifactID: artifact.id, proposedContentSHA256: "sha-variant", summary: "variant"
        )
        let variant = try DesignWorkflowEngine.adoptCandidate(
            in: &project, candidateID: candidate.id, mode: .variant
        )
        #expect(variant.id != artifact.id)
        #expect(project.artifact(artifact.id)?.currentRevisionID == base.id)
        #expect(project.artifact(artifact.id)?.branches[candidate.proposedRevisionID] == variant.id)
        #expect(project.candidate(candidate.id)?.variantArtifactID == variant.id)
    }

    @Test func anchorsGoStaleOnRevisionChangeAndCanBeRelocated() throws {
        var project = makeProject()
        let artifact = makeArtifact()
        DesignWorkflowEngine.addArtifact(artifact, to: &project)
        let first = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifact.id, contentSHA256: "v1", origin: .importFile
        )
        let feedback = try DesignWorkflowEngine.addFeedback(
            in: &project, artifactID: artifact.id,
            anchor: .region(x: 5, y: 5, width: 10, height: 10),
            comment: "Make it bolder", author: .user
        )
        #expect(feedback.status == .open)

        let second = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifact.id, contentSHA256: "v2", origin: .edit, expectedRevisionID: first.id
        )
        #expect(project.feedback(feedback.id)?.status == .staleAnchor)

        try DesignWorkflowEngine.relocateAnchor(
            in: &project, feedbackID: feedback.id,
            anchor: .region(x: 6, y: 6, width: 10, height: 10), toRevisionID: second.id
        )
        #expect(project.feedback(feedback.id)?.status == .open)
        #expect(project.feedback(feedback.id)?.revisionID == second.id)
    }

    @Test func resolveFeedbackRequiresActualChangeAtCurrentRevision() throws {
        var project = makeProject()
        let artifact = makeArtifact()
        DesignWorkflowEngine.addArtifact(artifact, to: &project)
        let first = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifact.id, contentSHA256: "v1", origin: .importFile
        )
        let feedback = try DesignWorkflowEngine.addFeedback(
            in: &project, artifactID: artifact.id,
            anchor: .objectID("layer-1"), comment: "align", author: .user
        )
        // Resolving against the same revision (no change) must fail.
        #expect(throws: DesignWorkflowError.noActualChange) {
            try DesignWorkflowEngine.resolveFeedback(
                in: &project, feedbackID: feedback.id, resolvedByRevisionID: first.id
            )
        }
        // A stale revision is not the current one.
        let second = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifact.id, contentSHA256: "v2", origin: .edit, expectedRevisionID: first.id
        )
        try DesignWorkflowEngine.resolveFeedback(
            in: &project, feedbackID: feedback.id, resolvedByRevisionID: second.id
        )
        #expect(project.feedback(feedback.id)?.status == .solved)
        #expect(project.feedback(feedback.id)?.resolvedByRevisionID == second.id)
    }

    @Test func revisionConflictIsRejected() throws {
        var project = makeProject()
        let artifact = makeArtifact()
        DesignWorkflowEngine.addArtifact(artifact, to: &project)
        let first = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifact.id, contentSHA256: "v1", origin: .importFile
        )
        #expect(throws: DesignWorkflowError.self) {
            try DesignWorkflowEngine.registerRevision(
                in: &project, artifactID: artifact.id,
                contentSHA256: "v2", origin: .edit, expectedRevisionID: "not-current"
            )
        }
        // The failed attempt left the artifact untouched.
        #expect(project.artifact(artifact.id)?.currentRevisionID == first.id)
    }

    @Test func restoreRevisionIsRecoverable() throws {
        var project = makeProject()
        let artifact = makeArtifact()
        DesignWorkflowEngine.addArtifact(artifact, to: &project)
        let first = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifact.id, contentSHA256: "v1", origin: .importFile
        )
        let second = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifact.id, contentSHA256: "v2", origin: .edit, expectedRevisionID: first.id
        )
        let restored = try DesignWorkflowEngine.restoreRevision(
            in: &project, artifactID: artifact.id, revisionID: first.id
        )
        #expect(restored.origin == .restore)
        #expect(restored.parentRevisionID == second.id)
        #expect(project.artifact(artifact.id)?.currentRevisionID == restored.id)
        // History still contains both originals: nothing is destroyed.
        #expect(project.artifact(artifact.id)?.revision(first.id) != nil)
        #expect(project.artifact(artifact.id)?.revision(second.id) != nil)
    }

    @Test func rejectCandidateKeepsArtifactUnchanged() throws {
        var project = makeProject()
        let artifact = makeArtifact()
        DesignWorkflowEngine.addArtifact(artifact, to: &project)
        let base = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifact.id, contentSHA256: "base", origin: .importFile
        )
        let candidate = try DesignWorkflowEngine.proposeCandidate(
            in: &project, artifactID: artifact.id, proposedContentSHA256: "proposal", summary: "x"
        )
        try DesignWorkflowEngine.rejectCandidate(in: &project, candidateID: candidate.id)
        #expect(project.candidate(candidate.id)?.status == .rejected)
        #expect(project.artifact(artifact.id)?.currentRevisionID == base.id)
    }
}

@Suite("DESIGN.md codec")
struct DesignMDCodecTests {
    @Test func parsesKnownSections() {
        let md = """
        # My Design

        Some intro prose.

        ## Palette
        - #0A0A0A
        - #FFFFFF

        ## Typography
        SF Pro, 17pt body.

        ## Prohibitions
        - no stock photos
        """
        let spec = DesignMDCodec.parse(md)
        #expect(spec.palette == ["#0A0A0A", "#FFFFFF"])
        #expect(spec.typography == "SF Pro, 17pt body.")
        #expect(spec.prohibitions == ["no stock photos"])
    }

    @Test func preservesUnknownSectionsAndPreamble() {
        let md = """
        # Brand Guide
        Keep this line.

        ## Palette
        - #123456

        ## Custom Internal Notes
        This section is unknown and must survive untouched.
        - item a
        - item b

        ## Motion
        Ease-out 200ms.
        """
        let spec = DesignMDCodec.parse(md)
        let exported = DesignMDCodec.export(spec)
        #expect(exported.contains("Keep this line."))
        #expect(exported.contains("## Custom Internal Notes"))
        #expect(exported.contains("This section is unknown and must survive untouched."))
        #expect(exported.contains("- item a"))
        #expect(exported.contains("## Motion"))
        #expect(exported.contains("Ease-out 200ms."))
        // Round-trip stability.
        let reparsed = DesignMDCodec.parse(exported)
        #expect(DesignMDCodec.export(reparsed) == exported)
        #expect(DesignMDCodec.sha256(of: reparsed) == DesignMDCodec.sha256(of: spec))
    }

    @Test func specHashIsStableAndChangesWithContent() {
        let a = DesignSpec(palette: ["#000000"])
        let b = DesignSpec(palette: ["#000000"])
        let c = DesignSpec(palette: ["#FFFFFF"])
        #expect(DesignMDCodec.sha256(of: a) == DesignMDCodec.sha256(of: b))
        #expect(DesignMDCodec.sha256(of: a) != DesignMDCodec.sha256(of: c))
    }
}

@Suite("Design canvas metadata binding")
struct DesignCanvasMetadataTests {
    @Test func roundTripAndBindingEnforced() throws {
        var project = DesignWorkflowEngine.createProject(nodeID: "node-a", contentType: .image)
        let artifact = DesignArtifact(
            contentType: .image,
            canvasNodeID: "node-a",
            identity: DesignArtifactIdentity(name: "Hero", positionX: 0, positionY: 0, width: 10, height: 10)
        )
        DesignWorkflowEngine.addArtifact(artifact, to: &project)
        _ = try DesignWorkflowEngine.registerRevision(
            in: &project,
            artifactID: artifact.id,
            contentSHA256: "rev-1",
            origin: .importFile
        )
        let raw = try DesignCanvasMetadata.encode(project)
        let decoded = try #require(try DesignCanvasMetadata.decode(raw, nodeID: "node-a"))
        #expect(decoded.nodeID == "node-a")
        #expect(decoded.artifacts.count == 1)

        // Binding mismatch fails closed.
        #expect(throws: DesignCanvasMetadata.CodecError.self) {
            _ = try DesignCanvasMetadata.decode(raw, nodeID: "node-b")
        }
        // Malformed fails closed.
        #expect(throws: DesignCanvasMetadata.CodecError.self) {
            _ = try DesignCanvasMetadata.decode("{not json", nodeID: "node-a")
        }
        // Absent is nil, not an error.
        #expect(try DesignCanvasMetadata.decode(nil, nodeID: "node-a") == nil)
    }

    @Test func newerSchemaRejected() throws {
        let raw = #"{"appliedOperationIDs":[],"artifacts":[],"candidates":[],"contentType":"image","createdAt":"2026-01-01T00:00:00Z","feedback":[],"nodeID":"node-a","schemaVersion":99,"updatedAt":"2026-01-01T00:00:00Z"}"#
        do {
            _ = try DesignCanvasMetadata.decode(raw, nodeID: "node-a")
            Issue.record("expected newerSchema")
        } catch let error as DesignCanvasMetadata.CodecError {
            guard case .newerSchema(let found, _) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(found == 99)
        }
    }

    @Test func operationIDDedup() throws {
        var project = DesignWorkflowEngine.createProject(nodeID: "node-a", contentType: .image)
        #expect(DesignWorkflowEngine.recordOperation("op-1", in: &project) == true)
        #expect(project.hasApplied(operationID: "op-1"))
        // Replay is rejected.
        #expect(DesignWorkflowEngine.recordOperation("op-1", in: &project) == false)
        #expect(project.appliedOperationIDs == ["op-1"])
    }
}

@Suite("Design adapter capabilities")
struct DesignCapabilityTests {
    @Test func everyUnavailableOperationCarriesAReason() {
        let capability = DesignAdapterCapability(
            contentType: .video,
            available: [.importSource]
        )
        #expect(capability.supports(.importSource))
        #expect(!capability.supports(.verifiedExport))
        #expect(capability.reason(for: .importSource) == nil)
        for operation in DesignOperation.allCases where operation != .importSource {
            #expect(capability.reason(for: operation)?.isEmpty == false)
        }
    }

    @Test func disconnectedRegistryIsHonest() {
        let registry = DesignCapabilityRegistry.disconnected()
        for type in DesignContentType.allCases {
            let capability = registry.capability(for: type)
            #expect(capability.available.isEmpty)
            for operation in DesignOperation.allCases {
                #expect(registry.reason(operation, for: type)?.isEmpty == false)
            }
        }
        #expect(!registry.supports(.preview, for: .webpage))
    }

    @Test func onlyConnectedOperationsAreAdvertised() {
        let registry = DesignCapabilityRegistry(capabilities: [
            .webpage: DesignAdapterCapability(
                contentType: .webpage,
                available: [.importSource, .preview, .sourceExport],
                unavailableReasons: [.generate: "No webpage generator is connected"]
            )
        ])
        #expect(registry.supports(.preview, for: .webpage))
        #expect(registry.supports(.sourceExport, for: .webpage))
        #expect(!registry.supports(.generate, for: .webpage))
        #expect(registry.reason(.generate, for: .webpage) == "No webpage generator is connected")
        #expect(!registry.supports(.preview, for: .cad))
    }
}
