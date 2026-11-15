// FloeAppTests — independent per-task browser execution (S7 item16).
//
// These are production-path tests: they use the compiled BrowserSessionCenter,
// BrowserTaskSession and the registered browser tools, with real WKWebViews
// loading synthetic offline HTML. Runtime-issued ToolContext identities select
// the task session; the visible projection is only a presentation concern.
//
// They are not executed in the code-first S5–S7 stage. Run them at the unified
// freeze together with the existing BrowserProtocol suites.

#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit) && DEBUG
import Foundation
import Testing
import WebKit
import SwiftUI
import UIKit
import FloeCore
import FloeModels
import FloeTools
import FloeEnvironments
import FloeExecution
@testable import FloeApp

@Suite("FloeApp.BrowserTaskIsolation", .serialized)
@MainActor
struct BrowserTaskSessionTests {
    // MARK: - Fixtures

    private func makeCenter() -> BrowserSessionCenter {
        BrowserSessionCenter(durableHandoffs: false)
    }

    private func makeRegistry(_ center: BrowserSessionCenter) -> ToolRunnerRegistry {
        let registry = ToolRunnerRegistry()
        registerBrowserTools(center: center, registry: registry)
        return registry
    }

    private func context(
        for owner: UUID,
        runID: UUID = UUID(),
        temporary: Bool = false
    ) -> ToolContext {
        ToolContext(
            runID: runID,
            cancellation: CancellationToken(),
            conversationID: owner,
            temporaryReadOnly: temporary
        )
    }

    /// Builds a tool context for a delegated child of `parentRunID` under the
    /// given root task. The identity mirrors what the parent runtime mints:
    /// never Codable, never model-issued.
    private func childContext(
        for owner: UUID,
        parentRunID: UUID,
        childID: UUID = UUID(),
        rootTaskID: UUID? = nil,
        depth: Int = 1,
        runID: UUID = UUID()
    ) -> ToolContext {
        let handoff = ChildExecutionHandoff(
            identity: ChildExecutionIdentity(
                childID: childID,
                parentRunID: parentRunID,
                rootTaskID: rootTaskID ?? owner,
                delegateCallID: "delegate-call-1",
                depth: depth
            ),
            dispatcher: ChildToolDispatcher(
                descriptorProvider: { _ in nil },
                allDescriptors: { [] },
                dispatch: { _, _ in
                    ToolResult(
                        callID: "unused",
                        status: .failed,
                        outputSummary: "unused",
                        outputDigest: ""
                    )
                }
            ),
            peers: PeerCollaborationHandle(
                register: { _ in },
                unregister: { },
                drain: { [] },
                peers: { _ in [] },
                send: { _, _, _ in SubagentPeerSendReceipt(accepted: false, reason: "unused") }
            )
        )
        return ToolContext(
            runID: runID,
            cancellation: CancellationToken(),
            conversationID: owner,
            childExecution: handoff
        )
    }

    private func run(
        _ registry: ToolRunnerRegistry,
        _ name: String,
        _ arguments: String,
        as context: ToolContext
    ) async throws -> String {
        let runner = try #require(registry.runner(named: name), "missing \(name)")
        return try await runner.execute(
            argumentsJSON: Data(arguments.utf8),
            context: context
        ).summary
    }

    private func object(_ summary: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(summary.utf8)) as? [String: Any] else {
            throw FloeError.storageCorrupted("expected a JSON object from a browser tool")
        }
        return value
    }

    private func page(_ summary: String) throws -> [String: Any] {
        let value = try object(summary)
        guard let page = value["page"] as? [String: Any] else {
            throw FloeError.storageCorrupted("browser result has no page snapshot")
        }
        return page
    }

    private func nodesText(_ page: [String: Any]) -> String {
        let nodes = page["nodes"] as? [[String: Any]] ?? []
        return nodes.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private func button(in page: [String: Any]) throws -> [String: Any] {
        let nodes = page["nodes"] as? [[String: Any]] ?? []
        guard let button = nodes.first(where: { ($0["role"] as? String) == "button" }) else {
            throw FloeError.storageCorrupted("fixture page has no button node")
        }
        return button
    }

    private func fixturePage(_ marker: String) -> String {
        """
        <!doctype html><html><body style="margin:0">
          <button id="go" style="width:180px;height:60px"
            onclick="document.getElementById('status').textContent='clicked-\(marker)'">Go \(marker)</button>
          <p id="status">ready-\(marker)</p>
        </body></html>
        """
    }

    private func storageFixturePage() -> String {
        """
        <!doctype html><html><body>
          <h1>Storage fixture</h1>
          <a id="next" href="/next?from=fixture">Next page</a>
          <a id="external" href="https://example.org/other">External</a>
          <table><caption>Synthetic prices</caption>
            <tr><th>Item</th><th>Cost</th></tr>
            <tr><td>Pen</td><td>2</td></tr>
          </table>
          <p>Alpha beta gamma.</p>
        </body></html>
        """
    }

    /// A task session that never touches the user's shared WebKit store.
    /// The session is constructed directly so the test owns its lifetime and
    /// can inject `WKWebsiteDataStore.nonPersistent()`.
    private func isolatedSession(
        owner: UUID,
        center: BrowserSessionCenter
    ) throws -> (session: BrowserTaskSession, tab: UUID, store: WKWebsiteDataStore) {
        let store = WKWebsiteDataStore.nonPersistent()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-storage-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = BrowserTaskSession(
            conversationID: owner,
            generation: 0,
            configuration: BrowserTaskSessionConfiguration(
                protocolVersion: "FloeBrowser/1.0",
                contentWorld: WKContentWorld.world(
                    name: "org.floeagent.browser.storage." + UUID().uuidString
                ),
                artifactDirectory: root,
                maximumTabs: 6,
                maximumEventsPerTab: 64,
                websiteDataStoreProvider: { store }
            ),
            host: center
        )
        _ = session.createTab()
        let tab = try #require(session.activeTabID)
        return (session, tab, store)
    }

    private func loadIsolated(
        _ html: String,
        baseURL: URL = URL(string: "https://storage.example.test/fixture/page")!,
        tab: UUID,
        session: BrowserTaskSession
    ) async throws {
        let webView = try #require(session.tabs.first(where: { $0.id == tab })?.webView)
        webView.loadHTMLString(html, baseURL: baseURL)
        let result = await session.execute(BrowserCommand(
            sessionID: session.sessionID,
            tabID: tab,
            action: .wait(.load)
        ))
        try #require(
            result.status == .ok,
            Comment(rawValue: result.message ?? result.error?.message ?? "synthetic page did not load")
        )
    }

    @discardableResult
    private func load(
        _ html: String,
        tab: UUID,
        in session: BrowserTaskSession,
        registry: ToolRunnerRegistry,
        context: ToolContext
    ) async throws -> [String: Any] {
        let webView = try #require(session.tabs.first(where: { $0.id == tab })?.webView)
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/\(UUID().uuidString)")!)
        let waited = try await run(
            registry,
            "browser.wait",
            "{\"tabID\":\"\(tab)\",\"condition\":\"load\",\"timeoutMilliseconds\":10000}",
            as: context
        )
        #expect(waited.contains("\"status\":\"ok\""), Comment(rawValue: waited))
        return try page(waited)
    }

    private func observe(
        tab: UUID,
        registry: ToolRunnerRegistry,
        context: ToolContext
    ) async throws -> [String: Any] {
        try page(try await run(registry, "browser.observe", "{\"tabID\":\"\(tab)\"}", as: context))
    }

    @Test("Design arguments never alter default semantic observation or create a session on validation failure")
    func designProfileValidationIsIsolated() async throws {
        let center = makeCenter()
        let registry = makeRegistry(center)
        let owner = UUID()
        let ctx = context(for: owner)
        for args in [
            #"{"profile":"semantic","captureID":"00000000-0000-0000-0000-000000000001"}"#,
            #"{"profile":"design","cursor":0}"#,
            #"{"profile":"design","designAction":"facts"}"#,
            #"{"profile":"design","designAction":"capture","needsFile":"needs.json"}"#
        ] {
            await #expect(throws: (any Error).self) { _ = try await run(registry, "browser.observe", args, as: ctx) }
        }
        #expect(center.session(for: owner) == nil)
    }

    @Test("Native WebKit design capture redacts output, measures facts and releases exact task files without running an engine")
    func designCaptureUsesActualWebKitAndTaskWorkspace() async throws {
        let center = makeCenter()
        let owner = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("design-tool-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { center.discard(conversationID: owner); try? FileManager.default.removeItem(at: root) }
        let registry = makeRegistry(center)
        var ctx = context(for: owner)
        ctx.workspaceRootURL = root
        // Tool execution resolves its environment through the process-wide
        // routing the real app factory installs; build the preview factory so
        // this test installs exactly the routing it exercises instead of
        // depending on another test's global setup (production-chain-test
        // precedent). Register this run's OWN session container through the
        // production run-binding path: registry metadata only — no VM boot, no
        // guest start — owned by exactly this conversation and this workspace
        // root; never an unregistered label, a guessed id or a first-
        // environment fallback. This stays a native measurement fixture, not
        // evidence of guest execution.
        let appEnvironment = AppEnvironment.preview()
        let bound = await ConversationCenter.ensureRunEnvironmentBinding(
            registry: appEnvironment.environmentRegistry,
            conversationID: owner,
            taskRoot: root)
        let boundEnvironmentID = try #require(
            bound,
            "the preview environment must register this task's own session container")
        ctx.environmentID = boundEnvironmentID
        // Cleanup only this test's own descriptor after the joined work (each
        // tool lease finishes inside its own execution): the session container
        // and this workspace's project container, mirroring the production-
        // chain teardown. Nothing else in the registry is touched.
        let ownedRegistry = appEnvironment.environmentRegistry
        let registeredWorkspaceID = FloeDigest.sha256Hex(Data(
            root.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
        func removeOwnedContainers() async {
            do { _ = try await ownedRegistry.remove(id: boundEnvironmentID) }
            catch { Issue.record("Owned browser fixture session cleanup failed: \(error)") }
            let projectContainers = await ownedRegistry
                .containersOwned(by: registeredWorkspaceID)
            if let project = projectContainers.first(where: { $0.kind == .project }) {
                do { _ = try await ownedRegistry.remove(id: project.id) }
                catch { Issue.record("Owned browser fixture project cleanup failed: \(error)") }
            }
        }
        do {
            _ = try await run(registry, "browser.tabs", "{}", as: ctx)
            let session = try #require(center.session(for: owner))
            let tab = try #require(session.activeTabID)
            try await load("""
                <!doctype html><html><body style="margin:0">
                <h1>Design fixture</h1><input id="credential" type="password" value="synthetic-secret-9264">
                <p>Measured page</p></body></html>
                """, tab: tab, in: session, registry: registry, context: ctx)
            let baseline = try await observe(tab: tab, registry: registry, context: ctx)
            let explicitSemantic = try page(try await run(registry, "browser.observe", #"{"profile":"semantic"}"#, as: ctx))
            #expect(nodesText(baseline) == nodesText(explicitSemantic))
            let summary = try await run(registry, "browser.observe", #"{"profile":"design"}"#, as: ctx)
            let result = try object(summary)
            #expect(result["engineRun"] as? Bool == false)
            #expect(!summary.contains(root.path))
            #expect(!summary.contains("synthetic-secret-9264"))
            let capture = try #require(result["capture"] as? [String: Any])
            let id = try #require(capture["captureId"] as? String)
            let relative = try #require(capture["relativeSnapshotFile"] as? String)
            #expect(relative.hasPrefix("Impeccable/" + owner.uuidString + "/"))
            let snapshot = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            #expect(!snapshot.contains("synthetic-secret-9264"))
            let webView = try #require(session.tabs.first(where: { $0.id == tab })?.webView)
            #expect(try await webView.evaluateJavaScript("document.getElementById('credential').value") as? String == "synthetic-secret-9264")

            var foreignRun = ctx
            foreignRun.runID = UUID()
            await #expect(throws: (any Error).self) {
                _ = try await run(registry, "browser.observe", #"{"profile":"design","designAction":"release","captureID":"\#(id)"}"#, as: foreignRun)
            }
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path))

            let needs: [String: Any] = ["round": 1, "hitTests": [[10.0, 10.0]],
                "hitTestsBits": [[String(10.0.bitPattern), String(10.0.bitPattern)]], "scrollProbes": []]
            try JSONSerialization.data(withJSONObject: needs).write(to: root.appendingPathComponent("needs.json"), options: .atomic)
            let factsResult = try object(try await run(registry, "browser.observe",
                #"{"profile":"design","designAction":"facts","captureID":"\#(id)","needsFile":"needs.json"}"#, as: ctx))
            let factsPath = try #require(factsResult["relativeFactsFile"] as? String)
            let facts = try object(String(decoding: Data(contentsOf: root.appendingPathComponent(factsPath)), as: UTF8.self))
            #expect(facts["taskId"] as? String == owner.uuidString)
            #expect(facts["captureId"] as? String == id)
            _ = try await run(registry, "browser.observe",
                #"{"profile":"design","designAction":"release","captureID":"\#(id)"}"#, as: ctx)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).deletingLastPathComponent().path))
        } catch {
            await removeOwnedContainers()
            throw error
        }
        await removeOwnedContainers()
    }

    @Test("Design capture refuses temporary use and missing task workspace bindings")
    func designCaptureKeepsTemporaryAndWorkspaceCeilings() async throws {
        let center = makeCenter()
        let registry = makeRegistry(center)
        let owner = UUID()
        defer { center.discard(conversationID: owner) }
        await #expect(throws: (any Error).self) {
            _ = try await run(registry, "browser.observe", #"{"profile":"design"}"#, as: context(for: owner, temporary: true))
        }
        #expect(center.session(for: owner) == nil)
        await #expect(throws: (any Error).self) {
            _ = try await run(registry, "browser.observe", #"{"profile":"design"}"#, as: context(for: owner))
        }
    }

    @Test("Foreign managed-service navigation is refused before creating a task browser")
    func foreignServiceCannotPassToolPreflightIntoAnotherSession() async throws {
        let center = makeCenter()
        let registry = makeRegistry(center)
        let owner = UUID(), other = UUID(), service = UUID()
        let url = URL(string: "http://127.0.0.1:53429/")!
        BrowserURLPolicy.authorizeService(url, owner: service, conversationID: owner)
        defer { BrowserURLPolicy.revokeService(owner: service); center.discard(conversationID: other) }
        #expect(try BrowserURLPolicy.validate(url.absoluteString, conversationID: owner) == url)
        #expect(throws: BrowserPolicyError.self) { try BrowserURLPolicy.validate(url.absoluteString) }
        #expect(throws: BrowserPolicyError.self) { try BrowserURLPolicy.validate(url.absoluteString, conversationID: other) }
        await #expect(throws: (any Error).self) {
            _ = try await run(registry, "browser.navigate", #"{"url":"http://127.0.0.1:53429/"}"#, as: context(for: other))
        }
        #expect(center.session(for: other) == nil)
        BrowserURLPolicy.revokeService(owner: service)
        #expect(throws: BrowserPolicyError.self) { try BrowserURLPolicy.validate(url.absoluteString, conversationID: owner) }
    }

    // MARK: - Two independent owners

    @Test("Distinct trusted tasks execute in independent sessions while the visible panel stays on its owner")
    func independentSessionsForDistinctOwners() async throws {
        let center = makeCenter()
        let ownerA = UUID()
        let ownerB = UUID()
        center.bind(to: ownerA)
        let registry = makeRegistry(center)
        let contextA = context(for: ownerA)
        let contextB = context(for: ownerB)

        // B's first tool call creates B's session without focusing its panel.
        let listingB = try await run(registry, "browser.tabs", "{}", as: contextB)
        let sessionA = try #require(center.session(for: ownerA))
        let sessionB = try #require(center.session(for: ownerB))
        let tabA = try #require(sessionA.activeTabID)
        let tabB = try #require(sessionB.activeTabID)
        #expect(tabA != tabB)
        #expect(sessionA.sessionID != sessionB.sessionID)
        #expect(center.conversationID == ownerA)
        #expect(center.activeTabID == tabA)
        #expect(!center.tabs.contains(where: { $0.id == tabB }))
        #expect(listingB.contains("\"status\":\"ok\""), Comment(rawValue: listingB))
        #expect(listingB.contains(tabB.uuidString))
        #expect(!listingB.contains(tabA.uuidString))

        try await load(fixturePage("alpha"), tab: tabA, in: sessionA, registry: registry, context: contextA)
        try await load(fixturePage("beta"), tab: tabB, in: sessionB, registry: registry, context: contextB)

        let pageA = try await observe(tab: tabA, registry: registry, context: contextA)
        let pageB = try await observe(tab: tabB, registry: registry, context: contextB)
        let documentA = try #require(pageA["documentID"] as? String)
        let documentB = try #require(pageB["documentID"] as? String)
        #expect(documentA != documentB)
        #expect(nodesText(pageA).contains("ready-alpha"))
        #expect(nodesText(pageB).contains("ready-beta"))

        // B's execution never replaced the visible projection.
        #expect(center.conversationID == ownerA)
        #expect(center.activeTabID == tabA)
        #expect(center.activeWebView === sessionA.activeWebView)
    }

    @Test("Overlapped asynchronous work in one session survives a visible-owner switch")
    func overlappedWorkSurvivesVisibleOwnerSwitch() async throws {
        let center = makeCenter()
        let ownerA = UUID()
        let ownerB = UUID()
        center.bind(to: ownerA)
        let registry = makeRegistry(center)
        let contextA = context(for: ownerA)
        let contextB = context(for: ownerB)
        let sessionA = try #require(center.session(for: ownerA))
        _ = try await run(registry, "browser.tabs", "{}", as: contextB)
        let sessionB = try #require(center.session(for: ownerB))
        let tabA = try #require(sessionA.activeTabID)
        let tabB = try #require(sessionB.activeTabID)

        try await load(fixturePage("alpha"), tab: tabA, in: sessionA, registry: registry, context: contextA)
        try await load(fixturePage("beta"), tab: tabB, in: sessionB, registry: registry, context: contextB)
        let webViewA = try #require(sessionA.activeWebView)
        _ = try? await webViewA.evaluateJavaScript(
            "setTimeout(() => { document.getElementById('status').textContent = 'ready-late-alpha'; }, 600)"
        )

        let waitingA = Task {
            try await run(
                registry,
                "browser.wait",
                "{\"tabID\":\"\(tabA)\",\"condition\":\"text\",\"value\":\"ready-late-alpha\",\"timeoutMilliseconds\":10000}",
                as: contextA
            )
        }
        // Switch the visible panel while A's wait is still in flight.
        center.bind(to: ownerB)
        #expect(center.conversationID == ownerB)
        #expect(center.activeTabID == tabB)

        let pageB = try await observe(tab: tabB, registry: registry, context: contextB)
        #expect(nodesText(pageB).contains("ready-beta"))

        let waitedA = try await waitingA.value
        #expect(waitedA.contains("\"status\":\"ok\""), Comment(rawValue: waitedA))
        let pageA = try await observe(tab: tabA, registry: registry, context: contextA)
        #expect(nodesText(pageA).contains("ready-late-alpha"))
        #expect(center.conversationID == ownerB)

        center.bind(to: ownerA)
        #expect(center.activeTabID == tabA)
        #expect(center.activeWebView === sessionA.activeWebView)
    }

    // MARK: - Forgery and absent owners

    @Test("Foreign tabs, documents and sessions are rejected; nil and temporary owners cannot browse")
    func foreignReferencesAndAbsentOwnerAreRejected() async throws {
        let center = makeCenter()
        let ownerA = UUID()
        let ownerB = UUID()
        center.bind(to: ownerA)
        let registry = makeRegistry(center)
        let contextA = context(for: ownerA)
        let contextB = context(for: ownerB)
        let sessionA = try #require(center.session(for: ownerA))
        _ = try await run(registry, "browser.tabs", "{}", as: contextB)
        let sessionB = try #require(center.session(for: ownerB))
        let tabA = try #require(sessionA.activeTabID)
        let tabB = try #require(sessionB.activeTabID)
        try await load(fixturePage("alpha"), tab: tabA, in: sessionA, registry: registry, context: contextA)
        try await load(fixturePage("beta"), tab: tabB, in: sessionB, registry: registry, context: contextB)
        let pageA = try await observe(tab: tabA, registry: registry, context: contextA)
        let pageB = try await observe(tab: tabB, registry: registry, context: contextB)
        let documentA = try #require(pageA["documentID"] as? String)
        let documentB = try #require(pageB["documentID"] as? String)
        let referenceA = try #require(try button(in: pageA)["ref"] as? String)

        // A's tab cannot be activated through B's tools.
        await #expect(throws: (any Error).self) {
            _ = try await run(
                registry,
                "browser.tab",
                "{\"action\":\"activate\",\"tabID\":\"\(tabA)\"}",
                as: contextB
            )
        }
        // A's document and element reference cannot be used in B.
        await #expect(throws: (any Error).self) {
            _ = try await run(
                registry,
                "browser.click",
                "{\"tabID\":\"\(tabB)\",\"ref\":\"\(referenceA)\",\"documentID\":\"\(documentA)\"}",
                as: contextB
            )
        }
        // A command carrying another owner's session ID is stale even when the
        // owner itself is trusted.
        let forgedSession = await center.execute(
            BrowserCommand(sessionID: sessionB.sessionID, tabID: tabB, action: .observe(cursor: nil)),
            in: ownerA
        )
        #expect(forgedSession.status == .stale)
        #expect(forgedSession.error?.code == "session")

        let anonymous = ToolContext(runID: UUID(), cancellation: CancellationToken())
        await #expect(throws: (any Error).self) {
            _ = try await run(registry, "browser.tabs", "{}", as: anonymous)
        }
        let temporary = context(for: ownerA, temporary: true)
        await #expect(throws: (any Error).self) {
            _ = try await run(registry, "browser.tabs", "{}", as: temporary)
        }

        // requestUser cannot conjure a browser for a task that has none.
        let neverBrowsed = UUID()
        await #expect(throws: (any Error).self) {
            _ = try await run(
                registry,
                "browser.panel",
                "{\"action\":\"requestUser\",\"reason\":\"Open a page first\"}",
                as: context(for: neverBrowsed)
            )
        }
        #expect(center.session(for: neverBrowsed) == nil)

        let stillB = try await observe(tab: tabB, registry: registry, context: contextB)
        #expect(stillB["documentID"] as? String == documentB)
    }

    // MARK: - Handoff and takeover

    @Test("Takeover of one task neither blocks nor mutates another, and cannot hide its panel")
    func takeoverIsIsolated() async throws {
        let center = makeCenter()
        let ownerA = UUID()
        let ownerB = UUID()
        center.bind(to: ownerA)
        let registry = makeRegistry(center)
        let contextA = context(for: ownerA)
        let contextB = context(for: ownerB)
        let sessionA = try #require(center.session(for: ownerA))
        _ = try await run(registry, "browser.tabs", "{}", as: contextB)
        let sessionB = try #require(center.session(for: ownerB))
        let tabA = try #require(sessionA.activeTabID)
        let tabB = try #require(sessionB.activeTabID)
        try await load(fixturePage("alpha"), tab: tabA, in: sessionA, registry: registry, context: contextA)
        try await load(fixturePage("beta"), tab: tabB, in: sessionB, registry: registry, context: contextB)
        let pageB = try await observe(tab: tabB, registry: registry, context: contextB)

        let panel = try await run(
            registry,
            "browser.panel",
            "{\"action\":\"requestUser\",\"reason\":\"Sign in to task A\"}",
            as: contextA
        )
        #expect(panel.contains("The user controls this task's browser"), Comment(rawValue: panel))
        #expect(center.presentationRequest?.conversationID == ownerA)
        #expect(center.presentationRequest?.show == true)
        #expect(sessionA.isUserControlling)
        #expect(!sessionB.isUserControlling)

        // While the user operates A, the model gets needsUser with no page,
        // screenshot, events or text. Reading the user's page is forbidden.
        let refusedA = try await run(
            registry, "browser.observe", "{\"tabID\":\"\(tabA)\"}", as: contextA)
        #expect(refusedA.contains("\"status\":\"needsUser\""), Comment(rawValue: refusedA))
        let refusedPage = try object(refusedA)
        #expect(refusedPage["page"] == nil)
        #expect((refusedPage["events"] as? [Any])?.isEmpty ?? true)
        #expect(!refusedA.contains("ready-alpha"))
        let refusedText = try await run(
            registry, "browser.text", "{\"tabID\":\"\(tabA)\"}", as: contextA)
        #expect(refusedText.contains("\"status\":\"needsUser\""), Comment(rawValue: refusedText))
        #expect(!refusedText.contains("ready-alpha"))
        let refusedShot = try await run(
            registry, "browser.screenshot", "{\"tabID\":\"\(tabA)\"}", as: contextA)
        #expect(refusedShot.contains("\"status\":\"needsUser\""), Comment(rawValue: refusedShot))
        #expect(!refusedShot.contains("screenshotArtifact"))
        // B keeps reading and mutating its own page.
        let documentB = try #require(pageB["documentID"] as? String)
        let referenceB = try #require(try button(in: pageB)["ref"] as? String)
        let clickedB = try await run(
            registry,
            "browser.click",
            "{\"tabID\":\"\(tabB)\",\"ref\":\"\(referenceB)\",\"documentID\":\"\(documentB)\"}",
            as: contextB
        )
        #expect(clickedB.contains("\"status\":\"ok\""), Comment(rawValue: clickedB))
        let clickedPageB = try page(clickedB)
        #expect(nodesText(clickedPageB).contains("clicked-beta"))

        // A's own mutation also waits for the return; no page observation can
        // supply it a command, and even a well-formed click is refused.
        let deniedA = try await run(
            registry,
            "browser.click",
            "{\"tabID\":\"\(tabA)\",\"ref\":\"n1\",\"documentID\":\"stale\"}",
            as: contextA
        )
        #expect(deniedA.contains("\"status\":\"needsUser\""), Comment(rawValue: deniedA))

        // B cannot dismiss A's visible panel.
        let requestBeforeHide = center.presentationRequest
        await #expect(throws: (any Error).self) {
            _ = try await run(registry, "browser.panel", "{\"action\":\"hide\"}", as: contextB)
        }
        #expect(center.presentationRequest == requestBeforeHide)

        center.deliverHandoff = { _, _ in false }
        await center.returnToAgent()
        #expect(!sessionA.isUserControlling)
        #expect(!sessionB.isUserControlling)
        #expect(center.handoffNotified)

        // A works again after the return, with fresh document evidence.
        let returnedA = try await observe(tab: tabA, registry: registry, context: contextA)
        let returnedDocument = try #require(returnedA["documentID"] as? String)
        let returnedReference = try #require(try button(in: returnedA)["ref"] as? String)
        let clickedA = try await run(
            registry,
            "browser.click",
            "{\"tabID\":\"\(tabA)\",\"ref\":\"\(returnedReference)\",\"documentID\":\"\(returnedDocument)\"}",
            as: contextA
        )
        #expect(clickedA.contains("\"status\":\"ok\""), Comment(rawValue: clickedA))
        #expect(!clickedA.contains("needsUser"))
    }

    @Test("Return delivery and recovery target the exact original task and run")
    func handoffTargetsExactRun() async throws {
        let center = makeCenter()
        let ownerA = UUID()
        let ownerB = UUID()
        let runA = UUID()
        let runB = UUID()
        center.bind(to: ownerA)
        let registry = makeRegistry(center)
        let contextA = context(for: ownerA, runID: runA)
        let contextB = context(for: ownerB, runID: runB)
        _ = try await run(registry, "browser.tabs", "{}", as: contextB)

        var attempts: [BrowserSessionCenter.Handoff] = []
        var failFirstAttempt = true
        center.deliverHandoff = { event, _ in
            attempts.append(event)
            if failFirstAttempt {
                failFirstAttempt = false
                throw FloeError.validationFailed("synthetic delivery failure")
            }
            return false
        }

        _ = try await run(
            registry,
            "browser.panel",
            "{\"action\":\"requestUser\",\"reason\":\"Enter the code shown on A\"}",
            as: contextA
        )
        _ = try await run(
            registry,
            "browser.panel",
            "{\"action\":\"requestUser\",\"reason\":\"Sign in on B\"}",
            as: contextB
        )
        let eventA = try #require(center.handoff(for: ownerA))
        let eventB = try #require(center.handoff(for: ownerB))
        #expect(eventA.runID == runA)
        #expect(eventB.runID == runB)
        #expect(center.handoff?.id == eventA.id)
        // Both owners keep a pending request; the later one is only the latest
        // route event and never erases the other task's prompt.
        #expect(center.pendingPanelRequest(for: ownerA)?.show == true)
        #expect(center.pendingPanelRequest(for: ownerB)?.show == true)
        #expect(center.presentationRequest?.conversationID == ownerB)

        // A failed delivery keeps A user-controlled and reports the error.
        await center.returnToAgent()
        #expect(attempts.count == 1)
        #expect(attempts.first?.id == eventA.id)
        #expect(center.handoffError != nil)
        #expect(center.session(for: ownerA)?.isUserControlling == true)

        // Retrying the same receipt succeeds and notifies only A.
        await center.returnToAgent()
        #expect(attempts.count == 2)
        #expect(center.handoffNotified)
        #expect(center.session(for: ownerA)?.isUserControlling == false)
        #expect(center.session(for: ownerB)?.isUserControlling == true)

        // A late recovery with a different run is ignored.
        await center.recoverHandoff(conversationID: ownerA, runID: runB)
        #expect(attempts.count == 2)
        // The exact run consumes the same durable receipt once.
        await center.recoverHandoff(conversationID: ownerA, runID: runA)
        #expect(attempts.count == 3)
        #expect(attempts.last?.id == eventA.id)
        #expect(center.session(for: ownerB)?.isUserControlling == true)
    }

    // MARK: - Release and artifact ownership

    @Test("Releasing one task leaves the other usable and fences late work")
    func releaseOwnsOneTaskOnly() async throws {
        let center = makeCenter()
        let ownerA = UUID()
        let ownerB = UUID()
        center.bind(to: ownerA)
        let registry = makeRegistry(center)
        let contextA = context(for: ownerA)
        let contextB = context(for: ownerB)
        let sessionA = try #require(center.session(for: ownerA))
        _ = try await run(registry, "browser.tabs", "{}", as: contextB)
        let sessionB = try #require(center.session(for: ownerB))
        let tabA = try #require(sessionA.activeTabID)
        let tabB = try #require(sessionB.activeTabID)
        try await load(fixturePage("alpha"), tab: tabA, in: sessionA, registry: registry, context: contextA)
        try await load(fixturePage("beta"), tab: tabB, in: sessionB, registry: registry, context: contextB)
        let pageB = try await observe(tab: tabB, registry: registry, context: contextB)
        let documentB = try #require(pageB["documentID"] as? String)
        let releasedWebView = try #require(sessionA.activeWebView)
        #expect(center.activeTaskSessionCount == 2)

        center.discard(conversationID: ownerA)
        #expect(center.session(for: ownerA) == nil)
        #expect(sessionA.isReleased)
        #expect(sessionA.tabs.isEmpty)
        #expect(sessionA.activeExecutionCount == 0)
        #expect(releasedWebView.navigationDelegate == nil)
        #expect(releasedWebView.uiDelegate == nil)
        #expect(releasedWebView.superview == nil)
        #expect(center.conversationID == nil)

        // B's session is untouched and its page still answers.
        #expect(center.session(for: ownerB) === sessionB)
        #expect(center.activeTaskSessionCount == 1)
        let stillB = try await observe(tab: tabB, registry: registry, context: contextB)
        #expect(stillB["documentID"] as? String == documentB)
        #expect(nodesText(stillB).contains("ready-beta"))

        // Late work for the released task is fenced and cannot recreate it.
        await #expect(throws: (any Error).self) {
            _ = try await run(registry, "browser.observe", "{\"tabID\":\"\(tabA)\"}", as: contextA)
        }
        #expect(center.session(for: ownerA) == nil)
        let lateCommand = await center.execute(
            BrowserCommand(sessionID: sessionA.sessionID, tabID: tabA, action: .observe(cursor: nil)),
            in: ownerA
        )
        #expect(lateCommand.status == .stale)
        #expect(center.session(for: ownerA) == nil)
        #expect(center.activeTaskSessionCount == 1)
    }

    @Test("Screenshots, documents and visual evidence stay with their owning task")
    func artifactsAndEvidenceAreOwnerScoped() async throws {
        let center = makeCenter()
        let ownerA = UUID()
        let ownerB = UUID()
        center.bind(to: ownerA)
        let registry = makeRegistry(center)
        let contextA = context(for: ownerA)
        let contextB = context(for: ownerB)
        let sessionA = try #require(center.session(for: ownerA))
        _ = try await run(registry, "browser.tabs", "{}", as: contextB)
        let sessionB = try #require(center.session(for: ownerB))
        let tabA = try #require(sessionA.activeTabID)
        let tabB = try #require(sessionB.activeTabID)
        try await load(
            "<!doctype html><html><body style=\"margin:0;background:#fff\"><p>alpha evidence</p></body></html>",
            tab: tabA,
            in: sessionA,
            registry: registry,
            context: contextA
        )
        try await load(
            "<!doctype html><html><body style=\"margin:0;background:#000;color:#fff\"><p>beta evidence</p></body></html>",
            tab: tabB,
            in: sessionB,
            registry: registry,
            context: contextB
        )

        let shotA = try page(try await run(registry, "browser.screenshot", "{\"tabID\":\"\(tabA)\"}", as: contextA))
        let shotB = try page(try await run(registry, "browser.screenshot", "{\"tabID\":\"\(tabB)\"}", as: contextB))
        let artifactA = try #require(shotA["screenshotArtifact"] as? [String: Any])
        let artifactB = try #require(shotB["screenshotArtifact"] as? [String: Any])
        let digestA = try #require(artifactA["sha256"] as? String)
        let digestB = try #require(artifactB["sha256"] as? String)
        let documentA = try #require(shotA["documentID"] as? String)
        let documentB = try #require(shotB["documentID"] as? String)
        #expect(documentA != documentB)
        #expect(digestA != digestB)
        let artifactIDA = try #require(artifactA["id"] as? String)
        let artifactIDB = try #require(artifactB["id"] as? String)
        #expect(artifactIDA != artifactIDB)
        #expect((artifactA["relativePath"] as? String)?.contains("BrowserArtifacts/") == true)
        #expect((artifactB["relativePath"] as? String)?.contains("BrowserArtifacts/") == true)

        // B cannot authorize a coordinate click with A's screenshot digest.
        let leaseB = try #require(sessionB.modelControl)
        let foreignEvidence = await center.execute(
            BrowserCommand(
                sessionID: sessionB.sessionID,
                tabID: tabB,
                expectedDocumentID: documentB,
                visualEvidenceSHA256: digestA,
                visualFallbackReason: "noStructuredTarget",
                action: .click(.point(x: 12, y: 12))
            ),
            in: ownerB,
            control: leaseB
        )
        #expect(foreignEvidence.status == .blocked)
        #expect(foreignEvidence.message?.contains("fresh screenshot") == true)

        // A's own digest passes evidence validation and is only rejected for
        // the structured/point boundary, never for a foreign screenshot.
        let leaseA = try #require(sessionA.modelControl)
        let ownEvidence = await center.execute(
            BrowserCommand(
                sessionID: sessionA.sessionID,
                tabID: tabA,
                expectedDocumentID: documentA,
                visualEvidenceSHA256: digestA,
                visualFallbackReason: "noStructuredTarget",
                action: .click(.point(x: 12, y: 12))
            ),
            in: ownerA,
            control: leaseA
        )
        #expect(ownEvidence.message?.contains("fresh screenshot") != true)
    }

    // MARK: - Release fence, reactivation and generation (repair)

    @Test("A released owner can never be recreated by late tool callbacks; the fence has no time expiry")
    func releasedOwnerStaysFencedForLateToolCallbacks() async throws {
        let center = makeCenter()
        let ownerA = UUID()
        let ownerB = UUID()
        center.bind(to: ownerA)
        let registry = makeRegistry(center)
        let contextA = context(for: ownerA)
        let contextB = context(for: ownerB)
        let sessionA = try #require(center.session(for: ownerA))
        _ = try await run(registry, "browser.tabs", "{}", as: contextB)
        #expect(center.activeTaskSessionCount == 2)

        center.discard(conversationID: ownerA)
        #expect(center.session(for: ownerA) == nil)
        #expect(sessionA.isReleased)
        let generationAtRelease = center.generation(for: ownerA)

        // The late callback is refused through the tool path...
        await #expect(throws: (any Error).self) {
            _ = try await run(registry, "browser.observe", "{}", as: contextA)
        }
        // ...and through the raw center execution path, with no session ever
        // recreated for the deleted owner. There is intentionally no waiting:
        // the fence is permanent, so elapsed time cannot re-authorize it.
        let late = await center.execute(
            BrowserCommand(sessionID: sessionA.sessionID, action: .observe(cursor: nil)),
            in: ownerA
        )
        #expect(late.status == .stale)
        #expect(center.session(for: ownerA) == nil)
        #expect(center.activeTaskSessionCount == 1)
        // The fence retained the generation; nothing moved it.
        #expect(center.generation(for: ownerA) == generationAtRelease)

        // The other owner is untouched.
        let stillB = try await run(registry, "browser.tabs", "{}", as: contextB)
        #expect(stillB.contains("\"status\":\"ok\""), Comment(rawValue: stillB))
    }

    @Test("Explicit UI restore and a newly admitted run reactivate with a fresh generation")
    func explicitRestoreAndNewOwnerRunReactivateWithNewGeneration() async throws {
        let center = makeCenter()
        let owner = UUID()
        center.bind(to: owner)
        let registry = makeRegistry(center)
        let first = try #require(center.session(for: owner))
        #expect(first.generation == center.generation(for: owner))

        center.discard(conversationID: owner)
        let fencedGeneration = center.generation(for: owner)

        // An explicit UI restore is trusted reactivation: a fresh session of
        // a new generation is created and tools work again.
        center.bind(to: owner)
        let restored = try #require(center.session(for: owner))
        #expect(restored !== first)
        #expect(restored.sessionID != first.sessionID)
        #expect(restored.generation > first.generation)
        #expect(restored.generation > fencedGeneration)
        let restoredContext = context(for: owner)
        let listed = try await run(registry, "browser.tabs", "{}", as: restoredContext)
        #expect(listed.contains("\"status\":\"ok\""), Comment(rawValue: listed))

        // A second release, then reactivation through runtime admission of a
        // NEW authorized run (recordOwnerRun) — not through the old callback.
        center.bind(to: nil)
        center.discard(conversationID: owner)
        let runAfterRestore = UUID()
        center.recordOwnerRun(conversationID: owner, runID: runAfterRestore)
        let readmitted = try await run(
            registry,
            "browser.tabs",
            "{}",
            as: context(for: owner, runID: runAfterRestore)
        )
        #expect(readmitted.contains("\"status\":\"ok\""), Comment(rawValue: readmitted))
        let second = try #require(center.session(for: owner))
        #expect(second !== restored)
        #expect(second.generation > restored.generation)
    }

    @Test("A cancelled late run is refused even after tombstone eviction; a fresh run is admitted")
    func cancelledLateCallbackRefusedEvenAfterFenceEviction() async throws {
        let center = makeCenter()
        let owner = UUID()
        center.bind(to: owner)
        let registry = makeRegistry(center)
        let token = CancellationToken()
        let lateContext = ToolContext(
            runID: UUID(),
            cancellation: token,
            conversationID: owner
        )
        _ = try await run(registry, "browser.tabs", "{}", as: lateContext)
        #expect(center.session(for: owner) != nil)

        // The task is released; the late run is cancelled by the runtime.
        center.discard(conversationID: owner)
        token.cancel()

        // Push the owner's tombstone out of the bounded registry: release
        // hundreds of unrelated owners. Pressure alone must not re-authorize
        // the deleted owner — cancellation is the remaining fence.
        for _ in 0..<600 {
            center.discard(conversationID: UUID())
        }

        do {
            _ = try await run(registry, "browser.tabs", "{}", as: lateContext)
            Issue.record("a cancelled late run must not reach or recreate a browser")
        } catch FloeError.cancelled {
            // Expected: refused by runtime cancellation before any session
            // creation, regardless of tombstone retention.
        }
        #expect(center.session(for: owner) == nil)

        // A genuinely new authorized run (fresh, live cancellation token) is
        // admitted and may create a fresh browser.
        let fresh = context(for: owner)
        let created = try await run(registry, "browser.tabs", "{}", as: fresh)
        #expect(created.contains("\"status\":\"ok\""), Comment(rawValue: created))
        #expect(center.session(for: owner) != nil)
    }

    @Test("Completions from an old generation cannot authorize work after reactivation")
    func oldGenerationCompletionsCannotAuthorizeNewWork() async throws {
        let center = makeCenter()
        let registry = makeRegistry(center)
        let owner = UUID()
        center.bind(to: owner)
        let old = try #require(center.session(for: owner))
        let tab = try #require(old.activeTabID)

        center.discard(conversationID: owner)
        center.bind(to: owner)
        let current = try #require(center.session(for: owner))
        #expect(current !== old)
        #expect(current.generation > old.generation)

        // The old session object itself refuses execution.
        let oldResult = await old.execute(
            BrowserCommand(sessionID: old.sessionID, action: .observe(cursor: nil))
        )
        #expect(oldResult.status == .stale)

        // A command minted for the old session/generation is stale against
        // the current session even though the owner is trusted again.
        let oldCommand = await center.execute(
            BrowserCommand(sessionID: old.sessionID, tabID: tab, action: .observe(cursor: nil)),
            in: owner
        )
        #expect(oldCommand.status == .stale)
        #expect(oldCommand.error?.code == "session")

        // A late host callback from the old session cannot initiate user
        // control or write a durable handoff for the new session.
        center.browserSessionRequestedUserControl(old, reason: "late callback")
        #expect(!current.isUserControlling)
        #expect(center.handoff(for: owner) == nil)

        // The current session's own takeover path still works, attributed to
        // the exact run that held control (never a guessed recent run).
        let currentRun = UUID()
        _ = try await run(
            registry, "browser.tabs", "{}", as: context(for: owner, runID: currentRun))
        #expect(current.currentModelRunID == currentRun)
        center.browserSessionRequestedUserControl(current, reason: "current")
        #expect(current.isUserControlling)
        #expect(center.handoff(for: owner)?.runID == currentRun)
    }

    // MARK: - Run-scoped browser control

    private func controlID(in summary: String) throws -> String {
        let value = try object(summary)
        let control = try #require(value["control"] as? [String: Any], "missing control marker")
        return try #require(control["id"] as? String)
    }

    @Test("First read acquires control before the page, survives calls, and release keeps the page")
    func modelControlIsAcquiredAtomicallyAndSurvivesCalls() async throws {
        let center = makeCenter()
        let owner = UUID()
        let runID = UUID()
        center.bind(to: owner)
        let registry = makeRegistry(center)
        let ctx = context(for: owner, runID: runID)

        // `browser.tabs` is the first call: the session, its first tab and
        // the holding period are established together, and the result names
        // the holder before any page read happened.
        let listing = try await run(registry, "browser.tabs", "{}", as: ctx)
        let listed = try page(listing)
        let session = try #require(center.session(for: owner))
        #expect(session.currentModelRunID == runID)
        #expect(session.hasModelControlHolder)
        let tabs = try #require(listed["tabs"] as? [[String: Any]])
        #expect(tabs.count == 1)
        let firstControl = try controlID(in: listing)

        let tab = try #require(session.activeTabID)
        try await load(fixturePage("control"), tab: tab, in: session, registry: registry, context: ctx)
        let page = try await observe(tab: tab, registry: registry, context: ctx)
        #expect(nodesText(page).contains("ready-control"))
        let held = try #require(session.modelControl)
        #expect(held.id.uuidString == firstControl)
        #expect(held.runID == runID)

        // The preview strip's label comes from this action's own document.
        let documentID = try #require(page["documentID"] as? String)
        let ref = try #require(try button(in: page)["ref"] as? String)
        _ = try await run(
            registry, "browser.click",
            "{\"tabID\":\"\(tab)\",\"ref\":\"\(ref)\",\"documentID\":\"\(documentID)\"}",
            as: ctx)
        #expect(session.lastModelActivity?.kind == .clicking)
        #expect(session.lastModelActivity?.detail == "Go control")

        // Another run is refused and cannot take this page.
        let otherRegistry = makeRegistry(center)
        await #expect(throws: (any Error).self) {
            _ = try await run(
                otherRegistry, "browser.observe", "{\"tabID\":\"\(tab)\"}",
                as: context(for: owner))
        }
        #expect(session.modelControl?.id.uuidString == firstControl)
        // A yield request from another run cannot hand over this page either.
        await #expect(throws: (any Error).self) {
            _ = try await run(
                registry, "browser.panel",
                "{\"action\":\"requestUser\",\"reason\":\"wrong run\"}",
                as: context(for: owner))
        }
        #expect(!session.isUserControlling)
        #expect(session.modelControl?.id.uuidString == firstControl)

        // Explicit release keeps the tab, URL, login state and page.
        let releasedURL = session.activeWebView?.url
        let released = try await run(
            registry, "browser.release", "{\"controlID\":\"\(firstControl)\"}", as: ctx)
        #expect(released.contains("released"), Comment(rawValue: released))
        #expect(!session.hasModelControlHolder)
        #expect(!session.isReleased)
        #expect(session.tabs.count == 1)
        #expect(session.activeTabID == tab)
        #expect(session.activeWebView?.url == releasedURL)

        // Repeating the release is a no-op.
        _ = try await run(
            registry, "browser.release", "{\"controlID\":\"\(firstControl)\"}", as: ctx)
        #expect(!session.hasModelControlHolder)

        // A later observation re-acquires; the old token cannot release it.
        let second = try await run(
            registry, "browser.observe", "{\"tabID\":\"\(tab)\"}", as: ctx)
        let secondControl = try controlID(in: second)
        #expect(secondControl != firstControl)
        _ = try await run(
            registry, "browser.release", "{\"controlID\":\"\(firstControl)\"}", as: ctx)
        #expect(session.modelControl?.id.uuidString == secondControl)
        _ = try await run(
            registry, "browser.release", "{\"controlID\":\"\(secondControl)\"}", as: ctx)
        #expect(!session.hasModelControlHolder)
    }

    @Test("Releasing control never creates a browser and is a no-op when none is open")
    func releaseDoesNotCreateBrowser() async throws {
        let center = makeCenter()
        let owner = UUID()
        center.bind(to: owner)
        let registry = makeRegistry(center)
        let ctx = context(for: owner, runID: UUID())
        // The bound session exists for viewing, but there is no holder and no
        // acquisition here: release must not create or navigate anything.
        center.discard(conversationID: owner)
        #expect(center.session(for: owner) == nil)
        let output = try await run(
            registry, "browser.release",
            "{\"controlID\":\"\(UUID().uuidString)\"}", as: ctx)
        #expect(output.contains("No task browser is open"), Comment(rawValue: output))
        #expect(center.session(for: owner) == nil)
    }

    @Test("The first page entry acquires the holder before reading or navigating", arguments: ["tabs", "observe", "navigate"])
    func firstPageEntryAcquiresHolder(_ entry: String) async throws {
        let center = makeCenter()
        let owner = UUID()
        let runID = UUID()
        let registry = makeRegistry(center)
        let ctx = context(for: owner, runID: runID)
        do {
            switch entry {
            case "tabs":
                _ = try await run(registry, "browser.tabs", "{}", as: ctx)
            case "observe":
                _ = try await run(registry, "browser.observe", "{}", as: ctx)
            default:
                _ = try await run(
                    registry, "browser.navigate",
                    "{\"url\":\"https://example.com/\"}", as: ctx)
            }
        } catch {
            // A blank/first page may legitimately fail its first observation.
            // Acquisition must still have happened before that attempt.
        }
        let session = try #require(center.session(for: owner))
        #expect(session.currentModelRunID == runID)
        #expect(session.hasModelControlHolder)
        #expect(session.tabs.count == 1)
    }

    @Test("User takeover withholds every page payload and notifies the actual holder run")
    func userTakeoverWithholdsPageAndNotifiesHolderRun() async throws {
        let center = makeCenter()
        let owner = UUID()
        let runID = UUID()
        center.bind(to: owner)
        let registry = makeRegistry(center)
        let ctx = context(for: owner, runID: runID)
        let session = try #require(center.session(for: owner))
        let tab = try #require(session.activeTabID)
        try await load(fixturePage("handover"), tab: tab, in: session, registry: registry, context: ctx)
        let before = try await observe(tab: tab, registry: registry, context: ctx)
        let beforeDocument = try #require(before["documentID"] as? String)
        let beforeControl = try #require(session.modelControl)

        // A newer run is admitted before the user takes over. The receipt
        // must still name the run that actually holds the page, never the
        // newest admitted run.
        let newerRun = UUID()
        center.recordOwnerRun(conversationID: owner, runID: newerRun)
        center.takeControl()
        #expect(session.isUserControlling)
        #expect(!session.hasModelControlHolder)
        #expect(session.lastModelActivity == nil)
        #expect(center.handoff(for: owner)?.runID == runID)
        #expect(center.handoff(for: owner)?.runID != newerRun)
        #expect(center.handoff(for: owner)?.sessionID == session.sessionID)
        #expect(center.handoff(for: owner)?.tabID == tab)
        #expect(beforeControl.runID == runID)

        for (name, arguments) in [
            ("browser.observe", "{\"tabID\":\"\(tab)\"}"),
            ("browser.text", "{\"tabID\":\"\(tab)\"}"),
            ("browser.links", "{\"tabID\":\"\(tab)\"}"),
            ("browser.table", "{\"tabID\":\"\(tab)\"}"),
            ("browser.events", "{\"tabID\":\"\(tab)\"}"),
            ("browser.screenshot", "{\"tabID\":\"\(tab)\"}"),
            ("browser.observe", "{\"tabID\":\"\(tab)\",\"profile\":\"design\"}")
        ] {
            let output = try await run(registry, name, arguments, as: ctx)
            #expect(output.contains("\"status\":\"needsUser\""), Comment(rawValue: name + ": " + output))
            #expect(!output.contains("\"page\""), Comment(rawValue: name))
            #expect(!output.contains("screenshotArtifact"), Comment(rawValue: name))
            #expect(!output.contains("ready-handover"), Comment(rawValue: name))
            #expect(!output.contains("Go handover"), Comment(rawValue: name))
            #expect(!output.contains("\"control\""), Comment(rawValue: name))
        }
        // Mutations are refused too, and the page is unchanged.
        let typed = try await run(
            registry, "browser.type",
            "{\"tabID\":\"\(tab)\",\"ref\":\"n1\",\"documentID\":\"stale\",\"text\":\"injected\"}",
            as: ctx)
        #expect(typed.contains("\"status\":\"needsUser\""), Comment(rawValue: typed))

        // The handback clears user control and invalidates the old document.
        center.deliverHandoff = { _, _ in false }
        await center.returnToAgent()
        #expect(!session.isUserControlling)
        #expect(!session.hasModelControlHolder)
        #expect(center.handoff?.returning == true)
        let returned = try await observe(tab: tab, registry: registry, context: ctx)
        #expect(returned["documentID"] as? String != beforeDocument)
        #expect(returned["control"] != nil)
        #expect(nodesText(returned).contains("ready-handover"))
    }

    @Test("User input on an idle browser stays local and creates no handoff receipt")
    func idleUserInputCreatesNoReceipt() async throws {
        let center = makeCenter()
        let owner = UUID()
        center.bind(to: owner)
        let session = try #require(center.session(for: owner))
        #expect(!session.hasModelControlHolder)
        session.registerUserInput()
        #expect(session.isUserControlling)
        #expect(center.handoff(for: owner) == nil)
        #expect(center.pendingPanelRequest(for: owner) == nil)
        await center.returnToAgent()
        #expect(!session.isUserControlling)
    }

    @Test("Human input before the model blocks AI insertion and preserves the field value")
    func humanInputFirstBlocksModelInsert() async throws {
        let center = makeCenter()
        let owner = UUID()
        let runID = UUID()
        center.bind(to: owner)
        let registry = makeRegistry(center)
        let ctx = context(for: owner, runID: runID)
        let session = try #require(center.session(for: owner))
        let tab = try #require(session.activeTabID)
        try await load(
            "<!doctype html><html><body><input id=\"field\" value=\"\"><p>form</p></body></html>",
            tab: tab, in: session, registry: registry, context: ctx)
        let page = try await observe(tab: tab, registry: registry, context: ctx)
        let documentID = try #require(page["documentID"] as? String)
        let field = try #require((page["nodes"] as? [[String: Any]])?
            .first(where: { ($0["role"] as? String) == "input" }))
        let ref = try #require(field["ref"] as? String)

        // First real keystroke/gesture: takeover happens before the model can
        // insert anything, and the exact holder run is notified.
        session.registerUserInput()
        #expect(session.isUserControlling)
        #expect(center.handoff(for: owner)?.runID == runID)
        let attempted = try await run(
            registry, "browser.type",
            "{\"tabID\":\"\(tab)\",\"ref\":\"\(ref)\",\"documentID\":\"\(documentID)\",\"text\":\"model-value\"}",
            as: ctx)
        #expect(attempted.contains("\"status\":\"needsUser\""), Comment(rawValue: attempted))
        let webView = try #require(session.activeWebView)
        let value = try await webView.evaluateJavaScript(
            "document.getElementById('field').value") as? String
        #expect(value == "")
        #expect(center.handoff(for: owner)?.runID == runID)
    }

    @Test("An in-flight read after takeover returns no content and defers human input until it settles")
    func inFlightReadIsWithheldOnTakeover() async throws {
        let center = makeCenter()
        let owner = UUID()
        let runID = UUID()
        center.bind(to: owner)
        let registry = makeRegistry(center)
        let ctx = context(for: owner, runID: runID)
        let session = try #require(center.session(for: owner))
        let tab = try #require(session.activeTabID)
        try await load(fixturePage("inflight"), tab: tab, in: session, registry: registry, context: ctx)
        let webView = try #require(session.activeWebView)
        #expect(webView.isUserInteractionEnabled)

        let waiting = Task {
            try await run(
                registry, "browser.wait",
                "{\"tabID\":\"\(tab)\",\"condition\":\"text\",\"value\":\"never-appears\",\"timeoutMilliseconds\":5000}",
                as: ctx)
        }
        // Let the real WebKit wait begin.
        for _ in 0..<50 where session.activeExecutionCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.activeExecutionCount > 0)
        center.takeControl()
        #expect(session.isUserControlling)
        #expect(session.takeoverPending)
        #expect(!webView.isUserInteractionEnabled)

        let output = try await waiting.value
        #expect(output.contains("\"status\":\"needsUser\""), Comment(rawValue: output))
        #expect(!output.contains("\"page\""))
        #expect(!output.contains("ready-inflight"))
        for _ in 0..<50 where session.takeoverPending {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!session.takeoverPending)
        #expect(webView.isUserInteractionEnabled)
        #expect(session.isUserControlling)
    }

    @Test("An in-flight click taken over is withheld, never replayed, and the page settles once")
    func inFlightClickTakenOverIsWithheldAndNeverReplayed() async throws {
        let center = makeCenter()
        let owner = UUID()
        let runID = UUID()
        center.bind(to: owner)
        let registry = makeRegistry(center)
        let ctx = context(for: owner, runID: runID)
        let session = try #require(center.session(for: owner))
        let tab = try #require(session.activeTabID)
        let html = "<!doctype html><html><body style=\"margin:0\">"
            + "<button id=\"go\" style=\"width:180px;height:60px\" "
            + "onclick=\"window.clickCount=(window.clickCount||0)+1; var end=Date.now()+1200; while(Date.now()<end){}; document.getElementById('status').textContent='clicked-once';\">Go</button>"
            + "<p id=\"status\">ready-click</p></body></html>"
        try await load(html, tab: tab, in: session, registry: registry, context: ctx)
        let page = try await observe(tab: tab, registry: registry, context: ctx)
        let documentID = try #require(page["documentID"] as? String)
        let ref = try #require(try button(in: page)["ref"] as? String)

        let clicking = Task {
            try await run(
                registry, "browser.click",
                "{\"tabID\":\"\(tab)\",\"ref\":\"\(ref)\",\"documentID\":\"\(documentID)\"}",
                as: ctx)
        }
        // Wait until the real WebKit click is dispatched, then take over.
        for _ in 0..<200 where session.activeExecutionCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        // The handler blocks the web process for 1.2s; taking over during
        // that window proves the already-dispatched click is not replayed.
        try await Task.sleep(for: .milliseconds(300))
        center.takeControl()
        #expect(session.isUserControlling)
        #expect(session.takeoverPending)

        let output = try await clicking.value
        #expect(output.contains("\"status\":\"needsUser\""), Comment(rawValue: output))
        #expect(!output.contains("clicked-once"))
        #expect(!output.contains("\"page\""))

        // The already-dispatched click cannot be undone; it must have landed
        // exactly once and the model result never claimed success.
        try await Task.sleep(for: .milliseconds(900))
        let webView = try #require(session.activeWebView)
        let count = try await webView.evaluateJavaScript("window.clickCount") as? NSNumber
        #expect(count?.intValue == 1)
        let status = try await webView.evaluateJavaScript(
            "document.getElementById('status').textContent") as? String
        #expect(status == "clicked-once")
        #expect(!session.takeoverPending)
        #expect(webView.isUserInteractionEnabled)
    }

    @Test("A run's terminal state releases only its own lease and never ends user control")
    func runEndReleasesLeaseAndKeepsPage() async throws {
        let center = makeCenter()
        let owner = UUID()
        let runID = UUID()
        center.bind(to: owner)
        let registry = makeRegistry(center)
        let ctx = context(for: owner, runID: runID)
        let session = try #require(center.session(for: owner))
        let tab = try #require(session.activeTabID)
        try await load(fixturePage("runend"), tab: tab, in: session, registry: registry, context: ctx)
        let page = try await observe(tab: tab, registry: registry, context: ctx)
        let lease = try #require(session.modelControl)
        let url = session.activeWebView?.url
        let documentID = try #require(page["documentID"] as? String)

        #expect(center.endModelControl(conversationID: owner, runID: UUID()) == false)
        #expect(session.modelControl == lease)
        #expect(center.endModelControl(conversationID: owner, runID: runID))
        #expect(!session.hasModelControlHolder)
        #expect(!session.isUserControlling)
        #expect(!session.isReleased)
        #expect(session.tabs.count == 1)
        #expect(session.activeWebView?.url == url)

        // A late completion carrying the ended lease is stale and returns no page.
        let late = await center.execute(
            BrowserCommand(
                sessionID: session.sessionID, tabID: tab,
                expectedDocumentID: documentID, action: .observe(cursor: nil)),
            in: owner, control: lease)
        #expect(late.status == .stale)
        #expect(late.error?.code == "control")
        #expect(late.page == nil)

        // A newer run may acquire the same page.
        _ = try await run(registry, "browser.tabs", "{}", as: context(for: owner, runID: UUID()))
        #expect(session.hasModelControlHolder)

        // A user takeover survives the holder run ending.
        center.takeControl()
        #expect(session.isUserControlling)
        #expect(center.endModelControl(conversationID: owner, runID: runID) == false)
        #expect(session.isUserControlling)
    }

    @Test("Repeated and stale release tokens never unlock a newer holding period")
    func staleReleaseCannotUnlockNewerHoldingPeriod() async throws {
        let center = makeCenter()
        let owner = UUID()
        let runID = UUID()
        center.bind(to: owner)
        let registry = makeRegistry(center)
        let ctx = context(for: owner, runID: runID)
        _ = try await run(registry, "browser.tabs", "{}", as: ctx)
        let session = try #require(center.session(for: owner))
        let first = try #require(session.modelControl)
        _ = try await run(
            registry, "browser.release", "{\"controlID\":\"\(first.id.uuidString)\"}", as: ctx)
        #expect(!session.hasModelControlHolder)
        let secondOutput = try await run(registry, "browser.observe", "{}", as: ctx)
        let second = try #require(session.modelControl)
        #expect(second.id != first.id)
        // The old token has no effect on the new period.
        let stale = try await run(
            registry, "browser.release", "{\"controlID\":\"\(first.id.uuidString)\"}", as: ctx)
        #expect(stale.contains("already released"), Comment(rawValue: stale))
        #expect(session.modelControl == second)
        #expect(secondOutput.contains(second.id.uuidString))
        // A different run cannot release it either.
        await #expect(throws: (any Error).self) {
            _ = try await run(
                registry, "browser.release", "{\"controlID\":\"\(second.id.uuidString)\"}",
                as: context(for: owner, runID: UUID()))
        }
        #expect(session.modelControl == second)
    }

    // MARK: - Original-run handoff attribution (repair)

    @Test("A delegated child's handoff stays on the original parent run, never the newest run")
    func childHandoffUsesOriginalParentRunNotNewest() async throws {
        let center = makeCenter()
        let owner = UUID()
        let parentRun = UUID()
        center.bind(to: owner)
        let registry = makeRegistry(center)

        let child = childContext(for: owner, parentRunID: parentRun)
        let panel = try await run(
            registry,
            "browser.panel",
            "{\"action\":\"requestUser\",\"reason\":\"Enter the code shown on the page\"}",
            as: child
        )
        #expect(panel.contains("The user controls this task's browser"), Comment(rawValue: panel))
        let receipt = try #require(center.handoff(for: owner))
        #expect(receipt.runID == parentRun)

        // A newer run of the same conversation is admitted before the user
        // returns. The pending receipt must NOT migrate to the newer run.
        let newerRun = UUID()
        center.recordOwnerRun(conversationID: owner, runID: newerRun)
        let secondChild = childContext(for: owner, parentRunID: parentRun, childID: UUID())
        _ = try await run(
            registry,
            "browser.panel",
            "{\"action\":\"requestUser\",\"reason\":\"Still waiting\"}",
            as: secondChild
        )
        let rerequested = try #require(center.handoff(for: owner))
        #expect(rerequested.id == receipt.id)
        #expect(rerequested.runID == parentRun)

        // Durable recovery consumes the exact original run only.
        // Recovery is valid only after the user returns control. Exercise
        // the real return transition with an undelivered outbox receipt.
        center.deliverHandoff = { _, _ in
            throw FloeError.validationFailed("synthetic return delivery failure")
        }
        await center.returnToAgent()
        let returning = try #require(center.handoff(for: owner))
        #expect(returning.returning)
        #expect(returning.id == receipt.id)
        #expect(center.session(for: owner)?.isUserControlling == true)

        var attempts: [BrowserSessionCenter.Handoff] = []
        center.deliverHandoff = { event, _ in
            attempts.append(event)
            return false
        }
        await center.recoverHandoff(conversationID: owner, runID: newerRun)
        #expect(attempts.isEmpty)
        await center.recoverHandoff(conversationID: owner, runID: parentRun)
        #expect(attempts.count == 1)
        #expect(attempts.first?.runID == parentRun)
    }

    @Test("A child handoff with a mismatched root task or nested depth is refused")
    func childIdentityForgeryIsRefused() async throws {
        let center = makeCenter()
        let owner = UUID()
        let otherTask = UUID()
        let parentRun = UUID()
        center.bind(to: owner)
        let registry = makeRegistry(center)

        // rootTaskID names a different conversation than the ToolContext.
        let wrongRoot = childContext(for: owner, parentRunID: parentRun, rootTaskID: otherTask)
        await #expect(throws: (any Error).self) {
            _ = try await run(
                registry,
                "browser.panel",
                "{\"action\":\"requestUser\",\"reason\":\"Forged root task\"}",
                as: wrongRoot
            )
        }
        // Canonical depth is 1; a nested identity is never minted and is
        // refused even inside the right task.
        let nested = childContext(for: owner, parentRunID: parentRun, depth: 2)
        await #expect(throws: (any Error).self) {
            _ = try await run(
                registry,
                "browser.panel",
                "{\"action\":\"requestUser\",\"reason\":\"Nested child\"}",
                as: nested
            )
        }
        #expect(center.handoff(for: owner) == nil)
        #expect(center.handoff(for: otherTask) == nil)
        #expect(center.session(for: owner)?.isUserControlling != true)
    }

    @Test("A main-run handoff uses the actual context run even after a newer run is admitted")
    func mainRunHandoffUsesActualContextRunID() async throws {
        let center = makeCenter()
        let owner = UUID()
        let mainRun = UUID()
        center.bind(to: owner)
        let registry = makeRegistry(center)
        let main = context(for: owner, runID: mainRun)

        _ = try await run(
            registry,
            "browser.panel",
            "{\"action\":\"requestUser\",\"reason\":\"Sign in\"}",
            as: main
        )
        let receipt = try #require(center.handoff(for: owner))
        #expect(receipt.runID == mainRun)

        // A newer run is admitted; the main run's own handoff never migrates.
        center.recordOwnerRun(conversationID: owner, runID: UUID())
        _ = try await run(
            registry,
            "browser.panel",
            "{\"action\":\"requestUser\",\"reason\":\"Still waiting\"}",
            as: main
        )
        #expect(center.handoff(for: owner)?.runID == mainRun)

        // Recovery is valid only after the user returns control. Exercise
        // the real return transition with an undelivered outbox receipt.
        center.deliverHandoff = { _, _ in
            throw FloeError.validationFailed("synthetic return delivery failure")
        }
        await center.returnToAgent()
        let returning = try #require(center.handoff(for: owner))
        #expect(returning.returning)
        #expect(returning.id == receipt.id)
        #expect(center.session(for: owner)?.isUserControlling == true)

        var attempts = 0
        center.deliverHandoff = { _, _ in
            attempts += 1
            return false
        }
        await center.recoverHandoff(conversationID: owner, runID: UUID())
        #expect(attempts == 0)
        await center.recoverHandoff(conversationID: owner, runID: mainRun)
        #expect(attempts == 1)
    }

    @Test("A real browser probe callback preserves its successful JSON receipt")
    func browserProbeCallbackPreservesSuccess() async throws {
        let data = try await BrowserProbeRequest().run(deadline: .now.advanced(by: .seconds(1))) {
            $0(.success(["ok": true]))
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Bool]
        #expect(object?["ok"] == true)
    }

    @Test("A missing native browser callback returns the real probe deadline failure")
    func missingBrowserProbeCallbackTimesOut() async throws {
        let request = BrowserProbeRequest()
        var callback: BrowserProbeRequest.Completion?
        await #expect(throws: BrowserProbeError.timedOut) {
            _ = try await request.run(deadline: .now.advanced(by: .milliseconds(250))) { callback = $0 }
        }
        #expect(callback != nil)
        // Native completions after the deadline are retired, never resumed
        // twice and never reported as a late successful browser operation.
        callback?(.success(["late": true]))
        callback?(.failure(CancellationError()))
    }

    @Test("A pending browser probe retires on cancellation or owner release", arguments: ["cancel", "release"])
    func pendingBrowserProbeRetires(_ boundary: String) async throws {
        let request = BrowserProbeRequest()
        let started = AsyncStream<Void>.makeStream()
        var callback: BrowserProbeRequest.Completion?
        let task = Task {
            try await request.run(deadline: .now.advanced(by: .seconds(30))) { completion in
                callback = completion
                started.continuation.yield(())
                started.continuation.finish()
            }
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        if boundary == "cancel" {
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        } else {
            request.invalidate()
            await #expect(throws: BrowserProbeError.released) { _ = try await task.value }
        }
        callback?(.success(["late": true]))
    }

    // MARK: - Real WebKit session-data bridge (isolated non-persistent store)

    @Test("Real WKWebView storage executes list/get/set/delete/clear and refuses a foreign origin")
    func storageBridgeRunsRealWebKitAndHonorsOrigin() async throws {
        let center = makeCenter()
        let owner = UUID()
        let (session, tab, store) = try isolatedSession(owner: owner, center: center)
        defer {
            session.release()
            try? FileManager.default.removeItem(at: session.artifactDirectory)
        }
        try await loadIsolated(storageFixturePage(), tab: tab, session: session)
        // The user's shared WebKit store and visible projection are never used.
        #expect(store !== WKWebsiteDataStore.default())
        #expect(session.websiteDataStore === store)
        #expect(session.tabLimit == 6)
        #expect(session.tabs.count == 1)
        #expect(center.session(for: owner) == nil)
        #expect(center.conversationID == nil)

        let bridge = BrowserWebDataBridge(session: session)
        let origin = "https://storage.example.test:443"
        // `location.origin` omits a default port; the native expected origin
        // must serialize the same way without weakening canonical matching.
        #expect(BrowserWebDataBridge.scriptOrigin(
            of: URL(string: "https://storage.example.test:443/fixture")!
        ) == "https://storage.example.test")
        #expect(BrowserWebDataBridge.scriptOrigin(
            of: URL(string: "https://storage.example.test:8443/fixture")!
        ) == "https://storage.example.test:8443")

        try await bridge.setStorage(
            tabID: tab, kind: .local, requestedOrigin: origin,
            key: "alpha", value: "hello"
        )
        try await bridge.setStorage(
            tabID: tab, kind: .local, requestedOrigin: origin,
            key: "beta", value: "wörld"
        )

        let metadata = try await bridge.storage(
            tabID: tab, kind: .local, requestedOrigin: origin, includeValues: false
        )
        #expect(metadata.origin == origin)
        #expect(metadata.totalKeys == 2)
        #expect(metadata.entries.allSatisfy { $0.value == nil })
        let betaMetadata = try #require(metadata.entries.first(where: { $0.key == "beta" }))
        #expect(betaMetadata.valueLength == "wörld".utf8.count)
        #expect(betaMetadata.valueLength == 6)

        let raw = try await bridge.storage(
            tabID: tab, kind: .local, requestedOrigin: origin, includeValues: true
        )
        #expect(raw.entries.first(where: { $0.key == "alpha" })?.value == "hello")
        #expect(raw.entries.first(where: { $0.key == "beta" })?.value == "wörld")

        // With no model-supplied origin, the trusted active-tab origin is
        // still passed to the script and reported.
        let defaultOriginPage = try await bridge.storage(
            tabID: tab, kind: .local, requestedOrigin: nil, includeValues: false
        )
        #expect(defaultOriginPage.origin == origin)
        #expect(defaultOriginPage.totalKeys == 2)

        #expect(try await bridge.storageValue(
            tabID: tab, kind: .local, requestedOrigin: origin, key: "alpha"
        ) == "hello")
        #expect(try await bridge.storageValue(
            tabID: tab, kind: .local, requestedOrigin: origin, key: "missing"
        ) == nil)

        // A model-supplied origin that does not match the tab is refused
        // before the fixed script can read or mutate anything.
        await #expect(throws: BrowserWebDataError.self) {
            _ = try await bridge.storage(
                tabID: tab, kind: .local,
                requestedOrigin: "https://other.example.test", includeValues: true
            )
        }
        await #expect(throws: BrowserWebDataError.self) {
            try await bridge.setStorage(
                tabID: tab, kind: .local,
                requestedOrigin: "https://other.example.test", key: "alpha", value: "overwritten"
            )
        }
        #expect(try await bridge.storageValue(
            tabID: tab, kind: .local, requestedOrigin: origin, key: "alpha"
        ) == "hello")

        try await bridge.deleteStorage(
            tabID: tab, kind: .local, requestedOrigin: origin, key: "alpha"
        )
        #expect(try await bridge.storageValue(
            tabID: tab, kind: .local, requestedOrigin: origin, key: "alpha"
        ) == nil)
        #expect(try await bridge.storage(
            tabID: tab, kind: .local, requestedOrigin: origin, includeValues: false
        ).totalKeys == 1)

        try await bridge.setStorage(
            tabID: tab, kind: .session, requestedOrigin: origin,
            key: "draft", value: "session-value"
        )
        let sessionRaw = try await bridge.storage(
            tabID: tab, kind: .session, requestedOrigin: origin, includeValues: true
        )
        #expect(sessionRaw.entries.first(where: { $0.key == "draft" })?.value == "session-value")
        try await bridge.clearStorage(tabID: tab, kind: .session, requestedOrigin: origin)
        #expect(try await bridge.storage(
            tabID: tab, kind: .session, requestedOrigin: origin, includeValues: false
        ).totalKeys == 0)

        // The raw-value boundary is a bridge invariant and does not require
        // the global advanced-provider preference.
        let snapshot = HTTPCookieSnapshot(
            name: "sid",
            value: "synthetic-secret",
            domain: "storage.example.test",
            path: "/",
            isSecure: true,
            isHTTPOnly: true,
            isSessionOnly: true,
            sameSite: "lax"
        )
        #expect(BrowserCookieRecord(snapshot: snapshot, includeValue: false).value == nil)
        #expect(BrowserCookieRecord(snapshot: snapshot, includeValue: false).valueLength
            == "synthetic-secret".utf8.count)
        #expect(BrowserCookieRecord(snapshot: snapshot, includeValue: true).value == "synthetic-secret")
    }

    @Test("Real WKWebView cookies keep HttpOnly attributes and expose raw values only on request")
    func cookieBridgeUsesRealWebKitHttpOnlyCookies() async throws {
        let center = makeCenter()
        let owner = UUID()
        let (session, tab, _) = try isolatedSession(owner: owner, center: center)
        defer {
            session.release()
            try? FileManager.default.removeItem(at: session.artifactDirectory)
        }
        try await loadIsolated(storageFixturePage(), tab: tab, session: session)
        let bridge = BrowserWebDataBridge(session: session)
        let input = HTTPCookieInput(
            name: "floe_fixture",
            value: "synthetic-cookie-value",
            domain: "storage.example.test",
            path: "/",
            secure: true,
            httpOnly: true,
            sameSite: "lax"
        )
        let written = try await bridge.setCookie(tabID: tab, input: input)
        #expect(written.value == nil)
        #expect(written.isHTTPOnly)
        #expect(written.isSecure)
        #expect(written.valueLength == input.value.utf8.count)

        let metadata = try await bridge.cookies(tabID: tab, includeValues: false)
        let metadataCookie = try #require(metadata.first(where: { $0.name == "floe_fixture" }))
        #expect(metadataCookie.value == nil)
        #expect(metadataCookie.isHTTPOnly)
        #expect(metadataCookie.valueLength == input.value.utf8.count)

        let raw = try await bridge.cookies(tabID: tab, includeValues: true)
        let rawCookie = try #require(raw.first(where: { $0.name == "floe_fixture" }))
        #expect(rawCookie.value == input.value)
        #expect(rawCookie.sameSite?.lowercased() == "lax")

        let deleted = try await bridge.deleteCookies(
            tabID: tab, name: "floe_fixture", domain: nil, path: nil
        )
        #expect(deleted == 1)
        let afterDelete = try await bridge.cookies(tabID: tab, includeValues: true)
        #expect(!afterDelete.contains(where: { $0.name == "floe_fixture" }))
    }

    @Test("A released task session refuses late storage and cookie work")
    func releasedSessionRefusesWebDataBridge() async throws {
        let center = makeCenter()
        let owner = UUID()
        let (session, tab, _) = try isolatedSession(owner: owner, center: center)
        defer {
            session.release()
            try? FileManager.default.removeItem(at: session.artifactDirectory)
        }
        try await loadIsolated(storageFixturePage(), tab: tab, session: session)
        let bridge = BrowserWebDataBridge(session: session)
        session.release()
        await #expect(throws: BrowserWebDataError.self) {
            _ = try await bridge.cookies(tabID: tab, includeValues: true)
        }
        await #expect(throws: BrowserWebDataError.self) {
            _ = try await bridge.storage(
                tabID: tab, kind: .local, requestedOrigin: nil, includeValues: true
            )
        }
        await #expect(throws: BrowserWebDataError.self) {
            try await bridge.setStorage(
                tabID: tab, kind: .local, requestedOrigin: nil, key: "late", value: "late"
            )
        }
    }

    @Test("Link, table and text readers run through the real protocol probe")
    func domReadersUseRealProtocolProbe() async throws {
        let center = makeCenter()
        let owner = UUID()
        let (session, tab, _) = try isolatedSession(owner: owner, center: center)
        defer {
            session.release()
            try? FileManager.default.removeItem(at: session.artifactDirectory)
        }
        try await loadIsolated(storageFixturePage(), tab: tab, session: session)

        let links = await session.execute(BrowserCommand(
            sessionID: session.sessionID,
            tabID: tab,
            action: .listLinks(cursor: nil, limit: 50)
        ))
        #expect(links.status == .ok, Comment(rawValue: links.message ?? "links failed"))
        let hrefs = (links.links ?? []).map(\.href)
        #expect(hrefs.contains("https://storage.example.test/next?from=fixture"))
        #expect(hrefs.contains("https://example.org/other"))

        let table = await session.execute(BrowserCommand(
            sessionID: session.sessionID,
            tabID: tab,
            action: .readTable(index: 0, cursor: nil, limit: 50)
        ))
        #expect(table.status == .ok, Comment(rawValue: table.message ?? "table failed"))
        let tablePage = try #require(table.table)
        #expect(tablePage.caption == "Synthetic prices")
        #expect(tablePage.headers == ["Item", "Cost"])
        #expect(tablePage.rows.contains(["Pen", "2"]))
        #expect(tablePage.totalRows == 2)

        let text = await session.execute(BrowserCommand(
            sessionID: session.sessionID,
            tabID: tab,
            action: .readText(start: 0, maxCharacters: 4_000)
        ))
        #expect(text.status == .ok, Comment(rawValue: text.message ?? "text failed"))
        #expect(try #require(text.textPage).text.contains("Alpha beta gamma."))
    }

}
#endif
