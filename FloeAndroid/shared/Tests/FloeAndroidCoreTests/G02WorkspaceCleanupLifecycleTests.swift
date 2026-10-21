// SPDX-License-Identifier: MPL-2.0
//
// G02-R7 owned private-workspace directory cleanup — AUTHORED, NOT RUN.
// This lane authors source only; the combined qualification compiles and
// executes it later.
//
// Contract under test (the real R5 failure was a DETERMINISTIC false
// refusal: `URL(fileURLWithPath:)` resolved the relative path against the
// process CWD, the result is always absolute, and the old guard rejected
// every absolute path as traversal — so every real cleanup died as the
// opaque `privateWorkspaceCleanupUnavailable`):
//  * owned directory present        -> actually removed, counted `.removed`;
//  * owned directory absent         -> `.absent` (goal already reached —
//                                      never a failure, never a removal);
//  * absolute / traversal input     -> typed refusal, filesystem untouched;
//  * non-`PrivateTasks/<uuid>` shape-> typed `workspacePathShape` refusal
//                                      (model-supplied URLs/prefixes can
//                                      never be expressed);
//  * symlink / regular file / dangling symlink at the owned path
//                                   -> typed `workspaceTargetForeign`
//                                      refusal; the link, its destination
//                                      and the file content stay intact;
//  * privacy.history.clear integration: per-conversation ownership facts
//    (no surviving references, kind + exact internal_relative_path
//    re-check, ORIGINAL row removal, bounded directory removal, durable V36
//    retirement) with truthful removed/absent/deferred accounting in the
//    report — project workspaces, Notes data and external repositories
//    are never touched.
// All filesystem fixtures are synthetic temporary roots owned by the test.
import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeAgentRuntime
@testable import FloeAndroidCore

// MARK: - Direct cleaner contract (real filesystem, synthetic roots)

final class G02WorkspaceCleaningTests: XCTestCase {

    private var root: URL!
    private var rootToken: RuntimeStorageRoot!
    private var cleaner: G02WorkspaceCleaning!

    override func setUp() async throws {
        let base = androidTestFixtureDirectory
            .appendingPathComponent("FloeG02Cleaning-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("Workspace", isDirectory: true),
            withIntermediateDirectories: true)
        root = base.standardizedFileURL
        rootToken = try XCTUnwrap(
            RuntimeStorageRoot(validatingAbsoluteDirectory: root.path))
        cleaner = G02WorkspaceCleaning(root: rootToken)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func ownedDirectory(_ id: UUID, fileBody: String = "task") throws -> URL {
        let dir = root.appendingPathComponent("Workspace/PrivateTasks/\(id.uuidString)",
                                              isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(fileBody.utf8).write(to: dir.appendingPathComponent("notes.md"))
        return dir
    }

    func testOwnedDirectoryIsActuallyRemoved() async throws {
        let id = UUID()
        let dir = try ownedDirectory(id)
        let outcome = try await cleaner.removePrivateTaskDirectory(
            relativePath: "PrivateTasks/\(id.uuidString)")
        XCTAssertEqual(outcome, .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        // The managed root itself survives.
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testAbsentDirectoryIsTheGoalStateNotAFailure() async throws {
        let id = UUID()
        let outcome = try await cleaner.removePrivateTaskDirectory(
            relativePath: "PrivateTasks/\(id.uuidString)")
        XCTAssertEqual(outcome, .absent)
    }

    func testAbsolutePathRefusedBeforeAnyFilesystemEffect() async throws {
        let victim = root.appendingPathComponent("Workspace/PrivateTasks/victim",
                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        do {
            _ = try await cleaner.removePrivateTaskDirectory(
                relativePath: victim.path)
            XCTFail("an absolute path must refuse typed")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireReason, "workspacePathTraversal")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
    }

    func testTraversalComponentsRefuseAndNeverEscapeTheRoot() async throws {
        let outside = androidTestFixtureDirectory
            .appendingPathComponent("FloeG02Outside-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        for bad in ["../Outside/\(UUID().uuidString)",
                    "PrivateTasks/../..",
                    "PrivateTasks/\(UUID().uuidString)/../../.."] {
            do {
                _ = try await cleaner.removePrivateTaskDirectory(relativePath: bad)
                XCTFail("traversal path must refuse: \(bad)")
            } catch let error as ConversationDomainError {
                XCTAssertEqual(error.wireReason, "workspacePathTraversal",
                               "unexpected refusal for \(bad)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testNonPrivateTaskShapesRefuseAndForeignTreesStayIntact() async throws {
        // A sibling tree that is NOT an owned private-task directory (e.g.
        // project/Notes-like data living under the managed root) must be
        // unreachable through this port.
        let foreign = root.appendingPathComponent("Workspace/Notes/\(UUID().uuidString)",
                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        for bad in ["Notes/\(UUID().uuidString)",
                    "PrivateTasks/not-a-uuid",
                    "PrivateTasks/\(UUID().uuidString)/nested",
                    "Other/\(UUID().uuidString)"] {
            do {
                _ = try await cleaner.removePrivateTaskDirectory(relativePath: bad)
                XCTFail("non-owned shape must refuse: \(bad)")
            } catch let error as ConversationDomainError {
                XCTAssertEqual(error.wireReason, "workspacePathShape",
                               "unexpected refusal for \(bad)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }

    func testSymlinkAtOwnedPathRefusesWithoutTouchingDestination() async throws {
        let id = UUID()
        let destination = androidTestFixtureDirectory
            .appendingPathComponent("FloeG02Destination-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("user-file.md")
        try Data("precious".utf8).write(to: marker)
        defer { try? FileManager.default.removeItem(at: destination) }

        let owned = root.appendingPathComponent("Workspace/PrivateTasks/\(id.uuidString)",
                                                isDirectory: true)
        try FileManager.default.createDirectory(
            at: owned.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: owned.path, withDestinationPath: destination.path)
        do {
            _ = try await cleaner.removePrivateTaskDirectory(
                relativePath: "PrivateTasks/\(id.uuidString)")
            XCTFail("a symlink at the owned path is foreign and must refuse")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireReason, "workspaceTargetForeign")
        }
        // Both the link and its destination survive untouched.
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path, isDirectory: &isDir))
        let linkValues = try owned.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertTrue(linkValues.isSymbolicLink == true)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "precious")
    }

    func testRegularFileAtOwnedPathRefusesWithContentIntact() async throws {
        let id = UUID()
        let owned = root.appendingPathComponent("Workspace/PrivateTasks/\(id.uuidString)")
        try FileManager.default.createDirectory(
            at: owned.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: owned)
        do {
            _ = try await cleaner.removePrivateTaskDirectory(
                relativePath: "PrivateTasks/\(id.uuidString)")
            XCTFail("a regular file at the owned path is foreign and must refuse")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireReason, "workspaceTargetForeign")
        }
        XCTAssertEqual(try String(contentsOf: owned, encoding: .utf8), "precious")
    }

    func testEmbeddedSymlinkInsideOwnedTreeCannotRedirectDeletion() async throws {
        let id = UUID()
        let outside = androidTestFixtureDirectory
            .appendingPathComponent("FloeG02Embed-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("keep.md")
        try Data("keep".utf8).write(to: outsideFile)
        defer { try? FileManager.default.removeItem(at: outside) }

        let dir = try ownedDirectory(id)
        try FileManager.default.createSymbolicLink(
            atPath: dir.appendingPathComponent("link.md").path,
            withDestinationPath: outsideFile.path)
        let outcome = try await cleaner.removePrivateTaskDirectory(
            relativePath: "PrivateTasks/\(id.uuidString)")
        XCTAssertEqual(outcome, .removed)
        // The owned tree is gone; the linked-outside file survives.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(try String(contentsOf: outsideFile, encoding: .utf8), "keep")
    }

    // MARK: G02-R7 ancestor/containment truth

    func testWorkspaceAncestorSymlinkRefusesWithoutTouchingExternalData() async throws {
        let id = UUID()
        let destination = androidTestFixtureDirectory
            .appendingPathComponent("FloeG02WsAncestor-\(UUID().uuidString)",
                                    isDirectory: true)
        let externalTask = destination
            .appendingPathComponent("PrivateTasks/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalTask,
                                                withIntermediateDirectories: true)
        let marker = externalTask.appendingPathComponent("user-data.md")
        try Data("external".utf8).write(to: marker)
        defer { try? FileManager.default.removeItem(at: destination) }

        let workspace = root.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.removeItem(at: workspace)
        try FileManager.default.createSymbolicLink(atPath: workspace.path,
                                                   withDestinationPath: destination.path)
        do {
            _ = try await cleaner.removePrivateTaskDirectory(
                relativePath: "PrivateTasks/\(id.uuidString)")
            XCTFail("a symlinked managed root is foreign and must refuse")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireReason, "workspaceTargetForeign")
        }
        // The link itself and every external byte survive.
        let link = try workspace.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertTrue(link.isSymbolicLink == true)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "external")
    }

    func testPrivateTasksAncestorSymlinkRefusesWithoutTouchingExternalData() async throws {
        let id = UUID()
        let destination = androidTestFixtureDirectory
            .appendingPathComponent("FloeG02PtAncestor-\(UUID().uuidString)",
                                    isDirectory: true)
        let externalTask = destination.appendingPathComponent("\(id.uuidString)",
                                                              isDirectory: true)
        try FileManager.default.createDirectory(at: externalTask,
                                                withIntermediateDirectories: true)
        let marker = externalTask.appendingPathComponent("user-data.md")
        try Data("external".utf8).write(to: marker)
        defer { try? FileManager.default.removeItem(at: destination) }

        let privateTasks = root.appendingPathComponent(
            "Workspace/PrivateTasks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: privateTasks.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: privateTasks.path,
                                                   withDestinationPath: destination.path)
        do {
            _ = try await cleaner.removePrivateTaskDirectory(
                relativePath: "PrivateTasks/\(id.uuidString)")
            XCTFail("a symlinked PrivateTasks ancestor is foreign and must refuse")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireReason, "workspaceTargetForeign")
        }
        let link = try privateTasks.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertTrue(link.isSymbolicLink == true)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "external")
    }

    func testDanglingSymlinkAtOwnedPathRefusesInsteadOfReportingAbsent() async throws {
        let id = UUID()
        let danglingTarget = androidTestFixtureDirectory
            .appendingPathComponent("FloeG02Missing-\(UUID().uuidString)")
        let owned = root.appendingPathComponent("Workspace/PrivateTasks/\(id.uuidString)")
        try FileManager.default.createDirectory(
            at: owned.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: owned.path,
                                                   withDestinationPath: danglingTarget.path)
        do {
            _ = try await cleaner.removePrivateTaskDirectory(
                relativePath: "PrivateTasks/\(id.uuidString)")
            XCTFail("a dangling symlink still occupies the owned path")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireReason, "workspaceTargetForeign")
        }
        // `fileExists` would follow the link and say false; the link itself
        // must still be there and untouched.
        let link = try owned.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertTrue(link.isSymbolicLink == true)
    }

    func testNonDirectoryPrivateTasksAncestorRefuses() async throws {
        let id = UUID()
        let privateTasks = root.appendingPathComponent("Workspace/PrivateTasks")
        try Data("not-a-directory".utf8).write(to: privateTasks)
        do {
            _ = try await cleaner.removePrivateTaskDirectory(
                relativePath: "PrivateTasks/\(id.uuidString)")
            XCTFail("a regular file where PrivateTasks belongs is foreign")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireReason, "workspaceTargetForeign")
        }
        XCTAssertEqual(try String(contentsOf: privateTasks, encoding: .utf8),
                       "not-a-directory")
    }

    func testUnreadableAncestorIsTypedFailureNeverAbsent() async throws {
        if geteuid() == 0 { throw XCTSkip("permission enforcement is bypassed as root") }
        let id = UUID()
        let dir = try ownedDirectory(id)
        let privateTasks = dir.deletingLastPathComponent()
        let original = try FileManager.default.attributesOfItem(
            atPath: privateTasks.path)[.posixPermissions] as? NSNumber
        let restore = {
            if let original {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: original], ofItemAtPath: privateTasks.path)
            }
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o000)],
            ofItemAtPath: privateTasks.path)
        defer { restore() }
        do {
            _ = try await cleaner.removePrivateTaskDirectory(
                relativePath: "PrivateTasks/\(id.uuidString)")
            XCTFail("EACCES must never be reported as absence")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "runtimeUnavailable")
            XCTAssertEqual(error.wireReason, "workspaceTargetUnreadable")
        }
        restore()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    func testMissingManagedAncestorsAreAuthoritativeAbsence() async throws {
        // Nothing at all: Workspace itself is absent.
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("Workspace", isDirectory: true))
        let id = UUID()
        let outcome = try await cleaner.removePrivateTaskDirectory(
            relativePath: "PrivateTasks/\(id.uuidString)")
        XCTAssertEqual(outcome, .absent)
        // Absence is a READ: the cleaner must not materialize a root.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Workspace").path))
        // Workspace exists but PrivateTasks is absent.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Workspace", isDirectory: true),
            withIntermediateDirectories: true)
        let second = try await cleaner.removePrivateTaskDirectory(
            relativePath: "PrivateTasks/\(UUID().uuidString)")
        XCTAssertEqual(second, .absent)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Workspace/PrivateTasks").path))
    }

    func testEmbeddedNULIsRefusedBeforeAnyFilesystemCall() async throws {
        let id = UUID()
        do {
            _ = try await cleaner.removePrivateTaskDirectory(
                relativePath: "PrivateTasks/\(id.uuidString)\u{0}tail")
            XCTFail("an embedded NUL must refuse before POSIX truncation")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireReason, "workspacePathTraversal")
        }
    }
}

// MARK: - privacy.history.clear integration (real stores, synthetic root)

final class G02HistoryClearWorkspaceCleanupTests: XCTestCase {

    private func makeCleaning(root: URL) throws -> G02WorkspaceCleaning {
        G02WorkspaceCleaning(root: try XCTUnwrap(
            RuntimeStorageRoot(validatingAbsoluteDirectory: root.standardizedFileURL.path)))
    }

    private func ownedDirectoryURL(root: URL, conversationID: UUID) -> URL {
        root.appendingPathComponent(
            "Workspace/PrivateTasks/\(conversationID.uuidString)", isDirectory: true)
    }

    private func seedOwnedDirectory(root: URL, conversationID: UUID) throws {
        let dir = ownedDirectoryURL(root: root, conversationID: conversationID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("task file".utf8).write(to: dir.appendingPathComponent("notes.md"))
    }

    private func historyRevision(_ assembly: PrivacyFacadeAssembly) async throws -> String {
        try await assembly.facade.summary().history.revision
    }

    private func clearHistory(_ assembly: PrivacyFacadeAssembly,
                              invocation: String = "inv-ws-clear") async throws
        -> PrivacyHistoryClearReport
    {
        let digest = try await historyRevision(assembly)
        let token = privacyIssue(assembly, digest: digest, invocation: invocation)!
        return try await assembly.facade.clearHistory(
            request: PrivacyClearRequest(confirmToken: token),
            revision: BaseRevision(resourceID: RuntimeFacadePrivacy.historyResourceID,
                                   version: digest),
            invocationID: invocation)
    }

    private func tableCount(_ stores: PrivacyTestBed.Stores, _ sql: String,
                            _ arguments: StatementArguments = []) async throws -> Int {
        try await PrivacyTestBed.count(stores.database, sql, arguments)
    }

    func testClearRemovesOwnedDirectoryAndReportsTruthfulAccounting() async throws {
        let stores = try await PrivacyTestBed.stores(name: "ws-removed")
        let conversation = try await PrivacyTestBed.seedConversation(stores)
        _ = try await stores.workspaces.ensureWorkspace(conversationID: conversation,
                                                        title: "owned task")
        try seedOwnedDirectory(root: stores.directory, conversationID: conversation)
        let cleaning = try makeCleaning(root: stores.directory)
        let assembly = PrivacyFacadeFactory.make(stores: stores,
                                                 workspaceCleaning: cleaning)
        let report = try await clearHistory(assembly)

        XCTAssertEqual(report.workspaceDirectories?.removed, 1)
        XCTAssertEqual(report.workspaceDirectories?.absent, 0)
        XCTAssertEqual(report.workspaceDirectories?.deferred, 0)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(report.partial)
        // The owned on-disk tree, the workspace row and the durable V36
        // queue row are all retired by the SAME authoritative lifecycle.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ownedDirectoryURL(root: stores.directory,
                                      conversationID: conversation).path))
        let privateTaskRows = try await tableCount(
            stores, "SELECT COUNT(*) FROM workspaces WHERE kind = 'privateTask'")
        XCTAssertEqual(privateTaskRows, 0)
        let queuedRows = try await tableCount(
            stores, "SELECT COUNT(*) FROM local_workspace_cleanup")
        XCTAssertEqual(queuedRows, 0)
        let conversationRows = try await tableCount(
            stores, "SELECT COUNT(*) FROM conversations WHERE id = ?",
            [conversation.uuidString])
        XCTAssertEqual(conversationRows, 0)
    }

    func testClearCountsAbsentDirectoryAsGoalReachedNotFailure() async throws {
        // EXACT R5 scenario shape: workspace ownership row exists, the
        // on-disk directory was never materialized (nothing wrote there).
        // The old build reported the opaque privateWorkspaceCleanupUnavailable
        // per conversation; the truthful effect is `.absent`.
        let stores = try await PrivacyTestBed.stores(name: "ws-absent")
        let conversation = try await PrivacyTestBed.seedConversation(stores)
        _ = try await stores.workspaces.ensureWorkspace(conversationID: conversation,
                                                        title: "never materialized")
        let cleaning = try makeCleaning(root: stores.directory)
        let assembly = PrivacyFacadeFactory.make(stores: stores,
                                                 workspaceCleaning: cleaning)
        let report = try await clearHistory(assembly)

        XCTAssertEqual(report.workspaceDirectories?.removed, 0)
        XCTAssertEqual(report.workspaceDirectories?.absent, 1)
        XCTAssertEqual(report.workspaceDirectories?.deferred, 0)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(report.partial)
        let queuedRows = try await tableCount(
            stores, "SELECT COUNT(*) FROM local_workspace_cleanup")
        XCTAssertEqual(queuedRows, 0)
    }

    func testClearWithNoWorkspaceRowsReportsRealZeroAccounting() async throws {
        let stores = try await PrivacyTestBed.stores(name: "ws-none")
        _ = try await PrivacyTestBed.seedConversation(stores)
        let cleaning = try makeCleaning(root: stores.directory)
        let assembly = PrivacyFacadeFactory.make(stores: stores,
                                                 workspaceCleaning: cleaning)
        let report = try await clearHistory(assembly)
        XCTAssertEqual(report.workspaceDirectories?.removed, 0)
        XCTAssertEqual(report.workspaceDirectories?.absent, 0)
        XCTAssertEqual(report.workspaceDirectories?.deferred, 0)
        XCTAssertFalse(report.partial)
    }

    func testClearRefusesForeignTargetPreservesDataAndDefersTyped() async throws {
        let stores = try await PrivacyTestBed.stores(name: "ws-foreign")
        let conversation = try await PrivacyTestBed.seedConversation(stores)
        _ = try await stores.workspaces.ensureWorkspace(conversationID: conversation,
                                                        title: "replaced by link")
        let owned = ownedDirectoryURL(root: stores.directory, conversationID: conversation)
        try FileManager.default.createDirectory(
            at: owned.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = androidTestFixtureDirectory
            .appendingPathComponent("FloeG02ForeignDest-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: destination,
                                                withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("keep.md")
        try Data("precious".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(atPath: owned.path,
                                                   withDestinationPath: destination.path)

        let cleaning = try makeCleaning(root: stores.directory)
        let assembly = PrivacyFacadeFactory.make(stores: stores,
                                                 workspaceCleaning: cleaning)
        let report = try await clearHistory(assembly)

        // The conversation row still clears; the directory effect is a
        // typed refusal and the clear is PARTIAL with recoverable data.
        XCTAssertEqual(report.workspaceDirectories?.removed, 0)
        XCTAssertEqual(report.workspaceDirectories?.absent, 0)
        XCTAssertEqual(report.workspaceDirectories?.deferred, 1)
        XCTAssertTrue(report.partial)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.phase, .drain)
        XCTAssertEqual(report.failures.first?.reason, "workspaceTargetForeign")
        // The symlink, its destination content and the durable queue row
        // all survive for the retry sweep.
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path,
                                                     isDirectory: &isDir))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "precious")
        let queuedRows = try await tableCount(
            stores, "SELECT COUNT(*) FROM local_workspace_cleanup")
        XCTAssertEqual(queuedRows, 1)
        try? FileManager.default.removeItem(at: destination)
    }

    func testClearDefersCleanupWhileAnotherConversationReferencesTheWorkspace() async throws {
        let stores = try await PrivacyTestBed.stores(name: "ws-survivor")
        let first = try await PrivacyTestBed.seedConversation(stores)
        // The sharer is ARCHIVED: it is excluded from the clear enumeration
        // (the frozen predicate), but its ownership reference is REAL — the
        // shared directory's lifetime cannot be inferred from the first
        // owner's deletion.
        let second = try await PrivacyTestBed.seedConversation(stores,
                                                               archived: true)
        _ = try await stores.workspaces.ensureWorkspace(conversationID: first,
                                                        title: "shared task")
        let shared = try await stores.workspaces.workspaceID(conversationID: first)
        try await PrivacyTestBed.seedOwnership(stores, conversationID: second,
                                               workspaceID: shared!)
        try seedOwnedDirectory(root: stores.directory, conversationID: first)

        let cleaning = try makeCleaning(root: stores.directory)
        let assembly = PrivacyFacadeFactory.make(stores: stores,
                                                 workspaceCleaning: cleaning)
        let report = try await clearHistory(assembly)

        XCTAssertEqual(report.deleted.conversations, 1)
        XCTAssertEqual(report.workspaceDirectories?.removed, 0)
        XCTAssertEqual(report.workspaceDirectories?.deferred, 1)
        XCTAssertTrue(report.partial)
        XCTAssertTrue(report.failures.contains {
            $0.reason == "workspaceOwnershipSurvivors"
        })
        // The shared directory, the workspace row and the durable queue row
        // are all preserved.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: ownedDirectoryURL(root: stores.directory,
                                      conversationID: first).path))
        let queuedRows = try await tableCount(
            stores, "SELECT COUNT(*) FROM local_workspace_cleanup")
        XCTAssertEqual(queuedRows, 1)
        let privateTaskRows = try await tableCount(
            stores, "SELECT COUNT(*) FROM workspaces WHERE kind = 'privateTask'")
        XCTAssertEqual(privateTaskRows, 1)
    }

    func testProjectWorkspaceAndExternalDataSurviveTheClear() async throws {
        let stores = try await PrivacyTestBed.stores(name: "ws-project")
        let conversation = try await PrivacyTestBed.seedConversation(stores)
        // A project workspace (external repository binding): the privacy
        // clear must never touch it — no directory effect is even attempted.
        let external = androidTestFixtureDirectory.appendingPathComponent("R7-external-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        let externalFile = external.appendingPathComponent("user-owned.md")
        try Data("preserve-project".utf8).write(to: externalFile)
        let projectID = UUID()
        try await stores.database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO workspaces
                        (id, name, root_bookmark, created_at, updated_at)
                    VALUES (?, 'external repo', ?, '2026-10-21T00:00:00.000Z', '2026-10-21T00:00:00.000Z')
                    """,
                arguments: [projectID.uuidString, Data([0x01])])
        }
        try await PrivacyTestBed.seedOwnership(stores, conversationID: conversation,
                                               workspaceID: projectID)
        let cleaning = try makeCleaning(root: stores.directory)
        let assembly = PrivacyFacadeFactory.make(stores: stores,
                                                 workspaceCleaning: cleaning)
        let report = try await clearHistory(assembly)
        XCTAssertEqual(report.deleted.conversations, 1)
        XCTAssertEqual(report.workspaceDirectories?.removed, 0)
        XCTAssertEqual(report.workspaceDirectories?.absent, 0)
        XCTAssertEqual(report.workspaceDirectories?.deferred, 0)
        let projectRows = try await tableCount(
            stores, "SELECT COUNT(*) FROM workspaces WHERE id = ?",
            [projectID.uuidString])
        XCTAssertEqual(projectRows, 1)
        XCTAssertEqual(try String(contentsOf: externalFile, encoding: .utf8), "preserve-project")
        let queuedRows = try await tableCount(
            stores, "SELECT COUNT(*) FROM local_workspace_cleanup")
        XCTAssertEqual(queuedRows, 0)
    }

    func testRemovalFailureStaysTypedRetainsQueueAndPreservesContents() async throws {
        let stores = try await PrivacyTestBed.stores(name: "ws-failure")
        let conversation = try await PrivacyTestBed.seedConversation(stores)
        _ = try await stores.workspaces.ensureWorkspace(conversationID: conversation,
                                                        title: "flaky removal")
        let dir = ownedDirectoryURL(root: stores.directory, conversationID: conversation)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let remnant = dir.appendingPathComponent("partial.md")
        try Data("recoverable".utf8).write(to: remnant)

        // The port contract declares `ConversationDomainError` refusals; the
        // cleanup lifecycle preserves that typed reason instead of collapsing
        // it into the generic cleanupThrew token.
        let cleaning = FakeWorkspaceCleaning(
            scriptedFailure: ConversationDomainError.runtimeUnavailable(
                "scriptedRemoveFailed"))
        let assembly = PrivacyFacadeFactory.make(stores: stores,
                                                 workspaceCleaning: cleaning)
        let report = try await clearHistory(assembly)

        XCTAssertEqual(report.workspaceDirectories?.removed, 0)
        XCTAssertEqual(report.workspaceDirectories?.deferred, 1)
        XCTAssertTrue(report.partial)
        XCTAssertEqual(report.failures.first?.reason, "scriptedRemoveFailed")
        // Recoverable data preserved; the durable queue row stays for the
        // launch sweep (retryPendingLocalWorkspaceCleanup).
        XCTAssertEqual(try String(contentsOf: remnant, encoding: .utf8), "recoverable")
        let queuedRows = try await tableCount(
            stores, "SELECT COUNT(*) FROM local_workspace_cleanup")
        XCTAssertEqual(queuedRows, 1)
    }
}


// MARK: - Atomic retirement admission + exact durable completion (G02-R7)

/// These regressions exercise the ANDROID-ONLY store additions over the REAL
/// schema-46 database and triggers. They are authored, not executed here.
final class G02PrivateWorkspaceRetirementTests: XCTestCase {

    private func seedQueue(_ stores: PrivacyTestBed.Stores,
                           workspaceID: UUID,
                           path: String) async throws {
        try await stores.database.writer { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO local_workspace_cleanup
                        (workspace_id, relative_path)
                    VALUES (?, ?)
                    """,
                arguments: [workspaceID.uuidString, path])
        }
    }

    private func queuePath(_ stores: PrivacyTestBed.Stores,
                           workspaceID: UUID) async throws -> String? {
        try await stores.database.reader { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT relative_path FROM local_workspace_cleanup
                    WHERE workspace_id = ?
                    """,
                arguments: [workspaceID.uuidString])
        }
    }

    private func workspaceRow(_ stores: PrivacyTestBed.Stores,
                              workspaceID: UUID) async throws
        -> (kind: String, path: String?)?
    {
        try await stores.database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT kind, internal_relative_path FROM workspaces WHERE id = ?",
                arguments: [workspaceID.uuidString]) else { return nil }
            let kind: String = row["kind"]
            let path: String? = row["internal_relative_path"]
            return (kind, path)
        }
    }

    private func count(_ stores: PrivacyTestBed.Stores,
                       _ sql: String,
                       _ arguments: StatementArguments = []) async throws -> Int {
        try await stores.database.reader { db in
            try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
        }
    }

    func testRetirementDeletesOnlyTheExactPrivateTaskRowAndQueuesExactPath() async throws {
        let stores = try await PrivacyTestBed.stores(name: "retire-row")
        let workspaceID = UUID()
        let conversationID = UUID()
        try await PrivacyTestBed.seedWorkspace(stores,
                                               workspaceID: workspaceID,
                                               conversationID: conversationID)
        let relative = "PrivateTasks/\(conversationID.uuidString)"
        let admission = try await stores.workspaces.retirePrivateTaskForCleanup(
            workspaceID: workspaceID, expectedRelativePath: relative)
        XCTAssertEqual(admission, .rowRetired)
        let remainingWorkspace = try await stores.workspaces.workspace(id: workspaceID)
        XCTAssertNil(remainingWorkspace)
        // The V36 BEFORE DELETE trigger committed the exact durable row in
        // the same transaction.
        let queued = try await queuePath(stores, workspaceID: workspaceID)
        XCTAssertEqual(queued, relative)
    }

    func testRetirementRefusesSurvivorsWithoutRehomingOrDeletingAnything() async throws {
        let stores = try await PrivacyTestBed.stores(name: "retire-survivors")
        let first = try await PrivacyTestBed.seedConversation(stores)
        let archivedSurvivor = try await PrivacyTestBed.seedConversation(
            stores, archived: true)
        _ = try await stores.workspaces.ensureWorkspace(conversationID: first,
                                                        title: "shared")
        let ownedWorkspaceID = try await stores.workspaces.workspaceID(
            conversationID: first)
        let workspaceID = try XCTUnwrap(ownedWorkspaceID)
        let ownedWorkspace = try await stores.workspaces.workspace(id: workspaceID)
        let workspace = try XCTUnwrap(ownedWorkspace)
        let relative = try XCTUnwrap(workspace.internalRelativePath)
        try await PrivacyTestBed.seedOwnership(
            stores, conversationID: archivedSurvivor, workspaceID: workspaceID)

        let before = try await count(stores, "SELECT COUNT(*) FROM workspaces")
        let admission = try await stores.workspaces.retirePrivateTaskForCleanup(
            workspaceID: workspaceID, expectedRelativePath: relative)
        XCTAssertEqual(admission, .deferredSurvivors)
        let after = try await count(stores, "SELECT COUNT(*) FROM workspaces")
        XCTAssertEqual(after, before, "no replacement private workspace was created")
        let ownership = try await count(stores,
            "SELECT COUNT(*) FROM conversation_workspace_ownership WHERE workspace_id = ?",
            [workspaceID.uuidString])
        XCTAssertEqual(ownership, 2)
        let row = try await workspaceRow(stores, workspaceID: workspaceID)
        XCTAssertEqual(row?.kind, "privateTask")
        XCTAssertEqual(row?.path, relative)
        let queued = try await count(stores,
            "SELECT COUNT(*) FROM local_workspace_cleanup")
        XCTAssertEqual(queued, 0)
    }

    func testRetirementDefersChangedOwnershipBeforeAnyMutation() async throws {
        let stores = try await PrivacyTestBed.stores(name: "retire-changed")
        let workspaceID = UUID()
        let conversationID = UUID()
        try await PrivacyTestBed.seedWorkspace(stores,
                                               workspaceID: workspaceID,
                                               conversationID: conversationID)
        let expected = "PrivateTasks/\(conversationID.uuidString)"
        let replaced = "PrivateTasks/\(UUID().uuidString)"
        try await stores.database.writer { db in
            try db.execute(
                sql: "UPDATE workspaces SET internal_relative_path = ? WHERE id = ?",
                arguments: [replaced, workspaceID.uuidString])
        }
        let admission = try await stores.workspaces.retirePrivateTaskForCleanup(
            workspaceID: workspaceID, expectedRelativePath: expected)
        XCTAssertEqual(admission, .deferredOwnershipChanged)
        let row = try await workspaceRow(stores, workspaceID: workspaceID)
        XCTAssertEqual(row?.path, replaced, "the changed binding is untouched")
        let queued = try await count(stores,
            "SELECT COUNT(*) FROM local_workspace_cleanup")
        XCTAssertEqual(queued, 0)
    }

    func testRetirementDefersOnReplacedQueueBindingBeforeAnyMutation() async throws {
        let stores = try await PrivacyTestBed.stores(name: "retire-qconflict")
        let workspaceID = UUID()
        let conversationID = UUID()
        try await PrivacyTestBed.seedWorkspace(stores,
                                               workspaceID: workspaceID,
                                               conversationID: conversationID)
        let expected = "PrivateTasks/\(conversationID.uuidString)"
        let replaced = "PrivateTasks/\(UUID().uuidString)"
        try await seedQueue(stores, workspaceID: workspaceID, path: replaced)
        let admission = try await stores.workspaces.retirePrivateTaskForCleanup(
            workspaceID: workspaceID, expectedRelativePath: expected)
        XCTAssertEqual(admission, .deferredQueueConflict)
        let row = try await workspaceRow(stores, workspaceID: workspaceID)
        XCTAssertNotNil(row)
        let queued = try await queuePath(stores, workspaceID: workspaceID)
        XCTAssertEqual(queued, replaced,
                       "the replaced durable binding was not erased")
    }

    func testRetirementWithoutARowNeedsTheExactDurableQueueAuthority() async throws {
        let stores = try await PrivacyTestBed.stores(name: "retire-queue-only")
        let queuedID = UUID()
        let relative = "PrivateTasks/\(UUID().uuidString)"
        try await seedQueue(stores, workspaceID: queuedID, path: relative)
        let admitted = try await stores.workspaces.retirePrivateTaskForCleanup(
            workspaceID: queuedID, expectedRelativePath: relative)
        XCTAssertEqual(admitted, .queueAuthority, "process-death recovery shape")

        let unknownID = UUID()
        let unknown = try await stores.workspaces.retirePrivateTaskForCleanup(
            workspaceID: unknownID, expectedRelativePath: relative)
        XCTAssertEqual(unknown, .deferredUnknownOwnership,
                       "a bare path can never be inferred as ownership")

        let conflict = try await stores.workspaces.retirePrivateTaskForCleanup(
            workspaceID: queuedID,
            expectedRelativePath: "PrivateTasks/\(UUID().uuidString)")
        XCTAssertEqual(conflict, .deferredQueueConflict)
    }

    func testCompletionIsConditionalAndNeverErasesAReplacedBinding() async throws {
        let stores = try await PrivacyTestBed.stores(name: "retire-completion")
        let workspaceID = UUID()
        let pathA = "PrivateTasks/\(UUID().uuidString)"
        let pathB = "PrivateTasks/\(UUID().uuidString)"
        try await seedQueue(stores, workspaceID: workspaceID, path: pathA)

        let wrong = try await stores.workspaces.finishLocalCleanup(
            workspaceID: workspaceID, expectedRelativePath: pathB)
        XCTAssertFalse(wrong)
        let stillA = try await queuePath(stores, workspaceID: workspaceID)
        XCTAssertEqual(stillA, pathA)

        let exact = try await stores.workspaces.finishLocalCleanup(
            workspaceID: workspaceID, expectedRelativePath: pathA)
        XCTAssertTrue(exact)
        let gone = try await queuePath(stores, workspaceID: workspaceID)
        XCTAssertNil(gone)

        let repeated = try await stores.workspaces.finishLocalCleanup(
            workspaceID: workspaceID, expectedRelativePath: pathA)
        XCTAssertFalse(repeated, "completion is idempotent, not a fake second write")
    }

    func testLateReferenceCannotAttachToAnAlreadyRetiredWorkspace() async throws {
        let stores = try await PrivacyTestBed.stores(name: "retire-late-ref")
        let conversationID = try await PrivacyTestBed.seedConversation(stores)
        let workspaceID = UUID()
        try await PrivacyTestBed.seedWorkspace(stores,
                                               workspaceID: workspaceID,
                                               conversationID: conversationID)
        let relative = "PrivateTasks/\(conversationID.uuidString)"
        let admission = try await stores.workspaces.retirePrivateTaskForCleanup(
            workspaceID: workspaceID, expectedRelativePath: relative)
        XCTAssertEqual(admission, .rowRetired)
        do {
            try await stores.workspaces.assignConversation(
                workspaceID: workspaceID, conversationID: conversationID)
            XCTFail("a retired workspace must not accept a late reference")
        } catch {
            // Typed original-store refusal (notFound): no ownership row and
            // no rehomed workspace.
        }
        let ownership = try await count(stores,
            "SELECT COUNT(*) FROM conversation_workspace_ownership")
        XCTAssertEqual(ownership, 0)
        let row = try await stores.workspaces.workspace(id: workspaceID)
        XCTAssertNil(row)
    }

    func testConcurrentReferenceInsertionAndRetirementNeverRehome() async throws {
        // Both operations use the ONE DatabaseManager writer, so exactly one
        // serialized order wins. Whichever wins, the other side must observe
        // it and the live task must never be silently rehomed.
        let stores = try await PrivacyTestBed.stores(name: "retire-race")
        for _ in 0..<4 {
            let conversationID = try await PrivacyTestBed.seedConversation(stores)
            let workspaceID = UUID()
            try await PrivacyTestBed.seedWorkspace(
                stores, workspaceID: workspaceID,
                conversationID: conversationID)
            let relative = "PrivateTasks/\(conversationID.uuidString)"

            let workspaces = stores.workspaces
            let retire = Task {
                try await workspaces.retirePrivateTaskForCleanup(
                    workspaceID: workspaceID, expectedRelativePath: relative)
            }
            let assign = Task {
                try await workspaces.assignConversation(
                    workspaceID: workspaceID, conversationID: conversationID)
            }
            let admission = try await retire.value
            var assignFailed = false
            do { try await assign.value } catch { assignFailed = true }

            switch admission {
            case .rowRetired:
                XCTAssertTrue(assignFailed,
                              "a reference after retirement must be refused")
                let row = try await stores.workspaces.workspace(id: workspaceID)
                XCTAssertNil(row)
            case .deferredSurvivors:
                XCTAssertFalse(assignFailed,
                               "a reference that committed first is a survivor")
                let row = try await stores.workspaces.workspace(id: workspaceID)
                XCTAssertNotNil(row)
            default:
                XCTFail("unexpected concurrent admission: \(admission)")
            }
        }
    }

    func testProcessDeathQueuedRetryCompletesThroughTheSameAuthority() async throws {
        let stores = try await RB3TestBed.stores()
        let record = try await RB3TestBed.seedOrdinary(
            stores, title: "crash before file removal")
        let conversationID = record.id
        let workspaceID = UUID()
        let relative = "PrivateTasks/\(conversationID.uuidString)"
        try await stores.database.writer { db in
            try db.execute(sql: """
                INSERT INTO workspaces (
                    id, name, root_bookmark, last_opened_at,
                    active_target_kind, active_target_host_id,
                    inspector_state_json, instructions_rel_path,
                    created_at, updated_at, kind, internal_relative_path
                ) VALUES (?, 'crash', ?, NULL, 'local', NULL, '{}', NULL,
                          '2026-10-19T00:00:00Z', '2026-10-19T00:00:00Z',
                          'privateTask', ?)
                """, arguments: [workspaceID.uuidString, Data(), relative])
        }
        let dir = stores.directory
            .appendingPathComponent("Workspace/\(relative)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let marker = dir.appendingPathComponent("notes.md")
        try Data("recoverable".utf8).write(to: marker)

        // Process-death shape: the authoritative row was retired (and the V36
        // queue row committed) but the file effect never ran.
        let admission = try await stores.workspaces.retirePrivateTaskForCleanup(
            workspaceID: workspaceID, expectedRelativePath: relative)
        XCTAssertEqual(admission, .rowRetired)
        let queuedBefore = try await RB3TestBed.count(
            stores.database, "SELECT COUNT(*) FROM local_workspace_cleanup")
        XCTAssertEqual(queuedBefore, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        let cleaning = G02WorkspaceCleaning(
            root: try XCTUnwrap(
                RuntimeStorageRoot(validatingAbsoluteDirectory:
                                    stores.directory.standardizedFileURL.path)))
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: nil,
                                           workspaceCleaning: cleaning)
        let failures = await bundle.domain.retryPendingLocalWorkspaceCleanup()
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        let queuedAfter = try await RB3TestBed.count(
            stores.database, "SELECT COUNT(*) FROM local_workspace_cleanup")
        XCTAssertEqual(queuedAfter, 0)
    }
    func testQueueReboundDuringFileEffectStaysDeferredAndPreserved() async throws {
        let stores = try await PrivacyTestBed.stores(name: "retire-rebound")
        let workspaceID = UUID()
        let relative = "PrivateTasks/\(UUID().uuidString)"
        let replacement = "PrivateTasks/\(UUID().uuidString)"
        try await seedQueue(stores, workspaceID: workspaceID, path: relative)
        struct RebindingCleaner: ConversationOwnedWorkspaceCleaning {
            let database: DatabaseManager
            let workspaceID: UUID
            let replacement: String
            func removePrivateTaskDirectory(relativePath: String) async throws -> PrivateTaskDirectoryRemoval {
                try await database.writer { db in
                    try db.execute(sql: "UPDATE local_workspace_cleanup SET relative_path = ? WHERE workspace_id = ?",
                                   arguments: [replacement, workspaceID.uuidString])
                }
                return .absent
            }
        }
        let outcome = await ConversationPrivateWorkspaceCleanup.perform(
            workspaceStore: stores.workspaces,
            cleaning: RebindingCleaner(database: stores.database, workspaceID: workspaceID, replacement: replacement),
            workspaceID: workspaceID, relativePath: relative)
        XCTAssertEqual(outcome, .deferred("workspaceCleanupQueueUnsettled"))
        let queued = try await queuePath(stores, workspaceID: workspaceID)
        XCTAssertEqual(queued, replacement)
    }

}
