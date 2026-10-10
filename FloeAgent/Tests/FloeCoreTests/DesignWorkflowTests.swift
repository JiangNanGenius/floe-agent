import Foundation
import Testing
@testable import FloeCore

@Suite("Design workflow")
struct DesignWorkflowTests {

    private func makeProject() -> DesignProject {
        DesignWorkflowEngine.createProject(
            canvasID: "canvas-1",
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
