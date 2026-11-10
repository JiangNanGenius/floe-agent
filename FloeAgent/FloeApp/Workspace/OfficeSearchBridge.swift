// SPDX-License-Identifier: MPL-2.0
#if canImport(WebKit)
import Foundation
import Combine
import WebKit

enum OfficeSearchText {
    /// Notes search offsets and the source cache both use UTF-16. Reject a
    /// stale/malformed range instead of finding a different phrase.
    static func phrase(in text: String, offset: Int, length: Int) -> String? {
        let source = text as NSString
        guard offset >= 0, length > 0, length <= 4096,
              offset <= source.length, length <= source.length - offset else { return nil }
        func bisectsSurrogatePair(_ boundary: Int) -> Bool {
            guard boundary > 0, boundary < source.length else { return false }
            return (0xD800...0xDBFF).contains(source.character(at: boundary - 1))
                && (0xDC00...0xDFFF).contains(source.character(at: boundary))
        }
        guard !bisectsSurrogatePair(offset), !bisectsSurrogatePair(offset + length) else { return nil }
        return source.substring(with: NSRange(location: offset, length: length))
    }
}

enum OfficeSearchFailure: Error, Sendable {
    case unavailable, timedOut, invalidReply
}

private struct OfficeSearchReply: Decodable, Sendable {
    let requestID: String
    let status: String
    let count: Int?
}

private final class OfficeSearchReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<OfficeSearchReply, any Error>?
    private var continuation: CheckedContinuation<OfficeSearchReply, any Error>?

    @discardableResult func finish(_ result: Result<OfficeSearchReply, any Error>) -> Bool {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return false }
        self.result = result
        let waiting = continuation; continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
        return true
    }
    func value() async throws -> OfficeSearchReply {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result) }
            else { self.continuation = continuation; lock.unlock() }
        }
    }
}

/// Read-only search in the existing mounted Office editor. One active request
/// and one latest queued request keep same-phrase Next/Previous events ordered.
/// Editing, original-file saves and autosave remain owned by OfficeFileSession.
@MainActor
final class OfficeSearchBridge: ObservableObject {
    enum Status: Equatable {
        case idle, searching, found, notFound, unavailable, timedOut
    }
    @Published private(set) var status: Status = .idle
    @Published private(set) var query = ""
    @Published private(set) var foundCount: Int?
    @Published private(set) var isSearching = false

    private struct Request {
        let id: UUID
        let query: String
        let backwards: Bool
        let useLastResult: Bool
    }
    private weak var webView: WKWebView?
    private var documentID: UUID?
    private var resourceID: UUID?
    private var generation: UInt64 = 0
    private var validatesOwner: (@MainActor () -> Bool)?
    private var activeID: UUID?
    private var latestID: UUID?
    private var pending: Request?
    private var task: Task<Void, Never>?
    private var quarantined = false
    private let timeout: Duration
    private let engineTimeoutMilliseconds: Int

    init(timeout: Duration = .seconds(5), engineTimeoutMilliseconds: Int = 4000) {
        self.timeout = min(.seconds(5), max(.milliseconds(1), timeout))
        self.engineTimeoutMilliseconds = min(4000, max(1, engineTimeoutMilliseconds))
    }

    func bind(documentID: UUID, resourceID: UUID?, webView: WKWebView,
              validatesOwner: @escaping @MainActor () -> Bool) {
        if self.documentID != documentID || self.resourceID != resourceID || self.webView !== webView {
            detach()
            self.documentID = documentID; self.resourceID = resourceID; self.webView = webView
        }
        self.validatesOwner = validatesOwner
    }

    func detach() {
        generation &+= 1
        task?.cancel(); task = nil
        pending = nil; activeID = nil; latestID = nil
        webView = nil; documentID = nil; resourceID = nil; validatesOwner = nil
        quarantined = false; foundCount = nil; status = .idle
        isSearching = false
    }

    func clearPresentation() {
        latestID = nil; pending = nil; foundCount = nil; query = ""
        status = quarantined ? .timedOut : .idle
    }

    func submit(_ phrase: String, backwards: Bool = false, useLastResult: Bool = false) {
        guard !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              phrase.utf16.count <= 4096, !quarantined,
              validatesOwner?() == true, let webView,
              webView.url?.isFileURL == true, webView.url?.lastPathComponent == "cool.html" else {
            status = quarantined ? .timedOut : .unavailable
            return
        }
        let request = Request(id: UUID(), query: phrase, backwards: backwards, useLastResult: useLastResult)
        query = phrase; foundCount = nil; status = .searching
        isSearching = true
        latestID = request.id
        pending = request // bounded: only the newest not-yet-started request
        startNextIfIdle()
    }

    private func startNextIfIdle() {
        guard activeID == nil, let request = pending, let webView, !quarantined else { return }
        pending = nil
        guard validatesOwner?() == true else { status = .idle; isSearching = false; return }
        let expected = generation
        activeID = request.id
        task = Task { @MainActor [self, weak webView] in
            guard let webView else { finish(request, generation: expected, result: .failure(OfficeSearchFailure.unavailable)); return }
            do {
                let reply = try await call(request, on: webView)
                finish(request, generation: expected, result: .success(reply))
            } catch { finish(request, generation: expected, result: .failure(error)) }
        }
    }

    private func finish(_ request: Request, generation expected: UInt64,
                        result: Result<OfficeSearchReply, any Error>) {
        guard generation == expected, activeID == request.id else { return }
        activeID = nil; task = nil
        guard validatesOwner?() == true else { pending = nil; status = .idle; isSearching = false; return }
        switch result {
        case .success(let reply):
            guard reply.requestID == request.id.uuidString else { pending = nil; status = .unavailable; isSearching = false; return }
            if reply.status == "timeout" {
                quarantine()
            } else if latestID == request.id {
                if reply.status == "result", let count = reply.count, count >= 0 {
                    foundCount = count; status = count == 0 ? .notFound : .found
                } else { status = .unavailable }
            }
        case .failure(let error):
            if error is CancellationError { pending = nil; status = .idle }
            else if case OfficeSearchFailure.timedOut = error { quarantine() }
            else if latestID == request.id { status = .unavailable }
        }
        isSearching = pending != nil
        startNextIfIdle()
    }

    private func quarantine() {
        // Collabora's event has the original phrase but no native request ID.
        // After an unacknowledged search, do not attach a new same-page query
        // to an ambiguous late engine result. Other Office actions stay usable.
        quarantined = true; pending = nil; foundCount = nil; status = .timedOut
    }

    private func call(_ request: Request, on webView: WKWebView) async throws -> OfficeSearchReply {
        let gate = OfficeSearchReplyGate()
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            gate.finish(.failure(OfficeSearchFailure.timedOut))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            webView.callAsyncJavaScript(Self.script, arguments: [
                "query": request.query, "backwards": request.backwards,
                "useLastResult": request.useLastResult, "requestID": request.id.uuidString,
                "timeoutMilliseconds": engineTimeoutMilliseconds
            ], in: nil, in: .page) { result in
                do {
                    let value = try result.get()
                    guard let text = value as? String, let data = text.data(using: .utf8), data.count <= 32768 else {
                        throw OfficeSearchFailure.invalidReply
                    }
                    gate.finish(.success(try JSONDecoder().decode(OfficeSearchReply.self, from: data)))
                } catch { gate.finish(.failure(error)) }
            }
            return try await gate.value()
        } onCancel: { gate.finish(.failure(CancellationError())) }
    }

    /// Fixed host code; query and ownership values always use WK arguments.
    /// This is the exact pinned SearchService API, not map.search or UNO edits.
    static let script = #"""
    const service = globalThis.app?.searchService;
    const map = globalThis.app?.map;
    if (!service || typeof service.search !== 'function' || !map ||
        typeof map.on !== 'function' || typeof map.off !== 'function') {
      return JSON.stringify({requestID, status:'unavailable'});
    }
    return await new Promise(resolve => {
      let settled = false;
      let timer;
      const finish = value => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        map.off('search', onSearch);
        resolve(JSON.stringify({requestID, ...value}));
      };
      const onSearch = event => {
        if (event?.originalPhrase !== query) return;
        const count = Number(event.count);
        if (!Number.isSafeInteger(count) || count < 0) return;
        finish({status:'result', count});
      };
      map.on('search', onSearch);
      timer = setTimeout(() => finish({status:'timeout'}), timeoutMilliseconds);
      try { service.search(query, backwards, '', 0, useLastResult); }
      catch (_) { finish({status:'unavailable'}); }
    });
    """#
}
#endif
