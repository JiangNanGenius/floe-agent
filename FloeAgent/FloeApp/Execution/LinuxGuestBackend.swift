// FloeApp — Linux guest backend assembly (TinyEMU RV64).
//
// Linux environments run their shell, Python and services inside one TinyEMU
// guest. This file builds the app-side backend:
//   - environment records declare `executionBackend == .linuxVM` (native
//     stays the default),
//   - the descriptor exports the environment layer and the workspace over
//     virtio-9p,
//   - `RoutingLocalShellBackend` sends exec.shell into the guest for Linux
//     environments and keeps the native ios_system substrate everywhere else.
//
// No qualified modern guest image exists yet. The image catalog reads
// manifests from FloeAgent's app-owned LinuxGuest/images directory; starting a
// Linux environment without a qualified manifest fails with the recorded
// reason rather than falling back to the 2018 demo image. The backend keeps
// environment ownership even without a real artifact root; image resolution
// then reports unavailable. No request falls back to a temporary directory or
// a native interpreter because Linux image storage is unavailable.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeEnvironments
import FloeExecution
import FloeTools

/// Maps Floe environment records onto Linux guest descriptors. Only
/// environments explicitly declared `executionBackend == .linuxVM` are owned
/// by the guest backend; deleted environments disappear immediately.
struct AppLinuxGuestEnvironmentProvider: LinuxGuestEnvironmentProviding {
    let registry: EnvironmentRegistry
    let defaultImageID: String

    func linuxGuestEnvironment(id: String) async -> LinuxGuestEnvironmentDescriptor? {
        guard let record = await registry.record(id: id),
              record.executionBackend == .linuxVM,
              record.state != .deleting else { return nil }

        let layer = await registry.layerURL(for: id)
        var shares: [LinuxGuestShare] = []
        if let layer {
            shares.append(LinuxGuestShare(tag: "floe-env", hostDirectory: layer))
        }
        if let workspace = try? await registry.workspaceRoot(for: id),
           !shares.contains(where: { $0.hostDirectory.standardizedFileURL == workspace.standardizedFileURL }) {
            shares.append(LinuxGuestShare(tag: "workspace", hostDirectory: workspace))
        }

        return LinuxGuestEnvironmentDescriptor(
            id: record.id,
            ownerID: record.ownerID,
            taskID: nil,
            writableDirectory: layer,
            shares: Array(shares.prefix(LinuxGuestShare.maximumShares)),
            imageID: defaultImageID,
            ramMB: nil,
            // Linux environments need apt/pip to install python3 and packages.
            // The engine has a single slirp instance, and the registry already
            // runs at most one guest per process, so enabling the network here
            // cannot create a second networked VM.
            networkEnabled: true,
            serviceForwards: []
        )
    }
}

/// Builds the single injected Linux guest service for the app.
enum LinuxGuestBackendAssembly {
    /// Manifest id expected under `<artifact root>/LinuxGuest/images/<id>/`.
    /// The manifest must carry a passing modern-guest qualification record.
    static let defaultImageID = "floe-debian13-riscv64-202609202607"

    /// Keep environment ownership available even when durable image storage is
    /// unavailable, so a Linux-selected request cannot fall back to native.
    static func makeService(registry: EnvironmentRegistry, artifactRoot: URL?) -> TinyEMULinuxCommandService {
        let images: any LinuxGuestImageResolving
        if let artifactRoot {
            images = FileLinuxGuestImageResolver(root: artifactRoot
                .appendingPathComponent("LinuxGuest", isDirectory: true)
                .appendingPathComponent("images", isDirectory: true))
        } else {
            FloeLogger(category: .tools).warning(
                "Linux guest images unavailable: no durable artifact root"
            )
            images = UnavailableLinuxGuestImageResolver()
        }
        let guestRegistry = TinyEMULinuxGuestRegistry(
            environments: AppLinuxGuestEnvironmentProvider(
                registry: registry,
                defaultImageID: defaultImageID
            ),
            images: images,
            limits: .standard,
            factory: TinyEMUGuestSessionFactory()
        )
        return TinyEMULinuxCommandService(registry: guestRegistry)
    }

    /// Verified image storage on the same artifact root as the resolver: it
    /// is what `floe-env image …` and the environment UI read. nil without a
    /// durable artifact root; guest ownership remains available independently.
    static func makeImageService(artifactRoot: URL?) -> LinuxGuestImageInstallationService? {
        guard let artifactRoot else { return nil }
        return LinuxGuestImageInstallationService(root: artifactRoot, limits: .standard)
    }
}

private struct UnavailableLinuxGuestImageResolver: LinuxGuestImageResolving {
    func linuxGuestImage(id: String) async -> LinuxGuestImage? { nil }
    func linuxGuestImageVerificationFailure(id: String) async -> String? {
        "Linux guest image storage is unavailable"
    }
}

/// Routes one-shot shell runs by the request's environment runtime: Linux
/// environments execute inside their guest, every other environment keeps the
/// injected native backend. Interactive sessions retain the backend selected
/// at open time, including Linux PTY sessions.
struct RoutingLocalShellBackend: LocalShellBackend {
    let native: any LocalShellBackend
    let guests: any LinuxCommandRunning
    let guestBackend: LinuxGuestShellBackend
    private let guestSessions = GuestSessionIDSet()

    init(native: any LocalShellBackend, guests: any LinuxCommandRunning, limits: LinuxGuestLimits = .standard) {
        self.native = native
        self.guests = guests
        self.guestBackend = LinuxGuestShellBackend(runner: guests, limits: limits)
    }

    func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        guard let environmentID = request.toolEnvironment?.id,
              await guests.ownsLinuxEnvironment(environmentID: environmentID) else {
            return await native.run(request, cancellation: cancellation)
        }
        return await guestBackend.run(request, cancellation: cancellation)
    }

    func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
        guard let environmentID = request.toolEnvironment?.id,
              await guests.ownsLinuxEnvironment(environmentID: environmentID) else {
            return try await native.openSession(request, cancellation: cancellation)
        }
        let result = try await guestBackend.openSession(request, cancellation: cancellation)
        guestSessions.insert(request.sessionID)
        return result
    }

    func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
        guard guestSessions.contains(request.sessionID) else {
            return try await native.exchangeSession(request, cancellation: cancellation)
        }
        let result = try await guestBackend.exchangeSession(request, cancellation: cancellation)
        if !result.alive { guestSessions.remove(request.sessionID) }
        return result
    }

    func closeSession(sessionID: String) async {
        guard guestSessions.remove(sessionID) else {
            await native.closeSession(sessionID: sessionID)
            return
        }
        await guestBackend.closeSession(sessionID: sessionID)
    }

    func signalSession(sessionID: String, signal: ShellSignal) async {
        guard guestSessions.contains(sessionID) else {
            await native.signalSession(sessionID: sessionID, signal: signal)
            return
        }
        await guestBackend.signalSession(sessionID: sessionID, signal: signal)
    }

    func resizeSession(sessionID: String, columns: Int, rows: Int) async {
        guard guestSessions.contains(sessionID) else {
            await native.resizeSession(sessionID: sessionID, columns: columns, rows: rows)
            return
        }
        await guestBackend.resizeSession(sessionID: sessionID, columns: columns, rows: rows)
    }
}

/// Session ids that belong to the Linux guest backend, so exchange/close/
/// signal/resize can be routed without re-resolving the environment.
final class GuestSessionIDSet: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []

    func insert(_ id: String) { lock.lock(); ids.insert(id); lock.unlock() }
    @discardableResult func remove(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.remove(id) != nil
    }
    func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
}
#endif
