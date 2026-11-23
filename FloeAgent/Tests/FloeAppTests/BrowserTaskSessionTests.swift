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
import Network
import os
import Testing
import WebKit
import SwiftUI
import UIKit
import FloeCore
import FloeModels
import FloeTools
import FloeEnvironments
import FloeExecution
import FloeAgentRuntime
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

    @Test("Scroll advertises the actual bounded delta arguments")
    func scrollSchemaMatchesArguments() throws {
        _ = makeRegistry(makeCenter())
        let descriptor = try #require(ToolCatalog.descriptor(named: "browser.scroll"))
        let schema = try #require(JSONSerialization.jsonObject(with: Data(descriptor.parametersJSON.utf8)) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: [String: Any]])
        #expect(Set(properties.keys) == Set(["tabID", "deltaX", "deltaY"]))
        #expect(schema["required"] as? [String] == ["deltaY"])
        #expect(schema["additionalProperties"] as? Bool == false)
        for key in ["deltaX", "deltaY"] {
            let delta = try #require(properties[key])
            #expect(delta["type"] as? String == "number")
            #expect(delta["minimum"] as? Int == -20_000)
            #expect(delta["maximum"] as? Int == 20_000)
        }
    }

    @Test("Browser download resolves a Unicode workspace consistently and still rejects escape")
    func downloadAcceptsNormalizedWorkspaceBeforeTrustGate() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserDownload-\(UUID().uuidString)", isDirectory: true)
        let workspace = container.appendingPathComponent("资料-é", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let owner = UUID()
        let ctx = ToolContext(runID: UUID(), workspaceRootURL: workspace,
                              cancellation: CancellationToken(), conversationID: owner)
        let registry = makeRegistry(makeCenter())
        do {
            _ = try await run(registry, "browser.download",
                #"{"url":"https://example.com/fixture.png","path":"fixture.png"}"#, as: ctx)
            Issue.record("An unbound run must never bypass browser data authorization")
        } catch {
            let message = error.localizedDescription
            #expect(!message.contains("different workspace"), Comment(rawValue: message))
            #expect(message.contains("browser") || message.contains("Browser"), Comment(rawValue: message))
        }
        do {
            _ = try await run(registry, "browser.download",
                #"{"url":"https://example.com/fixture.png","path":"../escape.png"}"#, as: ctx)
            Issue.record("Download must reject an escape before authorization or network access")
        } catch {
            #expect(!error.localizedDescription.contains("Advanced browser features"))
        }
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
        center: BrowserSessionCenter,
        linkOpenBehavior: BrowserLinkOpenBehavior = .inApp,
        usesWideLayout: @escaping @MainActor (URL?) -> Bool = { _ in false },
        previewSnapshotTimeout: Duration = .seconds(2),
        previewSnapshot: @escaping BrowserPreviewSnapshot = { webView, configuration, finish in
            webView.takeSnapshot(with: configuration) { image, _ in finish(image) }
        },
        openSystemURL: @escaping @MainActor (URL) -> Void = { _ in
            Issue.record("This isolated browser unexpectedly opened an external link")
        }
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
                websiteDataStoreProvider: { store },
                linkOpenBehaviorProvider: { linkOpenBehavior },
                usesWideLayout: usesWideLayout
            ),
            host: center,
            previewSnapshotTimeout: previewSnapshotTimeout,
            previewSnapshot: previewSnapshot,
            openSystemURL: openSystemURL
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

    @Test("A cold receipt records the old page's end and cannot claim or unlock the replacement WebKit page")
    func coldHandoffNeverClaimsTheReplacementPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("handoffs.json"), owner = UUID(), run = UUID()
        var previous: BrowserSessionCenter? = BrowserSessionCenter(durableHandoffs: false, handoffStoreURL: url)
        previous?.bind(to: owner)
        previous?.takeControl(runID: run)
        let original = try #require(previous?.handoff)
        #expect(original.humanPresent && !original.returning)
        previous = nil
        let center = BrowserSessionCenter(durableHandoffs: false, handoffStoreURL: url)
        center.bind(to: owner)
        defer { center.discard(conversationID: owner) }
        let newSession = try #require(center.visibleSession)
        let lease = try center.beginModelControl(conversationID: owner, runID: run).lease
        let newPage = try #require(newSession.activeWebView)
        var closures: [UUID] = []
        center.deliverTakeover = { _ in Issue.record("Replayed an arrival in a destroyed session"); return true }
        center.deliverHandoff = { old, resume in
            #expect(old.closedAfterRestart == true && !old.humanPresent && !resume)
            closures.append(old.id)
            return false
        }
        await center.recoverHandoff(conversationID: owner, runID: UUID())
        #expect(closures.isEmpty)
        await center.recoverHandoff(conversationID: owner, runID: run)
        let persisted = try JSONDecoder().decode([BrowserSessionCenter.Handoff].self, from: Data(contentsOf: url))
        #expect(persisted.first?.closedAfterRestart == true && closures == [original.id])
        #expect(newSession.sessionID != original.sessionID && newSession.activeWebView === newPage)
        #expect(newSession.isModelControlCurrent(lease) && !newSession.isUserControlling && !newPage.isUserInteractionEnabled)
    }

    @Test("A delayed handback freezes its original tab and restores interaction after success or failure", arguments: [false, true])
    func handbackKeepsItsOriginalTabWhileDeliveryIsPending(fails: Bool) async throws {
        let center = makeCenter(), owner = UUID()
        center.bind(to: owner)
        defer { center.discard(conversationID: owner) }
        let session = try #require(center.visibleSession)
        let original = try #require(session.activeTabID), other = try #require(session.createTab())
        session.activate(original)
        let page = try #require(session.activeWebView)
        center.takeControl(runID: UUID())
        let receipt = try #require(center.handoff)
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let (unblock, release) = AsyncStream<Void>.makeStream()
        defer { release.finish(); signal.finish() }
        center.deliverHandoff = { _, _ in
            signal.yield(())
            for await _ in unblock { break }
            if fails { throw FloeError.validationFailed("Fixture delivery failed") }
            return false
        }
        let returning = Task { await center.returnControlIfCurrent(for: session, handoffID: receipt.id) }
        for await _ in entered { break }
        #expect(session.returningToModel && !page.isUserInteractionEnabled)
        session.activate(other)
        session.close(original)
        session.close(other)
        #expect(session.createTab() == nil && !session.registerUserInput())
        #expect(session.tabs.map(\.id) == [original, other] && session.activeWebView === page)
        release.yield(())
        #expect(await returning.value == !fails)
        #expect(session.activeTabID == original && session.activeWebView === page && page.isUserInteractionEnabled)
        #expect(session.isUserControlling == fails && !session.returningToModel)
    }

    @Test("Returning a browser preserves the parked checkpoint and a later terminal run, even for a legacy Continue request")
    func returningABrowserNeverResumesOrRewritesTheOriginalCheckpoint() async throws {
        let environment = AppEnvironment.preview(), center = environment.browserCenter
        let conversations = ConversationCenter(environment: environment)
        defer { withExtendedLifetime(conversations) {} }
        try await environment.database.migrate()
        let owner = UUID(), id = UUID()
        try await environment.conversationStore.saveConversation(.init(id: owner, title: "Return checkpoint", createdAt: Date(), updatedAt: Date()))
        try await environment.runStore.saveRun(.init(id: id, conversationID: owner, state: "checkpointed", goal: "Fixture",
            startedAt: Date(), conversationMode: "chat"))
        let checkpoint = AgentCheckpoint(runID: id, conversationID: owner, state: .checkpointed(.init(reason: "Waiting for the browser")),
            messages: [.init(role: "user", content: "Fixture")], conversationMode: .chat)
        try await environment.checkpointStore.save(checkpoint)
        let saved = try #require(try await environment.checkpointStore.load(runID: id))
        let parked = try #require(try await environment.runStore.run(id: id))
        center.bind(to: owner)
        defer { center.discard(conversationID: owner) }
        let session = try #require(center.visibleSession)
        center.takeControl(runID: id)
        let receipt = try #require(center.handoff)
        #expect(await center.returnControlIfCurrent(for: session, handoffID: receipt.id))
        await center.returnToAgent(continueTask: true)
        await center.recoverHandoff(conversationID: owner, runID: id)
        #expect(center.handoffNeedsContinue && !center.handoffNotified && center.handoffError == nil)
        #expect(try await environment.runStore.runs(conversationID: owner) == [parked])
        #expect(try await environment.checkpointStore.load(runID: id) == saved)
        try await environment.runStore.updateRunState(id: id, state: "completed", endedAt: Date())
        let completed = try #require(try await environment.runStore.run(id: id))
        await center.returnToAgent(continueTask: true)
        #expect(try await environment.runStore.runs(conversationID: owner) == [completed])
        #expect(try await environment.checkpointStore.load(runID: id) == saved)
        #expect(try await environment.runStore.errors(runID: id).isEmpty)
        let messages = try await environment.conversationStore.messages(conversationID: owner)
        #expect(messages.map(\.content) == [BrowserControlNotice.humanTookControl.message, BrowserControlNotice.returned.message])
        #expect(messages.allSatisfy { $0.role == "system" && $0.runID == id })
        #expect(try await environment.runningInputStore.pending(conversationID: owner).isEmpty)
    }

    @Test("A finished run keeps private-free browser receipts without queuing or launching another turn")
    func endedRunKeepsOnlyItsOwnBrowserNotices() async throws {
        let environment = AppEnvironment.preview()
        let conversations = ConversationCenter(environment: environment)
        defer { withExtendedLifetime(conversations) {} }
        try await environment.database.migrate()
        let center = environment.browserCenter
        let owner = UUID(), runID = UUID(), newerRun = UUID()
        try await environment.conversationStore.saveConversation(.init(id: owner, title: "Browser notices", createdAt: Date(), updatedAt: Date()))
        for id in [runID, newerRun] {
            try await environment.runStore.saveRun(.init(id: id, conversationID: owner, state: "completed",
                goal: "Fixture", startedAt: Date(), endedAt: Date()))
        }
        center.bind(to: owner)
        defer { center.discard(conversationID: owner) }
        let session = try #require(center.visibleSession)
        try center.requestUserInteraction(reason: "private-canary-797", tabID: nil, runID: runID, in: owner)
        let requested = try #require(center.handoff)
        await center.recoverHandoff(conversationID: owner, runID: runID)
        #expect(try await environment.conversationStore.messages(conversationID: owner).isEmpty)
        center.recordOwnerRun(conversationID: owner, runID: newerRun)
        #expect(session.registerUserInput())
        #expect(await center.returnControlIfCurrent(for: session, handoffID: requested.id, comment: "Use the second result"))
        await center.recoverHandoff(conversationID: owner, runID: newerRun)
        await center.recoverHandoff(conversationID: owner, runID: runID)
        let notices = try await environment.conversationStore.messages(conversationID: owner)
        let controls = notices.filter { $0.role == "system" }
        #expect(notices.filter { $0.role == "user" }.map(\.content) == ["Use the second result"])
        #expect(controls.map(\.content) == [BrowserControlNotice.humanTookControl.message, BrowserControlNotice.returned.message])
        #expect(notices.allSatisfy { $0.role != "assistant" && $0.runID == runID && !$0.content.contains("private-canary") })
        #expect(Set(notices.map(\.id)).count == 3)
        #expect(try await environment.runningInputStore.pending(conversationID: owner).isEmpty)
        let runs = try await environment.runStore.runs(conversationID: owner)
        #expect(Set(runs.map(\.id)) == [runID, newerRun] && runs.allSatisfy { $0.state == "completed" })
    }

    @Test("Only a real human arrival notifies the original run and a handback cannot close a different task")
    func humanArrivalAndHandbackAreDistinctOwnerBoundEvents() async throws {
        let center = makeCenter()
        let owner = UUID(), other = UUID(), run = UUID()
        center.bind(to: owner)
        defer { center.discard(conversationID: other); center.discard(conversationID: owner) }
        let session = try #require(center.visibleSession)
        var events: [UUID] = []
        center.deliverTakeover = { receipt in
            #expect(receipt.runID == run && receipt.conversationID == owner && receipt.sessionID == session.sessionID)
            events.append(try #require(receipt.takeoverEventID))
            return true
        }
        center.deliverHandoff = { receipt, continueTask in
            #expect(receipt.runID == run && !continueTask)
            events.append(receipt.id)
            return false
        }

        try center.requestUserInteraction(reason: "Synthetic private interaction", tabID: nil, runID: run, in: owner)
        let request = try #require(center.handoff)
        #expect(!request.humanPresent && session.isUserControlling)
        await center.recoverHandoff(conversationID: owner, runID: run)
        #expect(events.isEmpty)
        #expect(throws: (any Error).self) {
            try center.requestUserInteraction(reason: "Another run", tabID: nil, runID: UUID(), in: owner)
        }
        center.takeControl()
        let arrival = try #require(center.handoff?.takeoverEventID)
        #expect(arrival != request.id)
        let initialActivity = session.humanActivitySequence
        #expect(session.registerUserInput())
        #expect(session.registerUserInput())
        #expect(session.humanActivitySequence == initialActivity + 2)
        center.takeControl()
        await center.recoverHandoff(conversationID: owner, runID: run)
        #expect(events == [arrival])
        center.bind(to: other)
        #expect(!(await center.returnControlIfCurrent(for: session, handoffID: request.id)))
        #expect(session.isUserControlling)
        center.bind(to: owner)
        #expect(!(await center.returnControlIfCurrent(for: session, handoffID: UUID())))
        #expect(!(await center.returnControlIfCurrent(for: session, handoffID: request.id, presentationID: UUID())))
        #expect(await center.returnControlIfCurrent(for: session, handoffID: request.id))
        #expect(events == [arrival, request.id] && !session.isUserControlling)
        #expect(!(await center.returnControlIfCurrent(for: session, handoffID: request.id)))
        let next = try center.beginModelControl(conversationID: owner, runID: run).lease
        let document = try #require(session.activeTab?.documentID)
        await center.recoverHandoff(conversationID: owner, runID: run)
        await center.recoverHandoff()
        #expect(session.modelControl == next && session.isModelControlCurrent(next))
        #expect(session.activeTab?.documentID == document && session.usesFixedViewport)
        #expect(session.activeWebView?.isUserInteractionEnabled == false)
        _ = center.releaseModelControl(conversationID: owner, runID: run, controlID: next.id)
        #expect(session.registerUserInput())
        center.bind(to: other)
        center.bind(to: owner)
        await center.recoverHandoff(conversationID: owner, runID: run)
        #expect(session.isUserControlling && center.handoff == nil)
    }

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
        #expect(panel.contains("Human interaction was requested for this task's browser"), Comment(rawValue: panel))
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
        _ = try await run(registry, "browser.panel", "{\"action\":\"hide\"}", as: contextB)
        #expect(center.presentationRequest == requestBeforeHide)
        #expect(sessionA.isUserControlling)
        #expect(center.handoff(for: ownerA)?.runID == contextA.runID)

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

    private func awaitPreview(_ predicate: @MainActor () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate(), "The expected WebKit preview transition did not occur")
    }

    private let previewArticle = """
        <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
        <body style="margin:0;background:#164899">
        <article><h1>Spatial measurements</h1><p>An ordinary article explains this diagram in freely written prose.</p>
        <button style="margin:16px;padding:8px;background:white">30°</button></article></body>
        """

    private func acquirePreviewLease(_ session: BrowserTaskSession) throws -> BrowserControlLease {
        if case .acquired(let lease) = try session.acquireModelControl(runID: UUID()) { return lease }
        throw FloeError.validationFailed("The fixture's browser did not grant the test run control")
    }

    @Test("Wide legacy layout persists for exactly the opted-in HTTP origin")
    func wideLayoutIsOffByDefaultAndRestoresOnlyTheSelectedOrigin() throws {
        let key = "floe-wide-layout-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let settings = BrowserSettingsService(defaults: defaults)
        let site = try #require(URL(string: "https://LEGACY.example:443/test?fixture=one"))
        let same = try #require(URL(string: "https://legacy.example/another"))
        let otherPort = try #require(URL(string: "https://legacy.example:8443/"))
        #expect(!settings.usesWideLayout(for: site))
        settings.setWideLayout(true, for: site)
        let restored = BrowserSettingsService(defaults: defaults)
        #expect(restored.usesWideLayout(for: same) && !restored.usesWideLayout(for: otherPort))
        #expect(restored.wideLayoutOrigins == ["https://legacy.example"])
        #expect(restored.userAgent == settings.userAgent)
        restored.setWideLayout(false, for: same)
        #expect(!BrowserSettingsService(defaults: defaults).usesWideLayout(for: site))
    }

    @Test("One real page retains its layout, form and history until release or explicit takeover", arguments: [false, true])
    func fixedViewportRetainsPageWhenTheDisplayResizes(wide: Bool) async throws {
        let center = makeCenter()
        let (session, tab, _) = try isolatedSession(owner: UUID(), center: center, usesWideLayout: { _ in wide })
        defer { session.release(); try? FileManager.default.removeItem(at: session.artifactDirectory) }
        let web = try #require(session.activeWebView)
        let presenter = UIView(frame: CGRect(x: 0, y: 0, width: 480, height: 640))
        web.frame = presenter.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        presenter.addSubview(web)
        try await loadIsolated("""
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <input id="draft"><div style="height:2000px">Reading</div>
            """, tab: tab, session: session)
        _ = try await web.evaluateJavaScript("draft.value='Fixture draft'; history.pushState({},'', '#kept'); scrollTo(0,90); true")
        let policy = web.configuration.preferences.inactiveSchedulingPolicy
        let history = try await web.evaluateJavaScript("history.length") as? NSNumber
        let model = try acquirePreviewLease(session)
        let host = try #require(web.superview)
        let size = web.bounds.size
        #expect(session.usesFixedViewport && !web.isUserInteractionEnabled)
        #expect(web.configuration.preferences.inactiveSchedulingPolicy == .none)
        #expect(host !== presenter && size.width == (wide ? 1280 : 480))
        let first = await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: tab,
                                                        action: .observe(cursor: nil)), control: model)
        let firstPage = try #require(first.page)
        presenter.frame.size = CGSize(width: 850, height: 260)
        presenter.layoutIfNeeded()
        let second = await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: tab,
                                                         action: .observe(cursor: nil)), control: model)
        let secondPage = try #require(second.page)
        #expect(web.bounds.size == size && web.superview === host)
        #expect(firstPage.viewportWidth == secondPage.viewportWidth && firstPage.viewportHeight == secondPage.viewportHeight)
        #expect(firstPage.documentID == secondPage.documentID)
        if wide {
            session.beginUserTakeover(reason: "Fixture takeover")
        } else {
            #expect(session.releaseModelControl(controlID: model.id, runID: model.runID) == .released)
        }
        #expect(!session.usesFixedViewport && session.activeWebView === web && web.isUserInteractionEnabled)
        #expect(web.configuration.preferences.inactiveSchedulingPolicy == policy)
        presenter.addSubview(web)
        web.frame = presenter.bounds
        let draft = try await web.evaluateJavaScript("draft.value") as? String
        let finalHistory = try await web.evaluateJavaScript("history.length") as? NSNumber
        #expect(draft == "Fixture draft" && finalHistory == history && web.url?.fragment == "kept")
    }

    @Test("Distinct presentations transfer the original WebKit page and stale owners cannot detach it")
    func fixedViewportTransfersThePageBetweenPresentations() async throws {
        let center = makeCenter()
        let (session, id, _) = try isolatedSession(owner: UUID(), center: center)
        defer { session.release(); try? FileManager.default.removeItem(at: session.artifactDirectory) }
        try await loadIsolated(previewArticle, tab: id, session: session)
        let tab = try #require(session.activeTab)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let left = UIWindow(windowScene: scene)
        let right = UIWindow(windowScene: scene)
        func mount(in window: UIWindow, readOnly: Bool, priority: Int) -> BrowserPageMount {
            let mount = BrowserPageMount(frame: CGRect(x: 0, y: 0, width: 500, height: 550))
            window.addSubview(mount)
            mount.configure(tab: tab, id: UUID(), readOnly: readOnly, priority: priority, active: true)
            return mount
        }
        let original = mount(in: left, readOnly: false, priority: 0)
        let waiting = mount(in: right, readOnly: false, priority: 0)
        #expect(original.ownsPage && !waiting.ownsPage && tab.webView.superview === original)
        let lease = try acquirePreviewLease(session)
        let fixedBounds = tab.webView.bounds
        let host = try #require(tab.webView.superview)
        let spectator = mount(in: left, readOnly: true, priority: 1)
        let larger = mount(in: right, readOnly: true, priority: 2)
        #expect(host.superview === larger && !spectator.ownsPage && !original.ownsPage)
        #expect(!tab.webView.isUserInteractionEnabled && tab.webView.accessibilityElementsHidden)
        larger.transform = CGAffineTransform(scaleX: 1.7, y: 1.7)
        #expect(tab.webView.bounds == fixedBounds && !host.isUserInteractionEnabled)
        larger.removeFromSuperview()
        #expect(host.superview === spectator)
        larger.detach()
        #expect(host.superview === spectator && tab.webView.superview === host)
        tab.viewport.preferPresentation(waiting.presentationID)
        #expect(session.releaseModelControl(controlID: lease.id, runID: lease.runID) == .released)
        #expect(waiting.ownsPage && tab.webView.superview === waiting && tab.webView.isUserInteractionEnabled)
        #expect(!tab.webView.accessibilityElementsHidden && !spectator.ownsPage)
        original.detach()
        spectator.detach()
        #expect(tab.webView.superview === waiting)
    }

    @Test("A hung native tool screenshot drains on takeover and its late callback cannot issue a second frame")
    func toolSnapshotDeadlineDrainsTakeoverAndFencesLateFrame() async throws {
        let center = makeCenter()
        var calls = 0
        var first: (@MainActor (UIImage?) -> Void)?
        let (session, tab, _) = try isolatedSession(owner: UUID(), center: center, previewSnapshotTimeout: .milliseconds(400),
            previewSnapshot: { _, _, completion in calls += 1; first = completion })
        defer { session.release(); try? FileManager.default.removeItem(at: session.artifactDirectory) }
        try await loadIsolated(previewArticle, tab: tab, session: session)
        let lease = try acquirePreviewLease(session)
        let command = BrowserCommand(sessionID: session.sessionID, tabID: tab, action: .screenshot)
        let pending = Task { @MainActor in await session.execute(command, control: lease) }
        try await awaitPreview { first != nil }
        session.beginUserTakeover(reason: "Fixture explicit takeover")
        #expect(session.takeoverPending && session.usesFixedViewport)
        let denied = await pending.value
        #expect(denied.status == .needsUser && denied.page == nil)
        #expect(!session.takeoverPending && !session.usesFixedViewport)
        session.endUserControl()
        let next = try acquirePreviewLease(session)
        let noOverlap = await session.execute(command, control: next)
        #expect(noOverlap.status == .timeout && calls == 1)
        first?(UIImage())
        #expect(session.modelControl == next && session.livePreviewFrame == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: session.artifactDirectory.path).isEmpty)
    }

    @Test("Scrolling during the native capture discards both the stale receipt and the image file")
    func modelSnapshotRejectsScrollDuringCapture() async throws {
        let center = makeCenter()
        var captured = false
        let (session, tab, _) = try isolatedSession(owner: UUID(), center: center, previewSnapshot: { web, configuration, finish in
            Task { @MainActor in
                _ = try? await web.evaluateJavaScript("window.scrollTo(0,150); true")
                web.takeSnapshot(with: configuration) { image, _ in captured = image != nil; finish(image) }
            }
        })
        defer { session.release(); try? FileManager.default.removeItem(at: session.artifactDirectory) }
        try await loadIsolated("<meta name='viewport' content='width=device-width,initial-scale=1'><body style='height:3000px'>Scroll fixture</body>", tab: tab, session: session)
        let lease = try acquirePreviewLease(session)
        let result = await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: tab, action: .screenshot), control: lease)
        #expect(captured && result.status == .stale && result.page == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: session.artifactDirectory.path).isEmpty)
    }

    @Test("Old screenshots cannot dispatch after scrolling, and an input already sent is never replayed")
    func viewportDriftRejectsOldPixelsAndNeverReplaysDispatchedClick() async throws {
        let center = makeCenter()
        let (session, tab, _) = try isolatedSession(owner: UUID(), center: center)
        defer { session.release(); try? FileManager.default.removeItem(at: session.artifactDirectory) }
        try await loadIsolated("""
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <body style="margin:0"><canvas id="pad" style="position:fixed;inset:0;width:100%;height:100%" width="400" height="400"></canvas>
            <div style="height:3000px"></div><script>
            window.presses=0; pad.onclick=()=>{ window.presses++; scrollTo(0,window.scrollY+100); };
            </script></body>
            """, tab: tab, session: session)
        let model = try acquirePreviewLease(session)
        let web = try #require(session.activeWebView)
        func screenshot() async throws -> (BrowserArtifactReference, String) {
            let result = await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: tab, action: .screenshot), control: model)
            let page = try #require(result.page)
            return (try #require(page.screenshotArtifact), page.documentID)
        }
        func click(_ image: BrowserArtifactReference, _ document: String) async -> BrowserResult {
            await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: tab, expectedDocumentID: document,
                visualEvidenceSHA256: image.sha256, visualFallbackReason: "noStructuredTarget",
                action: .click(.point(x: Double(image.pixelWidth) / 2, y: Double(image.pixelHeight) / 2))), control: model)
        }
        let first = try await screenshot()
        let original = try #require(session.activeTab?.visualFallbackEvidence?.geometry)
        _ = try await web.evaluateJavaScript("scrollTo(0,150); true")
        let stale = await click(first.0, first.1)
        #expect(stale.status == .stale)
        let before = try await web.evaluateJavaScript("window.presses") as? NSNumber
        #expect(before?.intValue == 0)

        // scrollTo changes the DOM offset before WebKit delivers its scroll event and UIKit viewport update.
        // Start the next independent capture only after both coordinate spaces stop changing.
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        var lastDOM: BrowserPageGeometry?
        var lastNative: ImpeccableNativeViewSample?
        var stableSince = ContinuousClock.now
        var settled = false
        while ContinuousClock.now < deadline {
            let data = try await BrowserProbeRequest().run(deadline: deadline) { completion in
                web.callAsyncJavaScript("return globalThis.__floeProtocol.geometry();",
                    arguments: [:], in: nil, in: session.contentWorld, completionHandler: completion)
            }
            let dom = try JSONDecoder().decode(BrowserPageGeometry.self, from: data)
            let native = ImpeccableNativeViewSample.current(of: web.scrollView)
            if dom != lastDOM || native != lastNative { stableSince = .now }
            lastDOM = dom
            lastNative = native
            if dom.page == original.page, dom.epoch > original.epoch, abs(dom.scrollY - 150) < 1,
               abs(dom.pageTop - dom.top - dom.scrollY) < 1, stableSince.duration(to: .now) >= .milliseconds(120) {
                settled = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(settled, Comment(rawValue: "Scroll did not settle before capture: DOM \(String(describing: lastDOM)), native \(String(describing: lastNative))"))
        let fresh = try await screenshot()
        let once = await click(fresh.0, fresh.1)
        #expect(once.error?.code == "dispatched-unconfirmed")
        let after = try await web.evaluateJavaScript("window.presses") as? NSNumber
        #expect(after?.intValue == 1)
    }

    @Test("A semantic ref can move without changing its control but cannot act on a repurposed button")
    func semanticRefSurvivesLayoutAndRefusesRepurposedControl() async throws {
        let center = makeCenter()
        let (session, tab, _) = try isolatedSession(owner: UUID(), center: center)
        defer { session.release(); try? FileManager.default.removeItem(at: session.artifactDirectory) }
        try await loadIsolated("""
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <button id="control" onclick="window.presses++">Original control</button><script>window.presses=0;</script>
            """, tab: tab, session: session)
        let model = try acquirePreviewLease(session)
        let web = try #require(session.activeWebView)
        let response = await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: tab, action: .observe(cursor:nil)), control: model)
        let page = try #require(response.page)
        let button = try #require(page.nodes.first { $0.role == "button" })
        let command = BrowserCommand(sessionID: session.sessionID, tabID: tab, expectedDocumentID: page.documentID,
                                     action: .click(.element(ref: button.ref, documentID: page.documentID)))
        _ = try await web.evaluateJavaScript("control.style.marginLeft='100px';true")
        let moved = await session.execute(command, control: model)
        #expect(moved.status == .ok)
        _ = try await web.evaluateJavaScript("control.textContent='Different control';true")
        let changed = await session.execute(command, control: model)
        #expect(changed.status == .stale)
        let count = try await web.evaluateJavaScript("window.presses") as? NSNumber
        #expect(count?.intValue == 1)
    }

    @Test("The active task's real viewport and clicked control appear only in memory while watched")
    func livePreviewShowsArticlePixelsAndConfirmedClickOnlyWhileObserved() async throws {
        let center = makeCenter()
        var captures = 0
        let (session, tab, _) = try isolatedSession(owner: UUID(), center: center, previewSnapshot: { view, configuration, finish in
            captures += 1
            view.takeSnapshot(with: configuration) { image, _ in finish(image) }
        })
        defer { session.release(); try? FileManager.default.removeItem(at: session.artifactDirectory) }
        try await loadIsolated(previewArticle, tab: tab, session: session)
        let lease = try acquirePreviewLease(session)
        let observed = await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: tab, action: .observe(cursor: nil)), control: lease)
        let page = try #require(observed.page)
        let button = try #require(page.nodes.first(where: { $0.role == "button" }))
        let clicked = await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: tab,
            action: .click(.element(ref: button.ref, documentID: page.documentID))), control: lease)
        #expect(clicked.status == .ok)
        #expect(session.livePreviewFrame == nil)
        let watcher = UUID()
        session.setLivePreviewObservation(watcher, visible: true)
        guard #available(iOS 27.0, *) else {
            await session.waitForCurrentPreviewUpdate()
            #expect(captures == 0 && session.livePreviewFrame == nil && session.lastModelActivity?.kind == .clicking)
            #expect(try FileManager.default.contentsOfDirectory(atPath: session.artifactDirectory.path).isEmpty)
            session.beginUserTakeover(reason: "Fixture user input")
            #expect(session.livePreviewFrame == nil && session.isUserControlling)
            return
        }
        try await awaitPreview { session.livePreviewFrame?.clickedLabel == "30°" }
        #expect(captures == 1)
        let frame = try #require(session.livePreviewFrame)
        let pixels = try #require(frame.image.cgImage)
        let marked = try #require(frame.normalizedTarget)
        #expect(pixels.width > 120 && pixels.width <= 720 && pixels.height > 100)
        #expect(marked.width > 0 && marked.width < 0.45 && marked.height < 0.45)
        let sample = try #require(pixels.cropping(to: CGRect(x: pixels.width / 2, y: pixels.height / 2, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        #expect(Int(rgba[2]) > Int(rgba[0]) + 60 && rgba[3] == 255)
        #expect(try FileManager.default.contentsOfDirectory(atPath: session.artifactDirectory.path).isEmpty)
        session.setLivePreviewObservation(watcher, visible: false)
        #expect(session.livePreviewFrame == nil && session.modelControl == lease)
        session.setLivePreviewObservation(watcher, visible: true)
        try await awaitPreview { session.livePreviewFrame != nil }
        let webView = try #require(session.activeWebView)
        _ = try await webView.evaluateJavaScript("document.body.appendChild(Object.assign(document.createElement('input'), {type:'password'})) !== null")
        try await awaitPreview { session.livePreviewFrame == nil }
        session.beginUserTakeover(reason: "Fixture user input")
        #expect(session.livePreviewFrame == nil && !session.isModelActive)
        #expect(session.activeWebView === webView)
    }

    @Test("Private forms, opaque content and private action labels never reach a passive screenshot", arguments: [
        "<input type='password'>", "<input autocomplete='one-time-code'>", "<textarea>private fixture</textarea>",
        "<input value='private fixture'>", "<iframe srcdoc='<input>'></iframe>",
        "<div id='opaque' style='width:120px;height:40px'>Harmless light DOM <b>fallback</b></div><script>opaque.attachShadow({mode:'closed'}).innerHTML='<input type=password>'</script>",
        "<private-widget>Public fallback</private-widget><script>document.querySelector('private-widget').attachShadow({mode:'closed'}).innerHTML='<input type=password>'</script>"
    ])
    func livePreviewWithholdsPrivateSurfacesAndLabels(_ markup: String) async throws {
        let center = makeCenter()
        var captures = 0
        let (session, tab, _) = try isolatedSession(owner: UUID(), center: center, previewSnapshot: { _, _, finish in
            captures += 1
            finish(nil)
        })
        defer { session.release(); try? FileManager.default.removeItem(at: session.artifactDirectory) }
        try await loadIsolated("<meta name='viewport' content='width=device-width,initial-scale=1'><body><button>Private Client Case</button>" + markup + "</body>", tab: tab, session: session)
        let lease = try acquirePreviewLease(session)
        session.setLivePreviewObservation(UUID(), visible: true)
        let observed = await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: tab, action: .observe(cursor: nil)), control: lease)
        let page = try #require(observed.page)
        let button = try #require(page.nodes.first(where: { $0.role == "button" }))
        let click = BrowserCommand(sessionID: session.sessionID, tabID: tab,
                                   action: .click(.element(ref: button.ref, documentID: page.documentID)))
        let clicked = await session.execute(click, control: lease)
        #expect(clicked.status == .ok)
        await session.waitForCurrentPreviewUpdate()
        let webView = try #require(session.activeWebView)
        if markup.contains("attachShadow") {
            let exposed = try await webView.callAsyncJavaScript(
                "return Array.from(document.querySelectorAll('*')).some(el => !!el.shadowRoot);",
                arguments: [:], in: nil, contentWorld: session.contentWorld)
            #expect(exposed as? Bool == false)
        }
        #expect(captures == 0 && session.livePreviewFrame == nil && session.lastModelActivity?.kind == .clicking)
        #expect(try FileManager.default.contentsOfDirectory(atPath: session.artifactDirectory.path).isEmpty)
    }

    @Test("A hanging snapshot never overlaps on its page or blocks another task tab; late pixels are withheld")
    func livePreviewTimeoutFencesDelayedImageAndRecoversOnAnotherTab() async throws {
        let center = makeCenter()
        var waiting: (@MainActor (UIImage?) -> Void)?
        var dispatched: [ObjectIdentifier] = []
        let (session, first, _) = try isolatedSession(owner: UUID(), center: center,
            previewSnapshotTimeout: .milliseconds(90), previewSnapshot: { view, config, finish in
                dispatched.append(ObjectIdentifier(view))
                if dispatched.count == 1 { waiting = finish } else { finish(UIImage(systemName: "rectangle")) }
            })
        defer { session.release(); try? FileManager.default.removeItem(at: session.artifactDirectory) }
        try await loadIsolated(previewArticle, tab: first, session: session)
        let second = try #require(session.createTab())
        try await loadIsolated(previewArticle, tab: second, session: session)
        session.activate(first)
        let lease = try acquirePreviewLease(session)
        session.setLivePreviewObservation(UUID(), visible: true)
        _ = await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: first, action: .observe(cursor: nil)), control: lease)
        guard #available(iOS 27.0, *) else {
            await session.waitForCurrentPreviewUpdate()
            #expect(dispatched.isEmpty && waiting == nil && session.livePreviewFrame == nil)
            session.activate(second)
            let secondResult = await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: second,
                action: .observe(cursor: nil)), control: lease)
            await session.waitForCurrentPreviewUpdate()
            #expect(secondResult.status == .ok && session.lastModelActivity?.kind == .observing)
            #expect(dispatched.isEmpty && waiting == nil && session.livePreviewFrame == nil)
            return
        }
        try await awaitPreview { waiting != nil }
        try await Task.sleep(for: .milliseconds(140))
        _ = await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: first, action: .observe(cursor: nil)), control: lease)
        #expect(session.livePreviewFrame == nil)
        session.activate(second)
        _ = await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: second, action: .observe(cursor: nil)), control: lease)
        try await awaitPreview { session.livePreviewFrame != nil }
        let fresh = try #require(session.livePreviewFrame?.image)
        waiting?(UIImage())
        #expect(dispatched.count == 2 && Set(dispatched).count == 2)
        #expect(session.livePreviewFrame?.image === fresh)
    }

    @Test("Takeover requires the displayed task, document and route, and stale sheet dismissals leave the new presentation open")
    func livePreviewInteractionPinsDocumentRouteAndPresentation() async throws {
        let center = makeCenter()
        center.deliverHandoff = { _, _ in false }
        let owner = UUID()
        center.bind(to: owner)
        defer { center.discard(conversationID: owner) }
        let session = try #require(center.visibleSession)
        let tab = try #require(session.activeTabID)
        try await loadIsolated(previewArticle, tab: tab, session: session)
        let lease = try acquirePreviewLease(session)
        let old = try #require(session.previewPageIdentity)
        let webView = try #require(session.activeWebView)
        _ = try await webView.evaluateJavaScript("history.pushState({}, '', '#detail'); true")
        try await awaitPreview { session.previewPageIdentity != old }
        #expect(!center.openPreviewInteraction(session: session, page: old, displayedLease: lease, presentationID: UUID()))
        #expect(session.modelControl == lease)
        let first = UUID()
        #expect(center.openPreviewInteraction(session: session, page: session.previewPageIdentity, displayedLease: lease, presentationID: first))
        center.closePreviewInteraction(first)
        #expect(session.isUserControlling && session.activeWebView === webView)
        let second = UUID()
        #expect(center.openPreviewInteraction(session: session, page: session.previewPageIdentity, displayedLease: nil, presentationID: second))
        center.closePreviewInteraction(first)
        #expect(center.previewInteractionID == second)
        center.closePreviewInteraction(second)
        await center.returnToAgent()
        try center.requestPanelDismissal(conversationID: owner)
        #expect(center.presentationRequest?.show != false && center.visibleSession === session)
    }

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
        let watcher = UUID()
        session.setLivePreviewObservation(watcher, visible: true)
        defer { session.setLivePreviewObservation(watcher, visible: false) }
        _ = try await run(
            registry, "browser.click",
            "{\"tabID\":\"\(tab)\",\"ref\":\"\(ref)\",\"documentID\":\"\(documentID)\"}",
            as: ctx)
        #expect(session.lastModelActivity?.kind == .clicking)
        if #available(iOS 27.0, *) {
            try await awaitPreview { session.livePreviewFrame?.clickedLabel == "Go control" }
        } else {
            await session.waitForCurrentPreviewUpdate()
            #expect(session.livePreviewFrame == nil && session.modelControl == held)
        }

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
        let summary = try await run(registry, "browser.observe", "{\"tabID\":\"\(tab)\"}", as: ctx)
        let returnedPage = try page(summary)
        let returnedControl = try #require(try object(summary)["control"] as? [String: String])
        let currentControl = try #require(session.modelControl)
        let documentID = try #require(returnedPage["documentID"] as? String)
        #expect(documentID != beforeDocument)
        #expect(currentControl.runID == runID)
        #expect(currentControl.id != beforeControl.id)
        #expect(returnedControl["id"] == currentControl.id.uuidString)
        #expect(returnedControl["releaseTool"] == "browser.release")
        #expect(nodesText(returnedPage).contains("ready-handover"))
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
        #expect(session.hasModelControlHolder && !webView.isUserInteractionEnabled)

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
        // The failure overlay and toolbar share this real reload path. It asks
        // for control first and leaves the current page alone while WebKit drains.
        #expect(!session.reloadFromUser())
        #expect(session.isUserControlling)
        #expect(session.takeoverPending)
        #expect(!webView.isUserInteractionEnabled)
        #expect(center.handoff(for: owner)?.runID == runID)
        session.finishTakeoverIfIdle()
        await center.returnToAgent()
        #expect(session.takeoverPending)
        #expect(session.isUserControlling)
        #expect(!session.registerUserInput())
        #expect(session.activeTabID == tab && session.activeWebView === webView)

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
        #expect(session.registerUserInput())
    }

    @Test("During handback, delayed links and popup callbacks cannot navigate or leave the app", arguments: BrowserLinkOpenBehavior.allCases)
    func lateLinksDuringHandbackCannotNavigateOrOpenAnotherWindow(behavior: BrowserLinkOpenBehavior) throws {
        let center = makeCenter()
        var opened: [URL] = []
        let (session, tab, _) = try isolatedSession(owner: UUID(), center: center, linkOpenBehavior: behavior,
            openSystemURL: { opened.append($0) })
        defer {
            session.release()
            try? FileManager.default.removeItem(at: session.artifactDirectory)
        }
        let page = try #require(session.activeWebView)
        let destination = try #require(URL(string: "https://example.test/deferred"))
        let blank = try #require(URL(string: "about:blank"))
        session.beginUserTakeover(reason: nil)
        session.returningToModel = true
        #expect(session.navigationPolicy(for: destination, type: .linkActivated, from: page) == .cancel)
        #expect(session.navigationPolicy(for: blank, type: .linkActivated, from: page) == .cancel)
        #expect(session.openRequestedWindow(for: URLRequest(url: destination), from: page, configuration: page.configuration) == nil)
        #expect(session.openRequestedWindow(for: nil, from: page, configuration: page.configuration) == nil)
        #expect(session.navigationPolicy(for: destination, type: .other, from: page) == .allow)
        #expect(opened.isEmpty && session.tabs.count == 1 && session.activeTabID == tab && session.activeWebView === page)
    }

    @Test("Deferred links and new windows open externally only for the settled user's current tab")
    func deferredSystemLinksRequireSettledControlOfTheActiveTab() async throws {
        let center = makeCenter()
        var opened: [URL] = []
        let (session, tab, _) = try isolatedSession(
            owner: UUID(), center: center, linkOpenBehavior: .systemBrowser,
            openSystemURL: { opened.append($0) })
        defer {
            session.release()
            try? FileManager.default.removeItem(at: session.artifactDirectory)
        }
        let webView = try #require(session.activeWebView)
        _ = try #require(session.createTab())
        let background = try #require(session.activeWebView)
        session.activate(tab)
        try await loadIsolated("<html><body><input id='draft' value='keep this draft'></body></html>",
                               tab: tab, session: session)
        let originalURL = webView.url
        let link = try #require(URL(string: "https://example.test/link"))
        let popup = try #require(URL(string: "https://example.test/popup"))
        guard case .acquired(let lease) = try session.acquireModelControl(runID: UUID()) else {
            Issue.record("The offline fixture did not acquire model control")
            return
        }
        #expect(session.navigationPolicy(for: link, type: .linkActivated, from: webView) == .allow)
        #expect(opened.isEmpty)

        let command = BrowserCommand(sessionID: session.sessionID, tabID: tab, timeoutMilliseconds: 5_000,
                                     action: .wait(.text("never-appears")))
        let waiting = Task { await session.execute(command, control: lease) }
        defer { waiting.cancel() }
        for _ in 0..<100 where session.activeExecutionCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(session.activeExecutionCount > 0)
        session.beginUserTakeover(reason: "Read the draft")
        try #require(session.takeoverPending)

        #expect(session.navigationPolicy(for: link, type: .linkActivated, from: webView) == .cancel)
        #expect(session.openRequestedWindow(for: URLRequest(url: popup), from: webView, configuration: webView.configuration) == nil)
        #expect(opened.isEmpty)
        #expect(session.tabs.count == 2 && session.activeTabID == tab && session.activeWebView === webView)
        let completion = await waiting.value
        #expect(completion.status == .needsUser)
        try #require(!session.takeoverPending && session.isUserControlling)
        #expect(session.navigationPolicy(for: link, type: .linkActivated, from: background) == .cancel)
        #expect(session.openRequestedWindow(for: URLRequest(url: popup), from: background, configuration: background.configuration) == nil)
        #expect(opened.isEmpty)
        #expect(session.navigationPolicy(for: link, type: .linkActivated, from: webView) == .cancel)
        #expect(session.openRequestedWindow(for: URLRequest(url: popup), from: webView, configuration: webView.configuration) == nil)
        #expect(opened == [link, popup])
        #expect(webView.url == originalURL && session.activeTabID == tab && session.tabs.count == 2)
        let draft = try await webView.evaluateJavaScript("document.getElementById('draft').value") as? String
        #expect(draft == "keep this draft")
    }

    @Test("The first loopback navigation reports its own committed document and the preview stays readable")
    func firstLoopbackNavigationObservesItsOwnCommit() async throws {
        let center = makeCenter()
        let (session, tabID, _) = try isolatedSession(owner: UUID(), center: center)
        defer { session.release(); try? FileManager.default.removeItem(at: session.artifactDirectory) }
        try await loadIsolated("<button>Previous document</button>", tab: tabID, session: session)
        try Data("<!doctype html><button>Current preview document</button>".utf8)
            .write(to: session.artifactDirectory.appendingPathComponent("index.html"))
        let (server, site) = try await LocalPreviewServer.start(root: session.artifactDirectory, entry: "index.html")
        defer { server.stop() }
        let lease = try acquirePreviewLease(session)
        let previousID = try #require(session.activeTab?.documentID)
        let result = await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: tabID,
            action: .navigate(url: site.url.absoluteString)), control: lease)
        try #require(result.status == .ok, Comment(rawValue: result.error?.message ?? "Navigation did not succeed"))
        let page = try #require(result.page)
        #expect(page.url == site.url.absoluteString && page.documentID != previousID && page.documentID == session.activeTab?.documentID)
        #expect(!page.nodes.contains(where: { $0.text == "Previous document" }))
        let loaded = await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: tabID,
            action: .wait(.text("Current preview document"))), control: lease)
        #expect(loaded.status == .ok && loaded.page?.nodes.contains(where: { $0.text == "Current preview document" }) == true)
    }

    @Test("Submitted input may navigate, while an already stale target cannot submit")
    func submittedInputNavigatesAndStaleTargetIsRejected() async throws {
        let center = makeCenter()
        let (session, tabID, _) = try isolatedSession(owner: UUID(), center: center)
        defer { session.release(); try? FileManager.default.removeItem(at: session.artifactDirectory) }
        try Data("""
            <!doctype html><form action="done.html"><input name="query"><button>Submit</button></form>
            """.utf8).write(to: session.artifactDirectory.appendingPathComponent("index.html"))
        try Data("<!doctype html><p>Submission received</p>".utf8)
            .write(to: session.artifactDirectory.appendingPathComponent("done.html"))
        let (server, site) = try await LocalPreviewServer.start(root: session.artifactDirectory, entry: "index.html")
        defer { server.stop() }
        let lease = try acquirePreviewLease(session)
        let opened = await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: tabID,
            action: .navigate(url: site.url.absoluteString)), control: lease)
        let page = try #require(opened.page)
        let input = try #require(page.nodes.first(where: { $0.role == "input" }))
        let oldTarget = BrowserTarget.element(ref: input.ref, documentID: page.documentID)
        let submitted = await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: tabID,
            expectedDocumentID: page.documentID, action: .type(oldTarget, text: "sample", submit: true)), control: lease)
        #expect(submitted.status == .ok, Comment(rawValue: submitted.message ?? submitted.error?.message ?? ""))
        let loaded = await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: tabID,
            action: .wait(.text("Submission received"))), control: lease)
        #expect(loaded.status == .ok)
        let stale = await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: tabID,
            expectedDocumentID: page.documentID, action: .type(oldTarget, text: "must-not-submit", submit: true)), control: lease)
        #expect(stale.status == .stale && stale.error?.code == "document")
    }

    @Test("A dispatched navigation never reports another page or returns page data after takeover", arguments: [false, true])
    func supersededOrTakenOverNavigationReturnsNoPage(takeover: Bool) async throws {
        let center = makeCenter()
        let (session, tabID, _) = try isolatedSession(owner: UUID(), center: center)
        defer { session.release(); try? FileManager.default.removeItem(at: session.artifactDirectory) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters), queue = DispatchQueue(label: "org.floeagent.test.pending-navigation")
        let requests = OSAllocatedUnfairLock(initialState: [NWConnection]())
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 4, maximumLength: 8192) { bytes, _, _, _ in
                if bytes?.starts(with: Data("GET ".utf8)) == true { requests.withLock { $0.append(connection) } }
                else { connection.cancel() }
            }
        }
        defer { listener.cancel(); requests.withLock { $0 }.forEach { $0.cancel() } }
        let port = try await startLoopbackListener(listener, on: queue)
        let lease = try acquirePreviewLease(session)
        let web = try #require(session.activeWebView)
        let navigating = Task {
            await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: tabID, timeoutMilliseconds: 5_000,
                action: .navigate(url: "http://127.0.0.1:\(port.rawValue)/pending")), control: lease)
        }
        defer { navigating.cancel() }
        try await awaitPreview { requests.withLock { !$0.isEmpty } }
        if takeover {
            session.beginUserTakeover(reason: nil)
            #expect(session.takeoverPending && !web.isUserInteractionEnabled)
            let connection = try #require(requests.withLock { $0.first })
            let body = "<!doctype html><button>Original request</button>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        } else {
            web.loadHTMLString("<button>Replacement page</button>", baseURL: nil)
        }
        let result = await navigating.value
        #expect(result.status == (takeover ? .needsUser : .stale) && result.page == nil)
        #expect(requests.withLock { $0.count } == 1)
        if takeover {
            try await awaitPreview { !session.takeoverPending }
            #expect(session.isUserControlling && web.isUserInteractionEnabled)
        }
    }

    @Test("A withheld response cannot replace a human draft after navigation stops",
          arguments: ["timeout", "cancel", "cancelAndTakeover", "release", "end", "missingDelegate"])
    func cancelledOrTimedOutNavigationCannotReplaceHumanDraft(interruption: String) async throws {
        let center = makeCenter()
        let (session, tab, _) = try isolatedSession(owner: UUID(), center: center)
        defer { session.release(); try? FileManager.default.removeItem(at: session.artifactDirectory) }
        let original = try #require(session.activeWebView)
        try await loadIsolated("<title>Draft</title><input id='draft' value='original'>", tab: tab, session: session)
        try await awaitPreview { original.title == "Draft" && !original.isLoading }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let connections = OSAllocatedUnfairLock(initialState: [NWConnection]())
        let queue = DispatchQueue(label: "org.floeagent.test.late-response")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 4, maximumLength: 8192) { bytes, _, _, _ in
                if bytes?.starts(with: Data("GET ".utf8)) == true { connections.withLock { $0.append(connection) } }
                else { connection.cancel() }
            }
        }
        defer { listener.cancel(); connections.withLock { $0 }.forEach { $0.cancel() } }
        let port = try await startLoopbackListener(listener, on: queue)
        let lease = try acquirePreviewLease(session)
        if interruption == "missingDelegate" { original.navigationDelegate = nil }
        let timesOut = interruption == "timeout" || interruption == "missingDelegate"
        let task = Task {
            await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: tab,
                timeoutMilliseconds: timesOut ? 1_500 : 10_000,
                action: .navigate(url: "http://127.0.0.1:\(port.rawValue)/withheld")), control: lease)
        }
        defer { task.cancel() }
        try await awaitPreview { connections.withLock { !$0.isEmpty } }
        switch interruption {
        case "cancelAndTakeover":
            session.beginUserTakeover(reason: nil)
            #expect(session.takeoverPending && !original.isUserInteractionEnabled)
            task.cancel()
        case "cancel": task.cancel()
        case "release": #expect(session.releaseModelControl(controlID: lease.id, runID: lease.runID) == .released)
        case "end": #expect(session.endModelControl(runID: lease.runID))
        default: break
        }
        let result = await task.value
        #expect(result.page == nil)
        if timesOut { #expect(result.status == .timeout) }
        else if interruption == "cancelAndTakeover" { #expect(result.status == .needsUser) }
        else if interruption == "cancel" { #expect(result.status == .failed && result.error?.code == "cancelled") }
        else { #expect(result.status == .stale) }
        if !session.isUserControlling { session.beginUserTakeover(reason: nil) }
        let target: WKWebView
        if interruption == "missingDelegate" {
            let receipt = try #require(session.unresponsiveNavigationID)
            session.finishTakeoverIfIdle()
            session.closeUnresponsiveNavigation(UUID())
            #expect(session.takeoverPending && session.activeWebView === original && !original.isUserInteractionEnabled)
            session.closeUnresponsiveNavigation(receipt)
            target = try #require(session.activeWebView)
            try #require(target !== original && original.superview == nil && original.navigationDelegate == nil)
            session.closeUnresponsiveNavigation(receipt)
            #expect(session.activeWebView === target)
            target.loadHTMLString("<title>New draft</title><input id='draft' value='original'>", baseURL: nil)
            try await awaitPreview { target.title == "New draft" && !target.isLoading }
        } else {
            target = original
        }
        try await awaitPreview { !session.takeoverPending && target.isUserInteractionEnabled }
        let humanDocument = try #require(session.activeTab?.documentID)
        let edited = try await target.evaluateJavaScript("document.querySelector('#draft').value = 'edited after takeover'") as? String
        try #require(edited == "edited after takeover")
        let connection = try #require(connections.withLock { $0.first })
        let body = "<!doctype html><title>Late replacement</title>"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel(); done.resume() })
        }
        try await awaitPreview { !target.isLoading }
        let draft = try await target.evaluateJavaScript("document.querySelector('#draft')?.value") as? String
        #expect(draft == "edited after takeover" && session.activeTab?.documentID == humanDocument)
        #expect(session.activeWebView === target && session.unresponsiveNavigationID == nil && connections.withLock { $0.count } == 1)
    }

    @Test("A real WebKit popup retains its opener and task, loads once, and inherits the isolated browser probe")
    func webKitPopupKeepsItsOpenerAndLoadsTheChildOnce() async throws {
        let center = makeCenter()
        let (session, parentID, store) = try isolatedSession(owner: UUID(), center: center)
        let root = session.artifactDirectory
        defer {
            session.release()
            try? FileManager.default.removeItem(at: root)
        }
        let parentHTML = """
            <!doctype html><title>Popup source</title><input id="draft" value="Source draft">
            <script>window.childLoads = 0;</script>
            """
        let childHTML = """
            <!doctype html><title>Popup child</title><button>Child action</button>
            <script>window.opener.childLoads++;</script>
            """
        try Data(parentHTML.utf8).write(to: root.appendingPathComponent("index.html"))
        try Data(childHTML.utf8).write(to: root.appendingPathComponent("child.html"))
        let (server, site) = try await LocalPreviewServer.start(root: root, entry: "index.html")
        defer { server.stop() }
        let parent = try #require(session.activeWebView)
        parent.load(URLRequest(url: site.url))
        try await awaitPreview { parent.title == "Popup source" && !parent.isLoading }
        let idlePolicy = parent.configuration.preferences.inactiveSchedulingPolicy
        let lease = try acquirePreviewLease(session)

        // This runs in the page and enters WebKit's real WKUIDelegate callback.
        let opened = try await parent.evaluateJavaScript("window.fixturePopup = window.open('child.html', 'floePopup'); !!window.fixturePopup") as? Bool
        try #require(opened == true)
        try await awaitPreview {
            session.tabs.count == 2 && session.activeWebView?.title == "Popup child" && session.activeWebView?.isLoading == false
        }
        let childTab = try #require(session.activeTab)
        let child = childTab.webView
        #expect(childTab.id != parentID && child !== parent)
        #expect(child.configuration.websiteDataStore === store)
        #expect(child.navigationDelegate === session && child.uiDelegate === session)
        let openerDraft = try await child.evaluateJavaScript("window.opener.document.getElementById('draft').value") as? String
        #expect(openerDraft == "Source draft")
        let loads = try await parent.evaluateJavaScript("window.childLoads") as? NSNumber
        #expect(loads?.intValue == 1)
        let siteProbe = try await child.evaluateJavaScript("typeof globalThis.__floeProtocol") as? String
        #expect(siteProbe == "undefined")
        let inheritedHandler = try await child.callAsyncJavaScript(
            "return typeof globalThis.webkit?.messageHandlers?.floePreviewChanged?.postMessage",
            arguments: [:], in: nil, contentWorld: session.contentWorld) as? String
        #expect(inheritedHandler == "function")
        let observed = await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: childTab.id,
            action: .observe(cursor: nil)), control: lease)
        #expect(observed.status == .ok && observed.page?.nodes.contains(where: {
            $0.role == "button" && $0.text == "Child action"
        }) == true)

        session.close(parentID)
        #expect(session.openRequestedWindow(for: URLRequest(url: site.url), from: parent, configuration: parent.configuration) == nil)
        #expect(session.openRequestedWindow(for: URLRequest(url: root), from: child, configuration: child.configuration) == nil)
        #expect(session.tabs.count == 1)
        #expect(session.activeWebView === child && child.configuration.preferences.inactiveSchedulingPolicy == .none)
        #expect(session.releaseModelControl(controlID: lease.id, runID: lease.runID) == .released)
        #expect(child.configuration.preferences.inactiveSchedulingPolicy == idlePolicy)
        _ = try await parent.evaluateJavaScript("window.fixturePopup.eval('window.close()'); true")
        try await awaitPreview { session.tabs.count == 1 && session.activeWebView !== child }
        #expect(session.activeTab?.openerID == nil && session.activeWebView != nil)
    }

    @Test("Closing a real popup returns to its original tab, including when close arrives during handback")
    func popupCloseReturnsToItsOpenerAfterHandback() async throws {
        let center = makeCenter()
        let (session, parentID, _) = try isolatedSession(owner: UUID(), center: center)
        defer { session.release(); try? FileManager.default.removeItem(at: session.artifactDirectory) }
        let parent = try #require(session.activeWebView)
        try await loadIsolated("<input id='draft' value='Retained draft'>", tab: parentID, session: session)
        let otherID = try #require(session.createTab())
        session.activate(parentID)
        let opened = try await parent.evaluateJavaScript("window.fixturePopup = window.open('about:blank', 'floeLogin'); !!window.fixturePopup") as? Bool
        try #require(opened == true)
        try await awaitPreview { session.tabs.count == 3 }
        let child = try #require(session.activeWebView)
        session.beginUserTakeover(reason: nil)
        session.returningToModel = true
        _ = try await parent.evaluateJavaScript("window.fixturePopup.close(); true")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var closed = false
        while !closed && ContinuousClock.now < deadline {
            closed = try await parent.evaluateJavaScript("window.fixturePopup.closed") as? Bool == true
            if !closed { try await Task.sleep(for: .milliseconds(20)) }
        }
        try #require(closed, "WebKit did not close the real child window")
        session.webViewDidClose(child) // A duplicate confirmed callback inside the fence is harmless.
        #expect(session.activeWebView === child && session.tabs.count == 3)
        session.returningToModel = false
        #expect(session.activeWebView === parent && session.tabs.map(\.id) == [parentID, otherID])
        session.webViewDidClose(child)
        session.webViewDidClose(parent)
        #expect(session.activeWebView === parent && session.tabs.count == 2)
        let draft = try await parent.evaluateJavaScript("document.getElementById('draft').value") as? String
        #expect(draft == "Retained draft" && session.isUserControlling)
    }

    @Test("When a popup loses its opener, the existing tab becomes read-only under the same model lease")
    func orphanedPopupRestoresFixedViewportOnTheExistingTab() async throws {
        let center = makeCenter()
        let (session, existingID, _) = try isolatedSession(owner: UUID(), center: center)
        defer { session.release(); try? FileManager.default.removeItem(at: session.artifactDirectory) }
        let existing = try #require(session.activeTab)
        try await loadIsolated("<button>Existing page</button>", tab: existingID, session: session)
        let sourceID = try #require(session.createTab())
        let source = try #require(session.activeWebView)
        try await loadIsolated("<title>Popup source</title>", tab: sourceID, session: session)
        let lease = try acquirePreviewLease(session)
        try #require(existing.viewport.fixedSize == nil && existing.webView.isUserInteractionEnabled)

        let opened = try await source.evaluateJavaScript("window.fixturePopup = window.open('about:blank', 'floeOrphan'); !!window.fixturePopup") as? Bool
        try #require(opened == true)
        try await awaitPreview { session.tabs.count == 3 && session.activeTab?.openerID == sourceID }
        session.close(sourceID)
        _ = try await source.evaluateJavaScript("window.fixturePopup.close(); true")
        try await awaitPreview { session.activeTabID == existingID && session.tabs.count == 1 }
        #expect(session.activeWebView === existing.webView && session.isModelControlCurrent(lease))
        #expect(existing.viewport.fixedSize == existing.webView.bounds.size && !existing.webView.isUserInteractionEnabled)
        #expect(existing.webView.accessibilityElementsHidden)
        #expect(session.releaseModelControl(controlID: lease.id, runID: lease.runID) == .released)
        #expect(existing.viewport.fixedSize == nil && existing.webView.isUserInteractionEnabled)
    }

    @Test("Browsing another tab preserves the model target and prevents overlapping access")
    func humanTabSelectionDoesNotRetargetModel() async throws {
        let center = makeCenter()
        let (session, modelTab, _) = try isolatedSession(owner: UUID(), center: center)
        defer { session.release(); try? FileManager.default.removeItem(at: session.artifactDirectory) }
        let other = try #require(session.createTab())
        session.activate(modelTab)
        let lease = try acquirePreviewLease(session)
        session.browseWhileModelRuns(other)
        #expect(session.activeTabID == modelTab && session.humanBrowsingTabID == other)
        #expect(session.fixedViewportTab?.id == modelTab)
        #expect(session.humanBrowsingTab?.viewport.fixedSize == nil)
        let blocked = await session.execute(BrowserCommand(sessionID: session.sessionID, tabID: other,
            action: .observe(cursor: nil)), control: lease)
        #expect(blocked.status == .needsUser)
        let newTab = try #require(session.createHumanBrowsingTab())
        #expect(session.activeTabID == modelTab && session.humanBrowsingTabID == newTab)
        #expect(session.releaseModelControl(controlID: lease.id, runID: lease.runID) == .released)
        #expect(session.activeTabID == newTab && session.humanBrowsingTabID == nil)
    }

    private func startLoopbackListener(_ listener: NWListener, on queue: DispatchQueue) async throws -> NWEndpoint.Port {
        let (startup, state) = AsyncStream<Bool>.makeStream()
        listener.stateUpdateHandler = {
            switch $0 {
            case .ready: state.yield(true); state.finish()
            case .failed, .cancelled: state.finish()
            default: break
            }
        }
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { state.finish() }
        var readiness = startup.makeAsyncIterator()
        let started = await readiness.next()
        try #require(started == true, "The loopback listener did not reach its ready state")
        let port = try #require(listener.port)
        try #require(port.rawValue > 0, "The ready listener did not receive an assigned port")
        return port
    }

    @Test("System browsing opens an ordinary GET externally and keeps the real popup form method and body in WebKit")
    func systemBrowserPreferencePreservesPopupFormPost() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "org.floeagent.test.popup-form")
        let exchanges = OSAllocatedUnfairLock(initialState: [String]())
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.echoPopupForm(connection, received: Data()) { entry in
                exchanges.withLock { $0.append(entry) }
            }
        }
        defer { listener.cancel() }
        let port = try await startLoopbackListener(listener, on: queue)
        let endpoint = try #require(URL(string: "http://127.0.0.1:\(port.rawValue)/form"))
        let parentURL = endpoint.deletingLastPathComponent().appendingPathComponent("parent")

        let center = makeCenter()
        var external: [URL] = []
        let (session, parentID, _) = try isolatedSession(owner: UUID(), center: center, linkOpenBehavior: .systemBrowser,
                                                         openSystemURL: { external.append($0) })
        defer { session.release(); try? FileManager.default.removeItem(at: session.artifactDirectory) }
        let parent = try #require(session.activeWebView)
        let windowScenes: [UIWindowScene] = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let foregroundScene: UIWindowScene? = windowScenes.first { candidate in
            candidate.activationState == .foregroundActive || candidate.activationState == .foregroundInactive
        }
        let scene = try #require(foregroundScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        let mount = BrowserPageMount(frame: controller.view.bounds)
        mount.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(mount)
        let presentation = UUID()
        let windows = PopupFormWindowObserver(session: session, mount: mount, presentation: presentation)
        defer { mount.detach(); window.isHidden = true; withExtendedLifetime(windows) {} }
        mount.configure(tab: session.activeTab, id: presentation, readOnly: false, priority: 0, active: true)
        window.layoutIfNeeded()
        try #require(parent.window === window && mount.ownsPage && !mount.bounds.isEmpty)
        parent.uiDelegate = windows
        @MainActor func waitFor(_ phase: String, _ condition: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            let tabs = session.tabs.map { tab in
                let lifecycle = tab.events.filter { $0.method.hasPrefix("Page.") || $0.method == "Network.loadingFailed" }
                    .map { $0.method + ($0.detail.map { ": " + $0 } ?? "") }
                return "\(tab.webView.url?.path ?? "-") mounted=\(tab.webView.window === window) loading=\(tab.webView.isLoading) events=\(lifecycle)"
            }
            let wire = exchanges.withLock { $0 }
            try #require(condition(), Comment(rawValue: "\(phase): windows=\(windows.entries) external=\(external.map(\.path)) wire=\(wire) tabs=\(tabs) surface=\(session.surfaceState)"))
        }
        parent.load(URLRequest(url: parentURL))
        try await waitFor("loading the HTTP parent form") { parent.url == parentURL && parent.title == "Popup form" && !parent.isLoading }
        session.beginUserTakeover(reason: nil)
        _ = try await parent.evaluateJavaScript("window.open('/ordinary', 'floeGet'); true")
        try await waitFor("opening the GET externally") { external.count == 1 }
        #expect(external == [endpoint.deletingLastPathComponent().appendingPathComponent("ordinary")])
        _ = try await parent.evaluateJavaScript("document.getElementById('submit-form').click(); true")
        try await waitFor("creating the POST child") { session.tabs.count == 2 && session.activeTab?.openerID == parentID }
        try await waitFor("receiving the POST body") { exchanges.withLock { $0.contains("received POST /form fixture=retain+this") } }
        let child = try #require(session.activeWebView)
        try #require(child.window === window && mount.ownsPage)
        try await waitFor("sending the complete HTTP response") { exchanges.withLock { $0.contains("sent POST /form") } }
        try await waitFor("loading the POST response in the child") {
            child.url == endpoint && !child.isLoading && session.activeTab?.events.contains(where: { $0.method == "Page.loadEventFired" }) == true
        }
        let echoed = try await child.evaluateJavaScript("document.readyState === 'complete' && document.getElementById('receipt')?.textContent") as? String
        #expect(echoed == "POST\nfixture=retain+this" && external.count == 1)
    }

    /// Observe the real callback and return the production delegate's exact decision.
    @MainActor private final class PopupFormWindowObserver: NSObject, WKUIDelegate {
        let session: BrowserTaskSession
        let mount: BrowserPageMount
        let presentation: UUID
        var entries: [String] = []
        init(session: BrowserTaskSession, mount: BrowserPageMount, presentation: UUID) {
            self.session = session
            self.mount = mount
            self.presentation = presentation
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let result = session.webView(webView, createWebViewWith: configuration, for: navigationAction, windowFeatures: windowFeatures)
            let request = navigationAction.request
            entries.append("\(request.httpMethod ?? "-") \(request.url?.path ?? "-") type=\(navigationAction.navigationType.rawValue) child=\(result != nil)")
            if let result, let tab = session.activeTab, tab.webView === result {
                mount.configure(tab: tab, id: presentation, readOnly: false, priority: 0, active: true)
            }
            return result
        }
    }

    /// Serve the opener and the form response on the same HTTP origin.
    private nonisolated static func echoPopupForm(_ connection: NWConnection, received: Data,
                                                   record: @escaping @Sendable (String) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, complete, error in
            var data = received
            if let chunk { data.append(chunk) }
            guard data.count < 32_768, error == nil else { connection.cancel(); return }
            if let end = data.range(of: Data("\r\n\r\n".utf8)),
               let headers = String(data: data[..<end.lowerBound], encoding: .utf8) {
                let lines = headers.components(separatedBy: "\r\n")
                let length = lines.first(where: { $0.lowercased().hasPrefix("content-length:") })
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = data[end.upperBound...]
                let firstLine = lines.first?.split(separator: " ") ?? []
                if length >= 0, body.count >= length, firstLine.count >= 2 {
                    let method = firstLine[0], path = firstLine[1]
                    let payload = String(decoding: body.prefix(length), as: UTF8.self)
                    record("received \(method) \(path) \(payload)")
                    let parent = method == "GET" && path == "/parent"
                    let receipt = (String(method) + "\n" + payload)
                        .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                        .replacingOccurrences(of: ">", with: "&gt;")
                    let text = parent ? """
                        <!doctype html><title>Popup form</title>
                        <form action="/form" method="post" target="floePost">
                        <input name="fixture" value="retain this"><button id="submit-form" type="submit">Submit</button></form>
                        """ : "<!doctype html><title>Form response</title><pre id='receipt'>\(receipt)</pre>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(text.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" + text
                    connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { error in
                            if let error { record("send failed \(method) \(path): \(error)") }
                            else { record("sent \(method) \(path)") }
                            connection.cancel()
                        })
                    return
                }
            }
            if complete { connection.cancel() }
            else { echoPopupForm(connection, received: data, record: record) }
        }
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
        session.finishTakeoverIfIdle()
        #expect(session.takeoverPending)
        #expect(!session.reloadFromUser())
        #expect(session.activeWebView?.isUserInteractionEnabled == false)

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

    @Test("Moving to other tools releases the current model lease and leaves the tab open")
    func idleReleasePreservesOpenTabsAndHumanControl() async throws {
        let center = makeCenter(), owner = UUID(), runID = UUID()
        center.bind(to: owner)
        defer { center.discard(conversationID: owner) }
        let registry = makeRegistry(center)
        let ctx = context(for: owner, runID: runID)
        _ = try await run(registry, "browser.tabs", "{}", as: ctx)
        let session = try #require(center.session(for: owner))
        let tabs = session.tabs.map(\.id)
        let lease = try #require(session.modelControl)
        center.releaseIdlePage(conversationID: owner, runID: UUID())
        #expect(session.modelControl == lease)
        center.releaseIdlePage(conversationID: owner, runID: runID)
        #expect(!session.isModelActive && session.tabs.map(\.id) == tabs)
        _ = try await run(registry, "browser.tabs", "{}", as: ctx)
        center.takeControl()
        center.releaseIdlePage(conversationID: owner, runID: runID)
        #expect(session.isUserControlling && session.tabs.map(\.id) == tabs)
    }

    @Test("Only in-flight browser work is presented, even while the run retains control")
    func idleLeaseDoesNotDisplayActivity() async throws {
        let center = makeCenter(), owner = UUID(), runID = UUID()
        center.bind(to: owner)
        defer { center.discard(conversationID: owner) }
        let registry = makeRegistry(center)
        _ = try await run(registry, "browser.tabs", "{}", as: context(for: owner, runID: runID))
        let session = try #require(center.session(for: owner))
        let lease = try #require(session.modelControl)
        #expect(session.visibleModelActivity == nil)
        let first = session.beginVisibleOperation(.scrolling, lease: lease)
        let second = session.beginVisibleOperation(.downloading, lease: lease)
        session.endVisibleOperation(first)
        #expect(session.visibleModelActivity == .downloading)
        session.endVisibleOperation(second)
        #expect(session.visibleModelActivity == nil)
        #expect(session.modelControl == lease)
        let pending = session.beginVisibleOperation(.observing, lease: lease)
        center.takeControl()
        #expect(session.visibleModelActivity == nil)
        session.endVisibleOperation(pending)
    }

    @Test("A recovered return comment cannot launch a new turn or enter a different run")
    func recoveredBrowserCommentKeepsItsTargetRun() async throws {
        let environment = AppEnvironment.preview(), owner = UUID(), run = UUID(), id = UUID()
        try await environment.database.migrate()
        try await environment.conversationStore.saveConversation(.init(id: owner, title: "Handoff", createdAt: Date(), updatedAt: Date()))
        try await environment.runStore.saveRun(.init(id: run, conversationID: owner, state: "executing", goal: "Return", startedAt: Date()))
        let store = environment.runningInputStore
        try await store.upsert(.init(id: id, conversationID: owner, targetRunID: run, content: "Use this tab",
            mode: .steer, status: .steerPending, executionMode: "browserReturnComment"))
        try await store.recoverTransientInputs()
        #expect(try await store.claimNextQueued(conversationID: owner) == nil)
        #expect(try await store.beginSteerPromotion(id: id, expectedRunID: UUID()) == nil)
        #expect(try await store.beginSteerPromotion(id: id, expectedRunID: run)?.targetRunID == run)
        try await store.cancelPendingSteer(id: id, owner: owner, runID: run)
        #expect(try await store.input(id: id)?.status == .cancelled)
        try await environment.conversationStore.deleteConversation(id: owner)
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
        #expect(panel.contains("Human interaction was requested for this task's browser"), Comment(rawValue: panel))
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

    // MARK: - Durable page restore (process relaunch)

    private func makeRestoreFiles(directory: URL) throws -> (handoffURL: URL, snapshotURL: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            directory.appendingPathComponent("BrowserHandoffs.json"),
            directory.appendingPathComponent("BrowserTaskSnapshots.json")
        )
    }

    private func restoreCenter(_ files: (handoffURL: URL, snapshotURL: URL)) -> BrowserSessionCenter {
        BrowserSessionCenter(durableHandoffs: false, handoffStoreURL: files.handoffURL, snapshotStoreURL: files.snapshotURL)
    }

    private func load(
        _ html: String,
        at baseURL: URL,
        tab: UUID,
        in session: BrowserTaskSession,
        registry: ToolRunnerRegistry,
        context: ToolContext
    ) async throws -> [String: Any] {
        let webView = try #require(session.tabs.first(where: { $0.id == tab })?.webView)
        webView.loadHTMLString(html, baseURL: baseURL)
        let waited = try await run(
            registry,
            "browser.wait",
            "{\"tabID\":\"\(tab)\",\"condition\":\"load\",\"timeoutMilliseconds\":10000}",
            as: context
        )
        #expect(waited.contains("\"status\":\"ok\""), Comment(rawValue: waited))
        return try page(waited)
    }

    @Test("A rebuilt center restores committed GET pages in saved tab order and selection with a fresh identity")
    func rebuiltCenterRestoresCommittedPagesOrderSelectionAndFreshIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try makeRestoreFiles(directory: directory)
        var center: BrowserSessionCenter? = restoreCenter(files)
        let owner = UUID()
        center?.bind(to: owner)
        let session = try #require(center?.session(for: owner))
        let registry = makeRegistry(center!)
        let ctx = context(for: owner)
        let tab1 = try #require(session.activeTabID)
        let base1 = URL(string: "https://restore.fixture/first")!
        try await load(fixturePage("alpha"), at: base1, tab: tab1, in: session, registry: registry, context: ctx)
        let tab2 = try #require(center?.createTab())
        let base2 = URL(string: "https://restore.fixture/second")!
        try await load(fixturePage("beta"), at: base2, tab: tab2, in: session, registry: registry, context: ctx)
        center?.activate(tab2)
        let page = try await observe(tab: tab2, registry: registry, context: ctx)
        let oldDocument = try #require(page["documentID"] as? String)
        // A durable human-takeover receipt bound to the pre-restart session.
        center?.takeControl(runID: UUID())
        let oldReceipt = try #require(center?.handoff)
        center?.flushBrowserSnapshots()
        #expect(FileManager.default.fileExists(atPath: files.snapshotURL.path))
        let oldSessionID = session.sessionID

        // Process end: release the center and every process-local session.
        center = nil

        let rebuilt = restoreCenter(files)
        rebuilt.bind(to: owner)
        let restored = try #require(rebuilt.session(for: owner))
        #expect(restored !== session)
        #expect(restored.sessionID != oldSessionID)
        #expect(restored.tabs.map(\.id) == [tab1, tab2])
        #expect(restored.activeTabID == tab2)
        #expect(restored.restoreInProgress)
        // Each restored tab keeps its validated pageURL from the start.
        #expect(restored.tabs.first(where: { $0.id == tab2 })?.restorableURL == base2)

        // The pre-restart receipt can never claim the replacement session.
        #expect(rebuilt.handoff?.sessionID == oldReceipt.sessionID)
        #expect(rebuilt.handoff?.sessionID != restored.sessionID)
        #expect(!restored.isUserControlling && restored.modelControl == nil)

        // Recovery targets the exact original run and still cannot hand the
        // new page to anyone.
        var recovered = 0
        rebuilt.deliverHandoff = { receipt, resume in
            #expect(receipt.id == oldReceipt.id && !resume)
            recovered += 1
            return false
        }
        await rebuilt.recoverHandoff(conversationID: owner, runID: UUID())
        #expect(recovered == 0)
        await rebuilt.recoverHandoff(conversationID: owner, runID: oldReceipt.runID!)
        #expect(recovered == 1)
        #expect(!restored.isUserControlling && restored.modelControl == nil)

        // An offline replay fails but must not erase the durable snapshot.
        // (Very slow DNS can keep the replay pending past the bounded wait;
        // the snapshot assertions below hold in either state.)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while restored.restoreInProgress && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        rebuilt.flushBrowserSnapshots()
        let persisted = try JSONDecoder().decode(
            [BrowserTaskPageSnapshot].self, from: Data(contentsOf: files.snapshotURL)
        )
        let entry = try #require(persisted.first(where: { $0.conversationID == owner }))
        #expect(entry.tabs.map(\.id) == [tab1, tab2])
        #expect(entry.selectedTabID == tab2)
        #expect(entry.tabs.first(where: { $0.id == tab2 })?.pageURL == base2)

        // Old DOM references and the old session identity are stale.
        let staleSession = await rebuilt.execute(
            BrowserCommand(sessionID: oldSessionID, tabID: tab1, expectedDocumentID: oldDocument, action: .observe(cursor: nil)),
            in: owner)
        #expect(staleSession.status == .stale && staleSession.error?.code == "session")
        let staleDocument = await rebuilt.execute(
            BrowserCommand(sessionID: restored.sessionID, tabID: tab1, expectedDocumentID: oldDocument, action: .observe(cursor: nil)),
            in: owner)
        #expect(staleDocument.status == .stale && staleDocument.error?.code == "document")

        // The first real model call observes the page again after its commit.
        let restoredWeb = try #require(restored.tabs.first(where: { $0.id == tab2 })?.webView)
        restoredWeb.loadHTMLString(fixturePage("beta"), baseURL: base2)
        let waited = await restored.execute(
            BrowserCommand(sessionID: restored.sessionID, tabID: tab2, action: .wait(.load))
        )
        #expect(waited.status == .ok, Comment(rawValue: waited.message ?? "restored page did not load"))
        let registry2 = makeRegistry(rebuilt)
        let observed = try await run(registry2, "browser.observe", "{\"tabID\":\"\(tab2)\"}", as: context(for: owner))
        #expect(observed.contains("ready-beta"), Comment(rawValue: observed))

        // A fresh takeover binds to the restored session's identity.
        rebuilt.takeControl(runID: UUID())
        #expect(rebuilt.handoff?.sessionID == restored.sessionID)
        rebuilt.discard(conversationID: owner)
    }

    @Test("Restored pages stay scoped to their exact task across a rebuild")
    func restoredPagesStayScopedToTheirExactTask() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try makeRestoreFiles(directory: directory)
        var center: BrowserSessionCenter? = restoreCenter(files)
        let ownerA = UUID(), ownerB = UUID()
        center?.bind(to: ownerA)
        let sessionA = try #require(center?.session(for: ownerA))
        let registry = makeRegistry(center!)
        let contextB = context(for: ownerB)
        let baseA = URL(string: "https://restore.fixture/task-a")!
        let a1 = try #require(sessionA.activeTabID)
        try await load(fixturePage("alpha"), at: baseA, tab: a1, in: sessionA, registry: registry, context: context(for: ownerA))
        _ = try await run(registry, "browser.tabs", "{}", as: contextB)
        let sessionB = try #require(center?.session(for: ownerB))
        let baseB = URL(string: "https://restore.fixture/task-b")!
        let b1 = try #require(sessionB.activeTabID)
        try await load(fixturePage("beta"), at: baseB, tab: b1, in: sessionB, registry: registry, context: contextB)
        center?.flushBrowserSnapshots()
        let persisted = try JSONDecoder().decode(
            [BrowserTaskPageSnapshot].self, from: Data(contentsOf: files.snapshotURL)
        )
        #expect(Set(persisted.map(\.conversationID)) == [ownerA, ownerB])
        center = nil

        let rebuilt = restoreCenter(files)
        rebuilt.bind(to: ownerA)
        let restoredA = try #require(rebuilt.session(for: ownerA))
        #expect(restoredA.tabs.map(\.id) == [a1])
        // The other task is untouched until its own bind.
        #expect(rebuilt.session(for: ownerB) == nil)
        rebuilt.bind(to: ownerB)
        let restoredB = try #require(rebuilt.session(for: ownerB))
        #expect(restoredB !== restoredA)
        #expect(restoredB.tabs.map(\.id) == [b1])
        #expect(restoredA.tabs.map(\.id) == [a1])
        #expect(restoredB.tabs.first?.restorableURL == baseB)
        // A task that never browsed restores as the honest blank default.
        let ownerC = UUID()
        rebuilt.bind(to: ownerC)
        let blankC = try #require(rebuilt.session(for: ownerC))
        #expect(blankC.tabs.count == 1 && blankC.tabs[0].restorableURL == nil)
        rebuilt.discard(conversationID: ownerA)
        rebuilt.discard(conversationID: ownerB)
        rebuilt.discard(conversationID: ownerC)
    }

    @Test("Deleting a task deletes its restorable pages before any rebuild")
    func deletingTaskRemovesItsRestorablePages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try makeRestoreFiles(directory: directory)
        var center: BrowserSessionCenter? = restoreCenter(files)
        let owner = UUID()
        center?.bind(to: owner)
        let session = try #require(center?.session(for: owner))
        let registry = makeRegistry(center!)
        let tab = try #require(session.activeTabID)
        try await load(
            fixturePage("alpha"),
            at: URL(string: "https://restore.fixture/delete-me")!,
            tab: tab,
            in: session,
            registry: registry,
            context: context(for: owner)
        )
        center?.flushBrowserSnapshots()
        // Archive/delete path: the center drops the owner and its snapshot together.
        center?.discard(conversationID: owner)
        let afterDelete = try JSONDecoder().decode(
            [BrowserTaskPageSnapshot].self, from: Data(contentsOf: files.snapshotURL)
        )
        #expect(!afterDelete.contains(where: { $0.conversationID == owner }))
        center = nil

        let rebuilt = restoreCenter(files)
        rebuilt.bind(to: owner)
        let blank = try #require(rebuilt.session(for: owner))
        #expect(blank.tabs.count == 1 && blank.activeTabID != nil)
        rebuilt.discard(conversationID: owner)
    }

    @Test("Closing tabs updates the persisted restore state on the same center")
    func closingTabsUpdatesThePersistedRestoreState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try makeRestoreFiles(directory: directory)
        let center = restoreCenter(files)
        let owner = UUID()
        center.bind(to: owner)
        defer { center.discard(conversationID: owner) }
        let session = try #require(center.session(for: owner))
        let registry = makeRegistry(center)
        let tab1 = try #require(session.activeTabID)
        try await load(fixturePage("alpha"), at: URL(string: "https://restore.fixture/keep")!,
                       tab: tab1, in: session, registry: registry, context: context(for: owner))
        let tab2 = try #require(center.createTab())
        try await load(fixturePage("beta"), at: URL(string: "https://restore.fixture/drop")!,
                       tab: tab2, in: session, registry: registry, context: context(for: owner))
        center.flushBrowserSnapshots()
        center.close(tab2)
        center.flushBrowserSnapshots()
        var persisted = try JSONDecoder().decode(
            [BrowserTaskPageSnapshot].self, from: Data(contentsOf: files.snapshotURL)
        )
        let entry = try #require(persisted.first(where: { $0.conversationID == owner }))
        #expect(entry.tabs.map(\.id) == [tab1])
        // Closing the last tab blanks it honestly and removes the restore entry.
        center.close(tab1)
        center.flushBrowserSnapshots()
        persisted = try JSONDecoder().decode(
            [BrowserTaskPageSnapshot].self, from: Data(contentsOf: files.snapshotURL)
        )
        #expect(!persisted.contains(where: { $0.conversationID == owner }))
    }

    @Test("Binding with prepareSession false selects only; the surface prepares the session")
    func bindingWithoutPreparationSelectsOnlyUntilTheSurfacePrepares() async throws {
        let center = makeCenter()
        let owner = UUID()
        center.bind(to: owner, prepareSession: false)
        #expect(center.conversationID == owner)
        #expect(center.session(for: owner) == nil)
        #expect(center.tabs.isEmpty)
        let session = center.prepareVisibleSession()
        #expect(session != nil)
        #expect(center.session(for: owner) === session)
        #expect(session?.tabs.count == 1)
        // The default path keeps preparing eagerly for existing callers.
        let other = UUID()
        center.bind(to: other)
        #expect(center.session(for: other) != nil)
        // Re-binding the prepared conversation is a no-op.
        center.bind(to: owner, prepareSession: false)
        #expect(center.session(for: owner) === session)
        center.discard(conversationID: owner)
        center.discard(conversationID: other)
    }

    @Test("A restored task with prepareSession false replays only when the surface prepares it")
    func durableRestoreWaitsForTheSurfaceWithPrepareSessionFalse() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try makeRestoreFiles(directory: directory)
        var center: BrowserSessionCenter? = restoreCenter(files)
        let owner = UUID()
        center?.bind(to: owner)
        let session = try #require(center?.session(for: owner))
        let registry = makeRegistry(center!)
        let tab = try #require(session.activeTabID)
        let base = URL(string: "https://restore.fixture/deferred")!
        try await load(fixturePage("alpha"), at: base, tab: tab, in: session, registry: registry, context: context(for: owner))
        center?.flushBrowserSnapshots()
        center = nil

        let rebuilt = restoreCenter(files)
        rebuilt.bind(to: owner, prepareSession: false)
        #expect(rebuilt.conversationID == owner)
        #expect(rebuilt.session(for: owner) == nil)
        let restored = rebuilt.prepareVisibleSession()
        #expect(restored?.tabs.map(\.id) == [tab])
        #expect(restored?.restoreInProgress == true)
        rebuilt.discard(conversationID: owner)
    }

    @Test("A resumed model can reopen saved tabs before the browser panel mounts")
    func resumedRunRestoresSavedTabsBeforeUserOpensPanel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try makeRestoreFiles(directory: directory)
        let owner = UUID()
        let tabs = ["first", "second"].map {
            BrowserTaskPageSnapshot.Tab(id: UUID(), pageURL: URL(string: "https://restore.invalid/\($0)")!)
        }
        let snapshot = BrowserTaskPageSnapshot(
            conversationID: owner, tabs: tabs, selectedTabID: tabs[1].id, savedAt: Date()
        )
        try JSONEncoder().encode([snapshot]).write(to: files.snapshotURL, options: .atomic)

        let center = restoreCenter(files)
        center.bind(to: owner, prepareSession: false)
        let control = try center.beginModelControl(conversationID: owner, runID: UUID())
        #expect(control.session.tabs.map(\.id) == tabs.map(\.id))
        #expect(control.session.activeTabID == tabs[1].id)
        control.session.close(tabs[0].id)
        center.flushBrowserSnapshots()
        let saved = try JSONDecoder().decode([BrowserTaskPageSnapshot].self, from: Data(contentsOf: files.snapshotURL))
        #expect(saved.first?.tabs == [tabs[1]])
        center.discard(conversationID: owner)
    }

    @Test("Restore policy admits only plain public GET pages")
    func restorePolicyAdmitsOnlyPlainPublicPages() {
        #expect(BrowserURLPolicy.isRestorablePageURL(URL(string: "https://example.com/docs/page?lang=swift")!))
        #expect(BrowserURLPolicy.isRestorablePageURL(URL(string: "http://example.com/")!))
        #expect(!BrowserURLPolicy.isRestorablePageURL(URL(string: "https://user:pass@example.com/")!))
        #expect(!BrowserURLPolicy.isRestorablePageURL(URL(string: "https://example.com/cb?code=secret&state=xyz")!))
        #expect(!BrowserURLPolicy.isRestorablePageURL(URL(string: "https://example.com/cb#access_token=secret&token_type=bearer")!))
        #expect(!BrowserURLPolicy.isRestorablePageURL(URL(string: "https://example.com/#/callback?%61ccess_token=secret")!))
        #expect(!BrowserURLPolicy.isRestorablePageURL(URL(string: "https://example.com/file?X-Amz-Signature=secret")!))
        #expect(!BrowserURLPolicy.isRestorablePageURL(URL(string: "http://127.0.0.1:8080/preview")!))
        #expect(!BrowserURLPolicy.isRestorablePageURL(URL(string: "http://0x7f.0.0.1/preview")!))
        #expect(!BrowserURLPolicy.isRestorablePageURL(URL(string: "http://service.internal./preview")!))
        #expect(!BrowserURLPolicy.isRestorablePageURL(URL(string: "http://192.168.1.10/router")!))
        #expect(!BrowserURLPolicy.isRestorablePageURL(URL(string: "http://intranet/dashboard")!))
        #expect(!BrowserURLPolicy.isRestorablePageURL(URL(string: "http://[fd00::1]/local")!))
        #expect(!BrowserURLPolicy.isRestorablePageURL(URL(string: "about:blank")!))
        #expect(!BrowserURLPolicy.isRestorablePageURL(URL(string: "data:text/html,hi")!))
        let long = "https://example.com/" + String(repeating: "a", count: 4096)
        #expect(!BrowserURLPolicy.isRestorablePageURL(URL(string: long)!))
    }

    @Test("Form-committed documents never become restorable")
    func formCommittedDocumentsNeverBecomeRestorable() {
        let publicURL = URL(string: "https://example.com/form-result")!
        #expect(BrowserTaskSession.restorableCommitURL(loadURL: publicURL, formSubmission: false) == publicURL)
        #expect(BrowserTaskSession.restorableCommitURL(loadURL: publicURL, formSubmission: true) == nil)
        #expect(BrowserTaskSession.restorableCommitURL(
            loadURL: URL(string: "http://127.0.0.1:9000/x")!, formSubmission: false) == nil)
        #expect(BrowserTaskSession.restorableCommitURL(loadURL: nil, formSubmission: false) == nil)
    }

    @Test("A corrupt snapshot file is ignored and replaced on the next flush")
    func corruptSnapshotFileIsIgnored() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try makeRestoreFiles(directory: directory)
        try "not json".write(to: files.snapshotURL, atomically: true, encoding: .utf8)
        let center = restoreCenter(files)
        let owner = UUID()
        center.bind(to: owner)
        #expect(center.session(for: owner) != nil)
        center.flushBrowserSnapshots()
        let data = try Data(contentsOf: files.snapshotURL)
        _ = try JSONDecoder().decode([BrowserTaskPageSnapshot].self, from: data)
        center.discard(conversationID: owner)
    }

    @Test("Snapshot loading clamps tab counts, drops unsafe URLs and bounds the task set")
    func snapshotLoadingClampsTabsAndDropsUnsafeURLs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try makeRestoreFiles(directory: directory)
        let owner = UUID()
        let longURL = URL(string: "https://example.com/" + String(repeating: "a", count: 5000))!
        let crafted = BrowserTaskPageSnapshot(
            conversationID: owner,
            tabs: (0..<8).map {
                BrowserTaskPageSnapshot.Tab(id: UUID(), pageURL: URL(string: "https://example.com/page/\($0)")!)
            } + [
                BrowserTaskPageSnapshot.Tab(id: UUID(), pageURL: longURL),
                BrowserTaskPageSnapshot.Tab(id: UUID(), pageURL: URL(string: "http://192.168.1.1/")!),
                BrowserTaskPageSnapshot.Tab(id: UUID(), pageURL: URL(string: "http://intranet/")!)
            ],
            selectedTabID: nil,
            savedAt: Date()
        )
        try JSONEncoder().encode([crafted]).write(to: files.snapshotURL, options: .atomic)
        let center = restoreCenter(files)
        center.bind(to: owner)
        let session = try #require(center.session(for: owner))
        #expect(session.tabs.count == BrowserTaskPageSnapshot.maximumTabs)
        center.discard(conversationID: owner)

        // The on-disk store is bounded to the most recent tasks.
        let many = (0..<BrowserTaskPageSnapshot.maximumSnapshots + 6).map { index in
            BrowserTaskPageSnapshot(
                conversationID: UUID(),
                tabs: [BrowserTaskPageSnapshot.Tab(
                    id: UUID(),
                    pageURL: URL(string: "https://example.com/task/\(index)")!
                )],
                selectedTabID: nil,
                savedAt: Date().addingTimeInterval(TimeInterval(-index))
            )
        }
        try JSONEncoder().encode(many).write(to: files.snapshotURL, options: .atomic)
        let bounded = restoreCenter(files)
        bounded.flushBrowserSnapshots()
        let stored = try JSONDecoder().decode(
            [BrowserTaskPageSnapshot].self, from: Data(contentsOf: files.snapshotURL)
        )
        #expect(stored.count == BrowserTaskPageSnapshot.maximumSnapshots)
    }

}
#endif
