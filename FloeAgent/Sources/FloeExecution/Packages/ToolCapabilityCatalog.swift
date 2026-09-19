// FloeExecution — Reviewed shell/apt tool routes.
//
// The shell capability set is broader than the signed WASI catalog: some
// commands ship inside the app's native shell engine, some need a signed WASI
// artifact, some are only available on a paired remote host, and some have no
// Floe route at all. This catalog is the single reviewed classification used by
// the apt layer (`apt list/search/show`) and by the execution settings page so
// neither the user nor the model is told a tool is installable when it is not.
//
// Rules enforced by `validate(knownCommands:signedCatalogIDs:)` and by the
// read-only `python3 capability-hub/build.py --check-tools` gate:
// * a `direct` entry must name commands the shipped shell dictionary registers;
// * an `available` `floe-precompiled` entry must reference real signed catalog
//   ids; a pending artifact must say so and may not claim availability;
// * `remote` and `unsupported` entries are never installable;
// * every name in `required` is covered by at least one entry's commands.

import Foundation
import FloeCore

public struct ToolCapabilityCatalog: Sendable, Decodable {
    /// How the tool reaches the device today.
    public enum Route: String, Codable, Sendable, CaseIterable {
        /// Bundled shell command; runs on device without any install.
        case direct
        /// Signed WASI artifact from the capability catalog.
        case floePrecompiled = "floe-precompiled"
        /// Only on a paired remote host with the tool on PATH.
        case remote
        /// No Floe route; must not be advertised as installable.
        case unsupported
    }

    /// Local execution route. Distinct from `route` so a remote-first tool can
    /// still state honestly that nothing runs on device.
    public enum Local: String, Codable, Sendable {
        case direct
        case floePrecompiled = "floe-precompiled"
        case unsupported
    }

    public struct Entry: Sendable, Decodable, Identifiable, Hashable {
        public var id: String
        public var displayName: String
        public var commands: [String]
        public var route: Route
        public var local: Local
        /// Runnable on device right now (direct commands, installed signed
        /// artifacts). Pending artifacts and host tools are false.
        public var available: Bool
        /// `apt install` for this entry can succeed as a reviewed operation.
        public var installable: Bool
        public var signedCatalogIDs: [String]
        /// Route available when `route` itself needs an artifact that is
        /// missing (currently only the evaluated fallback).
        public var fallback: Route?
        /// Exact missing-artifact reference when `route == .floePrecompiled`
        /// and the artifact is not signed yet.
        public var artifactGap: String?
        public var localAlternative: String?
        public var evidence: String
        public var summary: String? { displayName }
    }

    public var schemaVersion: Int
    public var updated: String
    public var note: String
    /// Tool names that must be covered by at least one entry.
    public var required: [String]
    public var tools: [Entry]

    public init(schemaVersion: Int = 1, updated: String = "", note: String = "",
                required: [String] = [], tools: [Entry] = []) {
        self.schemaVersion = schemaVersion
        self.updated = updated
        self.note = note
        self.required = required
        self.tools = tools
    }

    /// Entries whose command list contains the given command.
    public func entries(forCommand command: String) -> [Entry] {
        tools.filter { $0.commands.contains(command) }
    }

    /// Entries that render as usable capabilities (runnable or installable).
    /// Pending, remote and unsupported routes are excluded by construction.
    public var usableEntries: [Entry] {
        tools.filter { $0.available || $0.installable }
    }

    /// Read-only consistency check shared by the app and the local tooling.
    public func validate(knownCommands: Set<String>, signedCatalogIDs: Set<String>) throws {
        guard schemaVersion == 1, !tools.isEmpty else {
            throw FloeError.validationFailed("Unsupported or empty tool capability catalog")
        }
        var seenIDs = Set<String>()
        var covered = Set<String>()
        for entry in tools {
            guard entry.id.range(of: "^tool/[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil,
                  !entry.displayName.isEmpty, !entry.evidence.isEmpty,
                  seenIDs.insert(entry.id).inserted else {
                throw FloeError.validationFailed("Invalid or duplicate tool catalog entry")
            }
            covered.formUnion(entry.commands)
            switch entry.route {
            case .direct:
                guard entry.local == .direct, entry.available, entry.installable,
                      !entry.commands.isEmpty,
                      entry.commands.allSatisfy({ knownCommands.contains($0) }) else {
                    throw FloeError.validationFailed("\(entry.id): direct tool must name shipped shell commands")
                }
            case .floePrecompiled:
                guard entry.installable == entry.available else {
                    throw FloeError.validationFailed("\(entry.id): availability and installability disagree")
                }
                if entry.available {
                    guard !entry.signedCatalogIDs.isEmpty,
                          entry.signedCatalogIDs.allSatisfy({ signedCatalogIDs.contains($0) }) else {
                        throw FloeError.validationFailed("\(entry.id): available precompiled tool needs a signed catalog id")
                    }
                    guard entry.artifactGap == nil else {
                        throw FloeError.validationFailed("\(entry.id): available tool cannot carry an artifact gap")
                    }
                } else {
                    guard let gap = entry.artifactGap, !gap.isEmpty, entry.signedCatalogIDs.isEmpty else {
                        throw FloeError.validationFailed("\(entry.id): pending artifact needs an explicit gap and no signed id")
                    }
                }
            case .remote, .unsupported:
                guard !entry.available, !entry.installable, entry.signedCatalogIDs.isEmpty else {
                    throw FloeError.validationFailed("\(entry.id): remote/unsupported tools are never installable")
                }
            }
        }
        let missing = required.filter { !covered.contains($0) }
        guard missing.isEmpty else {
            throw FloeError.validationFailed("Tool catalog misses required coverage: \(missing.joined(separator: ", "))")
        }
    }

    /// Loads the reviewed catalog shipped in the FloeExecution bundle. A
    /// malformed manifest yields an empty catalog; it is never guessed.
    public static func bundled() -> ToolCapabilityCatalog {
        guard let url = Bundle.module.url(forResource: "ToolCapabilityCatalog", withExtension: "json"),
              let data = try? Data(floeContentsOf: url) else {
            FloeLogger(category: .tools).error("toolCapabilityCatalogMissing")
            return ToolCapabilityCatalog()
        }
        do {
            return try JSONDecoder().decode(ToolCapabilityCatalog.self, from: data)
        } catch {
            FloeLogger(category: .tools).error("toolCapabilityCatalogInvalid error=\(error.localizedDescription)")
            return ToolCapabilityCatalog()
        }
    }
}
