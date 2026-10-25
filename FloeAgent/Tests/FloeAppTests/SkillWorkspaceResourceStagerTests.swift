// FloeAppTests — installed Skill bundle delivery into the local Linux task workspace.
//
// The physical iPad exposed the gap: an exact `skill.read` returned the pinned
// guide and the audited script text, but the guest never received the bundle's
// sibling assets/references, so the model could neither find nor honestly
// recreate them. These tests lock the fix's real contracts:
//
//  * the stager publishes the COMPLETE pinned bundle (scripts + assets +
//    references + agent metadata) into the task workspace the existing
//    workspace share exports as /workspace, from the descriptor-time share map
//    — a cold read before the task's first exec.shell still stages what the
//    later first boot sees;
//  * reuse is granted only by full byte verification against the pinned
//    snapshot, never by the advisory marker; tampering, symlinks, foreign
//    entries and unsafe paths fail closed without overwriting anything;
//  * digests are validated as exact ASCII `0-9a-f` (real SHA-256 values carry
//    digits, which are not `Character.isLowercase`);
//  * cancellation is fenced after every suspension, before creation, after
//    verification and immediately before both staged returns;
//  * retention is workspace/task-owned: pinned trees are never pruned by age
//    (a long run keeps the tree it executes from), and markers are never
//    read or written through planted symlinks;
//  * nil/mismatched/nonlocal bindings report an honest unavailable status and
//    never fabricate a guest path or fall back to a host path;
//  * the PRODUCTION route (SkillReadTool → LocalSkillCreator → SkillsCenter →
//    stager) delivers the bundle, while list/search never stage anything.
//
// Fixtures are tiny synthetic packages; no guest, VM, device or upstream skill
// bytes are involved. Requires the FloeAppTests target membership entry that the
// integration owner adds with the other focused test files.

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeExecution
import FloeSkills
import FloeTools
@testable import FloeApp

// MARK: - Fixtures

private struct SkillBundleFixture {
    let packageRoot: URL
    let snapshot: SkillContentSnapshot
    let skillID: String
    let digest: String

    var leaf: String { "\(skillID)@\(digest)" }
}

private func makeBundleFixture(
    id: String = "resource-fixture",
    extras: [String: String] = [
        "scripts/new_notebook.py": "print('new notebook')\n",
        "assets/tutorial-template.ipynb": "{\"cells\":[]}\n",
        "references/guide.md": "# Guide\n\nUse the bundled template.\n",
        "agents/openai.yaml": "interface:\n  display_name: Fixture\n"
    ]
) throws -> SkillBundleFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-skill-bundle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let markdown = """
        ---
        name: \(id)
        description: Fixture bundle for workspace resource staging
        ---
        Follow the bundled references and use the script with its sibling assets.
        """
    let manifest = SkillManifest(
        id: id, version: "1.0.0",
        capabilities: [SkillCapability.remoteExecution.rawValue],
        tools: ["exec.shell"], scriptRuntime: .remote
    )
    try Data(markdown.utf8).write(to: root.appendingPathComponent("SKILL.md"), options: .atomic)
    try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("floe.json"), options: .atomic)
    for (path, text) in extras {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: target, options: .atomic)
    }
    let validated = try SkillPackageValidator().validate(packageAt: root)
    let snapshot = try SkillContentSnapshot(root: root, expectedDigest: validated.canonicalSHA256)
    return SkillBundleFixture(
        packageRoot: root, snapshot: snapshot, skillID: id, digest: validated.canonicalSHA256
    )
}

private func makeTemporaryDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The descriptor-time share table the guest boots with: workspace → /workspace.
private func makeWorkspaceShareMap(exporting workspace: URL) -> LinuxGuestPathMap {
    LinuxGuestPathMap(shares: [LinuxGuestShare(tag: LinuxGuestShare.workspaceTag, hostDirectory: workspace)])
}

private func stageContext(
    environmentID: String?,
    workspace: URL?,
    cancellation: CancellationToken = CancellationToken()
) -> SkillResourceContext {
    SkillResourceContext(environmentID: environmentID, workspaceRootURL: workspace, cancellation: cancellation)
}

private func stagedBundle(_ outcome: SkillStageOutcome) -> SkillStagedBundle? {
    if case .staged(let bundle) = outcome { return bundle }
    return nil
}

private func unavailableReason(_ outcome: SkillStageOutcome) -> String? {
    if case .unavailable(let reason) = outcome { return reason }
    return nil
}

private func contentBundleNames(in workspace: URL) -> [String] {
    let root = workspace.appendingPathComponent(".floe/skills", isDirectory: true)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return names.filter { !$0.hasPrefix(".") }.sorted()
}

private func stage(
    _ stager: SkillWorkspaceResourceStager,
    _ fixture: SkillBundleFixture,
    environmentID: String?,
    workspace: URL?,
    cancellation: CancellationToken = CancellationToken()
) async -> SkillStageOutcome {
    await stager.stage(
        snapshot: fixture.snapshot,
        in: stageContext(environmentID: environmentID, workspace: workspace, cancellation: cancellation)
    )
}

/// Records each descriptor lookup. The map exists without any guest running:
/// staging must work from the registry's descriptor, not from a live console.
private actor ShareMapProbe {
    private(set) var requests: [String] = []
    let map: LinuxGuestPathMap?

    init(map: LinuxGuestPathMap?) { self.map = map }

    func lookup(_ environmentID: String) -> LinuxGuestPathMap? {
        requests.append(environmentID)
        return map
    }
}

/// Signals that the injected descriptor lookup was actually entered, so a test
/// can cancel while `stage` is suspended inside it.
private actor StageEntryGate {
    private var entered = false

    func markEntered() { entered = true }

    func waitUntilEntered() async {
        while !entered {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

// MARK: - Stager behavior

@Suite("Skill workspace resource staging")
struct SkillWorkspaceResourceStagerTests {
    @Test func stagesSiblingBundleAndReturnsPortableGuestRoot() async throws {
        let fixture = try makeBundleFixture()
        let workspace = try makeTemporaryDirectory("workspace")
        defer { try? FileManager.default.removeItem(at: workspace) }
        defer { try? FileManager.default.removeItem(at: fixture.packageRoot) }
        let stager = SkillWorkspaceResourceStager { _ in makeWorkspaceShareMap(exporting: workspace) }

        let outcome = await stage(stager, fixture, environmentID: "env-local", workspace: workspace)
        let staged = try #require(stagedBundle(outcome))
        #expect(staged.guestRoot == "/workspace/.floe/skills/\(fixture.leaf)")
        #expect(!staged.guestRoot.contains(workspace.path), "only the portable guest path is exposed")
        #expect(staged.pinnedSHA256 == fixture.digest)
        #expect(staged.fileCount == fixture.snapshot.package.files.count)

        let stagedRoot = workspace.appendingPathComponent(".floe/skills/\(fixture.leaf)", isDirectory: true)
        for file in fixture.snapshot.package.files {
            #expect(try Data(contentsOf: stagedRoot.appendingPathComponent(file.relativePath))
                == fixture.snapshot.files[file.relativePath])
        }
        // The script and its sibling resources live in ONE immutable tree.
        #expect(FileManager.default.fileExists(
            atPath: stagedRoot.appendingPathComponent("assets/tutorial-template.ipynb").path))
        #expect(FileManager.default.fileExists(
            atPath: stagedRoot.appendingPathComponent("references/guide.md").path))
        #expect(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent(".floe/skills/.markers/\(fixture.leaf).json").path))

        // Footers never carry a raw host path.
        let footer = SkillWorkspaceResourceStager.resourceFooter(
            id: fixture.skillID, pinnedSHA256: fixture.digest,
            declaredFiles: fixture.snapshot.package.files, outcome: outcome)
        #expect(footer.contains("staged=true"))
        #expect(footer.contains(staged.guestRoot))
        #expect(!footer.contains(workspace.path))
        #expect(footer.contains("$CODEX_HOME/skills/\(fixture.skillID)/"))
        #expect(footer.contains("fileCount=\(staged.fileCount)"))
    }

    @Test func coldReadBeforeAnyGuestBootStagesThroughTheDescriptorShareMap() async throws {
        // The physical failure sequence reads a skill BEFORE the task's first
        // exec.shell. The descriptor-time share map is enough: no running
        // guest is a precondition, so the later first boot mounts the staged
        // files that were written here.
        let fixture = try makeBundleFixture()
        let workspace = try makeTemporaryDirectory("workspace")
        defer { try? FileManager.default.removeItem(at: workspace) }
        defer { try? FileManager.default.removeItem(at: fixture.packageRoot) }
        let probe = ShareMapProbe(map: makeWorkspaceShareMap(exporting: workspace))
        let stager = SkillWorkspaceResourceStager { environmentID in await probe.lookup(environmentID) }

        let outcome = await stage(stager, fixture, environmentID: "env-cold", workspace: workspace)
        #expect(stagedBundle(outcome) != nil)
        #expect(await probe.requests == ["env-cold"])
        #expect(contentBundleNames(in: workspace) == [fixture.leaf])
        #expect(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent(".floe/skills/\(fixture.leaf)/scripts/new_notebook.py").path))
    }

    @Test func reuseRequiresByteVerificationNotTheMarkerAlone() async throws {
        let fixture = try makeBundleFixture()
        let workspace = try makeTemporaryDirectory("workspace")
        defer { try? FileManager.default.removeItem(at: workspace) }
        defer { try? FileManager.default.removeItem(at: fixture.packageRoot) }
        let stager = SkillWorkspaceResourceStager { _ in makeWorkspaceShareMap(exporting: workspace) }
        let firstOutcome = await stage(stager, fixture, environmentID: "env", workspace: workspace)
        let first = try #require(stagedBundle(firstOutcome))

        // A bogus marker digest changes nothing: the pinned bytes decide.
        let marker = workspace.appendingPathComponent(".floe/skills/.markers/\(fixture.leaf).json")
        try Data(#"{"digest":"\#(String(repeating: "0", count: 64))","stagedAt":0}"#.utf8)
            .write(to: marker, options: .atomic)
        let reused = await stage(stager, fixture, environmentID: "env", workspace: workspace)
        #expect(stagedBundle(reused)?.guestRoot == first.guestRoot)

        // Tampering with any staged file fails closed: no guest path, and the
        // foreign/damaged tree is left exactly as found.
        let asset = workspace.appendingPathComponent(
            ".floe/skills/\(fixture.leaf)/assets/tutorial-template.ipynb")
        let tampered = Data("tampered".utf8)
        try tampered.write(to: asset, options: .atomic)
        let blocked = await stage(stager, fixture, environmentID: "env", workspace: workspace)
        #expect(unavailableReason(blocked) == SkillStageReason.pathBlocked)
        #expect(stagedBundle(blocked) == nil)
        #expect(try Data(contentsOf: asset) == tampered)
        #expect(contentBundleNames(in: workspace) == [fixture.leaf])
    }

    @Test func symlinksAndReservedConflictsFailClosedWithoutEscaping() async throws {
        let fixture = try makeBundleFixture()
        let workspace = try makeTemporaryDirectory("workspace")
        defer { try? FileManager.default.removeItem(at: workspace) }
        defer { try? FileManager.default.removeItem(at: fixture.packageRoot) }
        let stager = SkillWorkspaceResourceStager { _ in makeWorkspaceShareMap(exporting: workspace) }
        _ = await stage(stager, fixture, environmentID: "env", workspace: workspace)

        // A symlink inside an existing staged tree is never followed.
        let stagedRoot = workspace.appendingPathComponent(".floe/skills/\(fixture.leaf)", isDirectory: true)
        let guide = stagedRoot.appendingPathComponent("references/guide.md")
        try FileManager.default.removeItem(at: guide)
        try FileManager.default.createSymbolicLink(
            at: guide, withDestinationURL: stagedRoot.appendingPathComponent("SKILL.md"))
        let blocked = await stage(stager, fixture, environmentID: "env", workspace: workspace)
        #expect(unavailableReason(blocked) == SkillStageReason.pathBlocked)

        // A planted link at the reserved component cannot redirect writes.
        let victim = try makeTemporaryDirectory("victim")
        let linkedWorkspace = try makeTemporaryDirectory("linked-workspace")
        defer { try? FileManager.default.removeItem(at: victim) }
        defer { try? FileManager.default.removeItem(at: linkedWorkspace) }
        try FileManager.default.createSymbolicLink(
            at: linkedWorkspace.appendingPathComponent(".floe"), withDestinationURL: victim)
        let linkedStager = SkillWorkspaceResourceStager { _ in
            makeWorkspaceShareMap(exporting: linkedWorkspace)
        }
        let linked = await stage(linkedStager, fixture, environmentID: "env", workspace: linkedWorkspace)
        #expect(unavailableReason(linked) == SkillStageReason.reservedConflict)
        #expect((try FileManager.default.contentsOfDirectory(atPath: victim.path)).isEmpty)
    }

    @Test func markerSymlinksAreNeverFollowedAndExternalEntriesStayUntouched() async throws {
        let fixture = try makeBundleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.packageRoot) }
        let victim = try makeTemporaryDirectory("marker-victim")
        defer { try? FileManager.default.removeItem(at: victim) }
        let sentinel = victim.appendingPathComponent("sentinel.txt")
        let sentinelBytes = Data("external sentinel bytes".utf8)
        try sentinelBytes.write(to: sentinel, options: .atomic)

        // Case 1: the whole `.markers` directory is a planted symlink. Neither
        // the create route nor the reuse route may write through it.
        let workspace = try makeTemporaryDirectory("workspace")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let reserved = workspace.appendingPathComponent(".floe/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: reserved, withIntermediateDirectories: true)
        let markerLinkDir = reserved.appendingPathComponent(".markers")
        try FileManager.default.createSymbolicLink(at: markerLinkDir, withDestinationURL: victim)
        let stager = SkillWorkspaceResourceStager { _ in makeWorkspaceShareMap(exporting: workspace) }
        let first = await stage(stager, fixture, environmentID: "env", workspace: workspace)
        #expect(stagedBundle(first)?.guestRoot == "/workspace/.floe/skills/\(fixture.leaf)")
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: victim.path) == ["sentinel.txt"])
        let reused = await stage(stager, fixture, environmentID: "env", workspace: workspace)
        #expect(stagedBundle(reused)?.guestRoot == "/workspace/.floe/skills/\(fixture.leaf)")
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: victim.path) == ["sentinel.txt"])
        #expect(SkillWorkspaceResourceStager.isSymbolicLink(markerLinkDir), "the planted link is left as found")

        // Case 2: the marker entry itself is a planted symlink to a foreign
        // file. It is neither read nor replaced.
        let secondWorkspace = try makeTemporaryDirectory("workspace")
        defer { try? FileManager.default.removeItem(at: secondWorkspace) }
        let secondReserved = secondWorkspace.appendingPathComponent(".floe/skills", isDirectory: true)
        let secondMarkers = secondReserved.appendingPathComponent(".markers", isDirectory: true)
        try FileManager.default.createDirectory(at: secondMarkers, withIntermediateDirectories: true)
        let markerLink = secondMarkers.appendingPathComponent("\(fixture.leaf).json")
        try FileManager.default.createSymbolicLink(at: markerLink, withDestinationURL: sentinel)
        let secondStager = SkillWorkspaceResourceStager { _ in
            makeWorkspaceShareMap(exporting: secondWorkspace)
        }
        let second = await stage(secondStager, fixture, environmentID: "env", workspace: secondWorkspace)
        #expect(stagedBundle(second)?.guestRoot == "/workspace/.floe/skills/\(fixture.leaf)")
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
        #expect(SkillWorkspaceResourceStager.isSymbolicLink(markerLink), "the planted marker link is left as found")
    }

    @Test func unboundOrForeignContextsNeverReturnAGuestPath() async throws {
        let fixture = try makeBundleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.packageRoot) }
        let workspace = try makeTemporaryDirectory("workspace")
        let other = try makeTemporaryDirectory("other-workspace")
        let layer = try makeTemporaryDirectory("layer")
        defer { try? FileManager.default.removeItem(at: workspace) }
        defer { try? FileManager.default.removeItem(at: other) }
        defer { try? FileManager.default.removeItem(at: layer) }
        let missing = workspace.appendingPathComponent("removed-workspace")
        let share = makeWorkspaceShareMap(exporting: workspace)
        let foreignShare = makeWorkspaceShareMap(exporting: other)
        let environmentOnly = LinuxGuestPathMap(shares: [
            LinuxGuestShare(tag: LinuxGuestShare.environmentTag, hostDirectory: layer)
        ])

        let cases: [(environmentID: String?, workspace: URL?, map: LinuxGuestPathMap?, reason: String)] = [
            (nil, workspace, share, SkillStageReason.noBoundEnvironment),
            ("", workspace, share, SkillStageReason.noBoundEnvironment),
            ("env", nil, share, SkillStageReason.noBoundEnvironment),
            ("env", workspace, nil, SkillStageReason.noShareMap),
            ("env", workspace, environmentOnly, SkillStageReason.noWorkspaceShare),
            ("env", workspace, foreignShare, SkillStageReason.workspaceMismatch),
            ("env", missing, share, SkillStageReason.workspaceMismatch)
        ]
        for (index, item) in cases.enumerated() {
            let stager = SkillWorkspaceResourceStager { _ in item.map }
            let outcome = await stager.stage(
                snapshot: fixture.snapshot,
                in: stageContext(environmentID: item.environmentID, workspace: item.workspace))
            #expect(unavailableReason(outcome) == item.reason, "case \(index)")
            #expect(stagedBundle(outcome) == nil, "case \(index)")
        }
        // No cache tree appeared in the tested workspace or the foreign one.
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".floe").path))
        #expect(!FileManager.default.fileExists(atPath: other.appendingPathComponent(".floe").path))

        // A cancelled call does no IO at all.
        let token = CancellationToken()
        token.cancel()
        let stager = SkillWorkspaceResourceStager { _ in share }
        let cancelled = await stage(stager, fixture, environmentID: "env", workspace: workspace, cancellation: token)
        #expect(unavailableReason(cancelled) == SkillStageReason.cancelled)
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".floe").path))
    }

    @Test func cancellationWhileTheShareMapLookupIsSuspendedCreatesNothing() async throws {
        // The entry fence alone is not enough: cancellation can arrive while
        // the descriptor lookup is suspended. The post-await fence must stop
        // every later IO, so no reserved tree appears at all.
        let fixture = try makeBundleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.packageRoot) }
        let workspace = try makeTemporaryDirectory("workspace")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let map = makeWorkspaceShareMap(exporting: workspace)
        let gate = StageEntryGate()
        let stager = SkillWorkspaceResourceStager { _ in
            await gate.markEntered()
            try? await Task.sleep(nanoseconds: 400_000_000)
            return map
        }
        let token = CancellationToken()
        let call = Task { () -> SkillStageOutcome in
            await stage(stager, fixture, environmentID: "env", workspace: workspace, cancellation: token)
        }
        await gate.waitUntilEntered()
        token.cancel()
        let outcome = await call.value
        #expect(unavailableReason(outcome) == SkillStageReason.cancelled)
        #expect(stagedBundle(outcome) == nil)
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".floe").path))
    }

    @Test func cancellationDuringAReusedReadReturnsNoStagedPath() async throws {
        // A verified tree already exists; a cancellation that resolves during
        // the lookup must not hand the caller that path.
        let fixture = try makeBundleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.packageRoot) }
        let workspace = try makeTemporaryDirectory("workspace")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let map = makeWorkspaceShareMap(exporting: workspace)
        let first = await stage(
            SkillWorkspaceResourceStager { _ in map }, fixture,
            environmentID: "env", workspace: workspace)
        let staged = try #require(stagedBundle(first))
        #expect(staged.guestRoot == "/workspace/.floe/skills/\(fixture.leaf)")
        let stagedRoot = workspace.appendingPathComponent(".floe/skills/\(fixture.leaf)", isDirectory: true)

        let gate = StageEntryGate()
        let stager = SkillWorkspaceResourceStager { _ in
            await gate.markEntered()
            try? await Task.sleep(nanoseconds: 400_000_000)
            return map
        }
        let token = CancellationToken()
        let call = Task { () -> SkillStageOutcome in
            await stage(stager, fixture, environmentID: "env", workspace: workspace, cancellation: token)
        }
        await gate.waitUntilEntered()
        token.cancel()
        let outcome = await call.value
        #expect(unavailableReason(outcome) == SkillStageReason.cancelled)
        #expect(stagedBundle(outcome) == nil)
        // The already-verified tree is untouched and still byte-identical.
        #expect(try Data(contentsOf: stagedRoot.appendingPathComponent("scripts/new_notebook.py"))
            == fixture.snapshot.files["scripts/new_notebook.py"])
    }

    @Test func pinningLimitsRejectBeforeAnyWorkspaceWrite() async throws {
        let fixture = try makeBundleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.packageRoot) }
        let workspace = try makeTemporaryDirectory("workspace")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let stager = SkillWorkspaceResourceStager(
            limits: SkillValidationLimits(maximumFileBytes: 8),
            pathMappingProvider: { _ in makeWorkspaceShareMap(exporting: workspace) }
        )
        let outcome = await stage(stager, fixture, environmentID: "env", workspace: workspace)
        #expect(unavailableReason(outcome) == SkillStageReason.packageRejected)
        #expect((try FileManager.default.contentsOfDirectory(atPath: workspace.path)).isEmpty)
    }

    @Test func bundleValidationRejectsUnsafeIdentityPathsAndMismatchedBytes() {
        let digest = String(repeating: "a", count: 64)
        let files = [SkillFile(relativePath: "SKILL.md", byteCount: 1)]
        let bytes = ["SKILL.md": Data([0x01])]
        #expect(SkillWorkspaceResourceStager.stagingBundle(
            manifestID: "safe-id", digest: digest, declaredFiles: files, bytes: bytes, limits: .init()) != nil)
        for id in ["Bad/Id", "UPPER", "-leading", "", String(repeating: "a", count: 65)] {
            #expect(SkillWorkspaceResourceStager.stagingBundle(
                manifestID: id, digest: digest, declaredFiles: files, bytes: bytes, limits: .init()) == nil)
        }
        for badDigest in ["abc", String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
            #expect(SkillWorkspaceResourceStager.stagingBundle(
                manifestID: "safe-id", digest: badDigest, declaredFiles: files, bytes: bytes, limits: .init()) == nil)
        }
        for path in ["../SKILL.md", "/SKILL.md", "scripts/../x.py", "scripts//x.py", "scripts/", ""] {
            let declared = [SkillFile(relativePath: path, byteCount: 1)]
            #expect(SkillWorkspaceResourceStager.stagingBundle(
                manifestID: "safe-id", digest: digest, declaredFiles: declared,
                bytes: [path: Data([0x01])], limits: .init()) == nil, "path \(path)")
        }
        // Undeclared bytes and declared/actual size drift are rejected.
        #expect(SkillWorkspaceResourceStager.stagingBundle(
            manifestID: "safe-id", digest: digest, declaredFiles: files,
            bytes: ["SKILL.md": Data([0x01]), "extra.txt": Data()], limits: .init()) == nil)
        #expect(SkillWorkspaceResourceStager.stagingBundle(
            manifestID: "safe-id", digest: digest,
            declaredFiles: [SkillFile(relativePath: "SKILL.md", byteCount: 2)],
            bytes: bytes, limits: .init()) == nil)
    }

    @Test func canonicalDigestsAcceptDigitsAndRejectCaseOrNonASCII() {
        // Every real SHA-256 contains digits, and `Character.isLowercase` is
        // false for digits — so a case-property check rejects every real
        // digest. Validation must be exact ASCII `0-9a-f`.
        let mixed = "d41d8cd98f00b204e9800998ecf8427e5a1e67d8b9c0f3a24b6d8e0f1a2c3d45"
        let pureDigits = String(format: "%064x", 1)
        #expect(mixed.count == 64 && pureDigits.count == 64)
        #expect(SkillWorkspaceResourceStager.isCanonicalLowercaseHexDigest(mixed))
        #expect(SkillWorkspaceResourceStager.isCanonicalLowercaseHexDigest(pureDigits))
        #expect(!SkillWorkspaceResourceStager.isCanonicalLowercaseHexDigest(mixed.uppercased()))
        #expect(!SkillWorkspaceResourceStager.isCanonicalLowercaseHexDigest(String(mixed.dropLast()) + "G"))
        #expect(!SkillWorkspaceResourceStager.isCanonicalLowercaseHexDigest("abc"))
        // 62 ASCII bytes + one two-byte character = 64 UTF-8 bytes, not hex.
        let nonASCII = String(repeating: "a", count: 62) + "\u{00e9}"
        #expect(nonASCII.utf8.count == 64)
        #expect(!SkillWorkspaceResourceStager.isCanonicalLowercaseHexDigest(nonASCII))
        #expect(!SkillWorkspaceResourceStager.isCanonicalLowercaseHexDigest(
            String(repeating: "a", count: 63) + "\u{00e9}"))

        let files = [SkillFile(relativePath: "SKILL.md", byteCount: 1)]
        let bytes = ["SKILL.md": Data([0x01])]
        #expect(SkillWorkspaceResourceStager.stagingBundle(
            manifestID: "mixed-digest", digest: mixed, declaredFiles: files,
            bytes: bytes, limits: .init()) != nil)
        #expect(SkillWorkspaceResourceStager.stagingBundle(
            manifestID: "mixed-digest", digest: mixed.uppercased(), declaredFiles: files,
            bytes: bytes, limits: .init()) == nil)
        #expect(SkillWorkspaceResourceStager.stagingBundle(
            manifestID: "mixed-digest", digest: nonASCII, declaredFiles: files,
            bytes: bytes, limits: .init()) == nil)

        // Leaves parse with digits and reject case, non-ASCII and dot prefixes.
        let leaf = SkillWorkspaceResourceStager.parseLeaf("mixed-digest@\(mixed)")
        #expect(leaf?.skillID == "mixed-digest")
        #expect(leaf?.digest == mixed)
        #expect(SkillWorkspaceResourceStager.parseLeaf("mixed-digest@\(pureDigits)")?.digest == pureDigits)
        #expect(SkillWorkspaceResourceStager.parseLeaf("mixed-digest@\(mixed.uppercased())") == nil)
        #expect(SkillWorkspaceResourceStager.parseLeaf("mixed-digest@\(nonASCII)") == nil)
        #expect(SkillWorkspaceResourceStager.parseLeaf(".hidden@\(mixed)") == nil)
        #expect(SkillWorkspaceResourceStager.parseLeaf("mixed-digest") == nil)
    }

    @Test func pinnedRevisionsStayIndependentAcrossUpgradeAndResume() async throws {
        let fixture = try makeBundleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.packageRoot) }
        let workspace = try makeTemporaryDirectory("workspace")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let stager = SkillWorkspaceResourceStager { _ in makeWorkspaceShareMap(exporting: workspace) }
        let firstOutcome = await stage(stager, fixture, environmentID: "env", workspace: workspace)
        let first = try #require(stagedBundle(firstOutcome))

        // Reviewed upgrade: a new revision gets its own content-addressed tree.
        let upgradedRoot = try makeTemporaryDirectory("upgraded")
        defer { try? FileManager.default.removeItem(at: upgradedRoot) }
        let upgradedPackage = upgradedRoot.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.copyItem(at: fixture.packageRoot, to: upgradedPackage)
        let skillMarkdown = try String(
            contentsOf: upgradedPackage.appendingPathComponent("SKILL.md"), encoding: .utf8)
        try Data((skillMarkdown + "\nNew reviewed instructions.\n").utf8)
            .write(to: upgradedPackage.appendingPathComponent("SKILL.md"), options: .atomic)
        let upgradedValidated = try SkillPackageValidator().validate(packageAt: upgradedPackage)
        let upgraded = SkillBundleFixture(
            packageRoot: upgradedPackage,
            snapshot: try SkillContentSnapshot(root: upgradedPackage, expectedDigest: upgradedValidated.canonicalSHA256),
            skillID: fixture.skillID, digest: upgradedValidated.canonicalSHA256)
        let secondOutcome = await stage(stager, upgraded, environmentID: "env", workspace: workspace)
        let second = try #require(stagedBundle(secondOutcome))
        #expect(second.guestRoot != first.guestRoot)
        #expect(contentBundleNames(in: workspace) == [fixture.leaf, upgraded.leaf].sorted())

        // A resumed task pinned to the OLD digest reuses the original tree and
        // the upgrade never rewrote it.
        let resumedOutcome = await stage(stager, fixture, environmentID: "env", workspace: workspace)
        let resumed = try #require(stagedBundle(resumedOutcome))
        #expect(resumed.guestRoot == first.guestRoot)
        let oldScript = workspace.appendingPathComponent(
            ".floe/skills/\(fixture.leaf)/scripts/new_notebook.py")
        #expect(try Data(contentsOf: oldScript) == fixture.snapshot.files["scripts/new_notebook.py"])
    }

    @Test func concurrentStagingPublishesOneVerifiedTreePerPinnedDigest() async throws {
        let fixture = try makeBundleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.packageRoot) }
        let workspace = try makeTemporaryDirectory("workspace")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let map = makeWorkspaceShareMap(exporting: workspace)
        let firstStager = SkillWorkspaceResourceStager { _ in map }
        let secondStager = SkillWorkspaceResourceStager { _ in map }

        async let first = firstStager.stage(
            snapshot: fixture.snapshot,
            in: stageContext(environmentID: "env", workspace: workspace))
        async let second = secondStager.stage(
            snapshot: fixture.snapshot,
            in: stageContext(environmentID: "env", workspace: workspace))
        let outcomes = await [first, second]
        #expect(outcomes.allSatisfy { stagedBundle($0) != nil })
        #expect(Set(outcomes.compactMap { stagedBundle($0)?.guestRoot })
            == ["/workspace/.floe/skills/\(fixture.leaf)"])
        #expect(contentBundleNames(in: workspace) == [fixture.leaf])
        let stagedRoot = workspace.appendingPathComponent(".floe/skills/\(fixture.leaf)", isDirectory: true)
        for file in fixture.snapshot.package.files {
            #expect(try Data(contentsOf: stagedRoot.appendingPathComponent(file.relativePath))
                == fixture.snapshot.files[file.relativePath])
        }
    }

    @Test func retentionKeepsPinnedTreesAndRemovesOnlyProvenStagingTemps() async throws {
        let fixture = try makeBundleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.packageRoot) }
        let workspace = try makeTemporaryDirectory("workspace")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let reserved = workspace.appendingPathComponent(".floe/skills", isDirectory: true)
        let markers = reserved.appendingPathComponent(".markers", isDirectory: true)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)

        func hexDigest(_ seed: Int) -> String {
            String(format: "%064x", seed)
        }
        func plant(leaf: String, hoursOld: Double, markerDigest: String?, withContent: Bool = true) throws {
            let root = reserved.appendingPathComponent(leaf, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if withContent { try Data("x".utf8).write(to: root.appendingPathComponent("content.txt")) }
            guard let markerDigest else { return }
            let marker: [String: Any] = [
                "digest": markerDigest,
                "stagedAt": Date().timeIntervalSinceReferenceDate - hoursOld * 3_600
            ]
            try JSONSerialization.data(withJSONObject: marker)
                .write(to: markers.appendingPathComponent("\(leaf).json"))
        }
        let ownID = fixture.skillID
        let v1 = "\(ownID)@\(hexDigest(1))", v2 = "\(ownID)@\(hexDigest(2))", v3 = "\(ownID)@\(hexDigest(3))"
        let foreign = "other-skill@\(hexDigest(4))"
        let badMarker = "\(ownID)@\(hexDigest(5))"
        let markerless = "\(ownID)@\(hexDigest(6))"
        try plant(leaf: v1, hoursOld: 30, markerDigest: hexDigest(1))
        try plant(leaf: v2, hoursOld: 26, markerDigest: hexDigest(2))
        try plant(leaf: v3, hoursOld: 10, markerDigest: hexDigest(3))
        try plant(leaf: foreign, hoursOld: 30, markerDigest: hexDigest(4))
        try plant(leaf: badMarker, hoursOld: 30, markerDigest: hexDigest(5) + "0")
        try plant(leaf: markerless, hoursOld: 30, markerDigest: nil)
        try Data("user notes".utf8).write(to: reserved.appendingPathComponent("notes.txt"))
        let userDirectory = reserved.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)

        func plantStaging(_ name: String, hoursOld: Double?) throws -> URL {
            let url = reserved.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if let hoursOld {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(-hoursOld * 3_600)], ofItemAtPath: url.path)
            }
            return url
        }
        // Only a canonical `UUID().uuidString` suffix proves this helper made
        // the temporary: a stale one is removed, a fresh one proves a stage
        // is still in flight and is kept.
        let staleOwned = try plantStaging(
            SkillWorkspaceResourceStager.stagingPrefix + UUID().uuidString, hoursOld: 30)
        let liveOwned = try plantStaging(
            SkillWorkspaceResourceStager.stagingPrefix + UUID().uuidString, hoursOld: nil)
        // Prefix alone, a non-canonical case rendering and a planted symlink
        // are never treated as ours, even when old.
        let prefixOnly = try plantStaging(
            SkillWorkspaceResourceStager.stagingPrefix + "dead", hoursOld: 30)
        let foreignCase = try plantStaging(
            SkillWorkspaceResourceStager.stagingPrefix + UUID().uuidString.lowercased(), hoursOld: 30)
        let victim = try makeTemporaryDirectory("staging-victim")
        defer { try? FileManager.default.removeItem(at: victim) }
        let linkedTemp = reserved.appendingPathComponent(
            SkillWorkspaceResourceStager.stagingPrefix + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: linkedTemp, withDestinationURL: victim)

        // Staging the current revision triggers the retention pass.
        let stager = SkillWorkspaceResourceStager { _ in makeWorkspaceShareMap(exporting: workspace) }
        let outcome = await stage(stager, fixture, environmentID: "env", workspace: workspace)
        #expect(stagedBundle(outcome)?.guestRoot == "/workspace/.floe/skills/\(fixture.leaf)")

        let names = try FileManager.default.contentsOfDirectory(atPath: reserved.path)
        // No pinned tree is pruned by age: a task older than 24 h keeps every
        // tree it may still be executing from, including older revisions.
        #expect(Set(names) == Set([
            ".markers", fixture.leaf,
            v1, v2, v3, foreign, badMarker, markerless,
            "notes.txt", "scratch",
            liveOwned.lastPathComponent, prefixOnly.lastPathComponent,
            foreignCase.lastPathComponent, linkedTemp.lastPathComponent
        ]))
        #expect(!names.contains(staleOwned.lastPathComponent),
            "only a stale temporary with a canonical UUID name is removed")
        // Symlinked entries are left exactly as found; their target is untouched.
        #expect(SkillWorkspaceResourceStager.isSymbolicLink(linkedTemp))
        #expect((try FileManager.default.contentsOfDirectory(atPath: victim.path)).isEmpty)
    }
}

// MARK: - Real production route

@MainActor
private struct SkillReadRouteFixture {
    /// `SkillsCenter` holds its environment unowned, so the fixture must keep
    /// the environment alive for as long as the center is used.
    let environment: AppEnvironment
    let sandbox: URL
    let workspace: URL
    let installRoot: URL
    let center: SkillsCenter
    let tool: SkillReadTool
    let created: CreatedSkill
    let probe: ShareMapProbe
}

/// Builds the exact production chain with test-owned directories only:
/// real `SkillsCenter` (temporary installation root), real `LocalSkillCreator`
/// wrapper, the real `SkillReadTool`, and a descriptor-time share map injected
/// where `AppEnvironment` would supply the live Linux guest service.
@MainActor
private func makeSkillReadRouteFixture() async throws -> SkillReadRouteFixture {
    let environment = AppEnvironment.preview()
    try await environment.database.migrate()
    let sandbox = try makeTemporaryDirectory("skill-read-route")
    let installRoot = sandbox.appendingPathComponent("Skills", isDirectory: true)
    let workspace = sandbox.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let probe = ShareMapProbe(map: makeWorkspaceShareMap(exporting: workspace))
    let stager = SkillWorkspaceResourceStager { environmentID in await probe.lookup(environmentID) }
    let center = SkillsCenter(environment: environment, installationRoot: installRoot, resourceStager: stager)
    let created = try await center.createSkill(.init(
        name: "Workspace Resource Closure",
        description: "Fixture skill for the resource delivery route",
        instructions: "Use the bundled script and the sibling agent metadata.",
        pythonScripts: [.init(relativePath: "scripts/new_notebook.py", source: "print('fixture')\n")]
    ))
    return SkillReadRouteFixture(
        environment: environment,
        sandbox: sandbox, workspace: workspace, installRoot: installRoot, center: center,
        tool: SkillReadTool(manager: LocalSkillCreator(center: center)),
        created: created, probe: probe
    )
}

@Suite("Skill read production resource route")
@MainActor
struct SkillReadProductionResourceRouteTests {
    @Test func exactReadStagesThePinnedBundleThroughTheProductionWrapper() async throws {
        let fixture = try await makeSkillReadRouteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }
        let runID = UUID()
        let context = ToolContext(
            runID: runID, workspaceRootURL: fixture.workspace,
            cancellation: CancellationToken(), environmentID: "env-route"
        )

        let output = try await fixture.tool.execute(.init(id: fixture.created.id), context: context)
        let row = try #require(
            try JSONDecoder().decode([ManagedSkill].self, from: Data(output.summary.utf8)).first)
        #expect(row.id == fixture.created.id)
        #expect(row.resources?.staged == true)
        #expect(row.resources?.guestRoot
            == "/workspace/.floe/skills/\(fixture.created.id)@\(row.digest)")
        #expect(row.resources?.guestRoot?.contains(fixture.workspace.path) == false)
        #expect(row.resources?.pinnedSHA256 == row.digest)
        #expect(row.resources?.fileCount == 4)
        #expect(row.resources?.reason == nil)
        #expect(row.markdown?.contains("## Package files (Linux task workspace)") == true)
        #expect(row.markdown?.contains("staged=true") == true)
        #expect(row.markdown?.contains("$CODEX_HOME/skills/\(fixture.created.id)/") == true)
        #expect(row.markdown?.contains("Staged copy: /workspace/.floe/skills/") == true)

        // Cold read: the descriptor-time map was the ONLY lookup; no guest
        // console, boot or share change was involved.
        #expect(await fixture.probe.requests == ["env-route"])

        // The guest-visible tree is the complete pinned bundle: script plus its
        // sibling agent metadata, byte-identical to the installed package.
        let stagedRoot = try #require(row.resources?.guestRoot.map { guestRoot -> URL in
            let leaf = String(guestRoot.dropFirst("/workspace/".count))
            return fixture.workspace.appendingPathComponent(leaf, isDirectory: true)
        })
        for name in ["SKILL.md", "floe.json", "scripts/new_notebook.py", "agents/openai.yaml"] {
            #expect(FileManager.default.fileExists(atPath: stagedRoot.appendingPathComponent(name).path))
        }
        let stagedScript = try Data(
            contentsOf: stagedRoot.appendingPathComponent("scripts/new_notebook.py"))
        let installedScript = try Data(
            contentsOf: fixture.installRoot.appendingPathComponent(
                "\(fixture.created.id)/scripts/new_notebook.py"))
        #expect(stagedScript == Data("print('fixture')\n".utf8))
        #expect(stagedScript == installedScript)

        // Pagination cannot hide the execution root.
        let paged = try await fixture.tool.execute(
            .init(id: fixture.created.id, offset: 0, limit: 60), context: context)
        let pageRow = try #require(
            try JSONDecoder().decode([ManagedSkill].self, from: Data(paged.summary.utf8)).first)
        #expect(pageRow.markdown?.count == 60)
        #expect(pageRow.nextOffset == 60)
        #expect(pageRow.resources?.guestRoot == row.resources?.guestRoot)
    }

    @Test func listAndSearchNeverStageOrExposeARoot() async throws {
        let fixture = try await makeSkillReadRouteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }
        let context = ToolContext(
            runID: UUID(), workspaceRootURL: fixture.workspace,
            cancellation: CancellationToken(), environmentID: "env-route"
        )

        let listOutput = try await fixture.tool.execute(.init(), context: context)
        let listRows = try JSONDecoder().decode([ManagedSkill].self, from: Data(listOutput.summary.utf8))
        #expect(!listRows.isEmpty)
        #expect(listRows.allSatisfy { $0.resources == nil && $0.markdown == nil })

        _ = try await SkillSearchTool(manager: LocalSkillCreator(center: fixture.center))
            .execute(.init(queries: ["workspace resource closure"]), context: context)

        #expect(await fixture.probe.requests.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.workspace.appendingPathComponent(".floe").path))
    }

    @Test func foreignOrMissingBindingReportsUnavailableWithoutAPath() async throws {
        let fixture = try await makeSkillReadRouteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }

        // A foreign/unresolved environment: the provider (like the real guest
        // service for a remote or unbound run) has no map for it.
        let foreignContext = ToolContext(
            runID: UUID(), workspaceRootURL: fixture.workspace,
            cancellation: CancellationToken(), environmentID: "env-other"
        )
        let foreignOutput = try await fixture.tool.execute(
            .init(id: fixture.created.id), context: foreignContext)
        let foreignRow = try #require(
            try JSONDecoder().decode([ManagedSkill].self, from: Data(foreignOutput.summary.utf8)).first)
        #expect(foreignRow.resources?.staged == false)
        #expect(foreignRow.resources?.guestRoot == nil)
        #expect(foreignRow.resources?.reason == SkillStageReason.noShareMap)
        #expect(foreignRow.resources?.pinnedSHA256 == foreignRow.digest)
        #expect(foreignRow.markdown?.contains("staged=false") == true)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.workspace.appendingPathComponent(".floe").path))

        // Internal/UI reads without a tool context keep the historical shape.
        let plain = try await fixture.center.readSkills(id: fixture.created.id)
        #expect(plain.first?.resources == nil)
        #expect(plain.first?.markdown?.contains("## Package files") == false)
        #expect(plain.first?.markdown?.contains("### Audited source: scripts/new_notebook.py") == true)
    }

    @Test func temporaryChatReadsReportUnavailableAndNeverStage() async throws {
        let fixture = try await makeSkillReadRouteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }
        let context = ToolContext(
            runID: UUID(), workspaceRootURL: fixture.workspace,
            cancellation: CancellationToken(), environmentID: "env-route",
            temporaryReadOnly: true
        )
        let output = try await fixture.tool.execute(.init(id: fixture.created.id), context: context)
        let row = try #require(
            try JSONDecoder().decode([ManagedSkill].self, from: Data(output.summary.utf8)).first)
        // A temporary chat is RAM-only: the honest status is unavailable with
        // no guest path, and the workspace gains no cache tree.
        #expect(row.resources?.staged == false)
        #expect(row.resources?.guestRoot == nil)
        #expect(row.resources?.reason == SkillStageReason.noBoundEnvironment)
        #expect(row.markdown?.contains("staged=false") == true)
        #expect(await fixture.probe.requests.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.workspace.appendingPathComponent(".floe").path))
    }
}
#endif
