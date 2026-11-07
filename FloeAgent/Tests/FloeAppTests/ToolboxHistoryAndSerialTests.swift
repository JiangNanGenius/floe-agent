// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeToolboxCore
import FloeToolboxDiagnostics
import FloeToolboxClients
import FloeToolboxUI
import FloeToolboxWorkbenches
@testable import FloeApp

private actor HistoryDiagnosticFixture: DiagnosticWorkbenchService {
    private var held: CheckedContinuation<[DNSRecord], any Error>?
    private var started: [CheckedContinuation<Void, Never>] = []
    func dns(name: String, type: DNSRecordType, timeout: Double) async throws -> [DNSRecord] {
        if name == "late.example" {
            return try await withCheckedThrowingContinuation { continuation in
                held = continuation; let previous = started; started.removeAll(); previous.forEach { $0.resume() }
            }
        }
        if name == "missing.example" { throw DiagnosticError.dnsNoRecords(name, type) }
        return [.init(name: name, type: .a, ttl: 60, data: Data([192, 0, 2, 1]))]
    }
    func waitUntilHeld() async { if held == nil { await withCheckedContinuation { started.append($0) } } }
    func finishLate() { held?.resume(returning: [.init(name: "late.example", type: .a, ttl: 60, data: Data([192, 0, 2, 2]))]); held = nil }
    func ping(target: String, count: Int, timeoutSeconds: Int) throws -> [PingObservation] { throw DiagnosticError.invalid("unexpected") }
    func traceroute(target: String, maximumHops: Int, timeoutSeconds: Int) throws -> [TraceHop] { throw DiagnosticError.invalid("unexpected") }
    func ports(target: String, ports: [UInt16], timeout: Double) throws -> [PortObservation] { throw DiagnosticError.invalid("unexpected") }
    func discover(type: String, seconds: Double) throws -> [BonjourService] { throw DiagnosticError.invalid("unexpected") }
    func stop() { held?.resume(throwing: CancellationError()); held = nil }
}

private actor HistorySerialFixture: SerialConnection {
    private(set) var sent: [Data] = []
    func send(_ bytes: Data) { sent.append(bytes) }
    func receive(maximumBytes: Int) -> Data { Data() }
    func close() { }
}

@Suite("Reusable Toolbox history and serial controls", .serialized)
@MainActor struct ToolboxHistoryAndSerialTests {
    private func root() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Local/Scratch/toolbox-history-\(UUID())")
    }
    private func request(_ tool: ToolboxTool, _ target: String) -> DiagnosticRequestSnapshot {
        .init(id: UUID(), tool: tool, target: target, ports: "80, 443", recordType: .aaaa, serviceType: "_http._tcp")
    }
    @Test func explicitWhitelistDropsCredentialsURLSecretsAndDeviceIdentity() throws {
        var setup = ToolboxConnectionSetup()
        setup.address = "https://account:secret@example.test:8443/api/secret-path?token=secret-query#private"
        setup.username = "account"; setup.password = "secret-password"
        let http = try #require(ToolboxHistoryConfiguration.connection(tool: .http, setup: setup))
        #expect(http.target == "https://example.test:8443")
        let restored = try #require(http.connectionSetup())
        #expect(restored.username.isEmpty && restored.password.isEmpty && restored.usbRequest == nil && restored.bluetooth == nil)
        let encoded = String(decoding: try JSONEncoder().encode(http), as: UTF8.self)
        for secret in ["account", "secret", "token", "query", "private"] { #expect(!encoded.contains(secret)) }
        setup.address = "192.0.2.1"; setup.port = "1883"
        let mqtt = try #require(ToolboxHistoryConfiguration.connection(tool: .mqtt, setup: setup))
        #expect(mqtt.connectionSetup()?.password.isEmpty == true)
        setup.serial.connection = .usb; setup.usbBaud = "230400"
        let usb = try #require(ToolboxHistoryConfiguration.connection(tool: .serialAssistant, setup: setup))
        #expect(usb.target.isEmpty && usb.port.isEmpty && usb.usbBaud == "230400")
        #expect(usb.connectionSetup()?.usbRequest == nil && usb.connectionSetup()?.bluetooth == nil)
        #expect(ToolboxHistoryConfiguration.diagnostic(request(.ping, "https://example.test/?token=secret")) == nil)
    }
    @Test func persistentPartitionedHistoryDedupePinDeleteClearAndLateFinish() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json"), store = ToolboxHistoryStore(fileURL: file)
        let ping = try #require(ToolboxHistoryConfiguration.diagnostic(request(.ping, "baidu.com")))
        let first = try #require(store.begin(ping)); store.finish(first, outcome: .completed)
        let pingID = try #require(store.records(for: .ping).first?.id); store.togglePin(pingID)
        let second = try #require(store.begin(ping)); store.finish(first, outcome: .failed)
        #expect(store.records(for: .ping).count == 1 && store.records(for: .ping).first?.outcome == .started)
        store.finish(second, outcome: .failed)
        #expect(store.records(for: .ping).first?.uses == 2 && store.records(for: .ping).first?.pinned == true)
        let dns = try #require(ToolboxHistoryConfiguration.diagnostic(request(.dns, "example.test")))
        let dnsAttempt = try #require(store.begin(dns))
        let reloaded = ToolboxHistoryStore(fileURL: file)
        #expect(!reloaded.persistenceFailed && reloaded.records(for: .ping).first?.outcome == .failed)
        #expect(reloaded.records(for: .dns).first?.outcome == .interrupted)
        store.clear(.ping)
        #expect(store.records(for: .ping).isEmpty && store.records(for: .dns).count == 1)
        let dnsID = try #require(store.records(for: .dns).first?.id); store.delete(dnsID)
        store.finish(dnsAttempt, outcome: .completed)
        #expect(store.entries.isEmpty && ToolboxHistoryStore(fileURL: file).entries.isEmpty)
    }
    @Test func boundedHistoryRetainsPinnedTargetsWithoutGrowingOrOverwritingBadArchives() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json"), store = ToolboxHistoryStore(fileURL: file)
        let first = try #require(ToolboxHistoryConfiguration.diagnostic(request(.ping, "pinned.example")))
        store.begin(first); store.togglePin(try #require(store.records(for: .ping).first?.id))
        for number in 0..<40 { store.begin(ToolboxHistoryConfiguration.diagnostic(request(.ping, "host\(number).example"))) }
        #expect(store.records(for: .ping).count == 32 && store.records(for: .ping).first?.configuration.target == "pinned.example")
        let damaged = Data("not an archive".utf8); try damaged.write(to: file)
        let broken = ToolboxHistoryStore(fileURL: file); broken.begin(first)
        let retainedBytes = try Data(contentsOf: file)
        #expect(broken.persistenceFailed && retainedBytes == damaged)
    }
    @Test(.timeLimit(.minutes(1))) func actualDiagnosticCallbacksRecordFastFailureAndCancelWithoutLateSuccess() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let history = ToolboxHistoryStore(fileURL: directory.appendingPathComponent("history.json")), backend = HistoryDiagnosticFixture()
        let model = try DiagnosticWorkbenchModel(tool: .dns, service: backend, onRequestState: { request, state in
            switch state {
            case .running: history.begin(.diagnostic(request), attemptID: request.id)
            case .completed: history.finish(request.id, outcome: .completed)
            case .failed: history.finish(request.id, outcome: .failed)
            case .cancelled: history.finish(request.id, outcome: .cancelled)
            }
        })
        model.target = "example.test"; await (try #require(model.run())).value
        #expect(history.records(for: .dns).first?.outcome == .completed)
        model.target = "missing.example"; await (try #require(model.run())).value
        #expect(history.records(for: .dns).first?.outcome == .failed)
        model.target = "late.example"; let late = try #require(model.run()); await backend.waitUntilHeld()
        model.cancel(); #expect(history.records(for: .dns).first?.outcome == .cancelled)
        await backend.finishLate(); await late.value
        #expect(history.records(for: .dns).first?.outcome == .cancelled && model.cancelled)
        await model.close()
    }
    @Test func textAndHEXNewlineEncodingAreExactAndRejectInvalidPayloads() throws {
        #expect(try SerialPayloadEncoding.encode("中文", hexadecimal: false, lineEnding: .crlf) == Data("中文\r\n".utf8))
        #expect(try SerialPayloadEncoding.encode("01 03 00 FF", hexadecimal: true, lineEnding: .crlf) == Data([1, 3, 0, 255]))
        #expect(throws: (any Error).self) { try SerialPayloadEncoding.encode("GG", hexadecimal: true, lineEnding: .none) }
        #expect(throws: (any Error).self) { try SerialPayloadEncoding.encode(String(repeating: "a", count: 256 * 1024 + 1), hexadecimal: false, lineEnding: .none) }
    }
    @Test func realSessionSendClearDisplayAndInvalidationKeepOriginalCapture() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let lease = SessionLease(ownerID: UUID()), connection = HistorySerialFixture()
        let journal = try await CaptureJournal(ownerID: lease.ownerID, captureID: lease.sessionID,
            repository: FileCaptureRepository(root: directory), limits: CaptureLimits())
        let session = try SerialSession(lease: lease, endpoint: SerialEndpoint(title: "fixture", transport: .tcp, host: "192.0.2.1", port: 9000),
            journal: journal, connection: connection, authorize: { _ in true })
        let model = SerialPanelModel(session: session, journal: journal, provider: nil)
        model.input = "hello"; model.lineEnding = .lf; model.clearAfterSending = true; await model.send()
        #expect(await connection.sent == [Data("hello\n".utf8)])
        #expect(model.input.isEmpty && model.visibleRecords.count == 1)
        model.clearDisplay(); #expect(model.visibleRecords.isEmpty)
        #expect(await journal.snapshot().records.count == 1)
        model.input = "01 FF"; model.hexadecimal = true; await model.send()
        #expect(await connection.sent == [Data("hello\n".utf8), Data([1, 255])])
        #expect(model.visibleRecords.count == 1)
        model.invalidate(); model.input = "not sent"; await model.send()
        #expect(await connection.sent.count == 2 && !model.active)
        await session.close()
    }
}
#endif
