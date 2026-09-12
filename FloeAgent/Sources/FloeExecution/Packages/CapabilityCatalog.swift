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
            aliases: [String] = []
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
