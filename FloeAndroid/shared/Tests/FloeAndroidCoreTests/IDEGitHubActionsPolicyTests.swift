// SPDX-License-Identifier: MPL-2.0
//
// IDEGitHubActionsPolicyTests — ported + extended coverage for the Android
// policy/store ports (provenance in the source files). The merge/reconciler/
// catalog cases come from the iOS IDEGitHubActionsTests @3fd597b (same
// assertions); the additional cases exercise the documented Android delta
// surface: the module-local path helpers and the accepted-storage store.
import Foundation
import FloeCore
import Testing
@testable import FloeAndroidCore

@Suite("IDEGitHubActionsPolicyTests")
struct IDEGitHubActionsPolicyTests {

    private func candidate(_ path: String, size: Int = 12, symlink: Bool = false,
                           regular: Bool = true, sha: String = "abc") -> IDEGitHubActionsSnapshotCandidate {
        IDEGitHubActionsSnapshotCandidate(path: path, isRegularFile: regular, isSymlink: symlink,
                                          byteCount: size, sha256: sha)
    }

    // MARK: - Ported originals

    @Test func storeMergePreservesCancelIntentAndDownloadMetadata() {
        var existing = GitHubActionsJobRecord(
            requestID: "req-merge", workspaceID: UUID(), environmentID: nil, workspaceRootPath: nil,
            languageID: "rust", role: "build", repositoryFullName: "o/r", owner: "o", repository: "r",
            baseRef: "main", runBranch: "floe-ide/x", workflowPath: ".github/workflows/a.yml",
            installsTemplate: true, expectedArtifactName: nil, snapshotCommitSHA: nil, snapshotTreeSHA: nil,
            snapshotFiles: [], snapshotTotalBytes: 0)
        existing.state = .running
        existing.cancelRequestedAt = Date(timeIntervalSince1970: 1_700_000_500)
        existing.cancelLastAttemptAt = Date(timeIntervalSince1970: 1_700_000_500)
        existing.runID = 90
        existing.artifacts = [GitHubActionsArtifactRecord(
            id: 1, name: "out", sizeInBytes: 10, expired: false, createdAt: Date(), expiresAt: nil,
            downloadedSHA256: "deadbeef", downloadedRelativePath: ".floe/artifacts/90/out.zip")]
        var stale = existing
        stale.cancelRequestedAt = nil
        stale.cancelLastAttemptAt = nil
        stale.state = .running
        stale.artifacts = [GitHubActionsArtifactRecord(
            id: 1, name: "out", sizeInBytes: 10, expired: false, createdAt: Date(), expiresAt: nil,
            downloadedSHA256: nil, downloadedRelativePath: nil)]
        let merged = GitHubActionsJobStore.merge(existing: existing, incoming: stale)
        #expect(merged.cancelRequestedAt != nil)
        #expect(merged.state == .cancelling)
        #expect(merged.artifacts.first?.downloadedSHA256 == "deadbeef")
        #expect(merged.artifacts.first?.downloadedRelativePath == ".floe/artifacts/90/out.zip")
    }

    @Test func storeMergeKeepsTerminalObservationMonotonic() {
        var terminal = GitHubActionsJobRecord(
            requestID: "req-terminal", workspaceID: nil, environmentID: nil, workspaceRootPath: nil,
            languageID: "go", role: "build", repositoryFullName: "o/r", owner: "o", repository: "r",
            baseRef: "main", runBranch: "floe-ide/y", workflowPath: nil, installsTemplate: false,
            expectedArtifactName: nil, snapshotCommitSHA: nil, snapshotTreeSHA: nil,
            snapshotFiles: [], snapshotTotalBytes: 0)
        terminal.runID = 77
        terminal.state = .completed
        terminal.remoteStatus = "completed"
        terminal.remoteConclusion = "success"
        terminal.remoteHTMLURL = "https://github.com/o/r/actions/runs/77"
        var stale = terminal
        stale.state = .running
        stale.remoteStatus = "in_progress"
        stale.remoteConclusion = nil
        stale.remoteHTMLURL = nil
        let merged = GitHubActionsJobStore.merge(existing: terminal, incoming: stale)
        #expect(merged.state == .completed)
        #expect(merged.remoteConclusion == "success")
        #expect(merged.remoteStatus == "completed")
        #expect(merged.remoteHTMLURL == "https://github.com/o/r/actions/runs/77")
    }

    @Test func recordWithoutSnapshotIsNeverAutoResubmitted() {
        var record = GitHubActionsJobRecord(
            requestID: "req-no-snapshot", workspaceID: nil, environmentID: nil, workspaceRootPath: nil,
            languageID: "c", role: "build", repositoryFullName: "o/r", owner: "o", repository: "r",
            baseRef: "main", runBranch: "floe-ide/z", workflowPath: nil, installsTemplate: false,
            expectedArtifactName: nil, snapshotCommitSHA: nil, snapshotTreeSHA: nil,
            snapshotFiles: [], snapshotTotalBytes: 0)
        record.state = .preparing
        #expect(IDEGitHubActionsReconciler.actions(for: record) == [.awaitingManualRedispatch])
        #expect(!IDEGitHubActionsReconciler.hasActionableStep(record))
    }

    @Test func legacyArtifactRecordDecodesMissingOptionalFields() throws {
        let legacy = """
        {"id":1,"name":"out","sizeInBytes":4,"expired":false,"createdAt":"2026-01-01T00:00:00Z","expiresAt":null}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let artifact = try decoder.decode(GitHubActionsArtifactRecord.self, from: Data(legacy.utf8))
        #expect(artifact.remoteDigest == nil)
        #expect(artifact.downloadVerified == nil)
        #expect(artifact.downloadedRelativePath == nil)
    }

    @Test func generatedWorkflowsKeepFileNamesOutOfShellSource() {
        for template in IDEGitHubActionsWorkflowCatalog.templates {
            let yaml = template.yaml
            let inputLines = yaml.split(separator: "\n").filter { $0.contains("${{ inputs.target_file }}") }
            #expect(inputLines.count == 1)
            #expect(inputLines.first?.trimmingCharacters(in: .whitespaces) == "FLOE_TARGET_FILE: ${{ inputs.target_file }}")
            #expect(yaml.contains("\"./$FLOE_TARGET_FILE\""))
            #expect(yaml.contains("permissions:\n  contents: read"))
            #expect(yaml.contains("ref: ${{ inputs.snapshot_sha }}"))
            #expect(yaml.contains("persist-credentials: false"))
            #expect(!yaml.contains("actions/checkout@v4"))
            #expect(!yaml.contains("actions/upload-artifact@v4"))
        }
    }

    // MARK: - Snapshot policy

    @Test func snapshotManifestFiltersSecretsGitAndOversizedWithTypedExclusions() throws {
        let manifest = try IDEGitHubActionsSnapshotPolicy.manifest(candidates: [
            candidate("src/main.rs"),
            candidate(".git/config"),
            candidate(".env.production"),
            candidate("secrets/id_ed25519"),
            candidate("keys/signing.pem"),
            candidate("link", symlink: true),
            candidate("device", regular: false),
            candidate("big.mp4", size: IDEGitHubActionsSnapshotPolicy.maximumFileBytes + 1),
            candidate(".floe/artifacts/9/out.zip"),
        ])
        #expect(manifest.entries.map(\.path) == ["src/main.rs"])
        let reasons = manifest.excluded.map { "\($0)" }
        #expect(reasons.contains { $0.contains("gitMetadata") })
        #expect(reasons.contains { $0.contains("secretFile") })
        #expect(reasons.contains { $0.contains("symlink") })
        #expect(reasons.contains { $0.contains("notRegularFile") })
        #expect(reasons.contains { $0.contains("fileTooLarge") })
        #expect(reasons.contains { $0.contains("generatedArtifact") })
    }

    @Test func snapshotManifestEmptyIsTypedError() {
        #expect(throws: IDEGitHubActionsSnapshotError.empty) {
            _ = try IDEGitHubActionsSnapshotPolicy.manifest(candidates: [candidate(".git/config")])
        }
    }

    @Test func snapshotSkipDirectoriesAreTheReviewedSet() {
        #expect(IDEGitHubActionsSnapshotPolicy.isSnapshotSkipDirectory(".git"))
        #expect(IDEGitHubActionsSnapshotPolicy.isSnapshotSkipDirectory("node_modules"))
        #expect(!IDEGitHubActionsSnapshotPolicy.isSnapshotSkipDirectory("src"))
    }

    // MARK: - Path helpers (Android delta 1 fidelity)

    @Test func safePathMatchesOriginalAlgorithm() {
        #expect(IDEGitHubActionsSafePath.isSafeWorkspaceRelativePath("src/main.rs"))
        #expect(IDEGitHubActionsSafePath.isSafeWorkspaceRelativePath("a/b/c.txt"))
        #expect(!IDEGitHubActionsSafePath.isSafeWorkspaceRelativePath("/etc/passwd"))
        #expect(!IDEGitHubActionsSafePath.isSafeWorkspaceRelativePath("~/escape"))
        #expect(!IDEGitHubActionsSafePath.isSafeWorkspaceRelativePath("a/../b"))
        #expect(!IDEGitHubActionsSafePath.isSafeWorkspaceRelativePath("a//b"))
        #expect(!IDEGitHubActionsSafePath.isSafeWorkspaceRelativePath("bad\u{7}name"))
    }

    @Test func runBranchSanitizesLikeTheOriginalTokenRule() {
        #expect(IDEGitHubActionsSnapshotPolicy.runBranch(runToken: "ab'; rm -rf /;'") == "floe-ide/abrm-rf")
        let long = String(repeating: "x", count: 120)
        #expect(IDEGitHubActionsSnapshotPolicy.runBranch(runToken: long).count <= "floe-ide/".count + 48)
        #expect(IDEGitHubActionsSnapshotPolicy.runBranch(runToken: "!!!") == "floe-ide/run")
    }

    // MARK: - Installation contract

    @Test func installationDecisionNeverOverwritesDivergentFiles() {
        #expect(IDEGitHubActionsWorkflowInstallationPolicy.decision(
            existingSHA256: nil, templateSHA256: "t", templatePath: ".github/workflows/f.yml",
            existingPaths: []) == .install)
        #expect(IDEGitHubActionsWorkflowInstallationPolicy.decision(
            existingSHA256: "t", templateSHA256: "t", templatePath: ".github/workflows/f.yml",
            existingPaths: [".github/workflows/f.yml"]) == .alreadyInstalled)
        let conflict = IDEGitHubActionsWorkflowInstallationPolicy.decision(
            existingSHA256: "other", templateSHA256: "t", templatePath: ".github/workflows/f.yml",
            existingPaths: [".github/workflows/f.yml", ".github/workflows/f-floe.yml"])
        if case .conflict(let suggested) = conflict {
            #expect(suggested == ".github/workflows/f-floe2.yml")
        } else { Issue.record("expected a conflict"); return }
        #expect(IDEGitHubActionsWorkflowInstallationPolicy.isFloeGenerated(
            IDEGitHubActionsWorkflowCatalog.template(id: "build.rust")!.yaml))
    }

    @Test func workflowPathGrammarIsClosed() {
        #expect(IDEGitHubActionsWorkflowCatalog.isWorkflowPath(".github/workflows/ci.yml"))
        #expect(IDEGitHubActionsWorkflowCatalog.isWorkflowPath(".github/workflows/ci.yaml"))
        #expect(!IDEGitHubActionsWorkflowCatalog.isWorkflowPath(".github/workflows/nested/x.yml"))
        #expect(!IDEGitHubActionsWorkflowCatalog.isWorkflowPath("src/main.yml"))
        #expect(!IDEGitHubActionsWorkflowCatalog.isWorkflowPath(".github/workflows/x.sh"))
    }

    // MARK: - Artifact policy

    @Test func artifactDestinationIsDeterministicAndContained() {
        let destination = IDEGitHubActionsArtifactPolicy.destination(
            runID: 90, suggestedFileName: "my build@v2.zip", overwrite: false)
        #expect(destination.relativePath == ".floe/artifacts/90/my_build@v2.zip".replacingOccurrences(of: "@", with: "_"))
        #expect(IDEGitHubActionsArtifactPolicy.isSafeDestination(destination.relativePath))
        #expect(!IDEGitHubActionsArtifactPolicy.isSafeDestination("../outside.zip"))
        #expect(!IDEGitHubActionsArtifactPolicy.isSafeDestination("src/app.zip"))
        #expect(!IDEGitHubActionsArtifactPolicy.isSafeDestination(".floe/artifacts/9/../../secret"))
    }

    @Test func digestNormalizationAndFailClosedVerify() {
        #expect(IDEGitHubActionsArtifactPolicy.normalizedSHA256("sha256:ABC\u{20}") == "abc")
        #expect(IDEGitHubActionsArtifactPolicy.normalizedSHA256(nil) == nil)
        #expect(IDEGitHubActionsArtifactPolicy.normalizedSHA256("   ") == nil)
        // A missing expectation fails CLOSED: unverified bytes must never be
        // presented as a verified download.
        #expect(!IDEGitHubActionsArtifactPolicy.verify(data: Data("x".utf8), expectedSHA256: nil,
                                                        sha256: { _ in "abc" }))
        // The attested `sha256:<hex>` form enters the pipeline through
        // `normalizedSHA256` FIRST — the exact composition both production
        // engines run (Android GitHubActionsJobEngine.swift:830-834 and the
        // mirrored iOS GitHubActionsJobEngine.swift:819-824): the attestation
        // is normalized, then `verify` compares bare lowercase hex. The
        // original one-shot expectation asked `verify` to accept the raw
        // prefixed form directly, a contract the mirrored iOS policy
        // (FloeAgent/FloeApp/Workspace/IDEGitHubActionsPolicy.swift:900-930,
        // byte-identical to this port) never provided.
        #expect(IDEGitHubActionsArtifactPolicy.verify(
            data: Data("x".utf8),
            expectedSHA256: IDEGitHubActionsArtifactPolicy.normalizedSHA256("sha256:abc"),
            sha256: { _ in "abc" }))
        // Fail-closed strictness kept honest: a caller that skipped
        // normalization must NOT get a match — "abc" never equals the raw
        // "sha256:abc" string, so unverified bytes cannot be presented as
        // verified.
        #expect(!IDEGitHubActionsArtifactPolicy.verify(data: Data("x".utf8),
                                                       expectedSHA256: "sha256:abc",
                                                       sha256: { _ in "abc" }))
    }

    // MARK: - Accepted-storage store behavior (Android delta 2)

    @Test func explicitDirectoryStoreRoundTripsAndReportsCorruption() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-gha-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GitHubActionsJobStore(directory: directory)
        // The durable format is ISO8601 whole-second JSON (GitHubActionsJobStore
        // encoder/decoder strategies) and the store OWNS the save-time
        // `updatedAt` stamp — every durable write re-stamps it, the same
        // contract the passing engine-test harness fake mirrors
        // (GitHubActionsJobEngineTests.swift:127-136). So the fixture pins its
        // caller timestamps to whole seconds (those must round-trip exactly)
        // and compares the read-back against the ORIGINAL record field for
        // field, with the single store-owned `updatedAt` stamp aligned first.
        // A whole-value `contains(record)` on a `Date()`-created record could
        // never be satisfiable through this store and was the wrong premise.
        let stamp = Date(timeIntervalSince1970: 1_700_000_300)
        let record = GitHubActionsJobRecord(
            requestID: "req-round", workspaceID: UUID(), environmentID: nil,
            workspaceRootPath: "/task/root", languageID: "swift", role: "build",
            repositoryFullName: "o/r", owner: "o", repository: "r", baseRef: "main",
            runBranch: "floe-ide/round", workflowPath: ".github/workflows/s.yml",
            installsTemplate: false, expectedArtifactName: nil, snapshotCommitSHA: nil,
            snapshotTreeSHA: nil, snapshotFiles: [], snapshotTotalBytes: 0, state: .completed,
            createdAt: stamp, updatedAt: stamp)
        try await store.save(record)
        let loaded = try await store.load()
        let stored = try #require(loaded.records.first { $0.id == record.id })
        #expect(loaded.corruptFiles.isEmpty)
        var expected = record
        expected.updatedAt = stored.updatedAt  // store-owned write stamp, not caller data
        #expect(stored == expected)            // every other field byte-exact, createdAt included
        // A half-written file is REPORTED, never silently dropped or rewritten.
        try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.json"))
        let again = try await store.load()
        #expect(again.corruptFiles == ["broken.json"])
        let againStored = try #require(again.records.first { $0.id == record.id })
        // The good record survives the corrupt read unchanged — no rewrite.
        #expect(againStored == stored)
        // Idempotency lookup by intent.
        let byIntent = try await store.record(requestID: "req-round")
        #expect(byIntent?.id == record.id)
    }
}
