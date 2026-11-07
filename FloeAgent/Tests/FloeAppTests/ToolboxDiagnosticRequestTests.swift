import Foundation
import Testing
import dnssd
import FloeToolboxCore
import FloeToolboxDiagnostics
import FloeToolboxWorkbenches

/// Deliberately ignores task cancellation until explicitly completed, like a
/// backend callback already in flight. No DNS/socket/external data is used.
private actor ControlledDiagnosticService: DiagnosticWorkbenchService {
    private var pending: [String:CheckedContinuation<[DNSRecord],any Error>] = [:]
    private var waiters: [String:[CheckedContinuation<Void,Never>]] = [:]
    func dns(name:String,type:DNSRecordType,timeout:Double) async throws -> [DNSRecord] {
        try await withCheckedThrowingContinuation { continuation in
            pending[name] = continuation
            for waiter in waiters.removeValue(forKey:name) ?? [] { waiter.resume() }
        }
    }
    func waitForRequest(_ name:String) async {
        if pending[name] != nil { return }
        await withCheckedContinuation { waiters[name,default:[]].append($0) }
    }
    func complete(_ name:String,with result:Result<[DNSRecord],any Error>) -> Bool {
        guard let continuation = pending.removeValue(forKey:name) else { return false }
        continuation.resume(with:result); return true
    }
    func stop() {
        let previous = pending; pending.removeAll()
        for continuation in previous.values { continuation.resume(throwing:CancellationError()) }
        for values in waiters.values { for continuation in values { continuation.resume() } }
        waiters.removeAll()
    }
    func ping(target:String,count:Int,timeoutSeconds:Int) async throws -> [PingObservation] { throw DiagnosticError.invalid("unexpected fixture operation") }
    func traceroute(target:String,maximumHops:Int,timeoutSeconds:Int) async throws -> [TraceHop] { throw DiagnosticError.invalid("unexpected fixture operation") }
    func ports(target:String,ports:[UInt16],timeout:Double) async throws -> [PortObservation] { throw DiagnosticError.invalid("unexpected fixture operation") }
    func discover(type:String,seconds:Double) async throws -> [BonjourService] { throw DiagnosticError.invalid("unexpected fixture operation") }
}

@Suite("Toolbox frozen diagnostic requests", .serialized)
@MainActor struct ToolboxDiagnosticRequestTests {
    private func address(_ name:String,_ last:UInt8 = 1) -> [DNSRecord] {
        [.init(name:name,type:.a,ttl:60,data:Data([192,0,2,last]))]
    }
    @Test(.timeLimit(.minutes(1)))
    func newFailureAndEmptyAnswerNeverReuseThePreviousSuccessfulRows() async throws {
        let service = ControlledDiagnosticService(), model = try DiagnosticWorkbenchModel(tool:.dns,service:service)
        model.target = "success.example"
        let first = try #require(model.run())
        await service.waitForRequest("success.example")
        #expect(await service.complete("success.example",with:.success(address("success.example"))))
        await first.value
        #expect(model.rows.map(\.value) == ["192.0.2.1"])
        let firstID = try #require(model.request?.id)

        model.target = "missing.invalid"
        let second = try #require(model.run())
        #expect(model.rows.isEmpty && model.failure == nil && model.running)
        #expect(model.request?.id != firstID && model.request?.target == "missing.invalid")
        await service.waitForRequest("missing.invalid")
        #expect(await service.complete("missing.invalid",with:.failure(DiagnosticError.dnsNoRecords("missing.invalid",.a))))
        await second.value
        #expect(model.failed && !model.running && model.rows.isEmpty)
        #expect(model.failure == .dnsNoRecords("missing.invalid",.a))
        // Editing the next input does not relabel the frozen failed request.
        model.target = "edited-but-not-run.example"
        #expect(model.request?.target == "missing.invalid")

        model.target = "empty.example"; model.recordType = .aaaa
        let third = try #require(model.run())
        await service.waitForRequest("empty.example")
        #expect(await service.complete("empty.example",with:.success([])))
        await third.value
        #expect(model.rows.isEmpty && model.failure == .dnsNoRecords("empty.example",.aaaa))
        #expect(model.request?.description == "AAAA · empty.example")

        model.target = "service-error.example"
        let fourth = try #require(model.run())
        await service.waitForRequest("service-error.example")
        #expect(await service.complete("service-error.example",with:.failure(DiagnosticError.system("fixture errno 57"))))
        await fourth.value
        #expect(model.rows.isEmpty && model.failure == .system("fixture errno 57"))
        await model.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledLateSuccessAndFailureCannotOverwriteANewerCompletedRequest() async throws {
        for lateFails in [false,true] {
            let service = ControlledDiagnosticService(), model = try DiagnosticWorkbenchModel(tool:.dns,service:service)
            model.target = "old.example"
            let old = try #require(model.run())
            await service.waitForRequest("old.example")
            model.cancel()
            #expect(model.cancelled && !model.running && !model.failed && model.rows.isEmpty)
            model.target = "current.example"
            let current = try #require(model.run())
            let currentID = try #require(model.request?.id)
            #expect(!model.cancelled && model.failure == nil && model.rows.isEmpty)
            await service.waitForRequest("current.example")
            #expect(await service.complete("current.example",with:.success(address("current.example",2))))
            await current.value
            let late: Result<[DNSRecord],any Error> = lateFails
                ? .failure(DiagnosticError.dnsNoRecords("old.example",.a)) : .success(address("old.example"))
            #expect(await service.complete("old.example",with:late))
            await old.value // The late callback has actually passed the model fence.
            #expect(model.request?.id == currentID && model.request?.target == "current.example")
            #expect(model.rows.map(\.value) == ["192.0.2.2"])
            #expect(!model.failed && !model.cancelled && !model.running && model.failure == nil)
            await model.close()
        }
    }

    @Test func actualDNSSDNegativeCodesHaveSpecificMeaningsAndOtherCodesStayIntact() {
        #expect(DiagnosticError.dnsServiceFailure(code:Int32(kDNSServiceErr_NoSuchName),name:"missing.invalid",type:.a) == .dnsNameNotFound("missing.invalid"))
        #expect(DiagnosticError.dnsServiceFailure(code:Int32(kDNSServiceErr_NoSuchRecord),name:"fixture.example",type:.aaaa) == .dnsNoRecords("fixture.example",.aaaa))
        #expect(DiagnosticError.dnsServiceFailure(code:Int32(kDNSServiceErr_Refused),name:"fixture.example",type:.a) == .dnsService(Int32(kDNSServiceErr_Refused)))
        #expect(DiagnosticError.dnsServiceFailure(code:-12345,name:"fixture.example",type:.a) == .dnsService(-12345))
    }

    @Test func realJSONAndTextConversionsClearPriorOutputOnInvalidInputOrFailedAction() throws {
        let model = ToolboxTextUtilityModel()
        model.input = #"{"z":[1,true,"中文"],"a":false}"#
        model.perform(.sortJSON)
        #expect(!model.failed && !model.output.isEmpty)
        let value = try #require(JSONSerialization.jsonObject(with:Data(model.output.utf8)) as? [String:Any])
        #expect(value["a"] as? Bool == false)
        let array = try #require(value["z"] as? [Any])
        #expect(array.count == 3 && array[1] as? Bool == true && array[2] as? String == "中文")
        let a = try #require(model.output.range(of:#""a""#)), z = try #require(model.output.range(of:#""z""#))
        #expect(a.lowerBound < z.lowerBound)

        model.input = #"{"a":"#
        #expect(model.output.isEmpty && !model.failed)
        model.perform(.formatJSON)
        #expect(model.failed && model.output.isEmpty && model.errorDetail != nil)

        model.input = #"{"text":"retained input"}"#
        model.perform(.compactJSON)
        #expect(!model.failed && !model.output.isEmpty)
        // Same input, different conversion failure: no didSet can hide a
        // missing clear at the actual conversion boundary.
        model.perform(.base64Decode)
        #expect(model.failed && model.output.isEmpty)
        model.perform(.formatJSON)
        #expect(!model.failed && !model.output.isEmpty)
        #expect(model.input == #"{"text":"retained input"}"#)
    }
}
