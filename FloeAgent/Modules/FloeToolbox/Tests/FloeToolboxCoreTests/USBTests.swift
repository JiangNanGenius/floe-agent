import Foundation
import Testing
@testable import FloeToolboxCore

private actor USBFixture: USBTransferExecutor {
    var writes: [Data] = []; var controls: [USBControlRequest] = []; var closed = false
    let malformed: Bool
    init(malformed: Bool = false) { self.malformed = malformed }
    func control(_ request: USBControlRequest) -> Data { controls.append(request); return malformed ? Data([1]) : Data(repeating:0,count:Int(request.expectedReadBytes)) }
    func write(_ bytes: Data) -> Int { writes.append(bytes); return malformed ? bytes.count+1 : bytes.count }
    func read(maximumBytes: Int) -> Data { malformed ? Data(repeating:1,count:maximumBytes+1) : Data([1,2]) }
    func close() { closed = true }
}
@Test func usbCandidateFamiliesAreDescriptorBased() {
    #expect(USBSerialChipPlans.candidate(vendor:0x0403,product:0x6001,interfaceClass:0,subclass:0) == .ftdi)
    #expect(USBSerialChipPlans.candidate(vendor:0x1a86,product:0x55d4,interfaceClass:2,subclass:2) == .cdcACM)
    #expect(USBSerialChipPlans.candidate(vendor:0x10c4,product:0xea60,interfaceClass:0,subclass:0) == .cp210x)
    #expect(USBSerialChipPlans.candidate(vendor:0x1a86,product:0x7523,interfaceClass:0,subclass:0) == .ch34x)
    #expect(USBSerialChipPlans.candidate(vendor:0x1234,product:0x9999,interfaceClass:0,subclass:0) == nil)
}
@Test func cdcLineCodingAndChipPlans() throws {
    let settings = try USBSerialSettings()
    let cdc = try USBSerialChipPlans.configuration(family:.cdcACM,settings:settings)
    #expect(cdc[0].payload == Data([0,0xc2,1,0,0,0,8]))
    #expect(cdc[0].request == 0x20); #expect(cdc[1].value == 3)
    let cp = try USBSerialChipPlans.configuration(family:.cp210x,settings:settings)
    #expect(cp.map(\.request) == [0,0x1e,3,7])
    let ch = try USBSerialChipPlans.configuration(family:.ch34x,settings:settings)
    #expect(ch[1].value == 0x1312); #expect(ch[3].index == 0xc3)
    #expect(try USBSerialChipPlans.configuration(family:.ftdi,settings:settings).count == 3)
    #expect(throws: ToolboxError.self) { try USBSerialChipPlans.configuration(family:.pl2303,settings:settings) }
}
@Test func malformedUSBSettingsAndDataAreErrors() throws {
    #expect(throws: ToolboxError.self) { try USBSerialSettings(baud:0) }
    #expect(throws: ToolboxError.self) { try USBSerialSettings(dataBits:0) }
    #expect(throws: ToolboxError.self) { try USBControlRequest(requestType:0x80,request:1,payload:Data([1])) }
    #expect(throws: ToolboxError.self) { try USBSerialChipPlans.stripFTDIStatus(Data([1]),maximumPacketSize:64) }
    #expect(try USBSerialChipPlans.stripFTDIStatus(Data([0x10,0,65,66,0x10,0,67,68]),maximumPacketSize:4) == Data([65,66,67,68]))
}
@Test func prolificRevisionProfilesProduceCheckedRequests() throws {
    #expect(PL2303Revision.identify(deviceClass:0,controlPacketSize:64,usbVersion:0x200,deviceVersion:0x300) == nil)
    #expect(PL2303Revision.identify(deviceClass:0,controlPacketSize:64,usbVersion:0x200,deviceVersion:0x300,hxProbeSucceeded:true) == .taTB)
    #expect(PL2303Revision.identify(deviceClass:0,controlPacketSize:64,usbVersion:0x200,deviceVersion:0x300,hxProbeSucceeded:false) == .hxn)
    #expect(PL2303Revision.identify(deviceClass:2,controlPacketSize:8,usbVersion:0x110,deviceVersion:0) == .legacy01)
    let settings = try USBSerialSettings()
    let legacy = try USBSerialChipPlans.configuration(family:.pl2303,settings:settings,pl2303Revision:.legacy01)
    #expect(legacy.filter { $0.expectedReadBytes == 1 }.count == 6)
    #expect(legacy.contains { $0.value == 2 && $0.index == 0x24 })
    let hxn = try USBSerialChipPlans.configuration(family:.pl2303,settings:settings,pl2303Revision:.hxn)
    #expect(hxn.first?.request == 0x80 && hxn.first?.value == 7 && hxn.first?.index == 3)
    #expect(hxn.first { $0.request == 0x20 }?.payload == Data([0,0xc2,1,0,0,0,8]))
    for revision in PL2303Revision.allCases {
        #expect(try !USBSerialChipPlans.configuration(family:.pl2303,settings:USBSerialSettings(baud:123456),pl2303Revision:revision).isEmpty)
    }
}
@Test func usbAdapterMissingOrMalformedDeviceDoesNotTrap() async throws {
    let broken = USBFixture(malformed:true), connection = try USBSerialConnection(executor:broken,family:.cdcACM)
    await #expect(throws: ToolboxError.self) { try await connection.configure(USBSerialSettings()) }
    #expect(await broken.closed)
    await #expect(throws: ToolboxError.staleSession) { try await connection.send(Data([1])) }
    await connection.close()
}
@Test func usbAdapterChecksLengthsAndClose() async throws {
    let fixture = USBFixture(), connection = try USBSerialConnection(executor:fixture,family:.cdcACM)
    try await connection.configure(USBSerialSettings())
    try await connection.send(Data([1,2,3]))
    #expect(await fixture.writes == [Data([1,2,3])])
    #expect(try await connection.receive(maximumBytes:64) == Data([1,2]))
    await connection.close()
    await #expect(throws: ToolboxError.staleSession) { try await connection.receive(maximumBytes:64) }
}
