import Foundation
import FloeToolboxCore

public enum ModbusOperation: Sendable, Equatable {
    case read(function: UInt8,quantity: UInt16)
    case singleCoil(Bool),singleRegister(UInt16),coils([Bool]),registers([UInt16])
}
public struct ModbusExchangeResult: Sendable {
    public let report: ProtocolReport?
    /// RTU/ASCII address 0 is a write broadcast. No receipt or device-state claim is manufactured.
    public let broadcast: Bool
    public let request: Data
    public let response: Data?
    public let framing: ModbusFraming
    /// True only when a write response echoed the requested address and value/quantity.
    public let writeEchoVerified: Bool
}
public enum ModbusRequestBuilder {
    public static func build(unit: UInt8,address: UInt16,operation: ModbusOperation,transactionID: UInt16 = 1,rtu: Bool = false) throws -> Data {
        try build(unit:unit,address:address,operation:operation,transactionID:transactionID,framing:rtu ? .rtu : .mbap)
    }
    /// Builds one exact request. Inputs are validated against the public
    /// function limits and the selected serial/MBAP address space.
    public static func build(unit: UInt8,address: UInt16,operation: ModbusOperation,
                             transactionID: UInt16 = 1,framing: ModbusFraming) throws -> Data {
        func integer(_ value: UInt16) -> Data { Data([UInt8(value>>8),UInt8(value&255)]) }
        var pdu = Data(); let write: Bool
        switch operation {
        case .read(let function,let quantity):
            guard [1,2,3,4].contains(function), quantity > 0,
                  Int(quantity) <= (function < 3 ? 2000 : 125),
                  Int(address)+Int(quantity) <= 65536 else { throw ClientError.invalidConfiguration }
            pdu = Data([function]) + integer(address) + integer(quantity); write = false
        case .singleCoil(let value):
            pdu = Data([5]) + integer(address) + integer(value ? 0xFF00 : 0x0000); write = true
        case .singleRegister(let value):
            pdu = Data([6]) + integer(address) + integer(value); write = true
        case .coils(let values):
            guard !values.isEmpty, values.count <= 1968, Int(address)+values.count <= 65536 else { throw ClientError.invalidConfiguration }
            pdu = Data([15]) + integer(address) + integer(UInt16(values.count))
            pdu.append(UInt8((values.count+7)/8)); pdu += ModbusCodec.packCoils(values); write = true
        case .registers(let values):
            guard !values.isEmpty, values.count <= 123, Int(address)+values.count <= 65536 else { throw ClientError.invalidConfiguration }
            pdu = Data([16]) + integer(address) + integer(UInt16(values.count)) + Data([UInt8(values.count*2)])
            for value in values { pdu += integer(value) }
            write = true
        }
        do { try ModbusCodec.validate(unit:unit,framing:framing,write:write) }
        catch { throw ClientError.invalidConfiguration }
        let packet = try ModbusCodec.encode(unit:unit,pdu:pdu,framing:framing,transactionID:transactionID)
        _ = try ModbusCodec.decode(packet,framing:framing,response:false)
        return packet
    }
}

/// Single-request Modbus helper. Response assembly follows the selected
/// MBAP/RTU/ASCII format, including serial-over-TCP; UDP data is never
/// concatenated across datagrams. All requests are explicit and single.
public actor ModbusClient {
    public nonisolated let session: SerialSession
    public nonisolated let framing: ModbusFraming
    private var busy = false
    private var nextTransaction: UInt16 = 1
    public init(session: SerialSession) throws {
        guard let framing = session.endpoint.wireProtocol.modbusFraming,
              [.tcp,.udp,.bluetooth,.usb].contains(session.endpoint.transport) else { throw ClientError.invalidConfiguration }
        self.session = session; self.framing = framing
    }
    /// The bytes the next structured exchange would send, without sending.
    public func preview(unit: UInt8,address: UInt16,operation: ModbusOperation) throws -> Data {
        try ModbusRequestBuilder.build(unit:unit,address:address,operation:operation,
            transactionID:nextTransaction,framing:framing)
    }
    /// Request previews in every transport framing. A framing that cannot
    /// represent the operation (for example a serial broadcast read) is omitted.
    public func previewFrames(unit: UInt8,address: UInt16,operation: ModbusOperation) -> [ModbusFraming:Data] {
        var frames: [ModbusFraming:Data] = [:]
        for candidate in ModbusFraming.allCases {
            if let frame = try? ModbusRequestBuilder.build(unit:unit,address:address,operation:operation,
                                                           transactionID:nextTransaction,framing:candidate) {
                frames[candidate] = frame
            }
        }
        return frames
    }
    public func exchange(unit: UInt8,address: UInt16,operation: ModbusOperation,timeout: TimeInterval = 5) async throws -> ModbusExchangeResult {
        guard timeout.isFinite, (0.05...30).contains(timeout) else { throw ClientError.invalidConfiguration }
        guard !busy else { throw ClientError.busy }; busy = true; defer { busy = false }
        let transaction = nextTransaction
        nextTransaction = transaction == 65535 ? 1 : transaction+1
        let request = try ModbusRequestBuilder.build(unit:unit,address:address,operation:operation,
                                                     transactionID:transaction,framing:framing)
        let frame = try ModbusCodec.decodeFrame(request,framing:framing)
        return try await transact(request:request,frame:frame,operation:operation,timeout:timeout)
    }
    /// Sends one exact, already-framed request. The frame must decode as a
    /// request in this session's framing; response frames are rejected.
    public func exchangeFrame(_ request: Data,timeout: TimeInterval = 5) async throws -> ModbusExchangeResult {
        guard timeout.isFinite, (0.05...30).contains(timeout) else { throw ClientError.invalidConfiguration }
        guard !busy else { throw ClientError.busy }; busy = true; defer { busy = false }
        let frame = try ModbusCodec.decodeFrame(request,framing:framing)
        let report = try ModbusCodec.decode(request,framing:framing,response:false)
        let operation = try Self.operation(from:report)
        return try await transact(request:request,frame:frame,operation:operation,timeout:timeout)
    }
    private func transact(request: Data,frame: ModbusDecodedFrame,operation: ModbusOperation,timeout: TimeInterval) async throws -> ModbusExchangeResult {
        try await withThrowingTaskGroup(of: ModbusExchangeResult.self) { group in
            group.addTask { try await self.exchangeOnWire(request:request,frame:frame,operation:operation) }
            group.addTask {
                try await Task.sleep(for:.seconds(timeout))
                throw ClientError.timedOut
            }
            defer { group.cancelAll() }
            do {
                guard let result = try await group.next() else { throw ClientError.closed }
                return result
            } catch {
                group.cancelAll()
                // A transport callback can remain suspended until the actual wire is closed.
                if error as? ClientError == .timedOut || error is CancellationError {
                    await session.close()
                }
                throw error
            }
        }
    }
    private func exchangeOnWire(request: Data,frame: ModbusDecodedFrame,operation: ModbusOperation) async throws -> ModbusExchangeResult {
        let unit = frame.unit, transaction = frame.transactionID
        let requestBody = Data([unit]) + frame.pdu, requestedFunction = frame.function
        do {
            try await session.send(request,expected:session.lease)
        } catch {
            if error as? ToolboxError != .denied { await session.close() }
            throw error
        }
        if framing.isSerialLine, unit == 0 {
            return ModbusExchangeResult(report:nil,broadcast:true,request:request,response:nil,framing:framing,writeEchoVerified:false)
        }
        var buffer = Data(), discarded = 0
        do {
            while true {
                if framing == .ascii { trimASCII(&buffer) }
                if let length = try frameLength(buffer,framing:framing), buffer.count >= length {
                    let responseFrame = Data(buffer.prefix(length)); buffer.removeFirst(length)
                    let decoded: ModbusDecodedFrame
                    do { decoded = try ModbusCodec.decodeFrame(responseFrame,framing:framing) }
                    catch { throw ClientError.protocolViolation }
                    let matches: Bool = switch framing {
                    case .mbap: decoded.unit == unit && decoded.transactionID == transaction
                    case .rtu,.ascii: decoded.unit == unit
                    }
                    if matches {
                        let report: ProtocolReport
                        do { report = try ModbusCodec.decode(responseFrame,framing:framing,response:true) }
                        catch { throw ClientError.protocolViolation }
                        let echo = try validateResponse(report:report,decoded:decoded,requestBody:requestBody,
                                                        requestedFunction:requestedFunction,operation:operation)
                        return ModbusExchangeResult(report:report,broadcast:false,request:request,
                                                    response:responseFrame,framing:framing,writeEchoVerified:echo)
                    }
                    discarded += 1; guard discarded <= 4 else { throw ClientError.protocolViolation }; continue
                }
                let chunk = try await session.receive(expected:session.lease)
                guard !chunk.isEmpty, buffer.count+chunk.count <= 4096 else { throw ClientError.tooLarge }
                if session.endpoint.transport == .udp {
                    guard buffer.isEmpty, try frameLength(chunk,framing:framing) == chunk.count else { throw ClientError.protocolViolation }
                }
                buffer += chunk
            }
        } catch { await session.close(); throw error }
    }
    private func validateResponse(report: ProtocolReport,decoded: ModbusDecodedFrame,requestBody: Data,
                                  requestedFunction: UInt8,operation: ModbusOperation) throws -> Bool {
        let function = UInt8(report.fields["function"] ?? "")
        guard let function, function == requestedFunction || function == requestedFunction|0x80 else {
            throw ClientError.protocolViolation
        }
        if function & 0x80 != 0 { return false }
        let responseBody = Data([decoded.unit]) + decoded.pdu
        if [5,6,15,16].contains(function) {
            guard responseBody.prefix(6) == requestBody.prefix(6) else { throw ClientError.protocolViolation }
            return true
        }
        guard case .read(let requested, let count) = operation, requested == function else { throw ClientError.protocolViolation }
        let expected = function < 3 ? (Int(count)+7)/8 : Int(count)*2
        guard report.fields["byteCount"] == String(expected) else { throw ClientError.protocolViolation }
        if function < 3, count % 8 != 0, let last = decoded.pdu.last,
           last & (UInt8.max << UInt8(count % 8)) != 0 {
            throw ClientError.protocolViolation
        }
        return false
    }
    private static func operation(from report: ProtocolReport) throws -> ModbusOperation {
        guard let function = UInt8(report.fields["function"] ?? "") else { throw ClientError.invalidConfiguration }
        switch function {
        case 1,2,3,4:
            guard let quantity = report.fields["quantity"].flatMap(UInt16.init) else { throw ClientError.invalidConfiguration }
            return .read(function:function,quantity:quantity)
        case 5:
            guard let value = report.fields["valueOrQuantity"].flatMap(UInt16.init) else { throw ClientError.invalidConfiguration }
            return .singleCoil(value == 0xFF00)
        case 6:
            guard let value = report.fields["valueOrQuantity"].flatMap(UInt16.init) else { throw ClientError.invalidConfiguration }
            return .singleRegister(value)
        case 15:
            guard let quantity = report.fields["valueOrQuantity"].flatMap(Int.init),
                  let payload = report.fields["payloadHex"].flatMap({ try? Data(hex:$0) }) else { throw ClientError.invalidConfiguration }
            return .coils(try ModbusCodec.unpackCoils(payload,count:quantity))
        case 16:
            guard let payload = report.fields["payloadHex"].flatMap({ try? Data(hex:$0) }) else { throw ClientError.invalidConfiguration }
            return .registers(try ModbusCodec.registerValues(payload))
        default: throw ClientError.invalidConfiguration
        }
    }
    /// Drop idle line noise or a restarted ASCII frame before the next colon.
    private func trimASCII(_ buffer: inout Data) {
        while !buffer.isEmpty {
            let lineEnd = buffer.range(of:Data([0x0d,0x0a]))
            if let colon = buffer[..<(lineEnd?.lowerBound ?? buffer.endIndex)].lastIndex(of:0x3a) {
                buffer.removeSubrange(buffer.startIndex..<colon)
                return
            }
            buffer.removeSubrange(buffer.startIndex..<(lineEnd?.upperBound ?? buffer.endIndex))
        }
    }
    private func frameLength(_ bytes: Data,framing: ModbusFraming) throws -> Int? {
        switch framing {
        case .ascii:
            guard let colon = bytes.firstIndex(of:0x3a) else { return nil }
            guard let end = bytes.range(of:Data([0x0d,0x0a]),in:colon..<bytes.endIndex) else {
                guard bytes.count <= 513 else { throw ClientError.protocolViolation }; return nil
            }
            let length = bytes.distance(from:bytes.startIndex,to:end.upperBound)
            guard (11...513).contains(length) else { throw ClientError.protocolViolation }
            return length
        case .rtu:
            let prefix = Array(bytes.prefix(6))
            guard prefix.count >= 2 else { return nil }
            let function = prefix[1]
            if function&0x80 != 0 { return 5 }
            if [5,6,15,16].contains(function) { return 8 }
            guard [1,2,3,4].contains(function) else { throw ClientError.protocolViolation }
            guard prefix.count >= 3 else { return nil }
            guard prefix[2] > 0, prefix[2] <= 250 else { throw ClientError.protocolViolation }; return Int(prefix[2])+5
        case .mbap:
            let prefix = Array(bytes.prefix(6))
            guard prefix.count == 6 else { return nil }
            let length = Int(prefix[4])<<8 | Int(prefix[5])
            guard prefix[2] == 0, prefix[3] == 0, (3...254).contains(length) else { throw ClientError.protocolViolation }; return length+6
        }
    }
}
