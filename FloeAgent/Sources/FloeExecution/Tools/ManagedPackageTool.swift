// FloeExecution — apt capability tool.
// One tool for the whole capability lifecycle: search, list, show, install,
// remove, download. Installation routes through CapabilityInstaller, which
// reuses the reviewed managed-pip path and the app's skill/font/model stores.
// `pkg` is accepted as an alias action prefix so familiar spellings work.

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
        "Manage Floe capabilities with apt-like actions. `search`/`show`/`list` are read-only catalog queries. `install` acquires a capability through its reviewed primitive (managed pure-Python packages, workflow guides, fonts, local models, data-only .deb payloads, sandboxed WASM commands); `purpose` is required for anything downloaded. `remove` uninstalls a managed package (bundled packages cannot be removed). `download` fetches a catalog artifact to the workspace without installing it. Native binaries never run on iOS: data-only .deb extraction uses `dpkg -x`, and executable payloads must use an approved remote host."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "action":{"type":"string","enum":["search","list","show","install","remove","download"]},
      "query":{"type":"string","description":"Search terms for action=search"},
      "ids":{"type":"array","maxItems":16,"items":{"type":"string","description":"Catalog ids such as floe/py-openpyxl or aliases"},"description":"Targets for show/install/remove/download"},
      "purpose":{"type":"string","description":"Concrete reason this capability is needed for the user's request (required for network installs)"},
      "capabilities":{"type":"array","maxItems":16,"items":{"type":"string"},"description":"Narrow required capabilities, e.g. spreadsheet, pdf.read"}},
     "required":["action"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .writesFiles, .changesAgentBehavior]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

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
        if let purpose = args.purpose, purpose.utf8.count > 1_024 {
            throw FloeError.validationFailed("purpose exceeds 1024 bytes")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let action = args.action.lowercased().replacingOccurrences(of: "pkg ", with: "")
        switch action {
        case "search":
            let found = await installer.search(args.query ?? "")
            return await render(entries: found, action: action)
        case "list":
            let installed = Set(await installer.installedIDs())
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
            return await render(entries: found, action: action)
        case "install":
            return try await install(args: args, context: context)
        case "remove":
            var lines = ["status=ok action=remove"]
            for id in args.ids ?? [] {
                do {
                    let receipt = try await installer.remove(id: id)
                    lines.append("removed id=\(receipt.id) detail=\(receipt.detail)")
                } catch {
                    lines.append("failed id=\(id) error=\(error.localizedDescription)")
                    return Self.output(lines.joined(separator: "\n"), exitStatus: 1)
                }
            }
            return Self.output(lines.joined(separator: "\n"), exitStatus: 0)
        case "download":
            guard let workspace = context.workspaceRootURL else {
                throw FloeError.validationFailed("A workspace root is required for download")
            }
            let directory = workspace.appendingPathComponent("packages", isDirectory: true)
            var lines = ["status=ok action=download"]
            for id in args.ids ?? [] {
                let url = try await installer.download(id: id, to: directory)
                lines.append("downloaded id=\(id) path=packages/\(url.lastPathComponent)")
            }
            return Self.output(lines.joined(separator: "\n"), exitStatus: 0)
        default:
            throw FloeError.validationFailed("Unsupported action \(args.action)")
        }
    }

    private func install(args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        var lines = ["status=ok action=install"]
        for id in args.ids ?? [] {
            try context.cancellation.throwIfCancelled()
            do {
                let receipt = try await installer.install(
                    id: id,
                    purpose: args.purpose,
                    capabilities: args.capabilities ?? [],
                    cancellation: context.cancellation
                )
                lines.append("installed id=\(receipt.id) kind=\(receipt.kind.rawValue) tier=\(receipt.tier.rawValue) detail=\(receipt.detail)")
            } catch {
                lines.append("failed id=\(id) error=\(error.localizedDescription)")
                return Self.output(lines.joined(separator: "\n"), exitStatus: 1)
            }
        }
        return Self.output(lines.joined(separator: "\n"), exitStatus: 0)
    }

    private func render(entries: [CapabilityCatalog.Entry], action: String) async -> ToolExecutionOutput {
        let installed = Set(await installer.installedIDs())
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
        parts.append("summary=\(entry.summary)")
        return parts.joined(separator: " ")
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        ToolExecutionOutput(digesting: text, exitStatus: exitStatus)
    }
}
