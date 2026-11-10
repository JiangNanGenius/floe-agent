// SPDX-License-Identifier: MPL-2.0
// Actual App-host source-link/component captures. Public AX is diagnostic only;
// no automated touch/click proof is claimed. Root judges the real screenshots.
#if canImport(UIKit)
import Foundation
import SwiftUI
import UIKit
import XCTest
import FloeGit
import FloeModels
import FloePersistence
@testable import FloeApp

/// Same injected URLProtocol technique as GitHubCollaborationUIStateTests.
/// The lock protects all state; only this ephemeral session sees the fixture.
/// Unknown requests fail, and every non-GET is rejected and counted.
private final class GitHubCollaborationUIHTTP: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private var unexpected: [String] = []
    private var writes = 0
    func reset() { lock.lock(); defer { lock.unlock() }; paths = []; unexpected = []; writes = 0 }
    func readCount(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return paths.filter { $0 == path }.count }
    func receipt() -> (writes: Int, unexpected: [String], paths: [String]) {
        lock.lock(); defer { lock.unlock() }; return (writes, unexpected, paths)
    }
    func respond(_ request: URLRequest) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let path = request.url?.path ?? "missing-url"
        guard request.url?.host == "api.github.com", request.httpMethod == "GET" else {
            writes += 1; throw URLError(.noPermissionsToReadFile)
        }
        paths.append(path)
        let root = "/repos/qa/native-ui", sha = String(repeating: "a", count: 40)
        func issue() -> [String: Any] {
            ["id": 7, "number": 7, "title": "Inspect native collaboration",
             "body": "Issue details from the controlled transport.", "state": "open",
             "html_url": "https://github.com/qa/native-ui/issues/7", "updated_at": "2026-11-10T00:00:00Z",
             "user": ["login": "fixture-author"]]
        }
        func pull() -> [String: Any] {
            ["id": 42, "number": 42, "title": "Improve the native editor",
             "body": "Pull request details from the controlled transport.", "state": "open", "draft": false,
             "merged": false, "html_url": "https://github.com/qa/native-ui/pull/42", "user": ["login": "fixture-author"],
             "head": ["ref": "editor-fix", "sha": sha, "label": "qa:editor-fix"],
             "base": ["ref": "main", "sha": String(repeating: "b", count: 40), "label": "qa:main"]]
        }
        func comment(_ number: Int) -> [String: Any] {
            ["id": 701, "body": "A real decoded discussion comment.", "user": ["login": "fixture-reviewer"],
             "html_url": "https://github.com/qa/native-ui/issues/\(number)#issuecomment-701"]
        }
        let result: Any
        switch path {
        case root + "/issues": result = [issue()]
        case root + "/issues/7": result = issue()
        case root + "/issues/7/comments": result = [comment(7)]
        case root + "/pulls": result = [pull()]
        case root + "/pulls/42": result = pull()
        case root + "/issues/42/comments": result = [comment(42)]
        case root + "/pulls/42/reviews", root + "/pulls/42/comments": result = []
        case root + "/pulls/42/files":
            result = [["sha": String(repeating: "c", count: 40), "filename": "Sources/Editor.swift", "status": "modified",
                       "additions": 1, "deletions": 1, "patch": "@@ -1 +1 @@\n-old editor line\n+new editor line"]]
        case root + "/commits/" + sha + "/check-runs": result = ["check_runs": [], "total_count": 0]
        case root + "/commits/" + sha + "/status": result = ["state": "success", "sha": sha, "statuses": []]
        default: unexpected.append(path); throw URLError(.resourceUnavailable)
        }
        return try JSONSerialization.data(withJSONObject: result)
    }
}

private final class GitHubCollaborationUIURLProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = GitHubCollaborationUIHTTP()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let bytes = try Self.fixture.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor final class GitHubCollaborationNativeUIHostTests: XCTestCase {
    @MainActor private struct Mounted {
        let window: UIWindow
        let previousKey: UIWindow?
        let host: UIHostingController<AnyView>
        func close() {
            window.isHidden = true; window.rootViewController = nil
            previousKey?.makeKeyAndVisible()
        }
    }
    private struct Node {
        let object: NSObject
        let identifier: String
        let label: String
        let frame: CGRect
    }
    private func nodes(in window: UIWindow) -> [Node] {
        var found: [Node] = [], seen = Set<ObjectIdentifier>()
        func visit(_ object: NSObject, depth: Int) {
            guard depth < 40, seen.count < 4096, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let id = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? ""
            let label = object.accessibilityLabel ?? ""
            if !id.isEmpty || !label.isEmpty {
                found.append(.init(object: object, identifier: id, label: label, frame: object.accessibilityFrame))
            }
            if let view = object as? UIView {
                view.subviews.forEach { visit($0, depth: depth + 1) }
            }
            if let elements = object.accessibilityElements {
                elements.compactMap { $0 as? NSObject }.forEach { visit($0, depth: depth + 1) }
            }
            let count = object.accessibilityElementCount()
            if count > 0 && count <= 2048 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject { visit(child, depth: depth + 1) }
                }
            }
        }
        visit(window, depth: 0)
        return found
    }
    private func capture(_ name: String, mounted: Mounted) {
        mounted.host.view.layoutIfNeeded(); mounted.window.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: mounted.window.bounds)
        let image = renderer.image { _ in mounted.window.drawHierarchy(in: mounted.window.bounds, afterScreenUpdates: true) }
        let screenshot = XCTAttachment(image: image)
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let inventory = nodes(in: mounted.window).map { "\($0.identifier) | \($0.label) | \($0.frame)" }.joined(separator: "\n")
        let hierarchy = XCTAttachment(string: inventory)
        hierarchy.name = name + "-public-AX"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
    private func wait(_ name: String, mounted: Mounted, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        repeat {
            mounted.window.layoutIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        } while ContinuousClock.now < deadline
        capture("FAILED-" + name, mounted: mounted)
        XCTFail(name)
        throw NSError(domain: "GitHubCollaborationNativeUI", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
    }
    private func views(in root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap { views(in: $0) }
    }
    private func visibleScrolls(_ mounted: Mounted) -> [UIScrollView] {
        views(in: mounted.host.view).compactMap { $0 as? UIScrollView }.filter {
            !$0.isHidden && $0.window === mounted.window && $0.bounds.width > 0 && $0.bounds.height > 0 &&
                $0.convert($0.bounds, to: mounted.window).intersects(mounted.window.bounds)
        }
    }
    private func captureNativeLayout(_ name: String, mounted: Mounted) {
        let bars = views(in: mounted.host.view).compactMap { $0 as? UINavigationBar }
        let descriptions = bars.map { bar -> String in
            let items = (bar.topItem?.leftBarButtonItems ?? []) + (bar.topItem?.rightBarButtonItems ?? [])
            let labels = items.map { [$0.title, $0.accessibilityLabel, $0.accessibilityIdentifier].compactMap { $0 }.joined(separator: " / ") }
            return "navigationBar frame=\(bar.convert(bar.bounds, to: mounted.window)) items=\(labels)"
        } + visibleScrolls(mounted).map { scroll in
            "scroll frame=\(scroll.convert(scroll.bounds, to: mounted.window)) content=\(scroll.contentSize)"
        }
        let attachment = XCTAttachment(string: descriptions.joined(separator: "\n"))
        attachment.name = name + "-native-UIKit-layout"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testNativeCollaborationRoutesAndComponentsUseTheActualMiniGeometry() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let tasks = SQLiteConversationStore(database: database), workspaces = SQLiteWorkspaceStore(database: database)
        let task = ConversationRecord(id: UUID(), title: "Native collaboration UI fixture", createdAt: Date(), updatedAt: Date())
        try await tasks.saveConversation(task)
        let workspace = try await workspaces.ensureWorkspace(conversationID: task.id, title: task.title)
        let boundID = try await workspaces.workspaceID(conversationID: task.id)
        XCTAssertEqual(boundID, workspace.id)
        let repository = GitHubLinkRepositoryID(owner: "qa", name: "native-ui")
        let scope = GitHubCollaborationScope(repository: repository, workspaceID: workspace.id, sourceTaskID: task.id)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitHub-native-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubCollaborationUIURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = GitHubCollaborationClient(client: GitHubActionsClient(session: session))
        let service = try GitHubCollaborationService(client: client, journalURL: root.appendingPathComponent("journal.json"))
        GitHubCollaborationUIURLProtocol.fixture.reset()
        func view(initialLink: GitHubLink? = nil, identity: String) -> AnyView {
            AnyView(GitHubCollaborationView(repository: repository, workspaceID: workspace.id, sourceTaskID: task.id,
                service: service, client: client, tokenProvider: { "" }, initialLink: initialLink,
                onWorkOnIssue: { _ in throw GitHubCollaborationError.operationMismatch },
                // This isolated native owner can edit local drafts. The HTTP
                // fixture still refuses every non-GET, and the test requires
                // both an empty mutation journal and zero remote writes.
                onReturnTask: {}, onSignIn: {}, authorize: {}).id(identity))
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive }
        let scene = try XCTUnwrap(scenes.count == 1 ? scenes.first : nil, "Use the single canonical iPad scene")
        let host = UIHostingController(rootView: view(identity: "list")), window = UIWindow(windowScene: scene)
        let mounted = Mounted(window: window, previousKey: scene.windows.first(where: \.isKeyWindow), host: host)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds; window.rootViewController = host; window.makeKeyAndVisible()
        defer { mounted.close(); session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(window.traitCollection.userInterfaceIdiom, .pad)
        XCTAssertEqual(window.bounds.size, scene.effectiveGeometry.coordinateSpace.bounds.size)
        XCTAssertGreaterThan(window.bounds.width, 0); XCTAssertGreaterThan(window.bounds.height, 0)
        func cleanupDraft() async {
            if let store = try? GitHubCollaborationDraftStores.store(for: scope), let drafts = try? await store.load() {
                for draft in drafts { try? await store.remove(draft.id) }
            }
            if let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
                let path = support.appendingPathComponent("FloeAgent/GitHubCollaborationDrafts").appendingPathComponent(scope.storageKey + ".json")
                try? FileManager.default.removeItem(at: path)
            }
        }
        do {
            try await wait("production list route reads the actual fixture with a real viewport", mounted: mounted) {
                GitHubCollaborationUIURLProtocol.fixture.readCount("/repos/qa/native-ui/issues") > 0 &&
                    !self.visibleScrolls(mounted).isEmpty
            }
            // This is a rendering settle, not proof of a click or an AX tree.
            // Screenshots and actual UIKit metrics remain the visual evidence.
            try await Task.sleep(for: .milliseconds(150))
            capture("01-native-collaboration-list", mounted: mounted)
            captureNativeLayout("01-native-collaboration-list", mounted: mounted)

            let issueLink = try GitHubLinkParser.parse("https://github.com/qa/native-ui/issues/7")
            host.rootView = view(initialLink: issueLink, identity: "issue-link")
            try await wait("production issue source-link reads its detail and discussion", mounted: mounted) {
                GitHubCollaborationUIURLProtocol.fixture.readCount("/repos/qa/native-ui/issues/7/comments") > 0 &&
                    !self.visibleScrolls(mounted).isEmpty
            }
            try await Task.sleep(for: .milliseconds(150))
            capture("02-native-issue-discussion", mounted: mounted)
            captureNativeLayout("02-native-issue-discussion", mounted: mounted)

            let pullLink = try GitHubLinkParser.parse("https://github.com/qa/native-ui/pull/42")
            host.rootView = view(initialLink: pullLink, identity: "pull-link")
            try await wait("production PR source-link reads its actual detail and files", mounted: mounted) {
                GitHubCollaborationUIURLProtocol.fixture.readCount("/repos/qa/native-ui/pulls/42/files") > 0 &&
                    GitHubCollaborationUIURLProtocol.fixture.readCount("/repos/qa/native-ui/issues/42/comments") > 0 &&
                    !self.visibleScrolls(mounted).isEmpty
            }
            try await Task.sleep(for: .milliseconds(150))
            capture("03-native-pull-discussion", mounted: mounted)
            captureNativeLayout("03-native-pull-discussion", mounted: mounted)

            // Public in-process SwiftUI AX is empty/zero-frame on this actual
            // Mini. Do not fake touches or silently call a coordinator and
            // label it a tap. The following are explicit production component
            // mounts, populated only by the same real client/store path.
            let detail = GitHubCollaborationCenter(repository: repository, workspaceID: workspace.id,
                sourceTaskID: task.id, service: service, client: client, tokenProvider: { "" },
                initialLink: pullLink, authorize: {})
            await detail.bootstrap(); await detail.loadDetail()
            let file = try XCTUnwrap(detail.files.first { $0.filename == "Sources/Editor.swift" })
            XCTAssertEqual(detail.pull?.head.sha, String(repeating: "a", count: 40))
            host.rootView = AnyView(NavigationStack { GitHubCollaborationFileView(center: detail, file: file) }.id("file-component"))
            try await wait("production diff component has a real bounded native viewport", mounted: mounted) {
                !self.visibleScrolls(mounted).isEmpty
            }
            try await Task.sleep(for: .milliseconds(150))
            capture("04-native-pull-file-diff-component", mounted: mounted)
            captureNativeLayout("04-native-pull-file-diff-component", mounted: mounted)

            let line = GitHubReviewLine(path: file.filename, side: .right, line: 1)
            try line.validate(in: [file])
            await detail.beginDraft(.lineComment, line: line, viewedHeadSHA: detail.pull?.head.sha,
                viewedFile: file, viewedSelection: detail.selection)
            let route = try XCTUnwrap(detail.draftRoute)
            host.rootView = AnyView(GitHubCollaborationComposer(center: detail, draftID: route.id, onSignIn: {}).id("draft-component"))
            func editor() -> UITextView? {
                self.views(in: host.view).compactMap { $0 as? UITextView }.first {
                    $0.isEditable && !$0.isHidden && $0.window === window && $0.bounds.width > 0 && $0.bounds.height > 0
                }
            }
            try await wait("actual native draft editor is laid out", mounted: mounted) { editor() != nil }
            let input = try XCTUnwrap(editor())
            XCTAssertGreaterThanOrEqual(input.bounds.width, 200)
            XCTAssertGreaterThanOrEqual(input.bounds.height, 150)
            XCTAssertTrue(input.convert(input.bounds, to: window).intersects(window.bounds))
            capture("05-native-line-comment-draft-component", mounted: mounted)
            captureNativeLayout("05-native-line-comment-draft-component", mounted: mounted)
            let store = try GitHubCollaborationDraftStores.store(for: scope)
            let drafts = try await store.load(), draft = try XCTUnwrap(drafts.first)
            XCTAssertEqual(drafts.count, 1); XCTAssertEqual(draft.scope, scope)
            XCTAssertEqual(draft.kind, .lineComment); XCTAssertEqual(draft.number, 42)
            XCTAssertEqual(draft.headSHA, String(repeating: "a", count: 40))
            XCTAssertEqual(draft.reviewLine?.path, "Sources/Editor.swift")
            XCTAssertEqual(draft.reviewLine?.line, 1); XCTAssertEqual(draft.prepared, false)
            let journal = await service.recent(ownerTaskID: task.id)
            XCTAssertTrue(journal.isEmpty, "Opening a local draft is not remote mutation authorization")
            let traffic = GitHubCollaborationUIURLProtocol.fixture.receipt()
            XCTAssertEqual(traffic.writes, 0); XCTAssertTrue(traffic.unexpected.isEmpty, "Unknown fixture reads must fail, not return generic success")
            let evidence = XCTAttachment(string: "Visual/click boundary: source-link routes and explicit real components are mounted. Public AX is diagnostic only; no touch/click success is claimed.\n" + traffic.paths.joined(separator: "\n"))
            evidence.name = "native-collaboration-real-client-GETs-and-boundary"; evidence.lifetime = .keepAlways; add(evidence)
            mounted.close(); await cleanupDraft()
        } catch {
            capture("FAILED-native-collaboration-final-state", mounted: mounted)
            mounted.close(); await cleanupDraft(); throw error
        }
    }
}
#endif
