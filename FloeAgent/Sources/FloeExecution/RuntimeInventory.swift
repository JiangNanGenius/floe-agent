// FloeExecution — Execution-runtime inventory.
//
// The settings execution page and the capability catalog must show what the
// device can actually run, where it came from and whether an update or install
// is pending. This file owns the pure merge/classification rules; concrete
// probes (CPython, Node, JavaScriptCore, the signed WASI catalog and project
// layers) stay in their owning modules and are injected as values.
//
// Honesty rules encoded here:
// * A runtime is only listed as available with a version that a real probe or
//   a verified signed receipt supplied. No decorative placeholder versions.
// * `source` distinguishes a runtime bundled with the app, installed app-wide
//   by the user (signed WASI capabilities) and resolved from a project or
//   session environment layer.
// * `update` is only `.updatable` when two real versions were compared;
//   a missing signed artifact is `.unavailable`, never `.current`.

import Foundation
import FloeCore

/// One row of the execution-runtime inventory.
public struct RuntimeInventoryEntry: Sendable, Equatable, Identifiable {
    /// Where the runtime comes from.
    public enum Source: String, Sendable, Codable, CaseIterable {
        /// Ships inside the app bundle (CPython, Node, JavaScriptCore).
        case bundled
        /// Installed app-wide by the user from the signed WASI catalog.
        case user
        /// Resolved from a project or session environment layer.
        case project
        /// Runs on a paired remote host; nothing is installed locally.
        case remote
    }

    /// Availability derived from a real probe or a verified receipt.
    public enum Availability: Sendable, Equatable {
        /// Usable now; the associated version is the probed/verified version.
        case available(version: String)
        /// Not present. `installable` from the signed catalog may still offer it.
        case notInstalled
        /// Definitively unavailable; the reason is shown verbatim.
        case unavailable(reason: String)
    }

    /// Whether a newer or first install is possible through a signed artifact.
    public enum Update: Sendable, Equatable {
        case current
        /// Not installed; the signed catalog carries this version.
        case installable(version: String)
        /// Installed and the signed catalog carries a different newer version.
        case updatable(installed: String, available: String)
        /// No update route (bundled runtime, remote-only or artifact gap).
        case unavailable(reason: String)
    }

    public let id: String
    public let displayName: String
    public let source: Source
    public let availability: Availability
    public let update: Update
    /// Short provenance note (catalog id, environment id, host, gap).
    public let detail: String?

    public init(
        id: String,
        displayName: String,
        source: Source,
        availability: Availability,
        update: Update,
        detail: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.source = source
        self.availability = availability
        self.update = update
        self.detail = detail
    }
}

/// A real probe result for one bundled or remote runtime.
public struct RuntimeInventoryProbe: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let source: RuntimeInventoryEntry.Source
    public let capability: CapabilityState
    public let detail: String?

    public init(
        id: String,
        displayName: String,
        source: RuntimeInventoryEntry.Source,
        capability: CapabilityState,
        detail: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.source = source
        self.capability = capability
        self.detail = detail
    }
}

/// A signed WASI catalog package with its verified install state.
public struct RuntimeInventorySignedPackage: Sendable, Equatable {
    /// Catalog id, e.g. `floe/lua`.
    public let id: String
    /// Canonical command, e.g. `floe-lua`.
    public let command: String
    /// Version carried by the signed catalog entry.
    public let catalogVersion: String
    /// Version of the verified activation receipt, when installed.
    public let installedVersion: String?

    public init(id: String, command: String, catalogVersion: String, installedVersion: String?) {
        self.id = id
        self.command = command
        self.catalogVersion = catalogVersion
        self.installedVersion = installedVersion
    }
}

/// A runtime package installed in one environment layer.
public struct RuntimeInventoryLayerPackage: Sendable, Equatable {
    public let environmentID: String
    public let layerKind: String
    public let name: String
    public let version: String

    public init(environmentID: String, layerKind: String, name: String, version: String) {
        self.environmentID = environmentID
        self.layerKind = layerKind
        self.name = name
        self.version = version
    }
}

/// Pure merge rules for the inventory. Deterministic order: the fixed known
/// runtimes first, signed catalog packages next (catalog order), then
/// remaining ids alphabetically.
public enum RuntimeInventoryBuilder {
    /// Display order for known runtimes; unknown ids sort after.
    public static let knownOrder = ["javascript", "python", "node", "lua", "ruby", "php"]

    public static func build(
        probes: [RuntimeInventoryProbe],
        signed: [RuntimeInventorySignedPackage] = [],
        project: [RuntimeInventoryLayerPackage] = []
    ) -> [RuntimeInventoryEntry] {
        var entries: [RuntimeInventoryEntry] = []

        for probe in probes {
            let availability: RuntimeInventoryEntry.Availability
            let update: RuntimeInventoryEntry.Update
            switch probe.capability {
            case .available(let version):
                availability = .available(version: version.replacingOccurrences(of: " (remote)", with: ""))
                update = probe.source == .remote
                    ? .unavailable(reason: "Remote host runtime; update on the host")
                    : .current
            case .unavailable(let reason):
                availability = .unavailable(reason: reason)
                update = .unavailable(reason: reason)
            case .unknown:
                availability = .unavailable(reason: "Probe did not complete")
                update = .unavailable(reason: "Probe did not complete")
            }
            entries.append(RuntimeInventoryEntry(
                id: probe.id,
                displayName: probe.displayName,
                source: probe.source,
                availability: availability,
                update: update,
                detail: probe.detail
            ))
        }

        for package in signed {
            let availability: RuntimeInventoryEntry.Availability
            let update: RuntimeInventoryEntry.Update
            if let installed = package.installedVersion {
                availability = .available(version: installed)
                if installed == package.catalogVersion {
                    update = .current
                } else {
                    update = .updatable(installed: installed, available: package.catalogVersion)
                }
            } else {
                availability = .notInstalled
                update = .installable(version: package.catalogVersion)
            }
            entries.append(RuntimeInventoryEntry(
                id: package.id,
                displayName: package.command,
                source: .user,
                availability: availability,
                update: update,
                detail: "signed catalog \(package.id) \(package.catalogVersion)"
            ))
        }

        for package in project {
            entries.append(RuntimeInventoryEntry(
                id: "\(package.environmentID)/\(package.name)",
                displayName: package.name,
                source: .project,
                availability: .available(version: package.version),
                update: .unavailable(reason: "Project layer \(package.layerKind); managed with the environment"),
                detail: "environment \(package.environmentID)"
            ))
        }

        return entries.sorted { lhs, rhs in
            let lhsRank = knownOrder.firstIndex(of: lhs.id) ?? knownOrder.count
            let rhsRank = knownOrder.firstIndex(of: rhs.id) ?? knownOrder.count
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhsRank == knownOrder.count, lhs.id != rhs.id { return lhs.id < rhs.id }
            return false
        }
    }
}
