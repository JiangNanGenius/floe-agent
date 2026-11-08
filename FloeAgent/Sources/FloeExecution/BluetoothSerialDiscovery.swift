import Foundation

/// Discovery metadata only: inspecting these attributes never writes, reads a
/// value or enables notifications. Attribute properties do not prove UART semantics.
public struct BluetoothSerialGATTCharacteristic: Sendable, Equatable {
    public var uuid: String
    public var canWrite: Bool
    public var canNotify: Bool
    public init(uuid: String, canWrite: Bool, canNotify: Bool) {
        self.uuid = uuid; self.canWrite = canWrite; self.canNotify = canNotify
    }
}

public struct BluetoothSerialGATTService: Sendable, Equatable {
    public var uuid: String
    public var characteristics: [BluetoothSerialGATTCharacteristic]
    public init(uuid: String, characteristics: [BluetoothSerialGATTCharacteristic]) {
        self.uuid = uuid; self.characteristics = characteristics
    }
}

public struct BluetoothSerialChannel: Sendable, Codable, Equatable, Identifiable {
    public enum Recognition: String, Sendable, Codable { case nordicUART, microchipUART, unverified }
    public let endpoint: BluetoothSerialEndpoint
    public let recognition: Recognition
    public var id: String {
        [endpoint.serviceUUID, endpoint.writeCharacteristicUUID, endpoint.notifyCharacteristicUUID ?? ""]
            .map { BluetoothSerialDiscovery.canonicalUUID($0) ?? $0 }.joined(separator: "/")
    }
    public init(endpoint: BluetoothSerialEndpoint, recognition: Recognition) {
        self.endpoint = endpoint; self.recognition = recognition
    }
}

public enum BluetoothSerialDiscovery {
    private static let baseSuffix = "-0000-1000-8000-00805F9B34FB"
    private static let nus = (service: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E",
                              write: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E",
                              notify: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let microchip = (service: "49535343-FE7D-4AE5-8FA9-9FAFD205E455",
                                    write: "49535343-8841-43F4-A8D4-ECBE34729BB3",
                                    notify: "49535343-1E4D-4BD9-BA61-23C647249616")

    public static func canonicalUUID(_ value: String) -> String? {
        let upper = value.uppercased()
        if [4, 8].contains(upper.utf8.count), upper.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0)
        }) { return (upper.count == 4 ? "0000" + upper : upper) + baseSuffix }
        return upper.utf8.count == 36 ? UUID(uuidString: upper)?.uuidString : nil
    }

    /// Exact UART tuples are taken from Nordic NUS and Microchip Transparent
    /// UART specifications. Unknown vendor characteristics are choices requiring
    /// confirmation, never an automatic UART or pairing claim.
    public static func channels(peripheralID: UUID, services: [BluetoothSerialGATTService]) throws -> [BluetoothSerialChannel] {
        guard services.count <= 64 else { throw BluetoothSerialError.discoveryLimit }
        var result: [BluetoothSerialChannel] = []
        var serviceIDs = Set<String>()
        for service in services {
            guard let serviceID = canonicalUUID(service.uuid), serviceIDs.insert(serviceID).inserted else {
                throw BluetoothSerialError.ambiguousAttributes
            }
            guard service.characteristics.count <= 128 else { throw BluetoothSerialError.discoveryLimit }
            var characteristicIDs = Set<String>()
            for characteristic in service.characteristics {
                guard let id = canonicalUUID(characteristic.uuid), characteristicIDs.insert(id).inserted else {
                    throw BluetoothSerialError.ambiguousAttributes
                }
            }
            let known: (String, String, BluetoothSerialChannel.Recognition)?
            if serviceID == nus.service { known = (nus.write, nus.notify, .nordicUART) }
            else if serviceID == microchip.service { known = (microchip.write, microchip.notify, .microchipUART) }
            else { known = nil }
            if let (writeID, notifyID, recognition) = known {
                // Do not fall back to a control characteristic if a known UART
                // service is incomplete or advertises the wrong direction.
                if service.characteristics.contains(where: { canonicalUUID($0.uuid) == writeID && $0.canWrite }),
                   service.characteristics.contains(where: { canonicalUUID($0.uuid) == notifyID && $0.canNotify }) {
                    result.append(.init(endpoint: .init(peripheralID: peripheralID, serviceUUID: serviceID,
                        writeCharacteristicUUID: writeID, notifyCharacteristicUUID: notifyID), recognition: recognition))
                }
                continue
            }
            // Standard services (including HID, health and DFU) are not serial.
            // Exclude Nordic's legacy 128-bit DFU control service as well.
            guard !serviceID.hasSuffix(baseSuffix),
                  serviceID != "00001530-1212-EFDE-1523-785FEABCD123" else { continue }
            let writes = service.characteristics.filter(\.canWrite)
            let notifications = service.characteristics.filter(\.canNotify)
            for write in writes {
                for notify in notifications {
                    guard result.count < 32 else { throw BluetoothSerialError.discoveryLimit }
                    result.append(.init(endpoint: .init(peripheralID: peripheralID, serviceUUID: serviceID,
                        writeCharacteristicUUID: canonicalUUID(write.uuid)!,
                        notifyCharacteristicUUID: canonicalUUID(notify.uuid)!), recognition: .unverified))
                }
            }
        }
        return result.sorted { $0.id < $1.id }
    }

    public static func automaticEndpoint(from channels: [BluetoothSerialChannel]) throws -> BluetoothSerialEndpoint {
        let recognized = channels.filter { $0.recognition != .unverified }
        if recognized.count == 1 { return recognized[0].endpoint }
        guard !channels.isEmpty else { throw BluetoothSerialError.noSerialChannel }
        // One unidentified write/notify pair is still not proof of a UART.
        // It is shown for explicit selection instead of sending probe bytes.
        throw BluetoothSerialError.channelSelectionRequired(recognized.isEmpty ? channels : recognized)
    }
}

public struct BluetoothSerialOpenedSession: Sendable {
    public let sessionID: UUID
    public let endpoint: BluetoothSerialEndpoint
}

/// UI and the existing bluetooth.serial.open tool share this path. The selected
/// peripheral and resolved endpoint are immutable for this run; no payload is sent.
@MainActor public enum BluetoothSerialConnector {
    public static func open(service: any BluetoothSerialServicing, runID: UUID, peripheralID: UUID,
                            endpoint explicit: BluetoothSerialEndpoint? = nil,
                            timeout: TimeInterval = 15) async throws -> BluetoothSerialOpenedSession {
        try Task.checkCancellation()
        let endpoint: BluetoothSerialEndpoint
        if let explicit {
            guard explicit.peripheralID == peripheralID else { throw BluetoothSerialError.peripheralMismatch }
            try explicit.validate()
            endpoint = explicit
        } else {
            let channels = try await service.discoverChannels(runID: runID, peripheralID: peripheralID, timeout: timeout)
            try Task.checkCancellation()
            endpoint = try BluetoothSerialDiscovery.automaticEndpoint(from: channels)
            guard endpoint.peripheralID == peripheralID else { throw BluetoothSerialError.peripheralMismatch }
        }
        try Task.checkCancellation()
        let sessionID = try await service.open(runID: runID, endpoint: endpoint, timeout: timeout)
        if Task.isCancelled {
            await service.close(runID: runID, sessionID: sessionID)
            throw CancellationError()
        }
        return .init(sessionID: sessionID, endpoint: endpoint)
    }
}

/// The native request uses this gate before creating any public session ID.
/// Notification failure/cancellation never advances the request to ready.
struct BluetoothSerialOpenReadiness {
    enum Phase { case discovering, awaitingNotification, ready, cancelled }
    private(set) var phase: Phase = .discovering
    mutating func discovered(requiresNotification: Bool) throws {
        guard phase == .discovering else { throw BluetoothSerialError.notificationNotReady }
        phase = requiresNotification ? .awaitingNotification : .ready
    }
    mutating func subscribed(isNotifying: Bool, error: Error?) throws {
        if phase == .cancelled { throw CancellationError() }
        guard phase == .awaitingNotification else { throw BluetoothSerialError.notificationNotReady }
        if let error { throw BluetoothSerialError.from(error) }
        guard isNotifying else { throw BluetoothSerialError.notificationNotReady }
        phase = .ready
    }
    mutating func cancel() { phase = .cancelled }
}
