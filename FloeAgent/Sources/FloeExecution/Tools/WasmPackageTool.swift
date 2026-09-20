// FloeExecution — Signed WASM capability entry point.
// Sandboxed WASI commands are their own family: they install app-wide from
// the signed catalog through SignedWasmCapabilityStore and are never Debian
// packages, Python packages or environment-layer content. This is the only
// agent-facing install entry for them; apt does not carry them.

import Foundation
import FloeCore
import FloeTools

public struct WasmPackageTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var action: String
        public var ids: [String]?
        public var purpose: String?

        public init(action: String, ids: [String]? = nil, purpose: String? = nil) {
            self.action = action
            self.ids = ids
            self.purpose = purpose
        }
    }

    public static let name = "wasm.packages"
    public static let toolDescription =
        "Manage signed WASI commands (for example floe/lua). `list`/`show` read the verified signed catalog and report real install state. `install` downloads a SHA-256-pinned artifact and makes its floe-* shell command runnable; `purpose` is required. `remove` uninstalls the app-wide artifact. These are sandboxed WebAssembly commands, not Debian or Python packages: apt does not install them and they never enter an environment layer."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "action":{"type":"string","enum":["list","show","install","remove"]},
      "ids":{"type":"array","maxItems":16,"items":{"type":"string","description":"Catalog ids such as floe/lua, or command names such as floe-lua"},"description":"Targets for show/install/remove"},
      "purpose":{"type":"string","description":"Concrete reason this capability is needed for the user's request (required for installs)"},
     "required":["action"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let store: SignedWasmCapabilityStore

    public init(store: SignedWasmCapabilityStore) {
        self.store = store
    }

    public func validate(_ args: Arguments) throws {
        let action = args.action.lowercased()
        guard ["list", "show", "install", "remove"].contains(action) else {
            throw FloeError.validationFailed("action must be list, show, install or remove")
        }
        if ["show", "install", "remove"].contains(action) {
            guard let ids = args.ids, !ids.isEmpty, ids.count <= 16 else {
                throw FloeError.validationFailed("ids must contain 1-16 catalog ids")
            }
        }
        if action == "install" {
            guard let purpose = args.purpose?.trimmingCharacters(in: .whitespacesAndNewlines), !purpose.isEmpty else {
                throw FloeError.validationFailed("purpose is required for signed WASM installs")
            }
        }
        if let purpose = args.purpose, purpose.utf8.count > 1_024 {
            throw FloeError.validationFailed("purpose exceeds 1024 bytes")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        switch args.action.lowercased() {
        case "list":
            let installed = Set(await store.installedIDs())
            var lines = ["status=ok action=list count=\(store.catalog.packages.count)"]
            for entry in store.catalog.packages {
                lines.append(Self.line(entry, installed: installed.contains(entry.id)))
            }
            return Self.output(lines.joined(separator: "\n"), exitStatus: 0)
        case "show":
            let installed = Set(await store.installedIDs())
            var lines = ["status=ok action=show"]
            for id in args.ids ?? [] {
                guard let entry = resolve(id) else {
                    lines.append("failed id=\(id) error=not in the signed catalog")
                    return Self.output(lines.joined(separator: "\n"), exitStatus: 1)
                }
                lines.append(Self.line(entry, installed: installed.contains(entry.id)))
            }
            return Self.output(lines.joined(separator: "\n"), exitStatus: 0)
        case "install":
            var lines = ["status=ok action=install"]
            for id in args.ids ?? [] {
                try context.cancellation.throwIfCancelled()
                guard let entry = resolve(id) else {
                    lines.append("failed id=\(id) error=not in the signed catalog")
                    return Self.output(lines.joined(separator: "\n"), exitStatus: 1)
                }
                do {
                    try await store.install(id: entry.id, cancellation: context.cancellation)
                    lines.append("installed id=\(entry.id) version=\(entry.version) command=\(entry.command)")
                } catch {
                    lines.append("failed id=\(entry.id) error=\(error.localizedDescription)")
                    return Self.output(lines.joined(separator: "\n"), exitStatus: 1)
                }
            }
            return Self.output(lines.joined(separator: "\n"), exitStatus: 0)
        case "remove":
            var lines = ["status=ok action=remove"]
            for id in args.ids ?? [] {
                guard let entry = resolve(id) else {
                    lines.append("failed id=\(id) error=not in the signed catalog")
                    return Self.output(lines.joined(separator: "\n"), exitStatus: 1)
                }
                do {
                    try await store.remove(id: entry.id)
                    lines.append("removed id=\(entry.id) command=\(entry.command)")
                } catch {
                    lines.append("failed id=\(entry.id) error=\(error.localizedDescription)")
                    return Self.output(lines.joined(separator: "\n"), exitStatus: 1)
                }
            }
            return Self.output(lines.joined(separator: "\n"), exitStatus: 0)
        default:
            throw FloeError.validationFailed("Unsupported action \(args.action)")
        }
    }

    /// Resolves a catalog id or a bare/canonical command name; nothing is
    /// invented outside the verified signed catalog.
    private func resolve(_ operand: String) -> SignedWasmCatalog.Entry? {
        let normalized = operand.lowercased()
        return store.catalog.packages.first {
            $0.id.lowercased() == normalized || $0.command.lowercased() == normalized
        }
    }

    private static func line(_ entry: SignedWasmCatalog.Entry, installed: Bool) -> String {
        "entry id=\(entry.id) version=\(entry.version) command=\(entry.command) installed=\(installed)"
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        ToolExecutionOutput(digesting: text, exitStatus: exitStatus)
    }
}
