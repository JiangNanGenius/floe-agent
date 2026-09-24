// FloeAppTests — durable access for external workspaces picked for a
// template environment.
//
// The fileImporter's security scope only lives for the submit call, while the
// environment registry stores a plain path. Without a persisted bookmark, an
// external Files folder would lose access after relaunch even though the
// environment record still claims it. These tests pin the fix's contract: the
// picked folder is remembered through the same WorkspaceRecord/security-
// scoped bookmark the Files workspace flow uses, an existing record that
// already owns the folder is reused (never duplicated, renamed or re-owned),
// and a fresh store created after "relaunch" can still resolve the folder and
// read its files.

#if canImport(UIKit)
import Foundation
import Testing
import FloeExecution
import FloeModels
import FloePersistence
@testable import FloeApp

/// Counts the injected scope calls so the lease contract is observable
/// without a real external Files grant in the simulator.
private final class ScopeCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func increment() {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

@Suite("FloeApp.ExternalWorkspaceTemplateAccess", .serialized)
struct ExternalWorkspaceTemplateAccessTests {

    /// A file-backed workspace database under a disposable sandbox: reopening
    /// the same path is the app-relaunch simulation, and the picked folder
    /// lives outside the database so its bookmark is the only durable handle.
    private func makeSandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-workspace-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(at sandbox: URL) async throws -> SQLiteWorkspaceStore {
        let database = try DatabaseManager(path: sandbox.appendingPathComponent("floe.sqlite"))
        try await database.migrate()
        return SQLiteWorkspaceStore(database: database)
    }

    private func makeFolder(_ name: String, in sandbox: URL) throws -> URL {
        let url = sandbox.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    @Test("A folder picked for a template environment stays resolvable and readable after relaunch")
    func pickedFolderStaysResolvableAndReadableAfterRelaunch() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let picked = try makeFolder("External Workspace", in: sandbox)
        try Data("workspace-kept".utf8).write(to: picked.appendingPathComponent("README.md"))

        // Submit persists durable access while the importer's scope is live.
        let store = try await makeStore(at: sandbox)
        let created = try await WorkspaceCenter.ensureWorkspaceRecord(
            forDirectory: picked, name: nil, store: store
        )
        #expect(created.kind == .project)
        #expect(created.name == "External Workspace")
        #expect(created.rootBookmark.isEmpty == false)

        // Relaunch: a fresh store (same database file) resolves the bookmark
        // without the picker and reads the folder through the resolved URL.
        let reopened = try await makeStore(at: sandbox)
        let records = try await reopened.workspaces()
        #expect(records.count == 1)
        let record = try #require(records.first)
        var isStale = false
        let resolved = try URL(
            resolvingBookmarkData: record.rootBookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        #expect(isStale == false)
        #expect(canonicalPath(resolved) == canonicalPath(picked))
        let marker = resolved.appendingPathComponent("README.md")
        #expect(String(decoding: try Data(contentsOf: marker), as: UTF8.self) == "workspace-kept")
    }

    @Test("An existing workspace for the same folder keeps its identity and is never duplicated")
    func existingWorkspaceIsReusedWithoutMovingOwnership() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let picked = try makeFolder("External Workspace", in: sandbox)
        let other = try makeFolder("Other Project", in: sandbox)
        let store = try await makeStore(at: sandbox)

        let owned = WorkspaceRecord(
            name: "Existing Project",
            rootBookmark: try picked.bookmarkData(
                options: [], includingResourceValuesForKeys: nil, relativeTo: nil
            )
        )
        try await store.saveWorkspace(owned)
        let unrelated = WorkspaceRecord(
            name: "Other Project",
            rootBookmark: try other.bookmarkData(
                options: [], includingResourceValuesForKeys: nil, relativeTo: nil
            )
        )
        try await store.saveWorkspace(unrelated)

        // The picker can hand back a different spelling of the same folder;
        // matching goes through the resolved bookmark, not the raw path.
        let reused = try await WorkspaceCenter.ensureWorkspaceRecord(
            forDirectory: URL(fileURLWithPath: picked.path + "/./"),
            name: "Environment name",
            store: store
        )
        #expect(reused.id == owned.id)
        #expect(reused.name == "Existing Project")
        #expect(reused.rootBookmark == owned.rootBookmark)

        let all = try await store.workspaces()
        #expect(all.count == 2)
        #expect(all.contains { $0.id == owned.id })
        #expect(all.contains { $0.id == unrelated.id })
    }

    @Test("Private task workspaces never satisfy an external folder match")
    func privateTaskRecordsAreIgnored() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let picked = try makeFolder("External Workspace", in: sandbox)
        let store = try await makeStore(at: sandbox)

        // An app-owned private task has an intentionally empty bookmark and
        // must never be opened through the security-scoped project path.
        try await store.saveWorkspace(WorkspaceRecord(
            name: "Chat",
            rootBookmark: Data(),
            kind: .privateTask,
            internalRelativePath: "PrivateTasks/\(UUID().uuidString)"
        ))

        let record = try await WorkspaceCenter.ensureWorkspaceRecord(
            forDirectory: picked, name: nil, store: store
        )
        #expect(record.kind == .project)
        #expect(record.rootBookmark.isEmpty == false)
        let all = try await store.workspaces()
        #expect(all.count == 2)
    }

    @Test("A remembered external workspace yields one lease that releases exactly once")
    func rememberedWorkspaceYieldsOneShotLease() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let picked = try makeFolder("External Workspace", in: sandbox)
        let store = try await makeStore(at: sandbox)
        _ = try await WorkspaceCenter.ensureWorkspaceRecord(forDirectory: picked, name: nil, store: store)

        let starts = ScopeCallCounter()
        let stops = ScopeCallCounter()
        let lease = try await WorkspaceCenter.acquireExternalWorkspaceAccess(
            forCanonicalPath: picked.path,
            store: store,
            startScope: { _ in starts.increment(); return true },
            stopScope: { _ in stops.increment() }
        )
        let acquired = try #require(lease)
        #expect(starts.count == 1)
        #expect(stops.count == 0)

        // Reference semantics: a copied/transferred lease releases the
        // underlying scope once even when several teardown paths call it.
        acquired.release()
        acquired.release()
        #expect(stops.count == 1)
    }

    @Test("A remembered external workspace whose grant is refused fails closed")
    func refusedGrantFailsClosed() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let picked = try makeFolder("External Workspace", in: sandbox)
        let store = try await makeStore(at: sandbox)
        _ = try await WorkspaceCenter.ensureWorkspaceRecord(forDirectory: picked, name: nil, store: store)

        let stops = ScopeCallCounter()
        await #expect(throws: ExternalWorkspaceAccessError.self) {
            _ = try await WorkspaceCenter.acquireExternalWorkspaceAccess(
                forCanonicalPath: picked.path,
                store: store,
                startScope: { _ in false },
                stopScope: { _ in stops.increment() }
            )
        }
        #expect(stops.count == 0, "a refused grant never yields a lease to release")
    }

    @Test("An unremembered app-owned path needs no lease")
    func unrememberedAppOwnedPathNeedsNoLease() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let picked = try makeFolder("App Owned", in: sandbox)
        let store = try await makeStore(at: sandbox)

        // Test-host temp dirs live inside the app container: no grant is
        // required, so the guest keeps its previous scope-free behavior.
        #expect(WorkspaceCenter.isAppOwnedWorkspacePath(picked.path))
        let lease = try await WorkspaceCenter.acquireExternalWorkspaceAccess(
            forCanonicalPath: picked.path,
            store: store,
            startScope: { _ in true },
            stopScope: { _ in }
        )
        #expect(lease == nil)
    }
}
#endif
