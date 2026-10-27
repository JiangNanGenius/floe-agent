// FloeToolsTests — Temporary chat read ceiling tool policy.
//
// The temporary (ephemeral) chat ceiling is an audited read-only set, not a
// general read-only catalog: the public web trio (`web.search`,
// `web.searchAI` when its provider is configured, and `web.fetch`) plus six
// basic on-device reads (`apple.calendar.list`, `apple.reminders.list`,
// `apple.maps.search`, `apple.home.list`, `apple.watch.status` and
// `apple.location.current`). These tests pin the descriptor-driven API, the
// metadata anti-spoof checks, the executor-side argument decision (including
// the location tool's empty-arguments contract) and the legacy name-only
// overload. Ordinary runs do not consult this policy.

import Foundation
import Testing
@testable import FloeTools

@Suite("FloeTools.TemporaryChatToolPolicy")
struct TemporaryChatToolPolicyTests {

    // MARK: - Fixtures

    private func descriptor(
        _ name: String,
        schema: String = #"{"type":"object","additionalProperties":false}"#,
        risks: Set<RiskLabel> = [.networkAccess],
        sideEffecting: Bool = false,
        effect: ToolEffect? = .readOnly,
        requiresHostScope: Bool = false,
        executionBoundary: ToolExecutionBoundary = .any
    ) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: name,
            parametersJSON: schema,
            riskLabels: risks,
            isSideEffecting: sideEffecting,
            effect: effect,
            requiresHostScope: requiresHostScope,
            executionBoundary: executionBoundary
        )
    }

    private func web(_ name: String) -> ToolCatalog.Descriptor {
        descriptor(name, risks: [.networkAccess], effect: .readOnly)
    }

    /// The REAL compiled metadata of the six basic-device reads.
    private func deviceRead(_ name: String) -> ToolCatalog.Descriptor {
        switch name {
        case "apple.maps.search":
            return descriptor(name, risks: [.networkAccess], effect: .readOnly)
        case "apple.watch.status", "apple.location.current":
            return descriptor(name, risks: [], effect: .readOnly)
        default:
            return descriptor(name, risks: [.persistsPersonalData], effect: .readOnly)
        }
    }

    /// A representative slice of the real catalog: the admitted families,
    /// plus private, discovery, remote-inspection and mixed read/write tools
    /// that are genuinely read-only in an ordinary run but outside temporary
    /// chat.
    private func ordinaryCatalog() -> [ToolCatalog.Descriptor] {
        [
            descriptor("web.fetch"),
            descriptor("web.search"),
            descriptor("web.searchAI"),

            // Basic on-device reads (admitted by the temporary ceiling).
            deviceRead("apple.calendar.list"),
            deviceRead("apple.reminders.list"),
            deviceRead("apple.maps.search"),
            deviceRead("apple.home.list"),
            deviceRead("apple.watch.status"),
            deviceRead("apple.location.current"),

            // Personal-data history reads (outside the ceiling).
            descriptor("mail.accounts", risks: []),
            descriptor(
                "mail.read",
                schema: #"{"type":"object","properties":{"action":{"type":"string","enum":["folders","list","message"]}},"required":["action"],"additionalProperties":false}"#,
                risks: [.networkAccess, .accessesCredentials]
            ),
            descriptor("notes.read", risks: [.readsFiles]),
            descriptor("notes.search", risks: [.readsFiles]),
            descriptor("conversation.list", risks: [.persistsPersonalData]),
            descriptor("conversation.read", risks: [.persistsPersonalData]),

            // Workspace, discovery and authenticated remote reads (outside).
            descriptor("workspace.readFile", risks: [.readsFiles]),
            descriptor("workspace.listDirectory", risks: [.readsFiles]),
            descriptor("tools.search", risks: []),
            descriptor("skill.list", risks: []),
            descriptor("skill.read", risks: []),
            descriptor("ssh.inspectTarget", risks: [.networkAccess]),
            descriptor("cloudWorkspace.read", risks: [.readsFiles]),
            descriptor("design.getState", risks: [.readsFiles]),
            descriptor("browser.observe", risks: []),

            // Mixed read/write tools expose only read actions to an ordinary
            // read-only policy; temporary chat does not admit them at all.
            descriptor(
                "media.models",
                schema: #"{"type":"object","properties":{"action":{"type":"string","enum":["list","status","install","remove"]}},"required":["action"],"additionalProperties":false}"#,
                risks: [.networkAccess, .writesFiles],
                sideEffecting: true,
                effect: .mutating
            ),
            descriptor(
                "remoteHosting.manage",
                schema: #"{"type":"object","properties":{"action":{"type":"string","enum":["plan","publish","list","stop"]}},"required":["action"],"additionalProperties":false}"#,
                risks: [.networkAccess, .modifiesRemoteSystem],
                sideEffecting: true,
                effect: .mutating
            ),
            descriptor(
                "crypto.cipher",
                schema: #"{"type":"object","properties":{"action":{"type":"string","enum":["listKeys","deleteKey"]}},"required":["action"],"additionalProperties":false}"#,
                risks: [.accessesCredentials],
                sideEffecting: true,
                effect: .mutating
            ),

            // Writes, execution and control.
            descriptor("workspace.writeFile", risks: [.writesFiles], sideEffecting: true, effect: .mutating),
            descriptor("exec.shell", risks: [.executesLocalCode], sideEffecting: true, effect: .mutating),
            descriptor("delegate", risks: [.executesLocalCode], sideEffecting: true, effect: .mutating),
            descriptor("jobs.submit", risks: [.executesLocalCode], sideEffecting: true, effect: .mutating),
            descriptor("memory.remember", risks: [], sideEffecting: true, effect: .internalState),
            descriptor("mail.send", risks: [.sendsDataToProvider], sideEffecting: true, effect: .mutating),
        ]
    }

    // MARK: - Legacy compatibility

    @Test("Legacy name-only overload keeps the public web pair; descriptors admit the AI search too")
    func legacyCeilingContents() {
        #expect(TemporaryChatToolPolicy.nativeToolNames == ["web.search", "web.fetch"])
        #expect(TemporaryChatToolPolicy.publicWebToolNames == ["web.search", "web.searchAI", "web.fetch"])
        let offered: Set<String> = [
            "web.search", "web.fetch", "web.searchAI", "workspace.readFile",
            "shell.exec", "delegate.task", "jobs.submit", "memory.remember",
            "mail.search", "apple.calendar.list",
        ]
        #expect(TemporaryChatToolPolicy.allowedToolNames(from: offered) == ["web.search", "web.fetch"])
        #expect(TemporaryChatToolPolicy.allowedToolNames(from: []).isEmpty)
        #expect(TemporaryChatToolPolicy.isTemporaryChatTool("web.fetch"))
        #expect(!TemporaryChatToolPolicy.isTemporaryChatTool("web.searchAI"))
        #expect(TemporaryChatToolPolicy.isPublicWebTool("web.searchAI"))
        #expect(!TemporaryChatToolPolicy.isTemporaryChatTool("mail.read"))
        #expect(!TemporaryChatToolPolicy.isTemporaryChatTool("apple.calendar.list"))
    }

    // MARK: - Descriptor-driven ceiling

    @Test("A rich catalog narrows to exactly the public web trio plus the six basic device reads")
    func descriptorCeilingIsAuditedReadSet() {
        let catalog = ordinaryCatalog()
        let allowed = TemporaryChatToolPolicy.allowedToolNames(from: catalog)
        #expect(allowed == [
            "apple.calendar.list", "apple.home.list", "apple.location.current",
            "apple.maps.search", "apple.reminders.list", "apple.watch.status",
            "web.fetch", "web.search", "web.searchAI",
        ])
        // The ordinary-run read-only catalog is not a temporary capability.
        for name in [
            "mail.accounts", "mail.read", "notes.read", "notes.search",
            "conversation.list", "conversation.read",
            "workspace.readFile", "workspace.listDirectory",
            "tools.search", "skill.list", "skill.read", "ssh.inspectTarget",
            "cloudWorkspace.read", "design.getState", "browser.observe",
            "media.models", "remoteHosting.manage", "crypto.cipher",
        ] {
            #expect(!allowed.contains(name), "\(name) is outside the temporary read ceiling")
        }
    }

    @Test("Each basic device read passes with its real compiled metadata and JSON object arguments")
    func basicDeviceReadsAreAdmitted() {
        for name in TemporaryChatToolPolicy.basicDeviceReadToolNames {
            #expect(TemporaryChatToolPolicy.isBasicDeviceReadTool(name))
            #expect(TemporaryChatToolPolicy.isSafeBasicDeviceDescriptor(deviceRead(name)), Comment(rawValue: name))
            #expect(TemporaryChatToolPolicy.readOnlyDescriptor(deviceRead(name)) != nil, Comment(rawValue: name))
            #expect(TemporaryChatToolPolicy.denialReason(
                descriptor: deviceRead(name), arguments: Data("{}".utf8)) == nil,
                    Comment(rawValue: name))
        }
        // The actual tools take their documented arguments; the policy does
        // not blanket-validate them (the compiled tool does).
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: deviceRead("apple.calendar.list"),
            arguments: Data(#"{"start":"2026-10-01T00:00:00Z","limit":10}"#.utf8)) == nil)
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: deviceRead("apple.maps.search"),
            arguments: Data(#"{"query":"coffee"}"#.utf8)) == nil)
    }

    @Test("apple.location.current takes NO arguments: any field fails closed")
    func locationTakesNoArguments() {
        let location = deviceRead("apple.location.current")
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: location, arguments: Data("{}".utf8)) == nil)
        for bad in [#"{"query":"Sydney"}"#, #"{"latitude":1}"#, #"{"anything":true}"#] {
            #expect(TemporaryChatToolPolicy.denialReason(
                descriptor: location, arguments: Data(bad.utf8)) != nil, Comment(rawValue: bad))
        }
    }

    @Test("A forged basic-device descriptor (write metadata under a read name) fails closed")
    func basicDeviceDescriptorForgeFails() {
        // Extra risk label under a genuine read name.
        let credential = descriptor(
            "apple.calendar.list", risks: [.persistsPersonalData, .accessesCredentials])
        #expect(!TemporaryChatToolPolicy.isSafeBasicDeviceDescriptor(credential))
        #expect(TemporaryChatToolPolicy.readOnlyDescriptor(credential) == nil)
        // Side-effecting / mutating reshape.
        let mutating = descriptor(
            "apple.location.current", risks: [], sideEffecting: true, effect: .mutating)
        #expect(!TemporaryChatToolPolicy.isSafeBasicDeviceDescriptor(mutating))
        // Host-scoped variant is refused.
        let hostScoped = descriptor(
            "apple.maps.search", risks: [.networkAccess], requiresHostScope: true)
        #expect(!TemporaryChatToolPolicy.isSafeBasicDeviceDescriptor(hostScoped))
        // Child-only boundary under an allowed name never enters.
        let childOnly = descriptor(
            "apple.watch.status", risks: [], executionBoundary: .childOnly)
        #expect(!TemporaryChatToolPolicy.isSafeBasicDeviceDescriptor(childOnly))
        // Write-family tools under the apple.* prefix stay outside even when
        // they claim a read-only effect.
        let writeSibling = descriptor(
            "apple.calendar.update", risks: [.persistsPersonalData], sideEffecting: true,
            effect: .mutating)
        #expect(TemporaryChatToolPolicy.readOnlyDescriptor(writeSibling) == nil)
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: writeSibling, arguments: Data("{}".utf8)) != nil)
        // Every forged device call is denied at execution with the policy's
        // own reason, never executed.
        for forged in [credential, mutating, hostScoped, childOnly] {
            #expect(TemporaryChatToolPolicy.denialReason(
                descriptor: forged, arguments: Data("{}".utf8)) != nil,
                Comment(rawValue: forged.name))
        }
    }

    @Test("Uninstalled or unconfigured tools fall out of the derived ceiling")
    func derivedCeilingIsIntersectedByAvailability() {
        let offered = [descriptor("web.fetch")]
        #expect(TemporaryChatToolPolicy.allowedToolNames(from: offered) == ["web.fetch"])
        #expect(TemporaryChatToolPolicy.allowedToolNames(from: []).isEmpty)
        // No provider or descriptor for web.search is invented.
        let privateOnly = [descriptor("notes.read", risks: [.readsFiles])]
        #expect(TemporaryChatToolPolicy.allowedToolNames(from: privateOnly).isEmpty)
        // A device read offered with genuine metadata survives; a settings
        // toggle that removed it from the offered set simply cannot reappear.
        let deviceOnly = [deviceRead("apple.watch.status")]
        #expect(TemporaryChatToolPolicy.allowedToolNames(from: deviceOnly) == ["apple.watch.status"])
    }

    // MARK: - Projection

    @Test("An admitted descriptor is returned unchanged (identity preserved)")
    func admittedProjectionPreservesIdentity() {
        let fetch = descriptor("web.fetch")
        let projected = TemporaryChatToolPolicy.readOnlyDescriptor(fetch)
        #expect(projected?.name == "web.fetch")
        #expect(projected?.parametersJSON == fetch.parametersJSON)
        #expect(projected?.authorizationIdentity == fetch.authorizationIdentity)
        #expect(projected?.effect == .readOnly)
        #expect(projected?.riskLabels == fetch.riskLabels)
        #expect(TemporaryChatToolPolicy.readOnlyDescriptor(descriptor("web.search")) != nil)
        #expect(TemporaryChatToolPolicy.readOnlyDescriptor(descriptor("web.searchAI")) != nil)
        let calendar = deviceRead("apple.calendar.list")
        let projectedCalendar = TemporaryChatToolPolicy.readOnlyDescriptor(calendar)
        #expect(projectedCalendar?.name == "apple.calendar.list")
        #expect(projectedCalendar?.authorizationIdentity == calendar.authorizationIdentity)
    }

    @Test("Private and mixed reads are not projected at all")
    func privateReadsAreNotProjected() {
        for name in ["notes.read", "mail.read", "conversation.list", "skill.list", "media.models"] {
            let base = ordinaryCatalog().first { $0.name == name }!
            #expect(TemporaryChatToolPolicy.readOnlyDescriptor(base) == nil, "\(name) must not be projected")
            #expect(!TemporaryChatToolPolicy.isReadOnlySafe(base))
        }
    }

    @Test("Spoofed public web metadata fails closed")
    func spoofedPublicWebMetadataFailsClosed() {
        // A dynamic or stale descriptor cannot reuse a public web name with
        // a broader effect, host scope or risk label.
        let mutating = descriptor("web.fetch", sideEffecting: true, effect: .mutating)
        #expect(!TemporaryChatToolPolicy.isReadOnlySafe(mutating))
        #expect(TemporaryChatToolPolicy.readOnlyDescriptor(mutating) == nil)

        let credentials = descriptor("web.fetch", risks: [.networkAccess, .accessesCredentials])
        #expect(!TemporaryChatToolPolicy.isReadOnlySafe(credentials))

        let personal = descriptor("web.search", risks: [.networkAccess, .persistsPersonalData])
        #expect(!TemporaryChatToolPolicy.isReadOnlySafe(personal))

        let hostScoped = descriptor("web.fetch", requiresHostScope: true)
        #expect(!TemporaryChatToolPolicy.isReadOnlySafe(hostScoped))

        let writes = descriptor("web.search", risks: [.writesFiles], sideEffecting: true, effect: .mutating)
        #expect(!TemporaryChatToolPolicy.isReadOnlySafe(writes))
    }

    // MARK: - Executor-side decision

    @Test("denialReason allows admitted reads with object arguments")
    func denialReasonAllowsAdmittedReads() {
        let fetch = descriptor("web.fetch")
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: fetch,
            arguments: Data(#"{"url":"https://example.com"}"#.utf8)
        ) == nil)
        let search = descriptor("web.search")
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: search,
            arguments: Data(#"{"query":"weather"}"#.utf8)
        ) == nil)
        let aiSearch = descriptor("web.searchAI")
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: aiSearch,
            arguments: Data(#"{"query":"weather summary"}"#.utf8)
        ) == nil)
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: deviceRead("apple.reminders.list"),
            arguments: Data(#"{"includeCompleted":false}"#.utf8)
        ) == nil)
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: deviceRead("apple.home.list"),
            arguments: Data("{}".utf8)
        ) == nil)
    }

    @Test("denialReason fails closed for private tools, bad arguments and LAN opt-in")
    func denialReasonDeniesEverythingElse() {
        let fetch = descriptor("web.fetch")
        // Non-object or malformed arguments never reach a web handler.
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: fetch, arguments: Data("[]".utf8)) != nil)
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: fetch, arguments: Data("not json".utf8)) != nil)
        // Temporary chat is public-web-only; the LAN/diagnostic opt-in is
        // refused at the policy boundary in addition to the tool's
        // `publicWebOnly` target validation.
        let lan = TemporaryChatToolPolicy.denialReason(
            descriptor: fetch,
            arguments: Data(#"{"url":"http://192.168.1.1","localNetwork":true}"#.utf8)
        )
        #expect(lan?.contains("public") == true)

        // Device reads need a JSON object too; the compiled tool owns the
        // per-argument validation.
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: deviceRead("apple.calendar.list"), arguments: Data("[]".utf8)) != nil)

        // Every private, discovery, mixed and mutating tool is denied by
        // name even when its descriptor is otherwise read-only.
        for name in [
            "notes.read", "mail.read", "conversation.list", "skill.list",
            "workspace.readFile", "ssh.inspectTarget", "media.models",
            "workspace.writeFile", "exec.shell", "delegate", "jobs.submit",
            "memory.remember", "mail.send",
        ] {
            let base = ordinaryCatalog().first { $0.name == name }!
            #expect(TemporaryChatToolPolicy.denialReason(
                descriptor: base, arguments: Data("{}".utf8)
            ) != nil, "\(name) must be denied")
        }

        // A spoofed public web descriptor with a write label is denied even
        // though its name is on the allowlist.
        let spoof = descriptor("web.fetch", risks: [.writesFiles], sideEffecting: true)
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: spoof, arguments: Data(#"{"url":"https://example.com"}"#.utf8)
        ) != nil)
    }

    @Test("The generic denial names the actual ceiling without granting anything")
    func genericDenialCopyIsActionable() {
        let reason = TemporaryChatToolPolicy.denialReason(
            descriptor: descriptor("credential.read", risks: [.accessesCredentials]),
            arguments: Data("{}".utf8)) ?? ""
        #expect(reason.contains("outside the temporary chat's read ceiling"))
        #expect(reason.contains("public web search/fetch"))
        #expect(reason.contains("current location"))
    }

    @Test("Professional source is denied while default and explicit public web remain unchanged")
    func professionalSourceDenied() {
        let search = descriptor("web.search")
        let reason = TemporaryChatToolPolicy.denialReason(
            descriptor: search,
            arguments: Data(#"{"query":"公司档案","source":"professional"}"#.utf8)
        )
        #expect(reason?.contains("public web search only") == true)
        for json in [#"{"query":"weather"}"#, #"{"query":"weather","source":"web"}"#] {
            #expect(TemporaryChatToolPolicy.denialReason(
                descriptor: search, arguments: Data(json.utf8)) == nil)
        }
    }

    @Test("Provider-backed public search names include web.search and web.searchAI")
    func providerBackedSearchNames() {
        #expect(TemporaryChatToolPolicy.providerBackedWebSearchToolNames == ["web.search", "web.searchAI"])
        let catalog = [descriptor("web.searchAI"), descriptor("web.search"), descriptor("web.fetch")]
        #expect(TemporaryChatToolPolicy.allowedToolNames(from: catalog) == ["web.search", "web.searchAI", "web.fetch"])
    }
}
