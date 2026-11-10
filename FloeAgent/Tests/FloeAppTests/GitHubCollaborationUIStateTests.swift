// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import XCTest
import FloeGit
@testable import FloeApp

/// The lock protects every read/write of handler and requests. This fixture
/// changes only the injected URLSession transport, never the real service,
/// prepared-mutation validation, journal, draft writer or UI coordinator.
private final class GitHubUIHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: @Sendable (URLRequest) throws -> Data = { _ in Data("[]".utf8) }
    private var requests: [URLRequest] = []
    func reset(_ handler: @escaping @Sendable (URLRequest) throws -> Data) {
        lock.lock(); defer { lock.unlock() }; self.handler = handler; requests = []
    }
    func respond(_ request: URLRequest) throws -> Data {
        lock.lock(); requests.append(request); let operation = handler; lock.unlock()
        return try operation(request)
    }
    func posts() -> Int { lock.lock(); defer { lock.unlock() }; return requests.filter { $0.httpMethod == "POST" }.count }
    func reads(path: String) -> Int { lock.lock(); defer { lock.unlock() }; return requests.filter { $0.httpMethod == "GET" && $0.url?.path == path }.count }
}
private final class GitHubUIURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = GitHubUIHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.state.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor final class GitHubCollaborationUIStateTests: XCTestCase {
    private let repo = GitHubLinkRepositoryID(owner: "qa", name: "project")
    private func root() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("GitHubUI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value.resolvingSymlinksInPath()
    }
    private func center(root: URL) throws -> (GitHubCollaborationCenter, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubUIURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = GitHubCollaborationClient(client: GitHubActionsClient(session: session))
        let scope = GitHubCollaborationScope(repository: repo, workspaceID: UUID(), sourceTaskID: UUID())
        let drafts = try GitHubCollaborationDraftStore(scope: scope, directory: root.appendingPathComponent("Drafts"))
        let service = try GitHubCollaborationService(client: client, journalURL: root.appendingPathComponent("journal.json"))
        let center = GitHubCollaborationCenter(repository: repo, workspaceID: scope.workspaceID, sourceTaskID: scope.sourceTaskID,
            service: service, client: client, tokenProvider: { "synthetic-transport-fixture" }, authorize: {}, draftStore: drafts)
        return (center, session)
    }
    private func wait(_ title: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        XCTFail(title); throw NSError(domain: "GitHubUIFixture", code: 1)
    }

    func testScopedDraftsSurviveReopenAndLateAutosaveCannotUnlockPreparedPayload() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let scope = GitHubCollaborationScope(repository: repo, workspaceID: UUID(), sourceTaskID: UUID())
        let directory = root.appendingPathComponent("InitiallyMissingDrafts")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let store = try GitHubCollaborationDraftStore(scope: scope, directory: directory)
        var draft = GitHubCollaborationDraft(scope: scope, kind: .createIssue)
        draft.title = "Saved title"; draft.body = "User-authored draft"
        try await store.save(draft)
        var pendingAutosave = draft
        draft.prepared = true; draft.updatedAt = Date().addingTimeInterval(1)
        try await store.save(draft)
        pendingAutosave.body = "Stale callback"; pendingAutosave.updatedAt = Date().addingTimeInterval(2)
        try await store.save(pendingAutosave)
        let reopened = try GitHubCollaborationDraftStore(scope: scope, directory: directory)
        let saved = try await reopened.load()
        XCTAssertEqual(saved, [draft])
        let foreign = GitHubCollaborationScope(repository: repo, workspaceID: scope.workspaceID, sourceTaskID: UUID())
        let foreignStore = try GitHubCollaborationDraftStore(scope: foreign, directory: directory)
        let foreignDrafts = try await foreignStore.load()
        XCTAssertTrue(foreignDrafts.isEmpty)
        XCTAssertNotEqual(scope.storageKey, foreign.storageKey)
    }

    func testDraftStoreRefusesDirectoryReplacementWithASymlink() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let scope = GitHubCollaborationScope(repository: repo, workspaceID: UUID(), sourceTaskID: UUID())
        let directory = root.appendingPathComponent("PinnedDrafts"), moved = root.appendingPathComponent("RetainedDrafts")
        let elsewhere = root.appendingPathComponent("Elsewhere")
        let store = try GitHubCollaborationDraftStore(scope: scope, directory: directory)
        var draft = GitHubCollaborationDraft(scope: scope, kind: .createIssue)
        draft.title = "Preserve this original"; draft.body = "Original body"
        try await store.save(draft)
        let savedName = scope.storageKey + ".json"
        let before = try Data(contentsOf: directory.appendingPathComponent(savedName))
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("untouched".utf8).write(to: elsewhere.appendingPathComponent("sentinel"))
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: elsewhere)
        draft.body = "Must not reach the redirected directory"; draft.updatedAt = Date()
        do {
            try await store.save(draft)
            XCTFail("A pinned draft directory must not follow a replacement symlink")
        } catch { XCTAssertEqual(error as? GitHubCollaborationError, .operationMismatch) }
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(savedName)), before)
        XCTAssertEqual(try Data(contentsOf: elsewhere.appendingPathComponent("sentinel")), Data("untouched".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), ["sentinel"])
    }

    func testTwoSendTapsAndUnknownReopenNeverCreateAnotherPOST() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        GitHubUIURLProtocol.state.reset { request in
            if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
            if request.url?.path == "/user" { return Data(#"{"login":"qa-actor"}"#.utf8) }
            return Data("[]".utf8)
        }
        let (center, session) = try center(root: root); defer { session.invalidateAndCancel() }
        await center.bootstrap()
        XCTAssertTrue(center.canWrite)
        await center.beginDraft(.createIssue)
        let id = try XCTUnwrap(center.drafts.first?.id)
        center.updateDraft(id) { $0.title = "A real prepared issue"; $0.body = "Preserved body" }
        center.sendDraft(id); center.sendDraft(id)
        center.updateDraft(id) { $0.body = "A late edit must not change the submitted snapshot" }
        try await wait("The owned send must finish with an uncertain delivery") { center.activeOperationID == nil }
        XCTAssertEqual(GitHubUIURLProtocol.state.posts(), 1)
        XCTAssertEqual(center.records.first(where: { $0.id == id })?.state, .unknown)
        XCTAssertEqual(center.drafts.first(where: { $0.id == id })?.prepared, true)
        center.autosave?.cancel()
        let reopenedStore = try GitHubCollaborationDraftStore(scope: center.scope, directory: root.appendingPathComponent("Drafts"))
        let reopened = GitHubCollaborationCenter(repository: repo, workspaceID: center.scope.workspaceID,
            sourceTaskID: center.scope.sourceTaskID, service: center.service, client: center.client,
            tokenProvider: { "synthetic-transport-fixture" }, authorize: {}, draftStore: reopenedStore)
        await reopened.bootstrap()
        XCTAssertEqual(reopened.drafts.map(\.id), [id])
        reopened.sendDraft(id)
        try await wait("An uncertain operation must finish without another POST") { reopened.activeOperationID == nil }
        await reopened.reconcile(id)
        await reopened.copyDraftForEditing(id) // Not an escape hatch around the uncertain receipt.
        XCTAssertEqual(GitHubUIURLProtocol.state.posts(), 1)
        XCTAssertEqual(reopened.records.first(where: { $0.id == id })?.state, .unknown)
        XCTAssertEqual(reopened.drafts.map(\.id), [id])
        let store = try XCTUnwrap(reopened.draftStore)
        let stored = try await store.load()
        XCTAssertEqual(stored.first?.id, id)
        XCTAssertEqual(stored.first?.body, "Preserved body")
        reopened.autosave?.cancel()
    }

    func testDifferentPRWithTheSameHeadAndPatchCannotAdoptAnOldLineSelection() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        GitHubUIURLProtocol.state.reset { _ in Data("[]".utf8) }
        let (center, session) = try center(root: root); defer { session.invalidateAndCancel() }
        await center.bootstrap()
        let sha = String(repeating: "a", count: 40)
        let item = try JSONDecoder().decode(GitHubCollaborationPull.self, from: JSONSerialization.data(withJSONObject: [
            "id": 8, "number": 8, "title": "Current pull", "state": "open", "draft": false,
            "html_url": "https://github.com/qa/project/pull/8",
            "head": ["ref": "feature", "sha": sha, "label": "qa:feature"],
            "base": ["ref": "main", "sha": String(repeating: "b", count: 40), "label": "qa:main"]
        ]))
        let file = try JSONDecoder().decode(GitHubCollaborationFile.self, from: JSONSerialization.data(withJSONObject: [
            "sha": String(repeating: "c", count: 40), "filename": "source.swift", "status": "modified",
            "additions": 1, "deletions": 1, "patch": "@@ -1 +1 @@\n-old\n+new"
        ]))
        let line = GitHubReviewLine(path: file.filename, side: .right, line: 1)
        try line.validate(in: [file])
        center.pull = item; center.files = [file]; center.selection = .pull(8)
        await center.beginDraft(.lineComment, line: line, viewedHeadSHA: sha, viewedFile: file, viewedSelection: .pull(7))
        XCTAssertTrue(center.drafts.isEmpty)
        XCTAssertNotNil(center.operationError)
        XCTAssertEqual(GitHubUIURLProtocol.state.posts(), 0)
    }

    func testLateReadCannotReplaceTheNewFilterResults() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        GitHubUIURLProtocol.state.reset { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            let state = query?.first(where: { $0.name == "state" })?.value ?? "open"
            if state == "open" { Thread.sleep(forTimeInterval: 0.15) }
            let number = state == "open" ? 1 : 2
            return try JSONSerialization.data(withJSONObject: [["id": number, "number": number,
                "title": state, "state": state, "html_url": "https://github.com/qa/project/issues/\(number)", "updated_at": "2026-11-10T00:00:00Z"],
                ["id": 99, "number": 99, "title": "A pull returned by the issues endpoint", "state": state,
                 "html_url": "https://github.com/qa/project/pull/99", "updated_at": "2026-11-10T00:00:00Z",
                 "pull_request": ["url": "https://api.github.com/repos/qa/project/pulls/99"]]])
        }
        let (center, session) = try center(root: root); defer { session.invalidateAndCancel() }
        let first = Task { await center.loadList() }
        try await Task.sleep(for: .milliseconds(20))
        center.stateFilter = "closed"
        await center.loadList(); await first.value
        XCTAssertEqual(center.issues.map(\.number), [2])
        XCTAssertEqual(center.issues.first?.state, "closed")
        XCTAssertFalse(center.listLoading)
    }

    func testRerunDuringJobReadCannotPublishAnotherAttemptsJobsOrReadItsLog() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let sha = String(repeating: "a", count: 40), runPath = "/repos/qa/project/actions/runs/50"
        GitHubUIURLProtocol.state.reset { request in
            if request.url?.path == runPath {
                let attempt = GitHubUIURLProtocol.state.reads(path: runPath) == 1 ? 1 : 2
                return try JSONSerialization.data(withJSONObject: ["id": 50, "run_attempt": attempt,
                    "head_sha": sha, "status": "completed", "conclusion": "failure"])
            }
            if request.url?.path == runPath + "/jobs" {
                return Data(#"{"jobs":[{"id":501,"name":"Original failed job","status":"completed","conclusion":"failure"}]}"#.utf8)
            }
            XCTFail("The fenced reader must never ask for a log from the changed attempt")
            throw URLError(.badURL)
        }
        let (center, session) = try center(root: root); defer { session.invalidateAndCancel() }
        let run = try JSONDecoder().decode(GitHubActionAttempt.self, from: JSONSerialization.data(withJSONObject: [
            "id": 50, "run_attempt": 1, "head_sha": sha, "status": "completed", "conclusion": "failure"]))
        let reader = GitHubCollaborationRunReader(client: center.client, repository: repo, run: run)
        do {
            _ = try await reader.log(jobID: 501, token: "synthetic-transport-fixture")
            XCTFail("The new attempt must not be displayed as the selected original attempt")
        } catch GitHubLinkError.sourceChanged { }
        XCTAssertEqual(GitHubUIURLProtocol.state.reads(path: "/repos/qa/project/actions/jobs/501/logs"), 0)
        XCTAssertEqual(GitHubUIURLProtocol.state.posts(), 0)
    }
}
#endif
