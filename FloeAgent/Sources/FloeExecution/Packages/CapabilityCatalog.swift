// FloeExecution — Capability catalog.
// A single manifest describes every installable capability: bundled and
// managed pure-Python packages, skills, fonts, local models, data-only .deb
// payloads and WASM command packages. `apt`/`pkg` read this catalog; the
// catalog itself grants nothing.

import Foundation
import FloeCore

public struct CapabilityCatalog: Sendable, Decodable {
    public enum Kind: String, Codable, Sendable {
        case pythonPackage
        case skill
        case font
        case model
        case debData
        case wasmCommand
        /// A shell/apt tool whose route is reviewed in ToolCapabilityCatalog.
        case shellTool
    }

    public enum Tier: String, Codable, Sendable {
        /// Ships with the app; installing means verifying presence.
        case bundled
        /// Reviewed download from the network (pure Python / skills / fonts / models).
        case managed
        /// Build-time pinned wheel in the wheelhouse.
        case wheelhouse
        /// Data-only Debian payload (never native executables).
        case deb
        /// Sandboxed WASM command from the signed catalog.
        case wasm
        /// Runs only on a paired remote host; never installed locally.
        case remote
        /// No Floe route; listed only so attempts fail with the reason.
        case unsupported
    }

    public struct Entry: Codable, Sendable, Identifiable, Hashable {
        public var id: String
        public var kind: Kind
        public var tier: Tier
        public var summary: String
        /// Exact `name==version` for pythonPackage entries.
        public var spec: String?
        public var skillID: String?
        public var modelID: String?
        public var fontFamily: String?
        public var url: String?
        public var sha256: String?
        public var sizeBytes: Int?
        public var capabilities: [String]
        public var aliases: [String]
        /// Present for `shellTool` entries; nil for every other kind.
        public var route: ToolCapabilityCatalog.Route?
        /// Present for `shellTool` entries; the tool's local execution route.
        public var localRoute: ToolCapabilityCatalog.Local?
        /// Reviewed installability. False for remote/unsupported/pending tools.
        public var installable: Bool?
        /// Present for `shellTool` entries with `route == .floePrecompiled`;
        /// the signed WASI catalog ids whose installed artifact makes the
        /// tool runnable. Nil for every other route/kind.
        public var signedCatalogIDs: [String]?

        public init(
            id: String,
            kind: Kind,
            tier: Tier,
            summary: String,
            spec: String? = nil,
            skillID: String? = nil,
            modelID: String? = nil,
            fontFamily: String? = nil,
            url: String? = nil,
            sha256: String? = nil,
            sizeBytes: Int? = nil,
            capabilities: [String] = [],
            aliases: [String] = [],
            route: ToolCapabilityCatalog.Route? = nil,
            localRoute: ToolCapabilityCatalog.Local? = nil,
            installable: Bool? = nil,
            signedCatalogIDs: [String]? = nil
        ) {
            self.id = id
            self.kind = kind
            self.tier = tier
            self.summary = summary
            self.spec = spec
            self.skillID = skillID
            self.modelID = modelID
            self.fontFamily = fontFamily
            self.url = url
            self.sha256 = sha256
            self.sizeBytes = sizeBytes
            self.capabilities = capabilities
            self.aliases = aliases
            self.route = route
            self.localRoute = localRoute
            self.installable = installable
            self.signedCatalogIDs = signedCatalogIDs
        }

        /// Distribution name for pythonPackage entries (`name==version` → name).
        public var distributionName: String? {
            guard let spec else { return nil }
            return spec.split(separator: "=").first.map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    public var schemaVersion: Int
    public var entries: [Entry]

    public init(schemaVersion: Int = 1, entries: [Entry]) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    public func entry(id: String) -> Entry? {
        let normalized = id.lowercased()
        return entries.first {
            $0.id.lowercased() == normalized || $0.aliases.contains { $0.lowercased() == normalized }
        }
    }

    public func search(_ query: String) -> [Entry] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return entries }
        return entries.filter { entry in
            if entry.id.lowercased().contains(normalized) { return true }
            if entry.summary.lowercased().contains(normalized) { return true }
            if entry.aliases.contains(where: { $0.lowercased().contains(normalized) }) { return true }
            if let spec = entry.spec, spec.lowercased().contains(normalized) { return true }
            return entry.capabilities.contains { $0.lowercased().contains(normalized) }
        }
    }

    public func entries(kind: Kind) -> [Entry] { entries.filter { $0.kind == kind } }

    /// Reviewed shell/apt tool routes rendered as catalog entries. Direct
    /// commands are already available; remote/unsupported/pending artifacts
    /// stay visible only with `installable=false` so nothing is advertised as
    /// installable unless it actually installs and runs.
    public static func shellToolEntries(from tools: ToolCapabilityCatalog) -> [Entry] {
        tools.tools.map { tool in
            Entry(
                id: tool.id,
                kind: .shellTool,
                tier: {
                    switch tool.route {
                    case .direct: return .bundled
                    case .floePrecompiled: return .wasm
                    case .remote: return .remote
                    case .unsupported: return .unsupported
                    }
                }(),
                summary: tool.localAlternative.map { "\(tool.displayName); local alternative: \($0)" } ?? tool.displayName,
                capabilities: [],
                aliases: tool.commands,
                route: tool.route,
                localRoute: tool.local,
                installable: tool.installable,
                signedCatalogIDs: tool.route == .floePrecompiled ? tool.signedCatalogIDs : nil
            )
        }
    }

    /// Loads the manifest shipped in the FloeExecution bundle. An absent or
    /// malformed manifest yields an empty catalog instead of a crash.
    public static func bundled() -> CapabilityCatalog {
        guard let url = Bundle.module.url(forResource: "CapabilityCatalog", withExtension: "json"),
              let data = try? Data(floeContentsOf: url) else {
            FloeLogger(category: .tools).error("capabilityCatalogMissing")
            return CapabilityCatalog(entries: [])
        }
        do {
            return try JSONDecoder().decode(CapabilityCatalog.self, from: data)
        } catch {
            FloeLogger(category: .tools).error("capabilityCatalogInvalid error=\(error.localizedDescription)")
            return CapabilityCatalog(entries: [])
        }
    }
}
