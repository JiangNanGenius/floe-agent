// FloeApp — public-API bridge for this task's browser cookies, storage and
// website-data records.
//
// Scope is deliberately narrow:
//  * cookies for the active tab's origin through WKHTTPCookieStore, including
//    HttpOnly cookies (attributes are read through HTTPCookie's public API);
//  * localStorage/sessionStorage for the exact tab and origin through a fixed
//    script in the browser's isolated content world (no arbitrary JS);
//  * website-data records through WKWebsiteDataStore (metadata only, never
//    cache bodies), and deletion through the public record API.
//
// No Safari store, Keychain item, private WebKit database or raw cookie file
// is read. Cookie values are secrets: callers must ask for them explicitly,
// and ordinary logs/persistence hold only names, counts and attributes.

#if canImport(SwiftUI) && canImport(WebKit)
import Foundation
import WebKit
import FloeCore
import FloeExecution

struct BrowserCookieRecord: Codable, Sendable, Identifiable, Hashable {
    var name: String
    var value: String?
    var valueLength: Int
    var domain: String
    var path: String
    var expiresAt: Date?
    var isSecure: Bool
    var isHTTPOnly: Bool
    var isSessionOnly: Bool
    var sameSite: String?

    var id: String { "\(domain)|\(path)|\(name)" }

    init(snapshot: HTTPCookieSnapshot, includeValue: Bool) {
        self.name = snapshot.name
        self.value = includeValue ? snapshot.value : nil
        self.valueLength = snapshot.value.utf8.count
        self.domain = snapshot.domain
        self.path = snapshot.path
        self.expiresAt = snapshot.expiresAt
        self.isSecure = snapshot.isSecure
        self.isHTTPOnly = snapshot.isHTTPOnly
        self.isSessionOnly = snapshot.isSessionOnly
        self.sameSite = snapshot.sameSite
    }
}

enum BrowserStorageKind: String, Codable, CaseIterable, Sendable {
    case local
    case session
}

struct BrowserStorageEntry: Codable, Sendable, Hashable {
    var key: String
    var value: String?
    var valueLength: Int
}

struct BrowserStoragePage: Codable, Sendable {
    var kind: BrowserStorageKind
    var origin: String
    var entries: [BrowserStorageEntry]
    var totalKeys: Int
    var truncated: Bool
}

struct BrowserSiteDataGroup: Codable, Sendable, Identifiable, Hashable {
    var displayName: String
    var dataTypes: [String]

    var id: String { displayName }
}

enum BrowserWebDataError: Error, LocalizedError {
    case noActivePage
    case originMismatch
    case storageUnavailable
    case valueTooLarge
    case keyTooLarge
    case invalidCookie(String)
    case stale
    case contextChanged

    var errorDescription: String? {
        switch self {
        case .noActivePage: "Open a page in this task's browser first"
        case .originMismatch: "Storage access is limited to the active tab's exact origin"
        case .storageUnavailable: "This page did not expose local or session storage"
        case .valueTooLarge: "Storage value exceeds the 16 KiB browser-tool limit"
        case .keyTooLarge: "Storage key exceeds the 512-byte browser-tool limit"
        case .invalidCookie(let detail): "Invalid cookie: \(detail)"
        case .stale: "The browser privacy mode changed; the stale session-data result was discarded"
        case .contextChanged: "The browser page changed during the operation; the result was discarded"
        }
    }
}

@MainActor
final class BrowserWebDataBridge {
    private weak var session: BrowserTaskSession?

    init(session: BrowserTaskSession) {
        self.session = session
    }

    private var liveSession: BrowserTaskSession {
        get throws {
            guard let session, !session.isReleased else {
                throw BrowserWebDataError.noActivePage
            }
            return session
        }
    }

    private func assertStillCurrent() throws {
        guard let session, !session.isReleased else {
            throw BrowserWebDataError.stale
        }
    }

    nonisolated static func originURL(of url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        return components.url
    }

    /// WKWebView's `location.origin` omits a default port. The expected origin
    /// given to the fixed storage script must use the same serialization, so
    /// the in-page guard compares real values rather than two spellings.
    nonisolated static func scriptOrigin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        if let port = url.port, port != defaultPort {
            components.port = port
        }
        return components.string
    }

    /// Exact tab + origin + document identity captured before an await. The
    /// tab object itself is re-read after every WebKit await; a closed tab,
    /// a different origin or a replaced document is refused instead of
    /// combining old metadata with the new page's storage/cookies.
    private struct TabContext {
        let tabID: UUID
        let webView: WKWebView
        let origin: URL
        let scriptOrigin: String
        let documentGeneration: Int
    }

    private func captureContext(tabID: UUID?) throws -> TabContext {
        let session = try liveSession
        guard let selected = tabID ?? session.activeTabID,
              let tab = session.tabs.first(where: { $0.id == selected }) else {
            throw BrowserWebDataError.noActivePage
        }
        guard let origin = Self.originURL(of: tab.webView.url),
              let scriptOrigin = Self.scriptOrigin(of: origin) else {
            throw BrowserWebDataError.noActivePage
        }
        return TabContext(
            tabID: tab.id,
            webView: tab.webView,
            origin: origin,
            scriptOrigin: scriptOrigin,
            documentGeneration: tab.documentGeneration
        )
    }

    @discardableResult
    private func revalidate(
        _ context: TabContext,
        requireSameDocument: Bool
    ) throws -> BrowserTaskSession.Tab {
        try assertStillCurrent()
        guard let session else { throw BrowserWebDataError.stale }
        guard let tab = session.tabs.first(where: { $0.id == context.tabID }) else {
            throw BrowserWebDataError.stale
        }
        guard let origin = Self.originURL(of: tab.webView.url),
              HTTPCookiePolicy.sameOrigin(origin, context.origin) else {
            throw BrowserWebDataError.contextChanged
        }
        if requireSameDocument, tab.documentGeneration != context.documentGeneration {
            throw BrowserWebDataError.contextChanged
        }
        return tab
    }

    // MARK: - Cookies

    func cookies(tabID: UUID?, includeValues: Bool) async throws -> [BrowserCookieRecord] {
        let context = try captureContext(tabID: tabID)
        let store = context.webView.configuration.websiteDataStore
        let cookies = await store.httpCookieStore.allCookies()
        // The tab may have navigated while WebKit enumerated the store. A
        // different origin means the old match set is not this page's data.
        _ = try revalidate(context, requireSameDocument: false)
        let snapshots = cookies.map(HTTPCookiePolicy.snapshot(from:))
        let matching = snapshots.filter { HTTPCookiePolicy.domainMatches($0, for: context.origin) }
        return matching
            .map { BrowserCookieRecord(snapshot: $0, includeValue: includeValues) }
            .sorted { ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name) }
    }

    @discardableResult
    func setCookie(
        tabID: UUID?,
        input: HTTPCookieInput
    ) async throws -> BrowserCookieRecord {
        let context = try captureContext(tabID: tabID)
        let origin = context.origin
        let expires = input.expiresAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        let snapshot = HTTPCookieSnapshot(
            name: input.name,
            value: input.value,
            domain: input.domain ?? origin.host ?? "",
            path: input.path ?? "/",
            expiresAt: expires,
            isSecure: input.secure ?? (origin.scheme?.lowercased() == "https"),
            isHTTPOnly: input.httpOnly ?? true,
            isSessionOnly: expires == nil,
            sameSite: input.sameSite
        )
        let validated: HTTPCookieSnapshot
        do {
            validated = try HTTPCookiePolicy.validatedForSetting(snapshot, for: origin)
        } catch {
            throw BrowserWebDataError.invalidCookie(error.localizedDescription)
        }
        guard let cookie = HTTPCookiePolicy.httpCookie(from: validated) else {
            throw BrowserWebDataError.invalidCookie("The cookie attributes could not be represented")
        }
        await context.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        _ = try revalidate(context, requireSameDocument: false)
        return BrowserCookieRecord(snapshot: validated, includeValue: false)
    }

    /// Deletes cookies matching the optional attributes. Returns the number
    /// deleted, never any value.
    @discardableResult
    func deleteCookies(
        tabID: UUID?,
        name: String?,
        domain: String?,
        path: String?
    ) async throws -> Int {
        let context = try captureContext(tabID: tabID)
        let store = context.webView.configuration.websiteDataStore.httpCookieStore
        let all = await store.allCookies()
        _ = try revalidate(context, requireSameDocument: false)
        var deleted = 0
        for cookie in all {
            let matched = HTTPCookiePolicy.snapshot(from: cookie)
            guard HTTPCookiePolicy.domainMatches(matched, for: context.origin) else { continue }
            if let name, matched.name != name { continue }
            if let domain, matched.domain.lowercased() != domain.lowercased() { continue }
            if let path, matched.path != path { continue }
            // Re-check immediately before each mutation: a navigation during
            // the asynchronous delete loop must not continue deleting against
            // stale origin metadata.
            _ = try revalidate(context, requireSameDocument: false)
            await store.deleteCookie(cookie)
            deleted += 1
        }
        _ = try revalidate(context, requireSameDocument: false)
        return deleted
    }

    @discardableResult
    func clearCookies(tabID: UUID?) async throws -> Int {
        try await deleteCookies(tabID: tabID, name: nil, domain: nil, path: nil)
    }

    // MARK: - DOM storage

    func storage(
        tabID: UUID?,
        kind: BrowserStorageKind,
        requestedOrigin: String?,
        includeValues: Bool
    ) async throws -> BrowserStoragePage {
        let context = try captureContext(tabID: tabID)
        try assertOrigin(requestedOrigin, matches: context.origin)
        let dictionary = try await callStorage(
            context: context,
            operation: "list",
            kind: kind,
            includeValues: includeValues
        )
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        struct Response: Decodable {
            var entries: [BrowserStorageEntry]
            var totalKeys: Int
            var truncated: Bool
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return BrowserStoragePage(
            kind: kind,
            origin: HTTPCookiePolicy.origin(context.origin) ?? context.origin.absoluteString,
            entries: decoded.entries,
            totalKeys: decoded.totalKeys,
            truncated: decoded.truncated
        )
    }

    func storageValue(
        tabID: UUID?,
        kind: BrowserStorageKind,
        requestedOrigin: String?,
        key: String
    ) async throws -> String? {
        try validateKey(key)
        let context = try captureContext(tabID: tabID)
        try assertOrigin(requestedOrigin, matches: context.origin)
        let dictionary = try await callStorage(
            context: context,
            operation: "get",
            kind: kind,
            key: key
        )
        guard dictionary["found"] as? Bool == true else { return nil }
        guard let value = dictionary["value"] as? String else {
            throw BrowserWebDataError.storageUnavailable
        }
        return value
    }

    func setStorage(
        tabID: UUID?,
        kind: BrowserStorageKind,
        requestedOrigin: String?,
        key: String,
        value: String
    ) async throws {
        try validateKey(key)
        guard value.utf8.count <= 16 * 1_024 else { throw BrowserWebDataError.valueTooLarge }
        let context = try captureContext(tabID: tabID)
        try assertOrigin(requestedOrigin, matches: context.origin)
        _ = try await callStorage(
            context: context,
            operation: "set",
            kind: kind,
            key: key,
            value: value
        )
    }

    func deleteStorage(
        tabID: UUID?,
        kind: BrowserStorageKind,
        requestedOrigin: String?,
        key: String
    ) async throws {
        try validateKey(key)
        let context = try captureContext(tabID: tabID)
        try assertOrigin(requestedOrigin, matches: context.origin)
        _ = try await callStorage(
            context: context,
            operation: "delete",
            kind: kind,
            key: key
        )
    }

    func clearStorage(
        tabID: UUID?,
        kind: BrowserStorageKind,
        requestedOrigin: String?
    ) async throws {
        let context = try captureContext(tabID: tabID)
        try assertOrigin(requestedOrigin, matches: context.origin)
        _ = try await callStorage(
            context: context,
            operation: "clear",
            kind: kind
        )
    }

    private func validateKey(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 512,
              !key.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 || $0.value == 0x7f }) else {
            throw BrowserWebDataError.keyTooLarge
        }
    }

    private func assertOrigin(_ requested: String?, matches url: URL) throws {
        guard let requested, !requested.isEmpty else { return }
        guard let requestedURL = URL(string: requested),
              let left = HTTPCookiePolicy.origin(requestedURL),
              let right = HTTPCookiePolicy.origin(url),
              left == right else {
            throw BrowserWebDataError.originMismatch
        }
    }

    /// One fixed script for every storage operation. Caller/model data is
    /// passed only as arguments; no JavaScript source is assembled from
    /// caller input. The trusted expected origin is checked inside the page
    /// before any read or mutation, so a navigation between the native
    /// context capture and the script cannot touch the new origin's storage.
    ///
    /// Kept as a single constant so the focused Node check executes the exact
    /// production source rather than a copied approximation.
    private static let storageScript = #"""
    const floeOrigin = (() => {
      try { return String(location.origin); } catch (error) { return ''; }
    })();
    if (floeOrigin !== expectedOrigin) {
      return {status: 'origin-mismatch', origin: floeOrigin};
    }

    try {
      const storage = kind === 'local' ? localStorage : sessionStorage;
      const encoder = typeof TextEncoder === 'function' ? new TextEncoder() : null;
      const utf8Length = (text) => encoder ? encoder.encode(text).length : text.length;
      if (operation === 'list') {
        const wantsValues = includeValues === true;
        const entries = [];
        let total = 0;
        let omitted = false;
        const length = Number(storage.length) || 0;
        for (let index = 0; index < length && entries.length < 512; index += 1) {
          const key = storage.key(index);
          if (key === null) continue;
          const raw = storage.getItem(key);
          const text = raw === null ? '' : String(raw);
          const bytes = utf8Length(text);
          total += bytes;
          let value = null;
          if (wantsValues) {
            if (total <= 65536) {
              value = text.slice(0, 16384);
            } else {
              omitted = true;
            }
          }
          entries.push({
            key: String(key).slice(0, 512),
            value: value,
            valueLength: bytes
          });
        }
        return {
          status: 'ok',
          entries: entries,
          totalKeys: length,
          truncated: length > entries.length || omitted
        };
      }
      if (operation === 'get') {
        const raw = storage.getItem(key);
        if (raw === null) {
          return {status: 'ok', found: false, value: null, valueLength: 0};
        }
        const text = String(raw);
        return {
          status: 'ok',
          found: true,
          value: text.slice(0, 16384),
          valueLength: utf8Length(text)
        };
      }
      if (operation === 'set') {
        storage.setItem(key, value);
        return {status: 'ok'};
      }
      if (operation === 'delete') {
        storage.removeItem(key);
        return {status: 'ok'};
      }
      if (operation === 'clear') {
        storage.clear();
        return {status: 'ok'};
      }
      return {status: 'error', message: 'unsupported storage operation'};
    } catch (error) {
      return {status: 'error', message: String(error)};
    }
    """#

    private func callStorage(
        context: TabContext,
        operation: String,
        kind: BrowserStorageKind,
        key: String? = nil,
        value: String? = nil,
        includeValues: Bool = false
    ) async throws -> [String: Any] {
        let session = try liveSession
        var arguments: [String: Any] = [
            "operation": operation,
            "kind": kind.rawValue,
            "expectedOrigin": context.scriptOrigin,
            "includeValues": includeValues
        ]
        if let key { arguments["key"] = key }
        if let value { arguments["value"] = value }
        let result = try await context.webView.callAsyncJavaScript(
            Self.storageScript,
            arguments: arguments,
            in: nil,
            contentWorld: session.contentWorld
        )
        // WebKit's awaited call can outlive a navigation. Re-read the exact
        // tab, origin and document generation before accepting any result.
        _ = try revalidate(context, requireSameDocument: true)
        guard let dictionary = result as? [String: Any],
              let status = dictionary["status"] as? String else {
            throw BrowserWebDataError.storageUnavailable
        }
        switch status {
        case "ok":
            return dictionary
        case "origin-mismatch":
            throw BrowserWebDataError.contextChanged
        default:
            throw BrowserWebDataError.storageUnavailable
        }
    }

    // MARK: - Website data records

    static var allWebsiteDataTypes: Set<String> {
        WKWebsiteDataStore.allWebsiteDataTypes()
    }

    static func records(
        store: WKWebsiteDataStore,
        types: Set<String>? = nil
    ) async -> [BrowserSiteDataGroup] {
        let selected = types.map { Set($0.filter { allWebsiteDataTypes.contains($0) }) }
            ?? allWebsiteDataTypes
        let records = await store.dataRecords(ofTypes: selected)
        return records
            .map { BrowserSiteDataGroup(displayName: $0.displayName, dataTypes: $0.dataTypes.sorted()) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    @discardableResult
    static func deleteRecords(
        store: WKWebsiteDataStore,
        displayNames: Set<String>,
        types: Set<String>? = nil
    ) async -> Int {
        let selected = types.map { Set($0.filter { allWebsiteDataTypes.contains($0) }) }
            ?? allWebsiteDataTypes
        let records = await store.dataRecords(ofTypes: selected)
        var deleted = 0
        for record in records where displayNames.contains(record.displayName) {
            await store.removeData(ofTypes: record.dataTypes, for: [record])
            deleted += 1
        }
        return deleted
    }

    @discardableResult
    static func clearAll(store: WKWebsiteDataStore) async -> Int {
        let records = await store.dataRecords(ofTypes: allWebsiteDataTypes)
        await store.removeData(ofTypes: allWebsiteDataTypes, modifiedSince: .distantPast)
        return records.count
    }
}
#endif
