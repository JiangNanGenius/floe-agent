import Foundation
import Network
import NetworkExtension
import BridgeCore

/// Owns the app's packet-tunnel preference and runtime status.
///
/// It never reports the tunnel as connected because a configuration was saved.
/// Only `NEVPNStatus.connected` plus a real TCP probe of the DDI service counts
/// as transport-ready in the coordinator.
@MainActor
final class BridgeTunnelManager {
    private(set) var phase: BridgeTunnelPhase = .unknown
    private(set) var detail: String?
    private(set) var lastError: String?

    private var manager: NETunnelProviderManager?
    private var probeInFlight = false

    /// Poll the system status. Called by the host status timer; avoids treating
    /// another app's VPN notification as this reflector's state.
    func syncStatus() {
        guard let manager else { return }
        apply(manager.connection.status, detail: "status-poll")
    }

    func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            if let existing = managers.first(where: { manager in
                (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                    == BridgeBuild.tunnelBundleIdentifier
            }) {
                manager = existing
            }
            if let manager {
                apply(manager.connection.status, detail: "loaded-from-preferences")
            } else {
                setPhase(.disconnected, detail: "no-saved-configuration")
            }
        } catch {
            setPhase(.failed, detail: error.localizedDescription)
        }
    }

    private func ensureManager() async throws -> NETunnelProviderManager {
        if let manager { return manager }
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let created = managers.first(where: { manager in
            (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                == BridgeBuild.tunnelBundleIdentifier
        }) ?? NETunnelProviderManager()

        let protocolConfiguration = NETunnelProviderProtocol()
        protocolConfiguration.providerBundleIdentifier = BridgeBuild.tunnelBundleIdentifier
        protocolConfiguration.serverAddress = BridgeTransport.peerAddress
        protocolConfiguration.providerConfiguration = [
            "version": 1,
            "interfaceAddress": BridgeTransport.interfaceAddress,
            "peerAddress": BridgeTransport.peerAddress,
            "routePrefixLength": BridgeTransport.routePrefixLength,
        ]

        created.localizedDescription = BridgeTransport.tunnelDescription
        created.protocolConfiguration = protocolConfiguration
        created.isEnabled = true
        created.isOnDemandEnabled = false
        created.onDemandRules = []
        manager = created
        return created
    }

    func start() async throws {
        setPhase(.connecting, detail: "saving-preferences")
        let manager = try await ensureManager()
        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        } catch {
            setPhase(.failed, detail: error.localizedDescription)
            throw BridgeTunnelError.saveFailed(error.localizedDescription)
        }
        guard let session = manager.connection as? NETunnelProviderSession else {
            setPhase(.invalid, detail: "connection-is-not-a-provider-session")
            throw BridgeTunnelError.sessionUnavailable
        }
        do {
            try session.startVPNTunnel()
        } catch {
            setPhase(.failed, detail: error.localizedDescription)
            throw BridgeTunnelError.startFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            let status = manager.connection.status
            apply(status, detail: "waiting-for-connected")
            switch status {
            case .connected:
                return
            case .invalid:
                throw BridgeTunnelError.rejected("The system rejected the saved tunnel configuration.")
            case .disconnected:
                // A disconnect can be transient while the provider starts.
                break
            default:
                break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw BridgeTunnelError.timeout
    }

    func stop() {
        guard let manager else {
            setPhase(.disconnected, detail: "no-saved-configuration")
            return
        }
        setPhase(.disconnecting, detail: "stop-requested")
        manager.connection.stopVPNTunnel()
    }

    /// Reads the existing extension app-message snapshot without starting or
    /// reconfiguring the tunnel. A missing session, a non-connected status or
    /// an error returns a typed unavailable result. The provider message cannot
    /// be withdrawn, so a 1.5 s deadline races the callback through a one-shot
    /// gate; a late callback is ignored rather than resuming twice.
    func sampleProviderSnapshot(
        timeout: TimeInterval = BridgeTunnelSnapshotPolicy.requestTimeoutSeconds
    ) async -> BridgeTunnelProviderSnapshotRead {
        guard let manager else {
            return .unavailable(.noConfiguration)
        }
        guard manager.connection.status == .connected else {
            return .unavailable(.notConnected)
        }
        guard let session = manager.connection as? NETunnelProviderSession else {
            return .unavailable(.notProviderSession)
        }

        return await withCheckedContinuation {
            (continuation: CheckedContinuation<BridgeTunnelProviderSnapshotRead, Never>) in
            let once = BridgeOneShotValue<BridgeTunnelProviderSnapshotRead>()
            let finish: @Sendable (BridgeTunnelProviderSnapshotRead) -> Void = { value in
                if once.deliver(value) {
                    continuation.resume(returning: value)
                }
            }
            let queue = DispatchQueue(label: "org.floeagent.iosbridge.tunnel.snapshot")
            queue.asyncAfter(deadline: .now() + max(0.1, timeout)) {
                finish(.timeout)
            }
            do {
                try session.sendProviderMessage(Data("{}".utf8)) { response in
                    guard let response else {
                        finish(.unavailable(.messageFailed))
                        return
                    }
                    guard let snapshot = BridgeTunnelProviderSnapshot.parse(response) else {
                        finish(.unavailable(.malformedResponse))
                        return
                    }
                    finish(.available(snapshot))
                }
            } catch {
                finish(.unavailable(.sendFailed))
            }
        }
    }

    func probe() async -> BridgeTunnelProbeResult {
        if probeInFlight {
            return .unreachable("probe already in flight")
        }
        probeInFlight = true
        defer { probeInFlight = false }

        let queue = DispatchQueue(label: "org.floeagent.iosbridge.tunnel.probe")
        return await withCheckedContinuation { continuation in
            let gate = ProbeGate(continuation: continuation)
            let parameters = NWParameters.tcp
            let connection = NWConnection(
                host: NWEndpoint.Host(BridgeTransport.peerAddress),
                port: NWEndpoint.Port(rawValue: BridgeTransport.remotePairingPort)!,
                using: parameters
            )
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.cancel()
                    gate.finish(.reachable)
                case .waiting(let error):
                    if #available(iOS 14.2, *),
                       connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                        gate.finish(.localNetworkDenied)
                    } else {
                        _ = error
                    }
                case .failed(let error):
                    gate.finish(.unreachable(error.localizedDescription))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) {
                connection.cancel()
                gate.finish(.unreachable("no answer within 3s"))
            }
        }
    }

    private func apply(_ status: NEVPNStatus, detail: String?) {
        let mapped: BridgeTunnelPhase
        switch status {
        case .invalid: mapped = .invalid
        case .disconnected: mapped = .disconnected
        case .connecting: mapped = .connecting
        case .connected: mapped = .connected
        case .reasserting: mapped = .connecting
        case .disconnecting: mapped = .disconnecting
        @unknown default: mapped = .unknown
        }
        setPhase(mapped, detail: detail)
    }

    private func setPhase(_ phase: BridgeTunnelPhase, detail: String?) {
        self.phase = phase
        self.detail = detail
        if phase == .failed { lastError = detail }
    }
}

enum BridgeTunnelProbeResult: Equatable, Sendable {
    case reachable
    case localNetworkDenied
    case unreachable(String)
}

enum BridgeTunnelError: LocalizedError {
    case saveFailed(String)
    case startFailed(String)
    case sessionUnavailable
    case rejected(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .saveFailed(let message): return "Could not save the VPN configuration: \(message)"
        case .startFailed(let message): return "Could not start the reflector: \(message)"
        case .sessionUnavailable: return "The tunnel connection is not a packet-tunnel session."
        case .rejected(let message): return message
        case .timeout: return "The reflector did not reach connected within 25 seconds."
        }
    }
}


private final class ProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<BridgeTunnelProbeResult, Never>

    init(continuation: CheckedContinuation<BridgeTunnelProbeResult, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: BridgeTunnelProbeResult) {
        lock.lock()
        if resumed {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        continuation.resume(returning: value)
    }
}
