import Foundation
import Testing
@testable import FloeToolboxCore

@Test func hexRejectsPartialBytes() throws {
    #expect(try Data(hex: "00 ff 0A") == Data([0, 255, 10]))
    #expect(throws: ToolboxError.self) { try Data(hex: "A") }
    #expect(throws: ToolboxError.self) { try Data(hex: "0Z") }
}
@Test func modbusRequestAndCRC() throws {
    let tcp = try ModbusCodec.readRequest(unit: 1, address: 100, count: 8)
    #expect(tcp == Data([0, 1, 0, 0, 0, 6, 1, 3, 0, 100, 0, 8]))
    let request = try ModbusCodec.decode(tcp, response: false)
    #expect(request.fields["zeroBasedAddress"] == "100")
    let rtu = try ModbusCodec.readRequest(unit: 1, address: 0, count: 10, rtu: true)
    #expect(rtu == Data([1, 3, 0, 0, 0, 10, 0xc5, 0xcd]))
    #expect(try ModbusCodec.decode(rtu, rtu: true, response: false).fields["crc"] == "valid")
    var corrupt = rtu; corrupt[7] ^= 1
    #expect(throws: ToolboxError.self) { try ModbusCodec.decode(corrupt, rtu: true, response: false) }
    #expect(throws: ToolboxError.self) { try ModbusCodec.readRequest(unit: 1, address: 65535, count: 2) }
}
@Test func modbusResponseAndException() throws {
    let response = try ModbusCodec.decode(Data([0, 1, 0, 0, 0, 7, 1, 3, 4, 0, 236, 1, 2]), response: true)
    #expect(response.fields["registerValues"] == "236,258")
    #expect(try ModbusCodec.decode(Data([0, 1, 0, 0, 0, 3, 1, 0x83, 2]), response: true).fields["exceptionCode"] == "2")
    #expect(throws: ToolboxError.self) { try ModbusCodec.decode(Data([0, 1, 0, 0, 0, 7, 1, 3, 3, 0, 1]), response: true) }
}
@Test func mqttPublishAndMalformedLength() throws {
    let publish = Data([0x32, 8, 0, 1, 0x61, 0, 7, 0x31, 0x32, 0x33])
    let result = try MQTTCodec.decode(publish)
    #expect(result.fields["topic"] == "a")
    #expect(result.fields["packetID"] == "7")
    #expect(result.fields["payloadText"] == "123")
    #expect(throws: ToolboxError.self) { try MQTTCodec.decode(Data([0xc0, 1, 0])) }
    #expect(throws: ToolboxError.self) { try MQTTCodec.remainingLength(Data([0x80, 0x80, 0x80, 0x80])) }
}
@Test func streamFragmentationAndCoalescing() throws {
    let frame = try ModbusCodec.readRequest(unit: 1, address: 0, count: 1)
    var framer = SerialStreamFramer()
    #expect(try framer.append(Data(frame.prefix(5)), format: .modbusTCP).isEmpty)
    let output = try framer.append(Data(frame.dropFirst(5)) + frame, format: .modbusTCP)
    #expect(output == [frame, frame]); #expect(framer.pendingBytes == 0)
    var mqtt = SerialStreamFramer()
    #expect(try mqtt.append(Data([0xc0]), format: .mqtt).isEmpty)
    #expect(try mqtt.append(Data([0, 0xd0, 0]), format: .mqtt) == [Data([0xc0, 0]), Data([0xd0, 0])])
}
@Test func streamOverflowPreservesOldPendingData() throws {
    var framer = SerialStreamFramer(maximumFrameBytes: 8)
    _ = try framer.append(Data([0x30, 6]), format: .mqtt)
    #expect(throws: ToolboxError.self) { try framer.append(Data(repeating: 0, count: 7), format: .mqtt) }
    #expect(framer.pendingBytes == 2)
}
