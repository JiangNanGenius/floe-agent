import Foundation
import Testing
@testable import FloeToolboxCore

@Test func serialAssistantSeparatesConnectionFromProtocolAndOtherClients() throws {
    #expect(SerialAssistantConnection.allCases.map(\.rawValue) == ["tcp","udp","bluetooth","usb"])
    #expect(SerialAssistantProtocol.allCases.map(\.rawValue) == ["raw","modbus"])
    #expect([ToolboxTool.serialAssistant,.http,.webSocket,.mqtt].allSatisfy { $0.group == .communication })
    let udp = SerialAssistantConfiguration(connection:.udp,protocolType:.modbus,modbusFraming:.rtu)
    #expect(try udp.wireProtocol() == .modbusRTU)
    try udp.validate(endpoint:SerialEndpoint(title:"fixture",transport:.udp,wireProtocol:.modbusRTU,host:"192.0.2.1",port:502))
    #expect(throws: ToolboxError.self) { try SerialAssistantConfiguration(connection:.udp,protocolType:.modbus).wireProtocol() }
    #expect(throws: ToolboxError.self) {
        try udp.validate(endpoint:SerialEndpoint(title:"wrong protocol",transport:.udp,wireProtocol:.mqtt5,host:"192.0.2.1",port:502))
    }
}
private func observed(_ time: Double, ssid: String? = "Fixture Wi-Fi", bssid: String? = "02:00:00:00:00:01",
                      probe: RoamingProbeResult = .reply(milliseconds:5)) -> RoamingObservation {
    RoamingObservation(timestamp:Date(timeIntervalSince1970:time),uptime:time,status:.wifi,ssid:ssid,bssid:bssid,probe:probe)
}
@Test func roamingRecognizesObservedAPChangeAndKeepsProbeFactsSeparate() throws {
    var trace = try RoamingTrace(configuration:RoamingConfiguration(target:"192.0.2.1"))
    _ = try trace.append(observed(1,bssid:"02:AB:00:00:00:01"))
    _ = try trace.append(observed(2,bssid:"02:ab:00:00:00:01",probe:.reply(milliseconds:900)))
    #expect(trace.snapshot.totalAccessPointChanges == 0)
    _ = try trace.append(observed(3,bssid:"02:ab:00:00:00:02",probe:.timeout))
    #expect(trace.snapshot.totalAccessPointChanges == 1)
    #expect(trace.snapshot.events.last?.kind == .accessPointChanged)
    #expect(trace.snapshot.events.last?.previousObservedAt == Date(timeIntervalSince1970:2))
    #expect(trace.snapshot.probesSent == 3 && trace.snapshot.probesLost == 1)
}
@Test func missingIdentityAndProbeAvailabilityNeverInventRoamingOrLoss() throws {
    var trace = try RoamingTrace(configuration:RoamingConfiguration(target:"192.0.2.1"))
    _ = try trace.append(observed(1))
    _ = try trace.append(RoamingObservation(uptime:2,status:.unavailable,probe:.notAttempted))
    _ = try trace.append(observed(3,bssid:nil,probe:.notAttempted))
    _ = try trace.append(observed(4,bssid:"02:00:00:00:00:02"))
    #expect(trace.snapshot.totalAccessPointChanges == 0)
    #expect(trace.snapshot.events.map(\.kind) == [.identityUnavailable,.identityRestored])
    #expect(trace.snapshot.probesSent == 2 && trace.snapshot.packetLoss == 0)
}
@Test func roamingNetworkChangeIsDistinctFromAPRoaming() throws {
    var trace = try RoamingTrace(configuration:RoamingConfiguration(target:"192.0.2.1"))
    _ = try trace.append(observed(1))
    _ = try trace.append(observed(2,ssid:"Other fixture",bssid:"02:00:00:00:00:02"))
    #expect(trace.snapshot.events.map(\.kind) == [.networkChanged])
    #expect(trace.snapshot.totalAccessPointChanges == 0)
}
@Test func roamingGapsDoNotClaimObservedHandoffs() throws {
    var trace = try RoamingTrace(configuration:RoamingConfiguration(target:"192.0.2.1"))
    _ = try trace.append(observed(1))
    _ = try trace.append(observed(10,bssid:"02:00:00:00:00:02"))
    #expect(trace.snapshot.events.map(\.kind) == [.observationGap])
    #expect(trace.snapshot.totalAccessPointChanges == 0)
}
@Test func roamingRollingBoundsAndEventLayerAreExplicit() throws {
    var trace = try RoamingTrace(configuration:RoamingConfiguration(target:"192.0.2.1",maximumSamples:2,maximumEvents:1))
    var last: RoamingSample?
    for i in 1...4 { last = try trace.append(observed(Double(i),bssid:"02:00:00:00:00:0\(i)")) }
    #expect(trace.snapshot.samples.count == 2 && trace.snapshot.droppedSamples == 2)
    #expect(trace.snapshot.events.count == 1 && trace.snapshot.droppedEvents == 2)
    #expect(trace.snapshot.totalAccessPointChanges == 3)
    let event = try #require(last).captureEvent()
    #expect(event.layer == .applicationBytes && event.direction == .observation)
    #expect(try JSONDecoder().decode(RoamingSample.self,from:event.bytes) == last)
}
@Test func roamingMalformedMeasurementsPreserveTheTrace() throws {
    var trace = try RoamingTrace(configuration:RoamingConfiguration(target:"192.0.2.1"))
    _ = try trace.append(observed(2)); let old = trace.snapshot
    for bad in [observed(3,bssid:"invalid"),observed(3,probe:.reply(milliseconds:.nan)),observed(1),
                RoamingObservation(uptime:3,status:.wifi,signalDBM:0)] {
        #expect(throws: ToolboxError.self) { try trace.append(bad) }
        #expect(trace.snapshot == old)
    }
    #expect(throws: ToolboxError.self) { try RoamingConfiguration(target:"192.0.2.1",identityInterval:0) }
    #expect(old.meanLatencyMilliseconds == 5)
}
@Test func roamingProbeAndIdentityStreamsKeepIndependentObservationTimes() throws {
    var trace = try RoamingTrace(configuration:RoamingConfiguration(target:"192.0.2.1",identityInterval:1,probeInterval:0.2))
    _ = try trace.append(observed(1,probe:.notAttempted))
    _ = try trace.append(RoamingObservation(timestamp:Date(timeIntervalSince1970:1.9),uptime:1.9,status:.notObserved,probe:.reply(milliseconds:5)))
    _ = try trace.append(observed(2,bssid:"02:00:00:00:00:02",probe:.notAttempted))
    #expect(trace.snapshot.events.last?.kind == .accessPointChanged)
    #expect(trace.snapshot.events.last?.previousObservedAt == Date(timeIntervalSince1970:1))
    _ = try trace.append(RoamingObservation(uptime:9.9,status:.notObserved,probe:.timeout))
    _ = try trace.append(observed(10,bssid:"02:00:00:00:00:03",probe:.notAttempted))
    #expect(trace.snapshot.events.last?.kind == .observationGap)
    #expect(trace.snapshot.totalAccessPointChanges == 1)
    #expect(trace.snapshot.probesSent == 2 && trace.snapshot.probesLost == 1)
}
