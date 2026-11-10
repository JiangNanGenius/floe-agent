import Foundation
import Testing
import FloeToolboxCore
import FloeToolboxDiagnostics
import FloeToolboxWorkbenches

@MainActor private final class LANRequestRecorder {
    var states: [DiagnosticRequestState] = []
}
private actor LANUIProbeLog {
    var types: [String] = []
    var interfaces: [[UInt32]] = []
    var permitted: [SessionLease] = []
    func sawType(_ type: String) { types.append(type) }
    func resolved(_ indices: [UInt32]) { interfaces.append(indices) }
    func authorize(_ lease: SessionLease) { permitted.append(lease) }
}
private actor LANUIControlledService: DiagnosticWorkbenchService {
    private var pending: [Int: CheckedContinuation<LANScanReport, any Error>] = [:]
    private var sinks: [Int: @Sendable (LANDiscoveryEvent) -> Void] = [:]
    private var waiting: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var count = 0
    func lanScan(types: [String], seconds: Double, onEvent: (@Sendable (LANDiscoveryEvent) -> Void)?) async throws -> LANScanReport {
        count += 1; let number = count
        if let onEvent { sinks[number] = onEvent }
        return try await withCheckedThrowingContinuation { continuation in
            pending[number] = continuation
            for value in waiting.removeValue(forKey:number) ?? [] { value.resume() }
        }
    }
    func wait(_ number: Int) async {
        if pending[number] != nil { return }
        await withCheckedContinuation { waiting[number,default:[]].append($0) }
    }
    func emit(_ number: Int, _ event: LANDiscoveryEvent) { sinks[number]?(event) }
    func finish(_ number: Int, _ report: LANScanReport) { pending.removeValue(forKey:number)?.resume(returning:report) }
    func stop() { for value in pending.values { value.resume(throwing:CancellationError()) }; pending = [:] }
    func ping(target:String,count:Int,timeoutSeconds:Int) throws -> [PingObservation] { throw DiagnosticError.invalid("unexpected") }
    func traceroute(target:String,maximumHops:Int,timeoutSeconds:Int) throws -> [TraceHop] { throw DiagnosticError.invalid("unexpected") }
    func dns(name:String,type:DNSRecordType,timeout:Double) throws -> [DNSRecord] { throw DiagnosticError.invalid("unexpected") }
    func ports(target:String,ports:[UInt16],timeout:Double) throws -> [PortObservation] { throw DiagnosticError.invalid("unexpected") }
    func discover(type:String,seconds:Double) throws -> [BonjourService] { throw DiagnosticError.invalid("old single-type route must not execute") }
}

@Suite("RQ33 real workbench scan/lease and late-callback boundary", .serialized)
@MainActor struct ToolboxLANWorkbenchTests {
    private func report(_ status: LANScanStatus, _ services: [LANDiscoveredService] = []) -> LANScanReport {
        .init(services:services,browsedTypes:["_http._tcp"],rejectedTypes:[],status:status,notes:[],
              truncated:false,unresolvedCount:services.filter { !$0.resolved }.count,elapsedSeconds:0.2)
    }
    @Test func sameAuthorizedServiceReceivesFrozenScopeAndRealInterfaceIndices() async throws {
        let log = LANUIProbeLog(), lease = SessionLease(ownerID:UUID()), recorder = LANRequestRecorder()
        let probe = LANDiscoveryProbe(wifiAvailable:{ _ in true }, browse:{ type, _, sink in
            await log.sawType(type)
            sink([.init(name:"device",serviceType:type,domain:"local.",interfaces:["en4"],interfaceIndices:[4]),
                  .init(name:"device",serviceType:type,domain:"local.",interfaces:["en7"],interfaceIndices:[7])])
            return .init(sawReady:true,blockedReason:nil)
        }, resolve:{ service, _ in
            await log.resolved(service.interfaceIndices)
            return ("device.local",8443,["192.0.2.10"],nil)
        })
        let service = DiagnosticService(lease:lease,authorize:{ actual, _, _ in
            await log.authorize(actual); return actual == lease
        },lanProbe:probe)
        let model = try DiagnosticWorkbenchModel(tool:.lan,service:service,onRequestState:{ _, state in recorder.states.append(state) })
        model.lanConfiguration = .init(preset:.home,browseSeconds:3)
        let run = try #require(model.run())
        model.lanConfiguration = .init(preset:.print,browseSeconds:15) // User input cannot relabel the in-flight request.
        await run.value
        #expect(Set(await log.types) == Set(LANDiscoveryScope.types(for:.home)))
        #expect(await log.interfaces == [[4,7],[4,7]])
        #expect(await log.permitted == [lease])
        #expect(model.request?.lanConfiguration?.preset == .home && model.request?.lanConfiguration?.browseSeconds == 3)
        #expect(model.lanReport?.status == .foundDevices && model.lanServices.count == 2)
        #expect(model.lanServices.allSatisfy { $0.displayAddress == "192.0.2.10" && $0.port == 8443 })
        #expect(!model.running && !model.failed && recorder.states.count == 2)
        await model.close()
    }
    @Test func cancelledLateEventsAndReportCannotOverwriteANewerResult() async throws {
        let service = LANUIControlledService(), recorder = LANRequestRecorder()
        let model = try DiagnosticWorkbenchModel(tool:.lan,service:service,onRequestState:{ _, state in recorder.states.append(state) })
        let old = try #require(model.run()); await service.wait(1)
        model.cancel()
        #expect(model.cancelled && model.lanServices.isEmpty && model.lanReport == nil)
        model.lanConfiguration = .init(preset:.web)
        let current = try #require(model.run()), id = try #require(model.request?.id); await service.wait(2)
        let fresh = LANDiscoveredService(name:"current",serviceType:"_https._tcp",domain:"local.",targetHost:"current.local",port:443,addresses:["192.0.2.20"])
        await service.emit(2,.serviceResolved(fresh)); await service.finish(2,report(.foundDevices,[fresh])); await current.value
        let stale = LANDiscoveredService(name:"old",serviceType:"_http._tcp",domain:"local.",targetHost:"old.local",port:80,addresses:["192.0.2.30"])
        await service.emit(1,.serviceResolved(stale)); await service.finish(1,report(.foundDevices,[stale])); await old.value
        for _ in 0..<4 { await Task.yield() }
        #expect(model.request?.id == id && model.lanServices.map(\.name) == ["current"])
        #expect(model.lanReport?.services.map(\.name) == ["current"] && !model.failed && !model.cancelled)
        #expect(recorder.states.count == 4) // old running/cancelled + new running/completed, never old late success.
        await model.close()
    }
    @Test func blockedPathPermissionAndScopeAreNotRecordedAsEmptySuccess() async throws {
        for status in [LANScanStatus.permissionUncertain,.noWiFiPath,.outOfScopeOnly,.noDevices] {
            let service = LANUIControlledService(), recorder = LANRequestRecorder()
            let model = try DiagnosticWorkbenchModel(tool:.lan,service:service,onRequestState:{ _, state in recorder.states.append(state) })
            let task = try #require(model.run()); await service.wait(1)
            await service.finish(1,report(status)); await task.value
            #expect(model.lanReport?.status == status && model.lanServices.isEmpty)
            let blocked = status != .noDevices
            #expect(model.failed == blocked && !model.cancelled && !model.running)
            if case .failed? = recorder.states.last { #expect(blocked) }
            else if case .completed? = recorder.states.last { #expect(!blocked) }
            else { Issue.record("The real report must reach a terminal history state") }
            await model.close()
        }
    }
    @Test func reusableInputRoundTripsAndRejectsUnboundedOrUnknownArchiveFields() throws {
        let input = LANWorkbenchConfiguration(preset:.custom,customTypes:["_http._tcp","_https._tcp"],browseSeconds:10)
        #expect(try JSONDecoder().decode(LANWorkbenchConfiguration.self,from:JSONEncoder().encode(input)) == input)
        #expect(input.requestedTypes == ["_http._tcp","_https._tcp"] && input.isValid)
        #expect(!LANWorkbenchConfiguration(preset:.custom).isValid)
        #expect(!LANWorkbenchConfiguration(browseSeconds:Double.infinity).isValid)
        #expect(throws:(any Error).self) { try JSONDecoder().decode(LANWorkbenchConfiguration.self,from:Data(#"{"preset":"made-up","customTypes":[],"browseSeconds":5}"#.utf8)) }
        #expect(throws:(any Error).self) { try JSONDecoder().decode(LANWorkbenchConfiguration.self,from:Data(#"{"preset":"custom","customTypes":["https://evil.invalid"],"browseSeconds":5}"#.utf8)) }
        let fixture = LANUIControlledService(), model = try DiagnosticWorkbenchModel(tool:.lan,service:fixture)
        model.target = "  192.0.2.10  "; #expect(model.manualTarget == "192.0.2.10" && !model.running)
        model.target = "fe80::1%7"; #expect(model.manualTarget == "fe80::1%7")
        model.target = "https://example.test/?token=secret"; #expect(model.manualTarget == nil)
    }
}
