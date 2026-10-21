// FloeAppTests — task-owned local previews and page capture (S7 item16 repair).
//
// Production-path tests: the compiled LocalPreviewCoordinator, preview tools,
// BrowserSessionCenter and BrowserPageCapturePort with real loopback preview
// servers and real WKWebViews on synthetic offline HTML. Preview records are
// keyed by the trusted ToolContext owner: starting, reloading or stopping one
// task's preview never affects another task's, there is no nil-owner fallback,
// and a failed or cancelled start cleans up only its own staging.
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
import FloeTools
@testable import FloeApp

@Suite("FloeApp.BrowserPreviewOwnership", .serialized)
@MainActor
struct BrowserPreviewOwnershipTests {
    // MARK: - Fixtures

    private func makeCenter() -> BrowserSessionCenter {
        BrowserSessionCenter(durableHandoffs: false)
    }

    private func makeCoordinator(_ center: BrowserSessionCenter) -> LocalPreviewCoordinator {
        let coordinator = LocalPreviewCoordinator(browser: center)
        // Mirror the AppEnvironment wiring (primary applies the same hook in
        // production): releasing a task's browser stops only that owner's
        // preview record.
        center.ownerReleaseHook = { [weak coordinator] owner in
            coordinator?.releasePreview(for: owner)
        }
        return coordinator
    }

    private func makeRegistry(_ coordinator: LocalPreviewCoordinator) -> ToolRunnerRegistry {
        let registry = ToolRunnerRegistry()
        registerPreviewTools(environment: coordinator, registry: registry)
        return registry
    }

    private func workspaceWithIndexHTML(marker: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-preview-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        <!doctype html><html><body style="margin:0">
          <p id="marker">preview-\(marker)</p>
        </body></html>
        """.write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        return root
    }

    private func context(
        for owner: UUID,
        workspaceRoot: URL,
        temporary: Bool = false,
        token: CancellationToken = CancellationToken()
    ) -> ToolContext {
        ToolContext(
            runID: UUID(),
            workspaceRootURL: workspaceRoot,
            cancellation: token,
            conversationID: owner,
            temporaryReadOnly: temporary
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

    private func servedBody(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FloeError.storageCorrupted("preview server returned a non-200 response")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func url(fromStartSummary summary: String) throws -> URL {
        try #require(URL(string: summary.replacingOccurrences(of: "Preview started at ", with: "")))
    }

    /// Main-actor handshake for the coordinator's deterministic lifecycle
    /// seam: the test observes that a start reached a real suspension
    /// boundary and then releases it. Only the first start that arrives is
    /// suspended, so a later same-owner start can complete normally.
    @MainActor
    private final class PreviewStartGate {
        private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
        private var resumeWaiter: CheckedContinuation<Void, Never>?
        private var reached = false
        private var released = false
        private var suspendNext = true

        func suspendFirstArrival() async {
            reached = true
            let waiters = reachedWaiters
            reachedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            guard suspendNext else { return }
            suspendNext = false
            if released { return }
            await withCheckedContinuation { resumeWaiter = $0 }
        }

        func waitUntilSuspended() async {
            if reached { return }
            await withCheckedContinuation { reachedWaiters.append($0) }
        }

        func release() {
            released = true
            resumeWaiter?.resume()
            resumeWaiter = nil
        }
    }

    // MARK: - Per-task preview ownership

    @Test("Two tasks keep independent preview servers, ports and browser sessions")
    func previewsAreOwnedPerTask() async throws {
        let center = makeCenter()
        let ownerA = UUID()
        let ownerB = UUID()
        center.bind(to: ownerA)
        let coordinator = makeCoordinator(center)
        let registry = makeRegistry(coordinator)
        let workspaceA = try workspaceWithIndexHTML(marker: "alpha")
        let workspaceB = try workspaceWithIndexHTML(marker: "beta")
        defer {
            try? FileManager.default.removeItem(at: workspaceA)
            try? FileManager.default.removeItem(at: workspaceB)
        }

        let startedA = try await run(
            registry, "preview.start", "{}",
            as: context(for: ownerA, workspaceRoot: workspaceA)
        )
        let startedB = try await run(
            registry, "preview.start", "{}",
            as: context(for: ownerB, workspaceRoot: workspaceB)
        )
        let urlA = try #require(URL(string: startedA.replacingOccurrences(of: "Preview started at ", with: "")))
        let urlB = try #require(URL(string: startedB.replacingOccurrences(of: "Preview started at ", with: "")))
        #expect(urlA != urlB)
        #expect(urlA.port != urlB.port)
        #expect(coordinator.url(for: ownerA) == urlA)
        #expect(coordinator.url(for: ownerB) == urlB)

        // Both servers serve their own owner's content.
        let bodyA = try await servedBody(urlA)
        let bodyB = try await servedBody(urlB)
        #expect(bodyA.contains("preview-alpha"))
        #expect(bodyB.contains("preview-beta"))

        // Each owner's browser session navigated to its own preview.
        let sessionA = try #require(center.session(for: ownerA))
        let sessionB = try #require(center.session(for: ownerB))
        #expect(sessionA.activeWebView?.url == urlA)
        #expect(sessionB.activeWebView?.url == urlB)
        // The visible projection never moved to B.
        #expect(center.conversationID == ownerA)
    }

    @Test("Reloading one task's preview leaves every other owner serving and showing")
    func reloadAffectsOnlyCallingOwner() async throws {
        let center = makeCenter()
        let ownerA = UUID()
        let ownerB = UUID()
        center.bind(to: ownerA)
        let coordinator = makeCoordinator(center)
        let registry = makeRegistry(coordinator)
        let workspaceA = try workspaceWithIndexHTML(marker: "alpha")
        let workspaceB = try workspaceWithIndexHTML(marker: "beta")
        defer {
            try? FileManager.default.removeItem(at: workspaceA)
            try? FileManager.default.removeItem(at: workspaceB)
        }
        let startedA = try await run(
            registry, "preview.start", "{}",
            as: context(for: ownerA, workspaceRoot: workspaceA)
        )
        let startedB = try await run(
            registry, "preview.start", "{}",
            as: context(for: ownerB, workspaceRoot: workspaceB)
        )
        let urlA = try #require(URL(string: startedA.replacingOccurrences(of: "Preview started at ", with: "")))
        let urlB = try #require(URL(string: startedB.replacingOccurrences(of: "Preview started at ", with: "")))
        let sessionA = try #require(center.session(for: ownerA))
        let sessionB = try #require(center.session(for: ownerB))

        let reloaded = try await run(
            registry, "preview.reload", "{}",
            as: context(for: ownerB, workspaceRoot: workspaceB)
        )
        #expect(reloaded.contains("Preview reloaded"))

        // B's page still shows its own preview; A is untouched.
        #expect(sessionB.activeWebView?.url == urlB)
        #expect(sessionA.activeWebView?.url == urlA)
        let bodyA = try await servedBody(urlA)
        let bodyB = try await servedBody(urlB)
        #expect(bodyA.contains("preview-alpha"))
        #expect(bodyB.contains("preview-beta"))
    }

    @Test("Stopping one task's preview leaves the other owner's server and page usable")
    func stopAffectsOnlyCallingOwner() async throws {
        let center = makeCenter()
        let ownerA = UUID()
        let ownerB = UUID()
        center.bind(to: ownerA)
        let coordinator = makeCoordinator(center)
        let registry = makeRegistry(coordinator)
        let workspaceA = try workspaceWithIndexHTML(marker: "alpha")
        let workspaceB = try workspaceWithIndexHTML(marker: "beta")
        defer {
            try? FileManager.default.removeItem(at: workspaceA)
            try? FileManager.default.removeItem(at: workspaceB)
        }
        let startedA = try await run(
            registry, "preview.start", "{}",
            as: context(for: ownerA, workspaceRoot: workspaceA)
        )
        _ = try await run(
            registry, "preview.start", "{}",
            as: context(for: ownerB, workspaceRoot: workspaceB)
        )
        let urlA = try #require(URL(string: startedA.replacingOccurrences(of: "Preview started at ", with: "")))

        let stopped = try await run(
            registry, "preview.stop", "{}",
            as: context(for: ownerB, workspaceRoot: workspaceB)
        )
        #expect(stopped.contains("Preview stopped"))
        #expect(coordinator.url(for: ownerB) == nil)
        #expect(try await servedBody(urlA).contains("preview-alpha"))
        #expect(center.session(for: ownerA)?.activeWebView?.url == urlA)

        // A can still reload its own preview; B has none.
        let reloaded = try await run(
            registry, "preview.reload", "{}",
            as: context(for: ownerA, workspaceRoot: workspaceA)
        )
        #expect(reloaded.contains("Preview reloaded"))
        await #expect(throws: (any Error).self) {
            _ = try await run(
                registry, "preview.reload", "{}",
                as: context(for: ownerB, workspaceRoot: workspaceB)
            )
        }
    }

    // MARK: - Refusal and cleanup boundaries

    @Test("Preview tools refuse nil, temporary and cancelled owners without touching any browser")
    func previewRefusesUntrustedContexts() async throws {
        let center = makeCenter()
        let owner = UUID()
        center.bind(to: owner)
        let coordinator = makeCoordinator(center)
        let registry = makeRegistry(coordinator)
        let workspace = try workspaceWithIndexHTML(marker: "alpha")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let session = try #require(center.session(for: owner))

        // nil owner: no fallback to the visible browser.
        let anonymous = ToolContext(
            runID: UUID(),
            workspaceRootURL: workspace,
            cancellation: CancellationToken()
        )
        await #expect(throws: (any Error).self) {
            _ = try await run(registry, "preview.start", "{}", as: anonymous)
        }
        // Temporary chat is outside the preview ceiling.
        let temporary = context(for: owner, workspaceRoot: workspace, temporary: true)
        await #expect(throws: (any Error).self) {
            _ = try await run(registry, "preview.start", "{}", as: temporary)
        }
        // Cancelled run: refused before any server or session is created.
        let cancelledToken = CancellationToken()
        cancelledToken.cancel()
        let cancelled = context(for: owner, workspaceRoot: workspace, token: cancelledToken)
        await #expect(throws: FloeError.self) {
            _ = try await run(registry, "preview.start", "{}", as: cancelled)
        }
        // Nothing was navigated and no preview record exists.
        #expect(session.activeWebView?.url == nil)
        #expect(coordinator.url(for: owner) == nil)
    }

    @Test("A failed or cancelled start cleans only its own staging and keeps a working prior preview")
    func failedStartLeavesWorkingPreviewIntact() async throws {
        let center = makeCenter()
        let ownerA = UUID()
        let ownerB = UUID()
        center.bind(to: ownerA)
        let coordinator = makeCoordinator(center)
        let registry = makeRegistry(coordinator)
        let workspaceA = try workspaceWithIndexHTML(marker: "alpha")
        let workspaceB = try workspaceWithIndexHTML(marker: "beta")
        defer {
            try? FileManager.default.removeItem(at: workspaceA)
            try? FileManager.default.removeItem(at: workspaceB)
        }
        let startedA = try await run(
            registry, "preview.start", "{}",
            as: context(for: ownerA, workspaceRoot: workspaceA)
        )
        let urlA = try #require(URL(string: startedA.replacingOccurrences(of: "Preview started at ", with: "")))

        // B's start fails on a missing workspace root: A's record and page
        // must be untouched and no B record may exist.
        let missingRoot = workspaceB.appendingPathComponent("does-not-exist")
        await #expect(throws: (any Error).self) {
            _ = try await run(
                registry, "preview.start",
                "{\"root\":\"sub\"}",
                as: context(for: ownerB, workspaceRoot: missingRoot)
            )
        }
        // B's start is refused before admission (the token is already
        // cancelled): same single-owner cleanup.
        let cancelledToken = CancellationToken()
        cancelledToken.cancel()
        await #expect(throws: FloeError.self) {
            _ = try await run(
                registry, "preview.start", "{}",
                as: context(for: ownerB, workspaceRoot: workspaceB, token: cancelledToken)
            )
        }
        #expect(coordinator.url(for: ownerB) == nil)
        #expect(center.session(for: ownerB) == nil)
        #expect(try await servedBody(urlA).contains("preview-alpha"))
        #expect(center.session(for: ownerA)?.activeWebView?.url == urlA)
    }

    @Test("Releasing a task's browser stops only that owner's preview")
    func browserReleaseStopsOnlyThatOwnersPreview() async throws {
        let center = makeCenter()
        let ownerA = UUID()
        let ownerB = UUID()
        center.bind(to: ownerA)
        let coordinator = makeCoordinator(center)
        let registry = makeRegistry(coordinator)
        let workspaceA = try workspaceWithIndexHTML(marker: "alpha")
        let workspaceB = try workspaceWithIndexHTML(marker: "beta")
        defer {
            try? FileManager.default.removeItem(at: workspaceA)
            try? FileManager.default.removeItem(at: workspaceB)
        }
        let startedA = try await run(
            registry, "preview.start", "{}",
            as: context(for: ownerA, workspaceRoot: workspaceA)
        )
        _ = try await run(
            registry, "preview.start", "{}",
            as: context(for: ownerB, workspaceRoot: workspaceB)
        )
        let urlA = try #require(URL(string: startedA.replacingOccurrences(of: "Preview started at ", with: "")))

        center.discard(conversationID: ownerB)
        #expect(coordinator.url(for: ownerB) == nil)
        #expect(try await servedBody(urlA).contains("preview-alpha"))
        #expect(coordinator.url(for: ownerA) != nil)
    }

    // MARK: - Suspended-start cancellation and ordering

    @Test("Cancellation during a suspended start keeps the prior preview and never promotes staging")
    func cancelledStartKeepsPriorPreview() async throws {
        let center = makeCenter()
        let owner = UUID()
        center.bind(to: owner)
        let coordinator = makeCoordinator(center)
        let registry = makeRegistry(coordinator)
        let workspace = try workspaceWithIndexHTML(marker: "alpha")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let initial = try url(fromStartSummary: try await run(
            registry, "preview.start", "{}",
            as: context(for: owner, workspaceRoot: workspace)
        ))

        let gate = PreviewStartGate()
        let token = CancellationToken()
        var stagedURL: URL?
        coordinator.previewStartPhaseHookForTesting = { phase in
            guard case .afterServerStart(let hookOwner, let url) = phase,
                  hookOwner == owner else { return }
            stagedURL = url
            await gate.suspendFirstArrival()
        }
        defer { coordinator.previewStartPhaseHookForTesting = nil }

        let attempt = Task {
            try await run(
                registry, "preview.start", "{}",
                as: context(for: owner, workspaceRoot: workspace, token: token)
            )
        }
        await gate.waitUntilSuspended()
        token.cancel()
        gate.release()
        do {
            _ = try await attempt.value
            Issue.record("a cancelled preview start must not succeed")
        } catch FloeError.cancelled {
        } catch {
            Issue.record("expected cancellation, got \(error)")
        }

        #expect(stagedURL != nil && stagedURL != initial)
        #expect(coordinator.url(for: owner) == initial)
        #expect(center.session(for: owner)?.activeWebView?.url == initial)
    }

    @Test("Cancellation after navigation restores only this task's prior preview")
    func cancelledAfterNavigationRestoresPriorPreview() async throws {
        let center = makeCenter()
        let owner = UUID()
        let otherTask = UUID()
        center.bind(to: owner)
        let coordinator = makeCoordinator(center)
        let registry = makeRegistry(coordinator)
        let workspace = try workspaceWithIndexHTML(marker: "alpha")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let initial = try url(fromStartSummary: try await run(
            registry, "preview.start", "{}",
            as: context(for: owner, workspaceRoot: workspace)
        ))

        // Another task's browser is visible; the restore must use the owning
        // task's own session, never the visible projection.
        center.bind(to: otherTask)
        let token = CancellationToken()
        var stagedURL: URL?
        coordinator.previewStartPhaseHookForTesting = { phase in
            guard case .afterNavigation(let hookOwner, let url) = phase,
                  hookOwner == owner else { return }
            stagedURL = url
            token.cancel()
        }
        defer { coordinator.previewStartPhaseHookForTesting = nil }

        do {
            _ = try await run(
                registry, "preview.start", "{}",
                as: context(for: owner, workspaceRoot: workspace, token: token)
            )
            Issue.record("a cancelled preview start must not succeed")
        } catch FloeError.cancelled {
        } catch {
            Issue.record("expected cancellation, got \(error)")
        }

        #expect(stagedURL != nil && stagedURL != initial)
        #expect(center.session(for: owner)?.activeWebView?.url == initial)
        #expect(center.session(for: otherTask)?.activeWebView?.url == nil)
        #expect(coordinator.url(for: owner) == initial)
    }

    @Test("Cancellation after navigation restores this task's pre-existing page when no preview was active")
    func cancelledFirstStartRestoresPriorPage() async throws {
        let center = makeCenter()
        let owner = UUID()
        center.bind(to: owner)
        let coordinator = makeCoordinator(center)
        let registry = makeRegistry(coordinator)
        let workspace = try workspaceWithIndexHTML(marker: "alpha")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let session = try #require(center.session(for: owner))
        let tab = try #require(session.activeTabID)
        let webView = try #require(session.tabs.first(where: { $0.id == tab })?.webView)
        let previousPage = URL(string: "https://example.com/previous-\(UUID().uuidString)")!
        webView.loadHTMLString("<html><body>previous page</body></html>", baseURL: previousPage)
        _ = try await center.execute(
            BrowserCommand(sessionID: session.sessionID, tabID: tab, action: .wait(.load)),
            in: owner
        )
        #expect(session.activeWebView?.url == previousPage)

        let token = CancellationToken()
        var stagedURL: URL?
        coordinator.previewStartPhaseHookForTesting = { phase in
            guard case .afterNavigation(let hookOwner, let url) = phase,
                  hookOwner == owner else { return }
            stagedURL = url
            token.cancel()
        }
        defer { coordinator.previewStartPhaseHookForTesting = nil }

        do {
            _ = try await run(
                registry, "preview.start", "{}",
                as: context(for: owner, workspaceRoot: workspace, token: token)
            )
            Issue.record("a cancelled preview start must not succeed")
        } catch FloeError.cancelled {
        } catch {
            Issue.record("expected cancellation, got \(error)")
        }

        #expect(stagedURL != nil)
        #expect(coordinator.url(for: owner) == nil)
        #expect(session.activeWebView?.url == previousPage)
    }

    @Test("Releasing the task during a suspended start does not resurrect its browser or promote staging")
    func releaseDuringStartDoesNotResurrect() async throws {
        let center = makeCenter()
        let owner = UUID()
        center.bind(to: owner)
        let coordinator = makeCoordinator(center)
        let registry = makeRegistry(coordinator)
        let workspace = try workspaceWithIndexHTML(marker: "alpha")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let gate = PreviewStartGate()
        coordinator.previewStartPhaseHookForTesting = { phase in
            guard case .afterServerStart(let hookOwner, _) = phase,
                  hookOwner == owner else { return }
            await gate.suspendFirstArrival()
        }
        defer { coordinator.previewStartPhaseHookForTesting = nil }

        let attempt = Task {
            try await run(
                registry, "preview.start", "{}",
                as: context(for: owner, workspaceRoot: workspace)
            )
        }
        await gate.waitUntilSuspended()
        center.discard(conversationID: owner)
        #expect(center.session(for: owner) == nil)
        #expect(coordinator.url(for: owner) == nil)

        gate.release()
        do {
            _ = try await attempt.value
            Issue.record("a start for a released owner must not succeed")
        } catch {
            #expect(
                error.localizedDescription.contains("superseded"),
                Comment(rawValue: error.localizedDescription)
            )
        }
        #expect(center.session(for: owner) == nil)
        #expect(coordinator.url(for: owner) == nil)
        #expect(center.activeTaskSessionCount == 0)
    }

    @Test("Stopping the preview during a suspended start supersedes it without navigating the task's page")
    func stopDuringStartDoesNotPromoteStaging() async throws {
        let center = makeCenter()
        let owner = UUID()
        center.bind(to: owner)
        let coordinator = makeCoordinator(center)
        let registry = makeRegistry(coordinator)
        let workspace = try workspaceWithIndexHTML(marker: "alpha")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let session = try #require(center.session(for: owner))

        let gate = PreviewStartGate()
        coordinator.previewStartPhaseHookForTesting = { phase in
            guard case .afterServerStart(let hookOwner, _) = phase,
                  hookOwner == owner else { return }
            await gate.suspendFirstArrival()
        }
        defer { coordinator.previewStartPhaseHookForTesting = nil }

        let attempt = Task {
            try await run(
                registry, "preview.start", "{}",
                as: context(for: owner, workspaceRoot: workspace)
            )
        }
        await gate.waitUntilSuspended()
        _ = coordinator.stop(owner: owner)
        gate.release()

        do {
            _ = try await attempt.value
            Issue.record("a start whose preview was stopped must not succeed")
        } catch {
            #expect(
                error.localizedDescription.contains("superseded"),
                Comment(rawValue: error.localizedDescription)
            )
        }
        #expect(coordinator.url(for: owner) == nil)
        #expect(center.session(for: owner) === session)
        #expect(session.activeWebView?.url == nil)
    }

    @Test("A newer same-owner start wins; the suspended earlier start cannot replace it")
    func newerSameOwnerStartWins() async throws {
        let center = makeCenter()
        let owner = UUID()
        center.bind(to: owner)
        let coordinator = makeCoordinator(center)
        let registry = makeRegistry(coordinator)
        let workspace = try workspaceWithIndexHTML(marker: "alpha")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let gate = PreviewStartGate()
        var firstStagedURL: URL?
        coordinator.previewStartPhaseHookForTesting = { phase in
            guard case .afterServerStart(let hookOwner, let url) = phase,
                  hookOwner == owner else { return }
            if firstStagedURL == nil { firstStagedURL = url }
            await gate.suspendFirstArrival()
        }
        defer { coordinator.previewStartPhaseHookForTesting = nil }

        let earlier = Task {
            try await run(
                registry, "preview.start", "{}",
                as: context(for: owner, workspaceRoot: workspace)
            )
        }
        await gate.waitUntilSuspended()

        let newest = try url(fromStartSummary: try await run(
            registry, "preview.start", "{}",
            as: context(for: owner, workspaceRoot: workspace)
        ))
        gate.release()

        do {
            _ = try await earlier.value
            Issue.record("a superseded preview start must not succeed")
        } catch {
            #expect(
                error.localizedDescription.contains("superseded"),
                Comment(rawValue: error.localizedDescription)
            )
        }
        #expect(firstStagedURL != nil && firstStagedURL != newest)
        #expect(coordinator.url(for: owner) == newest)
        #expect(center.session(for: owner)?.activeWebView?.url == newest)
        #expect(try await servedBody(newest).contains("preview-alpha"))
    }

    @Test("A background owner's start never moves the explicitly selected preview projection")
    func startDoesNotStealSelectedProjection() async throws {
        let center = makeCenter()
        let ownerA = UUID()
        let ownerB = UUID()
        center.bind(to: ownerA)
        let coordinator = makeCoordinator(center)
        let registry = makeRegistry(coordinator)
        let workspaceA = try workspaceWithIndexHTML(marker: "alpha")
        let workspaceB = try workspaceWithIndexHTML(marker: "beta")
        defer {
            try? FileManager.default.removeItem(at: workspaceA)
            try? FileManager.default.removeItem(at: workspaceB)
        }

        // A is the explicit UI selection before any preview exists.
        coordinator.select(ownerA)
        #expect(coordinator.selectedOwner == ownerA)
        #expect(coordinator.activeURL == nil)

        let initialA = try url(fromStartSummary: try await run(
            registry, "preview.start", "{}",
            as: context(for: ownerA, workspaceRoot: workspaceA)
        ))
        #expect(coordinator.selectedOwner == ownerA)
        #expect(coordinator.activeURL == initialA)

        // Starting B in the background neither selects B nor rewrites A's URL.
        let urlB = try url(fromStartSummary: try await run(
            registry, "preview.start", "{}",
            as: context(for: ownerB, workspaceRoot: workspaceB)
        ))
        #expect(coordinator.selectedOwner == ownerA)
        #expect(coordinator.activeURL == initialA)

        // Explicit selection follows B; restarting A in the background keeps B.
        coordinator.select(ownerB)
        #expect(coordinator.selectedOwner == ownerB)
        #expect(coordinator.activeURL == urlB)
        let restartedA = try url(fromStartSummary: try await run(
            registry, "preview.start", "{}",
            as: context(for: ownerA, workspaceRoot: workspaceA)
        ))
        #expect(restartedA != initialA)
        #expect(coordinator.selectedOwner == ownerB)
        #expect(coordinator.activeURL == urlB)
        #expect(coordinator.url(for: ownerA) == restartedA)

        // Releasing B clears only B's projection.
        center.discard(conversationID: ownerB)
        #expect(coordinator.selectedOwner == nil)
        #expect(coordinator.activeURL == nil)
        #expect(coordinator.url(for: ownerA) == restartedA)
    }

    @Test("Reload reports the actual browser outcome and preserves the original record")
    func reloadReportsActualOutcome() async throws {
        let center = makeCenter()
        let owner = UUID()
        center.bind(to: owner)
        let coordinator = makeCoordinator(center)
        let registry = makeRegistry(coordinator)
        let workspace = try workspaceWithIndexHTML(marker: "alpha")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let started = try url(fromStartSummary: try await run(
            registry, "preview.start", "{}",
            as: context(for: owner, workspaceRoot: workspace)
        ))
        let session = try #require(center.session(for: owner))
        let toolContext = context(for: owner, workspaceRoot: workspace)

        // User takeover: a needsUser result, not a fake success.
        session.setUserControlling(true)
        let reload = try #require(registry.runner(named: "preview.reload"))
        let needsUser = try await reload.execute(argumentsJSON: Data("{}".utf8), context: toolContext)
        #expect(needsUser.requiresUserAction)
        #expect(needsUser.summary.contains("needs the user"), Comment(rawValue: needsUser.summary))
        #expect(coordinator.url(for: owner) == started)
        session.setUserControlling(false)

        // The browser page is gone: the record stays, but reload reports the
        // stale boundary instead of claiming success.
        session.release()
        await #expect(throws: (any Error).self) {
            _ = try await run(registry, "preview.reload", "{}", as: toolContext)
        }
        #expect(coordinator.url(for: owner) == started)
    }

    // MARK: - Design capture ownership

    @Test("Page capture reads the requesting owner's session and actual run, never the visible task")
    func captureReadsRequestingOwnerSessionOnly() async throws {
        let environment = AppEnvironment.preview()
        let center = environment.browserCenter
        let owner = UUID()
        let visibleTask = UUID()
        let captureRun = UUID()
        center.bind(to: owner)
        center.recordOwnerRun(conversationID: owner, runID: captureRun)
        let port = BrowserPageCapturePort(environment: environment)

        // Owner has no page yet: fail closed.
        await #expect(throws: (any Error).self) {
            _ = try await port.capturePage(conversationID: owner, runID: captureRun)
        }

        // Load the owner's own page, then switch the visible panel away.
        let session = try #require(center.session(for: owner))
        let tab = try #require(session.activeTabID)
        let webView = try #require(session.tabs.first(where: { $0.id == tab })?.webView)
        webView.loadHTMLString(
            "<!doctype html><html><body style=\"margin:0\"><p>owner-capture-page</p></body></html>",
            baseURL: URL(string: "https://example.com/\(UUID().uuidString)")
        )
        _ = try await center.execute(
            BrowserCommand(sessionID: session.sessionID, tabID: tab, action: .wait(.load)),
            in: owner
        )
        center.bind(to: visibleTask)

        // Capture succeeds even though another task's (empty) panel is
        // visible: it reads only the requesting owner's session. The locator
        // snapshot carries the owner's real page URL (OCR regions would need a
        // screenshot; the url/title/viewport fields are the ownership proof).
        let captured = try await port.capturePage(conversationID: owner, runID: captureRun)
        let json = String(decoding: captured.snapshotJSON, as: UTF8.self)
        #expect(json.contains("example.com"))

        // A stale run identity of the same task is refused rather than
        // silently attached to the newest run.
        await #expect(throws: (any Error).self) {
            _ = try await port.capturePage(conversationID: owner, runID: UUID())
        }
        // A foreign task's capture is refused even though it is now visible.
        await #expect(throws: (any Error).self) {
            _ = try await port.capturePage(conversationID: visibleTask, runID: nil)
        }
    }
}
#endif
