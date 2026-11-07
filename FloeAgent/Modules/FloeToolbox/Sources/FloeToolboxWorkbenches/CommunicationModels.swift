import Foundation
import SwiftUI
import FloeToolboxCore
import FloeToolboxClients

@MainActor public final class CaptureWorkbenchModel: ObservableObject {
    @Published public private(set) var records: [CaptureRecord] = []
    @Published public private(set) var dropped: UInt64 = 0
    @Published public private(set) var analysis: SerialAnalysisResult?
    @Published public var question = ""
    @Published public private(set) var analyzing = false
    @Published public private(set) var analysisCancelled = false
    @Published public private(set) var analysisTimedOut = false
    @Published public private(set) var failed = false
    @Published public private(set) var saveFailed = false
    private let journal: CaptureJournal
    private let analyzeHost: (@Sendable (String) async throws -> SerialAnalysisResult)?
    private let analysisTimeout: Duration
    private var analysisID: UUID?
    // Contract tests retain the owned task to await an actually late callback.
    internal private(set) var analysisOperation: Task<Void,Never>?
    private var analysisDeadline: Task<Void,Never>?
    private var analysisCompletion: CheckedContinuation<Void,Never>?
    public init(journal: CaptureJournal,analysisTimeout: Duration = .seconds(60),analyze: (@Sendable (String) async throws -> SerialAnalysisResult)? = nil) {
        self.journal = journal; self.analysisTimeout = analysisTimeout; analyzeHost = analyze
    }
    public func refresh() async {
        let state = await journal.snapshot(), count = state.droppedRecords+UInt64(max(0,state.records.count-200))
        if records.last?.sequence != state.records.last?.sequence || dropped != count { records = Array(state.records.suffix(200)); dropped = count }
    }
    public func analyze(defaultQuestion: String = "Analyze the current communication capture.") async {
        guard !analyzing, !Task.isCancelled else { return }
        guard let analyzeHost else { analysis = nil; failed = true; return }
        let id = UUID(), typed = question.trimmingCharacters(in:.whitespacesAndNewlines)
        let frozen = typed.isEmpty ? defaultQuestion:typed
        analysisID = id; analyzing = true; analysis = nil
        analysisCancelled = false; analysisTimedOut = false; failed = false
        await withTaskCancellationHandler {
            await withCheckedContinuation { completion in
                analysisCompletion = completion
                analysisOperation = Task { [weak self] in
                    do {
                        let result = try await analyzeHost(frozen)
                        guard let self, self.analysisID == id, !Task.isCancelled else { return }
                        self.analysis = result; self.finishAnalysis(id)
                    } catch {
                        guard let self, self.analysisID == id else { return }
                        self.analysisCancelled = error is CancellationError || Task.isCancelled
                        self.failed = !self.analysisCancelled; self.finishAnalysis(id)
                    }
                }
                let timeout = analysisTimeout
                analysisDeadline = Task { [weak self] in
                    do { try await Task.sleep(for:timeout) } catch { return }
                    guard let self, self.analysisID == id else { return }
                    self.analysisTimedOut = true; self.failed = true
                    self.analysisOperation?.cancel(); self.finishAnalysis(id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelAnalysis(id: id) }
        }
    }
    public func cancelAnalysis() { if let id = analysisID { cancelAnalysis(id:id) } }
    private func cancelAnalysis(id:UUID) {
        guard analysisID == id else { return }
        analysisOperation?.cancel(); analysis = nil; failed = false
        analysisCancelled = true; analysisTimedOut = false; finishAnalysis(id)
    }
    private func finishAnalysis(_ id:UUID) {
        guard analysisID == id else { return }
        analysisID = nil; analyzing = false; analysisOperation = nil
        analysisDeadline?.cancel(); analysisDeadline = nil
        let completion = analysisCompletion; analysisCompletion = nil; completion?.resume()
    }
    public func save() async -> URL? {
        do { let value = try await journal.saveSnapshot(); saveFailed = false; return value } catch { saveFailed = true; return nil }
    }
    public func export() async -> Data? {
        do { let value = try await journal.exportJSONLines(); saveFailed = false; return value } catch { saveFailed = true; return nil }
    }
}
@MainActor public final class HTTPWorkbenchModel: ObservableObject {
    @Published public var url: String
    @Published public var method = "GET"
    @Published public var headers = ""
    @Published public var body = ""
    @Published public private(set) var reply: HTTPClientReply?
    @Published public private(set) var busy = false
    @Published public private(set) var failed = false
    public let capture: CaptureWorkbenchModel
    private let session: HTTPDebugSession
    public init(session: HTTPDebugSession,targetURL: URL,journal: CaptureJournal,provider: (any SerialAnalysisProvider)? = nil) {
        self.session = session; url = targetURL.absoluteString
        if let provider { capture = CaptureWorkbenchModel(journal:journal,analyze:{ question in try await session.analyze(question:question,expected:session.lease,provider:provider) }) }
        else { capture = CaptureWorkbenchModel(journal:journal) }
    }
    public func send() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            guard let target = URL(string:url), headers.utf8.count <= 65536 else { throw ClientError.invalidConfiguration }
            var fields: [String:String] = [:], names: Set<String> = []
            for line in headers.split(whereSeparator:\.isNewline) {
                guard let colon = line.firstIndex(of:":") else { throw ClientError.invalidConfiguration }
                let name = String(line[..<colon]).trimmingCharacters(in:.whitespaces), value = String(line[line.index(after:colon)...]).trimmingCharacters(in:.whitespaces)
                guard names.insert(name.lowercased()).inserted else { throw ClientError.invalidConfiguration }; fields[name] = value
            }
            reply = try await session.send(HTTPClientRequest(url:target,method:method,headers:fields,body:body.isEmpty ? nil : Data(body.utf8)),expected:session.lease)
            failed = false; await capture.refresh()
        } catch HTTPClientFailure.responseLimit(let partial) { reply = partial; failed = true; await capture.refresh() }
        catch { failed = true; await capture.refresh() }
    }
    public func close() async { capture.cancelAnalysis(); await session.close() }
}
@MainActor public final class WebSocketWorkbenchModel: ObservableObject {
    @Published public var input = ""
    @Published public var binary = false
    @Published public private(set) var sending = false
    @Published public private(set) var receiving = false
    @Published public private(set) var failed = false
    public let capture: CaptureWorkbenchModel
    private let session: SerialSession
    public init(session: SerialSession,journal: CaptureJournal,provider: (any SerialAnalysisProvider)? = nil) throws {
        guard session.endpoint.transport == .webSocket else { throw ClientError.invalidConfiguration }; self.session = session
        if let provider { capture = CaptureWorkbenchModel(journal:journal,analyze:{ question in try await session.analyze(question:question,expected:session.lease,provider:provider) }) }
        else { capture = CaptureWorkbenchModel(journal:journal) }
    }
    public func send() async {
        guard !sending else { return }; sending = true; defer { sending = false }
        do { let payload: SerialPayload = binary ? .bytes(try Data(hex:input)) : .text(input); try await session.sendMessage(payload,expected:session.lease); failed = false; await capture.refresh() }
        catch { failed = true; await capture.refresh() }
    }
    public func receive() async {
        guard !receiving else { return }; receiving = true; defer { receiving = false }
        do { _ = try await session.receiveMessage(expected:session.lease); failed = false; await capture.refresh() }
        catch { failed = true }
    }
    public func close() async { capture.cancelAnalysis(); await session.close() }
}
@MainActor public final class MQTTWorkbenchModel: ObservableObject {
    @Published public var topic = ""
    @Published public var payload = ""
    @Published public var filter = ""
    @Published public var qos = MQTTQoS.atMostOnce
    @Published public var retained = false
    @Published public var binary = false
    @Published public private(set) var busy = false
    @Published public private(set) var failed = false
    @Published public private(set) var messages: [MQTTMessage] = []
    @Published public private(set) var dropped: UInt64 = 0
    public let capture: CaptureWorkbenchModel
    private let client: MQTTClient
    private var localDropped: UInt64 = 0
    private var updates: Task<Void,Never>?
    public init(client: MQTTClient,journal: CaptureJournal,provider: (any SerialAnalysisProvider)? = nil) {
        self.client = client
        if let provider { let session = client.session; capture = CaptureWorkbenchModel(journal:journal,analyze:{ question in try await session.analyze(question:question,expected:session.lease,provider:provider) }) }
        else { capture = CaptureWorkbenchModel(journal:journal) }
        updates = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refresh()
                do { try await Task.sleep(for:.milliseconds(250)) } catch { return }
            }
        }
    }
    public func publish() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await client.publish(topic:topic,payload:binary ? Data(hex:payload) : Data(payload.utf8),qos:qos,retained:retained); failed = false; await refresh() } catch { failed = true }
    }
    public func subscribe() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { _ = try await client.subscribe(filter,qos:qos); failed = false; await refresh() } catch { failed = true }
    }
    public func unsubscribe() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await client.unsubscribe(filter); failed = false; await refresh() } catch { failed = true }
    }
    public func refresh() async {
        let batch = await client.drainMessages(); if !batch.messages.isEmpty { messages += batch.messages }; let excess = max(0,messages.count-200)
        if excess > 0 { messages.removeFirst(excess); localDropped += UInt64(excess) }; let totalDropped = batch.dropped+localDropped; if dropped != totalDropped { dropped = totalDropped }; await capture.refresh()
    }
    public func close() async { capture.cancelAnalysis(); updates?.cancel(); updates = nil; await client.disconnect() }
    deinit { updates?.cancel() }
}
