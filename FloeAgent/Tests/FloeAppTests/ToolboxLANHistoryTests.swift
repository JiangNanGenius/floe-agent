#if canImport(UIKit)
import Foundation
import Testing
import FloeToolboxCore
import FloeToolboxDiagnostics
import FloeToolboxWorkbenches
@testable import FloeApp

private actor LANHistoryReadOnlyService: DiagnosticWorkbenchService {
    private(set) var invocations = 0
    func lanScan(types:[String],seconds:Double,onEvent:(@Sendable(LANDiscoveryEvent)->Void)?) throws -> LANScanReport { invocations += 1; throw DiagnosticError.invalid("unexpected implicit execution") }
    func ping(target:String,count:Int,timeoutSeconds:Int) throws -> [PingObservation] { throw DiagnosticError.invalid("unexpected") }
    func traceroute(target:String,maximumHops:Int,timeoutSeconds:Int) throws -> [TraceHop] { throw DiagnosticError.invalid("unexpected") }
    func dns(name:String,type:DNSRecordType,timeout:Double) throws -> [DNSRecord] { throw DiagnosticError.invalid("unexpected") }
    func ports(target:String,ports:[UInt16],timeout:Double) throws -> [PortObservation] { throw DiagnosticError.invalid("unexpected") }
    func discover(type:String,seconds:Double) throws -> [BonjourService] { throw DiagnosticError.invalid("unexpected") }
    func stop() {}
}

@Suite("RQ33 same history archive and explicit scan input", .serialized)
@MainActor struct ToolboxLANHistoryTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FloeLANUIHistory-\(UUID())",isDirectory:true)
    }
    @Test func savedScopeAndDurationReopenAndPrefillWithoutRunning() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at:directory) }
        let file = directory.appendingPathComponent("history.json")
        let store = ToolboxHistoryStore(fileURL:file), configuration = LANWorkbenchConfiguration(preset:.print,browseSeconds:10)
        let snapshot = DiagnosticRequestSnapshot(id:UUID(),tool:.lan,target:"not stored as an automatic check",ports:"80",recordType:.a,serviceType:"_http._tcp",lanConfiguration:configuration)
        let reusable = try #require(ToolboxHistoryConfiguration.diagnostic(snapshot))
        let attempt = try #require(store.begin(reusable)); store.finish(attempt,outcome:.completed)
        let reloaded = ToolboxHistoryStore(fileURL:file), row = try #require(reloaded.records(for:.lan).first)
        #expect(!reloaded.persistenceFailed && row.configuration.lanConfiguration == configuration && row.configuration.target.isEmpty)
        let service = LANHistoryReadOnlyService(), model = try DiagnosticWorkbenchModel(tool:.lan,service:service)
        row.configuration.apply(to:model)
        #expect(model.lanConfiguration == configuration && !model.running && model.request == nil)
        #expect(await service.invocations == 0)
        await model.close()
    }
    @Test func legacySingleTypeArchiveRemainsReadableAndMapsToExplicitCustomScope() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at:directory) }
        let file = directory.appendingPathComponent("history.json"), store = ToolboxHistoryStore(fileURL:file)
        let snapshot = DiagnosticRequestSnapshot(id:UUID(),tool:.lan,target:"",ports:"",recordType:.a,serviceType:"_http._tcp")
        let attempt = try #require(store.begin(ToolboxHistoryConfiguration.diagnostic(snapshot))); store.finish(attempt,outcome:.completed)
        // Actual version1 bytes without the new optional field, as already saved by previous Apps.
        let bytes = try Data(contentsOf:file)
        #expect(!String(decoding:bytes,as:UTF8.self).contains("lanConfiguration"))
        let reloaded = ToolboxHistoryStore(fileURL:file), row = try #require(reloaded.records(for:.lan).first)
        let service = LANHistoryReadOnlyService(), model = try DiagnosticWorkbenchModel(tool:.lan,service:service)
        row.configuration.apply(to:model)
        #expect(!reloaded.persistenceFailed && row.configuration.lanConfiguration == nil)
        #expect(model.lanConfiguration.preset == .custom && model.lanConfiguration.requestedTypes == ["_http._tcp"] && model.lanConfiguration.browseSeconds == 3)
        #expect(await service.invocations == 0 && !model.running)
        await model.close()
    }
}
#endif
