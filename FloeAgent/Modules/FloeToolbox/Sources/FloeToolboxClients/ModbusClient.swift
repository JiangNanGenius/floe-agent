import Foundation
import FloeToolboxCore

public enum ModbusOperation: Sendable {
    case read(function: UInt8,quantity: UInt16)
    case singleCoil(Bool),singleRegister(UInt16),coils([Bool]),registers([UInt16])
}
public struct ModbusExchangeResult: Sendable {
    public let report: ProtocolReport?
    /// RTU address 0 is a write broadcast. No receipt or device-state claim is manufactured.
    public let broadcast: Bool
}
public enum ModbusRequestBuilder {
    public static func build(unit: UInt8,address: UInt16,operation: ModbusOperation,transactionID: UInt16 = 1,rtu: Bool = false) throws -> Data {
        if case .read(let function,let quantity) = operation {
            guard !rtu || unit != 0 else { throw ClientError.invalidConfiguration }
            return try ModbusCodec.readRequest(unit:unit,function:function,address:address,count:quantity,transactionID:transactionID,rtu:rtu)
        }
        func integer(_ value: UInt16) -> Data { Data([UInt8(value>>8),UInt8(value&255)]) }
        var body = Data([unit])
        switch operation {
        case .singleCoil(let value): body.append(5); body += integer(address)+integer(value ? 0xFF00 : 0)
        case .singleRegister(let value): body.append(6); body += integer(address)+integer(value)
        case .coils(let values):
            guard !values.isEmpty, values.count <= 1968, Int(address)+values.count <= 65536 else { throw ClientError.invalidConfiguration }
            body.append(15); body += integer(address)+integer(UInt16(values.count)); let count = (values.count+7)/8; body.append(UInt8(count))
            var packed = Data(repeating:0,count:count)
            for (index,value) in values.enumerated() { if value { packed[index/8] |= 1<<UInt8(index%8) } }; body += packed
        case .registers(let values):
            guard !values.isEmpty, values.count <= 123, Int(address)+values.count <= 65536 else { throw ClientError.invalidConfiguration }
            body.append(16); body += integer(address)+integer(UInt16(values.count)); body.append(UInt8(values.count*2))
            for value in values { body += integer(value) }
        case .read: throw ClientError.invalidConfiguration
        }
        let packet: Data
        if rtu { let crc = ModbusCodec.crc16(body); packet = body+Data([UInt8(crc&255),UInt8(crc>>8)]) }
        else { packet = integer(transactionID)+Data([0,0])+integer(UInt16(body.count))+body }
        _ = try ModbusCodec.decode(packet,rtu:rtu,response:false); return packet
    }
}

/// Single-request Modbus helper. Response assembly follows the selected MBAP/RTU format,
/// including serial-over-TCP; UDP data is never concatenated across datagrams.
public actor ModbusClient {
    public nonisolated let session: SerialSession
    private var busy = false
    private var nextTransaction: UInt16 = 1
    public init(session: SerialSession) throws {
        guard [.modbusTCP,.modbusRTU].contains(session.endpoint.wireProtocol), [.tcp,.udp,.bluetooth,.usb].contains(session.endpoint.transport) else { throw ClientError.invalidConfiguration }
        self.session = session
    }
    public func exchange(unit: UInt8,address: UInt16,operation: ModbusOperation,timeout: TimeInterval = 5) async throws -> ModbusExchangeResult {
        guard !busy, timeout.isFinite, (0.05...30).contains(timeout) else { throw ClientError.busy }; busy = true; defer { busy = false }
        let rtu = session.endpoint.wireProtocol == .modbusRTU, transaction = nextTransaction
        nextTransaction = transaction == 65535 ? 1 : transaction+1
        let request = try ModbusRequestBuilder.build(unit:unit,address:address,operation:operation,transactionID:transaction,rtu:rtu)
        let requestBody = rtu ? request.dropLast(2) : request.dropFirst(6), requestedFunction = requestBody[requestBody.startIndex+1]
        try await session.send(request,expected:session.lease)
        if rtu, unit == 0 { return ModbusExchangeResult(report:nil,broadcast:true) }
        let clock = ContinuousClock(), deadline = clock.now.advanced(by:.seconds(timeout))
        var buffer = Data(), discarded = 0
        do {
            while true {
                if let length = try frameLength(buffer,rtu:rtu), buffer.count >= length {
                    let frame = Data(buffer.prefix(length)); buffer.removeFirst(length)
                    let report = try ModbusCodec.decode(frame,rtu:rtu,response:true)
                    let matches = report.fields["unitID"] == String(unit) && (rtu || report.fields["transactionID"] == String(transaction))
                    if matches {
                        guard let function = UInt8(report.fields["function"] ?? ""), function == requestedFunction || function == requestedFunction|0x80 else { throw ClientError.protocolViolation }
                        if function == requestedFunction {
                            let responseBody = rtu ? frame.dropLast(2) : frame.dropFirst(6)
                            if [5,6,15,16].contains(function) {
                                guard responseBody.prefix(6) == requestBody.prefix(6) else { throw ClientError.protocolViolation }
                            } else if case .read(let requested,let count) = operation {
                                let expected = requested < 3 ? (Int(count)+7)/8 : Int(count)*2
                                guard report.fields["byteCount"] == String(expected) else { throw ClientError.protocolViolation }
                            }
                        }
                        return ModbusExchangeResult(report:report,broadcast:false)
                    }
                    discarded += 1; guard discarded <= 4 else { throw ClientError.protocolViolation }; continue
                }
                let duration = clock.now.duration(to:deadline).components, seconds = Double(duration.seconds)+Double(duration.attoseconds)/1e18
                guard seconds > 0 else { throw ClientError.timedOut }
                let chunk = try await receive(seconds:seconds)
                guard !chunk.isEmpty, buffer.count+chunk.count <= 4096 else { throw ClientError.tooLarge }
                if session.endpoint.transport == .udp {
                    guard buffer.isEmpty, try frameLength(chunk,rtu:rtu) == chunk.count else { throw ClientError.protocolViolation }
                }
                buffer += chunk
            }
        } catch { await session.close(); throw error }
    }
    private func receive(seconds: Double) async throws -> Data {
        try await withThrowingTaskGroup(of:Data.self) { group in
            group.addTask { try await self.session.receive(expected:self.session.lease) }
            group.addTask { try await Task.sleep(for:.seconds(seconds)); throw ClientError.timedOut }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw ClientError.closed }; return result
        }
    }
    private func frameLength(_ bytes: Data,rtu: Bool) throws -> Int? {
        let prefix = Array(bytes.prefix(6))
        if rtu {
            guard prefix.count >= 2 else { return nil }
            let function = prefix[1]
            if function&0x80 != 0 { return 5 }
            if [5,6,15,16].contains(function) { return 8 }
            guard [1,2,3,4].contains(function) else { throw ClientError.protocolViolation }
            guard prefix.count >= 3 else { return nil }
            guard prefix[2] > 0, prefix[2] <= 250 else { throw ClientError.protocolViolation }; return Int(prefix[2])+5
        }
        guard prefix.count == 6 else { return nil }
        let length = Int(prefix[4])<<8 | Int(prefix[5])
        guard prefix[2] == 0, prefix[3] == 0, (3...254).contains(length) else { throw ClientError.protocolViolation }; return length+6
    }
}
