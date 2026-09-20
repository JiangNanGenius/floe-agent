// FloeExecution — Python package entry point.
// Python packages are their own family: this tool queries the reviewed
// catalog's pythonPackage entries and installs through the managed pip path
// (real pip inside the bundled CPython, py3-none-any wheels only, native
// payloads rejected). It never touches apt, Debian packages, Node or WASM.

import Foundation
import FloeCore
import FloeTools

public struct PythonPackageTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var action: String
        public var query: String?
        public var ids: [String]?
        public var purpose: String?

        public init(action: String, query: String? = nil, ids: [String]? = nil, purpose: String? = nil) {
            self.action = action
            self.query = query
            self.ids = ids
            self.purpose = purpose
        }
    }

    public static let name = "python.packages"
    public static let toolDescription =
        "Manage pure-Python packages for the bundled CPython runtime. `search`/`show`/`list` query the reviewed catalog (kind=pythonPackage only). `install` downloads an exact name==version spec through the managed pip path into the selected environment's shared site-packages — the same interpreter and package directory the python3 shell command and exec.localPython use; `purpose` is required. `remove` uninstalls a managed distribution (bundled packages cannot be removed). Only py3-none-any wheels with pinned SHA-256 install; packages needing native extensions fail honestly with the ABI reason. Debian packages are a different family managed by apt inside a Linux environment, never here."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "action":{"type":"string","enum":["search","list","show","install","remove"]},
      "query":{"type":"string","description":"Search terms for action=search"},
      "ids":{"type":"array","maxItems":16,"items":{"type":"string","description":"Catalog ids such as floe/py-openpyxl, or aliases"},"description":"Targets for show/install/remove"},
      "purpose":{"type":"string","description":"Concrete reason this package is needed for the user's request (required for network installs)"},
     "required":["action"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let installer: CapabilityInstaller

    public init(installer: CapabilityInstaller) {
        self.installer = installer
    }

    public func validate(_ args: Arguments) throws {
        let action = args.action.lowercased()
        guard ["search", "list", "show", "install", "remove"].contains(action) else {
            throw FloeError.validationFailed("action must be search, list, show, install or remove")
        }
        if action == "search" {
            guard let query = args.query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FloeError.validationFailed("query is required for action=search")
            }
        }
        if ["show", "install", "remove"].contains(action) {
            guard let ids = args.ids, !ids.isEmpty, ids.count <= 16 else {
                throw FloeError.validationFailed("ids must contain 1-16 catalog ids")
            }
        }
        if let purpose = args.purpose, purpose.utf8.count > 1_024 {
            throw FloeError.validationFailed("purpose exceeds 1024 bytes")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let action = args.action.lowercased()
        switch action {
        case "search":
            let found = await installer.search(args.query ?? "").filter { $0.kind == .pythonPackage }
            return await render(entries: found, action: action, environment: context.environment)
        case "list":
            let entries = installer.catalog.entries(kind: .pythonPackage)
            return await render(entries: entries, action: action, environment: context.environment)
        case "show":
            var found: [CapabilityCatalog.Entry] = []
            for id in args.ids ?? [] {
                guard let entry = installer.catalog.entry(id: id) else { continue }
                guard entry.kind == .pythonPackage else {
                    return Self.output("failed id=\(id) error=\(Self.wrongFamilyMessage(entry))", exitStatus: 1)
                }
                found.append(entry)
            }
            return await render(entries: found, action: action, environment: context.environment)
        case "install":
            var lines = ["status=ok action=install"]
            for id in args.ids ?? [] {
                try context.cancellation.throwIfCancelled()
                do {
                    let entry = try pythonEntry(id: id)
                    let receipt = try await installer.install(
                        id: entry.id,
                        purpose: args.purpose,
                        capabilities: [],
                        cancellation: context.cancellation,
                        environment: context.environment
                    )
                    lines.append("installed id=\(receipt.id) tier=\(receipt.tier.rawValue) detail=\(receipt.detail)")
                } catch {
                    lines.append("failed id=\(id) error=\(error.localizedDescription)")
                    return Self.output(lines.joined(separator: "\n"), exitStatus: 1)
                }
            }
            return Self.output(lines.joined(separator: "\n"), exitStatus: 0)
        case "remove":
            var lines = ["status=ok action=remove"]
            for id in args.ids ?? [] {
                do {
                    let entry = try pythonEntry(id: id)
                    let receipt = try await installer.remove(id: entry.id, environment: context.environment)
                    lines.append("removed id=\(receipt.id) detail=\(receipt.detail)")
                } catch {
                    lines.append("failed id=\(id) error=\(error.localizedDescription)")
                    return Self.output(lines.joined(separator: "\n"), exitStatus: 1)
                }
            }
            return Self.output(lines.joined(separator: "\n"), exitStatus: 0)
        default:
            throw FloeError.validationFailed("Unsupported action \(args.action)")
        }
    }

    private func pythonEntry(id: String) throws -> CapabilityCatalog.Entry {
        guard let entry = installer.catalog.entry(id: id) else {
            throw FloeError.notFound("python package \(id) is not in the catalog")
        }
        guard entry.kind == .pythonPackage else {
            throw FloeError.validationFailed(Self.wrongFamilyMessage(entry))
        }
        return entry
    }

    /// Points each family at its own entry instead of letting one tool stand
    /// in for every kind of capability.
    static func wrongFamilyMessage(_ entry: CapabilityCatalog.Entry) -> String {
        switch entry.kind {
        case .pythonPackage:
            return "\(entry.id) is a Python package; use the python.packages tool or pip inside a Linux environment"
        case .wasmCommand:
            return "\(entry.id) is a signed WASI command; use the wasm.packages tool"
        case .skill:
            return "\(entry.id) is a workflow skill; use skill.manage"
        case .font:
            return "\(entry.id) is a font; use the font tools"
        case .model:
            return "\(entry.id) is a local model; use the model manager"
        case .debData:
            return "\(entry.id) is a data-only .deb payload; extract it with dpkg-deb -x or install it inside a Linux environment"
        case .shellTool:
            return "\(entry.id) is a reviewed shell tool route, not an installable Python package"
        }
    }

    private func render(entries: [CapabilityCatalog.Entry], action: String, environment: ToolEnvironment?) async -> ToolExecutionOutput {
        let installed = Set(await installer.installedIDs(environment: environment))
        var lines = ["status=ok action=\(action) count=\(entries.count)"]
        for entry in entries {
            var parts = ["entry id=\(entry.id)", "tier=\(entry.tier.rawValue)"]
            if let spec = entry.spec { parts.append("spec=\(spec)") }
            parts.append("installed=\(installed.contains(entry.id))")
            parts.append("summary=\(entry.summary)")
            lines.append(parts.joined(separator: " "))
        }
        if entries.isEmpty { lines.append("No matching Python packages in the reviewed catalog.") }
        return Self.output(lines.joined(separator: "\n"), exitStatus: 0)
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        ToolExecutionOutput(digesting: text, exitStatus: exitStatus)
    }
}
