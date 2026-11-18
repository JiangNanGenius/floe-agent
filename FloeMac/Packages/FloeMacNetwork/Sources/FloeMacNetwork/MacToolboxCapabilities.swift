import Foundation
import FloeToolboxCore

/// The Mac network-diagnostics and communication slice of the Toolbox.
///
/// This is deliberately a capability description, not a claim that a tool ran.
/// Runtime permission state and actual results stay with the host and the
/// transport. Hardware that is absent or unverified is never reported as a
/// successful reading.
public enum MacToolboxPermission: String, CaseIterable, Sendable {
    /// macOS 15+ local-network privacy for Bonjour browsing and LAN probes.
    case localNetwork
    /// Location Services is required before CoreWLAN returns SSID/BSSID.
    case locationForWiFiIdentity
    /// CoreBluetooth central role for the BLE GATT serial transport.
    case bluetooth
    /// App Sandbox serial-device access for the selected `/dev/cu.*` node.
    case usbSerialAccess
}

public enum MacToolboxSelection: String, CaseIterable, Sendable {
    case bluetoothPeripheral
    case usbSerialPort
}

public enum MacToolboxRequirement: Equatable, Sendable {
    case permission(MacToolboxPermission)
    case selection(MacToolboxSelection)
    /// A plist/entitlement/declaration the host must supply before the call.
    case hostDeclaration(String)
    case hardware(String)
}

public enum MacToolboxAvailability: Equatable, Sendable {
    /// The shared implementation exists and this slice exercises it.
    case available
    /// The shared implementation exists, but the host must satisfy the listed
    /// requirements before the first operation. A denied requirement is an
    /// explicit failure, never an empty success.
    case availableWhenRequirementsMet
    /// This Mac candidate does not provide the required system capability.
    case unavailable(String)
}

public struct MacToolboxSubsystemCapability: Equatable, Sendable {
    public let identifier: String
    public let availability: MacToolboxAvailability
    public let requirements: [MacToolboxRequirement]
    public let detail: String
    public let modbusFramings: [ModbusFraming]

    public init(identifier: String, availability: MacToolboxAvailability,
                requirements: [MacToolboxRequirement], detail: String,
                modbusFramings: [ModbusFraming] = []) {
        self.identifier = identifier
        self.availability = availability
        self.requirements = requirements
        self.detail = detail
        self.modbusFramings = modbusFramings
    }
}

public struct MacToolboxToolCapability: Equatable, Sendable {
    public let tool: ToolboxTool
    public let availability: MacToolboxAvailability
    public let requirements: [MacToolboxRequirement]
    public let detail: String
    public let limitations: [String]
    public let subsystems: [MacToolboxSubsystemCapability]

    public init(tool: ToolboxTool, availability: MacToolboxAvailability,
                requirements: [MacToolboxRequirement] = [], detail: String,
                limitations: [String] = [], subsystems: [MacToolboxSubsystemCapability] = []) {
        self.tool = tool
        self.availability = availability
        self.requirements = requirements
        self.detail = detail
        self.limitations = limitations
        self.subsystems = subsystems
    }
}

/// Tools actually exposed by the manually initiated host surface.
public enum MacToolboxNetworkScope {
    public static let tools: [ToolboxTool] = [.ping, .traceroute, .dns, .port, .wifi, .roaming]

    /// Human-readable grouping used by the Mac integration note.
    public static let diagnosticTools: [ToolboxTool] = [.ping, .traceroute, .dns, .port, .lan, .wifi, .roaming]
    public static let communicationTools: [ToolboxTool] = [.serialAssistant, .http, .webSocket, .mqtt]
}

public enum MacToolboxCapabilityMatrix {
    /// Returns nil for tools outside this slice. A caller must not turn nil into
    /// an "unavailable" badge for unrelated utilities; their own owner reports
    /// their state.
    public static func capability(for tool: ToolboxTool) -> MacToolboxToolCapability? {
        if [.lan, .serialAssistant, .http, .webSocket, .mqtt].contains(tool) {
            return .init(tool: tool,
                availability: .unavailable("The host authorization and revocation lifecycle is not connected."),
                detail: "This tool is not enabled by the manual diagnostics surface.")
        }
        switch tool {
        case .ping:
            return .init(tool: tool, availability: .available,
                detail: "Four IPv4 ICMP probes using the built-in macOS ping utility.",
                limitations: ["IPv4 targets only; the live run requires a working ICMP datagram path. A timeout is not proof that the host is offline."])
        case .traceroute:
            return .init(tool: tool, availability: .available,
                detail: "The macOS traceroute utility with numerical addresses and a 30-hop limit.",
                limitations: ["IPv4 targets only. Intermediate routers may suppress ICMP; missing hops stay missing, never invented."])
        case .dns:
            return .init(tool: tool, availability: .available,
                detail: "A, AAAA, CNAME, PTR, MX, TXT and SRV queries using dig and the configured DNS servers.",
                limitations: ["PTR accepts a reverse DNS name. Local Bonjour lookup is separate."])
        case .port:
            return .init(tool: tool, availability: .available,
                detail: "Bounded TCP checks for the single host and at most 64 ports entered by the user.",
                limitations: ["TCP only; this is not a range scanner. A failed check is not evidence that a filtered port is closed."])
        case .lan:
            return .init(tool: tool, availability: .availableWhenRequirementsMet,
                requirements: [
                    .permission(.localNetwork),
                    .hostDeclaration("NSLocalNetworkUsageDescription"),
                    .hostDeclaration("NSBonjourServices entries equal to LANDiscoveryScope.declaredBonjourTypes")
                ],
                detail: "The shared LANDiscoveryEngine with a Mac NWBrowser/DNSServiceResolve probe for the declared Bonjour types.",
                limitations: ["Bonjour only; devices that do not advertise a declared service type are not discovered. A blocked permission is distinguished from an empty result."],
                subsystems: [.init(identifier: "lan.bonjour",
                    availability: .availableWhenRequirementsMet,
                    requirements: [.permission(.localNetwork),
                                   .hostDeclaration("NSLocalNetworkUsageDescription"),
                                   .hostDeclaration("NSBonjourServices")],
                    detail: "Browses only the app-declared service types and resolves addresses/ports through DNS-SD.")])
        case .wifi:
            return .init(tool: tool, availability: .availableWhenRequirementsMet,
                requirements: [
                    .permission(.locationForWiFiIdentity),
                    .hostDeclaration("NSLocationUsageDescription"),
                    .hostDeclaration("com.apple.security.personal-information.location when sandboxed")
                ],
                detail: "CoreWLAN interface power, SSID, BSSID, RSSI, noise and channel. Permission state is reported separately from the reading.",
                limitations: ["Without Location Services authorization the interface state remains readable but SSID/BSSID/RSSI stay nil. No RSSI is synthesized from NWPath. Wi-Fi may be connected while Ethernet is the primary path; the interface reading does not depend on the primary path.",
                              "The default-gateway convenience value comes from the existing Wi-Fi path service and can be nil when Wi-Fi is not primary."],
                subsystems: [.init(identifier: "wifi.identity",
                    availability: .availableWhenRequirementsMet,
                    requirements: [.permission(.locationForWiFiIdentity)],
                    detail: "SSID/BSSID require Location Services; RSSI is only reported when CoreWLAN returns a measured dBm value.")])
        case .roaming:
            return .init(tool: tool, availability: .available,
                detail: "Six user-initiated CoreWLAN readings of the current access point and signal.",
                limitations: ["SSID/BSSID changes require the same Location Services authorization as Wi-Fi. Missing identity stays missing."],
                subsystems: [.init(identifier: "roaming.identity",
                    availability: .availableWhenRequirementsMet,
                    requirements: [.permission(.locationForWiFiIdentity)],
                    detail: "Consecutive observed BSSIDs are compared for changes.")])
        case .serialAssistant:
            return .init(tool: tool, availability: .availableWhenRequirementsMet,
                requirements: [],
                detail: "One SerialSession/ModbusClient path for TCP, UDP, BLE GATT and Mac USB serial, preserving the selected endpoint and the existing authorization/journal boundary.",
                limitations: ["Bluetooth here is BLE GATT, not classic Bluetooth SPP. A peripheral must be selected; the adapter never scans implicitly.",
                              "USB support covers standard USB-serial adapters exposed as /dev/cu.* by a system driver. A device with no serial driver needs a separately signed DriverKit extension, which this slice does not provide or install.",
                              "Raw mode sends application bytes; Modbus requires the selected framing. Do not send raw bytes through a structured Modbus session.",
                              "Write-without-response GATT writes report local submission only; the peripheral did not acknowledge delivery."],
                subsystems: [
                    .init(identifier: "serial.tcp", availability: .available,
                        requirements: [], detail: "NetworkSerialConnection TCP, optional TLS, with bounded send/receive and cancellation.",
                        modbusFramings: [.mbap, .rtu, .ascii]),
                    .init(identifier: "serial.udp", availability: .available,
                        requirements: [], detail: "Bounded datagram-preserving UDP; no cross-datagram concatenation in Modbus.",
                        modbusFramings: [.mbap, .rtu, .ascii]),
                    .init(identifier: "serial.bluetooth", availability: .availableWhenRequirementsMet,
                        requirements: [.permission(.bluetooth), .selection(.bluetoothPeripheral),
                                       .hostDeclaration("NSBluetoothAlwaysUsageDescription")],
                        detail: "CoreBluetooth central GATT write/notify adapter with actual maximum-write-length chunking.",
                        modbusFramings: [.rtu, .ascii]),
                    .init(identifier: "serial.usb", availability: .availableWhenRequirementsMet,
                        requirements: [.selection(.usbSerialPort),
                                       .hostDeclaration("com.apple.security.device.serial when sandboxed")],
                        detail: "POSIX termios over a host-enumerated /dev/cu.* USB serial adapter with vendor/product binding.",
                        modbusFramings: [.rtu, .ascii])
                ])
        case .http:
            return .init(tool: tool, availability: .available,
                detail: "HTTP/HTTPS through HTTPClient and HTTPDebugSession: bounded response, same-origin redirects, explicit target, TLS system trust or supplied roots, journaled request/response.",
                limitations: ["No cross-origin redirect or credential forwarding. The command is an HTTP client, not a browser session. Response bodies can be truncated at the configured limit; truncation is reported."])
        case .webSocket:
            return .init(tool: tool, availability: .available,
                detail: "RFC 6455 ws/wss through WebSocketClientConnection and SerialSession, preserving text/binary message identity, ping/pong and cancellation.",
                limitations: ["No custom WebSocket extension negotiation; headers/protocols are bounded and validated by the shared client. Message assembly is bounded."])
        case .mqtt:
            return .init(tool: tool, availability: .available,
                detail: "MQTT 3.1.1 and 5 through MQTTClient/MQTTFramedConnection: CONNECT, SUBSCRIBE, UNSUBSCRIBE, PUBLISH QoS 0/1/2, keepalive, clean sessions and redacted capture.",
                limitations: ["Clean session only; no persistent-session replay. An unacknowledged publish is an uncertain outcome and is not automatically replayed. TLS uses the shared NWProtocolTLS trust configuration."])
        default:
            return nil
        }
    }

    /// Stable identifiers for the slice; used by integration tests instead of
    /// relying on UI labels.
    public static var implementedToolIdentifiers: [String] {
        MacToolboxNetworkScope.tools.map(\.rawValue)
    }

    public static func isInSlice(_ tool: ToolboxTool) -> Bool {
        MacToolboxNetworkScope.tools.contains(tool)
    }
}
