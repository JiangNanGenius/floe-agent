import Foundation
import Testing
import FloeToolboxCore
@testable import FloeToolboxDiagnostics

@Test func actualLoopbackPingAndTraceroute() async throws {
    let service = DiagnosticService(lease:SessionLease(ownerID:UUID()),authorize:{ _,_,_ in true })
    let replies = try await service.ping(target:"127.0.0.1",count:1)
    #expect(replies.count == 1)
    if case .reply(let ms) = replies.first?.status { #expect(ms >= 0) } else { Issue.record("loopback did not echo") }
    let trace = try await service.traceroute(target:"127.0.0.1",maximumHops:2)
    #expect(trace.last?.status == .reached)
    await service.stop()
    await #expect(throws:DiagnosticError.self) { try await service.ping(target:"127.0.0.1",count:1) }
}
@Test func deniedDiagnosticDoesNotProbeAndBoundsRejectBeforeAuthorization() async throws {
    let service = DiagnosticService(lease:SessionLease(ownerID:UUID()),authorize:{ _,_,_ in false })
    await #expect(throws:DiagnosticError.denied) { try await service.ping(target:"127.0.0.1",count:1) }
    await #expect(throws:DiagnosticError.self) { try await service.ports(target:"127.0.0.1",ports:[0]) }
    await #expect(throws:DiagnosticError.self) { try await BonjourDiscovery.browse(type:"http._tcp\ninvalid") }
}
private actor IdentitySequence {
    var index = 0
    func next() -> WiFiIdentity {
        index += 1
        return WiFiIdentity(status:.wifi,ssid:"synthetic",bssid:index < 2 ? "00:11:22:33:44:55" : "00:11:22:33:44:66")
    }
}
@Test func roamingOwnsIndependentSamplersAndPersistsStopFencedRecords() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
    let lease = SessionLease(ownerID:UUID()), identities = IdentitySequence()
    let journal = try CaptureJournal(ownerID:lease.ownerID,captureID:lease.sessionID,repository:FileCaptureRepository(root:root),limits:CaptureLimits())
    let sampler = try RoamingSampler(lease:lease,configuration:RoamingConfiguration(target:"127.0.0.1",identityInterval:0.1,probeInterval:0.15),journal:journal,identity:{ await identities.next() },probe:{ _ in .reply(milliseconds:2) },authorize:{ _,_,_ in true })
    try await sampler.start(); try await Task.sleep(for:.milliseconds(360)); await sampler.stop()
    try await Task.sleep(for:.milliseconds(30))
    let snapshot = await sampler.snapshot(), records = await journal.snapshot().records
    #expect(snapshot.totalAccessPointChanges == 1)
    #expect(snapshot.probesSent >= 2)
    #expect(snapshot.samples.contains { $0.observation.status == .notObserved && $0.observation.bssid == nil })
    #expect(records.count == snapshot.samples.count)
    try await Task.sleep(for:.milliseconds(120))
    #expect(await sampler.snapshot().samples.count == snapshot.samples.count)
    try await sampler.start(); await sampler.stop()
}
@Test func DNSRecordTextIsBoundedAndDoesNotInventSignal() {
    #expect(DNSRecord(name:"fixture",type:.a,ttl:1,data:Data([127,0,0,1])).text == "127.0.0.1")
    #expect(DNSRecord(name:"fixture",type:.txt,ttl:1,data:Data([3,97,98,99])).text == "abc")
    #expect(WiFiIdentity(status:.wifi).signalDBM == nil)
}

@Test func DNSNamesAndServiceRecordsRenderNetworkOrderAndRejectPointers() throws {
    let name = Data([4])+Data("host".utf8)+Data([5])+Data("local".utf8)+Data([0])
    #expect(DNSRecord(name:"fixture",type:.cname,ttl:1,data:name).text == "host.local.")
    #expect(DNSRecord(name:"fixture",type:.mx,ttl:1,data:Data([0,10])+name).text == "10 host.local.")
    #expect(DNSRecord(name:"fixture",type:.srv,ttl:1,data:Data([0,1,0,2,1,187])+name).text == "1 2 443 host.local.")
    #expect(DNSRecord(name:"fixture",type:.ptr,ttl:1,data:Data([0xC0,0x0C])).text == "c0 0c")
    #expect(try HostResolver.ipv4Addresses("localhost").contains { HostResolver.presentation($0) == "127.0.0.1" })
}


@Suite("Darwin ICMP error framing", .serialized)
struct DarwinICMPErrorTests {
    private let identifier: UInt16 = 0x3847
    private let sequence: UInt16 = 42
    private let token = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
    private var destination: UInt32 {
        Data([203, 0, 113, 8]).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }
    private func sealed(_ value: Data) -> Data {
        var data = value; data[2] = 0; data[3] = 0
        let sum = DeviceICMPPacket.checksum(data)
        data[2] = UInt8(sum >> 8); data[3] = UInt8(sum & 255)
        return data
    }
    private func wireError(type: UInt8 = 11, headerLength: Int = 24, quoteBytes: Int = 12) -> Data {
        let request = DeviceICMPPacket.buildEchoRequest(identifier: identifier, sequence: sequence, payload: token)
        var data = Data(count: 8 + headerLength)
        data[0] = type; data[8] = 0x40 | UInt8(headerLength / 4)
        data[10] = UInt8((headerLength + request.count) >> 8)
        data[11] = UInt8((headerLength + request.count) & 255)
        data[17] = 1
        data.replaceSubrange(24..<28, with: [203, 0, 113, 8])
        data += request.prefix(quoteBytes)
        return sealed(data)
    }
    private func darwinDelivered(_ wire: Data) -> Data {
        // XNU icmp_input validates the wire checksum, then NTOHS(ip_len)
        // in the quoted IPv4 header before delivering to the raw listener.
        var data = wire; data.swapAt(10, 11); return data
    }

    @Test func hostOrderQuotedLengthRestoresWireChecksumWithoutRelaxingIdentity() throws {
        let wire = wireError(), delivered = darwinDelivered(wire)
        #expect(DeviceICMPPacket.checksum(wire) == 0)
        #expect(DeviceICMPPacket.checksum(delivered) != 0)
        let expected = try #require(DeviceICMPPacket.parseEmbeddedError(wire))
        let parsed = try #require(DeviceICMPPacket.parseEmbeddedError(delivered))
        #expect(parsed == expected)
        #expect(parsed.matches(identifier: identifier, sequence: sequence, destination: destination, token: token))
        #expect(!parsed.matches(identifier: identifier + 1, sequence: sequence, destination: destination, token: token))
        #expect(!parsed.matches(identifier: identifier, sequence: sequence + 1, destination: destination, token: token))
        #expect(!parsed.matches(identifier: identifier, sequence: sequence, destination: 0, token: token))
        #expect(!parsed.matches(identifier: identifier, sequence: sequence, destination: destination, token: Data(repeating: 9, count: 16)))
        var outer = Data(count: 24); outer[0] = 0x46; outer[9] = 1
        #expect(DeviceICMPPacket.parseEmbeddedError(outer + delivered) == expected)
    }

    @Test func minimumQuotedHeadersMatchOnlyTheirExactProbeForBothErrorTypes() throws {
        for type in [DeviceICMPPacket.timeExceededType, DeviceICMPPacket.destinationUnreachableType] {
            let delivered = darwinDelivered(wireError(type: type, headerLength: 20, quoteBytes: 8))
            let parsed = try #require(DeviceICMPPacket.parseEmbeddedError(delivered))
            #expect(parsed.type == type && parsed.quotedPayload.isEmpty)
            #expect(parsed.matches(identifier: identifier, sequence: sequence, destination: destination, token: token))
            #expect(!parsed.matches(identifier: identifier + 1, sequence: sequence, destination: destination, token: token))
        }
    }

    @Test func normalizationStillRejectsCorruptionFragmentsAndForeignPacketShapes() {
        let wire = wireError()
        var damaged = darwinDelivered(wire); damaged[damaged.count - 1] ^= 1
        #expect(DeviceICMPPacket.parseEmbeddedError(damaged) == nil)
        var wrongProtocol = wire; wrongProtocol[17] = 17
        #expect(DeviceICMPPacket.parseEmbeddedError(darwinDelivered(sealed(wrongProtocol))) == nil)
        var fragment = wire; fragment[14] = 1
        #expect(DeviceICMPPacket.parseEmbeddedError(darwinDelivered(sealed(fragment))) == nil)
        var notEcho = wire; notEcho[8 + 24] = DeviceICMPPacket.echoReplyType
        #expect(DeviceICMPPacket.parseEmbeddedError(darwinDelivered(sealed(notEcho))) == nil)
        var badLength = wire; badLength[10] = 0; badLength[11] = 20
        #expect(DeviceICMPPacket.parseEmbeddedError(darwinDelivered(sealed(badLength))) == nil)
        #expect(DeviceICMPPacket.parseEmbeddedError(Data(darwinDelivered(wire).prefix(35))) == nil)
    }
}
