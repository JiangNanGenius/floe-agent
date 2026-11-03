import Foundation
import NetworkExtension
import BridgeCore

/// Independent local IPv4 reflector.
///
/// Only `10.7.0.1 ↔ 10.7.0.2` datagrams are accepted. The route installed by
/// the host is a single /32 to the peer, and the provider re-validates the
/// destination pair; a broader route cannot turn this into an Internet tunnel.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "org.floeagent.iosbridge.tunnel.state")
    private var runState = BridgeTunnelRunState()
    private var reflector = BridgeIPv4Reflector()
    private var startedAt: Date?

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let interfaceAddress = providerConfiguration?["interfaceAddress"] as? String
        let peerAddress = providerConfiguration?["peerAddress"] as? String
        let prefix = (providerConfiguration?["routePrefixLength"] as? NSNumber)?.intValue
            ?? providerConfiguration?["routePrefixLength"] as? Int

        guard interfaceAddress == BridgeTransport.interfaceAddress,
              peerAddress == BridgeTransport.peerAddress,
              prefix == BridgeTransport.routePrefixLength else {
            completionHandler(TunnelProviderError.invalidConfiguration)
            return
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: BridgeTransport.peerAddress)
        let ipv4 = NEIPv4Settings(
            addresses: [BridgeTransport.interfaceAddress],
            subnetMasks: [BridgeTransport.routeSubnetMask]
        )
        ipv4.includedRoutes = [
            NEIPv4Route(destinationAddress: BridgeTransport.peerAddress,
                        subnetMask: BridgeTransport.routeSubnetMask),
        ]
        ipv4.excludedRoutes = [.default()]
        settings.ipv4Settings = ipv4
        settings.dnsSettings = nil
        settings.mtu = 1400

        let completionBox = TunnelCompletionBox(completionHandler)
        let settingsEpoch: UInt64 = stateQueue.sync {
            reflector = BridgeIPv4Reflector()
            startedAt = nil
            return runState.beginStart()
        }

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else {
                completionBox.call(TunnelProviderError.providerReleased)
                return
            }
            if let error {
                self.stateQueue.sync { self.runState.stop() }
                completionBox.call(error)
                return
            }
            // Stop may have arrived while the system was applying settings.
            // Do not let this completion resurrect the provider or its loop.
            let allowed = self.stateQueue.sync { self.runState.completeStart(settingsEpoch) }
            guard allowed else {
                completionBox.call(TunnelProviderError.startCancelled)
                return
            }
            self.stateQueue.sync { self.startedAt = Date() }
            BridgeLog.shared.append("tunnel_started iface=\(BridgeTransport.interfaceAddress)/32 peer=\(BridgeTransport.peerAddress) epoch=\(settingsEpoch)")
            self.startReadLoop(epoch: settingsEpoch)
            completionBox.call(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        stateQueue.sync {
            runState.stop()
            startedAt = nil
        }
        BridgeLog.shared.append("tunnel_stopped reason=\(reason.rawValue)")
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let completionHandler else { return }
        let snapshot: [String: Any] = stateQueue.sync {
            [
                "schema": 1,
                "epoch": runState.epoch,
                "startedAt": startedAt.map { BridgeClock.timestamp($0) } as Any,
                "uptimeSeconds": startedAt.map { Date().timeIntervalSince($0) } as Any,
                "readLoopActive": runState.readLoopActive,
                "shouldRun": runState.shouldRun,
                "reflector": reflector.snapshotJSON(),
                "interfaceAddress": BridgeTransport.interfaceAddress,
                "peerAddress": BridgeTransport.peerAddress,
            ]
        }
        completionHandler(try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]))
    }

    private func startReadLoop(epoch expectedEpoch: UInt64) {
        guard stateQueue.sync(execute: { runState.allowsRead(epoch: expectedEpoch) }) else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            let stillActive = self.stateQueue.sync { self.runState.allowsRead(epoch: expectedEpoch) }
            guard stillActive else { return }

            var output: [Data] = []
            var outputProtocols: [NSNumber] = []
            for (index, packet) in packets.enumerated() {
                guard index < protocols.count, protocols[index].int32Value == AF_INET else { continue }
                let result = self.stateQueue.sync { () -> BridgeReflectionResult in
                    self.reflector.reflect([UInt8](packet))
                }
                switch result {
                case .reflected(let bytes):
                    output.append(Data(bytes))
                    outputProtocols.append(protocols[index])
                case .rejected:
                    break
                }
            }
            if !output.isEmpty {
                let allowed = self.stateQueue.sync { self.runState.allowsRead(epoch: expectedEpoch) }
                guard allowed else { return }
                self.packetFlow.writePackets(output, withProtocols: outputProtocols)
            }
            self.startReadLoop(epoch: expectedEpoch)
        }
    }
}

enum TunnelProviderError: LocalizedError {
    case invalidConfiguration
    case providerReleased
    case startCancelled

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "The reflector configuration is not the reviewed 10.7.0.1/32 layout."
        case .providerReleased:
            return "The tunnel provider was released before configuration completed."
        case .startCancelled:
            return "The reflector start was cancelled before its network settings were applied."
        }
    }
}


private final class TunnelCompletionBox: @unchecked Sendable {
    private let handler: ((Error?) -> Void)?
    init(_ handler: ((Error?) -> Void)?) { self.handler = handler }
    func call(_ error: Error?) { handler?(error) }
}
