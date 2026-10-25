// FloeSkillsTests — GitHub directory bundle update contracts.
//
// Exercises `GitHubSkillDownload.stage` against the GitHub Contents endpoint
// shape (arrays for directories, raw bytes for files) at ONE immutable commit.
// Every fixture is synthetic and in-memory: no HTTPS transport, credentials,
// real repository or network is involved.

import Crypto
import Foundation
import Testing
@testable import FloeSkills

@Suite("GitHub directory Skill updates")
struct GitHubDirectoryUpdateTests {
    // A real 40-hex commit id. Upper case also proves the raw resolved id is
    // what every pinned request uses while the returned binding is lowercase.
    private static let commit = "0123456789ABCDEF0123456789ABCDEF01234567"

    @Test("An unchanged version replaces every bundled byte and drops removed files")
    func unchangedVersionReplacesWholeBundle() async throws {
        let fixture = try DirectoryUpdateFixture()
        defer { fixture.cleanup() }

        let installedFiles = try Self.installedBundleFiles()
        let installed = try fixture.snapshot(id: "field-notes", files: installedFiles, traditional: false)

        var proposedFiles = installedFiles
        proposedFiles["SKILL.md"] = Self.skillMarkdown(
            id: "field-notes", body: "Updated field-note workflow for the same published version.")
        proposedFiles["references/guide.md"] = Data("Updated reference guidance.\n".utf8)
        proposedFiles["scripts/collect.sh"] = Data("#!/bin/sh\necho updated-collect\n".utf8)
        proposedFiles["LICENSE"] = Data("Updated license text shipped with the same version.\n".utf8)
        proposedFiles["assets/diagram.png"] = Self.pngBytes(seed: 2)
        proposedFiles.removeValue(forKey: "references/removed.md")

        let tree = MockGitHub.tree(prefix: "skills/field-notes", files: proposedFiles)
        let source = try GitHubSkillSource(
            owner: "floe-community", repository: "field-notes", ref: "main", path: "skills/field-notes")
        let log = RequestLog()
        let staging = fixture.freshStaging()
        let (commit, staged) = try await Self.stage(
            tree: tree, source: source, commit: Self.commit, at: staging, log: log)

        #expect(commit == Self.commit.lowercased())
        #expect(staged.package.manifest.version == "1.4.0")
        #expect(staged.package.manifest.version == installed.package.manifest.version)
        // Everything present upstream is materialised byte-for-byte...
        #expect(staged.files == proposedFiles)
        // ...and the file upstream dropped is not carried over from the install.
        #expect(staged.files["references/removed.md"] == nil)
        #expect(staged.package.canonicalSHA256 != installed.package.canonicalSHA256)

        let candidate = try SkillUpgradeCandidate(
            source: source, commit: commit, installed: installed, proposed: staged)
        #expect(Set(candidate.changedFiles) == [
            "LICENSE", "SKILL.md", "assets/diagram.png",
            "references/guide.md", "references/removed.md", "scripts/collect.sh"
        ])
        #expect(candidate.changedFiles.count == 6)
        #expect(candidate.addedCapabilities.isEmpty)
        #expect(candidate.addedTools.isEmpty)

        // The removed path is never requested; every present file is.
        let requested = Set(await log.paths())
        #expect(!requested.contains("skills/field-notes/references/removed.md"))
        #expect(requested.isSuperset(of: proposedFiles.keys.map { "skills/field-notes/" + $0 }))

        // Materialised bytes on disk, not just the in-memory snapshot.
        let image = try #require(proposedFiles["assets/diagram.png"])
        let guide = try #require(proposedFiles["references/guide.md"])
        #expect(try Data(contentsOf: staging.appendingPathComponent("assets/diagram.png")) == image)
        #expect(try Data(contentsOf: staging.appendingPathComponent("references/guide.md")) == guide)
    }

    @Test("A traditional package without floe.json stays byte-identical and gains no manifest")
    func traditionalBundleIsByteIdentical() async throws {
        let fixture = try DirectoryUpdateFixture()
        defer { fixture.cleanup() }

        let files: [String: Data] = [
            "SKILL.md": Self.skillMarkdown(id: "trad-notes", body: "Follow the documented steps."),
            "reference/checklist.md": Data("Checklist reference\n".utf8),
            "LICENSE": Data("Traditional license text\n".utf8),
            "scripts/run.sh": Data("#!/bin/sh\necho traditional\n".utf8)
        ]
        let installed = try fixture.snapshot(id: "trad-notes", files: files, traditional: true)
        #expect(!installed.files.keys.contains("floe.json"))
        #expect(installed.package.manifest.scriptRuntime == .remote)

        let tree = MockGitHub.tree(prefix: "guides/trad-notes", files: files)
        let source = try GitHubSkillSource(
            owner: "guides-owner", repository: "notes", ref: "main", path: "guides/trad-notes")
        let staging = fixture.freshStaging()
        let (commit, staged) = try await Self.stage(
            tree: tree, source: source, commit: Self.commit, at: staging, log: RequestLog())

        // Same bytes, same derived manifest: no floe.json is invented upstream.
        #expect(staged.files == installed.files)
        #expect(staged.package.canonicalSHA256 == installed.package.canonicalSHA256)
        #expect(staged.package.manifest == installed.package.manifest)
        #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("floe.json").path))

        let candidate = try SkillUpgradeCandidate(
            source: source, commit: commit, installed: installed, proposed: staged)
        #expect(candidate.changedFiles.isEmpty)
        #expect(candidate.addedCapabilities.isEmpty)
        #expect(candidate.addedTools.isEmpty)
    }

    @Test("A markdown source stages its containing directory at the pinned commit")
    func markdownSourceStagesContainingDirectory() async throws {
        let fixture = try DirectoryUpdateFixture()
        defer { fixture.cleanup() }

        var bundleFiles: [String: Data] = [
            "SKILL.md": Self.skillMarkdown(
                id: "markdown-notes", body: "Instructions plus the neighbouring bundle."),
            "references/notes.md": Data("Bundle reference\n".utf8)
        ]
        bundleFiles["floe.json"] = try Self.manifestJSON(
            id: "markdown-notes", version: "1.2.0", scripted: false)
        let installed = try fixture.snapshot(id: "markdown-notes", files: bundleFiles, traditional: false)

        let tree = MockGitHub.tree(prefix: "skills/markdown-notes", files: bundleFiles)
        // A `.md` source path means "this file's directory is the package root";
        // the transport must answer a Contents listing for the parent, not just
        // the document bytes.
        let source = try GitHubSkillSource(
            owner: "owner", repository: "repo", ref: "main",
            path: "skills/markdown-notes/SKILL.md")
        let log = RequestLog()
        let (commit, staged) = try await Self.stage(
            tree: tree, source: source, commit: Self.commit,
            at: fixture.freshStaging(), log: log)

        #expect(commit == Self.commit.lowercased())
        #expect(staged.files == bundleFiles)
        #expect(staged.package.manifest.id == "markdown-notes")
        let candidate = try SkillUpgradeCandidate(
            source: source, commit: commit, installed: installed, proposed: staged)
        #expect(candidate.changedFiles.isEmpty)

        let requested = Set(await log.paths())
        #expect(requested.contains("skills/markdown-notes"))
        #expect(requested.contains("skills/markdown-notes/references/notes.md"))
    }

    @Test("The mutable ref is resolved once and every listing and file is pinned")
    func resolveOncePinEveryRequest() async throws {
        let fixture = try DirectoryUpdateFixture()
        defer { fixture.cleanup() }

        let files: [String: Data] = [
            "SKILL.md": Self.skillMarkdown(id: "pinned-notes", body: "Pinned bundle."),
            "floe.json": try Self.manifestJSON(id: "pinned-notes", version: "3.1.0", scripted: false),
            "reference/a.md": Data("A\n".utf8),
            "reference/nested/b.md": Data("B\n".utf8),
            "assets/logo.png": Self.pngBytes(seed: 7)
        ]
        let tree = MockGitHub.tree(prefix: "skills/pinned-notes", files: files)
        let source = try GitHubSkillSource(
            owner: "owner", repository: "repo", ref: "release/test", path: "skills/pinned-notes")
        let log = RequestLog()
        let (commit, staged) = try await Self.stage(
            tree: tree, source: source, commit: Self.commit,
            at: fixture.freshStaging(), log: log)

        #expect(commit == Self.commit.lowercased())
        #expect(staged.package.manifest.id == "pinned-notes")

        let resolveCount = await log.resolveCount
        #expect(resolveCount == 1)
        let requests = await log.requests
        let expectedPaths = tree.reachableDirectories(prefix: "skills/pinned-notes")
            .union(tree.files.keys)
        #expect(Set(requests.map { $0.path }) == expectedPaths)
        #expect(requests.count == expectedPaths.count)
        // Every request carried the exact resolved commit, not the branch.
        #expect(Set(requests.map { $0.commit }) == [Self.commit])
    }

    @Test("Symlinks, submodules, escaped paths and mismatched blobs fail closed")
    func rejectsUnsafeEntries() async throws {
        let fixture = try DirectoryUpdateFixture()
        defer { fixture.cleanup() }

        var files: [String: Data] = [
            "SKILL.md": Self.skillMarkdown(id: "safety-notes", body: "Inspect the reference."),
            "reference/guide.md": Data("Guide\n".utf8)
        ]
        files["floe.json"] = try Self.manifestJSON(id: "safety-notes", version: "1.0.0", scripted: false)
        let baseTree = MockGitHub.tree(prefix: "skills/safety-notes", files: files)
        let source = try GitHubSkillSource(
            owner: "owner", repository: "repo", ref: "main", path: "skills/safety-notes")

        // A symlink entry is refused by its target before any traversal.
        var symlinkTree = baseTree
        symlinkTree.mutateListing("skills/safety-notes") { entry in
            entry.name == "reference" ? entry.retyped("symlink", target: "SKILL.md") : entry
        }
        await #expect(throws: SkillUpgradeError.invalidInventory) {
            try await Self.stage(
                tree: symlinkTree, source: source, commit: Self.commit,
                at: fixture.freshStaging(), log: RequestLog())
        }

        // A symlink without a target still cannot become a file or directory.
        var bareSymlinkTree = baseTree
        bareSymlinkTree.mutateListing("skills/safety-notes") { entry in
            entry.name == "reference" ? entry.retyped("symlink") : entry
        }
        await #expect(throws: SkillUpgradeError.invalidInventory) {
            try await Self.stage(
                tree: bareSymlinkTree, source: source, commit: Self.commit,
                at: fixture.freshStaging(), log: RequestLog())
        }

        // A git submodule is never fetched recursively.
        var submoduleTree = baseTree
        submoduleTree.mutateListing("skills/safety-notes") { entry in
            entry.name == "reference"
                ? entry.retyped("submodule", submoduleURL: "https://github.com/owner/repo") : entry
        }
        await #expect(throws: SkillUpgradeError.invalidInventory) {
            try await Self.stage(
                tree: submoduleTree, source: source, commit: Self.commit,
                at: fixture.freshStaging(), log: RequestLog())
        }

        // `..` and absolute paths are rejected by the shared path contract.
        var escapeTree = baseTree
        escapeTree.mutateListing("skills/safety-notes") { entry in
            entry.name == "SKILL.md" ? entry.moved(to: "skills/safety-notes/../outside.md") : entry
        }
        await #expect(throws: SkillUpgradeError.invalidSource) {
            try await Self.stage(
                tree: escapeTree, source: source, commit: Self.commit,
                at: fixture.freshStaging(), log: RequestLog())
        }

        var absoluteTree = baseTree
        absoluteTree.mutateListing("skills/safety-notes") { entry in
            entry.name == "SKILL.md" ? entry.moved(to: "/etc/passwd") : entry
        }
        await #expect(throws: SkillUpgradeError.invalidSource) {
            try await Self.stage(
                tree: absoluteTree, source: source, commit: Self.commit,
                at: fixture.freshStaging(), log: RequestLog())
        }

        // A listing entry whose path does not match its directory is refused.
        var mismatchedPathTree = baseTree
        mismatchedPathTree.mutateListing("skills/safety-notes") { entry in
            entry.name == "SKILL.md" ? entry.moved(to: "skills/other/SKILL.md") : entry
        }
        await #expect(throws: SkillUpgradeError.invalidInventory) {
            try await Self.stage(
                tree: mismatchedPathTree, source: source, commit: Self.commit,
                at: fixture.freshStaging(), log: RequestLog())
        }

        // A well-formed blob id that does not match the bytes fails closed.
        var blobTree = baseTree
        blobTree.mutateListing("skills/safety-notes/reference") { entry in
            entry.name == "guide.md" ? entry.withSHA(String(repeating: "1", count: 40)) : entry
        }
        await #expect(throws: SkillUpgradeError.hashMismatch("reference/guide.md")) {
            try await Self.stage(
                tree: blobTree, source: source, commit: Self.commit,
                at: fixture.freshStaging(), log: RequestLog())
        }
    }

    @Test("Native payloads and oversized entries are rejected")
    func rejectsNativeAndOversizedFiles() async throws {
        let fixture = try DirectoryUpdateFixture()
        defer { fixture.cleanup() }

        let validFiles: [String: Data] = [
            "SKILL.md": Self.skillMarkdown(id: "asset-notes", body: "Inspect the bundled assets."),
            "floe.json": try Self.manifestJSON(id: "asset-notes", version: "1.0.0", scripted: false)
        ]
        let source = try GitHubSkillSource(
            owner: "owner", repository: "repo", ref: "main", path: "skills/asset-notes")

        // A native extension and a native magic both bypass the transport hash
        // gate only to be refused by the shared package validator.
        let nativePayloads: [(String, Data)] = [
            ("assets/plugin.so", Data([0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01, 0x01, 0x00])),
            ("assets/loader.bin", Data([0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01, 0x01, 0x00]))
        ]
        for (path, payload) in nativePayloads {
            var files = validFiles
            files[path] = payload
            let tree = MockGitHub.tree(prefix: "skills/asset-notes", files: files)
            await #expect(throws: SkillValidationError.unsupportedFile(path)) {
                try await Self.stage(
                    tree: tree, source: source, commit: Self.commit,
                    at: fixture.freshStaging(), log: RequestLog())
            }
        }

        // The listing's own byte bound is enforced before the file is fetched.
        var oversizedTree = MockGitHub.tree(prefix: "skills/asset-notes", files: validFiles)
        oversizedTree.mutateListing("skills/asset-notes") { entry in
            entry.name == "SKILL.md" ? entry.withSize(2_097_153) : entry
        }
        let log = RequestLog()
        do {
            _ = try await Self.stage(
                tree: oversizedTree, source: source, commit: Self.commit,
                at: fixture.freshStaging(), log: log)
            Issue.record("An oversized directory entry must fail closed")
        } catch let error as SkillUpgradeError {
            #expect(error == .invalidInventory)
        }
        let requested = await log.paths()
        #expect(requested == ["skills/asset-notes"])
    }

    @Test("Same-version community bytes may change; official rewrites and downgrades may not")
    func candidateIdentityRules() throws {
        let fixture = try DirectoryUpdateFixture()
        defer { fixture.cleanup() }
        let commit = Self.commit

        let communitySource = try GitHubSkillSource(
            owner: "community", repository: "notes", ref: "main", path: "skills/community-notes")
        let installedCommunity = try fixture.plainSnapshot(
            id: "community-notes", version: "2.0.0", body: "Installed community body.")
        let rewrittenCommunity = try fixture.plainSnapshot(
            id: "community-notes", version: "2.0.0", body: "Reviewed community body with new wording.")
        let sameVersion = try SkillUpgradeCandidate(
            source: communitySource, commit: commit, installed: installedCommunity, proposed: rewrittenCommunity)
        #expect(sameVersion.changedFiles == ["SKILL.md"])
        #expect(sameVersion.snapshot.package.manifest.version == "2.0.0")

        // Downgrades need the explicit rollback path instead.
        let olderCommunity = try fixture.plainSnapshot(
            id: "community-notes", version: "1.9.0", body: "Older community body.")
        #expect(throws: SkillUpgradeError.versionRegression) {
            _ = try SkillUpgradeCandidate(
                source: communitySource, commit: commit,
                installed: installedCommunity, proposed: olderCommunity)
        }

        let officialSource = try OfficialSkillHub.source()
        let officialInstalled = try fixture.plainSnapshot(
            id: "floe-pdf", version: "1.7.0", body: "Published official body.")
        let officialRewritten = try fixture.plainSnapshot(
            id: "floe-pdf", version: "1.7.0", body: "Different bytes under the same published version.")
        // App callers cannot manufacture an official update at all.
        #expect(throws: OfficialSkillHub.Failure.signature) {
            _ = try SkillUpgradeCandidate(
                source: officialSource, commit: commit,
                installed: officialInstalled, proposed: officialRewritten)
        }
        // A verified catalog candidate still cannot rewrite a published version.
        #expect(throws: OfficialSkillHub.Failure.immutableVersion) {
            _ = try SkillUpgradeCandidate(
                verifiedSource: officialSource, commit: commit,
                installed: officialInstalled, proposed: officialRewritten)
        }
        // Only the fixed official catalog binding satisfies the official path.
        let fakeOfficialSource = try GitHubSkillSource(
            owner: "attacker", repository: "floe-agent", ref: "main", path: "skill-hub/catalog.json")
        #expect(throws: OfficialSkillHub.Failure.source) {
            _ = try SkillUpgradeCandidate(
                verifiedSource: fakeOfficialSource, commit: commit,
                installed: officialInstalled, proposed: officialRewritten)
        }
        // Downgrades are shared by official and community candidates.
        let olderOfficial = try fixture.plainSnapshot(
            id: "floe-pdf", version: "1.6.0", body: "Older official body.")
        #expect(throws: SkillUpgradeError.versionRegression) {
            _ = try SkillUpgradeCandidate(
                verifiedSource: officialSource, commit: commit,
                installed: officialInstalled, proposed: olderOfficial)
        }
    }

    @Test("Source bindings reject malformed installed digests")
    func bindingRejectsMalformedDigests() throws {
        let source = try GitHubSkillSource(
            owner: "owner", repository: "repo", ref: "main", path: "skills/notes")

        // Tracking intent may exist without installed evidence...
        let trackingOnly = try SkillGitHubBinding(
            source: source, installedCommit: nil, installedContentDigest: nil)
        #expect(trackingOnly.installedCommit == nil)
        #expect(trackingOnly.installedContentDigest == nil)

        // ...but installed evidence must be an exact git blob / SHA-256 shape.
        #expect(throws: SkillUpgradeError.invalidCommit) {
            _ = try SkillGitHubBinding(
                source: source, installedCommit: String(repeating: "a", count: 39), installedContentDigest: nil)
        }
        #expect(throws: SkillUpgradeError.invalidCommit) {
            _ = try SkillGitHubBinding(
                source: source, installedCommit: String(repeating: "z", count: 40), installedContentDigest: nil)
        }
        #expect(throws: SkillUpgradeError.invalidInventory) {
            _ = try SkillGitHubBinding(
                source: source, installedCommit: nil, installedContentDigest: String(repeating: "0", count: 63))
        }
        #expect(throws: SkillUpgradeError.invalidInventory) {
            _ = try SkillGitHubBinding(
                source: source, installedCommit: nil, installedContentDigest: String(repeating: "g", count: 64))
        }

        // Accepted evidence is normalised to lowercase and round-trips exactly.
        let binding = try SkillGitHubBinding(
            source: source,
            installedCommit: String(repeating: "AB", count: 20),
            installedContentDigest: String(repeating: "CD", count: 32))
        #expect(binding.installedCommit == String(repeating: "ab", count: 20))
        #expect(binding.installedContentDigest == String(repeating: "cd", count: 32))
        let decoded = try JSONDecoder().decode(SkillGitHubBinding.self, from: JSONEncoder().encode(binding))
        #expect(decoded == binding)

        // Persisted JSON is decoded through the same validating initialiser.
        let truncatedCommit = Data("""
        {"source":{"owner":"owner","repository":"repo","ref":"main","path":"skills/notes"},"installedCommit":"abc"}
        """.utf8)
        #expect(throws: SkillUpgradeError.invalidCommit) {
            _ = try JSONDecoder().decode(SkillGitHubBinding.self, from: truncatedCommit)
        }
        let malformedDigest = Data("""
        {"source":{"owner":"owner","repository":"repo","ref":"main","path":"skills/notes"},\
        "installedContentDigest":"\(String(repeating: "f", count: 64))g"}
        """.utf8)
        #expect(throws: SkillUpgradeError.invalidInventory) {
            _ = try JSONDecoder().decode(SkillGitHubBinding.self, from: malformedDigest)
        }
    }

    // MARK: - Staging driver

    private static func stage(tree: MockGitHubTree, source: GitHubSkillSource, commit: String,
                              at root: URL, log: RequestLog) async throws -> (String, SkillContentSnapshot) {
        let resolve: GitHubSkillDownload.ResolveCommit = { _ in
            await log.recordResolve()
            return commit
        }
        let fetch: GitHubSkillDownload.FetchFile = { _, pinned, path in
            await log.record(path: path, commit: pinned)
            return try tree.payload(for: path)
        }
        return try await GitHubSkillDownload.stage(source: source, at: root, resolve: resolve, fetch: fetch)
    }

    // MARK: - Synthetic package content

    private static func installedBundleFiles() throws -> [String: Data] {
        [
            "SKILL.md": skillMarkdown(id: "field-notes", body: "Installed field-note workflow."),
            "floe.json": try manifestJSON(id: "field-notes", version: "1.4.0", scripted: true),
            "references/guide.md": Data("Installed reference guidance.\n".utf8),
            "references/removed.md": Data("Obsolete note that upstream drops.\n".utf8),
            "scripts/collect.sh": Data("#!/bin/sh\necho installed-collect\n".utf8),
            "LICENSE": Data("Installed license text.\n".utf8),
            "assets/diagram.png": pngBytes(seed: 1)
        ]
    }

    fileprivate static func skillMarkdown(id: String, body: String) -> Data {
        Data("""
        ---
        name: \(id)
        description: Synthetic \(id) package used only by tests.
        ---

        \(body)
        """.utf8)
    }

    fileprivate static func manifestJSON(id: String, version: String, scripted: Bool) throws -> Data {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "id": id,
            "version": version,
            "capabilities": scripted ? [SkillCapability.remoteExecution.rawValue] : [],
            "tools": scripted ? ["exec.shell"] : [],
            "platforms": ["ios", "macos"],
            "scriptRuntime": scripted ? "remote" : "none"
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    fileprivate static func contentFiles(id: String, version: String, body: String) throws -> [String: Data] {
        var files: [String: Data] = ["SKILL.md": skillMarkdown(id: id, body: body)]
        files["floe.json"] = try manifestJSON(id: id, version: version, scripted: false)
        return files
    }

    private static func pngBytes(seed: UInt8) -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, seed])
    }
}

// MARK: - Fixture directory

private final class DirectoryUpdateFixture {
    let base: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeGitHubDirectory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    /// A staging path that does not exist yet: `materialize` requires a fresh root.
    func freshStaging() -> URL {
        base.appendingPathComponent("stage-\(UUID().uuidString)", isDirectory: true)
    }

    func snapshot(id: String, files: [String: Data], traditional: Bool) throws -> SkillContentSnapshot {
        let root = base.appendingPathComponent("installed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, data) in files {
            let target = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
        if traditional {
            let package = try SkillPackageValidator().validate(packageAt: root, requireManifest: false)
            return try SkillContentSnapshot(
                root: root, expectedDigest: package.canonicalSHA256, manifestOverride: package.manifest)
        }
        let package = try SkillPackageValidator().validate(packageAt: root)
        return try SkillContentSnapshot(root: root, expectedDigest: package.canonicalSHA256)
    }

    func plainSnapshot(id: String, version: String, body: String) throws -> SkillContentSnapshot {
        try snapshot(
            id: id,
            files: try GitHubDirectoryUpdateTests.contentFiles(id: id, version: version, body: body),
            traditional: false)
    }
}

// MARK: - GitHub Contents mock

private struct MockDirectoryEntry: Codable, Sendable {
    var name: String
    var path: String
    var type: String
    var size: Int
    var sha: String
    var target: String?
    var submoduleGitURL: String?

    private enum CodingKeys: String, CodingKey {
        case name, path, type, size, sha, target
        case submoduleGitURL = "submodule_git_url"
    }

    func retyped(_ newType: String, target: String? = nil, submoduleURL: String? = nil) -> MockDirectoryEntry {
        MockDirectoryEntry(name: name, path: path, type: newType, size: size, sha: sha,
                           target: target, submoduleGitURL: submoduleURL)
    }

    func moved(to newPath: String) -> MockDirectoryEntry {
        MockDirectoryEntry(name: name, path: newPath, type: type, size: size, sha: sha,
                           target: target, submoduleGitURL: submoduleGitURL)
    }

    func withSHA(_ newSHA: String) -> MockDirectoryEntry {
        MockDirectoryEntry(name: name, path: path, type: type, size: size, sha: newSHA,
                           target: target, submoduleGitURL: submoduleGitURL)
    }

    func withSize(_ newSize: Int) -> MockDirectoryEntry {
        MockDirectoryEntry(name: name, path: path, type: type, size: newSize, sha: sha,
                           target: target, submoduleGitURL: submoduleGitURL)
    }
}

private struct MockGitHubTree: Sendable {
    var directories: [String: [MockDirectoryEntry]]
    var files: [String: Data]

    func payload(for path: String) throws -> Data {
        if let entries = directories[path] { return try JSONEncoder().encode(entries) }
        if let data = files[path] { return data }
        throw MockGitHubError.missingPath(path)
    }

    mutating func mutateListing(_ directory: String,
                                _ transform: (MockDirectoryEntry) -> MockDirectoryEntry) {
        directories[directory] = directories[directory]?.map(transform)
    }

    func reachableDirectories(prefix: String) -> Set<String> {
        Set(directories.keys.filter { $0 == prefix || $0.hasPrefix(prefix + "/") })
    }
}

private enum MockGitHubError: Error { case missingPath(String) }

private enum MockGitHub {
    static func tree(prefix: String, files relativeFiles: [String: Data]) -> MockGitHubTree {
        var fullFiles: [String: Data] = [:]
        var directoryPaths: Set<String> = [prefix]
        for (relative, data) in relativeFiles {
            let full = prefix.isEmpty ? relative : prefix + "/" + relative
            fullFiles[full] = data
            var components = full.split(separator: "/").map(String.init)
            components.removeLast()
            var current = ""
            for component in components {
                current = current.isEmpty ? component : current + "/" + component
                directoryPaths.insert(current)
            }
        }
        var directories: [String: [MockDirectoryEntry]] = [:]
        for directory in directoryPaths {
            var entries: [MockDirectoryEntry] = []
            for (path, data) in fullFiles where parentPath(of: path) == directory {
                entries.append(MockDirectoryEntry(
                    name: lastComponent(of: path), path: path, type: "file",
                    size: data.count, sha: gitBlobSHA1(data), target: nil, submoduleGitURL: nil))
            }
            for child in directoryPaths where parentPath(of: child) == directory {
                entries.append(MockDirectoryEntry(
                    name: lastComponent(of: child), path: child, type: "dir",
                    size: 0, sha: String(repeating: "0", count: 40), target: nil, submoduleGitURL: nil))
            }
            directories[directory] = entries.sorted { $0.path < $1.path }
        }
        return MockGitHubTree(directories: directories, files: fullFiles)
    }

    private static func parentPath(of path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    private static func lastComponent(of path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }
}

private func gitBlobSHA1(_ data: Data) -> String {
    var hasher = Insecure.SHA1()
    hasher.update(data: Data("blob \(data.count)\0".utf8))
    hasher.update(data: data)
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

// MARK: - Request recording

private actor RequestLog {
    private(set) var resolveCount = 0
    private(set) var requests: [(path: String, commit: String)] = []

    func recordResolve() { resolveCount += 1 }
    func record(path: String, commit: String) { requests.append((path: path, commit: commit)) }
    func paths() -> [String] { requests.map { $0.path } }
}
