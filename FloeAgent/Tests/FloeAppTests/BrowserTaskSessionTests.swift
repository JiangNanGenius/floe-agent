// FloeAppTests — independent per-task browser execution (S7 item16).
//
// These are production-path tests: they use the compiled BrowserSessionCenter,
// BrowserTaskSession and the registered browser tools, with real WKWebViews
// loading synthetic offline HTML. Runtime-issued ToolContext identities select
// the task session; the visible projection is only a presentation concern.
//
// They are not executed in the code-first S5–S7 stage. Run them at the unified
// freeze together with the existing BrowserProtocol suites.

#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import Foundation
import Testing
import WebKit
import SwiftUI
import UIKit
import FloeCore
import FloeModels
import FloeTools
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

        // B keeps reading and mutating its own page.
        let readA = try await observe(tab: tabA, registry: registry, context: contextA)
        let readDocumentA = try #require(readA["documentID"] as? String)
        #expect(!readDocumentA.isEmpty)
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

        // A's own mutation waits for the return.
        let pageA = try await observe(tab: tabA, registry: registry, context: contextA)
        let documentA = try #require(pageA["documentID"] as? String)
        let referenceA = try #require(try button(in: pageA)["ref"] as? String)
        let deniedA = try await run(
            registry,
            "browser.click",
            "{\"tabID\":\"\(tabA)\",\"ref\":\"\(referenceA)\",\"documentID\":\"\(documentA)\"}",
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
        let foreignEvidence = await center.execute(
            BrowserCommand(
                sessionID: sessionB.sessionID,
                tabID: tabB,
                expectedDocumentID: documentB,
                visualEvidenceSHA256: digestA,
                visualFallbackReason: "noStructuredTarget",
                action: .click(.point(x: 12, y: 12))
            ),
            in: ownerB
        )
        #expect(foreignEvidence.status == .blocked)
        #expect(foreignEvidence.message?.contains("fresh screenshot") == true)

        // A's own digest passes evidence validation and is only rejected for
        // the structured/point boundary, never for a foreign screenshot.
        let ownEvidence = await center.execute(
            BrowserCommand(
                sessionID: sessionA.sessionID,
                tabID: tabA,
                expectedDocumentID: documentA,
                visualEvidenceSHA256: digestA,
                visualFallbackReason: "noStructuredTarget",
                action: .click(.point(x: 12, y: 12))
            ),
            in: ownerA
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

        // The current session's own takeover path still works.
        current.setUserControlling(true)
        #expect(current.isUserControlling)
        center.browserSessionRequestedUserControl(current, reason: "current")
        #expect(center.handoff(for: owner) != nil)
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
}
#endif
