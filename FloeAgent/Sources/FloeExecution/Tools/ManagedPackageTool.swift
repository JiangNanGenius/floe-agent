// FloeExecution — retired mixed apt tool, kept as a compatibility shim.
// The `apt` name used to install Python packages, skills, fonts, models,
// data-only .deb payloads and signed WASM commands from one tool. That mixed
// design is retired: APT manages Linux distribution packages only, and each
// other family has its own entry. This shim stays callable for old
// conversations, answers read-only catalog queries, and turns every
// install/remove/download into migration guidance with no side effects.

import Foundation
import FloeCore
import FloeTools

public struct ManagedPackageTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var action: String
        public var query: String?
        public var ids: [String]?
        public var purpose: String?
        public var capabilities: [String]?

        public init(
            action: String,
            query: String? = nil,
            ids: [String]? = nil,
            purpose: String? = nil,
            capabilities: [String]? = nil
        ) {
            self.action = action
            self.query = query
            self.ids = ids
            self.purpose = purpose
            self.capabilities = capabilities
        }
    }

    public static let name = "apt"
    public static let toolDescription =
        "Retired compatibility entry; not advertised to new conversations. APT now manages Linux distribution packages only, inside a Linux environment. Read-only `search`/`show`/`list` still query the reviewed capability catalog so old references resolve. `install`/`remove`/`download` no longer perform any install here: Python packages use the python.packages tool, signed WASI commands use the wasm.packages tool, skills/fonts/models use their own managers, and Debian packages use apt inside a Linux environment."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "action":{"type":"string","enum":["search","list","show","install","remove","download"]},
      "query":{"type":"string","description":"Search terms for action=search"},
      "ids":{"type":"array","maxItems":16,"items":{"type":"string","description":"Catalog ids such as floe/py-openpyxl or aliases"},"description":"Targets for show/install/remove/download"},
      "purpose":{"type":"string","description":"Recorded reason from the retired calling convention (unused)"},
      "capabilities":{"type":"array","maxItems":16,"items":{"type":"string"},"description":"Recorded capabilities from the retired calling convention (unused)"},
     "required":["action"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let installer: CapabilityInstaller

    public init(installer: CapabilityInstaller) {
        self.installer = installer
    }

    public func validate(_ args: Arguments) throws {
        let normalized = args.action.lowercased().replacingOccurrences(of: "pkg ", with: "")
        guard ["search", "list", "show", "install", "remove", "download"].contains(normalized) else {
            throw FloeError.validationFailed("action must be search, list, show, install, remove or download")
        }
        if normalized == "search" {
            guard let query = args.query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FloeError.validationFailed("query is required for action=search")
            }
        }
        if ["show", "install", "remove", "download"].contains(normalized) {
            guard let ids = args.ids, !ids.isEmpty, ids.count <= 16 else {
                throw FloeError.validationFailed("ids must contain 1-16 catalog ids")
            }
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let action = args.action.lowercased().replacingOccurrences(of: "pkg ", with: "")
        switch action {
        case "search":
            let found = await installer.search(args.query ?? "")
            return await render(entries: found, action: action, environment: context.environment)
        case "list":
            let installed = Set(await installer.installedIDs(environment: context.environment))
            let entries = await installer.allEntries()
            var lines = ["status=ok action=list total=\(entries.count) installed=\(installed.count)"]
            for entry in entries {
                lines.append(Self.line(entry, installed: installed.contains(entry.id)))
            }
            return Self.output(lines.joined(separator: "\n"), exitStatus: 0)
        case "show":
            var found: [CapabilityCatalog.Entry] = []
            for id in args.ids ?? [] {
                if let entry = installer.catalog.entry(id: id) { found.append(entry) }
            }
            return await render(entries: found, action: action, environment: context.environment)
        case "install", "remove", "download":
            return migrationGuidance(action: action, ids: args.ids ?? [])
        default:
            throw FloeError.validationFailed("Unsupported action \(args.action)")
        }
    }

    /// The retired mixed install routes each named capability to the entry
    /// that actually owns its family. Nothing is installed, removed or
    /// downloaded by this shim.
    private func migrationGuidance(action: String, ids: [String]) -> ToolExecutionOutput {
        var lines = ["status=retired action=\(action)",
                     "The mixed apt tool is retired; no changes were made. Use the entry that owns each family:"]
        for id in ids {
            if let entry = installer.catalog.entry(id: id) {
                lines.append("id=\(id) kind=\(entry.kind.rawValue) use=\(PythonPackageTool.wrongFamilyMessage(entry))")
            } else {
                lines.append("id=\(id) use=not in the reviewed catalog; Debian packages install with apt inside a Linux environment")
            }
        }
        return Self.output(lines.joined(separator: "\n"), exitStatus: 1)
    }

    private func render(entries: [CapabilityCatalog.Entry], action: String, environment: ToolEnvironment?) async -> ToolExecutionOutput {
        let installed = Set(await installer.installedIDs(environment: environment))
        var lines = ["status=ok action=\(action) count=\(entries.count)"]
        for entry in entries {
            lines.append(Self.line(entry, installed: installed.contains(entry.id)))
        }
        if entries.isEmpty { lines.append("No matching capabilities. Use action=list for the full catalog.") }
        return Self.output(lines.joined(separator: "\n"), exitStatus: 0)
    }

    private static func line(_ entry: CapabilityCatalog.Entry, installed: Bool) -> String {
        var parts = ["entry id=\(entry.id)", "kind=\(entry.kind.rawValue)", "tier=\(entry.tier.rawValue)"]
        if let spec = entry.spec { parts.append("spec=\(spec)") }
        if let size = entry.sizeBytes { parts.append("bytes=\(size)") }
        parts.append("installed=\(installed)")
        if let route = entry.route {
            parts.append("route=\(route.rawValue)")
            if let local = entry.localRoute { parts.append("local=\(local.rawValue)") }
            parts.append("installable=\(entry.installable ?? false)")
        }
        parts.append("summary=\(entry.summary)")
        return parts.joined(separator: " ")
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        ToolExecutionOutput(digesting: text, exitStatus: exitStatus)
    }
}
