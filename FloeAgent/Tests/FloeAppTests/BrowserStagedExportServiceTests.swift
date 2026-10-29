// FloeAppTests — task-owned staged-export pull (`browser.exportFile`).
//
// Production-path tests for the staged-export contract: a native-issued
// fixed-script PULL of the page's own staged raster into an authorized
// workspace destination. Two layers, mirroring the Impeccable capture suite:
//
// 1. REAL integration — the session's own `stagedExports` service with the
//    real WebKit transport runs the real fixed script against a real
//    WKWebView page that stages a genuine PNG fixture, gated by the real
//    `BrowserURLPolicy` preview registry, committing through the real
//    exclusive-link path. The fixture registers its tokenized loopback
//    endpoint BEFORE loading, which is the real App order and a hard
//    requirement: the session's own navigation delegate cancels an
//    unregistered 127.0.0.1 load, so the document would stay `about:blank`
//    and no staged global could ever exist. Fixture readiness is a genuine
//    commit (`Page.loadEventFired` plus the bound URL), never WebKit's
//    synchronous provisional URL.
// 2. Lifecycle/ownership — a deterministic stub transport (the established
//    seam) mutates LIVE session state inside the handlers exactly like the
//    session hooks do (handoff, release, tab close, takeover), proving the
//    binding re-checks fence late work, remove staging bytes and never
//    commit; plus the bound matrix (caps before decode, checksum, PNG
//    structure, no-overwrite, one-in-flight).
//
// Page-push absence is asserted directly: no `floeExport` (or any) script
// message handler exists on task tabs, and the fixed script registers no
// page→native channel — an unsolicited page message has nowhere to go.
//
// They are not executed in the code-first stage. Run them at the unified App
// freeze together with the existing BrowserTaskSession/Impeccable suites.

#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import Foundation
import Testing
import CryptoKit
import UIKit
import WebKit
import FloeCore
import FloeTools
@testable import FloeApp

// MARK: - Real PNG fixture builders (valid CRC32 + stored-deflate zlib)

private func stagedExportCRC32(_ bytes: [UInt8]) -> UInt32 {
    var table: [UInt32] = []
    if table.isEmpty {
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
            }
            table.append(value)
        }
    }
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
        crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
}

private func stagedExportAdler32(_ bytes: [UInt8]) -> UInt32 {
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in bytes {
        a = (a + UInt32(byte)) % 65521
        b = (b + a) % 65521
    }
    return (b << 16) | a
}

/// Minimal valid zlib stream with stored deflate blocks (no compression).
private func stagedExportZlibStored(_ raw: [UInt8]) -> [UInt8] {
    var out: [UInt8] = [0x78, 0x01]
    var offset = 0
    while offset < raw.count || (offset == 0 && raw.isEmpty) {
        let length = min(65535, raw.count - offset)
        let isFinal = offset + length >= raw.count
        out.append(isFinal ? 0x01 : 0x00)
        out.append(UInt8(length & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(~length & 0xFF))
        out.append(UInt8((~length >> 8) & 0xFF))
        out.append(contentsOf: raw[offset..<offset + length])
        offset += length
        if raw.isEmpty { break }
    }
    let adler = stagedExportAdler32(raw)
    out.append(UInt8((adler >> 24) & 0xFF))
    out.append(UInt8((adler >> 16) & 0xFF))
    out.append(UInt8((adler >> 8) & 0xFF))
    out.append(UInt8(adler & 0xFF))
    return out
}

/// A genuinely valid 8-bit RGB non-interlaced PNG (passes a full CRC walk).
private func stagedExportPNG(width: Int, height: Int, pixel: [UInt8] = [0x11, 0x22, 0x33]) -> Data {
    func be32(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
    func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        var out = be32(data.count)
        let typeBytes = [UInt8](type.utf8)
        out.append(contentsOf: typeBytes)
        out.append(contentsOf: data)
        out.append(contentsOf: be32(Int(stagedExportCRC32(typeBytes + data))))
        return out
    }
    var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    var ihdr = be32(width) + be32(height)
    ihdr.append(contentsOf: [8, 2, 0, 0, 0])
    bytes.append(contentsOf: chunk("IHDR", ihdr))
    var raw: [UInt8] = []
    for _ in 0..<height {
        raw.append(0)
        for _ in 0..<width { raw.append(contentsOf: pixel) }
    }
    bytes.append(contentsOf: chunk("IDAT", stagedExportZlibStored(raw)))
    bytes.append(contentsOf: chunk("IEND", []))
    return Data(bytes)
}

private func stagedExportSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Session fixtures

private let stagedExportToken = String(repeating: "5f", count: 16) // 32 chars

@MainActor
private final class StagedExportSpyHost: BrowserTaskSessionHost {
    func browserSessionRequestedUserControl(_ session: BrowserTaskSession, reason: String) {}
}

private func stagedExportEndpoint(port: Int) -> URL {
    URL(string: "http://127.0.0.1:\(port)/\(stagedExportToken)/index.html")!
}

/// Page HTML that stages a REAL descriptor exactly like the reviewed
/// art/canvas packages do (`window.__posterExport` / `window.__artExport`).
private func stagedExportPageHTML(
    png: Data, name: String, width: Int, height: Int, source: String
) -> String {
    let dataURL = "data:image/png;base64," + png.base64EncodedString()
    let global = source == "art" ? "__artExport" : "__posterExport"
    let schema = source == "art" ? "" : "schema: \"floe.poster-export/1\", "
    return """
    <!doctype html><html><head><title>staged</title></head><body><p>staged export fixture</p>
    <script>
    window.\(global) = {\(schema)state: "staged", name: "\(name)", width: \(width), height: \(height),
      bytes: \(png.count), sha256: "\(stagedExportSHA256(png))", dataURL: "\(dataURL)", stagedAt: Date.now()};
    </script></body></html>
    """
}

@MainActor
private func makeStagedExportSession(
    port: Int,
    html: String? = nil,
    authorizeEndpoint: Bool = true,
    keepEndpointAuthorized: Bool = false
) async -> (session: BrowserTaskSession, tabID: UUID, endpoint: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FloeStagedExportTests-\(UUID().uuidString)", isDirectory: true)
    let configuration = BrowserTaskSessionConfiguration(
        protocolVersion: "FloeBrowser/test",
        contentWorld: WKContentWorld.world(name: "org.floeagent.browser.exporttests.\(UUID().uuidString)"),
        artifactDirectory: directory,
        maximumTabs: 2,
        maximumEventsPerTab: 32
    )
    let session = BrowserTaskSession(
        conversationID: UUID(),
        generation: 1,
        configuration: configuration,
        host: StagedExportSpyHost()
    )
    guard let tabID = session.createTab() else {
        Issue.record("test session could not create a tab")
        preconditionFailure("unreachable")
    }
    let endpoint = stagedExportEndpoint(port: port)
    if authorizeEndpoint {
        // The real App order: the preview allocation is registered BEFORE the
        // page is served and navigated. `BrowserTaskSession.decidePolicyFor`
        // runs the real `BrowserURLPolicy` on every navigation, and an
        // unregistered 127.0.0.1 endpoint is CANCELLED — measured on host
        // WebKit with this exact fixture shape: `decidePolicy -> .cancel`, no
        // `didCommit`/`didFinish`, `webView.url` back to nil, document
        // `about:blank`, `typeof window.__posterExport == "undefined"`.
        BrowserURLPolicy.authorizePreview(endpoint)
    }
    let page = html ?? "<!doctype html><html><head><title>t</title></head><body><p>offline</p></body></html>"
    session.tabs.first(where: { $0.id == tabID })?.webView.loadHTMLString(page, baseURL: endpoint)
    // Wait for the REAL commit. `loadHTMLString` sets `webView.url` to the base
    // URL synchronously — before the policy delegate has decided anything — so a
    // URL-equality wait alone breaks immediately and hides a cancelled load
    // (that masking is why three real-page cases below failed as an unexplained
    // "staged global never appeared"). `Page.loadEventFired` is appended by the
    // session's own `didFinish`, so it can only be present for a document that
    // genuinely committed and finished loading.
    _ = await waitStagedExportCommit(session, tabID: tabID, endpoint: endpoint)
    if authorizeEndpoint, !keepEndpointAuthorized {
        // Leave no global registry state behind. Swift Testing exposes no
        // teardown hook in this SDK, and none is needed: the entry exists only so
        // the session's own navigation policy lets the fixture page commit, and
        // the stub-transport cases inject their own `endpointAuthorizer`.
        // Revoking after the commit cannot un-commit the document. Callers that
        // export through the REAL registry gate pass
        // `keepEndpointAuthorized: true` and revoke in their own `defer`.
        BrowserURLPolicy.revokePreview(endpoint)
    }
    return (session, tabID, endpoint)
}

/// Bounded wait for a genuinely committed fixture document: the tab's committed
/// URL equals the endpoint AND the session recorded its own `didFinish` event.
@MainActor
private func waitStagedExportCommit(
    _ session: BrowserTaskSession,
    tabID: UUID,
    endpoint: URL,
    timeout: TimeInterval = 10
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let tab = session.tabs.first(where: { $0.id == tabID }),
           tab.webView.url?.absoluteString == endpoint.absoluteString,
           tab.events.contains(where: { $0.method == "Page.loadEventFired" }) {
            return true
        }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return false
}

/// The bound tab's actual native + in-page state, for an honest failure message
/// instead of a bare timeout. Test-only: it reuses the production
/// `BrowserProbeRequest` seam and reads nothing that a page could forge into
/// authority (it is diagnostic text on a failed expectation).
@MainActor
private func stagedExportFixtureDiagnostic(
    _ session: BrowserTaskSession, tabID: UUID
) async -> String {
    guard let tab = session.tabs.first(where: { $0.id == tabID }) else {
        return "tab is gone"
    }
    let methods = tab.events.map { $0.method }.joined(separator: ",")
    let native = "webView.url=\(tab.webView.url?.absoluteString ?? "nil") events=[\(methods)]"
    let probe = "(function(){try{return JSON.stringify({href:String(location.href),ready:String(document.readyState),poster:String(typeof window.__posterExport),art:String(typeof window.__artExport),secure:String(window.isSecureContext),subtle:String(typeof (window.crypto&&window.crypto.subtle)),bodyLen:String((document.body&&document.body.innerHTML||'').length)});}catch(e){return 'jsException:'+String(e);}})()"
    guard let value = try? await evaluateStagedJavaScript(tab.webView, probe),
          let text = value as? String else {
        return "\(native) inPage=<probe unavailable>"
    }
    return "\(native) inPage=\(text)"
}

/// Evaluates a fixed test expression in the bound tab and returns its real
/// value, routed through the production `BrowserProbeRequest` callback→
/// continuation seam (the same one `StagedExportWebKitTransport` uses for the
/// fixed read-back script).
///
/// WKWebView exposes two `evaluateJavaScript` overloads (iOS 27 SDK):
///   * `(_:in:contentWorld:) async throws -> Any?`
///   * `(_:in:in:completionHandler:)` whose handler DEFAULTS to nil and whose
///     return type is `Void`.
/// Calling it with the second `in:` label (`in: nil, in: .page`) binds the
/// completion-handler overload, so `try await` is a no-op on a `Void` call
/// (the compiler's "no async operations occur within await" warning) and the
/// awaited "value" is `()` — `value as? String`/`as? NSNumber` are always nil.
/// That was ONE real cause in this suite: the push-channel probe read `()` and
/// no staged global was ever observed. Passing an explicit `completionHandler:`
/// forces the callback overload and bridges the SDK `Any` back as JSON `Data`
/// across a `@Sendable` continuation exactly as production does, so no
/// non-Sendable `Any` crosses an actor boundary and the evaluated value is
/// returned faithfully.
///
/// It was NOT the whole story. The three real-page cases still failed after the
/// overload fix because their fixture page never committed at all: the endpoint
/// was registered in `BrowserURLPolicy` only AFTER the wait, so the session's
/// real navigation policy cancelled the loopback load and the document stayed
/// `about:blank` (proved by `unregisteredLoopbackEndpointNeverCommits` below and
/// by a host WebKit probe of the same fixture shape). The push-channel test
/// passed vacuously for the same reason — `window.webkit.messageHandlers.
/// floeExport` is absent in an empty document too — so it now requires a real
/// commit before asserting.
@MainActor
private func evaluateStagedJavaScript(
    _ webView: WKWebView,
    _ script: String,
    timeout: Duration = .seconds(10)
) async throws -> Any? {
    let probe = BrowserProbeRequest()
    let data = try await probe.run(
        deadline: ContinuousClock.now.advanced(by: timeout)
    ) { completion in
        webView.evaluateJavaScript(script, in: nil, in: .page, completionHandler: completion)
    }
    guard !data.isEmpty else { return nil }
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

/// Bounded wait until the page's staged global exists (inline script ran).
///
/// The probe asks for a STRING, the one bridge this suite has directly observed
/// working end to end (`noPagePushChannelExists`); a numeric answer is accepted
/// too so the wait never depends on one bridging style. On timeout it records
/// the tab's actual native and in-page state, so a future failure names its
/// cause instead of presenting as an unexplained 10 s poll.
@MainActor
private func waitStagedGlobal(
    _ session: BrowserTaskSession, tabID: UUID, global: String
) async -> Bool {
    guard let webView = session.tabs.first(where: { $0.id == tabID })?.webView else {
        Issue.record("staged-global wait found no bound tab")
        return false
    }
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        // Flatten the `try?`-over-`Any?` double optional so the probe result is
        // a clean `Any` downcast (no Optional-to-NSNumber cast ambiguity).
        if let value = (try? await evaluateStagedJavaScript(
            webView, "(window.\(global) ? '1' : '0')")) ?? nil {
            if (value as? String) == "1" { return true }
            if let number = value as? NSNumber, number.intValue == 1 { return true }
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    let diagnostic = await stagedExportFixtureDiagnostic(session, tabID: tabID)
    Issue.record("window.\(global) never appeared within 10s — actual state: \(diagnostic)")
    return false
}

private func makeStagedExportWorkspace() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FloeStagedExportWS-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("out", isDirectory: true),
        withIntermediateDirectories: true)
    return root
}

// MARK: - Stub transport (deterministic envelopes; real rules run)

@MainActor
private final class StubStagedExportTransport: StagedExportTransport {
    struct Staged {
        var source: String
        var name: String
        var width: Int
        var height: Int
        /// Bytes actually served as the staged data URL payload.
        var payload: Data
        /// Digest declared in the descriptor (may differ from payload to
        /// drive the mismatch gate).
        var declaredSHA256: String
        /// Declared byte count (may differ from payload to drive caps).
        var declaredBytes: Int?
        var state: String = "staged"
        var hasDataURL = true
    }
    var staged: Staged?
    /// Live-state mutations from inside the handlers — the same seam the
    /// Impeccable suite uses to drive real lifecycle transitions mid-call.
    var onDescriptor: (@MainActor () -> Void)?
    var onChunk: (@MainActor (Int) -> Void)?
    var overrideChunkTotalChars: Int?
    var overrideChunkData: String?
    var corruptNonce = false
    var corruptLocation = false
    var location: String = ""
    private(set) var descriptorCalls = 0
    private(set) var chunkCalls = 0
    private(set) var fencedExportIDs: [UUID] = []

    func call(
        arguments: [String: Any],
        in webView: WKWebView,
        exportID: UUID,
        deadline: ContinuousClock.Instant
    ) async throws -> [String: Any] {
        let nonce = corruptNonce ? "forged" : (arguments["nonce"] as? String ?? "")
        let loc = corruptLocation ? "http://127.0.0.1:1/forged/index.html" : location
        let op = arguments["op"] as? String ?? ""
        if op == "descriptor" {
            descriptorCalls += 1
            onDescriptor?()
            guard let staged, staged.state == "staged" else {
                return ["ok": false, "reason": staged == nil ? "no-staged-export" : "not-staged",
                        "nonce": nonce, "loc": loc]
            }
            return [
                "ok": true,
                "schema": StagedExportContract.descriptorSchema,
                "source": staged.source,
                "name": staged.name,
                "width": staged.width,
                "height": staged.height,
                "bytes": staged.declaredBytes ?? staged.payload.count,
                "sha256": staged.declaredSHA256,
                "hasDataURL": staged.hasDataURL,
                "nonce": nonce,
                "loc": loc,
            ]
        }
        if op == "chunk" {
            let index = (arguments["index"] as? NSNumber)?.intValue ?? -1
            let chars = (arguments["chars"] as? NSNumber)?.intValue ?? 0
            chunkCalls += 1
            onChunk?(index)
            guard let staged, staged.state == "staged", staged.hasDataURL else {
                return ["ok": false, "reason": "no-staged-data", "nonce": nonce, "loc": loc]
            }
            let base64 = staged.payload.base64EncodedString()
            let start = index * chars
            guard start >= 0, start < base64.count else {
                return ["ok": false, "reason": "index-past-end", "nonce": nonce, "loc": loc]
            }
            let end = min(start + chars, base64.count)
            let lower = base64.index(base64.startIndex, offsetBy: start)
            let upper = base64.index(base64.startIndex, offsetBy: end)
            return [
                "ok": true,
                "index": index,
                "total": overrideChunkTotalChars ?? base64.count,
                "data": overrideChunkData ?? String(base64[lower..<upper]),
                "nonce": nonce,
                "loc": loc,
            ]
        }
        return ["ok": false, "reason": "unknown-op", "nonce": nonce, "loc": loc]
    }

    func fenceInFlight(exportID: UUID, reason: String) {
        fencedExportIDs.append(exportID)
    }
}

/// Suspension box for the one-in-flight test.
@MainActor
private final class ExportSuspension {
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false
    func suspend() async {
        await withCheckedContinuation { continuation in
            if resumed { continuation.resume(); return }
            self.continuation = continuation
        }
    }
    func resume() {
        guard !resumed else { return }
        resumed = true
        continuation?.resume()
        continuation = nil
    }
}

// MARK: - Suite

@Suite("FloeApp.BrowserStagedExport", .serialized)
@MainActor
struct BrowserStagedExportServiceTests {

    // MARK: REAL integration (real script, real WebKit, real registry)

    @Test("Authorized real-page staged export commits the exact full bytes")
    func realPagePosterExportCommitsExactBytes() async throws {
        let png = stagedExportPNG(width: 2, height: 2)
        let (session, tabID, endpoint) = await makeStagedExportSession(
            port: 65101,
            html: stagedExportPageHTML(png: png, name: "poster-2x2.png", width: 2, height: 2, source: "poster"),
            keepEndpointAuthorized: true)
        defer {
            session.release()
            BrowserURLPolicy.revokePreview(endpoint)
        }
        try #require(await waitStagedExportCommit(session, tabID: tabID, endpoint: endpoint),
                     "the fixture document never committed at its authorized endpoint")
        try #require(await waitStagedGlobal(session, tabID: tabID, global: "__posterExport"))
        // The fixture registered this preview BEFORE the load — the real App
        // order — so the export gate reads a genuinely owned endpoint rather
        // than being satisfied by a page that never existed.
        let workspace = try makeStagedExportWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let destination = workspace.appendingPathComponent("out/poster-2x2.png")
        let receipt = try await session.stagedExports.export(
            BrowserStagedExportService.Request(
                tabID: tabID,
                workspaceRootURL: workspace,
                destinationURL: destination,
                relativePath: "out/poster-2x2.png",
                expectedWidth: 2,
                expectedHeight: 2),
            cancellation: CancellationToken())
        #expect(receipt.state == "delivered")
        #expect(receipt.source == "poster")
        #expect(receipt.bytes == png.count)
        #expect(receipt.sha256 == stagedExportSHA256(png))
        #expect(receipt.declaredSHA256Matched)
        #expect(receipt.width == 2 && receipt.height == 2)
        #expect(receipt.endpoint == endpoint.absoluteString)
        let committed = try Data(contentsOf: destination)
        #expect(committed == png)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: workspace.appendingPathComponent("out").path)
            .filter { $0.contains(".part") }
        #expect(leftovers.isEmpty)
        #expect(session.tabs.first(where: { $0.id == tabID })?.events
            .contains { $0.method == "Browser.exportDelivered" } == true)
    }

    @Test("Real-page art source stages and exports through __artExport")
    func realPageArtExportCommitsExactBytes() async throws {
        let png = stagedExportPNG(width: 3, height: 2, pixel: [0xAB, 0xCD, 0xEF])
        let (session, tabID, endpoint) = await makeStagedExportSession(
            port: 65102,
            html: stagedExportPageHTML(png: png, name: "seed-1-3x2.png", width: 3, height: 2, source: "art"),
            keepEndpointAuthorized: true)
        defer {
            session.release()
            BrowserURLPolicy.revokePreview(endpoint)
        }
        try #require(await waitStagedExportCommit(session, tabID: tabID, endpoint: endpoint),
                     "the fixture document never committed at its authorized endpoint")
        try #require(await waitStagedGlobal(session, tabID: tabID, global: "__artExport"))
        let workspace = try makeStagedExportWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let destination = workspace.appendingPathComponent("out/seed-1-3x2.png")
        let receipt = try await session.stagedExports.export(
            BrowserStagedExportService.Request(
                tabID: tabID,
                workspaceRootURL: workspace,
                destinationURL: destination,
                relativePath: "out/seed-1-3x2.png",
                expectedWidth: nil,
                expectedHeight: nil),
            cancellation: CancellationToken())
        #expect(receipt.source == "art")
        #expect(receipt.bytes == png.count)
        #expect(try Data(contentsOf: destination) == png)
    }

    @Test("An endpoint outside the owned preview registry is refused before any read-back")
    func unregisteredEndpointRefused() async throws {
        let png = stagedExportPNG(width: 2, height: 2)
        let (session, tabID, endpoint) = await makeStagedExportSession(
            port: 65103,
            html: stagedExportPageHTML(png: png, name: "x.png", width: 2, height: 2, source: "poster"),
            keepEndpointAuthorized: true)
        defer { session.release() }
        try #require(await waitStagedExportCommit(session, tabID: tabID, endpoint: endpoint),
                     "the fixture document never committed at its authorized endpoint")
        try #require(await waitStagedGlobal(session, tabID: tabID, global: "__posterExport"))
        // The fixture registered this endpoint so the page could load at all;
        // revoking it before the export makes the REGISTRY GATE the refusal —
        // not a missing document (the committed URL is still bound and non-nil,
        // so `export` reaches the authorization check rather than the
        // "no committed document" one).
        BrowserURLPolicy.revokePreview(endpoint)
        let workspace = try makeStagedExportWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        await #expect(throws: StagedExportError.self) {
            _ = try await session.stagedExports.export(
                BrowserStagedExportService.Request(
                    tabID: tabID,
                    workspaceRootURL: workspace,
                    destinationURL: workspace.appendingPathComponent("out/x.png"),
                    relativePath: "out/x.png",
                    expectedWidth: nil,
                    expectedHeight: nil),
                cancellation: CancellationToken())
        }
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent("out/x.png").path))
    }

    @Test("No page→native push channel exists: floeExport is not registered and the fixed script registers none")
    func noPagePushChannelExists() async throws {
        let (session, tabID, endpoint) = await makeStagedExportSession(port: 65104)
        defer { session.release() }
        // This assertion is only meaningful about a REAL committed document: an
        // empty `about:blank` has no `floeExport` handler either, so without
        // this require the test can pass vacuously (which is exactly what it did
        // while the fixture's loopback load was being cancelled).
        try #require(await waitStagedExportCommit(session, tabID: tabID, endpoint: endpoint),
                     "the fixture document never committed at its authorized endpoint")
        guard let webView = session.tabs.first(where: { $0.id == tabID })?.webView else {
            Issue.record("tab missing"); return
        }
        let value = try await evaluateStagedJavaScript(
            webView,
            "String(!!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.floeExport))")
        #expect((value as? String) == "false")
        // The fixed producer is a pure read-back: it must never install a
        // message handler or any page→native channel of its own.
        #expect(!StagedExportScript.source.contains("messageHandlers"))
        #expect(!StagedExportScript.source.contains("postMessage"))
        #expect(!StagedExportScript.source.contains("addEventListener"))
    }

    /// The actual cause of the three real-page failures, asserted in both
    /// directions so it can never silently come back: an endpoint that is not
    /// registered in `BrowserURLPolicy` never becomes a document, because the
    /// session's OWN navigation delegate cancels the loopback load. Registering
    /// the preview first — the real App order — makes the identical page commit
    /// and stage its descriptor, with no other change.
    @Test("An unregistered loopback endpoint never commits a document; registering it first does")
    func unregisteredLoopbackEndpointNeverCommits() async throws {
        let png = stagedExportPNG(width: 2, height: 2)
        let html = stagedExportPageHTML(
            png: png, name: "poster-2x2.png", width: 2, height: 2, source: "poster")
        let (session, tabID, endpoint) = await makeStagedExportSession(
            port: 65105, html: html, authorizeEndpoint: false)
        defer {
            session.release()
            BrowserURLPolicy.revokePreview(endpoint)
        }
        let committedUnauthorized = await waitStagedExportCommit(
            session, tabID: tabID, endpoint: endpoint, timeout: 2)
        #expect(!committedUnauthorized,
                "an unauthorized loopback endpoint must never commit a document")
        let tab = try #require(session.tabs.first(where: { $0.id == tabID }))
        #expect(!tab.events.contains(where: { $0.method == "Page.frameNavigated" }),
                "a cancelled load must not report a committed document")
        #expect(!tab.events.contains(where: { $0.method == "Page.loadEventFired" }),
                "a cancelled load must not report a finished load")
        let webView = tab.webView
        // In-page half of the proof. It tolerates "no evaluable document at
        // all", which is the same conclusion as `undefined`: a cancelled
        // loopback load leaves nothing that could hold a staged descriptor.
        let unauthorizedDiagnostic = await stagedExportFixtureDiagnostic(session, tabID: tabID)
        #expect(unauthorizedDiagnostic.contains("\"poster\":\"undefined\"")
                    || unauthorizedDiagnostic.contains("inPage=<probe unavailable>"),
                "the staged global cannot exist in a document that never committed — actual: \(unauthorizedDiagnostic)")

        // Same page, same endpoint, same tab: only the registry changes.
        BrowserURLPolicy.authorizePreview(endpoint)
        webView.loadHTMLString(html, baseURL: endpoint)
        try #require(await waitStagedExportCommit(session, tabID: tabID, endpoint: endpoint),
                     "the identical page must commit once its endpoint is registered")
        // This fixture's descriptor is synchronous and its sha256 is precomputed
        // natively, so the global exists the moment the document commits and
        // this wait returns on its first probe. It is asserted anyway: a future
        // fixture that stages asynchronously (for example computing the digest
        // with WebCrypto) must not let `didFinish` be mistaken for "staged".
        try #require(await waitStagedGlobal(session, tabID: tabID, global: "__posterExport"),
                     "the committed document must expose its staged descriptor")
        let authorizedState = try await evaluateStagedJavaScript(
            webView, "String(typeof window.__posterExport)")
        #expect((authorizedState as? String) == "object",
                "the staged descriptor must exist in the committed document, got \(String(describing: authorizedState))")
    }

    // MARK: Stub-transport lifecycle / ownership

    private func stubSetup(
        port: Int,
        payload: Data? = nil,
        declaredSHA: String? = nil
    ) async throws -> (BrowserTaskSession, UUID, BrowserStagedExportService, StubStagedExportTransport, URL, URL) {
        let png = payload ?? stagedExportPNG(width: 2, height: 2)
        let (session, tabID, _) = await makeStagedExportSession(port: port)
        let transport = StubStagedExportTransport()
        transport.location = session.tabs.first(where: { $0.id == tabID })?.webView.url?.absoluteString ?? ""
        transport.staged = StubStagedExportTransport.Staged(
            source: "poster", name: "fixture.png", width: 2, height: 2,
            payload: png,
            declaredSHA256: declaredSHA ?? stagedExportSHA256(png))
        let service = BrowserStagedExportService(
            session: session,
            transport: transport,
            endpointAuthorizer: { _, _ in true })
        let workspace = try makeStagedExportWorkspace()
        let destination = workspace.appendingPathComponent("out/fixture.png")
        return (session, tabID, service, transport, workspace, destination)
    }

    /// Builds one export request. The workspace root is passed explicitly
    /// because the anchored commit binds the guard-resolved destination to the
    /// authorized root; a fixture that omits it would hide that requirement.
    private func request(
        tabID: UUID,
        destination: URL,
        workspace: URL,
        relativePath: String = "out/fixture.png"
    ) -> BrowserStagedExportService.Request {
        BrowserStagedExportService.Request(
            tabID: tabID, workspaceRootURL: workspace, destinationURL: destination,
            relativePath: relativePath, expectedWidth: nil, expectedHeight: nil)
    }

    @Test("Document handoff during the pull fences and removes staging bytes")
    func handoffDuringExportFences() async throws {
        let (session, tabID, service, transport, workspace, destination) = try await stubSetup(port: 65111)
        defer { session.release(); try? FileManager.default.removeItem(at: workspace) }
        transport.onDescriptor = { session.invalidateDocumentsForHandoff() }
        do {
            _ = try await service.export(request(tabID: tabID, destination: destination, workspace: workspace),
                                         cancellation: CancellationToken())
            Issue.record("export must not survive a document handoff")
        } catch let error as StagedExportError {
            guard case .fenced = error else {
                Issue.record("expected a fenced refusal, got \(error)"); return
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: workspace.appendingPathComponent("out").path)
            .filter { $0.contains(".part") }
        #expect(leftovers.isEmpty)
    }

    @Test("Session release during the pull fences and cleans up")
    func releaseDuringExportFences() async throws {
        let (session, tabID, service, transport, workspace, destination) = try await stubSetup(port: 65112)
        defer { try? FileManager.default.removeItem(at: workspace) }
        transport.onDescriptor = { session.release() }
        do {
            _ = try await service.export(request(tabID: tabID, destination: destination, workspace: workspace),
                                         cancellation: CancellationToken())
            Issue.record("export must not survive a session release")
        } catch let error as StagedExportError {
            guard case .fenced = error else {
                Issue.record("expected a fenced refusal, got \(error)"); return
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: workspace.appendingPathComponent("out").path)
            .filter { $0.contains(".part") }
        #expect(leftovers.isEmpty)
    }

    @Test("Closing the bound tab during the pull fences and cleans up")
    func tabCloseDuringExportFences() async throws {
        let (session, tabID, service, transport, workspace, destination) = try await stubSetup(port: 65113)
        defer { session.release(); try? FileManager.default.removeItem(at: workspace) }
        // close() requires a second tab to exist.
        _ = session.createTab()
        transport.onDescriptor = { session.close(tabID) }
        do {
            _ = try await service.export(request(tabID: tabID, destination: destination, workspace: workspace),
                                         cancellation: CancellationToken())
            Issue.record("export must not survive the bound tab closing")
        } catch let error as StagedExportError {
            guard case .fenced = error else {
                Issue.record("expected a fenced refusal, got \(error)"); return
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: workspace.appendingPathComponent("out").path)
            .filter { $0.contains(".part") }
        #expect(leftovers.isEmpty)
    }

    @Test("User takeover during the pull fences and cleans up")
    func takeoverDuringExportFences() async throws {
        let (session, tabID, service, transport, workspace, destination) = try await stubSetup(port: 65114)
        defer { session.release(); try? FileManager.default.removeItem(at: workspace) }
        transport.onDescriptor = { session.setUserControlling(true) }
        do {
            _ = try await service.export(request(tabID: tabID, destination: destination, workspace: workspace),
                                         cancellation: CancellationToken())
            Issue.record("export must not survive a user takeover")
        } catch let error as StagedExportError {
            guard case .fenced = error else {
                Issue.record("expected a fenced refusal, got \(error)"); return
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("User control at issue time is refused before any read-back")
    func takeoverAtStartRefused() async throws {
        let (session, tabID, service, transport, workspace, destination) = try await stubSetup(port: 65115)
        defer { session.release(); try? FileManager.default.removeItem(at: workspace) }
        session.setUserControlling(true)
        await #expect(throws: StagedExportError.self) {
            _ = try await service.export(self.request(tabID: tabID, destination: destination, workspace: workspace),
                                         cancellation: CancellationToken())
        }
        #expect(transport.descriptorCalls == 0)
    }

    @Test("Endpoint authorization revoked mid-export fences")
    func endpointRevokedDuringExportFences() async throws {
        let png = stagedExportPNG(width: 2, height: 2)
        let (session, tabID, _) = await makeStagedExportSession(port: 65116)
        defer { session.release() }
        let transport = StubStagedExportTransport()
        transport.location = session.tabs.first(where: { $0.id == tabID })?.webView.url?.absoluteString ?? ""
        transport.staged = StubStagedExportTransport.Staged(
            source: "poster", name: "fixture.png", width: 2, height: 2,
            payload: png, declaredSHA256: stagedExportSHA256(png))
        let authorized = AuthorizationFlag()
        let service = BrowserStagedExportService(
            session: session, transport: transport,
            endpointAuthorizer: { _, _ in authorized.value })
        transport.onDescriptor = { authorized.value = false }
        let workspace = try makeStagedExportWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let destination = workspace.appendingPathComponent("out/fixture.png")
        do {
            _ = try await service.export(request(tabID: tabID, destination: destination, workspace: workspace),
                                         cancellation: CancellationToken())
            Issue.record("export must not survive endpoint revocation")
        } catch let error as StagedExportError {
            guard case .fenced = error else {
                Issue.record("expected a fenced refusal, got \(error)"); return
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    private final class AuthorizationFlag { var value = true }

    @Test("Cancellation mid-export aborts and removes the part file")
    func cancellationDuringExportCleansUp() async throws {
        let (session, tabID, service, transport, workspace, destination) = try await stubSetup(port: 65117)
        defer { session.release(); try? FileManager.default.removeItem(at: workspace) }
        let token = CancellationToken()
        transport.onDescriptor = { token.cancel() }
        do {
            _ = try await service.export(request(tabID: tabID, destination: destination, workspace: workspace),
                                         cancellation: token)
            Issue.record("cancelled export must not commit")
        } catch {
            // FloeError.cancelled from the token, or a fenced StagedExportError.
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: workspace.appendingPathComponent("out").path)
            .filter { $0.contains(".part") }
        #expect(leftovers.isEmpty)
    }

    // MARK: Stub-transport bound matrix

    @Test("An existing destination is refused before any read-back; nothing is overwritten")
    func existingDestinationRefused() async throws {
        let (session, tabID, service, transport, workspace, destination) = try await stubSetup(port: 65121)
        defer { session.release(); try? FileManager.default.removeItem(at: workspace) }
        let original = Data("existing user bytes".utf8)
        try original.write(to: destination)
        await #expect(throws: StagedExportError.self) {
            _ = try await service.export(self.request(tabID: tabID, destination: destination, workspace: workspace),
                                         cancellation: CancellationToken())
        }
        #expect(transport.descriptorCalls == 0)
        #expect(try Data(contentsOf: destination) == original)
    }

    @Test("An oversized declaration is rejected before any chunk is requested")
    func oversizeDeclarationRejectedBeforeChunks() async throws {
        let png = stagedExportPNG(width: 2, height: 2)
        let (session, tabID, service, transport, workspace, destination) = try await stubSetup(port: 65122, payload: png)
        defer { session.release(); try? FileManager.default.removeItem(at: workspace) }
        transport.staged?.declaredBytes = StagedExportContract.maxFileBytes + 1
        await #expect(throws: StagedExportError.self) {
            _ = try await service.export(self.request(tabID: tabID, destination: destination, workspace: workspace),
                                         cancellation: CancellationToken())
        }
        #expect(transport.chunkCalls == 0)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("A malformed declared sha256 is a rejection, never an optional field")
    func malformedSHARejected() async throws {
        let (session, tabID, service, transport, workspace, destination) = try await stubSetup(port: 65123)
        defer { session.release(); try? FileManager.default.removeItem(at: workspace) }
        for bad in ["", "DEADBEEF", String(repeating: "a", count: 65), String(repeating: "A", count: 64)] {
            transport.staged?.declaredSHA256 = bad
            await #expect(throws: StagedExportError.self) {
                _ = try await service.export(self.request(tabID: tabID, destination: destination, workspace: workspace),
                                             cancellation: CancellationToken())
            }
            #expect(transport.chunkCalls == 0)
        }
    }

    @Test("A digest mismatch between staged declaration and delivered bytes refuses the commit")
    func shaMismatchRefusesCommit() async throws {
        let png = stagedExportPNG(width: 2, height: 2)
        let other = stagedExportPNG(width: 2, height: 2, pixel: [0x44, 0x55, 0x66])
        let (session, tabID, service, _, workspace, destination) = try await stubSetup(
            port: 65124, payload: png, declaredSHA: stagedExportSHA256(other))
        defer { session.release(); try? FileManager.default.removeItem(at: workspace) }
        await #expect(throws: StagedExportError.self) {
            _ = try await service.export(self.request(tabID: tabID, destination: destination, workspace: workspace),
                                         cancellation: CancellationToken())
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: workspace.appendingPathComponent("out").path)
            .filter { $0.contains(".part") }
        #expect(leftovers.isEmpty)
    }

    @Test("Non-PNG bytes with a correct digest are refused by the structural contract")
    func nonPNGPayloadRefused() async throws {
        // Deterministic non-PNG junk. `$0 &* 7 &+ 3` exceeds 255 from $0 == 37
        // (37*7+3 == 262), so the failable `UInt8(_:)` trapped the whole test
        // run ("Not enough bits to represent the passed value", crash frames:
        // Collection.map → this closure). `truncatingIfNeeded` keeps the exact
        // same low-8-bit byte stream (still not a PNG signature) without the
        // trap, so the structural contract — not a fixture crash — refuses it.
        let junk = Data((0..<128).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        let (session, tabID, service, _, workspace, destination) = try await stubSetup(
            port: 65125, payload: junk, declaredSHA: stagedExportSHA256(junk))
        defer { session.release(); try? FileManager.default.removeItem(at: workspace) }
        await #expect(throws: StagedExportError.self) {
            _ = try await service.export(self.request(tabID: tabID, destination: destination, workspace: workspace),
                                         cancellation: CancellationToken())
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("Caller-expected dimensions are enforced against the staged descriptor")
    func expectedDimensionMismatchRejected() async throws {
        let (session, tabID, service, transport, workspace, destination) = try await stubSetup(port: 65126)
        defer { session.release(); try? FileManager.default.removeItem(at: workspace) }
        var strict = self.request(tabID: tabID, destination: destination, workspace: workspace)
        strict.expectedWidth = 1080
        strict.expectedHeight = 1350
        await #expect(throws: StagedExportError.self) {
            _ = try await service.export(strict, cancellation: CancellationToken())
        }
        #expect(transport.chunkCalls == 0)
    }

    @Test("A mid-stream payload length change is rejected")
    func midStreamTotalChangeRejected() async throws {
        let (session, tabID, service, transport, workspace, destination) = try await stubSetup(port: 65127)
        defer { session.release(); try? FileManager.default.removeItem(at: workspace) }
        transport.onChunk = { [weak transport] _ in
            transport?.overrideChunkTotalChars = -1
        }
        await #expect(throws: StagedExportError.self) {
            _ = try await service.export(self.request(tabID: tabID, destination: destination, workspace: workspace),
                                         cancellation: CancellationToken())
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("A chunk longer than the declared remaining payload is rejected before decode")
    func chunkOverrunRejected() async throws {
        // Declared 3 bytes → expected total 4 base64 chars; serve 8.
        let png = stagedExportPNG(width: 2, height: 2)
        let (session, tabID, service, transport, workspace, destination) = try await stubSetup(port: 65128, payload: png)
        defer { session.release(); try? FileManager.default.removeItem(at: workspace) }
        transport.staged?.declaredBytes = 3
        transport.overrideChunkData = String(repeating: "A", count: 8)
        await #expect(throws: StagedExportError.self) {
            _ = try await service.export(self.request(tabID: tabID, destination: destination, workspace: workspace),
                                         cancellation: CancellationToken())
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: Pre-decode byte-total bound — canonical base64 padding coverage
    //
    // The bound that decides "chunk would exceed the declared byte total before
    // decode" must equal the EXACT decoded size (chars/4*3 minus terminal '='
    // padding), not the unpadded chars/4*3. These drive `decodeChunk` directly
    // (pure contract, no WebKit, deterministic) across every byte remainder and
    // both genuine refusals, so the padding fix is pinned without a live page.

    @Test("decodeChunk accepts canonical base64 at every byte remainder (0, 1, 2 mod 3)")
    func decodeChunkAcceptsEveryBase64Remainder() {
        // n % 3 == 0 → no padding; == 1 → '=='; == 2 → '='. Each single-chunk
        // payload's exact decoded size equals its declared remaining budget, so
        // the pre-decode bound must accept and round-trip the bytes. The old
        // unpadded chars/4*3 over-estimated the '=='/'=' cases by 2/1 and wrongly
        // refused them — the real-page poster (82-byte) and art (88-byte) exports
        // and the concurrent test's first export all decode through this path.
        for n in [3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 82, 88] {
            let raw = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            let b64 = raw.base64EncodedString()
            let totalChars = b64.utf8.count
            #expect(totalChars == 4 * ((n + 2) / 3), "base64 length for \(n) bytes")
            #expect(totalChars % 4 == 0, "quantum multiple for \(n) bytes")
            let (data, rejections) = StagedExportValidation.decodeChunk(
                ["ok": true, "index": 0, "total": totalChars, "data": b64,
                 "nonce": "n", "loc": "L"],
                expectedNonce: "n", expectedLocation: "L", expectedIndex: 0,
                expectedTotalChars: totalChars, remainingBytes: n)
            #expect(rejections.isEmpty, "n=\(n) (mod3=\(n % 3)) refused: \(rejections)")
            #expect(data == raw, "n=\(n) did not round-trip")
        }
    }

    @Test("decodeChunk still refuses a chunk whose exact decoded size exceeds the remaining budget")
    func decodeChunkRefusesExactOvershoot() {
        // 6 bytes → 8 base64 chars, no padding → exact decoded bound 6. Declare
        // only 5 remaining: the padding-aware bound must STILL refuse before
        // decode, proving the fix narrowed the estimate without weakening the
        // over-declaration gate.
        let raw = Data([1, 2, 3, 4, 5, 6])
        let b64 = raw.base64EncodedString()
        #expect(!b64.hasSuffix("="), "fixture must be unpadded to isolate the bound")
        let (data, rejections) = StagedExportValidation.decodeChunk(
            ["ok": true, "index": 0, "total": b64.utf8.count, "data": b64,
             "nonce": "n", "loc": "L"],
            expectedNonce: "n", expectedLocation: "L", expectedIndex: 0,
            expectedTotalChars: b64.utf8.count, remainingBytes: 5)
        #expect(data == nil)
        #expect(rejections.contains("chunk would exceed the declared byte total before decode"))
    }

    @Test("decodeChunk refuses corrupt base64 padding as invalid, never a short decode")
    func decodeChunkRefusesCorruptPadding() {
        // '=' in a non-terminal position is not valid base64. The padding-aware
        // bound must not let it slip through as a smaller decode; the strict
        // Data(base64Encoded:) gate refuses it, so a forged/corrupt chunk stays a
        // rejection rather than silently truncated bytes.
        for corrupt in ["AA=A", "A=AA", "=AAA"] {
            let (data, rejections) = StagedExportValidation.decodeChunk(
                ["ok": true, "index": 0, "total": corrupt.utf8.count, "data": corrupt,
                 "nonce": "n", "loc": "L"],
                expectedNonce: "n", expectedLocation: "L", expectedIndex: 0,
                expectedTotalChars: corrupt.utf8.count, remainingBytes: 3)
            #expect(data == nil, "\(corrupt) must not decode")
            #expect(rejections.contains("chunk is not valid base64"), "\(corrupt): \(rejections)")
        }
    }

    @Test("decodeChunk refuses non-canonical base64 that a lenient decoder would shorten")
    func decodeChunkRefusesNonCanonicalBase64() {
        // The grammar alone cannot see non-zero padding BITS, and Darwin
        // Foundation swallows them: measured, `Data(base64Encoded: "AB==")`
        // returns 1 byte that re-encodes as "AA==", and "/x==" returns 1 byte
        // that re-encodes as "/w==". Without the canonical round-trip a forged
        // chunk would commit DIFFERENT bytes than the page sent, under a digest
        // computed from those substituted bytes. Both must stay refusals.
        for nonCanonical in ["AB==", "/x==", "Ah=="] {
            #expect(StagedExportValidation.isCanonicalBase64Grammar(nonCanonical),
                    "\(nonCanonical) is grammatical; only the round-trip can see its bits")
            #expect(Data(base64Encoded: nonCanonical) != nil,
                    "\(nonCanonical) must really be a Foundation-accepted input for this to be a gate")
            let (data, rejections) = StagedExportValidation.decodeChunk(
                ["ok": true, "index": 0, "total": nonCanonical.utf8.count, "data": nonCanonical,
                 "nonce": "n", "loc": "L"],
                expectedNonce: "n", expectedLocation: "L", expectedIndex: 0,
                expectedTotalChars: nonCanonical.utf8.count, remainingBytes: 3)
            #expect(data == nil, "\(nonCanonical) must not decode")
            #expect(rejections.contains("chunk is not valid base64"), "\(nonCanonical): \(rejections)")
        }
        // The gate is a tightening only: every canonical encoding of the same
        // byte count still round-trips, so a genuine `btoa`/`toDataURL` payload
        // is never refused by it.
        for canonical in ["AA==", "AAA=", "AAAA", "/w==", "QUJDRA=="] {
            let raw = Data(base64Encoded: canonical)
            #expect(raw != nil, "\(canonical) must be a canonical Foundation input")
            let (data, rejections) = StagedExportValidation.decodeChunk(
                ["ok": true, "index": 0, "total": canonical.utf8.count, "data": canonical,
                 "nonce": "n", "loc": "L"],
                expectedNonce: "n", expectedLocation: "L", expectedIndex: 0,
                expectedTotalChars: canonical.utf8.count, remainingBytes: 4)
            #expect(data == raw, "\(canonical) must still decode: \(rejections)")
            #expect(rejections.isEmpty, "\(canonical): \(rejections)")
        }
    }

    @Test("Forged nonce or location echoes are rejected")
    func forgedIdentityEchoRejected() async throws {
        let (session, tabID, service, transport, workspace, destination) = try await stubSetup(port: 65129)
        defer { session.release(); try? FileManager.default.removeItem(at: workspace) }
        transport.corruptNonce = true
        await #expect(throws: StagedExportError.self) {
            _ = try await service.export(self.request(tabID: tabID, destination: destination, workspace: workspace),
                                         cancellation: CancellationToken())
        }
        transport.corruptNonce = false
        transport.corruptLocation = true
        await #expect(throws: StagedExportError.self) {
            _ = try await service.export(self.request(tabID: tabID, destination: destination, workspace: workspace),
                                         cancellation: CancellationToken())
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("One export at a time per task session")
    func concurrentExportRefused() async throws {
        let (session, tabID, service, transport, workspace, destination) = try await stubSetup(port: 65130)
        defer { session.release(); try? FileManager.default.removeItem(at: workspace) }
        _ = service // the gated service below drives this run
        let suspension = ExportSuspension()
        // The blocking transport parks the first export inside its chunk call
        // (registered in-flight), so the second export deterministically hits
        // the one-in-flight guard; the gate then releases the first to win.
        let blocking = BlockingTransport(inner: transport, gate: suspension)
        let blockingService = BrowserStagedExportService(
            session: session, transport: blocking,
            endpointAuthorizer: { _, _ in true })
        let first = Task {
            try await blockingService.export(self.request(tabID: tabID, destination: destination, workspace: workspace),
                                             cancellation: CancellationToken())
        }
        // Wait until the first export is inside its blocked chunk call.
        let deadline = Date().addingTimeInterval(5)
        while !blocking.isInsideCall, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try #require(blocking.isInsideCall)
        do {
            _ = try await blockingService.export(
                request(tabID: tabID,
                        destination: workspace.appendingPathComponent("out/second.png"),
                        workspace: workspace,
                        relativePath: "out/second.png"),
                cancellation: CancellationToken())
            Issue.record("a concurrent export must be refused")
        } catch let error as StagedExportError {
            guard case .rejected = error else {
                Issue.record("expected a rejected concurrent export, got \(error)"); return
            }
        }
        suspension.resume()
        let receipt = try await first.value
        #expect(receipt.state == "delivered")
    }

    // MARK: Registration and dispatch (catalog metadata is not an executable tool)

    /// A catalog descriptor with no runner is advertised but cannot execute: the
    /// runtime answers "No runner registered for tool". This drives the real
    /// registration entry point, the real type-erased runner and a real dispatch,
    /// so it fails on a registration that only added catalog metadata.
    @Test("browser.exportFile registers an executable runner that really dispatches")
    func exportStagedFileRegistersAnExecutableRunner() async throws {
        let center = BrowserSessionCenter(durableHandoffs: false)
        let registry = ToolRunnerRegistry()
        registerBrowserTools(center: center, registry: registry)

        let runner = try #require(
            registry.runner(named: "browser.exportFile"),
            "browser.exportFile must be executable, not only catalog metadata")
        #expect(runner.descriptor.name == "browser.exportFile")
        #expect(runner.descriptor.isSideEffecting)
        #expect(runner.descriptor.riskLabels.contains(.writesFiles))
        #expect(runner.descriptor.effect == .mutating)

        let context = ToolContext(
            runID: UUID(),
            scope: .local,
            cancellation: CancellationToken(),
            conversationID: UUID())

        // Real dispatch: the runner decodes the arguments and reaches this tool's
        // own destination validation, which refuses an absolute path.
        do {
            _ = try await runner.execute(
                argumentsJSON: Data(#"{"path":"/etc/hosts"}"#.utf8), context: context)
            Issue.record("an absolute destination must be refused by the tool itself")
        } catch let error as FloeError {
            #expect("\(error)".contains("workspace-relative"),
                    "dispatch must reach the tool's own validation, got \(error)")
        }

        // A missing required argument fails in this runner's own decoder, which
        // proves the declared schema belongs to the dispatched tool.
        do {
            _ = try await runner.execute(argumentsJSON: Data("{}".utf8), context: context)
            Issue.record("a missing destination must be refused")
        } catch let error as FloeError {
            #expect("\(error)".contains("path"), "got \(error)")
        }

        // A workspace-relative but non-PNG destination is refused by the same
        // validation before any page read, still through the registered runner.
        do {
            _ = try await runner.execute(
                argumentsJSON: Data(#"{"path":"out/art.txt"}"#.utf8), context: context)
            Issue.record("a non-PNG destination must be refused")
        } catch let error as FloeError {
            #expect("\(error)".contains(".png"), "got \(error)")
        }
    }

    /// Discovery must reflect what can actually execute: every browser tool the
    /// catalog advertises has to have a runner in the same registration pass.
    @Test("every advertised browser tool has an executable runner")
    func browserCatalogAndRunnersStayInSync() throws {
        let center = BrowserSessionCenter(durableHandoffs: false)
        let registry = ToolRunnerRegistry()
        registerBrowserTools(center: center, registry: registry)
        let advertised = Set(ToolCatalog.allDescriptors.map(\.name)).filter { $0.hasPrefix("browser.") }
        let executable = Set(registry.allDescriptors.map(\.name)).filter { $0.hasPrefix("browser.") }
        #expect(advertised.contains("browser.exportFile"))
        #expect(executable.contains("browser.exportFile"))
        let catalogOnly = advertised.subtracting(executable)
        #expect(catalogOnly.isEmpty,
                "catalog-only browser tools can never execute: \(catalogOnly.sorted())")
    }

    /// Transport that parks one designated call on a gate, marking presence.
    @MainActor
    private final class BlockingTransport: StagedExportTransport {
        let inner: StubStagedExportTransport
        let gate: ExportSuspension
        private var blockedOnce = false
        private(set) var isInsideCall = false
        init(inner: StubStagedExportTransport, gate: ExportSuspension) {
            self.inner = inner
            self.gate = gate
        }
        func call(
            arguments: [String: Any],
            in webView: WKWebView,
            exportID: UUID,
            deadline: ContinuousClock.Instant
        ) async throws -> [String: Any] {
            let op = arguments["op"] as? String ?? ""
            if op == "chunk", !blockedOnce {
                blockedOnce = true
                isInsideCall = true
                await gate.suspend()
                isInsideCall = false
            }
            return try await inner.call(arguments: arguments, in: webView,
                                        exportID: exportID, deadline: deadline)
        }
        func fenceInFlight(exportID: UUID, reason: String) {
            inner.fenceInFlight(exportID: exportID, reason: reason)
        }
    }
}
#endif
