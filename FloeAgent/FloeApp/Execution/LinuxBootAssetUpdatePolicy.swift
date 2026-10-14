// FloeApp — App-side wiring for verified Linux boot-asset updates.
//
// Two App-layer seams exist:
//   * the AUTOMATIC pre-start path, assembled in
//     `LinuxGuestBackendAssembly.makeService` (same directory): the registry
//     takes an immutable adoption callback at construction and every real
//     start runs it with `origin: .automatic` before that start's boot-asset
//     lease. An explicit rollback is never re-opened by that path.
//   * the EXPLICIT user/UI path below (`LinuxBootAssetUpdateCenter`), which
//     installs/rolls back with `origin: .explicitReapply` and is the only
//     path allowed to re-adopt a pair a user rolled back from.
//
// This file is the shared enumeration/probe seam: it enumerates the
// environments that can race a boot-asset commit (the registry's registered
// sessions — authoritative, because a first start registers its session
// before boot-path resolution), takes their serialized lifecycle
// reconciliation snapshots via the lifecycle manager (never a bare status
// check, so a guest that is starting/stopping/restarting or whose probe
// straddled a generation change is correctly refused), and hands both
// providers plus the shared gate to the package-owned
// LinuxGuestBootAssetUpdateService.
//
// The registry itself takes start leases on the same gate at every start
// entry, so an adoption/rollback commit and a guest start are mutually
// exclusive without any VM being implicitly stopped.

import Foundation
import FloeExecution

public enum LinuxBootAssetUpdatePolicy {
    /// Quiet-stop probe backed by the lifecycle manager's reconciliation
    /// snapshot: stopped phase, no registered instance, engine not
    /// running, not quarantined, no lifecycle operation in flight, and a
    /// generation-consistent probe. A nil snapshot is returned as nil (the
    /// service fails closed on it).
    public static func quietProbe(
        lifecycle: LinuxGuestLifecycleManager
    ) -> LinuxGuestBootAssetUpdateService.QuietProbe {
        { environmentID in
            await lifecycle.reconciliationSnapshot(environmentID: environmentID)
        }
    }

    /// Environment IDs bound to one image: the union of the registry's
    /// registered sessions and any provider-known descriptor naming the
    /// image. The registry set alone is authoritative for the quiet gate
    /// (an unregistered environment cannot be running or mid-start), and
    /// the union adds descriptor-only environments so their snapshots are
    /// re-proved inside the commit pass too. Never nil: the registry can
    /// always enumerate.
    public static func environmentIDs(
        registry: TinyEMULinuxGuestRegistry,
        environments: any LinuxGuestEnvironmentProviding
    ) -> LinuxGuestBootAssetUpdateService.EnvironmentIDs {
        { imageID in
            var ids = await registry.registeredEnvironmentIDs
            for id in await environments.environmentsUsingImage(imageID: imageID)
            where !ids.contains(id) {
                ids.append(id)
            }
            return ids
        }
    }

    /// Assemble the production update service: bundle URL injected by the
    /// app assembly (the generated `bundled-boot-pair` resource), shared
    /// lifecycle gate, registry-backed enumeration, lifecycle-backed quiet
    /// snapshots.
    public static func makeUpdateService(
        imagesRoot: URL,
        bundleProvider: @escaping @Sendable () -> URL?,
        registry: TinyEMULinuxGuestRegistry,
        lifecycle: LinuxGuestLifecycleManager,
        environments: any LinuxGuestEnvironmentProviding,
        gate: LinuxGuestBootAssetGate = .default,
        imageDirectoryResolver: LinuxGuestBootAssetUpdateService.ImageDirectoryResolver? = nil
    ) -> LinuxGuestBootAssetUpdateService {
        LinuxGuestBootAssetUpdateService(
            imagesRoot: imagesRoot,
            bundleProvider: bundleProvider,
            quietProbe: quietProbe(lifecycle: lifecycle),
            gate: gate,
            imageDirectoryResolver: imageDirectoryResolver
        )
    }

    /// Convenience: run the full stopped-only adoption for one image
    /// (explicit user action; see LinuxGuestBootAssetAdoptionOrigin).
    /// Throws (and changes nothing on disk) unless every environment of the
    /// image is quietly stopped under the shared gate.
    @discardableResult
    public static func installUpdate(
        imageID: String,
        service: LinuxGuestBootAssetUpdateService,
        registry: TinyEMULinuxGuestRegistry,
        environments: any LinuxGuestEnvironmentProviding
    ) async throws -> LinuxGuestBootAssetState {
        try await service.installUpdate(
            imageID: imageID,
            environmentIDs: environmentIDs(
                registry: registry,
                environments: environments
            ),
            origin: .explicitReapply
        )
    }

    @discardableResult
    public static func rollback(
        imageID: String,
        service: LinuxGuestBootAssetUpdateService,
        registry: TinyEMULinuxGuestRegistry,
        environments: any LinuxGuestEnvironmentProviding
    ) async throws -> LinuxGuestBootAssetState {
        try await service.rollback(
            imageID: imageID,
            environmentIDs: environmentIDs(
                registry: registry,
                environments: environments
            )
        )
    }
}

public extension LinuxGuestEnvironmentProviding {
    /// Provider-known environment ids whose descriptor names `imageID`.
    /// Providers without an enumeration source return an empty list; the
    /// registry's registered sessions still cover everything that can race
    /// a commit, so an empty result never weakens the gate.
    func environmentsUsingImage(imageID: String) async -> [String] {
        var matched: [String] = []
        for id in await knownEnvironmentIDs() {
            if await self.linuxGuestEnvironment(id: id)?.imageID == imageID {
                matched.append(id)
            }
        }
        return matched
    }

    /// Ids this provider can enumerate; the default is empty and concrete
    /// providers (the app assembly's environment store) override it.
    func knownEnvironmentIDs() async -> [String] { [] }
}

/// The concrete, app-ready boot-asset update center: one instance holds the
/// verified-update service bound to the app's registry (start leases),
/// lifecycle manager (quiet snapshots), environment provider (descriptor
/// enumeration) and the bundled resource URL. AppEnvironment constructs a
/// single center and hands it to the settings/update UI; every operation
/// runs through the package gate, so no adoption can interleave with a
/// guest start and no VM is ever implicitly stopped.
public final class LinuxBootAssetUpdateCenter: @unchecked Sendable {
    public let service: LinuxGuestBootAssetUpdateService
    private let registry: TinyEMULinuxGuestRegistry
    private let environments: any LinuxGuestEnvironmentProviding

    public init(
        imagesRoot: URL,
        bundleURL: @escaping @Sendable () -> URL?,
        registry: TinyEMULinuxGuestRegistry,
        lifecycle: LinuxGuestLifecycleManager,
        environments: any LinuxGuestEnvironmentProviding,
        gate: LinuxGuestBootAssetGate = .default,
        imageDirectoryResolver: LinuxGuestBootAssetUpdateService.ImageDirectoryResolver? = nil
    ) {
        self.registry = registry
        self.environments = environments
        self.service = LinuxGuestBootAssetUpdateService(
            imagesRoot: imagesRoot,
            bundleProvider: bundleURL,
            quietProbe: LinuxBootAssetUpdatePolicy.quietProbe(lifecycle: lifecycle),
            gate: gate,
            imageDirectoryResolver: imageDirectoryResolver
        )
    }

    /// Current state for the settings/update surface.
    public func state(imageID: String) async -> LinuxGuestBootAssetState {
        await service.state(imageID: imageID)
    }

    /// Install the bundled newer pair onto an installed image. Throws (and
    /// changes nothing on disk) unless every environment of the image is
    /// quietly stopped under the shared gate.
    @discardableResult
    public func installUpdate(imageID: String) async throws -> LinuxGuestBootAssetState {
        try await service.installUpdate(
            imageID: imageID,
            environmentIDs: LinuxBootAssetUpdatePolicy.environmentIDs(
                registry: registry,
                environments: environments
            ),
            origin: .explicitReapply
        )
    }

    /// Restore the manifest default (4.15) pair after verifying it still
    /// matches the manifest's artifact records.
    @discardableResult
    public func rollback(imageID: String) async throws -> LinuxGuestBootAssetState {
        try await service.rollback(
            imageID: imageID,
            environmentIDs: LinuxBootAssetUpdatePolicy.environmentIDs(
                registry: registry,
                environments: environments
            )
        )
    }
}
