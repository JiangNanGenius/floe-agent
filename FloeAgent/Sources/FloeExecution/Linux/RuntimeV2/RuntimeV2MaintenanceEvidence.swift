// FloeExecution — owner evidence collection for the legacy recovery domain.
//
// The authority never treats "I could not find an owner" as "nobody owns it".
// This collector composes the three real owner sources plus a direct filesystem
// trace scan:
//   * the live guest registry (starts, sessions, quarantine, teardown,
//     lifecycle transactions);
//   * the Runtime v2 integrator/store (held leases, lease registry rows,
//     queued admissions, preparation pass);
//   * the complete App DB environment-reference projection;
//   * lease sidecars and unexplained runtime/vm directories under the domain.
//
// Any missing provider, thrown query or unreadable directory makes the
// snapshot incomplete, which denies exclusive maintenance. A different store
// root (production arm64-v1 / resident ARM64) is not evidence about the legacy
// domain and is ignored by `quiescenceBlockers(domain:)`.

import Foundation
import FloeCore

public typealias RuntimeV2MaintenanceRegistryEvidence = RuntimeV2MaintenanceOwnerEvidence.Registry
public typealias RuntimeV2MaintenanceIntegratorEvidence = RuntimeV2MaintenanceOwnerEvidence.Integrator
public typealias RuntimeV2MaintenanceReferenceEvidence = RuntimeV2MaintenanceOwnerEvidence.References
public typealias RuntimeV2MaintenanceFilesystemEvidence = RuntimeV2MaintenanceOwnerEvidence.Filesystem

public actor RuntimeV2MaintenanceEvidenceCollector {
    public struct Sources: Sendable {
        /// Live registry snapshot. nil means the source is not installed.
        public var registry: (@Sendable () async -> RuntimeV2MaintenanceRegistryEvidence?)?
        /// Runtime v2 integrator snapshot. nil means the source is not installed.
        public var integrator: (@Sendable () async -> RuntimeV2MaintenanceIntegratorEvidence?)?
        /// Complete App DB projection adapter. Throwing/unavailable means the
        /// projection is not complete, which denies maintenance.
        public var references: (@Sendable () async throws -> RuntimeV2MaintenanceReferenceEvidence?)?
        /// True while a launch-time recovery pass is mutating the domain.
        public var startupRecoveryActive: (@Sendable () async -> Bool)?
        /// Additional fixed internal blocker codes from the trusted owner.
        public var additionalBlockers: (@Sendable () async -> [String])?

        public init(
            registry: (@Sendable () async -> RuntimeV2MaintenanceRegistryEvidence?)? = nil,
            integrator: (@Sendable () async -> RuntimeV2MaintenanceIntegratorEvidence?)? = nil,
            references: (@Sendable () async throws -> RuntimeV2MaintenanceReferenceEvidence?)? = nil,
            startupRecoveryActive: (@Sendable () async -> Bool)? = nil,
            additionalBlockers: (@Sendable () async -> [String])? = nil
        ) {
            self.registry = registry
            self.integrator = integrator
            self.references = references
            self.startupRecoveryActive = startupRecoveryActive
            self.additionalBlockers = additionalBlockers
        }
    }

    private let domain: RuntimeV2MaintenanceDomain
    private let sources: Sources
    private let fileManager: FileManager

    public init(
        domain: RuntimeV2MaintenanceDomain,
        sources: Sources,
        fileManager: FileManager = .default
    ) {
        self.domain = domain
        self.sources = sources
        self.fileManager = fileManager
    }

    public func collect() async -> RuntimeV2MaintenanceOwnerEvidence {
        var blockers: [String] = []

        let registry: RuntimeV2MaintenanceRegistryEvidence?
        if let provider = sources.registry {
            registry = await provider()
            if registry == nil { blockers.append("registry_provider_unavailable") }
        } else {
            registry = nil
            blockers.append("registry_provider_unavailable")
        }

        let integrator: RuntimeV2MaintenanceIntegratorEvidence?
        if let provider = sources.integrator {
            integrator = await provider()
            if integrator == nil { blockers.append("integrator_provider_unavailable") }
        } else {
            integrator = nil
            blockers.append("integrator_provider_unavailable")
        }

        let references: RuntimeV2MaintenanceReferenceEvidence?
        if let provider = sources.references {
            do {
                references = try await provider()
                if references == nil { blockers.append("reference_projection_unavailable") }
            } catch {
                references = nil
                blockers.append("reference_projection_threw")
            }
        } else {
            references = nil
            blockers.append("reference_projection_unavailable")
        }

        let startupRecoveryActive: Bool
        if let provider = sources.startupRecoveryActive {
            startupRecoveryActive = await provider()
        } else {
            startupRecoveryActive = false
        }
        if let provider = sources.additionalBlockers {
            blockers.append(contentsOf: await provider())
        }

        var filesystem = Self.scanFilesystem(
            domain: domain, fileManager: fileManager
        )

        // The legacy registry's `leases` rows are part of the owner set. If the
        // database exists and no integrator covering THIS root supplied them,
        // sidecar files alone are not complete. NEVER open/migrate the legacy
        // registry here: a fresh runtime v2 store with its own evidence source
        // is the only owner allowed to answer it.
        let integratorCoversDomain: Bool
        if let rootPath = integrator?.storeRootPath {
            let canonical = URL(fileURLWithPath: rootPath)
                .standardizedFileURL.resolvingSymlinksInPath().path
            integratorCoversDomain = canonical == domain.root.path
        } else {
            integratorCoversDomain = false
        }
        if !integratorCoversDomain,
           fileManager.fileExists(atPath: domain.root
            .appendingPathComponent("registry", isDirectory: true)
            .appendingPathComponent("runtime.sqlite").path) {
            filesystem.leaseRegistryUnmeasured = true
            blockers.append("filesystem_lease_registry_unmeasured")
        }

        // Completeness of a source is required only when that source is about
        // THIS domain. A resident-machine registry and a different store root
        // (production arm64-v1) are not evidence about the legacy recovery
        // bytes; their unrelated failures must not block this domain.
        let registryReady: Bool
        if let registry {
            registryReady = registry.usesResidentMachine || registry.isComplete
        } else {
            registryReady = false
        }
        let integratorReady: Bool
        if let integrator {
            if let rootPath = integrator.storeRootPath {
                let canonical = URL(fileURLWithPath: rootPath)
                    .standardizedFileURL.resolvingSymlinksInPath().path
                integratorReady = canonical == domain.root.path ? integrator.isComplete : true
            } else {
                integratorReady = false
            }
        } else {
            integratorReady = false
        }
        let complete = blockers.isEmpty
            && registryReady
            && integratorReady
            && references?.isComplete == true
            && filesystem.isComplete

        return RuntimeV2MaintenanceOwnerEvidence(
            capturedAt: Date(),
            isComplete: complete,
            blockers: Array(Set(blockers)).sorted(),
            registry: registry ?? RuntimeV2MaintenanceRegistryEvidence(isComplete: false),
            integrator: integrator ?? RuntimeV2MaintenanceIntegratorEvidence(isComplete: false),
            references: references ?? RuntimeV2MaintenanceReferenceEvidence(),
            filesystem: filesystem,
            startupRecoveryActive: startupRecoveryActive
        )
    }

    /// Bounded read-only filesystem trace scan. Every lease sidecar and every
    /// non-dot `runtime/vm` entry is an owner trace. A process-death/TTL answer
    /// is deliberately NOT computed here: the authority requires actual proof of
    /// closed workers/fds and refuses when only a stale timestamp exists.
    static func scanFilesystem(
        domain: RuntimeV2MaintenanceDomain, fileManager: FileManager
    ) -> RuntimeV2MaintenanceFilesystemEvidence {
        let maximumEntries = 4_096
        var leases: [String] = []
        var runtimeDirectories: [String] = []
        var unreadable = false
        var complete = true

        let environments = domain.environmentTracesDirectory
        if fileManager.fileExists(atPath: environments.path) {
            do {
                let entries = try fileManager.contentsOfDirectory(atPath: environments.path)
                if entries.count > maximumEntries {
                    complete = false
                }
                for entry in entries.prefix(maximumEntries) where !entry.hasPrefix(".") {
                    let lease = environments.appendingPathComponent(entry, isDirectory: true)
                        .appendingPathComponent("lease.json")
                    if fileManager.fileExists(atPath: lease.path) {
                        leases.append(entry)
                    }
                }
            } catch {
                unreadable = true
                complete = false
            }
        }

        let runtime = domain.runtimeWorkingDirectory
        if fileManager.fileExists(atPath: runtime.path) {
            do {
                let entries = try fileManager.contentsOfDirectory(atPath: runtime.path)
                if entries.count > maximumEntries {
                    complete = false
                }
                for entry in entries.prefix(maximumEntries) where !entry.hasPrefix(".") {
                    runtimeDirectories.append(entry)
                }
            } catch {
                unreadable = true
                complete = false
            }
        }

        return RuntimeV2MaintenanceFilesystemEvidence(
            leaseEnvironmentIDs: Array(Set(leases)).sorted(),
            runtimeWorkingDirectoryIDs: Array(Set(runtimeDirectories)).sorted(),
            unreadableEntries: unreadable,
            isComplete: complete
        )
    }
}
