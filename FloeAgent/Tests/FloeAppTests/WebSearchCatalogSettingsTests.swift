// FloeAppTests — user-instance search provider settings, v1 → v2 migration,
// per-instance Keychain ownership and reviewed signed-catalog updates.
//
// These tests use the REAL WebSearchSettingsCenter with synthetic storage
// seams (in-memory defaults/cloud/credential store and a feature-local MCP
// manager). The developer's iCloud defaults and the Keychain are never
// touched, and no network request is made.

import XCTest
import Foundation
@testable import FloeExecution
import FloeTools
@testable import FloeApp

@MainActor
final class WebSearchCatalogSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var cloud: CatalogFakeCloud!
    private var credentials: CatalogMemoryCredentials!
    private var dataPro: CatalogFakeDataPro!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "org.floeagent.tests.searchcatalog.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        cloud = CatalogFakeCloud()
        credentials = CatalogMemoryCredentials()
        dataPro = CatalogFakeDataPro()
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        cloud = nil
        credentials = nil
        dataPro = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeCenter() -> WebSearchSettingsCenter {
        WebSearchSettingsCenter(
            defaults: defaults,
            cloud: cloud,
            credentialStore: credentials.store,
            dataProManager: dataPro
        )
    }

    private func configuration(
        _ kind: WebSearchProviderKind,
        id: UUID = UUID(),
        name: String,
        enabled: Bool,
        account: String,
        endpoint: String? = nil,
        options: [String: String] = [:],
        priority: Int = 0
    ) -> WebSearchProviderConfiguration {
        WebSearchProviderConfiguration(
            id: id,
            kind: kind,
            displayName: name,
            endpoint: endpoint.flatMap(URL.init(string:)),
            credentialAccount: account,
            enabled: enabled,
            priority: priority,
            options: options
        )
    }

    private func instance(
        _ configuration: WebSearchProviderConfiguration,
        presetID: String? = nil,
        appliedCatalogVersion: String? = nil,
        overrides: Set<String> = [],
        catalogCredentialKeys: [String]? = ["apiKey"]
    ) -> WebSearchProviderInstance {
        WebSearchProviderInstance(
            configuration: configuration,
            presetID: presetID ?? SearchProviderPresets.presetID(for: configuration.kind),
            appliedCatalogVersion: appliedCatalogVersion,
            overrides: overrides,
            catalogCredentialKeys: catalogCredentialKeys
        )
    }

    /// A configuration whose Keychain account is owned by its own UUID, as
    /// the production add flow creates it.
    private func ownedConfiguration(
        _ kind: WebSearchProviderKind,
        name: String,
        enabled: Bool = false,
        endpoint: String? = nil
    ) -> WebSearchProviderConfiguration {
        let id = UUID()
        return WebSearchProviderConfiguration(
            id: id,
            kind: kind,
            displayName: name,
            endpoint: endpoint.flatMap(URL.init(string:)),
            credentialAccount: WebSearchProviderInstance.credentialAccount(for: id),
            enabled: enabled
        )
    }

    private func seedLegacy(_ records: [WebSearchProviderConfiguration]) throws {
        defaults.set(try JSONEncoder().encode(records), forKey: WebSearchSettingsCenter.defaultsKey)
    }

    private func catalogEntry(
        presetID: String = SearchProviderPresets.bocha,
        adapterKind: String = "bochaWeb",
        name: [String: String] = ["en": "Bocha Search", "zh-Hans": "博查搜索"],
        optionDefault: String? = "true",
        endpoint: String? = nil,
        managesEndpoint: Bool? = nil,
        credentialKeys: [String] = ["apiKey"]
    ) -> SearchProviderCatalogEntry {
        SearchProviderCatalogEntry(
            presetID: presetID,
            adapterKind: adapterKind,
            name: name,
            blurb: ["en": "Web search", "zh-Hans": "网页搜索"],
            defaultEndpoint: endpoint,
            endpointRequired: false,
            managesEndpoint: managesEndpoint,
            credentialFields: credentialKeys.map {
                .init(key: $0, required: true, label: ["en": $0, "zh-Hans": $0])
            },
            optionFields: [
                .init(
                    key: "summaryEnabled",
                    kind: .bool,
                    defaultValue: optionDefault,
                    allowedValues: nil,
                    label: ["en": "Summaries", "zh-Hans": "摘要"]
                )
            ]
        )
    }

    private func catalog(
        version: String,
        entries: [SearchProviderCatalogEntry]
    ) -> SearchProviderCatalogIndex {
        SearchProviderCatalogIndex(document: SearchProviderCatalogDocument(
            schemaVersion: 1,
            id: SearchProviderCatalog.packageID,
            version: version,
            entries: entries
        ))
    }

    private func credentialData(_ values: [String: String]) -> Data {
        try! JSONEncoder().encode(WebSearchCredential(values: values))
    }

    // MARK: - Package identity / bundled baseline

    func testBundledCatalogMatchesBaselineAndPackageIdentity() throws {
        XCTAssertEqual(ContentUpdateCenter.searchProviderPackageID, "floe.search.providers")
        XCTAssertEqual(SearchProviderCatalog.packageID, "floe.search.providers")
        XCTAssertEqual(ContentUpdateCenter.searchProviderCatalogPath, "SearchProviderCatalog.json")
        XCTAssertEqual(ContentUpdateCenter.builtInSearchProvidersVersion, "1.0.0")
        let bundled = try XCTUnwrap(SearchProviderCatalogIndex.loadBundled(bundle: .main))
        XCTAssertEqual(bundled.version, ContentUpdateCenter.builtInSearchProvidersVersion)
        XCTAssertEqual(bundled.entries.count, 9)
    }

    // MARK: - Fresh state

    func testFreshStoreIsEmptyAndNeverAutoCreatesPresets() throws {
        let center = makeCenter()
        XCTAssertTrue(center.instances.isEmpty, "no auto-created preset placeholders")
        XCTAssertTrue(center.providers.isEmpty)

        // The v2 store is pinned empty so a later catalog revision can never
        // auto-add instances; the legacy key stays untouched.
        let stored = try XCTUnwrap(defaults.data(forKey: WebSearchSettingsCenter.instancesKey))
        XCTAssertEqual(try JSONDecoder().decode([WebSearchProviderInstance].self, from: stored).count, 0)
        XCTAssertNil(defaults.data(forKey: WebSearchSettingsCenter.defaultsKey))

        // Reloading after a future catalog arrival keeps the list empty.
        let reloaded = makeCenter()
        XCTAssertTrue(reloaded.instances.isEmpty)
    }

    // MARK: - v1 migration

    func testLegacyMigrationKeepsConfiguredEntriesAndBacksUpPlaceholders() throws {
        let unusedBrave = configuration(
            .brave, name: "Brave Search", enabled: false, account: "web-search.brave", priority: 0
        )
        let usedBocha = configuration(
            .bochaWeb, name: "Bocha Search", enabled: true, account: "web-search.bochaWeb", priority: 1
        )
        let volcenginePreset = configuration(
            .volcengine,
            name: "Volcengine Web Search",
            enabled: false,
            account: "web-search.volcengine.\(UUID().uuidString.lowercased()).agentPlan",
            options: [VolcengineSearchOptions.Key.interface: VolcengineSearchInterface.agentPlan.rawValue],
            priority: 2
        )
        let custom = configuration(
            .custom, name: "Custom", enabled: false, account: "web-search.custom",
            endpoint: "https://search.example.com/api", priority: 3
        )
        try seedLegacy([unusedBrave, usedBocha, volcenginePreset, custom])
        credentials.storage["web-search.bochaWeb"] = credentialData(["apiKey": "bocha-key"])
        let originalLegacyBytes = try XCTUnwrap(defaults.data(forKey: WebSearchSettingsCenter.defaultsKey))

        let center = makeCenter()
        XCTAssertEqual(center.instances.count, 2, "only configured/customized records stay visible")
        XCTAssertFalse(center.instances.contains { $0.configuration.id == unusedBrave.id })
        XCTAssertFalse(center.instances.contains { $0.configuration.id == volcenginePreset.id })

        let bocha = try XCTUnwrap(center.instances.first { $0.configuration.kind == .bochaWeb })
        let instanceAccount = WebSearchProviderInstance.credentialAccount(for: usedBocha.id)
        XCTAssertEqual(bocha.configuration.credentialAccount, instanceAccount)
        XCTAssertEqual(
            center.credential(forAccount: instanceAccount)?.values["apiKey"],
            "bocha-key"
        )
        // The legacy entry remains as a backup and the v1 bytes are frozen.
        XCTAssertNotNil(credentials.storage["web-search.bochaWeb"])
        XCTAssertEqual(
            defaults.data(forKey: WebSearchSettingsCenter.defaultsKey),
            originalLegacyBytes
        )

        let customInstance = try XCTUnwrap(center.instances.first { $0.configuration.kind == .custom })
        XCTAssertTrue(customInstance.overrides.contains("endpoint"))
        XCTAssertEqual(customInstance.configuration.endpoint?.host, "search.example.com")

        let backup = try XCTUnwrap(defaults.data(forKey: WebSearchSettingsCenter.migrationBackupKey))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: backup) as? [String: Any])
        XCTAssertEqual((object["originalRecords"] as? [Any])?.count, 4)
    }

    func testBochaLegacyCredentialsAreCopiedPerInstanceWithoutGlobalRewrite() throws {
        let first = configuration(
            .bochaWeb, id: UUID(), name: "Bocha One", enabled: true,
            account: "web-search.bochaWeb", priority: 0
        )
        let second = configuration(
            .bochaWeb, id: UUID(), name: "Bocha Two", enabled: true,
            account: "web-search.bochaWeb.second", priority: 1
        )
        try seedLegacy([first, second])
        credentials.storage["web-search.bochaWeb"] = credentialData(["apiKey": "first-key"])
        credentials.storage["web-search.bochaWeb.second"] = credentialData(["apiKey": "second-key"])

        let center = makeCenter()
        XCTAssertEqual(center.instances.count, 2)
        let firstInstance = try XCTUnwrap(center.instances.first { $0.configuration.id == first.id })
        let secondInstance = try XCTUnwrap(center.instances.first { $0.configuration.id == second.id })
        XCTAssertEqual(
            firstInstance.configuration.credentialAccount,
            WebSearchProviderInstance.credentialAccount(for: first.id)
        )
        XCTAssertEqual(
            secondInstance.configuration.credentialAccount,
            WebSearchProviderInstance.credentialAccount(for: second.id)
        )
        XCTAssertNotEqual(
            firstInstance.configuration.credentialAccount,
            secondInstance.configuration.credentialAccount
        )
        XCTAssertEqual(
            center.credential(forAccount: firstInstance.configuration.credentialAccount)?.values["apiKey"],
            "first-key"
        )
        XCTAssertEqual(
            center.credential(forAccount: secondInstance.configuration.credentialAccount)?.values["apiKey"],
            "second-key"
        )
        // Custom display names survive the migration (no global Bocha rewrite).
        XCTAssertEqual(firstInstance.configuration.displayName, "Bocha One")
        XCTAssertEqual(secondInstance.configuration.displayName, "Bocha Two")
    }

    // MARK: - Instances and credentials

    func testMultipleAccountsOfSameKindUseIndependentKeychainEntries() throws {
        let center = makeCenter()
        let first = instance(
            ownedConfiguration(.brave, name: "Brave Work", enabled: true)
        )
        let second = instance(
            ownedConfiguration(.brave, name: "Brave Personal", enabled: true)
        )
        try center.saveInstance(first, credential: WebSearchCredential(values: ["apiKey": "work-key"]))
        try center.saveInstance(second, credential: WebSearchCredential(values: ["apiKey": "personal-key"]))

        XCTAssertEqual(center.instances.count, 2)
        let storedFirst = try XCTUnwrap(center.instances.first { $0.configuration.id == first.configuration.id })
        let storedSecond = try XCTUnwrap(center.instances.first { $0.configuration.id == second.configuration.id })
        XCTAssertNotEqual(storedFirst.configuration.credentialAccount, storedSecond.configuration.credentialAccount)
        XCTAssertEqual(center.credential(forAccount: storedFirst.configuration.credentialAccount)?.values["apiKey"], "work-key")
        XCTAssertEqual(center.credential(forAccount: storedSecond.configuration.credentialAccount)?.values["apiKey"], "personal-key")
        // New instances start disabled; enabling is the user's own switch.
        XCTAssertFalse(storedFirst.configuration.enabled)
        XCTAssertFalse(storedSecond.configuration.enabled)
        center.setEnabled(true, id: storedFirst.configuration.id)
        XCTAssertTrue(center.instances.first { $0.configuration.id == storedFirst.configuration.id }?.configuration.enabled == true)
        XCTAssertFalse(center.instances.first { $0.configuration.id == storedSecond.configuration.id }?.configuration.enabled == true)

        // Editing one key never touches the other account.
        var edited = try XCTUnwrap(center.instances.first { $0.configuration.id == storedFirst.configuration.id })
        edited.configuration.displayName = "Brave Work 2"
        try center.saveInstance(edited, credential: WebSearchCredential(values: ["apiKey": "work-key-2"]))
        XCTAssertEqual(center.credential(forAccount: storedSecond.configuration.credentialAccount)?.values["apiKey"], "personal-key")
    }

    func testUpsertKeepsExistingCatalogProvenance() throws {
        let center = makeCenter()
        var configuration = self.configuration(
            .brave, name: "Brave", enabled: false,
            account: WebSearchProviderInstance.credentialAccount(for: UUID())
        )
        let saved = instance(
            configuration,
            presetID: "brave",
            appliedCatalogVersion: "1.0.0",
            catalogCredentialKeys: ["apiKey"]
        )
        try center.saveInstance(saved, credential: WebSearchCredential(values: ["apiKey": "k"]))
        configuration = saved.configuration
        configuration.displayName = "Renamed"
        try center.upsert(configuration, credential: nil)

        let stored = try XCTUnwrap(center.instances.first)
        XCTAssertEqual(stored.configuration.displayName, "Renamed")
        XCTAssertEqual(stored.presetID, "brave")
        XCTAssertEqual(stored.appliedCatalogVersion, "1.0.0")
        XCTAssertEqual(stored.catalogCredentialKeys, ["apiKey"])
        XCTAssertTrue(stored.overrides.contains("displayName"))
    }

    func testUnreadyConfigurationIsSavedDisabled() throws {
        let center = makeCenter()
        var ready = instance(
            configuration(.brave, name: "Brave", enabled: false,
                          account: WebSearchProviderInstance.credentialAccount(for: UUID()))
        )
        try center.saveInstance(ready, credential: WebSearchCredential(values: ["apiKey": "k"]))
        center.setEnabled(true, id: ready.configuration.id)
        XCTAssertTrue(center.instances.first?.configuration.enabled == true)

        // Re-saving without a supplied or stored key is allowed but disabled;
        // the previously stored key remains untouched.
        ready = try XCTUnwrap(center.instances.first)
        ready.configuration.enabled = true
        ready.configuration.credentialAccount = WebSearchProviderInstance.credentialAccount(for: UUID())
        try center.saveInstance(ready, credential: nil)
        XCTAssertEqual(center.instances.first?.configuration.enabled, false)

        // A new instance is always saved disabled even if requested enabled.
        var fresh = instance(
            configuration(.brave, name: "Brave Two", enabled: true,
                          account: WebSearchProviderInstance.credentialAccount(for: UUID()))
        )
        fresh.configuration.enabled = true
        try center.saveInstance(fresh, credential: WebSearchCredential(values: ["apiKey": "k2"]))
        XCTAssertEqual(
            center.instances.first { $0.configuration.id == fresh.configuration.id }?.configuration.enabled,
            false
        )
    }

    // MARK: - Reviewed catalog updates

    func testCatalogUpdateMarksAndAppliesOnlyUnoverriddenFields() throws {
        let center = makeCenter()
        let bocha = instance(
            configuration(.bochaWeb, name: "Bocha Search", enabled: true,
                          account: WebSearchProviderInstance.credentialAccount(for: UUID())),
            presetID: SearchProviderPresets.bocha,
            appliedCatalogVersion: "1.0.0",
            overrides: ["displayName"]
        )
        try center.saveInstance(bocha, credential: WebSearchCredential(values: ["apiKey": "k"]))
        // New saved instances start disabled; the row switch is the user's
        // independent enablement control.
        center.setEnabled(true, id: bocha.configuration.id)
        let stored = try XCTUnwrap(center.instances.first)

        let newer = catalog(version: "1.1.0", entries: [
            catalogEntry(
                name: ["en": "Bocha Web Search", "zh-Hans": "博查网页搜索"],
                optionDefault: "false"
            )
        ])
        let plan = try XCTUnwrap(center.updatePlan(for: stored, catalog: newer))
        XCTAssertEqual(plan.changes.count, 1, "the overridden display name is not proposed")
        XCTAssertFalse(plan.requiresConfirmation)

        let applied = try center.applyCatalogUpdate(
            plan, to: stored.configuration.id, catalog: newer, confirmed: false
        )
        XCTAssertEqual(applied.configuration.displayName, "Bocha Search", "user name wins")
        XCTAssertEqual(applied.configuration.options["summaryEnabled"], "false")
        XCTAssertEqual(applied.configuration.enabled, true)
        XCTAssertEqual(applied.configuration.credentialAccount, stored.configuration.credentialAccount)
        XCTAssertEqual(applied.appliedCatalogVersion, "1.1.0")
        XCTAssertEqual(
            center.instances.first?.configuration.options["summaryEnabled"],
            "false"
        )

        // Re-applying the same revision is a no-op.
        let persisted = try XCTUnwrap(center.instances.first)
        XCTAssertNil(center.updatePlan(for: persisted, catalog: newer))
    }

    func testApplyCatalogUpdateNormalizesOnceAndPersistsOnce() throws {
        let center = makeCenter()
        let bocha = instance(
            configuration(.bochaWeb, name: "Bocha Search", enabled: true,
                          account: WebSearchProviderInstance.credentialAccount(for: UUID()),
                          options: ["summaryEnabled": "true"]),
            presetID: SearchProviderPresets.bocha,
            appliedCatalogVersion: "1.0.0"
        )
        try center.saveInstance(bocha, credential: WebSearchCredential(values: ["apiKey": "k"]))
        let stored = try XCTUnwrap(center.instances.first)

        let newer = catalog(version: "1.1.0", entries: [
            catalogEntry(
                name: ["en": "Bocha Web Search", "zh-Hans": "博查网页搜索"],
                optionDefault: "false"
            )
        ])
        let plan = try XCTUnwrap(center.updatePlan(for: stored, catalog: newer))
        XCTAssertEqual(plan.changes.count, 1, "only the real option diff is reviewed")

        let writesBefore = cloud.synchronizeCount
        let applied = try center.applyCatalogUpdate(
            plan, to: stored.configuration.id, catalog: newer, confirmed: false
        )
        // One reviewed apply writes the store exactly once: the official title
        // is normalized inside the same assignment instead of a second,
        // global title-sync pass.
        XCTAssertEqual(cloud.synchronizeCount, writesBefore + 1)
        let expected = newer.entries[0].displayName(
            localePrimary: WebSearchSettingsCenter.localePrimary
        )
        XCTAssertEqual(applied.configuration.displayName, expected)
        XCTAssertEqual(applied.configuration.options["summaryEnabled"], "false")
        XCTAssertEqual(applied.appliedCatalogVersion, "1.1.0")
        // The returned value is the stored instance, not a stale pre-sync copy.
        XCTAssertEqual(applied, try XCTUnwrap(center.instances.first))
        XCTAssertEqual(
            makeCenter().instances.first?.configuration.displayName, expected,
            "the single write persisted the normalized title"
        )
    }

    // MARK: - Official supplier title semantics
    //
    // The supplier display name is catalog-owned cosmetic metadata unless the
    // user personally renamed the instance. A saved official default (the
    // M4 case: legacy English preset names against a Chinese catalog) must
    // never be offered as a meaningless name-only "Available Update"; it
    // refreshes automatically through the existing store lifecycle. A real
    // alias persists through every later revision, reload and re-sync.

    func testNameOnlyCatalogRenameOffersNoUpdateAndOfficialTitleRefreshesAutomatically() throws {
        let center = makeCenter()
        let bocha = instance(
            configuration(.bochaWeb, name: "Bocha Search", enabled: true,
                          account: WebSearchProviderInstance.credentialAccount(for: UUID()),
                          options: ["summaryEnabled": "true"]),
            presetID: SearchProviderPresets.bocha,
            appliedCatalogVersion: "1.0.0"
        )
        try center.saveInstance(bocha, credential: WebSearchCredential(values: ["apiKey": "k"]))
        center.setEnabled(true, id: bocha.configuration.id)
        let stored = try XCTUnwrap(center.instances.first)

        let renamed = catalog(version: "1.1.0", entries: [
            catalogEntry(name: ["en": "Bocha Web Search", "zh-Hans": "博查网页搜索"])
        ])
        // 1. A pure supplier rename is never a reviewable config change.
        XCTAssertNil(center.updatePlan(for: stored, catalog: renamed))
        // 2. The official title of the saved default refreshes automatically.
        let expected = renamed.entries[0].displayName(
            localePrimary: WebSearchSettingsCenter.localePrimary
        )
        XCTAssertEqual(center.synchronizeCatalogTitles(catalog: renamed), 1)
        let synced = try XCTUnwrap(center.instances.first)
        XCTAssertEqual(synced.configuration.displayName, expected)
        XCTAssertEqual(synced.overrides, [], "a saved official default never becomes a user alias")
        XCTAssertEqual(synced.appliedCatalogVersion, "1.0.0",
                       "the reviewed marker only advances through applyCatalogUpdate")
        XCTAssertEqual(synced.configuration.enabled, true, "the user switch survives the refresh")
        XCTAssertEqual(synced.configuration.credentialAccount, stored.configuration.credentialAccount)
        XCTAssertEqual(center.credential(forAccount: synced.configuration.credentialAccount)?.values["apiKey"], "k")
        // 3. Persisted: a fresh center over the same storage reloads the synced title.
        XCTAssertEqual(makeCenter().instances.first?.configuration.displayName, expected)
        // 4. Idempotent.
        XCTAssertEqual(center.synchronizeCatalogTitles(catalog: renamed), 0)
    }

    func testUserRenamedAliasSurvivesCatalogRenameSyncAndReload() throws {
        let center = makeCenter()
        let bocha = instance(
            configuration(.bochaWeb, name: "My Bocha", enabled: true,
                          account: WebSearchProviderInstance.credentialAccount(for: UUID()),
                          options: ["summaryEnabled": "true"]),
            presetID: SearchProviderPresets.bocha,
            appliedCatalogVersion: "1.0.0",
            overrides: ["displayName"]
        )
        try center.saveInstance(bocha, credential: WebSearchCredential(values: ["apiKey": "k"]))
        center.setEnabled(true, id: bocha.configuration.id)
        let renamed = catalog(version: "1.1.0", entries: [
            catalogEntry(name: ["en": "Bocha Web Search", "zh-Hans": "博查网页搜索"])
        ])
        XCTAssertNil(center.updatePlan(for: try XCTUnwrap(center.instances.first), catalog: renamed))
        XCTAssertEqual(center.synchronizeCatalogTitles(catalog: renamed), 0,
                       "an actual alias is never renamed by the catalog")
        XCTAssertEqual(center.instances.first?.configuration.displayName, "My Bocha")
        XCTAssertEqual(makeCenter().instances.first?.configuration.displayName, "My Bocha")
    }

    func testTwoAccountsOfSameBrandRefreshIndependently() throws {
        let center = makeCenter()
        let official = instance(
            configuration(.bochaWeb, name: "Bocha Search", enabled: false,
                          account: WebSearchProviderInstance.credentialAccount(for: UUID())),
            presetID: SearchProviderPresets.bocha, appliedCatalogVersion: "1.0.0"
        )
        let aliased = instance(
            configuration(.bochaWeb, id: UUID(), name: "Work Bocha", enabled: false,
                          account: WebSearchProviderInstance.credentialAccount(for: UUID())),
            presetID: SearchProviderPresets.bocha, appliedCatalogVersion: "1.0.0",
            overrides: ["displayName"]
        )
        try center.saveInstance(official, credential: WebSearchCredential(values: ["apiKey": "one"]))
        try center.saveInstance(aliased, credential: WebSearchCredential(values: ["apiKey": "two"]))
        let renamed = catalog(version: "1.1.0", entries: [
            catalogEntry(name: ["en": "Bocha Web Search", "zh-Hans": "博查网页搜索"])
        ])
        XCTAssertEqual(center.synchronizeCatalogTitles(catalog: renamed), 1)
        let expected = renamed.entries[0].displayName(
            localePrimary: WebSearchSettingsCenter.localePrimary
        )
        XCTAssertEqual(
            center.instances.first { $0.configuration.id == official.configuration.id }?
                .configuration.displayName, expected
        )
        XCTAssertEqual(
            center.instances.first { $0.configuration.id == aliased.configuration.id }?
                .configuration.displayName, "Work Bocha"
        )
        // Both instances still own separate Keychain accounts and keys.
        let officialAccount = try XCTUnwrap(
            center.instances.first { $0.configuration.id == official.configuration.id }
        ).configuration.credentialAccount
        let aliasedAccount = try XCTUnwrap(
            center.instances.first { $0.configuration.id == aliased.configuration.id }
        ).configuration.credentialAccount
        XCTAssertNotEqual(officialAccount, aliasedAccount)
        XCTAssertEqual(center.credential(forAccount: officialAccount)?.values["apiKey"], "one")
        XCTAssertEqual(center.credential(forAccount: aliasedAccount)?.values["apiKey"], "two")
    }

    func testMeaningfulUpdateStillAppliesWithHostConfirmationAndRefreshesOfficialTitle() throws {
        let center = makeCenter()
        let bocha = instance(
            configuration(.bochaWeb, name: "Bocha Search", enabled: false,
                          account: WebSearchProviderInstance.credentialAccount(for: UUID()),
                          endpoint: "https://old.example.com/search",
                          options: ["summaryEnabled": "true"]),
            presetID: SearchProviderPresets.bocha,
            appliedCatalogVersion: "1.0.0"
        )
        try center.saveInstance(bocha, credential: WebSearchCredential(values: ["apiKey": "old-key"]))
        center.setEnabled(true, id: bocha.configuration.id)
        let stored = try XCTUnwrap(center.instances.first)
        let oldAccount = stored.configuration.credentialAccount

        let newer = catalog(version: "1.2.0", entries: [
            catalogEntry(
                name: ["en": "Bocha Web Search", "zh-Hans": "博查网页搜索"],
                optionDefault: "false",
                endpoint: "https://new.example.com/search",
                managesEndpoint: true
            )
        ])
        let plan = try XCTUnwrap(center.updatePlan(for: stored, catalog: newer))
        // The card shows exactly the real diffs: endpoint + option default.
        // The rename never appears as a user-field change.
        XCTAssertEqual(plan.changes.count, 2)
        XCTAssertTrue(plan.changes.contains { if case .endpoint = $0.field { return true }; return false })
        XCTAssertTrue(plan.changes.contains {
            if case .option("summaryEnabled") = $0.field { return true }; return false
        })
        XCTAssertTrue(plan.touchesHost)
        XCTAssertTrue(plan.requiresConfirmation)

        XCTAssertThrowsError(try center.applyCatalogUpdate(
            plan, to: stored.configuration.id, catalog: newer, confirmed: false
        )) { error in
            XCTAssertEqual(error as? WebSearchSettingsError, .confirmationRequired)
        }
        let afterRefusal = try XCTUnwrap(center.instances.first)
        XCTAssertEqual(afterRefusal.configuration.endpoint?.host, "old.example.com",
                       "an unconfirmed host change merges nothing")
        XCTAssertEqual(afterRefusal.configuration.credentialAccount, oldAccount)
        XCTAssertEqual(center.credential(forAccount: oldAccount)?.values["apiKey"], "old-key")

        let applied = try center.applyCatalogUpdate(
            plan, to: stored.configuration.id, catalog: newer, confirmed: true
        )
        XCTAssertEqual(applied.configuration.endpoint?.host, "new.example.com")
        XCTAssertNotEqual(applied.configuration.credentialAccount, oldAccount, "host change rotates the account")
        XCTAssertNil(center.credential(forAccount: applied.configuration.credentialAccount),
                     "the new account starts empty: the old key never follows to the new host")
        XCTAssertNotNil(center.credential(forAccount: oldAccount), "the old key stays as a backup")
        XCTAssertEqual(applied.configuration.options["summaryEnabled"], "false")
        XCTAssertEqual(applied.configuration.enabled, true)
        XCTAssertEqual(applied.appliedCatalogVersion, "1.2.0")
        // The official title advanced automatically with the reviewed real update.
        XCTAssertEqual(applied.configuration.displayName,
                       newer.entries[0].displayName(localePrimary: WebSearchSettingsCenter.localePrimary))
    }

    func testMergedOverridesKeepsFormerOfficialNamesCatalogOwnedAndMarksRealAliases() {
        let renamedEntry = catalogEntry(name: ["en": "Bocha Web Search", "zh-Hans": "博查网页搜索"])
        func config(_ name: String) -> WebSearchProviderConfiguration {
            configuration(.bochaWeb, name: name, enabled: true,
                          account: WebSearchProviderInstance.credentialAccount(for: UUID()))
        }
        // A user-typed alias is marked.
        XCTAssertTrue(WebSearchProviderEditor.mergedOverrides(
            existing: [], configuration: config("My Bocha"), previousName: "Bocha Search",
            entry: renamedEntry
        ).contains("displayName"))
        // A name equal to a current official title is catalog-owned.
        XCTAssertFalse(WebSearchProviderEditor.mergedOverrides(
            existing: [], configuration: config("Bocha Web Search"), previousName: "Bocha Search",
            entry: renamedEntry
        ).contains("displayName"))
        // The carried-over former official name stays catalog-owned even after
        // the catalog renamed it: saving a config is not an alias.
        XCTAssertFalse(WebSearchProviderEditor.mergedOverrides(
            existing: [], configuration: config("Bocha Search"), previousName: "Bocha Search",
            entry: renamedEntry
        ).contains("displayName"))
        // An unchanged genuine alias keeps its marking.
        XCTAssertTrue(WebSearchProviderEditor.mergedOverrides(
            existing: ["displayName"], configuration: config("My Bocha"), previousName: "My Bocha",
            entry: renamedEntry
        ).contains("displayName"))
        // Reverting an alias back to any official title clears the marking.
        XCTAssertFalse(WebSearchProviderEditor.mergedOverrides(
            existing: ["displayName"], configuration: config("博查网页搜索"), previousName: "My Bocha",
            entry: renamedEntry
        ).contains("displayName"))
    }

    func testHostChangeRequiresConfirmationAndRotatesTheCredentialAccount() throws {
        let center = makeCenter()
        var configuration = self.configuration(
            .bochaWeb, name: "Bocha", enabled: true,
            account: WebSearchProviderInstance.credentialAccount(for: UUID()),
            endpoint: "https://old.example.com/search"
        )
        let bocha = instance(
            configuration,
            presetID: SearchProviderPresets.bocha,
            appliedCatalogVersion: "1.0.0"
        )
        try center.saveInstance(bocha, credential: WebSearchCredential(values: ["apiKey": "old-key"]))
        center.setEnabled(true, id: bocha.configuration.id)
        let stored = try XCTUnwrap(center.instances.first)
        let oldAccount = stored.configuration.credentialAccount
        XCTAssertNotNil(center.credential(forAccount: oldAccount))

        let newer = catalog(version: "1.2.0", entries: [
            catalogEntry(
                name: ["en": "Bocha Search", "zh-Hans": "博查搜索"],
                endpoint: "https://new.example.com/search",
                managesEndpoint: true
            )
        ])
        let plan = try XCTUnwrap(center.updatePlan(for: stored, catalog: newer))
        XCTAssertTrue(plan.touchesHost)
        XCTAssertTrue(plan.requiresConfirmation)

        XCTAssertThrowsError(try center.applyCatalogUpdate(
            plan, to: stored.configuration.id, catalog: newer, confirmed: false
        )) { error in
            XCTAssertEqual(error as? WebSearchSettingsError, .confirmationRequired)
        }
        XCTAssertEqual(center.instances.first?.configuration.credentialAccount, oldAccount)
        XCTAssertEqual(center.instances.first?.configuration.endpoint?.host, "old.example.com")

        let applied = try center.applyCatalogUpdate(
            plan, to: stored.configuration.id, catalog: newer, confirmed: true
        )
        XCTAssertEqual(applied.configuration.endpoint?.host, "new.example.com")
        XCTAssertNotEqual(applied.configuration.credentialAccount, oldAccount)
        // The old key is preserved as a backup and the new account is empty:
        // the stored secret can never be sent to the new destination.
        XCTAssertNotNil(center.credential(forAccount: oldAccount))
        XCTAssertNil(center.credential(forAccount: applied.configuration.credentialAccount))
        XCTAssertEqual(applied.configuration.enabled, true)
    }

    func testRemovedCatalogEntryKeepsTheInstance() throws {
        let center = makeCenter()
        let bocha = instance(
            configuration(.bochaWeb, name: "Bocha", enabled: true,
                          account: WebSearchProviderInstance.credentialAccount(for: UUID())),
            presetID: SearchProviderPresets.bocha,
            appliedCatalogVersion: "1.0.0"
        )
        try center.saveInstance(bocha, credential: WebSearchCredential(values: ["apiKey": "k"]))
        let stored = try XCTUnwrap(center.instances.first)
        let withoutBocha = catalog(version: "1.3.0", entries: [
            catalogEntry(presetID: "brave", adapterKind: "brave", name: ["en": "Brave", "zh-Hans": "Brave"])
        ])
        XCTAssertNil(center.updatePlan(for: stored, catalog: withoutBocha))
        XCTAssertEqual(center.instances.count, 1)
        XCTAssertEqual(center.instances.first?.configuration.displayName, "Bocha")
    }

    // MARK: - Ordering and deletion

    func testReorderingUpdatesPriorityAndDeletionKeepsLegacyBackups() throws {
        let center = makeCenter()
        for index in 0..<3 {
            let item = instance(
                ownedConfiguration(.brave, name: "Brave \(index)"),
                catalogCredentialKeys: ["apiKey"]
            )
            try center.saveInstance(item, credential: WebSearchCredential(values: ["apiKey": "key-\(index)"]))
        }
        XCTAssertEqual(center.instances.map(\.configuration.priority), [0, 1, 2])
        center.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(center.instances.map(\.configuration.displayName), ["Brave 2", "Brave 0", "Brave 1"])
        XCTAssertEqual(center.instances.map(\.configuration.priority), [0, 1, 2])

        let removed = try XCTUnwrap(center.instances.first)
        let removedAccount = removed.configuration.credentialAccount
        let legacyAccount = "web-search.brave"
        credentials.storage[legacyAccount] = credentialData(["apiKey": "legacy"])
        center.remove(id: removed.configuration.id)
        XCTAssertEqual(center.instances.count, 2)
        XCTAssertNil(center.credential(forAccount: removedAccount), "instance-owned key removed")
        XCTAssertNotNil(credentials.storage[legacyAccount], "shared legacy key kept as backup")
        XCTAssertEqual(center.instances.map(\.configuration.priority), [0, 1])
    }

    // MARK: - Test Search entry point

    func testTestSearchReportsNotConfiguredWithoutCredential() async {
        let center = makeCenter()
        let draft = configuration(
            .brave, name: "Brave", enabled: true,
            account: WebSearchProviderInstance.credentialAccount(for: UUID())
        )
        let outcome = await center.testSearch(
            configuration: draft,
            credential: WebSearchCredential(values: ["apiKey": "  "]),
            query: "anything"
        )
        XCTAssertEqual(outcome.error, WebSearchTestOutcome.notConfiguredReason)
        XCTAssertTrue(outcome.results.isEmpty)
    }

    func testVolcengineEnabledUpsertStillRequiresCredential() throws {
        let center = makeCenter()
        let id = UUID()
        let configuration = WebSearchProviderConfiguration(
            id: id,
            kind: .volcengine,
            displayName: "Volcengine",
            endpoint: nil,
            credentialAccount: VolcengineSettingsDraft.perProviderCredentialAccount(
                for: id, interface: .agentPlan
            ),
            enabled: true,
            options: [VolcengineSearchOptions.Key.interface: VolcengineSearchInterface.agentPlan.rawValue]
        )
        XCTAssertThrowsError(try center.upsert(configuration, credential: nil)) { error in
            XCTAssertEqual(error as? VolcengineSearchSettingsError, .missingCredential)
        }
        XCTAssertTrue(center.instances.isEmpty)
    }
}

// MARK: - Synthetic storage seams

private final class CatalogFakeCloud: WebSearchCloudStoring {
    var storage: [String: Data] = [:]
    var synchronizeCount = 0
    var notificationObject: AnyObject? { nil }
    var externalChangeNotification: Notification.Name {
        Notification.Name("org.floeagent.tests.searchcatalog.cloud")
    }

    func data(forKey key: String) -> Data? { storage[key] }
    func set(_ data: Data?, forKey key: String) { storage[key] = data }
    func synchronize() { synchronizeCount += 1 }
}

private final class CatalogMemoryCredentials: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Data] = [:]

    var storage: [String: Data] {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    var store: WebSearchCredentialStore {
        WebSearchCredentialStore(
            read: { [self] account in
                lock.lock()
                defer { lock.unlock() }
                return stored[account]
            },
            write: { [self] account, data in
                lock.lock()
                stored[account] = data
                lock.unlock()
            },
            delete: { [self] account in
                lock.lock()
                stored.removeValue(forKey: account)
                lock.unlock()
            }
        )
    }
}

@MainActor
private final class CatalogFakeDataPro: VolcengineDataProManaging {
    func upsert(_ server: MCPServerConfiguration, credential: String?) async throws {}
    func setEnabled(_ enabled: Bool, serverID: UUID) {}
    func currentServer(serverID: UUID) -> MCPServerConfiguration? { nil }
    func state(serverID: UUID) -> VolcengineDataProState { .inactive }
    func refresh(serverID: UUID) async {}
    func observeState(
        serverID: UUID,
        onChange: @escaping @MainActor (VolcengineDataProState) -> Void
    ) -> VolcengineDataProObservation {
        onChange(.inactive)
        return VolcengineDataProObservation {}
    }
}
