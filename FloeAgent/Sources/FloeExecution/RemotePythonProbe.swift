// FloeExecution — Real remote-Python capability probe.
// See docs/ARCHITECTURE_EXECUTION.md §5.3: replaces the T07 placeholder in
// SettingsProbes with a probe that actually contacts the host. Lives in
// FloeExecution (which can reach FloeSSH) because FloeCore must stay
// dependency-free; the settings UI consumes any `CapabilityProbe`.

import Foundation
import FloeCore

/// Probes remote Python by opening a session to the target host and
/// running `command -v python3 && python3 --version`. Honest three-state
/// result: no host, host without python3, or available (version + host).
public struct RemotePythonProbe: CapabilityProbe {
    public let name = "python.remote"

    private let service: RemotePythonService
    private let hostID: UUID?

    /// - Parameters:
    ///   - service: The remote Python service (session/host resolution).
    ///   - hostID: The host to probe; nil probes the default (first
    ///     configured) host.
    public init(service: RemotePythonService, hostID: UUID? = nil) {
        self.service = service
        self.hostID = hostID
    }

    public func probe() async -> CapabilityState {
        do {
            let resolved = try await service.resolveHostID(hostID)
            guard let version = try await service.detectPython3(hostID: resolved) else {
                return .unavailable(reason: "The configured host has no python3 on PATH")
            }
            return .available(version: "\(version) (remote)")
        } catch RemotePythonError.noHostConfigured {
            return .unavailable(reason: "No SSH host is configured")
        } catch RemotePythonError.hostNotFound(let id) {
            return .unavailable(reason: "Host not found: \(id.uuidString)")
        } catch {
            return .unavailable(reason: "Probe failed: \(error.localizedDescription)")
        }
    }
}
