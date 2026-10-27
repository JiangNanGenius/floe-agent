// SPDX-License-Identifier: MPL-2.0
//
// IDE web-service terminal: pure policy and ownership tests.
//
// These exercise the production `IDEServiceRunPolicy`/`IDEServiceRunTerminalSession`
// against durable-job-shaped values and an injected source. No database,
// Linux guest, network, Simulator UI or browser is touched.
//
// Coverage:
//   * the browser action is enabled only for the exact owned, live, ready job;
//   * starting / not-ready / stopping / stopped / failed states stay closed;
//   * a URL printed in stdout is never promoted to a navigable endpoint;
//   * the chosen port and page path are preserved verbatim;
//   * a stale cross-workspace/task/environment refresh cannot rebind the
//     terminal;
//   * observing/closing never cancels; Stop cancels exactly the bound job;
//   * a click re-resolves a restarted live job and still passes the browser
//     authorization check.

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloePersistence
@testable import FloeApp

@Suite("FloeApp.IDERunWebPreview", .serialized)
@MainActor
struct IDERunWebPreviewTests {
    private let workspaceID = UUID()
    private let conversationID = UUID()
    private let environmentID = "test-environment"
    private let rootPath = "/tmp/floe-ide-web-preview"

    private func arguments(
        runtime: String = "static",
        entry: String = "web/index.html",
        cwd: String = "web",
        port: Int = 43123
    ) -> LocalServiceTool.Arguments {
        LocalServiceTool.Arguments(
            runtime: runtime, entry: entry, arguments: [], cwd: cwd, port: port
        )
    }

    private func makeJob(
        id: UUID = UUID(),
        state: BackgroundJobState = .running,
        conversationID: UUID? = nil,
        rootPath: String? = nil,
        environmentID: String? = nil,
        arguments: LocalServiceTool.Arguments? = nil,
        progress: LocalServiceProgress? = nil,
        lastError: String? = nil
    ) -> BackgroundJob {
        let payload = arguments ?? self.arguments()
        return BackgroundJob(
            id: id,
            conversationID: conversationID ?? self.conversationID,
            runID: UUID(),
            kind: .tool,
            targetTool: "exec.localService",
            payloadJSON: (try? JSONEncoder().encode(payload)) ?? Data(),
            state: state,
            progressJSON: progress.flatMap { try? JSONEncoder().encode($0) },
            lastError: lastError,
            workspaceRootPath: rootPath ?? self.rootPath,
            environmentID: environmentID ?? self.environmentID
        )
    }

    private func identity(
        workspaceID: UUID? = nil,
        rootPath: String? = nil,
        conversationID: UUID? = nil,
        environmentID: String? = nil,
        runtime: String = "static",
        entry: String = "web/index.html",
        cwd: String = "web",
        port: Int = 43123
    ) -> IDEServiceRunIdentity {
        IDEServiceRunIdentity(
            workspaceID: workspaceID ?? self.workspaceID,
            workspaceRootPath: rootPath ?? self.rootPath,
            conversationID: conversationID ?? self.conversationID,
            environmentID: environmentID ?? self.environmentID,
            runtime: runtime,
            entry: entry,
            cwd: cwd,
            port: port
        )
    }

    private func progress(
        state: String = "running",
        url: String? = "http://127.0.0.1:43123/web/index.html",
        stdout: String = "",
        stderr: String = ""
    ) -> LocalServiceProgress {
        LocalServiceProgress(
            state: state, runtime: "static", previewURL: url,
            stdout: stdout, stderr: stderr, truncated: false
        )
    }

    private func previewURL(for raw: String) -> URL? {
        let snapshot = progress(url: raw)
        return IDEServiceRunPolicy.previewURL(
            job: makeJob(progress: snapshot), identity: identity(), progress: snapshot
        )
    }

    // MARK: Identity

    @Test func identityIsCapturedFromTheDurableJobPayload() throws {
        let job = makeJob()
        let captured = try #require(
            IDEServiceRunPolicy.identity(for: job, workspaceID: workspaceID)
        )
        #expect(captured == identity())
        #expect(IDEServiceRunPolicy.matches(job, captured))
    }

    @Test func identityRejectsJobsWithoutOwnershipOrAPayload() {
        var wrongTool = makeJob()
        wrongTool.targetTool = "exec.shell"
        #expect(IDEServiceRunPolicy.identity(for: wrongTool, workspaceID: workspaceID) == nil)

        var noEnvironment = makeJob()
        noEnvironment.environmentID = nil
        #expect(IDEServiceRunPolicy.identity(for: noEnvironment, workspaceID: workspaceID) == nil)

        var noRoot = makeJob()
        noRoot.workspaceRootPath = nil
        #expect(IDEServiceRunPolicy.identity(for: noRoot, workspaceID: workspaceID) == nil)

        var badPayload = makeJob()
        badPayload.payloadJSON = Data("not-json".utf8)
        #expect(IDEServiceRunPolicy.identity(for: badPayload, workspaceID: workspaceID) == nil)
    }

    // MARK: Ready / not ready

    @Test func readyKeepsTheExactChosenPageAndPort() {
        let job = makeJob(progress: progress())
        #expect(IDEServiceRunPolicy.phase(job: job, identity: identity())
            == .ready(URL(string: "http://127.0.0.1:43123/web/index.html")!))
    }

    @Test func startingAndNotReadyStatesKeepTheBrowserClosed() {
        let queued = makeJob(state: .queued, progress: nil)
        #expect(IDEServiceRunPolicy.phase(job: queued, identity: identity()) == .starting)

        let noProgress = makeJob(progress: nil)
        #expect(IDEServiceRunPolicy.phase(job: noProgress, identity: identity()) == .starting)

        let starting = makeJob(progress: progress(state: "starting", url: nil))
        #expect(IDEServiceRunPolicy.phase(job: starting, identity: identity()) == .starting)

        let noEndpoint = makeJob(progress: progress(state: "running", url: nil))
        #expect(IDEServiceRunPolicy.phase(job: noEndpoint, identity: identity()) == .starting)
    }

    @Test func aURLPrintedInLogsIsNeverPromotedToTheBrowser() {
        let logs = progress(
            state: "running", url: nil,
            stdout: "server listening on http://127.0.0.1:43123/web/index.html\n"
        )
        let job = makeJob(progress: logs)
        #expect(IDEServiceRunPolicy.phase(job: job, identity: identity()) == .starting)
        #expect(IDEServiceRunPolicy.previewURL(
            job: job, identity: identity(), progress: logs) == nil)
    }

    @Test func stoppingStoppedAndFailedStatesKeepTheBrowserClosed() {
        let stopRequested = makeJob(lastError: "Stop requested; waiting for exit")
        #expect(IDEServiceRunPolicy.phase(job: stopRequested, identity: identity()) == .stopping)

        let stopping = makeJob(progress: progress(state: "stopping", url: nil))
        #expect(IDEServiceRunPolicy.phase(job: stopping, identity: identity()) == .stopping)

        let stoppedProgress = makeJob(progress: progress(state: "stopped", url: nil))
        #expect(IDEServiceRunPolicy.phase(job: stoppedProgress, identity: identity()) == .stopped)

        let stoppedJob = makeJob(
            state: .cancelled, progress: progress(state: "stopped", url: nil)
        )
        #expect(IDEServiceRunPolicy.phase(job: stoppedJob, identity: identity()) == .stopped)

        let failedProgress = makeJob(progress: progress(state: "failed", url: nil))
        #expect(IDEServiceRunPolicy.phase(job: failedProgress, identity: identity()) == .failed)

        let failedJob = makeJob(state: .failed, progress: nil, lastError: "boom")
        #expect(IDEServiceRunPolicy.phase(job: failedJob, identity: identity()) == .failed)

        let interrupted = makeJob(state: .interrupted)
        #expect(IDEServiceRunPolicy.phase(job: interrupted, identity: identity()) == .failed)
    }

    // MARK: Identity isolation

    @Test func identityMismatchNeverOpensAnotherService() {
        let job = makeJob(progress: progress())
        #expect(IDEServiceRunPolicy.phase(
            job: job, identity: identity(conversationID: UUID())) == .identityMismatch)
        #expect(IDEServiceRunPolicy.phase(
            job: job, identity: identity(environmentID: "other-environment")) == .identityMismatch)
        #expect(IDEServiceRunPolicy.phase(
            job: job, identity: identity(rootPath: "/tmp/other-workspace")) == .identityMismatch)
        #expect(IDEServiceRunPolicy.phase(
            job: job, identity: identity(runtime: "node")) == .identityMismatch)
        #expect(IDEServiceRunPolicy.phase(
            job: job, identity: identity(entry: "other.html")) == .identityMismatch)
        #expect(IDEServiceRunPolicy.phase(
            job: job, identity: identity(cwd: ".")) == .identityMismatch)
        #expect(IDEServiceRunPolicy.phase(
            job: job, identity: identity(port: 43124)) == .identityMismatch)
    }

    @Test func previewURLIsLoopbackOnTheChosenPortOnly() {
        #expect(previewURL(for: "http://127.0.0.1:43123/web/index.html")
            == URL(string: "http://127.0.0.1:43123/web/index.html"))
        #expect(previewURL(for: "http://localhost:43123/web/index.html") == nil)
        #expect(previewURL(for: "https://127.0.0.1:43123/web/index.html") == nil)
        #expect(previewURL(for: "http://192.168.1.5:43123/web/index.html") == nil)
        #expect(previewURL(for: "http://127.0.0.1:43124/web/index.html") == nil)
        #expect(previewURL(for: "http://127.0.0.1/web/index.html") == nil)
        #expect(previewURL(for: "http://user:pass@127.0.0.1:43123/web/index.html") == nil)
    }

    @Test func launchAcceptanceRequiresThePinnedWorkspaceAndRoot() {
        let launch = IDEServiceRunLaunch(identity: identity(), job: makeJob(progress: progress()))
        let root = URL(fileURLWithPath: rootPath)
        #expect(IDEServiceRunPolicy.accepts(
            launch: launch, workspaceID: workspaceID, root: root,
            currentWorkspaceID: workspaceID, currentRootURL: root))
        #expect(!IDEServiceRunPolicy.accepts(
            launch: launch, workspaceID: workspaceID, root: root,
            currentWorkspaceID: UUID(), currentRootURL: root))
        #expect(!IDEServiceRunPolicy.accepts(
            launch: launch, workspaceID: workspaceID, root: URL(fileURLWithPath: "/tmp/other"),
            currentWorkspaceID: workspaceID, currentRootURL: root))
        let otherIdentity = identity(workspaceID: UUID())
        #expect(!IDEServiceRunPolicy.accepts(
            launch: IDEServiceRunLaunch(identity: otherIdentity, job: launch.job),
            workspaceID: workspaceID, root: root,
            currentWorkspaceID: workspaceID, currentRootURL: root))
    }

    // MARK: Session ownership

    @Test func observingNeverStopsAndStopCancelsOnlyTheBoundJob() async {
        let bound = makeJob(progress: progress())
        let unrelated = makeJob(id: UUID(), progress: progress())
        let source = FakeSource(job: bound, listed: [bound, unrelated])
        let session = IDEServiceRunTerminalSession(
            identity: identity(), initialJob: bound, source: source)

        await session.refresh()
        await session.refresh()
        #expect(source.cancelCalls.isEmpty, "refresh/observation must never cancel a service")
        #expect(session.canOpenBrowser)
        #expect(session.canStop)

        await session.stop()
        #expect(source.cancelCalls == [bound.id],
                "Stop must name exactly the bound durable job")
        #expect(session.phase == .stopping)
        #expect(!session.canOpenBrowser)
    }

    @Test func staleCrossWorkspaceRefreshCannotReplaceTheBoundJob() async {
        let bound = makeJob(progress: progress())
        let source = FakeSource(job: bound)
        let session = IDEServiceRunTerminalSession(
            identity: identity(), initialJob: bound, source: source)

        source.stored = makeJob(
            id: bound.id, conversationID: UUID(), progress: progress()
        )
        await session.refresh()

        #expect(session.phase == .identityMismatch)
        #expect(session.job.id == bound.id)
        #expect(session.job.conversationID == conversationID)
        #expect(!session.canOpenBrowser)
        #expect(!session.canStop)
    }

    @Test func clickResolutionFollowsOnlyALiveCurrentService() async {
        let url = URL(string: "http://127.0.0.1:43123/web/index.html")!
        let original = makeJob(
            state: .cancelled, progress: progress(state: "stopped", url: nil)
        )
        let restarted = makeJob(id: UUID(), progress: progress())
        let source = FakeSource(job: original, listed: [restarted, original])
        let session = IDEServiceRunTerminalSession(
            identity: identity(), initialJob: original, source: source)

        BrowserURLPolicy.revokeService(owner: original.id)
        BrowserURLPolicy.revokeService(owner: restarted.id)
        defer {
            BrowserURLPolicy.revokeService(owner: original.id)
            BrowserURLPolicy.revokeService(owner: restarted.id)
        }
        BrowserURLPolicy.authorizeService(
            url, owner: restarted.id, conversationID: conversationID
        )

        let target = await session.resolveBrowserTarget()
        #expect(target?.job.id == restarted.id)
        #expect(target?.url == url)
        #expect(session.job.id == restarted.id)
        #expect(session.canOpenBrowser)
    }

    @Test func browserClickIsRefusedWithoutCurrentAuthorization() async {
        let job = makeJob(progress: progress())
        let source = FakeSource(job: job)
        let session = IDEServiceRunTerminalSession(
            identity: identity(), initialJob: job, source: source)

        BrowserURLPolicy.revokeService(owner: job.id)
        let refused = await session.resolveBrowserTarget()
        #expect(refused == nil, "an unauthorized loopback endpoint must never acquire network authority")
        #expect(session.browserNotice != nil)
        #expect(session.job.id == job.id)

        let url = URL(string: "http://127.0.0.1:43123/web/index.html")!
        BrowserURLPolicy.authorizeService(
            url, owner: job.id, conversationID: conversationID
        )
        defer { BrowserURLPolicy.revokeService(owner: job.id) }
        let accepted = await session.resolveBrowserTarget()
        #expect(accepted?.url == url)
    }

    @Test func readyFailureAfterAPreviousReadyDisablesTheAction() async {
        let job = makeJob(progress: progress())
        let source = FakeSource(job: job)
        let session = IDEServiceRunTerminalSession(
            identity: identity(), initialJob: job, source: source)
        #expect(session.canOpenBrowser)

        source.stored.state = .failed
        source.stored.lastError = "The server exited"
        await session.refresh()
        #expect(session.phase == .failed)
        #expect(!session.canOpenBrowser)
        #expect(!session.canStop)
    }

    @Test func routeCarriesAServiceOnlyForTheWebServiceCase() {
        let job = makeJob(progress: progress())
        let source = FakeSource(job: job)
        let session = IDEServiceRunTerminalSession(
            identity: identity(), initialJob: job, source: source)

        #expect(IDERunTerminalRoute.scriptRun.serviceSession == nil)
        #expect(IDERunTerminalRoute.webService(session).serviceSession === session)
    }
}

/// In-memory source. It records cancellation IDs so ownership can be asserted
/// without a database, and it can return a different durable snapshot to model
/// a stale cross-workspace callback.
@MainActor
private final class FakeSource: IDEServiceRunTerminalSource {
    var stored: BackgroundJob
    var listed: [BackgroundJob]
    private(set) var cancelCalls: [UUID] = []

    init(job: BackgroundJob, listed: [BackgroundJob] = []) {
        self.stored = job
        self.listed = listed
    }

    func job(id: UUID) async throws -> BackgroundJob? {
        stored.id == id ? stored : nil
    }

    func jobs(conversationID: UUID) async throws -> [BackgroundJob] {
        listed
    }

    func cancel(id: UUID) async throws -> BackgroundJob {
        cancelCalls.append(id)
        guard stored.id == id else {
            throw FloeError.validationFailed("No stored service owns that job ID")
        }
        // Mirrors BackgroundJobService.cancel: a requested stop is not yet a
        // terminal result, so the browser stays closed while it drains.
        stored.lastError = "Stop requested; waiting for the native service to exit"
        return stored
    }
}
#endif
