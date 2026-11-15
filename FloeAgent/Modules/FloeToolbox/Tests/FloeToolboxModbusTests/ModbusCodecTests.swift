import Foundation
import Testing
import FloeToolboxCore
import FloeToolboxClients

private struct Vector {
    let name: String
    let pdu: Data
    let response: Bool
    let fields: [String: String]
}

@Test func modbusOfficialPDUVectorsDecodeInEveryFraming() throws {
    let vectors: [Vector] = [
        Vector(name:"01 read coils response",pdu:Data([1,3,0xCD,0x6B,0x05]),response:true,
               fields:["packedCoilsHex":"CD 6B 05","byteCount":"3","bitOrder":"LSB-first"]),
        Vector(name:"02 read discrete inputs response",pdu:Data([2,3,0xAC,0xDB,0x35]),response:true,
               fields:["packedCoilsHex":"AC DB 35","byteCount":"3"]),
        Vector(name:"03 read holding registers response",pdu:Data([3,6,0x02,0x2B,0,0,0,0x64]),response:true,
               fields:["registerValues":"555,0,100","byteCount":"6","byteOrder":"big-endian"]),
        Vector(name:"04 read input registers response",pdu:Data([4,2,0,0x0A]),response:true,
               fields:["registerValues":"10","byteCount":"2"]),
        Vector(name:"05 write single coil request",pdu:Data([5,0,0xAC,0xFF,0]),response:false,
               fields:["zeroBasedAddress":"172","valueOrQuantity":"65280"]),
        Vector(name:"06 write single register request",pdu:Data([6,0,1,0,3]),response:false,
               fields:["zeroBasedAddress":"1","valueOrQuantity":"3"]),
        Vector(name:"0F write multiple coils request",pdu:Data([0x0F,0,0x13,0,0x0A,2,0xCD,0x01]),response:false,
               fields:["zeroBasedAddress":"19","valueOrQuantity":"10","payloadHex":"CD 01"]),
        Vector(name:"10 write multiple registers request",pdu:Data([0x10,0,1,0,2,4,0,0x0A,1,2]),response:false,
               fields:["zeroBasedAddress":"1","valueOrQuantity":"2","payloadHex":"00 0A 01 02"]),
        Vector(name:"exception response",pdu:Data([0x83,2]),response:true,
               fields:["exceptionCode":"2","exceptionName":"ILLEGAL DATA ADDRESS"]),
    ]
    for framing in ModbusFraming.allCases {
        for vector in vectors {
            let frame = try ModbusCodec.encode(unit:1,pdu:vector.pdu,framing:framing,transactionID:0x1234)
            let report = try ModbusCodec.decode(frame,framing:framing,response:vector.response)
            #expect(report.name == (framing == .mbap ? "Modbus TCP" : framing == .rtu ? "Modbus RTU" : "Modbus ASCII"),
                    "\(vector.name) in \(framing)")
            for (key,value) in vector.fields {
                #expect(report.fields[key] == value, "\(vector.name) \(key) in \(framing)")
            }
            let decoded = try ModbusCodec.decodeFrame(frame,framing:framing)
            #expect(decoded.unit == 1 && decoded.pdu == vector.pdu)
            #expect(decoded.transactionID == (framing == .mbap ? 0x1234 : nil))
        }
    }
}

@Test func modbusOfficialCRCAndLRCAndEnvelopeVectors() throws {
    // Modbus over Serial Line V1.02, Appendix B: frame 02 07 -> CRC 0x1241.
    #expect(ModbusCodec.crc16(Data([0x02,0x07])) == 0x1241)
    #expect(ModbusCodec.lrc(Data([1,3,0,0,0,1])) == 0xFB)
    #expect(try ModbusCodec.readRequest(unit:1,address:0,count:10,rtu:true)
            == Data([1,3,0,0,0,10,0xC5,0xCD]))
    #expect(try ModbusCodec.readRequest(unit:1,address:0,count:10,transactionID:1)
            == Data([0,1,0,0,0,6,1,3,0,0,0,10]))
    #expect(try ModbusCodec.readRequest(unit:1,address:0,count:1,transactionID:1,framing:.ascii)
            == Data(":010300000001FB\r\n".utf8))
    #expect(try ModbusCodec.encode(unit:1,pdu:Data([3,0,0,0,1]),framing:.ascii)
            == Data(":010300000001FB\r\n".utf8))
}

@Test func modbusFramingConversionIsBidirectionalAndPreservesPDU() throws {
    let request = Data([3,0,0,0,2])
    for source in ModbusFraming.allCases {
        let original = try ModbusCodec.encode(unit:7,pdu:request,framing:source,transactionID:0x1234)
        for target in ModbusFraming.allCases {
            let converted = try ModbusCodec.convert(original,from:source,to:target,
                transactionID:target == .mbap ? 0x1234 : nil)
            let frame = try ModbusCodec.decodeFrame(converted,framing:target)
            #expect(frame.unit == 7 && frame.pdu == request)
            #expect(frame.transactionID == (target == .mbap ? 0x1234 : nil))
            let back = try ModbusCodec.convert(converted,from:target,to:source,
                transactionID:source == .mbap ? 0x1234 : nil)
            #expect(back == original, "\(source) -> \(target) -> \(source)")
        }
    }
    let rtu = try ModbusCodec.encode(unit:1,pdu:Data([6,0,1,0,9]),framing:.rtu)
    let mbap = try ModbusCodec.convert(rtu,from:.rtu,to:.mbap,transactionID:7)
    #expect(try ModbusCodec.decodeFrame(mbap,framing:.mbap).transactionID == 7)
    let ascii = try ModbusCodec.encode(unit:1,pdu:Data([1,0,0,0,8]),framing:.ascii)
    #expect(try ModbusCodec.decodeFrame(ascii,framing:.ascii).pdu == Data([1,0,0,0,8]))
}

@Test func modbusDirectionInferenceAndMalformedFramesFailClosed() throws {
    let readRequest = try ModbusCodec.encode(unit:1,pdu:Data([3,0,0,0,1]),framing:.rtu)
    #expect(ModbusCodec.isResponse(try ModbusCodec.decodeFrame(readRequest,framing:.rtu)) == false)
    let readResponse = try ModbusCodec.encode(unit:1,pdu:Data([3,2,0,42]),framing:.rtu)
    #expect(ModbusCodec.isResponse(try ModbusCodec.decodeFrame(readResponse,framing:.rtu)) == true)
    let writeRequest = try ModbusCodec.encode(unit:1,pdu:Data([6,0,1,0,2]),framing:.mbap)
    #expect(ModbusCodec.isResponse(try ModbusCodec.decodeFrame(writeRequest,framing:.mbap)) == false)
    #expect(try ModbusCodec.decodeAuto(writeRequest,framing:.mbap).summary == "Request or write echo")
    let exception = try ModbusCodec.encode(unit:1,pdu:Data([0x83,2]),framing:.ascii)
    #expect(ModbusCodec.isResponse(try ModbusCodec.decodeFrame(exception,framing:.ascii)) == true)

    var badRTU = readResponse; badRTU[badRTU.index(before:badRTU.endIndex)] ^= 0xFF
    #expect(throws: ToolboxError.self) { try ModbusCodec.decodeFrame(badRTU,framing:.rtu) }
    var badASCII = Data(":010300000001FB\r\n".utf8)
    badASCII[badASCII.index(badASCII.endIndex,offsetBy:-3)] = 0x30
    #expect(throws: ToolboxError.self) { try ModbusCodec.decodeFrame(badASCII,framing:.ascii) }
    var missingCRLF = Data(":010300000001FB".utf8)
    #expect(throws: ToolboxError.self) { try ModbusCodec.decodeFrame(missingCRLF,framing:.ascii) }
    missingCRLF = Data(":010300000001FBXX\r\n".utf8)
    #expect(throws: ToolboxError.self) { try ModbusCodec.decodeFrame(missingCRLF,framing:.ascii) }
    var badMBAP = Data([0,1,0,0,0,6,1,3,0,0,0,1]); badMBAP[5] = 7
    #expect(throws: ToolboxError.self) { try ModbusCodec.decodeFrame(badMBAP,framing:.mbap) }
    #expect(throws: ToolboxError.self) { try ModbusCodec.decode(Data([5,0,1,0x12,0x34]),framing:.mbap,response:false) }
    #expect(throws: ToolboxError.self) { try ModbusCodec.decode(Data([0x0F,0,0,0,3,1,0xF8]),framing:.mbap,response:false) }
}

@Test func modbusFunctionLimitsAndAddressSpace() throws {
    #expect(throws: ClientError.self) { try ModbusRequestBuilder.build(unit:1,address:0,operation:.read(function:3,quantity:126),framing:.mbap) }
    #expect(throws: ClientError.self) { try ModbusRequestBuilder.build(unit:1,address:0,operation:.read(function:1,quantity:2001),framing:.mbap) }
    #expect(throws: ClientError.self) { try ModbusRequestBuilder.build(unit:1,address:65535,operation:.read(function:3,quantity:2),framing:.mbap) }
    #expect(try ModbusRequestBuilder.build(unit:1,address:0,operation:.read(function:1,quantity:2000),framing:.mbap).count == 12)
    #expect(try ModbusRequestBuilder.build(unit:1,address:0,operation:.read(function:3,quantity:125),framing:.mbap).count == 12)
    #expect(throws: ClientError.self) { try ModbusRequestBuilder.build(unit:1,address:0,operation:.coils(Array(repeating:true,count:1969)),framing:.mbap) }
    #expect(throws: ClientError.self) { try ModbusRequestBuilder.build(unit:1,address:0,operation:.registers(Array(repeating:1,count:124)),framing:.mbap) }
    #expect(throws: ClientError.self) { try ModbusRequestBuilder.build(unit:0,address:0,operation:.read(function:3,quantity:1),framing:.rtu) }
    #expect(try ModbusRequestBuilder.build(unit:0,address:0,operation:.singleRegister(1),framing:.rtu).count == 8)
    #expect(throws: ClientError.self) { try ModbusRequestBuilder.build(unit:248,address:0,operation:.singleRegister(1),framing:.rtu) }
    #expect(try ModbusRequestBuilder.build(unit:0,address:0,operation:.read(function:3,quantity:1),framing:.mbap).count == 12)
}

@Test func modbusMaximumADUSizesAreExact() throws {
    let maximumPDU = Data([0x41] + Array(repeating:0,count:252))
    let rtu = try ModbusCodec.encode(unit:1,pdu:maximumPDU,framing:.rtu)
    let ascii = try ModbusCodec.encode(unit:1,pdu:maximumPDU,framing:.ascii)
    let mbap = try ModbusCodec.encode(unit:1,pdu:maximumPDU,framing:.mbap)
    #expect(rtu.count == 256)
    #expect(ascii.count == 513)
    #expect(mbap.count == 260)
    #expect(try ModbusCodec.decodeFrame(rtu,framing:.rtu).pdu == maximumPDU)
    #expect(try ModbusCodec.decodeFrame(ascii,framing:.ascii).pdu == maximumPDU)
    #expect(try ModbusCodec.decodeFrame(mbap,framing:.mbap).pdu == maximumPDU)
    #expect(throws: ToolboxError.self) {
        _ = try ModbusCodec.encode(unit:1,pdu:Data([0x41] + Array(repeating:0,count:253)),framing:.ascii)
    }
}

@Test func modbusCoilPackingAndRegisterByteOrder() throws {
    #expect(ModbusCodec.packCoils([true,false,true]) == Data([0x05]))
    #expect(try ModbusCodec.unpackCoils(Data([0x05]),count:3) == [true,false,true])
    let bits = try ModbusCodec.unpackCoils(Data([0xCD,0x6B,0x05]),count:19)
    #expect(bits == [true,false,true,true,false,false,true,true,
                     true,true,false,true,false,true,true,false,
                     true,false,true])
    #expect(try ModbusCodec.registerValues(Data([0x02,0x2B,0,0,0,0x64])) == [555,0,100])
    #expect(throws: ToolboxError.self) { try ModbusCodec.registerValues(Data([1])) }
    #expect(throws: ToolboxError.self) { try ModbusCodec.unpackCoils(Data([0xFF]),count:9) }
}

@Test func modbusAddressReferencesAndValueParsing() throws {
    #expect(try ModbusAddressText.parse("0").zeroBased == 0)
    #expect(try ModbusAddressText.parse("0x10").zeroBased == 16)
    #expect(try ModbusAddressText.parse("40001",expected:.holdingRegister).zeroBased == 0)
    #expect(try ModbusAddressText.parse("40001",expected:.holdingRegister).table == .holdingRegister)
    #expect(try ModbusAddressText.parse("30001",expected:.inputRegister).zeroBased == 0)
    #expect(try ModbusAddressText.parse("10001",expected:.discreteInput).zeroBased == 0)
    #expect(try ModbusAddressText.parse("00001",expected:.coil).zeroBased == 0)
    #expect(try ModbusAddressText.parse("410000",expected:.holdingRegister).zeroBased == 9999)
    #expect(try ModbusAddressText.parse("010000",expected:.coil).zeroBased == 9999)
    #expect(try ModbusAddressText.parse("40000").zeroBased == 40000)
    #expect(try ModbusAddressText.parse("50001").zeroBased == 50001)
    #expect(throws: ToolboxError.self) { try ModbusAddressText.parse("40001",expected:.coil) }
    #expect(throws: ToolboxError.self) { try ModbusAddressText.parse("65536") }
    #expect(ModbusAddressText.reference(table:.holdingRegister,zeroBased:0) == "40001")
    #expect(ModbusAddressText.reference(table:.holdingRegister,zeroBased:9998) == "49999")
    #expect(ModbusAddressText.reference(table:.holdingRegister,zeroBased:9999) == "410000")
    #expect(ModbusAddressText.reference(table:.coil,zeroBased:9999) == "010000")

    #expect(try ModbusValueParser.uint8("255") == 255)
    #expect(try ModbusValueParser.uint16("0x1234") == 0x1234)
    #expect(try ModbusValueParser.uint16List("1, 0x02\n3") == [1,2,3])
    #expect(try ModbusValueParser.boolList("1, off, 开") == [true,false,true])
    #expect(throws: ClientError.self) { try ModbusValueParser.uint8("256") }
    #expect(throws: ClientError.self) { try ModbusValueParser.uint16List("1,,2") }
}

@Test func modbusOperationDraftResolvesEveryPublicOperation() throws {
    let read = try ModbusOperationDraft(kind:.readHoldingRegisters,addressText:"40001",quantityText:"2").resolve()
    #expect(read.address == 0 && read.quantity == 2 && read.table == .holdingRegister)
    if case .read(let function,let quantity) = read.operation { #expect(function == 3 && quantity == 2) } else { Issue.record("wrong read operation") }
    let coil = try ModbusOperationDraft(kind:.writeSingleCoil,addressText:"00001",coilOn:true).resolve()
    if case .singleCoil(let value) = coil.operation { #expect(value) } else { Issue.record("wrong coil operation") }
    #expect(coil.expectedValues == [1] && coil.readBackQuantity == 1)
    let register = try ModbusOperationDraft(kind:.writeSingleRegister,addressText:"40002",valuesText:"0x2A").resolve()
    if case .singleRegister(let value) = register.operation { #expect(value == 42) } else { Issue.record("wrong register operation") }
    #expect(register.address == 1)
    let coils = try ModbusOperationDraft(kind:.writeMultipleCoils,valuesText:"1,0,1").resolve()
    if case .coils(let values) = coils.operation { #expect(values == [true,false,true]) } else { Issue.record("wrong coils operation") }
    #expect(coils.quantity == 3 && coils.readBackQuantity == 3)
    let registers = try ModbusOperationDraft(kind:.writeMultipleRegisters,valuesText:"10,20").resolve()
    if case .registers(let values) = registers.operation { #expect(values == [10,20]) } else { Issue.record("wrong registers operation") }
    #expect(registers.quantity == 2)
    #expect(throws: ClientError.self) { try ModbusOperationDraft(kind:.readCoils,quantityText:"2001").resolve() }
    #expect(throws: ClientError.self) { try ModbusOperationDraft(kind:.readHoldingRegisters,addressText:"65535",quantityText:"2").resolve() }
    #expect(throws: ClientError.self) { try ModbusOperationDraft(kind:.writeMultipleCoils,valuesText:"2").resolve() }
    #expect(throws: ClientError.self) { try ModbusOperationDraft(kind:.writeMultipleRegisters,addressText:"65535",valuesText:"1,2").resolve() }
}
