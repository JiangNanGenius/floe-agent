// SPDX-License-Identifier: MPL-2.0

import AppKit
import FloeMacToolbox
import Foundation
import WebKit

// FloeMacUnified — task-browser site memory.
//
// The Mac task browser is ephemeral by default: every session uses a
// non-persistent WKWebsiteDataStore, so cookies and website data vanish when
// the session is released and never leak across tasks. This feature adds the
// iPad-parity opt-in: the user may explicitly choose to REMEMBER one site.
// A remembered site gets its own dedicated, WebKit-managed persistent data
// store (`WKWebsiteDataStore(forIdentifier:)`), so:
//
//  * a remembered site's login survives an app relaunch (the store identifier
//    is persisted in the registry and reused);
//  * jars are per-origin — there is no hidden global cookie sharing, and one
//    remembered site's data never mixes with another site's;
//  * removing a remembered site wipes exactly that site's jar through public
//    WebKit APIs (all website-data types since the distant past plus every
//    cookie in the store's cookie jar);
//  * everything else — non-remembered sites, temporary chat, other apps'
//    browsing data — is untouched.
//
// The store for a tab is decided from the target origin of every main-frame
// navigation (address bar, page restore, model navigate, chat link, in-page
// clicks, redirects and popup loads): a navigation is only allowed to commit
// when the tab's web view already sits on that origin's jar, so a remembered
// jar can never follow the page into a different site and an ephemeral page
// never picks up a remembered jar. Because WebKit binds the data store at
// web-view creation, switching jars rebuilds that tab's web view and replays
// the exact request there (the document identity rotates like a control
// handoff; back/forward history does not carry across jars).
//
// Remembering is a user action surfaced by Settings (and, wired by Primary,
// by the browser chrome). Model tools can never enable it; secrets never
// enter the transcript: the registry keeps only the origin, a store UUID and
// timestamps, and the inventory reports counts and data-type names only.

/// One explicitly remembered site.
struct MacRememberedSite: Codable, Hashable, Identifiable, Sendable {
    /// Canonical origin `scheme://host[:port]` (lowercase host, default port
    /// omitted). This is the identity key; it is never a URL with credentials,
    /// path, query or fragment.
    let origin: String
    /// WebKit persistent data-store identifier for this site's jar.
    let storeID: UUID
    var addedAt: Date

    var id: String { origin }

    /// Human-facing label; the host portion of the origin.
    var displayName: String {
        origin.components(separatedBy: "://").last ?? origin
    }
}

/// Inventory of one remembered site. Metadata only: counts and data-type
/// names — never cookie values, cache bodies or page content.
struct MacRememberedSiteSummary: Identifiable, Sendable {
    let origin: String
    let displayName: String
    let addedAt: Date
    let cookieCount: Int
    let recordCount: Int
    let dataTypes: [String]

    var id: String { origin }
}

@MainActor
final class MacSiteMemoryRegistry: ObservableObject {
    nonisolated private static let recordLimit = 64
    nonisolated private static let archiveByteLimit = 256 * 1_024

    @Published private(set) var sites: [MacRememberedSite] = []

    private let directory: URL?
    private var storeCache: [String: WKWebsiteDataStore] = [:]
    private var deferredWrite: Task<Void, Never>?
    private var dirty = false
    /// Store identifiers whose wipe is in flight. Resolution returns nil for
    /// these across every await of the wipe, so a navigation replay or a
    /// late WebKit callback can never re-acquire a jar that is being
    /// emptied. Choices themselves stay until the wipe path removes them.
    private var wipingStoreIDs: Set<UUID> = []
    /// False when the persisted archive could not be read or validated. The
    /// registry is then unavailable: remembering stays disabled, the corrupt
    /// file is left untouched for recovery, and nothing silently replaces it
    /// with an empty list.
    private(set) var isAvailable = true

    /// - Parameter directory: injected by the host (construct-and-pass). When
    ///   nil the registry is memory-only and remembering stays disabled, so a
    ///   miswired build can never silently persist website data.
    init(directory: URL?) {
        self.directory = directory
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let archive = directory.appendingPathComponent("remembered-sites.json")
            guard let bytes = try Self.readFile(archive, limit: Self.archiveByteLimit) else { return }
            let decoded = try JSONDecoder().decode([MacRememberedSite].self, from: bytes)
            var merged: [String: MacRememberedSite] = [:]
            for site in decoded.prefix(Self.recordLimit * 4) where Self.canonicalOrigin(site.origin) != nil {
                if let existing = merged[site.origin], existing.addedAt >= site.addedAt { continue }
                merged[site.origin] = site
            }
            sites = merged.values
                .sorted { $0.addedAt < $1.addedAt }
                .prefix(Self.recordLimit)
                .map { $0 }
        } catch {
            // Unreadable or corrupt archive: site memory degrades to
            // unavailable instead of wiping, guessing, or serving an empty
            // registry over a real one. The file stays in place for recovery.
            sites = []
            isAvailable = false
        }
    }

    /// True when this registry can durably keep remember choices.
    var isPersistent: Bool { directory != nil && isAvailable }
    var canRememberMore: Bool { isPersistent && sites.count < Self.recordLimit }

    /// Called with the store identifiers that are about to be wiped, BEFORE
    /// any data is removed, so every live task session can detach its tabs
    /// from those jars. Set by the owning tools hub. A detached jar can never
    /// be repopulated by a page still sitting on it.
    var onJarsInvalidated: (@MainActor (Set<UUID>) -> Void)?

    /// Canonical origin of an allowed http(s) URL, or nil. Mirrors the iPad
    /// `scriptOrigin` serialization so a stored origin always matches what
    /// the page reports.
    nonisolated static func canonicalOrigin(_ url: URL) -> String? {
        guard MacBrowserAddress.allows(url),
              let scheme = url.scheme?.lowercased(),
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

    /// Canonical origin string for a raw stored value (validation on load).
    nonisolated private static func canonicalOrigin(_ raw: String) -> String? {
        guard let url = URL(string: raw) else { return nil }
        return canonicalOrigin(url)
    }

    // MARK: - Resolution

    /// The dedicated persistent jar for a remembered origin, or nil when the
    /// origin is not remembered (caller then stays ephemeral). Instances are
    /// cached so a tab's store identity compares by reference.
    func store(for url: URL) -> WKWebsiteDataStore? {
        guard let origin = Self.canonicalOrigin(url),
              let site = sites.first(where: { $0.origin == origin }) else { return nil }
        guard !wipingStoreIDs.contains(site.storeID) else { return nil }
        return cachedStore(for: site)
    }

    /// Whether a navigation to `url` would currently use a remembered jar.
    func isRemembered(_ url: URL) -> Bool {
        guard let origin = Self.canonicalOrigin(url) else { return false }
        return sites.contains(where: { $0.origin == origin })
    }

    // MARK: - Mutations (user-initiated only)

    /// Remembers one site. Returns the canonical origin, or nil when the URL
    /// is not an allowed http(s) address, the registry is not persistent, or
    /// the record cap is reached.
    @discardableResult
    func remember(url: URL, now: Date = Date()) -> String? {
        guard directory != nil, canRememberMore,
              let origin = Self.canonicalOrigin(url),
              !sites.contains(where: { $0.origin == origin }) else { return nil }
        sites.append(MacRememberedSite(origin: origin, storeID: UUID(), addedAt: now))
        scheduleWrite()
        objectWillChange.send()
        return origin
    }

    /// Stops remembering one site and wipes its retained jar. Resolution for
    /// the jar is gated first, every live tab is detached onto its ephemeral
    /// store, and only then does the wipe begin — so a page still sitting on
    /// the jar can never repopulate it, and no navigation replay can
    /// re-acquire it mid-wipe. The data-store container itself is
    /// WebKit-managed and stays (empty) on disk.
    func forget(origin: String) async {
        guard let index = sites.firstIndex(where: { $0.origin == origin }) else { return }
        let site = sites[index]
        wipingStoreIDs.insert(site.storeID)
        defer { wipingStoreIDs.remove(site.storeID) }
        onJarsInvalidated?([site.storeID])
        sites.remove(at: index)
        storeCache.removeValue(forKey: origin)
        scheduleWrite()
        objectWillChange.send()
        await Self.wipeStore(WKWebsiteDataStore(forIdentifier: site.storeID))
    }

    /// Wipes the retained data of every remembered site while KEEPING the
    /// remember choices. Live tabs are detached onto their ephemeral store
    /// and resolution is gated for the whole wipe; afterwards each site
    /// resolves to its (now empty) jar again, so the next visit starts
    /// clean without losing the opt-in.
    func clearAllRetainedData() async {
        let snapshot = sites
        let storeIDs = Set(snapshot.map(\.storeID))
        wipingStoreIDs.formUnion(storeIDs)
        defer { wipingStoreIDs.subtract(storeIDs) }
        onJarsInvalidated?(storeIDs)
        storeCache.removeAll()
        for site in snapshot {
            await Self.wipeStore(WKWebsiteDataStore(forIdentifier: site.storeID))
        }
        objectWillChange.send()
    }

    /// Wipes every remembered jar and drops every remember choice. Live tabs
    /// are detached from every jar BEFORE any wipe begins. Each wipe uses
    /// only public WebKit APIs against this app's own dedicated stores —
    /// never the shared default store, Safari, Keychain or another app's
    /// data.
    func forgetAll() async {
        let snapshot = sites
        let storeIDs = Set(snapshot.map(\.storeID))
        wipingStoreIDs.formUnion(storeIDs)
        defer { wipingStoreIDs.subtract(storeIDs) }
        onJarsInvalidated?(storeIDs)
        sites = []
        storeCache.removeAll()
        scheduleWrite()
        objectWillChange.send()
        for site in snapshot {
            await Self.wipeStore(WKWebsiteDataStore(forIdentifier: site.storeID))
        }
    }

    // MARK: - Inventory

    /// Per-site inventory: cookie count, website-data record count and the
    /// data-type names present. No values are read or returned.
    func siteSummaries() async -> [MacRememberedSiteSummary] {
        var summaries: [MacRememberedSiteSummary] = []
        for site in sites {
            let store = cachedStore(for: site)
            let cookies = await store.httpCookieStore.allCookies()
            let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
            summaries.append(MacRememberedSiteSummary(
                origin: site.origin,
                displayName: site.displayName,
                addedAt: site.addedAt,
                cookieCount: cookies.count,
                recordCount: records.count,
                dataTypes: Array(Set(records.flatMap(\.dataTypes))).sorted()
            ))
        }
        return summaries
    }

    private func cachedStore(for site: MacRememberedSite) -> WKWebsiteDataStore {
        if let cached = storeCache[site.origin] { return cached }
        let store = WKWebsiteDataStore(forIdentifier: site.storeID)
        storeCache[site.origin] = store
        return store
    }

    // MARK: - Store wiping (public WebKit APIs only)

    /// Deletes every byte one dedicated data store holds: all website-data
    /// types since the distant past plus every cookie in its jar.
    /// MainActor-isolated: `WKWebsiteDataStore.allWebsiteDataTypes()` is a
    /// MainActor call in the Swift 6 SDK.
    static func wipeStore(_ store: WKWebsiteDataStore) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
        let cookies = await store.httpCookieStore.allCookies()
        for cookie in cookies {
            await store.httpCookieStore.deleteCookie(cookie)
        }
    }

    // MARK: - Persistence

    /// Best-effort final write. Deferred writes already keep the archive
    /// nearly current; this covers termination paths without requiring the
    /// host to hook app-lifecycle events.
    isolated deinit { flush() }

    func flush() {
        deferredWrite?.cancel()
        deferredWrite = nil
        guard dirty, let directory else { return }
        let snapshot = sites.sorted { $0.origin < $1.origin }
        dirty = false
        if !Self.write(snapshot, to: directory) {
            dirty = true
        }
    }

    private func scheduleWrite() {
        guard directory != nil else { return }
        dirty = true
        deferredWrite?.cancel()
        deferredWrite = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.flush()
        }
    }

    nonisolated private static func write(_ snapshot: [MacRememberedSite], to directory: URL) -> Bool {
        do {
            let archive = directory.appendingPathComponent("remembered-sites.json")
            let bytes = try JSONEncoder().encode(snapshot)
            guard bytes.count <= archiveByteLimit else { throw CocoaError(.fileWriteOutOfSpace) }
            try bytes.write(to: archive, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
            return true
        } catch {
            return false
        }
    }

    private static func readFile(_ url: URL, limit: Int) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadNoPermission)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_nlink == 1, info.st_size <= limit else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
}
