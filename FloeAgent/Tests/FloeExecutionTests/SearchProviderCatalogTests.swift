// FloeExecutionTests — signed search-provider catalog, instance provenance,
// reviewed catalog updates and the v1 → v2 instance migration.
//
// Pure and deterministic: no network, no Keychain, no app target. The bundled
// catalog is read from the checkout so the shipped defaults are part of the
// contract, and the staged content-hub envelope is checked for the
// catalog-aware minimum app version (1.7.65).

import Foundation
import Testing
@testable import FloeExecution

@Suite("Search provider catalog")
struct SearchProviderCatalogTests {

    // MARK: - Fixtures

    static var repoRoot: URL {
        var candidate = URL(fileURLWithPath: #filePath)
        if !candidate.path.hasPrefix("/") {
            candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(candidate.path)
        }
        while candidate.path != "/" {
            let probe = candidate.appendingPathComponent("FloeAgent/FloeApp/Resources/SearchProviderCatalog.json")
            if FileManager.default.fileExists(atPath: probe.path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return candidate
    }

    static var bundledURL: URL {
        repoRoot.appendingPathComponent("FloeAgent/FloeApp/Resources/SearchProviderCatalog.json")
    }

    static func bundledData() throws -> Data {
        try Data(contentsOf: bundledURL)
    }

    static func bundledIndex() throws -> SearchProviderCatalogIndex {
        try SearchProviderCatalogIndex.validated(from: bundledData())
    }

    /// Builds a catalog document with the bundled entries, a different
    /// version and an optional mutation of the Bocha entry.
    static func catalogIndex(
        version: String,
        mutateEntry: ((inout [String: Any]) -> Void)? = nil
    ) throws -> SearchProviderCatalogIndex {
        var object = try #require(
            try JSONSerialization.jsonObject(with: bundledData()) as? [String: Any]
        )
        object["version"] = version
        var entries = try #require(object["entries"] as? [[String: Any]])
        if let mutateEntry {
            mutateEntry(&entries[0])
        }
        object["entries"] = entries
        return try SearchProviderCatalogIndex.validated(
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    static func configuration(
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

    static func bochaInstance(
        appliedVersion: String = "1.0.0",
        overrides: Set<String> = []
    ) -> WebSearchProviderInstance {
        WebSearchProviderInstance(
            configuration: configuration(
                .bochaWeb,
                name: "Bocha Search",
                enabled: true,
                account: WebSearchProviderInstance.credentialAccount(for: UUID())
            ),
            presetID: SearchProviderPresets.bocha,
            appliedCatalogVersion: appliedVersion,
            overrides: overrides,
            catalogCredentialKeys: ["apiKey"]
        )
    }

    /// Asserts one exact catalog-domain error without relying on a specific
    /// error-matching overload.
    static func expectCatalogError(
        _ expected: SearchProviderCatalogError,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            Issue.record("expected \(expected)", sourceLocation: sourceLocation)
        } catch {
            #expect(error as? SearchProviderCatalogError == expected)
        }
    }

    // MARK: - Bundled document

    @Test("Bundled catalog maps exactly the compiled adapters with bilingual copy")
    func bundledCatalogMatchesCompiledAdapters() throws {
        let index = try Self.bundledIndex()
        #expect(index.document.id == "floe.search.providers")
        #expect(index.document.version == "1.1.0")
        #expect(index.entries.count == 10)
        let mapping = Dictionary(uniqueKeysWithValues: index.entries.map { ($0.presetID, $0.adapterKind) })
        #expect(mapping == [
            "bocha": "bochaWeb",
            "tencent-wsa": "tencentWSA",
            "volcengine": "volcengine",
            "deepseek": "deepseek",
            "brave": "brave",
            "tavily": "tavily",
            "exa": "exa",
            "google-programmable": "googleProgrammable",
            "searxng": "searxng",
            "custom-interface": "custom"
        ])
        for entry in index.entries {
            #expect(!entry.name.isEmpty)
            #expect(entry.name["en"]?.isEmpty == false)
            #expect(entry.name["zh-Hans"]?.isEmpty == false)
            #expect(entry.blurb["en"]?.isEmpty == false)
            #expect(entry.blurb["zh-Hans"]?.isEmpty == false)
            // The catalog never carries enablement or secrets.
            #expect(entry.managesEndpoint != true)
            #expect(entry.credentialFields.allSatisfy { !$0.key.isEmpty })
            #expect(entry.credentialFields.allSatisfy { $0.label["en"]?.isEmpty == false })
            if entry.endpointRequired {
                #expect(entry.defaultEndpoint == nil)
            }
            if let endpoint = entry.defaultEndpoint {
                #expect(endpoint.hasPrefix("https://"))
            }
        }
        #expect(index.entry(presetID: "searxng")?.credentialKeys.isEmpty == true)
        #expect(index.entry(presetID: "google-programmable")?.credentialKeys == ["apiKey", "engineId"])
    }

    @Test("Local catalog search is deterministic and bilingual")
    func searchIsDeterministicAndLocalized() throws {
        let index = try Self.bundledIndex()
        #expect(index.search(query: "", localePrimary: "en").count == 10)
        #expect(index.search(query: "deepseek", localePrimary: "en").map(\.presetID) == ["deepseek"])
        #expect(index.search(query: "DeepSeek", localePrimary: "zh-Hans").map(\.presetID) == ["deepseek"])
        #expect(index.search(query: "brave", localePrimary: "en").map(\.presetID) == ["brave"])
        #expect(index.search(query: "博查", localePrimary: "zh-Hans").map(\.presetID) == ["bocha"])
        #expect(index.search(query: "  BOCHA  ", localePrimary: "en").map(\.presetID) == ["bocha"])
        #expect(index.search(query: "no-such-provider", localePrimary: "en").isEmpty)
    }

    @Test("Structural failures reject the whole document")
    func structuralFailuresRejectWholeDocument() throws {
        func document(
            schemaVersion: Int = 1,
            id: String = "floe.search.providers",
            version: String = "1.0.0",
            entries: [[String: Any]] = []
        ) -> Data {
            let object: [String: Any] = [
                "schemaVersion": schemaVersion,
                "id": id,
                "version": version,
                "entries": entries
            ]
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        }
        Self.expectCatalogError(.schemaVersionUnsupported) {
            _ = try SearchProviderCatalogDocument.validated(from: document(schemaVersion: 2))
        }
        Self.expectCatalogError(.packageIdentityMismatch) {
            _ = try SearchProviderCatalogDocument.validated(from: document(id: "other.package"))
        }
        Self.expectCatalogError(.emptyEntries) {
            _ = try SearchProviderCatalogDocument.validated(from: document())
        }
        Self.expectCatalogError(.invalidVersion("1.0")) {
            _ = try SearchProviderCatalogDocument.validated(from: document(version: "1.0"))
        }
        // Duplicate preset ids: re-use the bundled Bocha entry twice.
        var object = try #require(try JSONSerialization.jsonObject(with: Self.bundledData()) as? [String: Any])
        var entries = try #require(object["entries"] as? [[String: Any]])
        entries.append(entries[0])
        object["entries"] = entries
        Self.expectCatalogError(.duplicatePresetID("bocha")) {
            _ = try SearchProviderCatalogDocument.validated(
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
        // Non-HTTPS default endpoints are rejected.
        var httpObject = try #require(try JSONSerialization.jsonObject(with: Self.bundledData()) as? [String: Any])
        var httpEntries = try #require(httpObject["entries"] as? [[String: Any]])
        httpEntries[0]["defaultEndpoint"] = "http://api.bochaai.com/v1/web-search"
        httpObject["entries"] = httpEntries
        Self.expectCatalogError(.invalidEndpoint("bocha")) {
            _ = try SearchProviderCatalogDocument.validated(
                from: JSONSerialization.data(withJSONObject: httpObject)
            )
        }
        // Oversized payloads never reach the decoder.
        Self.expectCatalogError(.oversized) {
            _ = try SearchProviderCatalogDocument.validated(
                from: Data(repeating: 0x7B, count: SearchProviderCatalog.maximumDocumentBytes + 1)
            )
        }
    }

    @Test("Adapters this build does not compile are dropped fail-closed")
    func unknownAdaptersFailClosed() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Self.bundledData()) as? [String: Any])
        var entries = try #require(object["entries"] as? [[String: Any]])
        var future = entries[0]
        future["presetID"] = "quantum-search"
        future["adapterKind"] = "quantumSearch"
        future["name"] = ["en": "Quantum", "zh-Hans": "量子"]
        future["blurb"] = ["en": "Future brand", "zh-Hans": "未来品牌"]
        entries.append(future)
        object["entries"] = entries

        let filtered = try SearchProviderCatalogDocument.validated(
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(filtered.entries.count == 10)
        #expect(!filtered.entries.contains { $0.presetID == "quantum-search" })

        object["entries"] = [future]
        Self.expectCatalogError(.noUsableEntries) {
            _ = try SearchProviderCatalogDocument.validated(
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    @Test("Staged content-hub package targets a catalog-aware app and matches the bundle")
    func stagedContentHubPackageIsConsistent() throws {
        let source = Self.repoRoot
            .appendingPathComponent("content-hub/sources/providers/floe.search.providers")
        let envelope = try #require(
            try JSONSerialization.jsonObject(
                with: try Data(contentsOf: source.appendingPathComponent("content.json"))
            ) as? [String: Any]
        )
        #expect(envelope["id"] as? String == "floe.search.providers")
        #expect(envelope["kind"] as? String == "providers")
        #expect(envelope["version"] as? String == "1.1.0")
        // A search catalog must never activate on an older app that does not
        // understand the payload/flow. 1.7.65 is the first build that compiles
        // the DeepSeek adapter kind, so 1.7.64 would fail closed and drop it.
        #expect(envelope["minimumAppVersion"] as? String == "1.7.65")
        #expect(envelope["containsScripts"] as? Bool == false)
        #expect((envelope["releaseNotes"] as? [String: String])?["en"]?.isEmpty == false)
        #expect((envelope["releaseNotes"] as? [String: String])?["zh-Hans"]?.isEmpty == false)

        let payload = try Data(contentsOf: source.appendingPathComponent("SearchProviderCatalog.json"))
        #expect(payload == (try Self.bundledData()), "bundled fallback and signed payload must not drift")
        _ = try SearchProviderCatalogIndex.validated(from: payload)
    }

    // MARK: - Draft creation

    @Test("Draft instances start disabled on compiled endpoints with independent accounts")
    func draftFactoryCreatesDisabledInstances() throws {
        let index = try Self.bundledIndex()

        let braveEntry = try #require(index.entry(presetID: "brave"))
        let brave = try #require(SearchProviderDraftFactory.draftInstance(for: braveEntry, localePrimary: "en"))
        #expect(brave.configuration.enabled == false)
        #expect(brave.configuration.kind == .brave)
        // The compiled canonical endpoint (and its tunnel grant) is kept.
        #expect(brave.configuration.endpoint == nil)
        #expect(brave.configuration.credentialAccount ==
                WebSearchProviderInstance.credentialAccount(for: brave.configuration.id))
        #expect(brave.configuration.credentialAccount.hasPrefix("web-search.instance."))
        #expect(brave.presetID == "brave")
        #expect(brave.appliedCatalogVersion == nil)

        let deepSeekEntry = try #require(index.entry(presetID: "deepseek"))
        #expect(deepSeekEntry.adapterKind == "deepseek")
        #expect(deepSeekEntry.defaultEndpoint == "https://api.deepseek.com/v1/tools/search")
        #expect(deepSeekEntry.credentialKeys == ["apiKey"])
        #expect(deepSeekEntry.optionFields.map(\.key) == [DeepSeekSearchOptions.Key.needContent])
        #expect(deepSeekEntry.optionFields.first?.defaultValue == "false")
        let deepSeek = try #require(SearchProviderDraftFactory.draftInstance(
            for: deepSeekEntry,
            localePrimary: "en"
        ))
        #expect(deepSeek.configuration.kind == .deepseek)
        #expect(deepSeek.configuration.enabled == false)
        #expect(deepSeek.configuration.endpoint == nil)
        #expect(deepSeek.configuration.options[DeepSeekSearchOptions.Key.needContent] == "false")
        #expect(deepSeek.configuration.credentialAccount.hasPrefix("web-search.instance."))
        #expect(deepSeek.presetID == "deepseek")

        let customEntry = try #require(index.entry(presetID: "custom-interface"))
        let custom = try #require(SearchProviderDraftFactory.draftInstance(for: customEntry, localePrimary: "en"))
        #expect(custom.configuration.endpoint == nil, "custom endpoints are user supplied")
        #expect(custom.configuration.options.isEmpty)

        let searxngEntry = try #require(index.entry(presetID: "searxng"))
        let searxng = try #require(SearchProviderDraftFactory.draftInstance(
            for: searxngEntry,
            localePrimary: "en"
        ))
        #expect(searxng.configuration.credentialAccount.hasPrefix("web-search.instance."))

        var volcengineAccountID: UUID?
        let volcengineEntry = try #require(index.entry(presetID: "volcengine"))
        let volcengine = try #require(SearchProviderDraftFactory.draftInstance(
            for: volcengineEntry,
            localePrimary: "zh-Hans",
            volcengineCredentialAccount: { id in
                volcengineAccountID = id
                return VolcengineSettingsDraftAccountFormula.account(for: id, interface: .agentPlan)
            }
        ))
        #expect(volcengine.configuration.options[VolcengineSearchOptions.Key.interface]
            == VolcengineSearchInterface.agentPlan.rawValue)
        #expect(volcengineAccountID == volcengine.configuration.id)
        #expect(volcengine.configuration.enabled == false)
    }

    @Test("Preset identity survives adapter kinds, including legacy Bocha AI")
    func presetIdentityMapsKinds() {
        #expect(SearchProviderPresets.presetID(for: .bochaWeb) == "bocha")
        #expect(SearchProviderPresets.presetID(for: .bochaAI) == "bocha")
        #expect(SearchProviderPresets.presetID(for: .tencentWSA) == "tencent-wsa")
        #expect(SearchProviderPresets.presetID(for: .volcengine) == "volcengine")
        #expect(SearchProviderPresets.presetID(for: .deepseek) == "deepseek")
        #expect(SearchProviderPresets.presetID(for: .custom) == "custom-interface")
        #expect(SearchProviderPresets.presetID(for: .searxng) == "searxng")
        #expect(WebSearchProviderInstance.credentialAccount(for: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!)
            == "web-search.instance.00112233-4455-6677-8899-aabbccddeeff")
    }

    // MARK: - Reviewed catalog updates

    @Test("Catalog updates merge only non-overridden real fields; names sync automatically")
    func planMergesOnlyUnoverriddenFields() throws {
        let instance = Self.bochaInstance()
        let renamed = try Self.catalogIndex(version: "1.1.0") { entry in
            entry["name"] = ["en": "Bocha Web Search", "zh-Hans": "博查网页搜索"]
            var fields = entry["optionFields"] as? [[String: Any]] ?? []
            fields[0]["defaultValue"] = "false"
            entry["optionFields"] = fields
        }
        let bochaEntry = try #require(renamed.entry(presetID: "bocha"))
        let plan = try #require(SearchProviderUpdatePlanner.plan(
            for: instance, in: renamed, localePrimary: "en"
        ))
        #expect(plan.toCatalogVersion == "1.1.0")
        #expect(plan.fromCatalogVersion == "1.0.0")
        // The catalog rename is cosmetic supplier metadata, never a reviewable
        // field change: only the real option default diff is offered.
        #expect(plan.changes.count == 1)
        #expect(plan.changes.first?.field == .option("summaryEnabled"))
        #expect(plan.touchesHost == false)
        #expect(plan.touchesCredentialKeys == false)
        #expect(plan.requiresConfirmation == false)

        let applied = SearchProviderUpdatePlanner.apply(
            plan, to: instance, entry: bochaEntry
        )
        #expect(applied.didRotateCredential == false)
        // apply() merges only the plan fields; the official title advances
        // through the automatic synchronizer.
        #expect(applied.instance.configuration.displayName == "Bocha Search")
        let synced = SearchProviderTitleSynchronizer.synchronizing(
            applied.instance, catalog: renamed, localePrimary: "en"
        )
        #expect(synced.configuration.displayName == "Bocha Web Search")
        #expect(synced.overrides.isEmpty)
        #expect(synced.appliedCatalogVersion == "1.1.0")
        #expect(synced.configuration.options["summaryEnabled"] == "false")
        #expect(synced.configuration.enabled == true)
        #expect(synced.configuration.priority == instance.configuration.priority)
        #expect(synced.configuration.credentialAccount == instance.configuration.credentialAccount)
        #expect(synced.catalogCredentialKeys == ["apiKey"])

        // A revision that only renames the supplier offers nothing at all,
        // in any locale.
        var matching = instance
        matching.configuration.options["summaryEnabled"] = "true"
        let renameOnly = try Self.catalogIndex(version: "1.2.0") { entry in
            entry["name"] = ["en": "Bocha Web Search", "zh-Hans": "博查网页搜索"]
        }
        #expect(SearchProviderUpdatePlanner.plan(
            for: matching, in: renameOnly, localePrimary: "en"
        ) == nil)
        #expect(SearchProviderUpdatePlanner.plan(
            for: matching, in: renameOnly, localePrimary: "zh-Hans"
        ) == nil)

        // A genuine user alias wins over every later title: no pending plan,
        // no automatic rename.
        var overridden = instance
        overridden.configuration.displayName = "My Bocha"
        overridden.overrides = ["displayName", "option:summaryEnabled"]
        #expect(SearchProviderUpdatePlanner.plan(
            for: overridden, in: renamed, localePrimary: "en"
        ) == nil)
        #expect(SearchProviderTitleSynchronizer.synchronizing(
            overridden, catalog: renamed, localePrimary: "en"
        ).configuration.displayName == "My Bocha")

        // An already reviewed version produces no plan.
        var reviewed = instance
        reviewed.appliedCatalogVersion = "1.1.0"
        #expect(SearchProviderUpdatePlanner.plan(
            for: reviewed, in: renamed, localePrimary: "en"
        ) == nil)
    }

    @Test("Host changes require confirmation and rotate the credential account")
    func hostChangeRequiresConfirmationAndRotates() throws {
        var instance = Self.bochaInstance()
        instance.configuration.endpoint = URL(string: "https://old.example.com/search")
        let hosted = try Self.catalogIndex(version: "1.2.0") { entry in
            entry["managesEndpoint"] = true
            entry["defaultEndpoint"] = "https://new.example.com/search"
        }
        let plan = try #require(SearchProviderUpdatePlanner.plan(
            for: instance, in: hosted, localePrimary: "en"
        ))
        #expect(plan.touchesHost)
        #expect(plan.requiresConfirmation)
        #expect(plan.rotatesCredentialAccount)

        let applied = SearchProviderUpdatePlanner.apply(
            plan,
            to: instance,
            entry: try #require(hosted.entry(presetID: "bocha")),
            rotatedCredentialAccount: "web-search.instance.fresh"
        )
        #expect(applied.didRotateCredential)
        #expect(applied.instance.configuration.credentialAccount == "web-search.instance.fresh")
        #expect(applied.instance.configuration.endpoint?.host == "new.example.com")
        // The enabled switch and identity are retained; only the key source
        // is rotated so an old secret can never reach the new host.
        #expect(applied.instance.configuration.enabled)
        #expect(applied.instance.configuration.id == instance.configuration.id)

        // A catalog that does not manage endpoints never proposes one.
        // (search-saved-name lane: this fixture previously asserted plan == nil
        // while the saved instance still lacked the current summaryEnabled
        // default, so a REAL option diff made the plan non-nil — a pre-existing
        // base failure in this suite, originally unrunnable on this host. The
        // assertion is unchanged; the fixture is aligned to a fully default-
        // matching saved state so the test checks exactly what it claims.)
        var unmanaged = instance
        unmanaged.configuration.endpoint = nil
        unmanaged.configuration.options["summaryEnabled"] = "true"
        let plain = try Self.catalogIndex(version: "1.3.0") { entry in
            entry["defaultEndpoint"] = "https://elsewhere.example.com/search"
        }
        #expect(SearchProviderUpdatePlanner.plan(
            for: unmanaged, in: plain, localePrimary: "en"
        ) == nil)
    }

    @Test("Credential schema changes require confirmation")
    func credentialSchemaChangeRequiresConfirmation() throws {
        let instance = Self.bochaInstance()
        let reauth = try Self.catalogIndex(version: "1.4.0") { entry in
            entry["credentialFields"] = [
                ["key": "apiKey", "required": true, "label": ["en": "API Key", "zh-Hans": "API 密钥"]],
                ["key": "projectId", "required": true, "label": ["en": "Project", "zh-Hans": "项目"]]
            ]
        }
        let plan = try #require(SearchProviderUpdatePlanner.plan(
            for: instance, in: reauth, localePrimary: "en"
        ))
        #expect(plan.touchesCredentialKeys)
        #expect(plan.requiresConfirmation)
        #expect(plan.rotatesCredentialAccount)
    }

    @Test("Removed catalog entries never delete or change user instances")
    func removedCatalogEntryNeverDeletesInstance() throws {
        let instance = Self.bochaInstance()
        var object = try #require(try JSONSerialization.jsonObject(with: Self.bundledData()) as? [String: Any])
        object["entries"] = try #require(object["entries"] as? [[String: Any]])
            .filter { ($0["presetID"] as? String) != "bocha" }
        let trimmed = try SearchProviderCatalogIndex.validated(
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(SearchProviderUpdatePlanner.plan(
            for: instance, in: trimmed, localePrimary: "en"
        ) == nil)
        #expect(instance.configuration.displayName == "Bocha Search")
    }

    // MARK: - Automatic official title refresh

    @Test("Title sync refreshes catalog-owned names only, is idempotent and locale-true")
    func titleSyncRefreshesOnlyCatalogOwnedNames() throws {
        var official = Self.bochaInstance()
        official.configuration.options["summaryEnabled"] = "true"
        let presetless = WebSearchProviderInstance(
            configuration: Self.configuration(
                .custom, name: "My Tunnel", enabled: true, account: "web-search.custom",
                endpoint: "https://tunnel.example.com/api"
            ),
            presetID: nil, appliedCatalogVersion: nil
        )
        var aliased = Self.bochaInstance()
        aliased.configuration.displayName = "My Bocha"
        aliased.overrides = ["displayName"]

        let renamed = try Self.catalogIndex(version: "1.1.0") { entry in
            entry["name"] = ["en": "Bocha Web Search", "zh-Hans": "博查网页搜索"]
        }
        let batch = SearchProviderTitleSynchronizer.synchronize(
            instances: [official, aliased, presetless], catalog: renamed, localePrimary: "en"
        )
        #expect(batch.renamedCount == 1)
        #expect(batch.instances[0].configuration.displayName == "Bocha Web Search")
        #expect(batch.instances[1].configuration.displayName == "My Bocha")
        #expect(batch.instances[2] == presetless)
        // Only the name changes on the refreshed instance: everything else is
        // byte-identical, including the reviewed catalog marker.
        #expect(batch.instances[0].overrides == official.overrides)
        #expect(batch.instances[0].appliedCatalogVersion == official.appliedCatalogVersion)
        #expect(batch.instances[0].configuration.credentialAccount == official.configuration.credentialAccount)
        #expect(batch.instances[0].configuration.enabled == official.configuration.enabled)
        #expect(batch.instances[0].configuration.priority == official.configuration.priority)
        #expect(batch.instances[0].configuration.options == official.configuration.options)
        // Second pass renames nothing.
        #expect(SearchProviderTitleSynchronizer.synchronize(
            instances: batch.instances, catalog: renamed, localePrimary: "en"
        ).renamedCount == 0)
        // Localized official titles are honoured deterministically.
        let zh = SearchProviderTitleSynchronizer.synchronize(
            instances: [official], catalog: renamed, localePrimary: "zh-Hans"
        )
        #expect(zh.instances.first?.configuration.displayName == "博查网页搜索")

        // Synced results round-trip through the v2 store: the refreshed name
        // persists and remains catalog-owned (no alias marking) after reload.
        let decoded = try JSONDecoder().decode(
            [WebSearchProviderInstance].self, from: try JSONEncoder().encode(batch.instances)
        )
        #expect(decoded[0].configuration.displayName == "Bocha Web Search")
        #expect(decoded[0].overrides.isEmpty)
        #expect(SearchProviderUpdatePlanner.plan(for: decoded[0], in: renamed, localePrimary: "en") == nil)
        #expect(SearchProviderTitleSynchronizer.synchronize(
            instances: decoded, catalog: renamed, localePrimary: "en"
        ).renamedCount == 0)

        // A removed preset keeps its last official title: sync never renames
        // against a missing entry.
        var object = try #require(try JSONSerialization.jsonObject(with: Self.bundledData()) as? [String: Any])
        object["version"] = "1.3.0"
        object["entries"] = try #require(object["entries"] as? [[String: Any]])
            .filter { ($0["presetID"] as? String) != "bocha" }
        let trimmed = try SearchProviderCatalogIndex.validated(
            from: JSONSerialization.data(withJSONObject: object)
        )
        let trimmedSync = SearchProviderTitleSynchronizer.synchronize(
            instances: [batch.instances[0]], catalog: trimmed, localePrimary: "en"
        )
        #expect(trimmedSync.renamedCount == 0)
        #expect(trimmedSync.instances.first?.configuration.displayName == "Bocha Web Search")
    }

    @Test("Drafts created from a catalog pick stay catalog-owned until a real rename")
    func catalogPickDraftFollowsLaterTitles() throws {
        let bundled = try Self.bundledIndex()
        let bochaEntry = try #require(bundled.entry(presetID: "bocha"))
        let draft = try #require(SearchProviderDraftFactory.draftInstance(
            for: bochaEntry, localePrimary: "zh-Hans"
        ))
        #expect(draft.configuration.displayName == "博查搜索")
        #expect(draft.overrides.isEmpty, "adopting the pick default is not a user alias")
        let renamed = try Self.catalogIndex(version: "1.1.0") { entry in
            entry["name"] = ["en": "Bocha Web Search", "zh-Hans": "博查网页搜索"]
        }
        #expect(SearchProviderUpdatePlanner.plan(
            for: draft, in: renamed, localePrimary: "zh-Hans"
        ) == nil, "a pure rename offers nothing even with a newer unreviewed version")
        let synced = SearchProviderTitleSynchronizer.synchronize(
            instances: [draft], catalog: renamed, localePrimary: "zh-Hans"
        )
        #expect(synced.renamedCount == 1)
        #expect(synced.instances.first?.configuration.displayName == "博查网页搜索")
    }

    // MARK: - v1 → v2 migration

    @Test("Migration keeps configured records and drops only provably unused presets")
    func migrationKeepsConfiguredRecords() throws {
        let unusedBrave = Self.configuration(
            .brave, name: "Brave Search", enabled: false, account: "web-search.brave", priority: 0
        )
        let configuredBrave = Self.configuration(
            .brave, name: "Work Brave", enabled: true,
            account: "web-search.brave.work", priority: 1
        )
        let bochaWeb = Self.configuration(
            .bochaWeb, name: "Bocha Search", enabled: false,
            account: "web-search.bochaWeb", priority: 2
        )
        let bochaAI = Self.configuration(
            .bochaAI, name: "Bocha AI Search", enabled: true,
            account: "web-search.bochaAI", priority: 3
        )
        let volcenginePreset = WebSearchProviderConfiguration(
            id: UUID(),
            kind: .volcengine,
            displayName: "Volcengine Web Search",
            endpoint: nil,
            credentialAccount: "web-search.volcengine.\(UUID().uuidString.lowercased()).agentPlan",
            enabled: false,
            priority: 4,
            options: [VolcengineSearchOptions.Key.interface: VolcengineSearchInterface.agentPlan.rawValue]
        )
        let custom = Self.configuration(
            .custom, name: "Custom", enabled: false, account: "web-search.custom",
            endpoint: "https://search.example.com/api", priority: 5
        )
        let records = [unusedBrave, configuredBrave, bochaWeb, bochaAI, volcenginePreset, custom]
        let credentials: Set<String> = ["web-search.brave.work", "web-search.bochaAI"]

        let result = WebSearchInstanceMigration.migrate(
            records: records,
            hasCredential: { credentials.contains($0) }
        )
        #expect(result.droppedPlaceholderCount == 2)
        #expect(result.instances.count == 3)
        #expect(!result.instances.contains { $0.configuration.id == unusedBrave.id })
        #expect(!result.instances.contains { $0.configuration.id == volcenginePreset.id })

        let keptBrave = try #require(result.instances.first { $0.configuration.id == configuredBrave.id })
        #expect(keptBrave.configuration.displayName == "Work Brave")
        #expect(keptBrave.configuration.enabled)
        #expect(keptBrave.overrides.contains("displayName"))
        #expect(keptBrave.configuration.credentialAccount ==
                WebSearchProviderInstance.credentialAccount(for: configuredBrave.id))
        let braveCopy = try #require(
            result.outcomes.first { $0.sourceIndex == 1 }?.credentialCopies.first
        )
        #expect(braveCopy.from == "web-search.brave.work")
        #expect(braveCopy.to == keptBrave.configuration.credentialAccount)

        let copies = result.outcomes.flatMap(\.credentialCopies)
        #expect(copies.contains { $0.from == "web-search.bochaAI" })
        #expect(result.instances.filter { $0.configuration.kind == .bochaWeb }.count == 1)
        let bocha = try #require(result.instances.first { $0.configuration.kind == .bochaWeb })
        #expect(bocha.configuration.enabled, "the enabled AI record merged into the Web instance")
        #expect(bocha.configuration.options["summaryEnabled"] == "true")
        #expect(bocha.configuration.credentialAccount.hasPrefix("web-search.instance."))

        let keptCustom = try #require(result.instances.first { $0.configuration.kind == .custom })
        #expect(keptCustom.overrides.contains("endpoint"))
        #expect(keptCustom.configuration.endpoint?.host == "search.example.com")
        #expect(keptCustom.configuration.credentialAccount.hasPrefix("web-search.instance."))

        // The backup document retains every original record and outcome.
        let backup = result.backupDocument(originalRecords: records)
        let object = try #require(try JSONSerialization.jsonObject(with: backup) as? [String: Any])
        #expect((object["originalRecords"] as? [Any])?.count == records.count)
        #expect((object["outcomes"] as? [Any])?.count == records.count)
    }

    @Test("A Bocha-only AI install becomes one working Bocha Web instance")
    func migrationConvertsBochaOnlyAIInstall() {
        let bochaAI = Self.configuration(
            .bochaAI, name: "Bocha AI Search", enabled: true, account: "web-search.bochaAI"
        )
        let result = WebSearchInstanceMigration.migrate(
            records: [bochaAI],
            hasCredential: { $0 == "web-search.bochaAI" }
        )
        #expect(result.instances.count == 1)
        #expect(result.instances.first?.configuration.kind == .bochaWeb)
        #expect(result.instances.first?.configuration.enabled == true)
        #expect(result.outcomes.first?.credentialCopies.first?.from == "web-search.bochaAI")
    }

    @Test("Migrated defaults follow later catalog titles while migrated aliases persist")
    func migratedDefaultsFollowCatalogTitlesAliasesPersist() throws {
        let defaultBocha = Self.configuration(
            .bochaWeb, name: "Bocha Search", enabled: true, account: "web-search.bocha.a"
        )
        let aliasBocha = Self.configuration(
            .bochaWeb, id: UUID(), name: "My Bocha", enabled: true, account: "web-search.bocha.b"
        )
        let aliasBrave = Self.configuration(
            .brave, id: UUID(), name: "Work Brave", enabled: true, account: "web-search.brave.c"
        )
        let result = WebSearchInstanceMigration.migrate(
            records: [defaultBocha, aliasBocha, aliasBrave],
            hasCredential: { _ in true }
        )
        #expect(result.instances.count == 3)
        let migratedDefault = try #require(
            result.instances.first { $0.configuration.displayName == "Bocha Search" }
        )
        #expect(!migratedDefault.overrides.contains("displayName"),
                "an untouched legacy default is not a user alias just because it was saved")
        #expect(result.instances.contains {
            $0.configuration.displayName == "My Bocha" && $0.overrides.contains("displayName")
        })
        #expect(result.instances.contains {
            $0.configuration.displayName == "Work Brave" && $0.overrides.contains("displayName")
        })

        let renamed = try Self.catalogIndex(version: "1.1.0") { entry in
            entry["name"] = ["en": "Bocha Web Search", "zh-Hans": "博查网页搜索"]
        }
        // None of the migrated instances receives a reviewable plan from a
        // rename-only revision (the legacy M4 badge case).
        for instance in result.instances {
            #expect(SearchProviderUpdatePlanner.plan(
                for: instance, in: renamed, localePrimary: "en"
            ) == nil)
        }
        // The automatic refresh renames exactly the unaliased record.
        let synced = SearchProviderTitleSynchronizer.synchronize(
            instances: result.instances, catalog: renamed, localePrimary: "en"
        )
        #expect(synced.renamedCount == 1)
        #expect(synced.instances.contains { $0.configuration.displayName == "Bocha Web Search" })
        #expect(synced.instances.contains { $0.configuration.displayName == "My Bocha" })
        #expect(synced.instances.contains { $0.configuration.displayName == "Work Brave" })
    }

    @Test("v2 instances round-trip and v1 payloads still decode")
    func instanceStoreRoundTripsAndV1Decodes() throws {
        let instance = Self.bochaInstance(appliedVersion: "1.0.0", overrides: ["displayName"])
        let data = try JSONEncoder().encode([instance])
        let decoded = try JSONDecoder().decode([WebSearchProviderInstance].self, from: data)
        #expect(decoded.count == 1)
        #expect(decoded[0].configuration == instance.configuration)
        #expect(decoded[0].overrides == ["displayName"])
        #expect(decoded[0].presetID == "bocha")
        #expect(decoded[0].catalogCredentialKeys == ["apiKey"])

        // A v1 array (no instance metadata) keeps decoding for migration and
        // for older builds reading the frozen legacy key.
        let legacy = [Self.configuration(.brave, name: "Brave Search", enabled: true, account: "web-search.brave")]
        let legacyData = try JSONEncoder().encode(legacy)
        let legacyDecoded = try JSONDecoder().decode([WebSearchProviderConfiguration].self, from: legacyData)
        #expect(legacyDecoded.count == 1)
        #expect(legacyDecoded[0].kind == .brave)

        // The v1 helper preserves its historical semantics (Bocha collapse),
        // and is only used before the migration.
        let web = Self.configuration(.bochaWeb, name: "Bocha Search", enabled: false, account: "web-search.bochaWeb")
        let ai = Self.configuration(.bochaAI, name: "Bocha AI", enabled: true, account: "web-search.bochaAI")
        let normalized = WebSearchSettingsCenterMirror.legacyNormalized([web, ai])
        #expect(normalized.count == 1)
        #expect(normalized[0].enabled)
        #expect(normalized[0].credentialAccount == "web-search.bochaWeb")
    }
}

// MARK: - Test-only mirrors of app/formula helpers

/// The app's Volcengine editor derives per-provider accounts through
/// `VolcengineSettingsDraft`; this mirror pins the exact string contract the
/// FloeExecution draft factory is injected with (the app tests exercise the
/// real helper).
enum VolcengineSettingsDraftAccountFormula {
    static func account(for providerID: UUID, interface: VolcengineSearchInterface) -> String {
        "web-search.volcengine.\(providerID.uuidString.lowercased()).\(interface.rawValue)"
    }
}

/// The app's legacy-only runtime projection is private to the app target; this
/// mirror documents the same pre-migration semantics in the module test.
enum WebSearchSettingsCenterMirror {
    static func legacyNormalized(
        _ source: [WebSearchProviderConfiguration]
    ) -> [WebSearchProviderConfiguration] {
        let legacyAI = source.first { $0.kind == .bochaAI }
        var result = source.filter { $0.kind != .bochaAI }
        if let index = result.firstIndex(where: { $0.kind == .bochaWeb }) {
            if let legacyAI {
                result[index].enabled = result[index].enabled || legacyAI.enabled
                result[index].options["summaryEnabled"] = result[index].options["summaryEnabled"] ?? "true"
            }
            result[index].displayName = "Bocha Search"
            result[index].credentialAccount = "web-search.bochaWeb"
        }
        return result
    }
}
