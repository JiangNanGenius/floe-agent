// FloeApp — Linux guest backend assembly (TinyEMU RV64).
//
// Linux environments run their shell, Python and services inside one TinyEMU
// guest. This file builds the app-side backend:
//   - environment records declare `runtime == .linux` (native stays default),
//   - the descriptor exports the environment layer and the workspace over
//     virtio-9p,
//   - `RoutingLocalShellBackend` sends exec.shell into the guest for Linux
//     environments and keeps the native ios_system substrate everywhere else.
//
// No qualified modern guest image exists yet. The image catalog reads
// manifests from FloeAgent's app-owned LinuxGuest/images directory; starting a
// Linux environment without a qualified manifest fails with the recorded
// reason rather than falling back to the 2018 demo image.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeEnvironments
import FloeExecution
import FloeTools

/// Maps Floe environment records onto Linux guest descriptors. Only
/// environments explicitly declared `runtime == .linux` are owned by the
/// guest backend; deleted environments disappear immediately.
struct AppLinuxGuestEnvironmentProvider: LinuxGuestEnvironmentProviding {
    let registry: EnvironmentRegistry
    let defaultImageID: String

    func linuxGuestEnvironment(id: String) async -> LinuxGuestEnvironmentDescriptor? {
        guard let record = await registry.record(id: id),
              record.runtime == .linux,
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
            networkEnabled: false,
            serviceForwards: []
        )
    }
}

/// Builds the single injected Linux guest service for the app.
enum LinuxGuestBackendAssembly {
    /// Manifest id expected under `<artifact root>/LinuxGuest/images/<id>/`.
    /// The manifest must carry a passing modern-guest qualification record.
    static let defaultImageID = "floe-linux-base"

    static func makeService(registry: EnvironmentRegistry, artifactRoot: URL?) -> TinyEMULinuxCommandService {
        let imagesRoot = (artifactRoot ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("LinuxGuest", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
        let guestRegistry = TinyEMULinuxGuestRegistry(
            environments: AppLinuxGuestEnvironmentProvider(
                registry: registry,
                defaultImageID: defaultImageID
            ),
            images: FileLinuxGuestImageResolver(root: imagesRoot),
            limits: .standard,
            factory: TinyEMUGuestSessionFactory()
        )
        return TinyEMULinuxCommandService(registry: guestRegistry)
    }
}

/// Routes one-shot shell runs by the request's environment runtime: Linux
/// environments execute inside their guest, every other environment keeps the
/// injected native backend. Interactive sessions only exist natively; a Linux
/// environment reports the honest "not wired yet" error instead of opening a
/// native session that would escape the guest.
struct RoutingLocalShellBackend: LocalShellBackend {
    let native: any LocalShellBackend
    let guests: any LinuxCommandRunning
    let guestBackend: LinuxGuestShellBackend

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
        return try await guestBackend.openSession(request, cancellation: cancellation)
    }

    func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
        try await native.exchangeSession(request, cancellation: cancellation)
    }

    func closeSession(sessionID: String) async {
        await native.closeSession(sessionID: sessionID)
    }

    func signalSession(sessionID: String, signal: ShellSignal) async {
        await native.signalSession(sessionID: sessionID, signal: signal)
    }

    func resizeSession(sessionID: String, columns: Int, rows: Int) async {
        await native.resizeSession(sessionID: sessionID, columns: columns, rows: rows)
    }
}
#endif
