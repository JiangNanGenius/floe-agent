// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import FloeMacToolbox
import FloeTools
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// One task's independent browser on the Mac workbench lane. All WebKit work
/// is MainActor. A session owns its tabs' WKWebViews, their document
/// identities, the bounded lifecycle/DOM event buffer and the user-control
/// state; the visible workbench browser renders this session's active tab, so
/// the model and the user always share the exact same page and tab session.
/// Background tabs are real WKWebViews with a non-zero viewport: they keep
/// loading and answering semantic probes without ever being presented, and no
/// model action ever pulls them to the front.
///
/// Fences mirror the iPad task browser: every command carries the exact
/// sessionID; a per-owner lease fences a model run's holding period; a
/// navigation replaces the documentID; user input transfers control to the
/// user synchronously before it can change the page; end-of-turn retires the
/// lease while the page, tabs and scroll positions stay exactly where they
/// are.
@MainActor
final class MacTaskBrowserSession: NSObject, ObservableObject {
    enum SurfaceState: Equatable {
        case unbound
        case ready
        case loading
        case failed(String)
        case needsUser(String)
    }

    struct Tab: Identifiable {
        let id: UUID
        /// The tab's web view. Replaced (same tab id, fresh document) when a
        /// remembered-site navigation requires a different website data store,
        /// because WebKit fixes the data store at web-view creation.
        var webView: MacTaskBrowserWebView
        var documentID: String
        var revision: Int
        var nextEventSequence: Int
        var events: [MacBrowserProtocolEvent]
    }

    let conversationID: UUID
    /// Owner lifecycle generation stamped at creation by the owning tools hub.
    let generation: Int
    @Published private(set) var sessionID = UUID()
    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var activeTabID: UUID?
    @Published private(set) var isUserControlling = false
    @Published private(set) var takeoverPending = false
    @Published private(set) var surfaceState: SurfaceState = .unbound
    @Published private(set) var lastModelActivity: MacBrowserModelActivity?
    /// Chrome state republished from the active tab's WebKit getters for the
    /// visible workbench surface.
    @Published private(set) var address = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var activeTabTitle = ""
    @Published private(set) var tabStateRevision = 0
    @Published private(set) var tabLimitNotice: String?
    /// Model-initiated download state for this task only (user-initiated
    /// Save-panel transfers stay in MacBrowserDownloadController).
    @Published private(set) var downloadProgress: MacBrowserDownloadSnapshot?
    @Published private(set) var downloadOutcome: MacBrowserDownloadOutcome?

    private(set) var isReleased = false
    private var activeExecutionCount = 0
    private var pendingProbes: [UUID: () -> Void] = [:]
    private(set) var lastActivityAt = Date()

    /// The model run currently allowed to read or act on this browser. It
    /// survives between tool calls until an explicit release, the run's real
    /// terminal state, or a user takeover.
    @Published private(set) var modelControl: MacBrowserControlLease?
    private var controlEpochCounter = 0
    private var dispatchBusy = false
    private var dispatchWaiters: [DispatchWaiter] = []
    /// Public node labels from the most recent observation, keyed by the
    /// document they belong to; used only for the local status strip, cleared
    /// on document replacement, invalidation and any control change.
    private var documentNodeLabels: [String: [String: String]] = [:]

    private struct DispatchWaiter {
        let id: UUID
        let epoch: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    let downloads = BrowserDownloadService()
    private var downloadObservation: AnyCancellable?
    private var tabObservations: [UUID: [NSKeyValueObservation]] = [:]

    /// First real human input on any tab web view. Set by the owning hub so
    /// the presentation routing happens before the input changes the page.
    var onFirstUserInput: ((String) -> Void)?
    /// Set by the owning hub; called on the main actor when a navigation
    /// commits or finishes so the safe URL-only page restore record can be
    /// persisted. Never carries cookies, forms or request bodies.
    var onPageCommit: ((URL?) -> Void)?
    /// Remembered-site memory injected by the owning hub. Default nil keeps
    /// every session strictly ephemeral; when set, explicit navigations to a
    /// remembered origin use that site's dedicated persistent jar. Model runs
    /// can never set or extend it.
    weak var siteMemory: MacSiteMemoryRegistry?

    nonisolated static let protocolVersion = "floe.mactaskbrowser.v1"
    nonisolated static let maximumTabs = 6
    nonisolated static let maximumEventsPerTab = 128
    private let contentWorld = WKContentWorld.world(name: "FloeMacTaskBrowser")
    private let websiteDataStore = WKWebsiteDataStore.nonPersistent()

    var hasModelControlHolder: Bool { modelControl != nil }
    var currentModelRunID: UUID? { modelControl?.runID }
    var isModelActive: Bool { modelControl != nil && !isUserControlling && !takeoverPending }

    var activeTab: Tab? {
        guard let activeTabID else { return nil }
        return tabs.first(where: { $0.id == activeTabID })
    }

    var activeWebView: WKWebView? { activeTab?.webView }

    init(conversationID: UUID, generation: Int = 0) {
        self.conversationID = conversationID
        self.generation = generation
        super.init()
        downloadObservation = downloads.$active
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                guard let self else { return }
                guard let current = active.first else {
                    downloadProgress = nil
                    return
                }
                downloadProgress = MacBrowserDownloadSnapshot(
                    id: current.id,
                    displayName: current.displayName,
                    progress: current.progress,
                    isFinishing: current.state == .finishing
                )
            }
    }

    // MARK: - Tabs

    @discardableResult
    func createTab(configuration suppliedConfiguration: WKWebViewConfiguration? = nil) -> UUID? {
        guard !isReleased, !takeoverPending else { return nil }
        guard tabs.count < Self.maximumTabs else {
            tabLimitNotice = MacTaskBrowserText.t(
                "此浏览器最多支持 6 个标签页。关闭一个标签页后再打开新的标签页。",
                "This browser supports up to 6 tabs. Close a tab before opening another."
            )
            return nil
        }
        tabLimitNotice = nil
        lastActivityAt = Date()
        let configuration = suppliedConfiguration ?? WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        let controller = configuration.userContentController
        if !controller.userScripts.contains(where: { $0.source == Self.protocolProbeSource }) {
            controller.addUserScript(WKUserScript(
                source: Self.protocolProbeSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: contentWorld
            ))
        }
        // Background tabs are never presented; a real viewport keeps every
        // DOM node measurable for semantic observation (a zero-sized
        // WKWebView reports every element as invisible).
        let webView = MacTaskBrowserWebView(
            frame: CGRect(x: 0, y: 0, width: 1_024, height: 768),
            configuration: configuration
        )
        webView.onFirstUserInteraction = { [weak self] reason in
            self?.registerUserInput(reason: reason)
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        let id = UUID()
        tabs.append(Tab(
            id: id,
            webView: webView,
            documentID: UUID().uuidString,
            revision: 0,
            nextEventSequence: 1,
            events: []
        ))
        activeTabID = id
        installObservers(for: id, webView: webView)
        appendEvent(tabID: id, method: "Target.targetCreated")
        syncChromeState()
        return id
    }

    func activate(_ id: UUID) {
        guard !isReleased, !takeoverPending, tabs.contains(where: { $0.id == id }) else { return }
        // A user tab switch is presentation only: any in-flight tool command
        // captured its own tabID/webView before awaiting, so switching here
        // never retargets a pending model action.
        activeTabID = id
        syncChromeState()
        appendEvent(tabID: id, method: "Target.targetActivated")
    }

    func close(_ id: UUID) {
        guard !isReleased, !takeoverPending,
              let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabObservations.removeValue(forKey: id)?.forEach { $0.invalidate() }
        let removed = tabs.remove(at: index)
        removed.webView.stopLoading()
        removed.webView.navigationDelegate = nil
        removed.webView.uiDelegate = nil
        if tabs.isEmpty {
            activeTabID = nil
            createTab()
            onPageCommit?(nil)
            return
        }
        if activeTabID == id {
            activeTabID = tabs[min(index, tabs.count - 1)].id
            onPageCommit?(activeWebView?.url)
        }
        syncChromeState()
    }

    func clearTabLimitNotice() {
        tabLimitNotice = nil
    }

    // MARK: - User chrome actions

    /// Every visible-chrome action funnels through here: the first real human
    /// gesture transfers control from a model run before the action changes
    /// the page. When no model holds control this stays a cheap local check.
    private func userDidInteract() {
        registerUserInput(reason: "You started using this browser")
    }

    func userNavigate(to rawAddress: String) {
        userDidInteract()
        guard !isReleased, !takeoverPending,
              let url = MacBrowserAddress.url(from: rawAddress) else { return }
        if tabs.isEmpty { createTab() }
        prepareStore(for: url, tabID: activeTabID)
        if let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
            replaceDocument(at: index)
        }
        activeWebView?.load(URLRequest(url: url))
    }

    func userGoBack() {
        userDidInteract()
        guard !isReleased, !takeoverPending else { return }
        if let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
            replaceDocument(at: index)
        }
        activeWebView?.goBack()
    }

    func userGoForward() {
        userDidInteract()
        guard !isReleased, !takeoverPending else { return }
        if let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
            replaceDocument(at: index)
        }
        activeWebView?.goForward()
    }

    func userReloadOrStop() {
        userDidInteract()
        guard !isReleased, !takeoverPending, let webView = activeWebView else { return }
        if webView.isLoading { webView.stopLoading() }
        else {
            if let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
                replaceDocument(at: index)
            }
            webView.reload()
        }
    }

    func userActivateTab(_ id: UUID) {
        userDidInteract()
        activate(id)
    }

    func userCreateTab() {
        userDidInteract()
        createTab()
    }

    func userCloseTab(_ id: UUID) {
        userDidInteract()
        close(id)
    }

    /// Applies the last committed page for a user-opened task browser. Only
    /// ever called when the user materializes this task's browser, never on
    /// startup by itself.
    func restorePage(_ url: URL) {
        guard !isReleased, tabs.isEmpty, MacBrowserAddress.allows(url) else { return }
        createTab()
        prepareStore(for: url, tabID: activeTabID)
        activeWebView?.load(URLRequest(url: url))
    }

    // MARK: - Site memory (explicit opt-in only)

    /// The data store an explicit navigation to `url` must use: the
    /// remembered site's own jar when the user opted in, otherwise this
    /// session's ephemeral store. Nothing here reads or writes data.
    private func dataStore(for url: URL) -> WKWebsiteDataStore {
        siteMemory?.store(for: url) ?? websiteDataStore
    }

    /// Aligns a tab's web view with the jar its next explicit navigation
    /// targets. WebKit binds the website data store at web-view creation, so a
    /// jar change rebuilds the tab's web view: the tab id and protocol event
    /// history stay, the document identity rotates exactly like a control
    /// handoff (the old jar's page cannot leak into the new context), and
    /// back/forward history does not carry across jars. No-op when the tab
    /// already uses the right store.
    @discardableResult
    private func prepareStore(for url: URL, tabID: UUID?) -> Bool {
        guard let tabID,
              let index = tabs.firstIndex(where: { $0.id == tabID }) else { return false }
        let desired = dataStore(for: url)
        let current = tabs[index].webView.configuration.websiteDataStore
        guard current !== desired else { return false }
        replaceWebView(at: index, dataStore: desired)
        return true
    }

    /// Detaches the tab's current web view and installs a fresh one bound to
    /// `dataStore`, mirroring `createTab`'s wiring (probe script, delegates,
    /// input gate, observers). The tab keeps its id and event log so model
    /// references to the tab stay meaningful; the document rotates.
    private func replaceWebView(at index: Int, dataStore: WKWebsiteDataStore) {
        let tabID = tabs[index].id
        tabObservations.removeValue(forKey: tabID)?.forEach { $0.invalidate() }
        let old = tabs[index].webView
        old.stopLoading()
        old.navigationDelegate = nil
        old.uiDelegate = nil
        old.removeFromSuperview()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let controller = configuration.userContentController
        if !controller.userScripts.contains(where: { $0.source == Self.protocolProbeSource }) {
            controller.addUserScript(WKUserScript(
                source: Self.protocolProbeSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: contentWorld
            ))
        }
        let webView = MacTaskBrowserWebView(
            frame: CGRect(x: 0, y: 0, width: 1_024, height: 768),
            configuration: configuration
        )
        webView.onFirstUserInteraction = { [weak self] reason in
            self?.registerUserInput(reason: reason)
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Mirrors setTabsInteractionEnabled: only a takeover waiting for an
        // in-flight model action freezes interaction, never user control.
        webView.floesModelInteractionFrozen = takeoverPending
        tabs[index].webView = webView
        replaceDocument(at: index)
        installObservers(for: tabID, webView: webView)
        syncChromeState()
    }

    /// Detaches every tab from the identified jars (a remembered site was
    /// removed, forgotten, or its data is being cleared). Affected tabs are
    /// rebuilt onto this session's ephemeral store UNCONDITIONALLY — the
    /// registry must not be consulted here, because during the wipe it may
    /// still resolve (or re-resolve) the very jar being removed. Called by
    /// the owning hub before the registry wipes the jars, so a page still
    /// sitting on one cannot repopulate it.
    func detachStores(_ storeIDs: Set<UUID>) {
        guard !isReleased, !storeIDs.isEmpty else { return }
        for index in tabs.indices {
            let store = tabs[index].webView.configuration.websiteDataStore
            guard let identifier = store.identifier, storeIDs.contains(identifier) else { continue }
            replaceWebView(at: index, dataStore: websiteDataStore)
        }
    }

    // MARK: - Chrome

    private func syncChromeState() {
        guard let tab = tabs.first(where: { $0.id == activeTabID }) else {
            address = ""
            canGoBack = false
            canGoForward = false
            isLoading = false
            activeTabTitle = ""
            tabStateRevision &+= 1
            return
        }
        canGoBack = tab.webView.canGoBack
        canGoForward = tab.webView.canGoForward
        isLoading = tab.webView.isLoading
        activeTabTitle = tab.webView.title ?? ""
        address = tab.webView.url?.absoluteString ?? ""
        tabStateRevision &+= 1
    }

    private func installObservers(for id: UUID, webView: WKWebView) {
        var observations: [NSKeyValueObservation] = []
        let schedule: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.syncChromeState() }
        }
        observations.append(webView.observe(\.isLoading, options: [.initial, .new]) { _, _ in schedule() })
        observations.append(webView.observe(\.canGoBack, options: [.initial, .new]) { _, _ in schedule() })
        observations.append(webView.observe(\.canGoForward, options: [.initial, .new]) { _, _ in schedule() })
        observations.append(webView.observe(\.title, options: [.initial, .new]) { _, _ in schedule() })
        observations.append(webView.observe(\.url, options: [.initial, .new]) { _, _ in schedule() })
        tabObservations[id] = observations
    }

    // MARK: - Ownership lifecycle

    var userControlMessage: String? {
        if isUserControlling || takeoverPending {
            return "The user controls this browser; wait until the user returns control"
        }
        return nil
    }

    /// Acquire before a model reads or acts on the page. An existing holder
    /// or a user controlling the browser keeps control of the same session.
    func acquireModelControl(runID: UUID) throws -> MacBrowserControlAcquisition {
        guard !isReleased else {
            throw MacTaskBrowserError.validation("This task's browser session was released")
        }
        if let userControlMessage { return .needsUser(userControlMessage) }
        if let holder = modelControl {
            return holder.runID == runID ? .acquired(holder) : .heldByAnotherRun
        }
        // A new holding period after any earlier release/handoff must not
        // reuse element or document references from the previous period.
        if controlEpochCounter > 0 {
            invalidateDocumentsForHandoff()
        }
        controlEpochCounter += 1
        let lease = MacBrowserControlLease(id: UUID(), runID: runID, epoch: controlEpochCounter)
        modelControl = lease
        if case .needsUser = surfaceState { surfaceState = .ready }
        return .acquired(lease)
    }

    /// Explicit model release. Releasing an already released holding period,
    /// or a token from an earlier holding period, is a no-op; it can never
    /// release the run's newer acquisition.
    func releaseModelControl(controlID: UUID, runID: UUID) -> MacBrowserControlReleaseOutcome {
        guard let holder = modelControl else { return .alreadyReleased }
        guard holder.runID == runID else { return .heldByAnotherRun }
        guard holder.id == controlID else { return .alreadyReleased }
        retireModelControlHolder()
        return .released
    }

    /// The owning run reached a real terminal state (completed, failed,
    /// cancelled, or checkpointed). Only that exact logical run loses the
    /// page; the page, tabs, login and scroll position are preserved. A user
    /// takeover is never undone by a run ending.
    @discardableResult
    func endModelControl(runID: UUID) -> Bool {
        guard let holder = modelControl, holder.runID == runID else { return false }
        retireModelControlHolder()
        return true
    }

    private func retireModelControlHolder() {
        controlEpochCounter += 1
        modelControl = nil
        lastModelActivity = nil
        // In-flight page work of this holding period is fenced with it.
        fenceDispatchQueue()
        invalidatePendingProbes()
        downloads.cancelAll()
    }

    /// Whether this exact holding period still authorizes page access. Every
    /// page payload is checked against it immediately before it is returned
    /// or committed.
    func isModelControlCurrent(_ lease: MacBrowserControlLease?) -> Bool {
        guard !isReleased, !isUserControlling, !takeoverPending else { return false }
        guard let lease else { return true }
        guard let holder = modelControl, holder == lease,
              controlEpochCounter == lease.epoch else { return false }
        return true
    }

    func assertModelControlCurrent(_ lease: MacBrowserControlLease?) throws {
        guard isModelControlCurrent(lease) else {
            throw MacTaskBrowserError.validation(
                "Browser control was released or returned to the user; stop and re-observe after control is returned"
            )
        }
    }

    /// First real human input on a tab, the address field or the tab chrome.
    /// Idle browsing that no model owns stays local and creates no handoff.
    func registerUserInput(reason: String = "You started using this browser") {
        guard !isReleased, !isUserControlling, modelControl != nil else { return }
        onFirstUserInput?(reason)
    }

    /// Transfers the page to the user. The model holder is revoked
    /// synchronously, queued model dispatches are fenced, and user input was
    /// already held back by the web view before it could change the page.
    func beginUserTakeover(reason: String?) {
        guard !isReleased else { return }
        controlEpochCounter += 1
        modelControl = nil
        lastModelActivity = nil
        documentNodeLabels.removeAll()
        fenceDispatchQueue()
        invalidatePendingProbes()
        downloads.cancelAll()
        isUserControlling = true
        takeoverPending = activeExecutionCount > 0
        setTabsInteractionEnabled(takeoverPending)
        surfaceState = .needsUser(reason ?? "User takeover is active")
    }

    /// The user returned control. Previous element/document references stay
    /// invalid; the next model acquisition is a new epoch. No new model run
    /// is started from here.
    func endUserControl() {
        guard !isReleased else { return }
        isUserControlling = false
        takeoverPending = false
        controlEpochCounter += 1
        modelControl = nil
        lastModelActivity = nil
        documentNodeLabels.removeAll()
        setTabsInteractionEnabled(false)
        if case .needsUser = surfaceState { surfaceState = .ready }
    }

    private func setTabsInteractionEnabled(_ frozen: Bool) {
        for tab in tabs {
            tab.webView.floesModelInteractionFrozen = frozen
        }
    }

    private func finishTakeoverIfIdle() {
        guard isUserControlling, takeoverPending, activeExecutionCount == 0 else { return }
        takeoverPending = false
        setTabsInteractionEnabled(false)
    }

    private func fenceDispatchQueue() {
        let waiters = dispatchWaiters
        dispatchWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume(returning: false) }
    }

    /// Serializes actions for this one browser session. A queued call is
    /// woken with `false` when control changed while it waited; it then
    /// returns stale/needsUser without touching the page.
    private func enterDispatch(epoch: Int) async -> Bool {
        if !dispatchBusy {
            dispatchBusy = true
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    dispatchWaiters.append(DispatchWaiter(
                        id: waiterID, epoch: epoch, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelDispatchWaiter(waiterID) }
        }
    }

    private func cancelDispatchWaiter(_ id: UUID) {
        guard let index = dispatchWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = dispatchWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func leaveDispatch() {
        while !dispatchWaiters.isEmpty {
            let next = dispatchWaiters.removeFirst()
            if next.epoch == controlEpochCounter, !isUserControlling, !takeoverPending {
                next.continuation.resume(returning: true)
                return
            }
            next.continuation.resume(returning: false)
        }
        dispatchBusy = false
    }

    /// Invalidate every element/document reference before the user or a new
    /// run takes the page. Only this task's evidence is affected.
    func invalidateDocumentsForHandoff() {
        guard !isReleased else { return }
        documentNodeLabels.removeAll()
        for index in tabs.indices {
            replaceDocument(at: index)
        }
    }

    private func replaceDocument(at index: Int) {
        tabs[index].documentID = UUID().uuidString
        tabs[index].revision = 0
    }

    /// Hub-owned release (task deletion). Stops only this task's WebViews and
    /// fences its delegate/probe callbacks; no other task session is touched.
    func release() {
        guard !isReleased else { return }
        isReleased = true
        controlEpochCounter += 1
        modelControl = nil
        lastModelActivity = nil
        documentNodeLabels.removeAll()
        fenceDispatchQueue()
        invalidatePendingProbes()
        downloads.cancelAll()
        tabObservations.values.forEach { $0.forEach { $0.invalidate() } }
        tabObservations.removeAll()
        isUserControlling = false
        takeoverPending = false
        surfaceState = .unbound
        for tab in tabs {
            tab.webView.stopLoading()
            tab.webView.navigationDelegate = nil
            tab.webView.uiDelegate = nil
            tab.webView.removeFromSuperview()
        }
        tabs.removeAll()
        activeTabID = nil
        address = ""
    }

    // MARK: - Command execution

    /// Captures the WebKit viewport owned by this exact task and run.
    /// The user can take over at any time, including during the native read.
    func captureVisionViewport(tabID: UUID?, control: MacBrowserControlLease) async throws -> Data {
        try assertModelControlCurrent(control)
        guard await enterDispatch(epoch: control.epoch) else {
            try Task.checkCancellation()
            throw MacTaskBrowserError.validation("Browser control changed before the screenshot")
        }
        activeExecutionCount += 1
        defer {
            activeExecutionCount -= 1
            leaveDispatch()
            finishTakeoverIfIdle()
        }
        try assertModelControlCurrent(control)
        try Task.checkCancellation()
        guard let targetID = tabID ?? activeTabID, let tab = tabs.first(where: { $0.id == targetID }),
              let url = tab.webView.url, !tab.webView.isLoading else {
            throw MacTaskBrowserError.validation("Open a browser page and wait for it to load before taking a screenshot")
        }
        let webView = tab.webView
        let size = webView.bounds.size
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else {
            throw MacTaskBrowserError.validation("The browser viewport has no visible size")
        }
        let deadline = ContinuousClock.now + .seconds(6)
        let before = try await visionGeometry(for: webView, deadline: deadline)
        try assertModelControlCurrent(control)
        let options = WKSnapshotConfiguration()
        options.rect = CGRect(origin: .zero, size: size)
        let scale = min(1, 1280 / max(size.width, size.height))
        options.snapshotWidth = NSNumber(value: max(1, Double(size.width * scale)))
        options.afterScreenUpdates = true
        let raster: CGImage = try await runProbe(deadline: deadline) { complete in
            webView.takeSnapshot(with: options) { image, error in
                if let error { complete(.failure(error)); return }
                guard let raster = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    complete(.failure(MacTaskBrowserError.validation("WebKit did not return a screenshot")))
                    return
                }
                complete(.success(raster))
            }
        }
        try assertModelControlCurrent(control)
        let bytes = try await Task.detached(priority: .userInitiated) {
            try Self.encodeVisionSnapshot(raster)
        }.value
        let after = try await visionGeometry(for: webView, deadline: deadline)
        try assertModelControlCurrent(control)
        try Task.checkCancellation()
        guard before == after, webView.bounds.size == size, webView.url == url, !webView.isLoading,
              tabs.contains(where: { $0.id == targetID && $0.documentID == tab.documentID && $0.webView === webView }) else {
            throw MacTaskBrowserError.validation("The page or viewport changed during capture. Take a new screenshot.")
        }
        lastActivityAt = Date()
        recordModelActivity(for: .observe(cursor: nil))
        return bytes
    }

    private struct VisionGeometry: Decodable, Equatable {
        let width, height, scrollX, scrollY, scale: Double
    }

    private func visionGeometry(for webView: WKWebView, deadline: ContinuousClock.Instant) async throws -> VisionGeometry {
        let value = try await probeValue("return globalThis.__floeProtocol?.visionGeometry() ?? null;",
                                         arguments: [:], in: webView, deadline: deadline)
        guard let object = value as? [String: Any] else {
            throw MacTaskBrowserError.validation("The page has no available screenshot geometry")
        }
        return try JSONDecoder().decode(VisionGeometry.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private nonisolated static func encodeVisionSnapshot(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard (1...4096).contains(image.width), (1...4096).contains(image.height),
              image.width * image.height <= 8_388_608,
              let encoder = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw MacTaskBrowserError.validation("The browser screenshot exceeds the image size limit")
        }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder), output.length > 0,
              output.length <= VerifiedToolImageArtifact.maximumStoredImageBytes else {
            throw MacTaskBrowserError.validation("The browser screenshot could not be encoded within the image limit")
        }
        return output as Data
    }

    /// Executes one command for a model holding a lease. Dispatches are
    /// serialized; a takeover or release while queued returns without
    /// touching the page, and every page payload is rechecked before it is
    /// returned.
    func execute(_ command: MacBrowserCommand, control: MacBrowserControlLease?) async -> MacBrowserResult {
        guard !isReleased else {
            return failure(command, status: .stale, code: "released", "This task's browser session was released")
        }
        lastActivityAt = Date()
        activeExecutionCount += 1
        defer {
            activeExecutionCount -= 1
            finishTakeoverIfIdle()
        }

        guard command.version == 1 else {
            return failure(command, status: .failed, code: "version", "Unsupported browser protocol version")
        }
        guard command.sessionID == sessionID else {
            return failure(command, status: .stale, code: "session", "Browser session is no longer active")
        }
        if command.action != .protocolInfo {
            if let denied = pageAccessFailure(command, control: control) { return denied }
        }

        let epoch = controlEpochCounter
        guard await enterDispatch(epoch: epoch) else {
            let takenOver = isUserControlling || takeoverPending
            return failure(
                command,
                status: takenOver ? .needsUser : .stale,
                code: takenOver ? "takeover" : "control",
                takenOver
                    ? "The user currently controls the browser"
                    : "Browser control was released or handed to the user"
            )
        }
        defer { leaveDispatch() }

        // Recheck after waiting behind another action. A takeover, release or
        // newer holder while this call was queued must never reach the page.
        guard !isReleased else {
            return failure(command, status: .stale, code: "released", "This task's browser session was released")
        }
        if command.action != .protocolInfo {
            if let denied = pageAccessFailure(command, control: control) { return denied }
        }

        let result = await executeAuthorized(command, control: control)
        if command.action != .protocolInfo, !isModelControlCurrent(control) {
            // A result that already says needsUser carries no page payload;
            // keep its specific reason.
            if result.status == .needsUser { return result }
            let takenOver = isUserControlling || takeoverPending
            return failure(
                command,
                status: takenOver ? .needsUser : .stale,
                code: takenOver ? "takeover" : "control",
                takenOver
                    ? "The user currently controls the browser; this result was withheld"
                    : "Browser control was released or handed to the user; this result was withheld"
            )
        }
        if result.status == .ok, modelControl != nil {
            recordModelActivity(for: command.action)
        }
        return result
    }

    private func pageAccessFailure(
        _ command: MacBrowserCommand,
        control: MacBrowserControlLease?
    ) -> MacBrowserResult? {
        if isReleased {
            return failure(command, status: .stale, code: "released", "This task's browser session was released")
        }
        if isUserControlling || takeoverPending {
            return failure(command, status: .needsUser, code: "takeover", "The user currently controls the browser")
        }
        if let control, !isModelControlCurrent(control) {
            return failure(
                command,
                status: .stale,
                code: "control",
                "Browser control was released or handed to the user"
            )
        }
        if control == nil, modelControl != nil {
            // A native/protocol caller without a run identity must never
            // bypass the run that currently owns this page.
            return failure(
                command,
                status: .stale,
                code: "control",
                "This browser is in use by a run; it must release control first"
            )
        }
        return nil
    }

    private func recordModelActivity(for action: MacBrowserAction) {
        let kind: MacBrowserModelActivity.Kind
        var detail: String?
        switch action {
        case .navigate, .create, .activateTab, .closeTab, .back, .forward, .reload:
            kind = .navigating
        case .click(let target):
            kind = .clicking
            detail = publicLabel(for: target)
        case .type:
            kind = .typing
        case .scroll:
            kind = .scrolling
        case .wait:
            kind = .waiting
        case .observe, .listTabs, .events, .protocolInfo, .takeover:
            kind = .observing
        }
        lastModelActivity = MacBrowserModelActivity(kind: kind, detail: detail, at: Date())
    }

    /// A same-document, publicly safe label for the executed target. It never
    /// contains form values, credentials, URLs or text from a different page.
    private func publicLabel(for target: MacBrowserTarget) -> String? {
        switch target {
        case .element(let ref, let documentID):
            guard tabs.contains(where: { $0.documentID == documentID }),
                  let label = documentNodeLabels[documentID]?[ref] else { return nil }
            return label
        }
    }

    private static func boundedPublicLabel(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(80))
    }

    private func recordNodeLabels(tabID: UUID, documentID: String, nodes: [MacBrowserNode]) {
        guard tabs.contains(where: { $0.id == tabID && $0.documentID == documentID }) else { return }
        var labels: [String: String] = [:]
        for node in nodes {
            let candidate = node.name.isEmpty ? node.text : node.name
            if let label = Self.boundedPublicLabel(candidate) { labels[node.ref] = label }
        }
        guard !labels.isEmpty else { return }
        documentNodeLabels[documentID] = labels
        // Bounded: a task only needs the current/previous observation.
        if documentNodeLabels.count > 4 {
            for key in Array(documentNodeLabels.keys) where key != documentID {
                documentNodeLabels.removeValue(forKey: key)
                if documentNodeLabels.count <= 2 { break }
            }
        }
    }

    private func executeAuthorized(_ command: MacBrowserCommand, control: MacBrowserControlLease?) async -> MacBrowserResult {
        switch command.action {
        case .protocolInfo:
            return MacBrowserResult(
                requestID: command.requestID,
                status: .ok,
                protocolVersion: Self.protocolVersion
            )
        case .create:
            guard let id = createTab() else {
                return failure(command, status: .blocked, code: "tab-limit", "The six-tab limit was reached")
            }
            return await observeResult(command, tabID: id, cursor: nil)
        case .listTabs:
            return await observeResult(command, tabID: command.tabID ?? activeTabID, cursor: nil)
        case .activateTab(let id):
            activate(id)
            return await observeResult(command, tabID: id, cursor: nil)
        case .closeTab(let id):
            close(id)
            return await observeResult(command, tabID: activeTabID, cursor: nil)
        case .takeover:
            onFirstUserInput?("Browser control was handed to the user")
            beginUserTakeover(reason: "Browser control was handed to the user")
            return failure(command, status: .needsUser, code: "takeover", "Browser control was handed to the user")
        case .navigate, .back, .forward, .reload, .observe, .click, .type, .scroll,
             .wait, .events:
            break
        }

        if case .navigate = command.action, command.tabID == nil, tabs.isEmpty {
            createTab()
        }
        guard let tabID = command.tabID ?? activeTabID,
              let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
        }
        let tab = tabs[index]
        if let expected = command.expectedDocumentID, expected != tab.documentID {
            return failure(command, status: .stale, code: "document", "The page changed; observe it again")
        }

        do {
            switch command.action {
            case .navigate(let value):
                guard let url = MacBrowserAddress.url(from: value) else {
                    throw MacTaskBrowserError.policy("The address is not an allowed http(s) URL")
                }
                if let denied = pageAccessFailure(command, control: control) { return denied }
                // A remembered-site jar change rebuilds the tab's web view and
                // rotates the document; the freshly loaded page is then
                // observed under the new document identity.
                prepareStore(for: url, tabID: tabID)
                guard let freshIndex = tabs.firstIndex(where: { $0.id == tabID }) else {
                    return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
                }
                replaceDocument(at: freshIndex)
                tabs[freshIndex].webView.load(URLRequest(url: url))
                return await waitResult(command, tabID: tabID, condition: .domContentLoaded)
            case .back:
                if let denied = pageAccessFailure(command, control: control) { return denied }
                replaceDocument(at: index)
                tab.webView.goBack()
            case .forward:
                if let denied = pageAccessFailure(command, control: control) { return denied }
                replaceDocument(at: index)
                tab.webView.goForward()
            case .reload:
                if let denied = pageAccessFailure(command, control: control) { return denied }
                replaceDocument(at: index)
                tab.webView.reload()
            case .observe(let cursor):
                return await observeResult(command, tabID: tabID, cursor: cursor)
            case .click(let target):
                if let denied = pageAccessFailure(command, control: control) { return denied }
                try await perform(
                    target: target,
                    in: tab,
                    operation: "click",
                    text: nil,
                    submit: false
                )
            case .type(let target, let text, let submit):
                guard text.utf8.count <= 16 * 1024 else {
                    throw MacTaskBrowserError.policy("Browser input exceeds 16 KiB")
                }
                if let denied = pageAccessFailure(command, control: control) { return denied }
                try await perform(
                    target: target,
                    in: tab,
                    operation: "type",
                    text: text,
                    submit: submit
                )
            case .scroll(let x, let y):
                if let denied = pageAccessFailure(command, control: control) { return denied }
                _ = try await tab.webView.callAsyncJavaScript(
                    "window.scrollBy(dx, dy); return true;",
                    arguments: ["dx": x, "dy": y],
                    in: nil,
                    contentWorld: contentWorld
                )
                appendEvent(tabID: tabID, method: "Input.dispatchMouseEvent", detail: "scroll")
            case .wait(let condition):
                return await waitResult(command, tabID: tabID, condition: condition)
            case .events(let afterSequence, let limit):
                return await eventsResult(
                    command,
                    tabID: tabID,
                    afterSequence: afterSequence,
                    limit: limit
                )
            case .protocolInfo, .create, .listTabs, .activateTab, .closeTab, .takeover:
                break
            }
            return await observeResult(command, tabID: tabID, cursor: nil)
        } catch MacTaskBrowserInteractionError.needsUser(let message) {
            onFirstUserInput?(message)
            beginUserTakeover(reason: message)
            return failure(command, status: .needsUser, code: "takeover", message)
        } catch MacTaskBrowserInteractionError.stale(let message) {
            return failure(command, status: .stale, code: "document", message)
        } catch let error as MacTaskBrowserError {
            switch error {
            case .policy(let message):
                return failure(command, status: .blocked, code: "policy", message)
            case .validation(let message):
                return failure(command, status: .failed, code: "validation", message)
            }
        } catch {
            return failure(command, status: .failed, code: "webkit", error.localizedDescription)
        }
    }

    private func perform(
        target: MacBrowserTarget,
        in tab: Tab,
        operation: String,
        text: String?,
        submit: Bool
    ) async throws {
        let script = """
        const protocol = globalThis.__floeProtocol;
        if (!protocol) return {status:'stale'};
        return protocol.perform(operation, target, documentID, text, submit);
        """
        let targetObject: [String: Any]
        switch target {
        case .element(let ref, let documentID):
            targetObject = ["kind": "element", "ref": ref, "documentID": documentID]
        }
        let value = try await tab.webView.callAsyncJavaScript(
            script,
            arguments: [
                "operation": operation,
                "target": targetObject,
                "documentID": tab.documentID,
                "text": text ?? "",
                "submit": submit
            ],
            in: nil,
            contentWorld: contentWorld
        )
        let status = (value as? [String: Any])?["status"] as? String
        if status == "needsUser" { throw MacTaskBrowserInteractionError.needsUser("Sensitive input requires user takeover") }
        if status == "stale" { throw MacTaskBrowserInteractionError.stale("The target is stale; observe the page again") }
        if status != "ok" { throw MacTaskBrowserError.policy("The target cannot accept this action") }
        appendEvent(
            tabID: tab.id,
            method: operation == "click" ? "Input.dispatchMouseEvent" : "Input.insertText"
        )
    }

    private func observeResult(_ command: MacBrowserCommand, tabID: UUID?, cursor: Int?) async -> MacBrowserResult {
        guard let tabID, let tab = tabs.first(where: { $0.id == tabID }) else {
            return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(min(30_000, max(250, command.timeoutMilliseconds))))
        do {
            try Task.checkCancellation()
            await collectProbeEvents(tabID: tabID, deadline: deadline)
            try Task.checkCancellation()
            let start = max(0, cursor ?? 0)
            let probe = try await semanticSnapshot(
                in: tab.webView,
                documentID: tab.documentID,
                cursor: start,
                limit: 40,
                deadline: deadline
            )
            try Task.checkCancellation()
            guard !isReleased else { throw MacBrowserProbeError.released }
            guard let index = tabs.firstIndex(where: { $0.id == tabID && $0.webView === tab.webView }),
                  tabs[index].documentID == tab.documentID else {
                return failure(command, status: .stale, code: "document", "The page changed; observe it again")
            }
            tabs[index].revision = max(tabs[index].revision, probe.revision)
            recordNodeLabels(tabID: tabID, documentID: tab.documentID, nodes: probe.nodes)
            let snapshot = MacBrowserPageSnapshot(
                documentID: tab.documentID,
                revision: max(tab.revision, probe.revision),
                url: tab.webView.url.flatMap { MacBrowserRestoreStore.sanitizedURL($0.absoluteString) }?.absoluteString ?? "",
                title: tab.webView.title ?? "",
                isLoading: tab.webView.isLoading,
                viewportWidth: probe.viewportWidth,
                viewportHeight: probe.viewportHeight,
                tabs: tabSnapshots(),
                nodes: probe.nodes,
                nextCursor: probe.nextCursor
            )
            return MacBrowserResult(requestID: command.requestID, status: .ok, page: snapshot)
        } catch MacBrowserProbeError.timedOut {
            return failure(command, status: .timeout, code: "timeout", "Browser page observation timed out")
        } catch MacBrowserProbeError.released {
            return failure(command, status: .stale, code: "released", "This task's browser session was released")
        } catch is CancellationError {
            return failure(command, status: .failed, code: "cancelled", "Browser page observation was cancelled")
        } catch {
            return failure(command, status: .failed, code: "observe", error.localizedDescription)
        }
    }

    private func probeValue(
        _ script: String,
        arguments: [String: Any],
        in webView: WKWebView,
        deadline: ContinuousClock.Instant
    ) async throws -> Any? {
        let data: Data = try await runProbe(deadline: deadline) { complete in
            webView.callAsyncJavaScript(
                script, arguments: arguments, in: nil, in: self.contentWorld
            ) { result in
                complete(result.flatMap { value in
                    Result { try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) }
                })
            }
        }
        return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    private func runProbe<Value: Sendable>(
        deadline: ContinuousClock.Instant,
        invoke: (@escaping MacBrowserProbeRequest<Value>.Completion) -> Void
    ) async throws -> Value {
        guard !isReleased else { throw MacBrowserProbeError.released }
        let id = UUID()
        let request = MacBrowserProbeRequest<Value>()
        pendingProbes[id] = { request.invalidate() }
        defer { pendingProbes.removeValue(forKey: id) }
        return try await request.run(deadline: deadline, invoke: invoke)
    }

    private func invalidatePendingProbes() {
        let invalidations = pendingProbes
        pendingProbes.removeAll()
        for invalidate in invalidations.values { invalidate() }
    }

    private struct ProbeSnapshot: Decodable {
        var revision: Int
        var viewportWidth: Double
        var viewportHeight: Double
        var nodes: [MacBrowserNode]
        var nextCursor: Int?
    }

    private func semanticSnapshot(
        in webView: WKWebView,
        documentID: String,
        cursor: Int,
        limit: Int,
        deadline: ContinuousClock.Instant
    ) async throws -> ProbeSnapshot {
        let script = """
        const protocol = globalThis.__floeProtocol;
        if (!protocol) return {
          revision:0,
          viewportWidth:Math.max(1, Number(window.innerWidth) || 1),
          viewportHeight:Math.max(1, Number(window.innerHeight) || 1),
          nodes:[],
          nextCursor:null
        };
        return protocol.snapshot(documentID, cursor, limit);
        """
        let value = try await probeValue(
            script,
            arguments: ["documentID": documentID, "cursor": cursor, "limit": limit],
            in: webView,
            deadline: deadline
        )
        guard JSONSerialization.isValidJSONObject(value as Any) else {
            return ProbeSnapshot(
                revision: 0,
                viewportWidth: max(1, webView.frame.width),
                viewportHeight: max(1, webView.frame.height),
                nodes: [],
                nextCursor: nil
            )
        }
        let data = try JSONSerialization.data(withJSONObject: value as Any)
        return try JSONDecoder().decode(ProbeSnapshot.self, from: data)
    }

    private struct ProbeState: Decodable {
        var readyState: String
        var selectorFound: Bool
        var textFound: Bool
        var idleMilliseconds: Double
        var revision: Int
    }

    private func eventsResult(
        _ command: MacBrowserCommand,
        tabID: UUID,
        afterSequence: Int?,
        limit: Int
    ) async -> MacBrowserResult {
        await collectProbeEvents(tabID: tabID)
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
        }
        let floor = max(0, afterSequence ?? 0)
        let available = tab.events.filter { $0.sequence > floor }
        let boundedLimit = min(100, max(1, limit))
        let selected = Array(available.prefix(boundedLimit))
        return MacBrowserResult(
            requestID: command.requestID,
            status: .ok,
            events: selected,
            nextEventSequence: selected.last?.sequence ?? afterSequence,
            protocolVersion: Self.protocolVersion
        )
    }

    private func waitResult(
        _ command: MacBrowserCommand,
        tabID: UUID,
        condition: MacBrowserWaitCondition
    ) async -> MacBrowserResult {
        let timeout = min(30_000, max(250, command.timeoutMilliseconds))
        let deadline = Date().addingTimeInterval(Double(timeout) / 1_000)
        repeat {
            guard !isReleased else {
                return failure(command, status: .stale, code: "released", "This task's browser session was released")
            }
            if isUserControlling || takeoverPending {
                return failure(command, status: .needsUser, code: "takeover", "The user currently controls the browser")
            }
            guard let tab = tabs.first(where: { $0.id == tabID }) else {
                return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
            }
            await collectProbeEvents(tabID: tabID)
            if case .documentChanged(let oldDocumentID) = condition,
               tab.documentID != oldDocumentID {
                appendEvent(tabID: tabID, method: "Runtime.waitConditionSatisfied")
                return await observeResult(command, tabID: tabID, cursor: nil)
            }
            do {
                let state = try await probeState(
                    in: tab.webView,
                    documentID: tab.documentID,
                    condition: condition
                )
                let satisfied: Bool
                switch condition {
                case .load:
                    satisfied = !tab.webView.isLoading && state.readyState == "complete"
                case .domContentLoaded:
                    satisfied = state.readyState == "interactive" || (!tab.webView.isLoading && state.readyState == "complete")
                case .selector:
                    satisfied = state.selectorFound
                case .text:
                    satisfied = state.textFound
                case .documentChanged:
                    satisfied = false
                case .idle(let milliseconds):
                    satisfied = !tab.webView.isLoading
                        && state.idleMilliseconds >= Double(min(5_000, max(100, milliseconds)))
                }
                if satisfied {
                    appendEvent(tabID: tabID, method: "Runtime.waitConditionSatisfied")
                    return await observeResult(command, tabID: tabID, cursor: nil)
                }
            } catch {
                // Document-start script injection and the isolated content
                // world can briefly race navigation commit. Treat that as a
                // not-yet-satisfied wait and retry until the bounded deadline.
                if Date() >= deadline {
                    return failure(command, status: .failed, code: "probe", error.localizedDescription)
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline && !Task.isCancelled
        if Task.isCancelled {
            return failure(command, status: .failed, code: "cancelled", "Browser wait was cancelled")
        }
        return failure(command, status: .timeout, code: "timeout", "Browser wait condition timed out")
    }

    private func probeState(
        in webView: WKWebView,
        documentID: String,
        condition: MacBrowserWaitCondition
    ) async throws -> ProbeState {
        var selector = ""
        var text = ""
        switch condition {
        case .selector(let value): selector = String(value.prefix(512))
        case .text(let value): text = String(value.prefix(512))
        default: break
        }
        let value = try await webView.callAsyncJavaScript(
            """
            const protocol = globalThis.__floeProtocol;
            if (!protocol) return {readyState:'loading', selectorFound:false, textFound:false, idleMilliseconds:0, revision:0};
            return protocol.status(documentID, selector, text);
            """,
            arguments: ["documentID": documentID, "selector": selector, "text": text],
            in: nil,
            contentWorld: contentWorld
        )
        guard JSONSerialization.isValidJSONObject(value as Any) else {
            throw MacTaskBrowserError.policy("The browser probe returned an invalid status")
        }
        let data = try JSONSerialization.data(withJSONObject: value as Any)
        return try JSONDecoder().decode(ProbeState.self, from: data)
    }

    private func collectProbeEvents(tabID: UUID, deadline: ContinuousClock.Instant? = nil) async {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        do {
            let value = try await probeValue(
                "return globalThis.__floeProtocol ? globalThis.__floeProtocol.drainEvents(documentID) : [];",
                arguments: ["documentID": tab.documentID],
                in: tab.webView,
                deadline: deadline ?? ContinuousClock.now.advanced(by: .seconds(15))
            )
            guard JSONSerialization.isValidJSONObject(value as Any) else { return }
            let data = try JSONSerialization.data(withJSONObject: value as Any)
            let events = try JSONDecoder().decode([ProbeEvent].self, from: data)
            for event in events {
                appendEvent(
                    tabID: tabID,
                    method: event.method,
                    detail: event.detail,
                    revision: event.revision
                )
            }
        } catch {
            // A navigation may replace the JS world between lookup and call.
            // Native lifecycle events still describe that transition.
        }
    }

    /// Internal for this session's download receipts only; every other caller
    /// stays inside this session.
    func appendEvent(
        tabID: UUID,
        method: String,
        detail: String? = nil,
        revision: Int? = nil
    ) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let sequence = tabs[index].nextEventSequence
        tabs[index].nextEventSequence += 1
        tabs[index].events.append(MacBrowserProtocolEvent(
            sequence: sequence,
            timestamp: Date(),
            tabID: tabID,
            documentID: tabs[index].documentID,
            method: method,
            detail: detail.map { String($0.prefix(512)) },
            revision: revision
        ))
        if tabs[index].events.count > Self.maximumEventsPerTab {
            tabs[index].events.removeFirst(tabs[index].events.count - Self.maximumEventsPerTab)
        }
        if let revision {
            tabs[index].revision = max(tabs[index].revision, revision)
        }
    }

    /// Model-initiated authenticated download for this task's browser. The
    /// chosen tab's WKWebView supplies its website data store, so a file
    /// behind the page's existing login is fetched with that page's cookies
    /// without exposing cookie values to the model. Destination authority is
    /// the caller's: the tools layer resolves it inside the pinned task
    /// workspace with create-new semantics before this is reached.
    func startDownload(
        tabID: UUID?,
        url: URL,
        destinationURL: URL,
        relativePath: String,
        maxBytes: Int,
        overwrite: Bool,
        cancellation: CancellationToken,
        commitStagedFile: @escaping BrowserDownloadService.StagedFileCommit
    ) async throws -> BrowserDownloadReceipt {
        guard !isReleased else { throw MacTaskBrowserError.validation("This task's browser was released") }
        guard !isUserControlling, !takeoverPending else {
            throw MacTaskBrowserError.validation("Wait for the user to return browser control before downloading")
        }
        guard let selected = tabID ?? activeTabID,
              let tab = tabs.first(where: { $0.id == selected }) else {
            throw MacTaskBrowserError.validation("The source browser tab is no longer available")
        }
        let suggested = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
        do {
            let receipt = try await downloads.start(
                webView: tab.webView,
                request: URLRequest(url: url),
                destinationURL: destinationURL,
                relativePath: relativePath,
                suggestedFilename: suggested,
                maxBytes: maxBytes,
                overwrite: overwrite,
                cancellation: cancellation,
                commitStagedFile: commitStagedFile
            )
            downloadOutcome = .saved(MacBrowserSavedDownload(
                displayName: receipt.suggestedFilename,
                fileURL: receipt.destinationURL
            ))
            lastModelActivity = MacBrowserModelActivity(kind: .downloading, detail: receipt.suggestedFilename, at: Date())
            return receipt
        } catch {
            // Present every post-commit failure (not just BrowserDownloadError)
            // in this task's chrome row; cancellation stays silent.
            if let downloadError = error as? BrowserDownloadError, case .cancelled = downloadError {
                downloadOutcome = nil
            } else {
                downloadOutcome = .error(MacBrowserDownloadController.visibleTaskError(error))
            }
            throw error
        }
    }

    /// Runs in a named isolated content world at document start. It maintains
    /// stable per-document node references and a small lifecycle/DOM queue,
    /// but deliberately exposes no arbitrary JavaScript evaluation endpoint.
    private static let protocolProbeSource = #"""
    (() => {
      if (globalThis.__floeProtocol) return;
      let documentID = '';
      let revision = 0;
      let nextRef = 1;
      let lastMutation = performance.now();
      const references = new WeakMap();
      const nodesByRef = new Map();
      const events = [];
      const selector = 'a,button,input,textarea,select,[role],[contenteditable="true"],[onclick],summary,label,h1,h2,h3,p';

      const push = (method, detail = null) => {
        events.push({method, detail, revision});
        if (events.length > 128) events.splice(0, events.length - 128);
      };
      const setDocument = id => {
        if (id && documentID !== id) documentID = id;
      };
      const roots = () => {
        const result = [document];
        const visit = root => {
          let all = [];
          try { all = Array.from(root.querySelectorAll('*')); } catch (_) {}
          for (const el of all) {
            if (el.shadowRoot) { result.push(el.shadowRoot); visit(el.shadowRoot); }
            if ((el.tagName || '').toLowerCase() === 'iframe') {
              try { if (el.contentDocument) { result.push(el.contentDocument); visit(el.contentDocument); } } catch (_) {}
            }
          }
        };
        visit(document);
        return result;
      };
      const visible = el => {
        try {
          const rect = el.getBoundingClientRect();
          const style = getComputedStyle(el);
          return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
        } catch (_) { return false; }
      };
      const ensureRef = el => {
        let ref = references.get(el);
        if (!ref) {
          if (nodesByRef.size >= 2048) {
            for (const [key, node] of nodesByRef) if (!node?.isConnected) nodesByRef.delete(key);
            while (nodesByRef.size >= 2048) nodesByRef.delete(nodesByRef.keys().next().value);
          }
          ref = `n${nextRef++}`;
          references.set(el, ref);
          nodesByRef.set(ref, el);
        }
        return ref;
      };
      const findByRef = ref => {
        const found = nodesByRef.get(ref);
        return found?.isConnected ? found : null;
      };
      const allNodes = () => {
        const seen = new Set();
        const output = [];
        for (const root of roots()) {
          let candidates = [];
          try { candidates = Array.from(root.querySelectorAll(selector)); } catch (_) {}
          for (const el of candidates) {
            if (seen.has(el) || !visible(el)) continue;
            seen.add(el);
            output.push(el);
            if (output.length >= 400) return output;
          }
        }
        return output;
      };
      const sensitiveField = el => {
        const hint = [el.type, el.autocomplete, el.name, el.id, el.getAttribute('aria-label')].filter(Boolean).join(' ');
        return /password|one[-_ ]?time[-_ ]?code|otp\b|\bcc-|security[-_ ]?code|\bcvv\b|api[-_ ]?key|access[-_ ]?token|验证码|密码|银行卡/.test(hint.toLowerCase());
      };
      const sensitiveForm = form => !!form && Array.from(form.elements).some(sensitiveField);
      const requiresHumanAction = (el, operation, submit) => {
        if (sensitiveField(el) || (operation === 'type' && sensitiveForm(el.form))) return true;
        const control = el.closest('button,input,a,[role="button"]') || el;
        const hint = [control.innerText, control.value, control.getAttribute('aria-label')].filter(Boolean).join(' ');
        if (operation === 'click' && /log\s*in|sign\s*in|check\s*out|place\s*order|purchase|\bpay\b|send\s+(message|email)|publish|登录|付款|支付|下单|发送消息|发送邮件|发布/i.test(hint)) return true;
        const submits = submit || (operation === 'click' && ['submit', 'image'].includes(control.type));
        const form = control.form || el.form;
        return submits && !!form && (sensitiveForm(form) || String(control.formMethod || form.method).toLowerCase() !== 'get');
      };
      const serialize = el => {
        const rect = el.getBoundingClientRect();
        const role = el.getAttribute('role') || (el.tagName || '').toLowerCase();
        const redact = sensitiveField(el) || sensitiveForm(el.form);
        return {
          ref: ensureRef(el), role,
          name: String(el.getAttribute('aria-label') || el.title || '').slice(0, 300),
          text: redact ? '' : String(el.innerText || el.textContent || '').trim().slice(0, 500),
          value: redact ? null : (el.value == null ? null : String(el.value).slice(0, 500)),
          state: {disabled: !!el.disabled, checked: !!el.checked, selected: !!el.selected},
          bounds: {x:rect.x, y:rect.y, width:rect.width, height:rect.height}
        };
      };
      const snapshot = (id, cursor, limit) => {
        setDocument(id);
        const nodes = allNodes();
        const start = Math.max(0, Number(cursor) || 0);
        const count = Math.min(50, Math.max(1, Number(limit) || 40));
        const end = Math.min(nodes.length, start + count);
        return {
          revision,
          viewportWidth: Math.max(1, Number(window.innerWidth) || 1),
          viewportHeight: Math.max(1, Number(window.innerHeight) || 1),
          nodes: nodes.slice(start, end).map(serialize),
          nextCursor: end < nodes.length ? end : null
        };
      };
      const perform = (operation, target, expectedDocumentID, text, submit) => {
        setDocument(expectedDocumentID);
        if (target.kind === 'element' && target.documentID !== documentID) return {status:'stale'};
        const el = target.kind === 'element'
          ? findByRef(target.ref)
          : document.elementFromPoint(Number(target.x), Number(target.y));
        if (!el || !el.isConnected) return {status:'stale'};
        if (requiresHumanAction(el, operation, submit)) return {status:'needsUser'};
        if (operation === 'click') {
          el.scrollIntoView({block:'center', inline:'center'});
          const rect = el.getBoundingClientRect();
          const x = rect.x + rect.width / 2;
          const y = rect.y + rect.height / 2;
          for (const type of ['pointerover','pointerenter','pointerdown','pointerup']) {
            try { el.dispatchEvent(new PointerEvent(type, {bubbles:true, cancelable:true, clientX:x, clientY:y, pointerType:'mouse', isPrimary:true})); } catch (_) {}
          }
          el.click();
          return {status:'ok'};
        }
        const tag = (el.tagName || '').toLowerCase();
        if (!(tag === 'input' || tag === 'textarea' || el.isContentEditable)) return {status:'blocked'};
        el.focus();
        if (el.isContentEditable) {
          el.textContent = text;
        } else {
          const prototype = tag === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
          if (setter) setter.call(el, text); else el.value = text;
        }
        try { el.dispatchEvent(new InputEvent('beforeinput', {bubbles:true, inputType:'insertText', data:text})); } catch (_) {}
        el.dispatchEvent(new Event('input', {bubbles:true}));
        el.dispatchEvent(new Event('change', {bubbles:true}));
        if (submit) {
          el.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', code:'Enter', bubbles:true}));
          if (el.form?.requestSubmit) el.form.requestSubmit();
          el.dispatchEvent(new KeyboardEvent('keyup', {key:'Enter', code:'Enter', bubbles:true}));
        }
        return {status:'ok'};
      };
      const status = (id, query, expectedText) => {
        setDocument(id);
        let selectorFound = false;
        if (query) {
          for (const root of roots()) {
            try { if (root.querySelector(query)) { selectorFound = true; break; } } catch (_) {}
          }
        }
        const bodyText = expectedText ? String(document.body?.innerText || '') : '';
        return {
          readyState: document.readyState,
          selectorFound,
          textFound: !!expectedText && bodyText.includes(expectedText),
          idleMilliseconds: Math.max(0, performance.now() - lastMutation),
          revision
        };
      };
      const drainEvents = id => { setDocument(id); return events.splice(0, events.length); };

      new MutationObserver(records => {
        if (!records.length) return;
        revision += 1;
        lastMutation = performance.now();
        push('DOM.documentUpdated');
      }).observe(document, {subtree:true, childList:true, attributes:true, characterData:true});
      document.addEventListener('DOMContentLoaded', () => push('Page.domContentEventFired'), {once:true});
      addEventListener('load', () => push('Page.loadEventFired'), {once:true});
      addEventListener('hashchange', () => push('Page.navigatedWithinDocument'));
      addEventListener('popstate', () => push('Page.navigatedWithinDocument'));
      const visionGeometry = () => ({
        width: window.innerWidth, height: window.innerHeight,
        scrollX: window.scrollX, scrollY: window.scrollY,
        scale: window.visualViewport?.scale ?? 1
      });
      globalThis.__floeProtocol = {snapshot, perform, status, drainEvents, visionGeometry};
      push('Runtime.executionContextCreated');
    })();
    """#

    private struct ProbeEvent: Decodable {
        var method: String
        var detail: String?
        var revision: Int?
    }

    private func tabSnapshots() -> [MacBrowserTabSnapshot] {
        tabs.map {
            MacBrowserTabSnapshot(
                id: $0.id,
                url: $0.webView.url.flatMap { MacBrowserRestoreStore.sanitizedURL($0.absoluteString) }?.absoluteString ?? "",
                title: $0.webView.title ?? "",
                isActive: $0.id == activeTabID
            )
        }
    }

    private func failure(
        _ command: MacBrowserCommand,
        status: MacBrowserResult.Status,
        code: String,
        _ message: String
    ) -> MacBrowserResult {
        MacBrowserResult(
            requestID: command.requestID,
            status: status,
            message: message,
            error: MacBrowserFailure(code: code, message: message)
        )
    }
}

extension MacTaskBrowserSession: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard !isReleased, let url = navigationAction.request.url else {
            return .cancel
        }
        // WebKit uses its own blank document while `loadHTMLString` commits.
        if url.absoluteString == "about:blank" { return .allow }
        guard MacBrowserAddress.allows(url) else { return .cancel }
        // Jar enforcement for every main-frame navigation — user clicks,
        // redirects, form submissions and a popup tab's first real load: a
        // remembered jar must never follow the page into a different site,
        // and an ephemeral page must never pick up a remembered jar it did
        // not opt into. When the tab's store does not match the target
        // origin's jar, the tab's web view is rebuilt onto the right jar and
        // the exact request is replayed there (the replay passes this same
        // check with the correct store and is allowed).
        if navigationAction.targetFrame?.isMainFrame == true,
           let tabID = tabs.first(where: { $0.webView === webView })?.id {
            let desired = dataStore(for: url)
            if webView.configuration.websiteDataStore !== desired {
                prepareStore(for: url, tabID: tabID)
                tabs.first(where: { $0.id == tabID })?.webView.load(navigationAction.request)
                return .cancel
            }
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !isReleased, let tabID = tabs.first(where: { $0.webView === webView })?.id else { return }
        appendEvent(tabID: tabID, method: "Page.frameStartedLoading")
        surfaceState = .loading
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !isReleased, let index = tabs.firstIndex(where: { $0.webView === webView }) else { return }
        replaceDocument(at: index)
        documentNodeLabels.removeAll()
        appendEvent(
            tabID: tabs[index].id,
            method: "Page.frameNavigated"
        )
        if tabs[index].id == activeTabID {
            syncChromeState()
            onPageCommit?(webView.url)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isReleased, let index = tabs.firstIndex(where: { $0.webView === webView }) else { return }
        appendEvent(tabID: tabs[index].id, method: "Page.loadEventFired")
        if tabs[index].id == activeTabID {
            syncChromeState()
            onPageCommit?(webView.url)
        }
        surfaceState = isUserControlling ? .needsUser("User takeover is active") : .ready
        // Title/back-forward availability are WebKit getters, not @Published
        // fields; notify the visible projection explicitly.
        objectWillChange.send()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard !isReleased, let tabID = tabs.first(where: { $0.webView === webView })?.id else { return }
        let nsError = error as NSError
        appendEvent(tabID: tabID, method: "Network.loadingFailed", detail: "\(nsError.domain):\(nsError.code)")
        surfaceState = .failed("\(nsError.localizedDescription) (\(nsError.code))")
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard !isReleased, let tabID = tabs.first(where: { $0.webView === webView })?.id else { return }
        let nsError = error as NSError
        appendEvent(tabID: tabID, method: "Network.loadingFailed", detail: "\(nsError.domain):\(nsError.code)")
        surfaceState = .failed("\(nsError.localizedDescription) (\(nsError.code))")
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard !isReleased, !takeoverPending,
              tabs.contains(where: { $0.webView === webView }),
              let url = navigationAction.request.url,
              url.absoluteString == "about:blank" || MacBrowserAddress.allows(url) else { return nil }
        // A target=_blank / window.open request opens a real task tab. The
        // six-tab limit is honest: at capacity the popup is refused and the
        // user/model sees the limit notice instead of a fake success. The new
        // tab inherits the opener's jar until its first main-frame policy
        // check, which swaps the web view onto the target origin's jar when
        // they differ — the opener's window handle is not preserved across
        // that swap, and no request is ever committed into the wrong jar.
        guard let id = createTab(configuration: configuration),
              let created = tabs.first(where: { $0.id == id })?.webView else {
            if let activeTabID {
                appendEvent(tabID: activeTabID, method: "Target.targetLimitReached", detail: "maximumTabs")
            }
            return nil
        }
        return created
    }
}

/// A web view that transfers control to the user on the first real human
/// input before the input changes the page, mirroring the iPad gesture
/// recognizer behavior. Synthetic events dispatched by the protocol probe
/// never pass through these entry points.
final class MacTaskBrowserWebView: WKWebView {
    var onFirstUserInteraction: ((String) -> Void)?
    /// While a takeover is waiting for an already dispatched model action to
    /// settle, native interaction is frozen; the uncertain result is never
    /// replayed and the user can force-return control from the chrome.
    var floesModelInteractionFrozen = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        if view != nil, floesModelInteractionFrozen { return nil }
        return view
    }

    override func mouseDown(with event: NSEvent) {
        onFirstUserInteraction?("You started using this browser")
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onFirstUserInteraction?("You started using this browser")
        super.rightMouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        onFirstUserInteraction?("You started using this browser")
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        onFirstUserInteraction?("You started using this browser")
        super.scrollWheel(with: event)
    }
}

/// A callback may never arrive after a WebKit process/navigation failure.
/// Resolve a single Sendable value on callback, deadline, cancellation,
/// or owner release; a late callback cannot resume it twice. No task group
/// waits for an uncooperative native callback before returning the failure.
@MainActor
private final class MacBrowserProbeRequest<Value: Sendable> {
    typealias Completion = @MainActor @Sendable (Result<Value, Error>) -> Void
    private var continuation: CheckedContinuation<Value, Error>?
    private var deadlineTask: Task<Void, Never>?
    private var started = false

    func run(
        deadline: ContinuousClock.Instant,
        invoke: (@escaping Completion) -> Void
    ) async throws -> Value {
        precondition(!started)
        started = true
        try Task.checkCancellation()
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else {
                    finish(.failure(CancellationError()))
                    return
                }
                guard ContinuousClock.now < deadline else {
                    finish(.failure(MacBrowserProbeError.timedOut))
                    return
                }
                deadlineTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) }
                    catch { return }
                    self?.finish(.failure(MacBrowserProbeError.timedOut))
                }
                invoke { [weak self] result in self?.finish(result) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
        try Task.checkCancellation()
        return value
    }

    func invalidate() { finish(.failure(MacBrowserProbeError.released)) }

    private func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        continuation.resume(with: result)
    }
}

enum MacBrowserProbeError: Error, Sendable, Equatable {
    case timedOut
    case released
}

enum MacTaskBrowserInteractionError: Error {
    case needsUser(String)
    case stale(String)
}

enum MacTaskBrowserError: Error, LocalizedError {
    case policy(String)
    case validation(String)

    var errorDescription: String? {
        switch self {
        case .policy(let message), .validation(let message): return message
        }
    }
}

enum MacTaskBrowserText {
    static func t(_ chinese: String, _ english: String) -> String {
        if let language = Locale.current.language.languageCode?.identifier,
           language == "zh" { return chinese }
        return english
    }
}

/// Registry of live task browser sessions. It never swaps one task's tabs
/// into another: entries are keyed by trusted conversation identity and
/// released only by that task's deletion or explicit retirement.
@MainActor
final class MacTaskBrowserSessionStore {
    private var sessions: [UUID: MacTaskBrowserSession] = [:]
    let maximumSessions: Int

    init(maximumSessions: Int = 8) {
        self.maximumSessions = maximumSessions
    }

    var count: Int { sessions.count }

    func session(for conversationID: UUID) -> MacTaskBrowserSession? {
        sessions[conversationID]
    }

    func insert(_ session: MacTaskBrowserSession) throws {
        if let existing = sessions[session.conversationID] {
            guard existing === session else {
                throw MacTaskBrowserError.validation("Another browser session already owns this task")
            }
            return
        }
        guard sessions.count < maximumSessions else {
            throw MacTaskBrowserError.validation(
                "Too many task browsers are open; close a browser or delete a task you no longer use"
            )
        }
        sessions[session.conversationID] = session
    }

    @discardableResult
    func release(_ conversationID: UUID) -> MacTaskBrowserSession? {
        sessions.removeValue(forKey: conversationID)
    }

    /// Least-recently-used first, for explicit ownership decisions only.
    /// Never used to evict implicitly.
    func sessionsByLeastRecentActivity() -> [MacTaskBrowserSession] {
        sessions.values.sorted { $0.lastActivityAt < $1.lastActivityAt }
    }
}

/// Visible result state of a model-initiated task download. The file already
/// sits at the workspace-pinned path; the workbench chrome shows the same
/// per-owner row as a user download.
enum MacBrowserDownloadOutcome: Equatable {
    case saved(MacBrowserSavedDownload)
    case error(String)
}
