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
