import Foundation
import Testing
import FloeToolboxCore
import FloeToolboxUSBWire
@testable import FloeToolboxUSB
private actor FakeUSBChannel: USBUserClientChannel {
    var closed = false; var writes = Data(); var corrupt = false; var short = false
    func setCorrupt() { corrupt = true }
    func setShort() { short = true }
    func exchange(_ request: Data, maximumReplyBytes: Int) throws -> Data {
        guard !closed else { throw USBClientError.detached }
        var header = FloeUSBRequest()
        guard request.withUnsafeBytes({ floe_usb_validate_request($0.baseAddress,$0.count,&header) }) else { throw USBClientError.invalidPacket }
        var payload = Data(), count: UInt32 = 0
        if header.operation == FLOE_USB_OP_INFO {
            var info = FloeUSBDeviceInfo(); info.vendor = 0x10c4; info.product = 0xea60
            info.inputEndpoint = 0x81; info.outputEndpoint = 2; info.maximumPacketSize = 64
            payload = withUnsafeBytes(of:info) { Data($0) }; count = UInt32(payload.count)
        } else if header.operation == FLOE_USB_OP_WRITE {
            count = short ? header.payloadSize/2 : header.payloadSize
            writes += request.dropFirst(MemoryLayout<FloeUSBRequest>.size).prefix(Int(count))
        } else if header.operation == FLOE_USB_OP_CONTROL, header.requestType&0x80 == 0 { count = header.payloadSize }
        else { payload = Data(repeating:7,count:Int(header.capacity)); count = header.capacity }
        var response = FloeUSBResponse(); response.magic = corrupt ? 0 : FLOE_USB_MAGIC; response.version = 1
        response.operation = header.operation; response.requestID = header.requestID; response.generation = 9; response.actual = count
        return withUnsafeBytes(of:response) { Data($0) }+payload
    }
    func close() { closed = true }
}
@Test func userClientChunksLargeWritesAndBindsDescriptorGeneration() async throws {
    let channel = FakeUSBChannel(), executor = USBUserClientExecutor(channel:channel)
    let info = try await executor.information()
    #expect(info.family == .cp210x && info.generation == 9)
    let bytes = Data(repeating:42,count:20000)
    #expect(try await executor.write(bytes) == bytes.count)
    #expect(await channel.writes == bytes)
    #expect(try await executor.read(maximumBytes:65536).count == 3072)
    await executor.close(); await executor.close()
    await #expect(throws:USBClientError.detached) { try await executor.read(maximumBytes:1) }
}
@Test func malformedUserClientReplyFailsClosedAndCoreRejectsShortWrites() async throws {
    let channel = FakeUSBChannel(), executor = USBUserClientExecutor(channel:channel)
    _ = try await executor.information(); await channel.setCorrupt()
    await #expect(throws:USBClientError.invalidPacket) { try await executor.read(maximumBytes:3) }
    #expect(await channel.closed)
    let shortChannel = FakeUSBChannel()
    let connection = try await USBSerialClient.connect(channel:shortChannel,settings:USBSerialSettings())
    await shortChannel.setShort()
    await #expect(throws:ToolboxError.self) { try await connection.send(Data([1,2,3,4])) }
    await connection.close()
}
@Test func malformedIPCAndDescriptorInputsAreRejected() {
    var header = FloeUSBRequest()
    for length in 0..<48 { let bytes = Data(repeating:0,count:length); #expect(!bytes.withUnsafeBytes { floe_usb_validate_request($0.baseAddress,$0.count,&header) }) }
    let truncated = Data([9,2,99,0,1,1,0,0,0])
    var endpoints = FloeUSBEndpoints()
    #expect(!truncated.withUnsafeBytes { floe_usb_find_endpoints($0.baseAddress,$0.count,0,0,&endpoints) })
    let descriptor = Data([9,2,32,0,1,1,0,0,0,9,4,0,0,2,255,0,0,0,7,5,0x81,2,64,0,0,7,5,2,2,64,0,0])
    #expect(descriptor.withUnsafeBytes { floe_usb_find_endpoints($0.baseAddress,$0.count,0,0,&endpoints) })
    #expect(endpoints.input == 0x81 && endpoints.output == 2 && endpoints.maximumPacketSize == 64)
}
