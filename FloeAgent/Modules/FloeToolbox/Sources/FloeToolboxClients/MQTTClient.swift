import Foundation
import FloeToolboxCore

public enum MQTTVersion: UInt8, Sendable, Codable { case v311 = 4, v5 = 5 }
public enum MQTTQoS: UInt8, Sendable, Codable { case atMostOnce = 0, atLeastOnce = 1, exactlyOnce = 2 }
public struct MQTTConfiguration: Sendable {
    public let version: MQTTVersion
    public let clientID: String
    public let keepAlive: UInt16
    public let maximumPacketBytes: Int
    public let maximumEvents: Int
    public let maximumEventBytes: Int
    public init(version: MQTTVersion = .v5, clientID: String, keepAlive: UInt16 = 30,
                maximumPacketBytes: Int = 256*1024, maximumEvents: Int = 500, maximumEventBytes: Int = 2*1024*1024) throws {
        _ = try MQTTWire.string(clientID)
        guard !clientID.isEmpty, clientID.utf8.count <= 256, (128...1024*1024).contains(maximumPacketBytes),
              (1...10000).contains(maximumEvents), (1024...16*1024*1024).contains(maximumEventBytes) else { throw ClientError.invalidConfiguration }
        self.version = version; self.clientID = clientID; self.keepAlive = keepAlive
        self.maximumPacketBytes = maximumPacketBytes; self.maximumEvents = maximumEvents; self.maximumEventBytes = maximumEventBytes
    }
}
public struct MQTTMessage: Equatable, Sendable {
    public let topic: String
    public let payload: Data
    public let qos: MQTTQoS
    public let retained: Bool
    public let duplicate: Bool
}
public enum MQTTClientFailure: Error, Equatable, Sendable { case rejected(UInt8), disconnected(UInt8), malformed, overflow, notConnected }

/// Turns an ordered stream into whole MQTT packets before capture/redaction. A fragmented
/// CONNECT/AUTH must never expose a later credential fragment as an unrelated raw packet.
public actor MQTTFramedConnection: SerialConnection {
    private let stream: any SerialConnection
    private let maximum: Int
    private var buffer = Data()
    private var reading = false
    private var closed = false
    public init(stream: any SerialConnection, maximumPacketBytes: Int = 256*1024) throws {
        guard (128...1024*1024).contains(maximumPacketBytes) else { throw ClientError.invalidConfiguration }
        self.stream = stream; maximum = maximumPacketBytes
    }
    public func send(_ bytes: Data) async throws {
        guard !closed else { throw ClientError.closed }
        guard let size = try MQTTWire.packetLength(bytes), size == bytes.count, size <= maximum else { throw MQTTClientFailure.malformed }
        try await stream.send(bytes)
    }
    public func receive(maximumBytes: Int) async throws -> Data {
        guard !closed, !reading else { throw ClientError.busy }
        reading = true; defer { reading = false }
        do {
            while true {
                if let length = try MQTTWire.packetLength(buffer) {
                    guard length <= min(maximum,maximumBytes) else { throw ClientError.tooLarge }
                    if buffer.count >= length { let packet = Data(buffer.prefix(length)); buffer.removeFirst(length); return packet }
                }
                let piece = try await stream.receive(maximumBytes:min(65536,maximum))
                guard !closed, !piece.isEmpty, buffer.count+piece.count <= maximum+65536 else { throw ClientError.tooLarge }
                buffer.append(piece)
            }
        } catch { await close(); throw error }
    }
    public func close() async { closed = true; buffer.removeAll(); await stream.close() }
}

enum MQTTWire {
    static func variable(_ value: Int) throws -> Data {
        guard (0...268435455).contains(value) else { throw MQTTClientFailure.malformed }
        var n = value, result = Data()
        repeat { var byte = UInt8(n%128); n /= 128; if n > 0 { byte |= 128 }; result.append(byte) } while n > 0
        return result
    }
    static func packetLength(_ bytes: Data) throws -> Int? {
        guard bytes.count >= 2 else { return nil }
        var value = 0, multiplier = 1
        for offset in 1...4 {
            guard offset < bytes.count else { return nil }
            let byte = bytes[bytes.startIndex+offset]; value += Int(byte&127)*multiplier
            if byte&128 == 0 {
                guard offset == 1 || byte != 0 else { throw MQTTClientFailure.malformed }
                return offset+1+value
            }
            multiplier *= 128
        }
        throw MQTTClientFailure.malformed
    }
    static func packet(_ header: UInt8, _ body: Data = Data()) throws -> Data { Data([header]) + (try variable(body.count)) + body }
    static func integer(_ value: UInt16) -> Data { Data([UInt8(value>>8),UInt8(value&255)]) }
    static func string(_ text: String) throws -> Data {
        let bytes = Data(text.utf8)
        guard bytes.count <= 65535, !text.unicodeScalars.contains(where:{ $0.value == 0 || (0xD800...0xDFFF).contains($0.value) || (0xFDD0...0xFDEF).contains($0.value) || $0.value&0xFFFF == 0xFFFE || $0.value&0xFFFF == 0xFFFF }) else { throw MQTTClientFailure.malformed }
        return integer(UInt16(bytes.count))+bytes
    }
    struct Reader {
        let bytes: [UInt8]; var offset = 0
        init(_ bytes: Data) { self.bytes = Array(bytes) }
        mutating func byte() throws -> UInt8 { guard offset < bytes.count else { throw MQTTClientFailure.malformed }; defer { offset += 1 }; return bytes[offset] }
        mutating func integer() throws -> UInt16 { let high = try byte(); return UInt16(high)<<8 | UInt16(try byte()) }
        mutating func variable() throws -> Int {
            var value = 0, multiplier = 1
            for index in 0..<4 { let b = try byte(); value += Int(b&127)*multiplier; if b&128 == 0 { guard index == 0 || b != 0 else { throw MQTTClientFailure.malformed }; return value }; multiplier *= 128 }
            throw MQTTClientFailure.malformed
        }
        mutating func data(_ length: Int) throws -> Data { guard length >= 0, offset+length <= bytes.count else { throw MQTTClientFailure.malformed }; defer { offset += length }; return Data(bytes[offset..<offset+length]) }
        mutating func string() throws -> String { let size = try integer(); guard let value = String(data:try data(Int(size)),encoding:.utf8) else { throw MQTTClientFailure.malformed }; _ = try MQTTWire.string(value); return value }
        mutating func properties() throws -> [UInt8:UInt32] {
            let length = try variable(), end = offset+length
            guard end <= bytes.count else { throw MQTTClientFailure.malformed }
            var values: [UInt8:UInt32] = [:]
            while offset < end {
                let property = try variable(); guard property <= 255 else { throw MQTTClientFailure.malformed }
                let key = UInt8(property)
                if values[key] != nil { throw MQTTClientFailure.malformed }
                switch key {
                case 0x01,0x17,0x19,0x24,0x25,0x28,0x29,0x2A: values[key] = UInt32(try byte())
                case 0x13,0x21,0x22,0x23: values[key] = UInt32(try integer())
                case 0x02,0x11,0x18,0x27: values[key] = UInt32(try integer())<<16 | UInt32(try integer())
                case 0x0B: _ = try variable()
                case 0x03,0x08,0x12,0x15,0x1A,0x1C,0x1F: _ = try string()
                case 0x09,0x16: let size = try integer(); _ = try data(Int(size))
                case 0x26: _ = try string(); _ = try string()
                default: throw MQTTClientFailure.malformed
                }
                guard offset <= end else { throw MQTTClientFailure.malformed }
            }
            return values
        }
        var atEnd: Bool { offset == bytes.count }
    }
}

private actor MQTTWriter {
    private struct Item: Sendable { let packet: Data; let gate: ClientCompletion<Void> }
    private let session: SerialSession
    private var queue: [Item] = []
    private var queuedBytes = 0
    private var draining = false
    private var closed = false
    init(_ session: SerialSession) { self.session = session }
    func send(_ packet: Data) async throws {
        guard !closed, queue.count < 64, queuedBytes+packet.count <= 2*1024*1024 else { throw MQTTClientFailure.overflow }
        let gate = ClientCompletion<Void>(); queue.append(Item(packet:packet,gate:gate)); queuedBytes += packet.count
        if !draining { draining = true; Task { await self.drain() } }
        try await gate.wait(seconds:30)
    }
    private func drain() async {
        while !queue.isEmpty, !closed {
            let item = queue.removeFirst(); queuedBytes -= item.packet.count
            guard item.gate.isPending else { continue }
            do { try await session.send(item.packet,expected:session.lease); item.gate.finish(.success(())) }
            catch { item.gate.finish(.failure(error)) }
        }
        draining = false
    }
    func close() { closed = true; for item in queue { item.gate.finish(.failure(ClientError.closed)) }; queue.removeAll(); queuedBytes = 0 }
}

/// A clean-session debugging client. Reconnect creates a fresh lease/client and subscriptions;
/// unacknowledged publishes are reported as uncertain and are never automatically replayed.
public actor MQTTClient {
    private enum Phase { case connect, subscribe, unsubscribe, puback, pubrec, pubcomp }
    private struct Pending { var phase: Phase; let gate: ClientCompletion<[UInt8]> }
    public nonisolated let configuration: MQTTConfiguration
    public nonisolated let session: SerialSession
    private let writer: MQTTWriter
    private var pending: [UInt16:Pending] = [:]
    private var nextID: UInt16 = 1
    private var receiver: Task<Void,Never>?
    private var timer: Task<Void,Never>?
    private var connected = false
    private var closed = false
    private var events: [MQTTMessage] = []
    private var eventBytes = 0
    private var dropped: UInt64 = 0
    private var inboundQoS2: [UInt16:MQTTMessage] = [:]
    private var inboundBytes = 0
    private var serverMaximumPacket = 1024*1024
    private var serverMaximumQoS: UInt8 = 2
    private var serverReceiveMaximum = 64
    private var serverRetainAvailable = true
    private var effectiveKeepAlive: UInt16
    private let clock = ContinuousClock()
    private var lastSent: ContinuousClock.Instant
    private var pingSent: ContinuousClock.Instant?
    public init(configuration: MQTTConfiguration, session: SerialSession) throws {
        guard [.mqtt311,.mqtt5].contains(session.endpoint.wireProtocol), session.endpoint.transport == .tcp else { throw ClientError.invalidConfiguration }
        self.configuration = configuration; self.session = session; writer = MQTTWriter(session)
        effectiveKeepAlive = configuration.keepAlive; lastSent = clock.now
    }
    public func connect(username: String? = nil, password: Data? = nil, timeout: TimeInterval = 15) async throws {
        guard receiver == nil, !closed else { throw ClientError.busy }
        guard password == nil || username != nil, (password?.count ?? 0) <= 65535 else { throw ClientError.invalidConfiguration }
        var flags: UInt8 = 2
        if username != nil { flags |= 128 }; if password != nil { flags |= 64 }
        var body = try MQTTWire.string("MQTT") + Data([configuration.version.rawValue,flags]) + MQTTWire.integer(configuration.keepAlive)
        if configuration.version == .v5 {
            body += Data([8,0x21,0,64,0x27]) + Data([UInt8(configuration.maximumPacketBytes>>24),UInt8((configuration.maximumPacketBytes>>16)&255),UInt8((configuration.maximumPacketBytes>>8)&255),UInt8(configuration.maximumPacketBytes&255)])
        }
        body += try MQTTWire.string(configuration.clientID)
        if let username { body += try MQTTWire.string(username) }
        if let password { body += MQTTWire.integer(UInt16(password.count))+password }
        let gate = ClientCompletion<[UInt8]>(); pending[0] = Pending(phase:.connect,gate:gate)
        receiver = Task { await self.readLoop() }
        do {
            try await send(try MQTTWire.packet(0x10,body))
            _ = try await gate.wait(seconds:timeout); pending.removeValue(forKey:0)
            guard !closed else { throw ClientError.closed }; connected = true
            if effectiveKeepAlive > 0 { timer = Task { await self.keepAliveLoop() } }
        } catch { await fail(error); throw error }
    }
    public func subscribe(_ filter: String, qos: MQTTQoS = .atMostOnce, timeout: TimeInterval = 15) async throws -> UInt8 {
        try Self.validateFilter(filter)
        let id = try reserve(.subscribe)
        guard let gate = pending[id]?.gate else { throw MQTTClientFailure.malformed }
        defer { pending.removeValue(forKey:id) }
        var body = MQTTWire.integer(id); if configuration.version == .v5 { body.append(0) }
        body += try MQTTWire.string(filter); body.append(qos.rawValue)
        try await send(try MQTTWire.packet(0x82,body)); let codes = try await gate.wait(seconds:timeout)
        let code = try requireCode(codes); guard code <= 2 else { throw MQTTClientFailure.rejected(code) }; return code
    }
    public func unsubscribe(_ filter: String, timeout: TimeInterval = 15) async throws {
        try Self.validateFilter(filter)
        let id = try reserve(.unsubscribe)
        guard let gate = pending[id]?.gate else { throw MQTTClientFailure.malformed }
        defer { pending.removeValue(forKey:id) }
        var body = MQTTWire.integer(id); if configuration.version == .v5 { body.append(0) }; body += try MQTTWire.string(filter)
        try await send(try MQTTWire.packet(0xA2,body)); let codes = try await gate.wait(seconds:timeout)
        if let code = codes.first, code >= 128 { throw MQTTClientFailure.rejected(code) }
    }
    public func publish(topic: String, payload: Data, qos: MQTTQoS = .atMostOnce, retained: Bool = false,
                        timeout: TimeInterval = 15) async throws {
        guard connected, !closed else { throw MQTTClientFailure.notConnected }
        guard !topic.isEmpty, !topic.contains("+"), !topic.contains("#"), qos.rawValue <= serverMaximumQoS,
              !retained || serverRetainAvailable else { throw ClientError.invalidConfiguration }
        var body = try MQTTWire.string(topic)
        let id: UInt16? = qos == .atMostOnce ? nil : try reserve(qos == .atLeastOnce ? .puback : .pubrec)
        defer { if let id { pending.removeValue(forKey:id) } }
        if let id { body += MQTTWire.integer(id) }; if configuration.version == .v5 { body.append(0) }; body += payload
        let gate = id.flatMap { pending[$0]?.gate }
        try await send(try MQTTWire.packet(0x30 | qos.rawValue<<1 | (retained ? 1 : 0),body))
        if let gate { let codes = try await gate.wait(seconds:timeout); if let code = codes.first, code >= 128 { throw MQTTClientFailure.rejected(code) } }
    }
    public func drainMessages() -> (messages:[MQTTMessage], dropped:UInt64) {
        let result = events; events.removeAll(); eventBytes = 0; return (result,dropped)
    }
    public func disconnect() async {
        if connected, !closed { try? await send(Data([0xE0,0])) }
        await fail(ClientError.closed)
    }
    private func requireCode(_ codes: [UInt8]) throws -> UInt8 { guard codes.count == 1, let code = codes.first else { throw MQTTClientFailure.malformed }; return code }
    private func reserve(_ phase: Phase) throws -> UInt16 {
        guard connected, !closed else { throw MQTTClientFailure.notConnected }
        guard pending.count < 64 else { throw MQTTClientFailure.overflow }
        if phase == .puback || phase == .pubrec {
            let publishes = pending.values.filter { [.puback,.pubrec,.pubcomp].contains($0.phase) }.count
            guard publishes < serverReceiveMaximum else { throw MQTTClientFailure.overflow }
        }
        for _ in 0..<65535 { let id = nextID; nextID = id == 65535 ? 1 : id+1; if pending[id] == nil { pending[id] = Pending(phase:phase,gate:ClientCompletion<[UInt8]>()); return id } }
        throw MQTTClientFailure.overflow
    }
    private func send(_ packet: Data) async throws {
        guard !closed, packet.count <= min(serverMaximumPacket,configuration.maximumPacketBytes) else { throw ClientError.tooLarge }
        try await writer.send(packet); guard !closed else { throw ClientError.closed }; lastSent = clock.now
    }
    private func readLoop() async {
        do {
            while !closed { let packet = try await session.receive(expected:session.lease); try await consume(packet) }
        } catch { if !closed { await fail(error) } }
    }
    private func consume(_ packet: Data) async throws {
        guard !closed, packet.count <= configuration.maximumPacketBytes, try MQTTWire.packetLength(packet) == packet.count else { throw MQTTClientFailure.malformed }
        var reader = MQTTWire.Reader(packet), header = try reader.byte(); _ = try reader.variable()
        let type = header>>4, flags = header&15
        guard type == 3 || flags == (type == 6 ? 2 : 0) else { throw MQTTClientFailure.malformed }
        switch type {
        case 2:
            guard !connected, let waiting = pending[0] else { throw MQTTClientFailure.malformed }
            let acknowledgeFlags = try reader.byte(), reason = try reader.byte()
            guard acknowledgeFlags == 0 else { throw MQTTClientFailure.malformed } // clean start never resumes server state
            if configuration.version == .v5 {
                let properties = try reader.properties()
                if let value = properties[0x13] { effectiveKeepAlive = UInt16(value) }
                if let value = properties[0x27] { guard value > 0 else { throw MQTTClientFailure.malformed }; serverMaximumPacket = min(Int(value),1024*1024) }
                if let value = properties[0x24] { guard value <= 1 else { throw MQTTClientFailure.malformed }; serverMaximumQoS = UInt8(value) }
                if let value = properties[0x25] { guard value <= 1 else { throw MQTTClientFailure.malformed }; serverRetainAvailable = value != 0 }
                if let value = properties[0x21] { guard value > 0 else { throw MQTTClientFailure.malformed }; serverReceiveMaximum = min(64,Int(value)) }
            }
            guard reader.atEnd else { throw MQTTClientFailure.malformed }
            waiting.gate.finish(reason == 0 ? .success([reason]) : .failure(MQTTClientFailure.rejected(reason)))
        case 3:
            guard connected, let qos = MQTTQoS(rawValue:(header>>1)&3), qos != .atMostOnce || flags&8 == 0 else { throw MQTTClientFailure.malformed }
            let topic = try reader.string(); guard !topic.isEmpty, !topic.contains("+"), !topic.contains("#") else { throw MQTTClientFailure.malformed }
            let id: UInt16? = qos == .atMostOnce ? nil : try reader.integer()
            if let id { guard id != 0 else { throw MQTTClientFailure.malformed } }
            if configuration.version == .v5 { let properties = try reader.properties(); guard properties[0x23] == nil else { throw MQTTClientFailure.malformed } }
            let message = MQTTMessage(topic:topic,payload:try reader.data(reader.bytes.count-reader.offset),qos:qos,retained:flags&1 != 0,duplicate:flags&8 != 0)
            if qos == .exactlyOnce, let id {
                if inboundQoS2[id] == nil {
                    guard inboundQoS2.count < 64, inboundBytes+message.payload.count <= configuration.maximumEventBytes else { throw MQTTClientFailure.overflow }
                    inboundQoS2[id] = message; inboundBytes += message.payload.count
                } else { guard message.duplicate else { throw MQTTClientFailure.malformed } }
                try await send(try MQTTWire.packet(0x50,MQTTWire.integer(id)))
            } else {
                append(message)
                if let id { try await send(try MQTTWire.packet(0x40,MQTTWire.integer(id))) }
            }
        case 4,5,6,7,9,11:
            let id = try reader.integer(); guard id != 0 else { throw MQTTClientFailure.malformed }
            if type == 6 {
                if configuration.version == .v5, !reader.atEnd { let reason = try reader.byte(); guard reason == 0 || reason == 0x92 else { throw MQTTClientFailure.malformed }; if !reader.atEnd { _ = try reader.properties() } }
                guard reader.atEnd else { throw MQTTClientFailure.malformed }
                if let message = inboundQoS2.removeValue(forKey:id) { inboundBytes -= message.payload.count; append(message) }
                try await send(try MQTTWire.packet(0x70,MQTTWire.integer(id))); return
            }
            var codes: [UInt8] = []
            if type == 9 || type == 11 {
                if configuration.version == .v5 { _ = try reader.properties() }
                while !reader.atEnd { codes.append(try reader.byte()) }
            } else if configuration.version == .v5, !reader.atEnd {
                codes.append(try reader.byte()); if !reader.atEnd { _ = try reader.properties() }
            }
            guard reader.atEnd, let waiting = pending[id] else { throw MQTTClientFailure.malformed }
            switch (type,waiting.phase) {
            case (4,.puback),(7,.pubcomp): waiting.gate.finish(.success(codes))
            case (9,.subscribe): _ = try requireCode(codes); waiting.gate.finish(.success(codes))
            case (11,.unsubscribe): if configuration.version == .v5 { _ = try requireCode(codes) }; waiting.gate.finish(.success(codes))
            case (5,.pubrec):
                if let reason = codes.first, reason >= 128 { waiting.gate.finish(.success(codes)) }
                else { pending[id]?.phase = .pubcomp; try await send(try MQTTWire.packet(0x62,MQTTWire.integer(id))) }
            case (5,.pubcomp): try await send(try MQTTWire.packet(0x62,MQTTWire.integer(id)))
            default: throw MQTTClientFailure.malformed
            }
        case 13:
            guard reader.atEnd, pingSent != nil else { throw MQTTClientFailure.malformed }; pingSent = nil
        case 14:
            var reason: UInt8 = 0
            if configuration.version == .v5, !reader.atEnd { reason = try reader.byte(); if !reader.atEnd { _ = try reader.properties() } }
            guard reader.atEnd else { throw MQTTClientFailure.malformed }; throw MQTTClientFailure.disconnected(reason)
        default: throw MQTTClientFailure.malformed
        }
    }
    private func append(_ message: MQTTMessage) {
        let size = message.topic.utf8.count+message.payload.count
        guard size <= configuration.maximumEventBytes else { dropped &+= 1; return }
        while events.count >= configuration.maximumEvents || eventBytes+size > configuration.maximumEventBytes {
            guard !events.isEmpty else { break }; let old = events.removeFirst(); eventBytes -= old.topic.utf8.count+old.payload.count; dropped &+= 1
        }
        events.append(message); eventBytes += size
    }
    private func keepAliveLoop() async {
        do {
            while !closed {
                try await Task.sleep(for:.seconds(max(0.1,Double(effectiveKeepAlive)/4)))
                guard !closed else { return }
                if let pingSent, pingSent.duration(to:clock.now) >= .seconds(Double(effectiveKeepAlive)) { throw ClientError.timedOut }
                if pingSent == nil, lastSent.duration(to:clock.now) >= .seconds(Double(effectiveKeepAlive)/2) {
                    pingSent = clock.now; try await send(try MQTTWire.packet(0xC0))
                }
            }
        } catch { if !closed { await fail(error) } }
    }
    private func fail(_ error: any Error) async {
        guard !closed else { return }; closed = true; connected = false
        receiver?.cancel(); timer?.cancel(); receiver = nil; timer = nil
        for item in pending.values { item.gate.finish(.failure(error)) }; pending.removeAll()
        inboundQoS2.removeAll(); inboundBytes = 0
        await writer.close(); await session.close()
    }
    private static func validateFilter(_ filter: String) throws {
        guard !filter.isEmpty else { throw ClientError.invalidConfiguration }; _ = try MQTTWire.string(filter)
        let levels = filter.split(separator:"/",omittingEmptySubsequences:false)
        for (index,level) in levels.enumerated() {
            guard !level.contains("#") || level == "#" && index == levels.count-1,
                  !level.contains("+") || level == "+" else { throw ClientError.invalidConfiguration }
        }
    }
}
