// FloeBrowserTests — deterministic doubles for the portable browser module.
// Authored (job-9960651880854093) but NOT executed in this source lane;
// Main's unified G04 cohort runs them (host-runnable: no UIKit, no WebKit,
// no networking, no device).

import Foundation
import FloeCore
@testable import FloeBrowser

// MARK: - Renderer double

actor FakeRenderer: BrowserRenderer {
    enum Mode: Sendable {
        case scripted                       // canned JSON per expression kind
        case neverAnswerEvaluations         // drives the timeout fence
        case unavailable                    // throws .unavailable everywhere
    }

    var mode: Mode = .scripted
    var createdTabs: [UUID] = []
    var destroyedTabs: [UUID] = []
    var navigations: [(tabID: UUID, url: String)] = []
    var reloads: [UUID] = []
    var backForwards: [(tabID: UUID, direction: String)] = []
    var stops: [UUID] = []
    var evaluations: [(tabID: UUID, expression: String)] = []
    var released = false

    var tabStates: [UUID: BrowserRendererTabState] = [:]
    var snapshotJSON = #"{"revision":3,"viewportWidth":1280,"viewportHeight":800,"nodes":[],"nextCursor":null}"#
    var statusJSON = #"{"readyState":"complete","selectorFound":false,"textFound":false,"idleMilliseconds":900,"revision":3}"#
    var performStatus = "ok"
    var screenshotBytes = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 7, count: 512)
    var screenshotPixels = (width: 1280, height: 800)
    var lastProbeSource = ""
    nonisolated(unsafe) var evaluateDelayNanoseconds: UInt64 = 0

    // MARK: protocol

    func createTab(tabID: UUID, probeSource: String) async throws {
        switch mode {
        case .unavailable: throw BrowserRendererError.unavailable
        case .scripted, .neverAnswerEvaluations:
            createdTabs.append(tabID)
            lastProbeSource = probeSource
            tabStates[tabID] = BrowserRendererTabState(url: nil, title: nil, isLoading: false)
        }
    }

    func destroyTab(tabID: UUID) async {
        destroyedTabs.append(tabID)
        tabStates[tabID] = nil
    }

    func navigate(tabID: UUID, url: URL) async throws {
        switch mode {
        case .unavailable: throw BrowserRendererError.unavailable
        default:
            navigations.append((tabID, url.absoluteString))
            tabStates[tabID] = BrowserRendererTabState(url: url.absoluteString, title: "Page", isLoading: false)
        }
    }

    func goBack(tabID: UUID) async throws { backForwards.append((tabID, "back")) }
    func goForward(tabID: UUID) async throws { backForwards.append((tabID, "forward")) }
    func reload(tabID: UUID) async throws { reloads.append(tabID) }
    func stopLoading(tabID: UUID) async { stops.append(tabID) }

    func state(tabID: UUID) async throws -> BrowserRendererTabState {
        if mode == .unavailable { throw BrowserRendererError.unavailable }
        guard let value = tabStates[tabID] else {
            throw BrowserRendererError.failed("unknown tab \(tabID)")
        }
        return value
    }

    func evaluate(tabID: UUID, expression: String, timeoutMilliseconds: Int) async throws -> String {
        if mode == .unavailable { throw BrowserRendererError.unavailable }
        if mode == .neverAnswerEvaluations {
            // Simulates an uncooperative page-world callback: never returns.
            try? await Task.sleep(nanoseconds: UInt64(max(timeoutMilliseconds, 1) + 5_000) * 1_000_000)
            throw BrowserRendererError.timedOut
        }
        evaluations.append((tabID, expression))
        if evaluateDelayNanoseconds > 0, expression.contains("p.perform(") {
            try? await Task.sleep(nanoseconds: evaluateDelayNanoseconds)
        }
        if expression.contains("p.snapshot(") { return snapshotJSON }
        if expression.contains("p.status(") { return statusJSON }
        if expression.contains("p.drainEvents(") { return "[]" }
        if expression.contains("p.perform(") { return #"{"status":"\#(performStatus)"}"# }
        if expression.contains("scrollBy") { return "'ok'" }
        return "{}"
    }

    func captureScreenshot(tabID: UUID) async throws -> BrowserScreenshotData {
        if mode == .unavailable { throw BrowserRendererError.unavailable }
        guard let value = tabStates[tabID] else { throw BrowserRendererError.failed("unknown tab") }
        return BrowserScreenshotData(
            jpeg: screenshotBytes,
            pixelWidth: screenshotPixels.width,
            pixelHeight: screenshotPixels.height,
            state: value
        )
    }

    func release() async { released = true }

    // MARK: test helpers

    func setEvaluateDelay(_ nanoseconds: UInt64) {
        evaluateDelayNanoseconds = nanoseconds
    }

    func setSnapshot(_ json: String) { snapshotJSON = json }

    func setTabState(_ tabID: UUID, url: String?, title: String? = "Page", loading: Bool = false) {
        tabStates[tabID] = BrowserRendererTabState(url: url, title: title, isLoading: loading)
    }

    func nodes(_ nodesJSON: String, nextCursor: Int?) {
        snapshotJSON = #"{"revision":5,"viewportWidth":1280,"viewportHeight":800,"nodes":\#(nodesJSON),"nextCursor":\#(nextCursor.map(String.init) ?? "null")}"#
    }
}

// MARK: - Preview transport double

actor FakePreviewTransport: BrowserPreviewTransport {
    var starts: [(lease: BrowserPreviewLeaseRequest, port: Int)] = []
    var stops: [UUID] = []
    var nextPort = 21_000
    var startDelayNanoseconds: UInt64 = 0
    var failStarts = false

    func start(lease: BrowserPreviewLeaseRequest) async throws -> BrowserPreviewEndpoint {
        if startDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: startDelayNanoseconds)
        }
        if failStarts { throw BrowserPreviewTransportError.startFailed("synthetic bind failure") }
        let port = nextPort
        nextPort += 1
        starts.append((lease, port))
        return BrowserPreviewEndpoint(port: port)
    }

    func stop(leaseID: UUID) async {
        stops.append(leaseID)
    }
}

// MARK: - Preview resource double (native path authority emulation)

actor FakePreviewResource: PreviewResourcePort {
    /// joined workspace-relative paths -> bytes
    var files: [String: Data] = [:]
    /// existing directories (joined paths; "" is the workspace root)
    var directories: Set<String> = [""]
    var escapeNames: Set<String> = []

    private func joined(_ root: PreviewWorkspaceRoot, _ relativePath: String) -> String {
        let base = root.relativeRoot.replacingOccurrences(of: "/", with: "")
        if base.isEmpty { return relativePath == "." || relativePath.isEmpty ? "" : relativePath }
        if relativePath == "." || relativePath.isEmpty { return base }
        return base + "/" + relativePath
    }

    func seed(body: String, at joinedPath: String) { files[joinedPath] = Data(body.utf8) }
    func seed(_ joinedPath: String, _ bytes: Data) { files[joinedPath] = bytes }
    func markEscape(_ joinedPath: String) { escapeNames.insert(joinedPath) }
    func addDirectory(_ path: String) { directories.insert(path) }

    func isDirectory(_ root: PreviewWorkspaceRoot, relativePath: String) async throws -> Bool {
        directories.contains(joined(root, relativePath))
    }

    func stat(_ root: PreviewWorkspaceRoot, relativePath: String) async throws -> PreviewResourceInfo? {
        guard let data = files[joined(root, relativePath)] else { return nil }
        return PreviewResourceInfo(byteCount: data.count)
    }

    func read(_ root: PreviewWorkspaceRoot, relativePath: String, offset: Int, length: Int) async throws -> Data {
        let path = joined(root, relativePath)
        if escapeNames.contains(path) {
            // Symlink-escape emulation: the NATIVE authority refuses.
            throw FakeResourceError.escape(path)
        }
        guard let data = files[path] else { return Data() }
        let start = min(offset, data.count)
        let end = min(start + length, data.count)
        return data[start..<end]
    }

    func listing(_ root: PreviewWorkspaceRoot, relativePath: String) async throws -> [String] {
        let base = joined(root, relativePath)
        return files.keys.compactMap { key in
            if base.isEmpty { return key.contains("/") ? nil : key }
            guard key.hasPrefix(base + "/") else { return nil }
            let rest = String(key.dropFirst(base.count + 1))
            return rest.contains("/") ? nil : rest
        }
    }
}

enum FakeResourceError: Error { case escape(String) }

// MARK: - Download sink double

actor FakeDownloadSink: BrowserDownloadSinkPort {
    struct Staged { var bytes = Data(); var handle: String }
    var staged: [String: Data] = [:]
    var openCount = 0
    var committed: [(handle: String, sha256: String, bytes: Int, receipt: BrowserDownloadReceipt)] = []
    var discarded: [String] = []
    var failCommit = false

    func open(ticket: BrowserDownloadTicket) async throws -> String {
        openCount += 1
        let handle = "staged-\(ticket.id.uuidString)"
        staged[handle] = Data()
        return handle
    }

    func append(handle: String, bytes: Data) async throws {
        staged[handle, default: Data()].append(bytes)
    }

    func commit(handle: String, sha256: String, expectedBytes: Int) async throws -> BrowserDownloadReceipt {
        if failCommit { throw BrowserDownloadError.sinkFailed("refused") }
        guard let bytes = staged[handle] else { throw BrowserDownloadError.unknownTicket }
        // Verification proof: the sink independently re-hashes the staged
        // bytes and compares against the coordinator digest. A coordinator
        // that hashed different bytes than the sink stored cannot commit.
        let digest = FloeDigest.sha256Hex(bytes)
        guard digest == sha256.lowercased(), bytes.count == expectedBytes else {
            throw BrowserDownloadError.sinkFailed("hash/size mismatch")
        }
        staged.removeValue(forKey: handle)
        let receipt = BrowserDownloadReceipt(
            relativePath: "BrowserDownloads/committed-\(handle)",
            byteCount: bytes.count,
            sha256: digest
        )
        committed.append((handle, sha256, expectedBytes, receipt))
        return receipt
    }

    func discard(handle: String) async {
        discarded.append(handle)
        staged.removeValue(forKey: handle)
    }

    func stagedCount() -> Int { staged.count }
}

// MARK: - Center harness

struct BrowserTestHarness {
    let center: BrowserSessionCenter
    let policy: BrowserURLPolicy
    let renderer: FakeRenderer
    let directory: URL

    static func make(
        durableHandoffs: Bool = false,
        maximumSessions: Int = 128,
        maximumOwnerFences: Int = 512,
        deliverHandoff: (@Sendable (BrowserHandoff, Bool) async throws -> Bool)? = nil,
        ownerAuthority: (@Sendable (BrowserOwnerID) async -> Bool)? = nil,
        projectionUpdate: (@Sendable (BrowserProjection) -> Void)? = nil
    ) -> BrowserTestHarness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-browser-tests-\(UUID().uuidString)", isDirectory: true)
        let renderer = FakeRenderer()
        let policy = BrowserURLPolicy()
        let center = BrowserSessionCenter(
            configuration: BrowserCenterConfiguration(
                artifactsDirectory: root.appendingPathComponent("Artifacts", isDirectory: true),
                receiptsDirectory: root.appendingPathComponent("Receipts", isDirectory: true),
                maximumSessions: maximumSessions,
                maximumOwnerFences: maximumOwnerFences,
                durableHandoffs: durableHandoffs
            ),
            rendererFactory: { _ in renderer },
            policy: policy,
            visualText: { _, _, _ in [] },
            deliverHandoff: deliverHandoff,
            ownerReleaseHook: nil,
            projectionUpdate: projectionUpdate ?? { _ in },
            ownerAuthority: ownerAuthority
        )
        return BrowserTestHarness(center: center, policy: policy, renderer: renderer, directory: root)
    }

    static func owner(task: UUID = UUID(), workspace: UUID = UUID(), epoch: UInt64 = 7) -> BrowserOwnerID {
        BrowserOwnerID(taskID: task, workspaceID: workspace, rootEpoch: epoch)
    }

    func teardown() {
        try? FileManager.default.removeItem(at: directory)
    }
}

func makeNavigatedSession(
    harness: BrowserTestHarness,
    owner: BrowserOwnerID
) async throws -> (BrowserTaskSession, UUID) {
    let session = try await harness.center.taskSession(for: owner)
    let sessionID = await session.sessionID
    let tabs = await session.tabSnapshots()
    let tabID = tabs.first!.id
    _ = await harness.center.execute(
        BrowserCommand(sessionID: sessionID, tabID: tabID, action: .navigate(url: "https://example.test/feed")),
        in: owner
    )
    await harness.center.ingress(.loadStarted(tabID: tabID))
    await harness.center.ingress(.loadCommitted(tabID: tabID))
    await harness.center.ingress(.loadFinished(tabID: tabID, url: "https://example.test/feed", title: "Feed"))
    return (session, sessionID)
}
