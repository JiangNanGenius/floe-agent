// SPDX-License-Identifier: MPL-2.0
//
// C08 B0 — model workspace-file tool relink.
//
// AUTHORED, NOT EXECUTED by this source-only lane. These tests run against the
// REAL `WorkspaceFileService`/`WorkspacePathGuard` on a synthetic temporary
// workspace and the REAL `C08WorkspaceFileTools` registration/runner surface
// (the same `AnyAgentTool` decoding a provider call uses). No fake file
// service and no second permission table are involved.
//
// Required Main sequence: apply MAIN_PATCH.diff (restores the original
// FloeWorkspace tool bodies) first; this test file will not compile before
// that patch, by design.
//
// Coverage:
//   * all ORIGINAL canonical handlers are reachable (not a metadata row only);
//   * the task `ToolContext.workspaceRootURL` is the only root and two task
//     roots never leak into one another;
//   * declared path ceilings, traversal, symlink escape and secret names;
//   * temporary chat and host scopes are refused before any effect;
//   * CAS conflict / atomic patch / no-overwrite create / move / copy / delete;
//   * bounded pagination, 64 KiB reads, search caps and binary refusal;
//   * cancellation leaves no effect;
//   * availability filtering removes the handlers from real discovery;
//   * append/replace text CAS semantics.

import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeWorkspace
@testable import FloeAndroidCore

final class C08WorkspaceFileToolTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots.removeAll()
    }

    // MARK: - Fixture

    private func makeRoot(_ label: String = "c08-files") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func install(available: Bool = true) -> ToolRunnerRegistry {
        let registry = ToolRunnerRegistry()
        C08WorkspaceFileTools.install(into: registry, isAvailable: { available })
        return registry
    }

    private func context(
        root: URL,
        allowed: [String] = [],
        temporary: Bool = false,
        scope: ToolScope = .local,
        cancellation: CancellationToken? = nil
    ) -> ToolContext {
        ToolContext(
            runID: UUID(),
            toolCallID: "c08-call",
            scope: scope,
            workspaceRootURL: root,
            allowedWorkspacePaths: allowed,
            cancellation: cancellation ?? CancellationToken(),
            temporaryReadOnly: temporary
        )
    }

    private func run(
        _ name: String,
        _ arguments: [String: Any],
        context: ToolContext,
        registry: ToolRunnerRegistry
    ) async throws -> ToolExecutionOutput {
        guard let runner = registry.runner(named: name) else {
            throw FloeError.notFound("runner \(name)")
        }
        let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return try await runner.execute(argumentsJSON: data, context: context)
    }

    private func write(_ text: String, to relativePath: String, in root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func read(_ relativePath: String, in root: URL) throws -> String {
        let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
        return String(decoding: data, as: UTF8.self)
    }

    private func exists(_ relativePath: String, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    private func sha(_ text: String) -> String {
        FloeDigest.sha256Hex(Data(text.utf8))
    }

    // MARK: - Real reachability

    func testInstalledSurfaceReachesRealOriginalHandlers() async throws {
        let root = try makeRoot()
        try write("hello\n", to: "notes/a.txt", in: root)
        let registry = install()
        let ctx = context(root: root)

        let expected: Set<String> = [
            "workspace.listDirectory", "workspace.readFile", "workspace.searchFiles",
            "workspace.inspectFileMetadata", "workspace.createFile",
            "workspace.appendFile", "workspace.replaceText", "workspace.writeFile",
            "workspace.applyPatch", "workspace.moveFile", "workspace.deleteFile",
            "workspace.createDirectory", "workspace.copyFile",
        ]
        XCTAssertEqual(Set(C08WorkspaceFileTools.toolNames), expected)
        for name in expected {
            XCTAssertNotNil(registry.runner(named: name), "missing real runner for \(name)")
        }
        XCTAssertEqual(Set(registry.allDescriptors.map(\.name)), expected)

        let list = try await run("workspace.listDirectory", ["path": "."], context: ctx, registry: registry)
        XCTAssertTrue(list.summary.contains("entries=1"), list.summary)
        XCTAssertTrue(list.summary.contains("\tnotes"), list.summary)

        let read = try await run("workspace.readFile", ["path": "notes/a.txt"], context: ctx, registry: registry)
        XCTAssertTrue(read.summary.contains("hello"), read.summary)
        XCTAssertTrue(read.summary.contains("truncated=false"), read.summary)
    }

    func testTaskContextRootsDoNotLeak() async throws {
        let rootA = try makeRoot("task-a")
        let rootB = try makeRoot("task-b")
        try write("A", to: "a.txt", in: rootA)
        try write("B", to: "b.txt", in: rootB)
        let registry = install()

        let listingA = try await run(
            "workspace.listDirectory", ["path": "."],
            context: context(root: rootA), registry: registry)
        XCTAssertTrue(listingA.summary.contains("a.txt"), listingA.summary)
        XCTAssertFalse(listingA.summary.contains("b.txt"), listingA.summary)

        let listingB = try await run(
            "workspace.listDirectory", ["path": "."],
            context: context(root: rootB), registry: registry)
        XCTAssertTrue(listingB.summary.contains("b.txt"), listingB.summary)
        XCTAssertFalse(listingB.summary.contains("a.txt"), listingB.summary)

        _ = try await run(
            "workspace.createFile",
            ["path": "only-a.txt", "content": "x"],
            context: context(root: rootA), registry: registry)
        XCTAssertTrue(exists("only-a.txt", in: rootA))
        XCTAssertFalse(exists("only-a.txt", in: rootB))
    }

    // MARK: - Authority / path failure

    func testDeclaredPathCeilingTraversalSymlinkAndSecret() async throws {
        let root = try makeRoot()
        let outside = try makeRoot("outside")
        try write("inside", to: "allowed/ok.txt", in: root)
        try write("private", to: "private/no.txt", in: root)
        try write("outside", to: "outside.txt", in: outside)
        try write("secret", to: ".env", in: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.txt"),
            withDestinationURL: outside.appendingPathComponent("outside.txt"))
        let registry = install()

        let ok = try await run(
            "workspace.readFile", ["path": "allowed/ok.txt"],
            context: context(root: root, allowed: ["allowed"]), registry: registry)
        XCTAssertTrue(ok.summary.contains("inside"), ok.summary)

        do {
            _ = try await run(
                "workspace.readFile", ["path": "private/no.txt"],
                context: context(root: root, allowed: ["allowed"]), registry: registry)
            XCTFail("declared path ceiling must refuse private/no.txt")
        } catch let error as FloeError {
            guard case .validationFailed = error else {
                return XCTFail("expected validationFailed, got \(error)")
            }
        }

        do {
            _ = try await run(
                "workspace.readFile", ["path": "../outside.txt"],
                context: context(root: root), registry: registry)
            XCTFail("traversal must be refused")
        } catch let error as WorkspaceToolError {
            guard case .escapesRoot = error else {
                return XCTFail("expected escapesRoot, got \(error)")
            }
        }

        do {
            _ = try await run(
                "workspace.readFile", ["path": "escape.txt"],
                context: context(root: root), registry: registry)
            XCTFail("symlink escape must be refused")
        } catch let error as WorkspaceToolError {
            guard case .escapesRoot = error else {
                return XCTFail("expected escapesRoot, got \(error)")
            }
        }

        do {
            _ = try await run(
                "workspace.readFile", ["path": ".env"],
                context: context(root: root), registry: registry)
            XCTFail("secret file must be refused")
        } catch let error as WorkspaceToolError {
            guard case .secretFile = error else {
                return XCTFail("expected secretFile, got \(error)")
            }
        }
    }

    func testTemporaryAndHostScopesAreRefusedBeforeAnyEffect() async throws {
        let root = try makeRoot()
        let registry = install()

        do {
            _ = try await run(
                "workspace.createFile",
                ["path": "temporary.txt", "content": "must not exist"],
                context: context(root: root, temporary: true), registry: registry)
            XCTFail("temporary chat write must be refused")
        } catch let error as WorkspaceToolError {
            guard case .unsupportedScope = error else {
                return XCTFail("expected unsupportedScope, got \(error)")
            }
        }
        XCTAssertFalse(exists("temporary.txt", in: root))

        do {
            _ = try await run(
                "workspace.readFile", ["path": "."],
                context: context(root: root, scope: .host(UUID())), registry: registry)
            XCTFail("host scope must be refused")
        } catch let error as WorkspaceToolError {
            guard case .unsupportedScope = error else {
                return XCTFail("expected unsupportedScope, got \(error)")
            }
        }
    }

    // MARK: - Writes / CAS / patch

    func testWriteConflictIsReportedAndLeavesFileUntouched() async throws {
        let root = try makeRoot()
        try write("original", to: "doc.txt", in: root)
        let registry = install()
        let ctx = context(root: root)

        do {
            _ = try await run(
                "workspace.writeFile",
                ["path": "doc.txt", "content": "changed", "expectedSHA256": sha("wrong")],
                context: ctx, registry: registry)
            XCTFail("stale digest must conflict")
        } catch let error as WorkspaceToolError {
            guard case .conflict = error else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
        XCTAssertEqual(try read("doc.txt", in: root), "original")

        _ = try await run(
            "workspace.writeFile",
            ["path": "doc.txt", "content": "changed", "expectedSHA256": sha("original")],
            context: ctx, registry: registry)
        XCTAssertEqual(try read("doc.txt", in: root), "changed")
    }

    func testCreateNoOverwriteAndPatchAtomicity() async throws {
        let root = try makeRoot()
        let registry = install()
        let ctx = context(root: root)

        _ = try await run(
            "workspace.createFile", ["path": "a.txt", "content": "one\n"],
            context: ctx, registry: registry)
        do {
            _ = try await run(
                "workspace.createFile", ["path": "a.txt", "content": "two\n"],
                context: ctx, registry: registry)
            XCTFail("createFile must not overwrite by default")
        } catch let error as WorkspaceToolError {
            guard case .alreadyExistsOverwritable = error else {
                return XCTFail("expected alreadyExistsOverwritable, got \(error)")
            }
        }
        XCTAssertEqual(try read("a.txt", in: root), "one\n")

        let badPatch = "--- a/a.txt\n+++ b/a.txt\n@@ -1,1 +1,1 @@\n-missing\n+two\n"
        do {
            _ = try await run(
                "workspace.applyPatch", ["path": "a.txt", "patch": badPatch],
                context: ctx, registry: registry)
            XCTFail("context mismatch patch must fail")
        } catch let error as WorkspaceToolError {
            guard case .invalidPatch = error else {
                return XCTFail("expected invalidPatch, got \(error)")
            }
        }
        XCTAssertEqual(try read("a.txt", in: root), "one\n")

        let goodPatch = "--- a/a.txt\n+++ b/a.txt\n@@ -1,1 +1,2 @@\n one\n+two\n"
        _ = try await run(
            "workspace.applyPatch", ["path": "a.txt", "patch": goodPatch],
            context: ctx, registry: registry)
        XCTAssertEqual(try read("a.txt", in: root), "one\ntwo\n")
    }

    func testMoveCopyDeleteOnlyExactOwners() async throws {
        let root = try makeRoot()
        try write("x", to: "from.txt", in: root)
        let registry = install()
        let ctx = context(root: root)

        _ = try await run(
            "workspace.copyFile", ["from": "from.txt", "to": "copy.txt"],
            context: ctx, registry: registry)
        XCTAssertEqual(try read("copy.txt", in: root), "x")
        XCTAssertTrue(exists("from.txt", in: root))

        _ = try await run(
            "workspace.moveFile", ["from": "copy.txt", "to": "moved.txt"],
            context: ctx, registry: registry)
        XCTAssertFalse(exists("copy.txt", in: root))
        XCTAssertEqual(try read("moved.txt", in: root), "x")

        try write("y", to: "dir/child.txt", in: root)
        do {
            _ = try await run(
                "workspace.deleteFile", ["path": "dir"],
                context: ctx, registry: registry)
            XCTFail("non-empty directory delete without recursive must fail")
        } catch let error as WorkspaceToolError {
            guard case .invalidArguments = error else {
                return XCTFail("expected invalidArguments, got \(error)")
            }
        }
        XCTAssertTrue(exists("dir/child.txt", in: root))

        _ = try await run(
            "workspace.deleteFile", ["path": "dir", "recursive": true],
            context: ctx, registry: registry)
        XCTAssertFalse(exists("dir/child.txt", in: root))

        do {
            _ = try await run(
                "workspace.deleteFile", ["path": "."],
                context: ctx, registry: registry)
            XCTFail("the workspace root is not a delete target")
        } catch let error as WorkspaceToolError {
            guard case .invalidArguments = error else {
                return XCTFail("expected invalidArguments, got \(error)")
            }
        }
    }

    // MARK: - Bounded reads / pagination / binary

    func testBoundedPaginationReadsSearchAndBinaryRefusal() async throws {
        let root = try makeRoot()
        for index in 0..<205 {
            try write("entry \(index)\n", to: "many/f\(index).txt", in: root)
        }
        let longLine = String(repeating: "a", count: 200)
        let longText = (0..<600).map { "\($0) \(longLine)" }.joined(separator: "\n")
        try write(longText, to: "big.txt", in: root)
        try Data([0x41, 0x00, 0x42]).write(to: root.appendingPathComponent("binary.bin"))
        let registry = install()
        let ctx = context(root: root)

        let first = try await run(
            "workspace.listDirectory", ["path": "many"], context: ctx, registry: registry)
        XCTAssertTrue(first.summary.contains("entries=200"), first.summary)
        guard let tokenRange = first.summary.range(of: "nextPageToken=") else {
            return XCTFail("first page must report a cursor: \(first.summary)")
        }
        let token = first.summary[tokenRange.upperBound...]
            .split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertFalse(token.isEmpty)

        let second = try await run(
            "workspace.listDirectory", ["path": "many", "pageToken": token],
            context: ctx, registry: registry)
        XCTAssertTrue(second.summary.contains("entries=5"), second.summary)
        XCTAssertFalse(second.summary.contains("nextPageToken="), second.summary)

        let read = try await run(
            "workspace.readFile", ["path": "big.txt"], context: ctx, registry: registry)
        XCTAssertTrue(read.summary.contains("truncated=true"), read.summary)
        XCTAssertTrue(read.summary.contains("totalLines=600"), read.summary)
        XCTAssertLessThanOrEqual(read.summary.utf8.count, 70 * 1024)

        let hit = try await run(
            "workspace.searchFiles", ["query": "entry 204"], context: ctx, registry: registry)
        XCTAssertTrue(hit.summary.contains("f204.txt"), hit.summary)

        let metadata = try await run(
            "workspace.inspectFileMetadata", ["path": "big.txt"],
            context: ctx, registry: registry)
        XCTAssertTrue(metadata.summary.contains("sha256=\(sha(longText))"), metadata.summary)

        do {
            _ = try await run(
                "workspace.readFile", ["path": "binary.bin"],
                context: ctx, registry: registry)
            XCTFail("binary bytes must not be presented as invented text")
        } catch let error as WorkspaceToolError {
            guard case .unsupportedContent = error else {
                return XCTFail("expected unsupportedContent, got \(error)")
            }
        }
    }

    // MARK: - Cancellation

    func testCancellationLeavesNoEffect() async throws {
        let root = try makeRoot()
        try write("stable", to: "stable.txt", in: root)
        let registry = install()
        let token = CancellationToken()
        token.cancel()
        let ctx = context(root: root, cancellation: token)

        do {
            _ = try await run(
                "workspace.writeFile",
                ["path": "stable.txt", "content": "changed"],
                context: ctx, registry: registry)
            XCTFail("cancelled write must not run")
        } catch let error as FloeError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(try read("stable.txt", in: root), "stable")

        do {
            _ = try await run(
                "workspace.createFile", ["path": "new.txt", "content": "x"],
                context: ctx, registry: registry)
            XCTFail("cancelled create must not run")
        } catch let error as FloeError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertFalse(exists("new.txt", in: root))

        do {
            _ = try await run(
                "workspace.deleteFile", ["path": "stable.txt"],
                context: ctx, registry: registry)
            XCTFail("cancelled delete must not run")
        } catch let error as FloeError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertTrue(exists("stable.txt", in: root))
    }

    // MARK: - Discovery availability

    func testAvailabilityFiltersTheRealDiscoverySurface() async throws {
        let registry = install(available: false)
        XCTAssertTrue(registry.allDescriptors.isEmpty)
        for name in C08WorkspaceFileTools.toolNames {
            XCTAssertNil(registry.runner(named: name))
        }

        let live = install(available: true)
        XCTAssertEqual(Set(live.allDescriptors.map(\.name)), Set(C08WorkspaceFileTools.toolNames))
    }

    // MARK: - Append / replace original CAS tools

    func testAppendAndReplaceAreCasBound() async throws {
        let root = try makeRoot()
        try write("alpha", to: "text.md", in: root)
        let registry = install()
        let ctx = context(root: root)

        _ = try await run(
            "workspace.appendFile",
            ["path": "text.md", "content": "-beta", "expectedSHA256": sha("alpha")],
            context: ctx, registry: registry)
        XCTAssertEqual(try read("text.md", in: root), "alpha-beta")

        do {
            _ = try await run(
                "workspace.replaceText",
                ["path": "text.md", "oldText": "beta", "newText": "gamma", "expectedOccurrences": 2],
                context: ctx, registry: registry)
            XCTFail("occurrence mismatch must be refused")
        } catch let error as WorkspaceToolError {
            guard case .invalidArguments = error else {
                return XCTFail("expected invalidArguments, got \(error)")
            }
        }
        XCTAssertEqual(try read("text.md", in: root), "alpha-beta")

        _ = try await run(
            "workspace.replaceText",
            ["path": "text.md", "oldText": "beta", "newText": "gamma",
             "expectedOccurrences": 1, "expectedSHA256": sha("alpha-beta")],
            context: ctx, registry: registry)
        XCTAssertEqual(try read("text.md", in: root), "alpha-gamma")
    }
}
