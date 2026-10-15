// FloeToolsTests — Temporary chat read-only tool policy.
//
// The temporary (ephemeral) chat ceiling is derived from the compiled
// descriptor metadata plus two audited tables: verified mixed-action read
// policies and verified per-tool exclusions (no family/prefix bans). These
// tests pin the descriptor-driven API, the action-level narrowing, the
// executor-side denial decision and the legacy name-only overload.

import Foundation
import Testing
@testable import FloeTools

@Suite("FloeTools.TemporaryChatToolPolicy")
struct TemporaryChatToolPolicyTests {

    // MARK: - Fixtures

    private func descriptor(
        _ name: String,
        description: String? = nil,
        schema: String = #"{"type":"object","additionalProperties":false}"#,
        risks: Set<RiskLabel> = [],
        sideEffecting: Bool = false,
        effect: ToolEffect? = nil
    ) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: name,
            toolDescription: description,
            parametersJSON: schema,
            riskLabels: risks,
            isSideEffecting: sideEffecting,
            effect: effect
        )
    }

    private func actionSchema(_ values: [String]) -> String {
        let quoted = values.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"type":"object","properties":{"action":{"type":"string","enum":[\#(quoted)]}},"required":["action"],"additionalProperties":false}"#
    }

    /// A representative slice of the real catalog: safe reads across public,
    /// personal, device, remote-inspection and discovery surfaces — plus
    /// every audited rejection class.
    private func ordinaryCatalog() -> [ToolCatalog.Descriptor] {
        [
            // Public retrieval + discovery.
            descriptor("web.fetch", risks: [.networkAccess], effect: .readOnly),
            descriptor("web.search", risks: [.networkAccess], effect: .readOnly),
            descriptor("web.searchAI", risks: [.networkAccess], effect: .readOnly),
            descriptor("tools.search", effect: .readOnly),
            descriptor("skill.list"), descriptor("skill.read"), descriptor("skill.search"),
            descriptor("checklist.readPlan", effect: .readOnly),

            // Personal data reads.
            descriptor("apple.calendar.list", risks: [.persistsPersonalData]),
            descriptor("apple.reminders.list", risks: [.persistsPersonalData]),
            descriptor("apple.maps.search", risks: [.networkAccess]),
            descriptor("apple.location.current"),
            descriptor("apple.clipboard.read", risks: [.persistsPersonalData]),
            descriptor("apple.watch.status"),
            descriptor("apple.home.list", risks: [.persistsPersonalData]),
            descriptor("apple.automation.list", risks: [.persistsPersonalData]),
            descriptor("mail.accounts"),
            descriptor(
                "mail.read",
                schema: actionSchema(["folders", "list", "message"]),
                risks: [.networkAccess, .accessesCredentials]
            ),
            descriptor("mail.search", risks: [.networkAccess, .accessesCredentials]),
            descriptor("notes.read", risks: [.readsFiles]),
            descriptor("notes.search", risks: [.readsFiles]),
            descriptor("conversation.list", risks: [.persistsPersonalData]),
            descriptor("conversation.read", risks: [.persistsPersonalData]),
            descriptor("conversation.search", risks: [.persistsPersonalData]),
            descriptor("memory.list", effect: .readOnly),
            descriptor("memory.recall", effect: .readOnly),
            descriptor("memory.search", effect: .readOnly),
            descriptor("memory.organizePreview", effect: .readOnly),

            // Device / media / informational reads.
            descriptor("font.list"),
            descriptor("crypto.hash", risks: [.readsFiles], effect: .readOnly),
            descriptor("media.capabilities", effect: .readOnly),
            descriptor("image.models", effect: .readOnly),
            descriptor("video.models", effect: .readOnly),
            descriptor("video.status", risks: [.networkAccess], effect: .readOnly),
            descriptor("document.office.capabilities"),
            descriptor("bluetooth.serial.scan", effect: .readOnly),
            descriptor("environment.linuxStatus", effect: .readOnly),

            // Authenticated remote inspections (credential authentication for
            // an authorized read is allowed; disclosure is not).
            descriptor("ssh.listHosts", effect: .readOnly),
            descriptor("ssh.inspectTarget", risks: [.networkAccess], effect: .readOnly),
            descriptor("ssh.taskStatus", risks: [.networkAccess], effect: .readOnly),
            descriptor("github.repositories", risks: [.networkAccess, .accessesCredentials], effect: .readOnly),
            descriptor("remote.connection.status", effect: .readOnly),
            descriptor("remoteHosting.inspect", risks: [.networkAccess]),
            descriptor("vnc.status", effect: .readOnly),
            descriptor("cloudWorkspace.catalog", risks: [.readsFiles], effect: .readOnly),
            descriptor("cloudWorkspace.list", risks: [.readsFiles]),
            descriptor("cloudWorkspace.read", risks: [.readsFiles]),
            descriptor("cloudWorkspace.git.status", risks: [.readsFiles]),
            descriptor("cloudWorkspace.git.diff", risks: [.readsFiles]),
            descriptor("cloudWorkspace.git.log", risks: [.readsFiles]),
            descriptor("network.ping", risks: [.networkAccess], effect: .readOnly),
            descriptor("network.dnsLookup", risks: [.networkAccess], effect: .readOnly),
            descriptor("network.tcpProbe", risks: [.networkAccess], effect: .readOnly),
            descriptor("network.traceroute", risks: [.networkAccess], effect: .readOnly),
            descriptor("network.scanLAN", risks: [.networkAccess], effect: .readOnly),
            descriptor("design.getState", risks: [.readsFiles]),
            descriptor("design.compare", risks: [.readsFiles]),
            descriptor("design.resolveTarget", risks: [.readsFiles]),
            descriptor("browser.observe", effect: .readOnly),
            descriptor("browser.tabs", effect: .readOnly),
            descriptor("browser.events", effect: .readOnly),
            descriptor("browser.wait", effect: .readOnly),

            // Task-workspace reads: safe per the policy; the center removes
            // them when the run has no task root (pre-existing rule).
            descriptor("workspace.readFile", risks: [.readsFiles]),
            descriptor("workspace.listDirectory", risks: [.readsFiles]),

            // Verified mixed tools (base descriptor can be mutating).
            descriptor(
                "media.models",
                schema: actionSchema(["list", "install", "remove", "status"]),
                risks: [.networkAccess, .writesFiles],
                sideEffecting: true,
                effect: .mutating
            ),
            descriptor(
                "remoteHosting.manage",
                schema: actionSchema(["plan", "publish", "list", "stop"]),
                risks: [.networkAccess, .modifiesRemoteSystem],
                sideEffecting: true
            ),
            descriptor(
                "crypto.cipher",
                schema: actionSchema(["generateKey", "deleteKey", "listKeys", "encrypt", "decrypt", "sign", "verify"]),
                risks: [.accessesCredentials],
                sideEffecting: true,
                effect: .mutating
            ),

            // Audited exclusions: read-only metadata but unsafe/unusable.
            descriptor("exec.javascript", effect: .readOnly),
            descriptor("exec.wasm", effect: .readOnly),
            descriptor("browser.navigate", risks: [.networkAccess], effect: .readOnly),
            descriptor("git.status", risks: [.readsFiles]),
            descriptor("git.diff", risks: [.readsFiles]),
            descriptor("git.log", risks: [.readsFiles]),
            descriptor("document.readSheet", risks: [.readsFiles], effect: .readOnly),
            descriptor("document.office.inspect", risks: [.readsFiles]),
            descriptor("document.pdf.inspect", risks: [.readsFiles], effect: .readOnly),
            descriptor("audio.inspect", risks: [.readsFiles], effect: .readOnly),
            descriptor("video.inspect", risks: [.readsFiles], effect: .readOnly),
            descriptor("image.ocr", risks: [.readsFiles], effect: .readOnly),
            descriptor("image.barcode.scan", risks: [.readsFiles], effect: .readOnly),
            descriptor("jobs.status", effect: .readOnly),
            descriptor("jobs.result", effect: .readOnly),
            descriptor("canvas.getState"),
            descriptor("canvas.assetSearch", effect: .readOnly),
            descriptor("canvas.designCapabilities"),
            descriptor("canvas.designGetState"),
            descriptor("canvas.designGetProjectSpec"),
            descriptor("canvas.generationStatus"),

            // Writes / execution / control / sends (metadata + labels).
            descriptor("workspace.writeFile", risks: [.writesFiles], sideEffecting: true),
            descriptor("workspace.deleteFile", risks: [.writesFiles, .deletesFiles], sideEffecting: true),
            descriptor("exec.shell", risks: [.executesLocalCode], sideEffecting: true, effect: .mutating),
            descriptor("exec.localPython", risks: [.executesLocalCode], sideEffecting: true, effect: .mutating),
            descriptor("shell.open", risks: [.executesLocalCode], sideEffecting: true, effect: .mutating),
            descriptor("python.packages", risks: [.writesFiles], sideEffecting: true),
            descriptor("linux.port", risks: [.networkAccess, .writesFiles], sideEffecting: true),
            descriptor("environment.startLinux", risks: [.writesFiles], sideEffecting: true, effect: .mutating),
            descriptor("delegate", risks: [.executesLocalCode], sideEffecting: true, effect: .mutating),
            descriptor("delegate.message", sideEffecting: true, effect: .internalState),
            descriptor("jobs.submit", risks: [.executesLocalCode], sideEffecting: true),
            descriptor("jobs.cancel", sideEffecting: true, effect: .internalState),
            descriptor("mcp_1234567890_remote_tool", risks: [.modifiesRemoteSystem], sideEffecting: true, effect: .mutating),
            descriptor("memory.remember", sideEffecting: true, effect: .internalState),
            descriptor("memory.forget", sideEffecting: true, effect: .internalState),
            descriptor("checklist.updatePlan", effect: .internalState),
            descriptor("skill.manage", risks: [.writesFiles], sideEffecting: true, effect: .mutating),
            descriptor("skill.create", risks: [.writesFiles], sideEffecting: true, effect: .mutating),
            descriptor("canvas.designPropose", sideEffecting: true, effect: .internalState),
            descriptor("design.propose", sideEffecting: true, effect: .internalState),
            descriptor("design.adopt", risks: [.writesFiles], sideEffecting: true),
            descriptor("browser.panel", risks: [.controlsGUI], sideEffecting: true, effect: .mutating),
            descriptor("browser.screenshot", risks: [.sendsDataToProvider], effect: .readOnly),
            descriptor("browser.type", risks: [.controlsGUI, .sendsDataToProvider], sideEffecting: true, effect: .mutating),
            descriptor("preview.start", risks: [.controlsGUI], effect: .readOnly),
            descriptor("preview.reload", risks: [.controlsGUI], effect: .readOnly),
            descriptor("preview.stop", effect: .readOnly),
            descriptor("image.inspect", risks: [.readsFiles, .sendsDataToProvider], effect: .readOnly),
            descriptor("image.generate", risks: [.sendsDataToProvider, .writesFiles], sideEffecting: true, effect: .mutating),
            descriptor("image.process", risks: [.readsFiles, .writesFiles], sideEffecting: true, effect: .mutating),
            descriptor("audio.transcribe", risks: [.writesFiles], sideEffecting: true),
            descriptor("video.generate", risks: [.sendsDataToProvider, .writesFiles], sideEffecting: true, effect: .mutating),
            descriptor("media.project", risks: [.writesFiles], sideEffecting: true, effect: .mutating),
            descriptor("document.pdf.fillForm", risks: [.readsFiles, .writesFiles], sideEffecting: true, effect: .mutating),
            descriptor("document.office.edit", risks: [.readsFiles, .writesFiles], sideEffecting: true, effect: .mutating),
            descriptor("document.createWord", risks: [.writesFiles], sideEffecting: true),
            descriptor("cad.document", risks: [.readsFiles, .writesFiles], sideEffecting: true, effect: .mutating),
            descriptor("apple.calendar.update", risks: [.persistsPersonalData], sideEffecting: true),
            descriptor("apple.maps.open", risks: [.controlsGUI], sideEffecting: true),
            descriptor("apple.home.control", risks: [.controlsGUI], sideEffecting: true),
            descriptor("apple.camera.capture", risks: [.controlsGUI, .writesFiles], sideEffecting: true, effect: .mutating),
            descriptor("apple.shortcuts.run", risks: [.controlsGUI], sideEffecting: true, effect: .mutating),
            descriptor("apple.mail.compose", risks: [.controlsGUI], sideEffecting: true),
            descriptor("mail.setRead", risks: [.persistsPersonalData], sideEffecting: true),
            descriptor("mail.move", risks: [.persistsPersonalData], sideEffecting: true),
            descriptor("mail.download", risks: [.writesFiles], sideEffecting: true),
            descriptor("mail.send", risks: [.sendsDataToProvider], sideEffecting: true),
            descriptor("network.http", risks: [.sendsDataToProvider], sideEffecting: true, effect: .mutating),
            descriptor("network.download", risks: [.writesFiles], sideEffecting: true, effect: .mutating),
            descriptor("ssh.execute", risks: [.executesRemoteCommand], sideEffecting: true, effect: .mutating),
            descriptor("ssh.updateHost", risks: [.persistsPersonalData], sideEffecting: true),
            descriptor("git.commit", risks: [.writesFiles], sideEffecting: true),
            descriptor("git.push", risks: [.modifiesRemoteSystem], sideEffecting: true),
            descriptor("github.clone", risks: [.writesFiles], sideEffecting: true),
            descriptor("github.createRepository", risks: [.modifiesRemoteSystem], sideEffecting: true),
            descriptor("vnc.connect", risks: [.controlsGUI], sideEffecting: true, effect: .mutating),
            descriptor("vnc.observe", risks: [.sendsDataToProvider], effect: .readOnly),
            descriptor("vnc.typeText", risks: [.controlsGUI, .sendsDataToProvider], sideEffecting: true, effect: .mutating),
            descriptor("remote.connection.open", sideEffecting: true, effect: .mutating),
            descriptor("cloudWorkspace.write", risks: [.writesFiles], sideEffecting: true),
            descriptor("credential.manage", risks: [.accessesCredentials], sideEffecting: true, effect: .mutating),
            descriptor("notes.edit", risks: [.writesFiles], sideEffecting: true),
            descriptor("font.install", risks: [.writesFiles], sideEffecting: true),
            descriptor("bluetooth.serial.open", risks: [.networkAccess], sideEffecting: true, effect: .mutating),
            descriptor("conversation.spawn", sideEffecting: true, effect: .internalState),
            descriptor("apple.automation.update", risks: [.changesAgentBehavior], sideEffecting: true),
        ]
    }

    private let expectedAllowed: Set<String> = [
        "web.fetch", "web.search", "web.searchAI",
        "tools.search", "skill.list", "skill.read", "skill.search", "checklist.readPlan",
        "apple.calendar.list", "apple.reminders.list", "apple.maps.search",
        "apple.location.current", "apple.clipboard.read", "apple.watch.status",
        "apple.home.list", "apple.automation.list",
        "mail.accounts", "mail.read", "mail.search",
        "notes.read", "notes.search",
        "conversation.list", "conversation.read", "conversation.search",
        "memory.list", "memory.recall", "memory.search", "memory.organizePreview",
        "font.list", "crypto.hash", "media.capabilities", "image.models",
        "video.models", "video.status", "document.office.capabilities",
        "bluetooth.serial.scan", "environment.linuxStatus",
        "ssh.listHosts", "ssh.inspectTarget", "ssh.taskStatus",
        "github.repositories", "remote.connection.status", "remoteHosting.inspect",
        "vnc.status",
        "cloudWorkspace.catalog", "cloudWorkspace.list", "cloudWorkspace.read",
        "cloudWorkspace.git.status", "cloudWorkspace.git.diff", "cloudWorkspace.git.log",
        "network.ping", "network.dnsLookup", "network.tcpProbe", "network.traceroute", "network.scanLAN",
        "design.getState", "design.compare", "design.resolveTarget",
        "browser.observe", "browser.tabs", "browser.events", "browser.wait",
        "workspace.readFile", "workspace.listDirectory",
        "media.models", "remoteHosting.manage", "crypto.cipher",
    ]

    // MARK: - Legacy compatibility

    @Test("Legacy name-only overload keeps the public web pair")
    func legacyCeilingContents() {
        #expect(TemporaryChatToolPolicy.nativeToolNames == ["web.search", "web.fetch"])
        let offered: Set<String> = [
            "web.search", "web.fetch", "workspace.readFile", "shell.exec",
            "delegate.task", "jobs.submit", "memory.remember", "mail.search",
        ]
        #expect(TemporaryChatToolPolicy.allowedToolNames(from: offered) == ["web.search", "web.fetch"])
        #expect(TemporaryChatToolPolicy.allowedToolNames(from: []).isEmpty)
        #expect(TemporaryChatToolPolicy.isTemporaryChatTool("web.fetch"))
        #expect(!TemporaryChatToolPolicy.isTemporaryChatTool("mail.read"))
    }

    // MARK: - Descriptor-driven ceiling

    @Test("Verified reads stay; audited exclusions and writes fall out")
    func descriptorCeilingContents() {
        let catalog = ordinaryCatalog()
        let allowed = TemporaryChatToolPolicy.allowedToolNames(from: catalog)
        #expect(allowed == expectedAllowed)
        // Every remaining catalog entry is a real audited rejection.
        for name in Set(catalog.map(\.name)).subtracting(expectedAllowed) {
            let excluded = TemporaryChatToolPolicy.verifiedExclusionReason(for: name) != nil
            let descriptor = catalog.first { $0.name == name }!
            let metadataDenied = descriptor.effect != .readOnly
                || descriptor.isSideEffecting
                || !descriptor.riskLabels.isDisjoint(with: TemporaryChatToolPolicy.forbiddenRiskLabels)
            #expect(excluded || metadataDenied, "\(name) must be either audited or metadata-denied")
        }
    }

    @Test("Uninstalled or unconfigured tools fall out of the derived ceiling")
    func derivedCeilingIsIntersectedByAvailability() {
        let offered = [descriptor("web.fetch", risks: [.networkAccess], effect: .readOnly)]
        #expect(TemporaryChatToolPolicy.allowedToolNames(from: offered) == ["web.fetch"])
        #expect(TemporaryChatToolPolicy.allowedToolNames(from: []).isEmpty)
    }

    // MARK: - Projection

    @Test("A pure read descriptor is returned unchanged (identity preserved)")
    func pureReadProjectionPreservesIdentity() {
        let fetch = descriptor("web.fetch", risks: [.networkAccess], effect: .readOnly)
        let projected = TemporaryChatToolPolicy.readOnlyDescriptor(fetch)
        #expect(projected?.name == "web.fetch")
        #expect(projected?.parametersJSON == fetch.parametersJSON)
        #expect(projected?.authorizationIdentity == fetch.authorizationIdentity)
        #expect(projected?.effect == .readOnly)
    }

    @Test("A verified mixed tool is narrowed without mutating the base descriptor")
    func mixedToolProjectsNarrowedSchema() throws {
        let base = try #require(ordinaryCatalog().first { $0.name == "media.models" })
        let originalSchema = base.parametersJSON
        let projected = try #require(TemporaryChatToolPolicy.readOnlyDescriptor(base))
        #expect(projected.name == "media.models")
        // The base descriptor identity is untouched...
        #expect(base.parametersJSON == originalSchema)
        // ...while the projection carries only the audited read actions.
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(projected.parametersJSON.utf8)) as? [String: Any]
        )
        let properties = try #require(object["properties"] as? [String: Any])
        let action = try #require(properties["action"] as? [String: Any])
        #expect(Set(action["enum"] as? [String] ?? []) == ["list", "status"])
    }

    @Test("A mail read projection pins the three fetch actions")
    func mailReadProjectionNarrows() throws {
        let base = try #require(ordinaryCatalog().first { $0.name == "mail.read" })
        let projected = try #require(TemporaryChatToolPolicy.readOnlyDescriptor(base))
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(projected.parametersJSON.utf8)) as? [String: Any]
        )
        let properties = try #require(object["properties"] as? [String: Any])
        let action = try #require(properties["action"] as? [String: Any])
        #expect(Set(action["enum"] as? [String] ?? []) == ["folders", "list", "message"])
    }

    @Test("A mixed tool whose schema cannot be narrowed is not offered")
    func unnarrowableSchemaFailsClosed() {
        #expect(TemporaryChatToolPolicy.narrowedSchema(
            #"{"type":"object","properties":{"query":{"type":"string"}}}"#,
            actions: ["list"]
        ) == nil)
        #expect(TemporaryChatToolPolicy.narrowedSchema("not json", actions: ["list"]) == nil)
    }

    @Test("Exclusions are per audited tool, not per family")
    func exclusionsArePerToolNotPerFamily() {
        // Audited reads inside otherwise-excluded families stay available.
        #expect(TemporaryChatToolPolicy.isReadOnlySafe(descriptor("browser.observe", effect: .readOnly)))
        #expect(TemporaryChatToolPolicy.isReadOnlySafe(descriptor("ssh.inspectTarget", risks: [.networkAccess], effect: .readOnly)))
        #expect(TemporaryChatToolPolicy.isReadOnlySafe(descriptor("cloudWorkspace.read", risks: [.readsFiles])))
        #expect(TemporaryChatToolPolicy.isReadOnlySafe(descriptor("network.ping", risks: [.networkAccess], effect: .readOnly)))
        #expect(TemporaryChatToolPolicy.isReadOnlySafe(descriptor("design.getState", risks: [.readsFiles])))
        // The audited exceptions are refused with their exact reason.
        #expect(TemporaryChatToolPolicy.verifiedExclusionReason(for: "exec.javascript") != nil)
        #expect(TemporaryChatToolPolicy.verifiedExclusionReason(for: "browser.navigate") != nil)
        #expect(TemporaryChatToolPolicy.verifiedExclusionReason(for: "git.status") != nil)
        #expect(TemporaryChatToolPolicy.verifiedExclusionReason(for: "jobs.result") != nil)
        #expect(TemporaryChatToolPolicy.verifiedExclusionReason(for: "canvas.getState") != nil)
        // Remote MCP/dynamic descriptors stay refused by METADATA (the
        // dynamic registration path always compiles a conservative mutating
        // descriptor), never by a blanket name ban; a trusted configured read
        // follows the ordinary catalog rules.
        #expect(!TemporaryChatToolPolicy.isReadOnlySafe(
            descriptor("mcp_abcdef0123_remote", sideEffecting: true, effect: .mutating)))
        #expect(TemporaryChatToolPolicy.verifiedExclusionReason(for: "mcp_abcdef0123_remote") == nil)
        // A hidden write label still fails closed even with a read effect.
        #expect(!TemporaryChatToolPolicy.isReadOnlySafe(
            descriptor("weird.read", risks: [.writesFiles], effect: .readOnly)))
    }

    // MARK: - Executor-side decision

    @Test("denialReason is nil only for a safe read action")
    func denialReasonAllowsSafeReads() {
        let fetch = descriptor("web.fetch", risks: [.networkAccess], effect: .readOnly)
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: fetch,
            arguments: Data(#"{"url":"https://example.com"}"#.utf8)
        ) == nil)
        let mail = ordinaryCatalog().first { $0.name == "mail.read" }!
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: mail,
            arguments: Data(#"{"action":"message","accountID":"x"}"#.utf8)
        ) == nil)
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: mail,
            arguments: Data(#"{"action":"folders"}"#.utf8)
        ) == nil)
    }

    @Test("denialReason fails closed for denied tools and non-read actions")
    func denialReasonDeniesEverythingElse() {
        let mail = ordinaryCatalog().first { $0.name == "mail.read" }!
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: mail, arguments: Data(#"{"action":"delete"}"#.utf8)) != nil)
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: mail, arguments: Data(#"{"accountID":"x"}"#.utf8)) != nil)
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: mail, arguments: Data("[]".utf8)) != nil)
        let write = descriptor("workspace.writeFile", risks: [.writesFiles], sideEffecting: true)
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: write, arguments: Data(#"{"path":"a.txt"}"#.utf8)) != nil)
        let js = descriptor("exec.javascript", effect: .readOnly)
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: js, arguments: Data(#"{}"#.utf8)) != nil)
    }

    @Test("Verified mixed tools accept their read actions and refuse the rest")
    func mixedToolActionDecisions() throws {
        for (name, allowedAction, deniedAction) in [
            ("media.models", "list", "install"),
            ("remoteHosting.manage", "plan", "publish"),
            ("crypto.cipher", "listKeys", "deleteKey"),
        ] {
            let base = try #require(ordinaryCatalog().first { $0.name == name })
            #expect(TemporaryChatToolPolicy.denialReason(
                descriptor: base,
                arguments: Data(#"{"action":"\#(allowedAction)"}"#.utf8)
            ) == nil, "\(name) must allow \(allowedAction)")
            #expect(TemporaryChatToolPolicy.denialReason(
                descriptor: base,
                arguments: Data(#"{"action":"\#(deniedAction)"}"#.utf8)
            ) != nil, "\(name) must refuse \(deniedAction)")
            // The projection only ever contains the read actions.
            let projected = try #require(TemporaryChatToolPolicy.readOnlyDescriptor(base))
            #expect(projected.parametersJSON.contains("\"\(allowedAction)\""))
            #expect(!projected.parametersJSON.contains("\"\(deniedAction)\""))
        }
    }

    @Test("Provider-backed search names are declared for availability narrowing")
    func providerBackedSearchNames() {
        #expect(TemporaryChatToolPolicy.providerBackedWebSearchToolNames == ["web.search", "web.searchAI"])
    }
}
