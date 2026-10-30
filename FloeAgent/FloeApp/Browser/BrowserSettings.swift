// FloeApp — reusable browser preferences and the provider-recipient gate.
//
// Browser privacy has two independent dimensions:
//  * which pages/requests may use the shared browser session, and
//  * whether that session's cookies and website data may be kept on disk.
//
// Persistence is OFF until the user explicitly enables it after an explicit
// warning. The warning is deliberately provider-neutral: official and
// third-party model providers both receive data the task includes in a
// request, and no provider is described as risk-free. Provider authorization
// is granted once per provider identity, not per tool call or per site.

#if canImport(SwiftUI) && canImport(WebKit)
import Combine
import Foundation
import SwiftUI
import WebKit
import FloeCore

enum BrowserLinkOpenBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case inApp
    case systemBrowser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inApp: IDELanguageRunText.t("在任务浏览器中打开", "Open in task browser")
        case .systemBrowser: IDELanguageRunText.t("在系统浏览器中打开", "Open in system browser")
        }
    }
}

enum BrowserUserAgentMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case mobile
    case desktop
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: IDELanguageRunText.t("自动（WebKit 默认）", "Automatic (WebKit default)")
        case .mobile: IDELanguageRunText.t("手机网站", "Mobile site")
        case .desktop: IDELanguageRunText.t("桌面网站", "Desktop site")
        case .custom: IDELanguageRunText.t("自定义", "Custom")
        }
    }
}

struct BrowserUserAgentSetting: Codable, Equatable, Sendable {
    var mode: BrowserUserAgentMode = .automatic
    var customValue: String = ""

    var effectiveValue: String? {
        switch mode {
        case .automatic:
            return nil
        case .mobile:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        case .desktop:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        case .custom:
            let trimmed = customValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(1_024))
        }
    }
}

/// Separate one-time consent for advanced browser features. It governs
/// cookie/storage reads and browser-session fetches even when website
/// persistence is OFF; it is not the persistence switch.
struct BrowserAdvancedConsent: Codable, Equatable, Sendable {
    static let warningVersion = 1

    var warningVersion: Int
    var confirmedAt: Date

    var isCurrent: Bool { warningVersion == Self.warningVersion }
}

@MainActor
final class BrowserSettingsService: ObservableObject {
    static let shared = BrowserSettingsService()

    private enum Key {
        static let linkOpen = "browser.settings.linkOpen"
        static let userAgent = "browser.settings.userAgent"
        static let advancedEnabled = "browser.settings.advancedBrowserFeatures"
        static let advancedConsent = "browser.settings.advancedConsent"
        static let authorizedProviders = "browser.settings.authorizedProviders"
    }

    @Published private(set) var linkOpenBehavior: BrowserLinkOpenBehavior
    @Published private(set) var userAgent: BrowserUserAgentSetting
    @Published private(set) var advancedBrowserFeaturesEnabled: Bool
    @Published private(set) var advancedConsent: BrowserAdvancedConsent?
    /// Bumped on every advanced-feature ON/OFF transition. An in-flight
    /// cookie/storage/fetch result whose captured generation no longer matches
    /// is discarded and never returned to the model.
    @Published private(set) var advancedGeneration: UInt64 = 0
    @Published private(set) var authorizedProviderIDs: Set<String>
    /// Internal change counter; BrowserSessionCenter observes this to apply
    /// privacy/UA changes to every live task session.
    @Published private(set) var revision = 0

    private let defaults: UserDefaults
    /// The ordinary browser keeps using WebKit's shared persistent store,
    /// exactly as before this feature. The advanced-AI gate does not clear
    /// cookies, log the user out or replace the store.
    private let sharedWebsiteDataStore = WKWebsiteDataStore.default()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.linkOpenBehavior = BrowserLinkOpenBehavior(
            rawValue: defaults.string(forKey: Key.linkOpen) ?? ""
        ) ?? .inApp
        if let data = defaults.data(forKey: Key.userAgent),
           let decoded = try? JSONDecoder().decode(BrowserUserAgentSetting.self, from: data) {
            self.userAgent = decoded
        } else {
            self.userAgent = BrowserUserAgentSetting()
        }
        self.advancedBrowserFeaturesEnabled = defaults.bool(forKey: Key.advancedEnabled)
        self.authorizedProviderIDs = Set(defaults.stringArray(forKey: Key.authorizedProviders) ?? [])
        if let data = defaults.data(forKey: Key.advancedConsent),
           let decoded = try? JSONDecoder().decode(BrowserAdvancedConsent.self, from: data),
           decoded.isCurrent {
            self.advancedConsent = decoded
        } else {
            self.advancedConsent = nil
        }
        if self.advancedBrowserFeaturesEnabled && self.advancedConsent?.isCurrent != true {
            self.advancedBrowserFeaturesEnabled = false
            defaults.set(false, forKey: Key.advancedEnabled)
            defaults.removeObject(forKey: Key.advancedConsent)
            self.advancedConsent = nil
        }
    }

    var websiteDataStore: WKWebsiteDataStore { sharedWebsiteDataStore }

    var advancedWarning: String {
        IDELanguageRunText.t(
            "高级浏览器功能允许任务读取此任务浏览器中的 Cookie、登录状态和网站存储，并让网页请求复用浏览器会话。启用后，账号、登录状态和私人页面内容可能随任务请求发送给你配置的模型提供商。官方提供商同样适用，没有任何提供商可被视为零风险。授权按提供商保留，不会按网站重复询问；关闭后，正在进行的敏感读取结果会被丢弃。",
            "Advanced browser features let a task read cookies, login state and website storage from its browser, and let web requests reuse the browser session. When on, accounts, login state and private page content may be sent to your configured model provider as part of task requests. Official providers are not exempt; no provider is risk-free. Authorization is retained per provider, not requested per site. Turning it off discards in-flight sensitive results."
        )
    }

    var providerWarning: String {
        IDELanguageRunText.t(
            "浏览器会话数据（包括 Cookie、登录状态和本地存储）可能随任务请求发送给该模型提供商。官方与第三方提供商承担相同的信任风险；没有任何提供商可被视为零风险。授权会按提供商保留，不会按网站或每次调用重复询问。",
            "Browser session data (including cookies, login state and local storage) may be sent to this model provider as part of task requests. Official and third-party providers carry the same trust risk; no provider is risk-free. Authorization is retained per provider and is not requested per site or per call."
        )
    }

    func setLinkOpenBehavior(_ behavior: BrowserLinkOpenBehavior) {
        guard behavior != linkOpenBehavior else { return }
        linkOpenBehavior = behavior
        defaults.set(behavior.rawValue, forKey: Key.linkOpen)
        bump()
    }

    func setUserAgent(mode: BrowserUserAgentMode, customValue: String? = nil) {
        let trimmed = String((customValue ?? userAgent.customValue).trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_024))
        let next = BrowserUserAgentSetting(mode: mode, customValue: trimmed)
        guard next != userAgent else { return }
        userAgent = next
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Key.userAgent)
        }
        bump()
    }

    /// Enables the separate advanced-browser gate only after the caller has
    /// shown `advancedWarning` and obtained an explicit confirmation. This is
    /// intentionally independent of website persistence.
    @discardableResult
    func enableAdvancedBrowserFeatures(
        confirmedWarning: Bool,
        now: Date = Date()
    ) -> Bool {
        guard confirmedWarning else { return false }
        advancedConsent = BrowserAdvancedConsent(
            warningVersion: BrowserAdvancedConsent.warningVersion,
            confirmedAt: now
        )
        advancedBrowserFeaturesEnabled = true
        advancedGeneration &+= 1
        defaults.set(true, forKey: Key.advancedEnabled)
        if let data = try? JSONEncoder().encode(advancedConsent) {
            defaults.set(data, forKey: Key.advancedConsent)
        }
        bump()
        return true
    }

    /// Turning advanced features OFF invalidates every in-flight sensitive
    /// result by generation and revokes all future cookie/storage/fetch use.
    func disableAdvancedBrowserFeatures() {
        guard advancedBrowserFeaturesEnabled || advancedConsent != nil else { return }
        advancedBrowserFeaturesEnabled = false
        advancedConsent = nil
        advancedGeneration &+= 1
        defaults.set(false, forKey: Key.advancedEnabled)
        defaults.removeObject(forKey: Key.advancedConsent)
        bump()
    }

    func isProviderAuthorized(_ providerID: String) -> Bool {
        authorizedProviderIDs.contains(providerID)
    }

    func authorizeProvider(_ providerID: String) {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard authorizedProviderIDs.insert(trimmed).inserted else { return }
        persistProviders()
        bump()
    }

    /// Deletes the real persistent WebKit store through public APIs only.
    /// This runs only from the user's explicit website-data Delete action;
    /// it is never coupled to the advanced-AI switch or provider grant.
    /// No Safari, Keychain or private WebKit database is touched.
    func deleteAllWebsiteData() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
        let cookies = await store.httpCookieStore.allCookies()
        for cookie in cookies {
            await store.httpCookieStore.deleteCookie(cookie)
        }
    }

    private func persistProviders() {
        defaults.set(Array(authorizedProviderIDs).sorted(), forKey: Key.authorizedProviders)
    }

    private func bump() {
        revision &+= 1
    }
}

struct BrowserDataAuthorization: Sendable, Equatable {
    let provider: BrowserProviderIdentity
    let advancedGeneration: UInt64
}

struct BrowserProviderIdentity: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var isOfficial: Bool

    init(id: String, displayName: String, isOfficial: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.isOfficial = isOfficial
    }
}

/// The app wires the current provider identity here when the conversation's
/// provider changes. Browser data tools require an explicit one-time grant
/// for that exact identity. There is intentionally no per-call prompt and no
/// anonymous fallback: without a known provider identity the gate fails
/// closed instead of assuming the provider is trusted.
@MainActor
final class BrowserProviderTrustCoordinator: ObservableObject {
    static let shared = BrowserProviderTrustCoordinator(settings: .shared)

    /// Settings display only. It is never the authority for a running tool:
    /// a background run keeps the provider snapshot bound by the host below,
    /// even when the user selects another task/provider in the UI.
    @Published private(set) var currentProvider: BrowserProviderIdentity?

    private struct RunBinding {
        let provider: BrowserProviderIdentity
        let conversationID: UUID?
        let generation: UInt64
    }

    private let settings: BrowserSettingsService
    private var runBindings: [UUID: RunBinding] = [:]
    private var runBindingOrder: [UUID] = []
    private var nextBindingGeneration: UInt64 = 0
    private let maximumRunBindings = 512
    /// Optional app-owned checks. Existing provider grants may already live
    /// in the provider permission system; this hook lets the app reuse them
    /// instead of creating a parallel permission store.
    var existingGrantCheck: ((BrowserProviderIdentity) async -> Bool)?
    /// Optional one-time request surface for the Settings view only.
    var authorizationRequest: ((BrowserProviderIdentity) async -> Bool)?

    init(settings: BrowserSettingsService) {
        self.settings = settings
    }

    func setCurrentProvider(_ provider: BrowserProviderIdentity?) {
        currentProvider = provider
    }

    /// Host-only binding from the actual run service. The identity must come
    /// from the immutable provider/model snapshot of this run, never from a
    /// model argument, page content or the visible Settings selection.
    func bindProvider(
        runID: UUID,
        conversationID: UUID?,
        identity: BrowserProviderIdentity
    ) {
        let trimmed = identity.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var provider = identity
        provider.id = trimmed
        nextBindingGeneration &+= 1
        if runBindings[runID] == nil { runBindingOrder.append(runID) }
        runBindings[runID] = RunBinding(
            provider: provider,
            conversationID: conversationID,
            generation: nextBindingGeneration
        )
        while runBindingOrder.count > maximumRunBindings {
            let evicted = runBindingOrder.removeFirst()
            runBindings.removeValue(forKey: evicted)
        }
    }

    func unbindProvider(runID: UUID) {
        runBindings.removeValue(forKey: runID)
        runBindingOrder.removeAll { $0 == runID }
    }

    func providerForRun(_ runID: UUID) -> BrowserProviderIdentity? {
        runBindings[runID]?.provider
    }

    func isAuthorized(_ provider: BrowserProviderIdentity) -> Bool {
        settings.isProviderAuthorized(provider.id)
    }

    @discardableResult
    func authorizeCurrentProviderAfterUserConfirmation() -> Bool {
        guard let provider = currentProvider else { return false }
        settings.authorizeProvider(provider.id)
        return true
    }

    /// Reuses an existing provider grant when the app supplies one; otherwise
    /// only a previously recorded, explicit per-provider grant counts. This
    /// path is intentionally non-interactive: a tool call must never create a
    /// per-call or per-site re-authorization prompt.
    func ensureAuthorized(_ provider: BrowserProviderIdentity) async -> Bool {
        if settings.isProviderAuthorized(provider.id) { return true }
        if let existingGrantCheck, await existingGrantCheck(provider) {
            settings.authorizeProvider(provider.id)
            return true
        }
        return false
    }

    /// Explicit user-initiated authorization from the Browser settings view.
    func requestAuthorizationFromSettings(_ provider: BrowserProviderIdentity) async -> Bool {
        if let existingGrantCheck, await existingGrantCheck(provider) {
            settings.authorizeProvider(provider.id)
            return true
        }
        if let authorizationRequest, await authorizationRequest(provider) {
            settings.authorizeProvider(provider.id)
            return true
        }
        return false
    }

    /// Tool/transport gate. Authorization is bound to the trusted run, not to
    /// whichever provider the Settings UI currently displays. The binding is
    /// re-read after the await so a resumed/re-bound run can never authorize a
    /// different recipient mid-call.
    @discardableResult
    func requireBrowserDataAuthorization(
        runID: UUID,
        conversationID: UUID?
    ) async throws -> BrowserDataAuthorization {
        guard settings.advancedBrowserFeaturesEnabled,
              settings.advancedConsent?.isCurrent == true else {
            throw FloeError.validationFailed(
                "Advanced browser features are off. Enable them once in Browser settings after reviewing the privacy warning."
            )
        }
        let advancedGeneration = settings.advancedGeneration
        guard let binding = runBindings[runID] else {
            throw FloeError.validationFailed(
                "This run has no model-provider binding, so browser session data access is disabled."
            )
        }
        if let expected = binding.conversationID, let actual = conversationID,
           expected != actual {
            throw FloeError.validationFailed("The browser data request belongs to a different task")
        }
        let generation = binding.generation
        let provider = binding.provider
        guard await ensureAuthorized(provider) else {
            throw FloeError.validationFailed(
                "This model provider is not authorized for browser session data. Review Browser settings and authorize it once for this provider."
            )
        }
        guard settings.advancedBrowserFeaturesEnabled,
              settings.advancedConsent?.isCurrent == true,
              settings.advancedGeneration == advancedGeneration else {
            throw FloeError.validationFailed(
                "Advanced browser features were turned off while authorizing; no sensitive result was returned."
            )
        }
        guard let current = runBindings[runID],
              current.generation == generation,
              current.provider.id == provider.id else {
            throw FloeError.validationFailed(
                "The model provider binding changed while authorizing; retry the browser data action."
            )
        }
        return BrowserDataAuthorization(
            provider: provider,
            advancedGeneration: advancedGeneration
        )
    }

    /// Synchronous post-await check for a call that already captured its
    /// recipient. It refuses a run re-bound to another provider while the
    /// browser or WebKit store was awaiting.
    func revalidateBrowserDataAuthorization(
        runID: UUID,
        expectedProviderID: String,
        advancedGeneration: UInt64
    ) throws {
        guard settings.advancedBrowserFeaturesEnabled,
              settings.advancedConsent?.isCurrent == true,
              settings.advancedGeneration == advancedGeneration else {
            throw FloeError.validationFailed(
                "Advanced browser features were turned off during the action; the sensitive result was discarded."
            )
        }
        guard let binding = runBindings[runID],
              binding.provider.id == expectedProviderID,
              settings.isProviderAuthorized(expectedProviderID) else {
            throw FloeError.validationFailed(
                "The model provider changed or lost its grant during the browser data action; the result was not used."
            )
        }
    }
}
#endif
