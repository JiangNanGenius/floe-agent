// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import FloeExecution
import FloeToolboxCore
import FloeToolboxClients
import FloeToolboxDiagnostics
import FloeToolboxWorkbenches

/// A whitelist of reusable input; never credentials, payloads or implicit execution.
/// A BLE channel is retained only after a real connection succeeds.
nonisolated struct ToolboxHistoryConfiguration: Codable, Equatable, Sendable {
    let toolName: String
    var target = ""
    var port = ""
    var ports = ""
    var recordType: UInt16 = 1
    var serviceType = ""
    var interval: Double = 1
    var useTLS = false
    var serial = SerialAssistantConfiguration()
    var bluetooth: BluetoothSerialEndpoint?
    var mqttVersion: UInt8 = 5
    var usbBaud = "115200"
    var usbDataBits: UInt8 = 8
    var usbStopBits: UInt8 = 1
    var usbParity: UInt8 = 0
    var tool: ToolboxTool? { ToolboxTool(rawValue: toolName) }

    static func diagnostic(_ request: DiagnosticRequestSnapshot) -> Self? {
        var value = Self(toolName: request.tool.rawValue)
        switch request.tool {
        case .ping, .traceroute, .dns, .port:
            guard let host = host(request.target) else { return nil }; value.target = host
            if request.tool == .dns { value.recordType = request.recordType.rawValue }
            if request.tool == .port {
                let pieces = request.ports.split(whereSeparator: { $0 == "," || $0.isWhitespace })
                let parsed = pieces.compactMap { UInt16($0) }.filter { $0 > 0 }
                guard !parsed.isEmpty, parsed.count == pieces.count, parsed.count <= 128 else { return nil }
                value.ports = parsed.map(String.init).joined(separator: ", ")
            }
        case .lan:
            let service = request.serviceType.trimmingCharacters(in: .whitespacesAndNewlines)
            guard service.utf8.count <= 128, !service.isEmpty,
                  service.utf8.allSatisfy({ allowedHostByte($0) || $0 == 95 }) else { return nil }
            value.serviceType = service
        default: return nil
        }
        return value
    }
    static func roaming(target: String, interval: Double) -> Self? {
        guard let host = host(target), interval.isFinite, (0.2...60).contains(interval) else { return nil }
        var value = Self(toolName: ToolboxTool.roaming.rawValue)
        value.target = host; value.interval = interval; return value
    }
    static func connection(tool: ToolboxTool, setup: ToolboxConnectionSetup) -> Self? {
        var value = Self(toolName: tool.rawValue)
        switch tool {
        case .http, .webSocket:
            guard let origin = origin(setup.address, schemes: tool == .http ? ["http", "https"] : ["ws", "wss"]) else { return nil }
            // Paths may contain API keys too. Only retain the server origin.
            value.target = origin
        case .mqtt:
            guard let host = host(setup.address), let port = UInt16(setup.port), port > 0 else { return nil }
            value.target = host; value.port = String(port); value.useTLS = setup.useTLS
            value.mqttVersion = setup.mqttVersion.rawValue
        case .serialAssistant:
            value.serial = setup.serial
            switch setup.serial.connection {
            case .tcp, .udp:
                guard let host = host(setup.address), let port = UInt16(setup.port), port > 0 else { return nil }
                value.target = host; value.port = String(port)
                value.useTLS = setup.serial.connection == .tcp && setup.useTLS
            case .bluetooth:
                if let endpoint = setup.bluetooth {
                    guard (try? endpoint.validate()) != nil,
                          setup.bluetoothPeripheralID == nil || setup.bluetoothPeripheralID == endpoint.peripheralID else { return nil }
                    value.bluetooth = endpoint
                }
            case .usb:
                guard (try? setup.usbSettings()) != nil else { return nil }
                value.usbBaud = setup.usbBaud; value.usbDataBits = setup.usbDataBits
                value.usbStopBits = setup.usbStopBits; value.usbParity = setup.usbParity
            }
        default: return nil
        }
        return value
    }
    func connectionSetup() -> ToolboxConnectionSetup? {
        guard let tool, [.http, .webSocket, .mqtt, .serialAssistant].contains(tool) else { return nil }
        var setup = ToolboxConnectionSetup()
        setup.address = target; setup.port = port; setup.useTLS = useTLS
        setup.serial = serial; setup.mqttVersion = MQTTVersion(rawValue: mqttVersion) ?? .v5
        setup.usbBaud = usbBaud; setup.usbDataBits = usbDataBits
        setup.usbStopBits = usbStopBits; setup.usbParity = usbParity
        setup.bluetooth = bluetooth
        setup.bluetoothPeripheralID = bluetooth?.peripheralID
        // Filling the form never connects; the user must press Connect.
        // No username, password, payload or USB request is restored.
        return setup
    }
    @MainActor func apply(to model: DiagnosticWorkbenchModel) {
        guard model.tool.rawValue == toolName, !model.running else { return }
        model.target = target; model.ports = ports
        model.recordType = DNSRecordType(rawValue: recordType) ?? .a
        model.serviceType = serviceType
    }
    var label: String {
        if tool == .lan { return serviceType }
        if tool == .serialAssistant {
            let transport = serial.connection.rawValue.uppercased()
            if serial.connection == .usb {
                let parity = usbParity == 0 ? "N" : usbParity == 1 ? "O" : "E"
                return "USB · \(usbBaud) · \(usbDataBits)\(parity)\(usbStopBits)"
            }
            if serial.connection == .bluetooth { return "Bluetooth · \(serial.protocolType.rawValue)" }
            return "\(transport) · \(target):\(port)"
        }
        if tool == .dns { return "\(DNSRecordType(rawValue: recordType).map { String(describing: $0).uppercased() } ?? "DNS") · \(target)" }
        if tool == .port { return "\(target) · \(ports)" }
        return port.isEmpty ? target : "\(target):\(port)"
    }
    /// The same whitelist also validates disk input. Old or malformed data is never executed.
    var isValid: Bool {
        guard let tool else { return false }
        if tool == .roaming { return Self.roaming(target: target, interval: interval) == self }
        if let setup = connectionSetup() { return Self.connection(tool: tool, setup: setup) == self }
        let request = DiagnosticRequestSnapshot(id: UUID(), tool: tool, target: target, ports: ports,
            recordType: DNSRecordType(rawValue: recordType) ?? .a, serviceType: serviceType)
        return Self.diagnostic(request) == self
    }
    private static func host(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 253, value.utf8.allSatisfy(allowedHostByte) else { return nil }
        return value
    }
    private static func allowedHostByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || byte == 45 || byte == 46 || byte == 58 || byte == 91 || byte == 93
    }
    private static func origin(_ text: String, schemes: Set<String>) -> String? {
        guard let input = URLComponents(string: text), let scheme = input.scheme?.lowercased(),
              schemes.contains(scheme), let name = input.host, host(name) != nil,
              input.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        var result = URLComponents(); result.scheme = scheme; result.host = name; result.port = input.port
        return result.string
    }
}

nonisolated struct ToolboxHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case started, ready, completed, failed, cancelled, interrupted }
    let id: UUID
    var configuration: ToolboxHistoryConfiguration
    var attemptID: UUID
    var usedAt: Date
    var outcome: Outcome
    var pinned = false
    var uses = 1
}

/// The owner is independent of page lifetime. Records never cause execution on load.
@MainActor final class ToolboxHistoryStore: ObservableObject {
    static let shared = ToolboxHistoryStore()
    static let maximumPerTool = 32
    @Published private(set) var entries: [ToolboxHistoryEntry] = []
    @Published private(set) var persistenceFailed = false
    private let fileURL: URL?
    private var readable = true
    private nonisolated struct Archive: Codable { let version: Int; var entries: [ToolboxHistoryEntry] }
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? (try? PersonalContentLibrary.applicationRoot().deletingLastPathComponent()
            .appendingPathComponent("Toolbox/History/recent.json"))
        guard let fileURL = self.fileURL else { persistenceFailed = true; readable = false; return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 512 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
            guard archive.version == 1, archive.entries.count <= ToolboxTool.allCases.count * Self.maximumPerTool,
                  archive.entries.allSatisfy({ $0.configuration.isValid }),
                  Set(archive.entries.map(\.id)).count == archive.entries.count,
                  ToolboxTool.allCases.allSatisfy({ tool in
                      let matching = archive.entries.filter { $0.configuration.tool == tool }
                      return matching.count <= Self.maximumPerTool && matching.filter(\.pinned).count <= 8
                  }), archive.entries.allSatisfy({ (1...1_000_000).contains($0.uses) }) else { throw CocoaError(.fileReadCorruptFile) }
            entries = archive.entries.map { entry in
                var entry = entry
                if entry.outcome == .started { entry.outcome = .interrupted }
                return entry
            }
        } catch { persistenceFailed = true; readable = false } // Preserve the damaged file for recovery.
    }
    func records(for tool: ToolboxTool) -> [ToolboxHistoryEntry] {
        entries.filter { $0.configuration.tool == tool }.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.usedAt > $1.usedAt
        }
    }
    @discardableResult func begin(_ configuration: ToolboxHistoryConfiguration?, attemptID: UUID = UUID(), now: Date = Date()) -> UUID? {
        guard let configuration, configuration.isValid else { return nil }
        if let index = entries.firstIndex(where: { $0.configuration == configuration }) {
            entries[index].attemptID = attemptID; entries[index].usedAt = now
            entries[index].outcome = .started; entries[index].uses = min(1_000_000, entries[index].uses + 1)
        } else {
            entries.append(.init(id: UUID(), configuration: configuration, attemptID: attemptID, usedAt: now, outcome: .started))
        }
        if let tool = configuration.tool {
            let overflow = records(for: tool).dropFirst(Self.maximumPerTool).map(\.id)
            entries.removeAll { overflow.contains($0.id) }
        }
        save(); return attemptID
    }
    func finish(_ attemptID: UUID?, outcome: ToolboxHistoryEntry.Outcome, resolvedBluetooth: BluetoothSerialEndpoint? = nil) {
        guard let attemptID, outcome != .started,
              let index = entries.firstIndex(where: { $0.attemptID == attemptID && $0.outcome == .started }) else { return }
        if outcome == .ready, let resolvedBluetooth,
           entries[index].configuration.tool == .serialAssistant,
           entries[index].configuration.serial.connection == .bluetooth,
           (try? resolvedBluetooth.validate()) != nil {
            entries[index].configuration.bluetooth = resolvedBluetooth
        }
        entries[index].outcome = outcome; save()
    }
    func togglePin(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), let tool = entries[index].configuration.tool else { return }
        // Keep room for recent entries even when some favorites are pinned.
        if !entries[index].pinned, records(for: tool).filter(\.pinned).count >= 8 { return }
        entries[index].pinned.toggle(); save()
    }
    func delete(_ id: UUID) { entries.removeAll { $0.id == id }; save() }
    func clear(_ tool: ToolboxTool) { entries.removeAll { $0.configuration.tool == tool }; save() }
    private func save() {
        guard readable, let fileURL else { persistenceFailed = true; return }
        do {
            let bytes = try JSONEncoder().encode(Archive(version: 1, entries: entries))
            guard bytes.count <= 512 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try bytes.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            persistenceFailed = false
        } catch { persistenceFailed = true }
    }
}
#endif
