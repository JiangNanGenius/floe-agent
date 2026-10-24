// SPDX-License-Identifier: MPL-2.0
//
// G04GitActionsDomainTests — lane-owned honesty surface for the durable
// Actions composition: the frozen wire action grammar (no new V3 outer keys;
// the action-level `Arguments` grammar is the ONLY thing extended), the
// reviewed-manifest canonical digest, the bounded regular-file publish
// reader, and the policy-filtered snapshot walk over a REAL temporary
// workspace through the ORIGINAL WorkspaceFileService/WorkspacePathGuard.
// Everything network- or composition-bound (live epoch, vault, GitHub) is
// deliberately NOT faked here; it is exercised by Main's grouped cohort.
import Foundation
import FloeCore
import FloeGit
import FloeWorkspace
import Testing
@testable import FloeAndroidCore

@Suite("G04GitActionsDomainTests")
struct G04GitActionsDomainTests {

    typealias Value = SettingsDomainV1.JSONValue

    private func arguments(_ fields: [String: Value], write: Bool, action: String = "actions.dispatch") throws -> G04WorkspaceGit.Arguments {
        try G04WorkspaceGit.Arguments(action: action, values: fields, write: write)
    }

    // MARK: - Frozen action grammar

    @Test func dispatchGrammarIsTheReviewedEngineIntent() throws {
        let digest = String(repeating: "a", count: 64)
        let ok = try arguments([
            "owner": .string("octo"), "repository": .string("demo"),
            "workflowPath": .string(".github/workflows/floe-build-rust.yml"),
            "requestID": .string("req-200"), "languageID": .string("rust"),
            "role": .string("build"), "platform": .string("linux"),
            "targetFile": .string("src/main.rs"), "reviewedManifestSHA": .string(digest),
            "inputs": .object([:]),
        ], write: true)
        #expect(ok.values["requestID"] != nil)
        // The pre-engine raw (owner, workflowID, reference, headSHA) shape is
        // GONE from this action: it cannot bypass the durable engine.
        #expect(throws: G04WorkspaceGit.Failure.invalidArguments) {
            _ = try self.arguments([
                "owner": .string("octo"), "repository": .string("demo"),
                "workflowID": .integer(7), "reference": .string("main"),
                "headSHA": .string("deadbeef"),
            ], write: true)
        }
        // Dispatch is never a read-family action.
        #expect(throws: G04WorkspaceGit.Failure.invalidArguments) {
            _ = try self.arguments([
                "owner": .string("octo"), "repository": .string("demo"),
                "workflowPath": .string(".github/workflows/f.yml"),
                "requestID": .string("r"), "languageID": .string("rust"),
                "role": .string("build"), "platform": .string("linux"),
                "reviewedManifestSHA": .string(digest),
            ], write: false)
        }
    }

    @Test func newDurableReadActionsFitTheReadFamilyOnly() throws {
        for name in G04GitActionsDomain.durableReads {
            #expect(G04WorkspaceGit.Arguments.reads.contains(name), "\(name) must ride gitQuery")
            #expect(throws: G04WorkspaceGit.Failure.invalidArguments) {
                _ = try self.arguments([:], write: true, action: name)
            }
            _ = try self.arguments([:], write: false, action: name)
        }
        for name in G04GitActionsDomain.durableWrites {
            #expect(!G04WorkspaceGit.Arguments.reads.contains(name))
            #expect(throws: G04WorkspaceGit.Failure.invalidArguments) {
                _ = try self.arguments([:], write: false, action: name)
            }
        }
    }

    @Test func reviewedDigestFieldRejectsMalformedShapes() throws {
        let base: [String: Value] = [
            "owner": .string("octo"), "repository": .string("demo"),
            "workflowPath": .string(".github/workflows/f.yml"),
            "requestID": .string("req"), "languageID": .string("go"),
            "role": .string("build"), "platform": .string("linux"),
        ]
        // The grammar accepts the KEY; the digest SHAPE is validated at the
        // engine boundary via `digestLike` — malformed values must throw there.
        let bad = try self.arguments(base.merging(["reviewedManifestSHA": .string("nope")]) { $1 }, write: true)
        #expect(throws: G04WorkspaceGit.Failure.invalidArguments) { _ = try bad.digestLike("reviewedManifestSHA") }
        let caps = try self.arguments(base.merging(["reviewedManifestSHA": .string(String(repeating: "A", count: 64))]) { $1 }, write: true)
        #expect(throws: G04WorkspaceGit.Failure.invalidArguments) { _ = try caps.digestLike("reviewedManifestSHA") }
        let good = try self.arguments(base.merging(["reviewedManifestSHA": .string(String(repeating: "f", count: 64))]) { $1 }, write: true)
        #expect(try good.digestLike("reviewedManifestSHA") == String(repeating: "f", count: 64))
    }

    // MARK: - Canonical manifest digest + value shape

    @Test func manifestDigestIsCanonicalAndSensitiveToContent() {
        let rows = [IDEGitHubActionsSnapshotEntry(path: "a.txt", byteCount: 1, sha256: "s1"),
                    IDEGitHubActionsSnapshotEntry(path: "b.txt", byteCount: 2, sha256: "s2")]
        let first = IDEGitHubActionsSnapshotManifest(entries: rows, totalBytes: 3, excluded: [.symlink])
        let second = IDEGitHubActionsSnapshotManifest(entries: rows, totalBytes: 3, excluded: [.symlink])
        #expect(G04GitActionsDomain.manifestDigest(first) == G04GitActionsDomain.manifestDigest(second))
        let changed = IDEGitHubActionsSnapshotManifest(
            entries: first.entries.map { e in
                IDEGitHubActionsSnapshotEntry(path: e.path, byteCount: e.byteCount + 1, sha256: e.sha256)
            },
            totalBytes: 4, excluded: first.excluded)
        #expect(G04GitActionsDomain.manifestDigest(changed) != G04GitActionsDomain.manifestDigest(first))
        let value = G04GitActionsDomain.manifestValue(first)
        guard case .object(let object) = value, case .array(let entries)? = object["entries"] else {
            Issue.record("manifest must expose entries"); return
        }
        #expect(entries.count == 2)
        #expect(object["fileCount"] == .integer(2))
    }

    // MARK: - Bounded regular-file publish reader

    @Test func readRegularFileRefusesNonRegularAndOversizedBeforeBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-gha-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("exactly-the-snapshot".utf8)
        let file = root.appendingPathComponent("main.rs")
        try data.write(to: file)
        #expect(try G04GitActionsDomain.readRegularFile(at: file, maxBytes: 1024) == data)
        // Oversized: typed refusal, capped read never exceeds the bound.
        let big = root.appendingPathComponent("big.bin")
        try Data(repeating: 7, count: 4_128).write(to: big)
        #expect(throws: (any Error).self) {
            _ = try G04GitActionsDomain.readRegularFile(at: big, maxBytes: 1_024)
        }
        // Directory and missing file refuse; symlink refuses.
        #expect(throws: (any Error).self) {
            _ = try G04GitActionsDomain.readRegularFile(at: root, maxBytes: 1_024)
        }
        #expect(throws: (any Error).self) {
            _ = try G04GitActionsDomain.readRegularFile(
                at: root.appendingPathComponent("absent"), maxBytes: 1_024)
        }
        let link = root.appendingPathComponent("link.rs")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) {
            _ = try G04GitActionsDomain.readRegularFile(at: link, maxBytes: 1_024)
        }
    }

    // MARK: - Real-tree policy walk

    @Test func buildManifestWalksRealTreeAndDropsEverythingThePolicyRefuses() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-gha-walk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"),
                                                withIntermediateDirectories: true)
        try Data("fn main(){}".utf8).write(to: root.appendingPathComponent("src/main.rs"))
        try Data("x".utf8).write(to: root.appendingPathComponent(".git/config"))
        try Data("token".utf8).write(to: root.appendingPathComponent(".env"))
        try Data("p".utf8).write(to: root.appendingPathComponent("server.pem"))
        try Data("dep".utf8).write(to: root.appendingPathComponent("node_modules/dep.js"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: root.appendingPathComponent("src/main.rs"))
        // Review revision (GIT_PRIVATE_PATCH_REVIEW_01.json): a link to a
        // DIRECTORY must be refused before traversal too — `listDirectory`
        // reports isDirectory through `resourceValues`, which follows the
        // link, so classification cannot be trusted first. The exact manifest
        // assertions below fail closed on any traversal (a descended link
        // would add "src-link/main.rs" entries and 11 more bytes).
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("src-link"),
            withDestinationURL: root.appendingPathComponent("src"))
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
        let manifest = try G04GitActionsDomain.buildManifest(directory: ".", fileService: service)
        #expect(manifest.entries.map(\.path) == ["src/main.rs"])
        #expect(manifest.totalBytes == Data("fn main(){}".utf8).count)
        // .git and node_modules are skipped DIRECTORIES (never descended, so
        // they are not even exclusion rows); .env/pem are secret exclusions;
        // BOTH links (file and directory) are refused as links.
        let reasons = manifest.excluded.map { "\($0)" }
        #expect(reasons.contains { $0.contains("secretFile") })
        #expect(reasons.contains { $0.contains("symlink") })
        #expect(!reasons.contains { $0.contains("node_modules") })
        #expect(!manifest.entries.contains { $0.path.hasPrefix(".git") })
    }

    // MARK: - Durable directory is accepted-task-owned

    @Test func storeDirectoryIsTheFloeTreeUnderTheTaskRootAndGitInvisible() {
        // The engine records live in the Floe-owned tree, which the snapshot
        // policy itself refuses to upload (generatedArtifact).
        #expect(IDEGitHubActionsSnapshotPolicy.isGeneratedPath(
            G04GitActionsDomain.storeRelativePath))
        #expect(G04GitActionsDomain.storeRelativePath.hasPrefix(".floe/"))
        #expect(IDEGitHubActionsArtifactPolicy.isSafeDestination(
            ".floe/artifacts/123/out.zip"))
    }
}

private extension G04GitActionsDomain {
    /// The lane's own split of the new grammar for test enumeration
    /// (mirrors `engineActions`: reads ride gitQuery, writes gitMutate).
    static var durableReads: [String] {
        ["actions.snapshotPreview", "actions.templates", "actions.records", "actions.record",
         "actions.refresh", "actions.jobLog", "actions.loadArtifacts"]
    }
    static var durableWrites: [String] {
        ["actions.dispatch", "actions.cancelJob", "actions.downloadArtifact", "actions.installTemplate"]
    }
}
