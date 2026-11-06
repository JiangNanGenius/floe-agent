import Foundation

public enum ToolboxError: Error, Equatable, Sendable {
    case invalid(String), truncated(String), unsupported(String), limit(String)
    case staleSession, denied, revisionConflict, corruptStore
}

/// Endpoint types are not a capability registry. The host exposes only adapters it actually provides.
public enum SerialTransport: String, Codable, Sendable, CaseIterable {
    case tcp, udp, bluetooth, webSocket, usb
}
public enum SerialProtocol: String, Codable, Sendable, CaseIterable {
    case raw, modbusTCP, modbusRTU, mqtt311, mqtt5, webSocketMessage
}
public struct SerialEndpoint: Codable, Equatable, Sendable {
    public var title: String
    public var transport: SerialTransport
    public var wireProtocol: SerialProtocol
    public var host: String?
    public var port: Int?
    public var peripheralID: UUID?
    public var serviceUUID: String?
    public var writeCharacteristicUUID: String?
    public var notifyCharacteristicUUID: String?
    public var usbVendorID: UInt16?
    public var usbProductID: UInt16?

    public init(title: String, transport: SerialTransport, wireProtocol: SerialProtocol = .raw,
                host: String? = nil, port: Int? = nil, peripheralID: UUID? = nil,
                serviceUUID: String? = nil, writeCharacteristicUUID: String? = nil,
                notifyCharacteristicUUID: String? = nil, usbVendorID: UInt16? = nil, usbProductID: UInt16? = nil) throws {
        self.title = title; self.transport = transport; self.wireProtocol = wireProtocol
        self.host = host; self.port = port; self.peripheralID = peripheralID
        self.serviceUUID = serviceUUID; self.writeCharacteristicUUID = writeCharacteristicUUID
        self.notifyCharacteristicUUID = notifyCharacteristicUUID
        self.usbVendorID = usbVendorID; self.usbProductID = usbProductID
        try validate()
    }

    public func validate() throws {
        guard !title.isEmpty, title.utf8.count <= 256 else { throw ToolboxError.invalid("title") }
        if transport == .usb {
            guard usbVendorID != nil, usbProductID != nil else { throw ToolboxError.invalid("USB identity") }
        } else if transport == .bluetooth {
            guard peripheralID != nil, Self.isGATTUUID(serviceUUID), Self.isGATTUUID(writeCharacteristicUUID),
                  notifyCharacteristicUUID == nil || Self.isGATTUUID(notifyCharacteristicUUID) else {
                throw ToolboxError.invalid("BLE endpoint")
            }
        } else if transport == .webSocket {
            guard let host, host.utf8.count <= 4096, let url = URL(string: host), ["ws", "wss"].contains(url.scheme),
                  url.host != nil, url.user == nil, url.password == nil else { throw ToolboxError.invalid("WebSocket URL") }
        } else {
            guard let host, !host.isEmpty, host.utf8.count <= 253,
                  !host.contains(where: { "@/\\?#".contains($0) }),
                  !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
                  let port, (1...65535).contains(port) else { throw ToolboxError.invalid("host or port") }
        }
    }
    /// Keep connection credentials and URL paths/queries out of model metadata.
    func analysisTarget(redactor: CaptureRedactor) -> Self {
        var copy = self
        copy.title = redactor.sanitizeText(title)
        if transport == .webSocket, let host, var url = URLComponents(string: host) {
            url.user = nil; url.password = nil; url.path = ""; url.query = nil; url.fragment = nil
            copy.host = url.string.map { redactor.sanitizeText($0) }
        } else { copy.host = host.map { redactor.sanitizeText($0) } }
        return copy
    }
    private static func isGATTUUID(_ text: String?) -> Bool {
        guard let text else { return false }
        if [4, 8].contains(text.count) { return text.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) } }
        return text.count == 36 && UUID(uuidString: text) != nil
    }
}

public struct SessionLease: Codable, Hashable, Sendable {
    public let ownerID: UUID
    public let sessionID: UUID
    public let generation: UUID
    public init(ownerID: UUID, sessionID: UUID = UUID(), generation: UUID = UUID()) {
        self.ownerID = ownerID; self.sessionID = sessionID; self.generation = generation
    }
}
public enum CaptureDirection: String, Codable, Sendable { case sent, received, observation }
public enum CaptureLayer: String, Codable, Sendable { case applicationBytes, webSocketMessage, networkPacket }
public enum CaptureOrigin: String, Codable, Sendable { case liveSession, pcap, pcapng }
public struct CaptureRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sequence: UInt64
    public let timestamp: Date?
    public let direction: CaptureDirection
    public let layer: CaptureLayer
    public let origin: CaptureOrigin
    public let bytes: Data
    public let originalByteCount: Int
    public let redacted: Bool
    public let notes: [String]
    public var truncated: Bool { bytes.count < originalByteCount }
    public init(id: UUID = UUID(), sequence: UInt64, timestamp: Date? = Date(), direction: CaptureDirection,
                layer: CaptureLayer, origin: CaptureOrigin = .liveSession, bytes: Data,
                originalByteCount: Int? = nil, redacted: Bool = false, notes: [String] = []) {
        self.id = id; self.sequence = sequence; self.timestamp = timestamp; self.direction = direction
        self.layer = layer; self.origin = origin; self.bytes = bytes
        self.originalByteCount = originalByteCount ?? bytes.count; self.redacted = redacted; self.notes = notes
    }
}
public struct CaptureLimits: Codable, Equatable, Sendable {
    public let maximumRecords: Int
    public let maximumBytes: Int
    public let maximumRecordBytes: Int
    public init(maximumRecords: Int = 10_000, maximumBytes: Int = 8 * 1_024 * 1_024,
                maximumRecordBytes: Int = 256 * 1_024) throws {
        guard (1...100_000).contains(maximumRecords), (1...64 * 1_024 * 1_024).contains(maximumBytes),
              (1...1_024 * 1_024).contains(maximumRecordBytes) else { throw ToolboxError.invalid("capture limits") }
        self.maximumRecords = maximumRecords; self.maximumBytes = maximumBytes
        self.maximumRecordBytes = min(maximumRecordBytes, maximumBytes)
    }
}
public struct CaptureState: Codable, Equatable, Sendable {
    public var version = 1
    public let captureID: UUID
    public let ownerID: UUID
    public var revision: UInt64 = 0
    public var nextSequence: UInt64 = 1
    public var droppedRecords: UInt64 = 0
    public var records: [CaptureRecord] = []
    public init(captureID: UUID = UUID(), ownerID: UUID) { self.captureID = captureID; self.ownerID = ownerID }
    public var retainedBytes: Int { records.reduce(0) { $0 + $1.bytes.count } }
}

public struct ProtocolReport: Codable, Equatable, Sendable {
    public let name: String
    public let summary: String
    public var fields: [String: String]
    public var warnings: [String]
    public init(name: String, summary: String, fields: [String: String] = [:], warnings: [String] = []) {
        self.name = name; self.summary = summary; self.fields = fields; self.warnings = warnings
    }
}

struct ByteReader {
    let bytes: [UInt8]
    var offset = 0
    init(_ data: Data) { bytes = Array(data) }
    var remaining: Int { bytes.count - offset }
    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else { throw ToolboxError.truncated("bytes") }
        defer { offset += count }; return Array(bytes[offset..<offset+count])
    }
    mutating func u8() throws -> UInt8 { try take(1)[0] }
    mutating func u16(little: Bool = false) throws -> UInt16 {
        let b = try take(2); return little ? UInt16(b[0]) | UInt16(b[1]) << 8 : UInt16(b[0]) << 8 | UInt16(b[1])
    }
    mutating func u32(little: Bool = false) throws -> UInt32 {
        let b = try take(4); return little ? b.enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) } : b.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
