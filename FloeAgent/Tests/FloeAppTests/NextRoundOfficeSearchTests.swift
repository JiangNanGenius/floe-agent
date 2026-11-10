#if canImport(WebKit)
import Foundation
import Testing
import WebKit
#if os(macOS)
import AppKit
#endif
@testable import FloeApp

private enum OfficeSearchQualificationError: Error { case deadline }

@MainActor private final class OfficeSearchOwner {
    var current = true
}

@MainActor private struct OfficeSearchFixture {
    let directory: URL
    let webView: WKWebView
    init() async throws {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        let base = ProcessInfo.processInfo.environment["FLOE_RQ09_FIXTURE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("cool.html")
        try Self.html.write(to: file, atomically: true, encoding: .utf8)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.loadFileURL(file, allowingReadAccessTo: directory)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while webView.isLoading || webView.url == nil {
            guard ContinuousClock.now < deadline else { throw OfficeSearchQualificationError.deadline }
            try await Task.sleep(for: .milliseconds(5))
        }
        let ready = try await webView.evaluateJavaScript("Boolean(globalThis.app?.searchService)") as? Bool
        guard ready == true else { throw OfficeSearchQualificationError.deadline }
    }
    func close() {
        webView.stopLoading()
        try? FileManager.default.removeItem(at: directory)
    }
    func calls() async throws -> [[String: Any]] {
        let text = try await webView.evaluateJavaScript("JSON.stringify(globalThis.calls)") as! String
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [[String: Any]]
    }
    static let html = #"""
    <!doctype html><meta charset="utf-8"><script>
    globalThis.calls=[];globalThis.edits=0;const listeners=new Set();
    globalThis.app={map:{on(name,callback){listeners.add(callback)},off(name,callback){listeners.delete(callback)}},
      searchService:{search(query,backwards,replacement,command,useLastResult){
        calls.push({query,backwards,replacement,command,useLastResult});
        if(query==='never')return;
        const send=()=>{for(const callback of [...listeners])callback({originalPhrase:query,count:query==='absent'?0:1})};
        for(const callback of [...listeners])callback({originalPhrase:'unrelated',count:123});
        setTimeout(send,query==='slow'?80:5);
      }}};
    </script>
    """#
}

@Suite("RQ09 mounted Office search bridge", .serialized)
@MainActor
struct NextRoundOfficeSearchTests {
    private func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw OfficeSearchQualificationError.deadline }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("UTF16 search focus uses the exact phrase and refuses invalid or split-surrogate ranges")
    func exactPhraseFromUTF16Range() {
        let text = "前😀查找后"
        #expect(OfficeSearchText.phrase(in: text, offset: 3, length: 2) == "查找")
        #expect(OfficeSearchText.phrase(in: text, offset: 1, length: 2) == "😀")
        #expect(OfficeSearchText.phrase(in: text, offset: 2, length: 1) == nil)
        #expect(OfficeSearchText.phrase(in: text, offset: -1, length: 1) == nil)
        #expect(OfficeSearchText.phrase(in: text, offset: Int.max, length: 1) == nil)
    }

    @Test("Literal queries use structured WK arguments and the pinned read-only five-argument service")
    func literalQueryAndNavigationContract() async throws {
        let fixture = try await OfficeSearchFixture(), bridge = OfficeSearchBridge()
        defer { bridge.detach(); fixture.close() }
        bridge.bind(documentID: UUID(), resourceID: UUID(), webView: fixture.webView) { true }
        let query = "中文 \"quote\" \\ \n </script>"
        bridge.submit(query)
        try await until { !bridge.isSearching }
        #expect(bridge.status == .found)
        bridge.submit(query, backwards: true, useLastResult: true)
        try await until { !bridge.isSearching }
        let calls = try await fixture.calls()
        #expect(calls.count == 2)
        #expect(calls[0]["query"] as? String == query)
        #expect(calls[0]["replacement"] as? String == "")
        #expect(calls[0]["command"] as? Int == 0)
        #expect(calls[0]["useLastResult"] as? Bool == false)
        #expect(calls[1]["backwards"] as? Bool == true)
        #expect(calls[1]["useLastResult"] as? Bool == true)
        #expect(try await fixture.webView.evaluateJavaScript("globalThis.edits") as? Int == 0)
    }

    @Test("A native count zero is real not-found; an unrelated search event is ignored")
    func zeroIsNotFound() async throws {
        let fixture = try await OfficeSearchFixture(), bridge = OfficeSearchBridge()
        defer { bridge.detach(); fixture.close() }
        bridge.bind(documentID: UUID(), resourceID: nil, webView: fixture.webView) { true }
        bridge.submit("absent")
        try await until { !bridge.isSearching }
        #expect(bridge.status == .notFound)
        #expect(bridge.foundCount == 0)
    }

    @Test("Searches remain serial with only the latest queued request; superseded results cannot publish")
    func latestQueuedSearchIsBounded() async throws {
        let fixture = try await OfficeSearchFixture(), bridge = OfficeSearchBridge()
        defer { bridge.detach(); fixture.close() }
        bridge.bind(documentID: UUID(), resourceID: nil, webView: fixture.webView) { true }
        bridge.submit("slow")
        bridge.submit("superseded")
        bridge.submit("current")
        try await until { !bridge.isSearching }
        let calls = try await fixture.calls()
        #expect(calls.compactMap { $0["query"] as? String } == ["slow", "current"])
        #expect(bridge.query == "current")
        #expect(bridge.status == .found)
    }

    @Test("A detached/replaced document cannot receive its old search result")
    func ownerReplacementFencesOldResult() async throws {
        let old = try await OfficeSearchFixture(), current = try await OfficeSearchFixture()
        let bridge = OfficeSearchBridge()
        defer { bridge.detach(); old.close(); current.close() }
        bridge.bind(documentID: UUID(), resourceID: nil, webView: old.webView) { true }
        bridge.submit("slow")
        bridge.bind(documentID: UUID(), resourceID: nil, webView: current.webView) { true }
        bridge.submit("current")
        try await until { !bridge.isSearching }
        try await Task.sleep(for: .milliseconds(100))
        #expect(bridge.query == "current")
        #expect(bridge.status == .found)
    }

    @Test("Lost visible ownership drops the result and closes the busy state")
    func visibilityLossDropsResult() async throws {
        let fixture = try await OfficeSearchFixture(), bridge = OfficeSearchBridge(), owner = OfficeSearchOwner()
        defer { bridge.detach(); fixture.close() }
        bridge.bind(documentID: UUID(), resourceID: nil, webView: fixture.webView) { owner.current }
        bridge.submit("slow")
        owner.current = false
        try await until { !bridge.isSearching }
        #expect(bridge.status == .idle)
        #expect(bridge.foundCount == nil)
    }

    @Test("No engine reply ends as timeout, never not-found/success or an ambiguous new same-page query")
    func timeoutIsFailureAndRequiresFreshBinding() async throws {
        let fixture = try await OfficeSearchFixture()
        let bridge = OfficeSearchBridge(timeout: .milliseconds(100), engineTimeoutMilliseconds: 50)
        defer { bridge.detach(); fixture.close() }
        bridge.bind(documentID: UUID(), resourceID: nil, webView: fixture.webView) { true }
        bridge.submit("never")
        try await until { !bridge.isSearching }
        #expect(bridge.status == .timedOut)
        #expect(bridge.foundCount == nil)
        bridge.submit("current")
        #expect(bridge.status == .timedOut)
        #expect(try await fixture.calls().count == 1)
    }
}
#endif
