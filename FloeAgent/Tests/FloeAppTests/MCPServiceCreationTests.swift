#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloePersistence
@testable import FloeApp

private actor MCPServiceTestGate {
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = false
    func wait() async {
        entered = true
        if opened { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func open() {
        opened = true
        let pending = continuations; continuations = []
        for item in pending { item.resume() }
    }
}

private actor MCPServiceTestSettings: SettingsStore {
    private var values: [String: String] = [:]
    private var nextGate: MCPServiceTestGate?
    private var failWrites = 0
    func failNextWrite() { failWrites += 1 }
    func holdNextWrite(_ gate: MCPServiceTestGate) { nextGate = gate }
    func value(forKey key: String) async throws -> String? { values[key] }
    func setValue(_ json: String, forKey key: String) async throws {
        let gate = nextGate; nextGate = nil
        if let gate { await gate.wait() }
        if failWrites > 0 { failWrites -= 1; throw FloeError.storageCorrupted("Fixture write failed") }
        values[key] = json
    }
    func removeValue(forKey key: String) async throws { values[key] = nil }
    func allValues() async throws -> [String: String] { values }
}

@MainActor
private final class MCPServiceTestBackend: MCPServiceCreationBackend {
    var generationGate: MCPServiceTestGate?
    var verificationGate: MCPServiceTestGate?
    var stopGate: MCPServiceTestGate?
    var saveGate: MCPServiceTestGate?
    var forgedReceipt = false
    var failSave = false
    var stopFailuresRemaining = 0
    var savedIDs: Set<UUID> = []
    var onSaveCommit: (() async -> Void)?
    var calls: [(String, MCPServiceCreationRecord)] = []
    let buildID = UUID(), serviceID = UUID()

    func resolve(_ record: MCPServiceCreationRecord) async throws -> MCPServiceCreationBinding {
        calls.append(("resolve", record))
        return .init(root: URL(fileURLWithPath: "/fixture/project"), projectRelativePath: "MCPServices/" + record.id.uuidString,
                     providerID: UUID(), modelID: UUID(), modelName: "Configured model")
    }
    func prepare(_ record: MCPServiceCreationRecord, template: MCPServiceTemplate.VerifiedPackage) async throws {
        calls.append(("prepare", record))
    }
    func generate(_ record: MCPServiceCreationRecord) async throws {
        calls.append(("generate", record))
        if let generationGate { await generationGate.wait() }
    }
    func submitBuild(_ record: MCPServiceCreationRecord) async throws -> UUID {
        calls.append(("submitBuild", record)); return buildID
    }
    func waitForBuild(_ record: MCPServiceCreationRecord) async throws { calls.append(("waitBuild", record)) }
    func submitService(_ record: MCPServiceCreationRecord) async throws -> UUID {
        calls.append(("submitService", record)); return serviceID
    }
    func waitForEndpoint(_ record: MCPServiceCreationRecord) async throws -> URL {
        calls.append(("endpoint", record)); return URL(string: "http://127.0.0.1:8080/mcp")!
    }
    func verify(_ record: MCPServiceCreationRecord, endpoint: URL) async throws -> MCPServiceCreationReceipt {
        calls.append(("verify", record))
        if let verificationGate { await verificationGate.wait() }
        return .init(conversationID: forgedReceipt ? UUID() : record.conversationID,
                     runID: record.runID, serviceJobID: serviceID,
                     environmentID: record.request.environmentID, endpoint: endpoint,
                     smokeDigest: String(repeating: "a", count: 64), verifiedAt: Date())
    }
    func saveConnection(_ record: MCPServiceCreationRecord) async throws -> UUID {
        calls.append(("save", record))
        if let saveGate { await saveGate.wait() }
        if failSave { throw FloeError.validationFailed("Fixture save failed") }
        savedIDs.insert(record.connectionID)
        await onSaveCommit?()
        return record.connectionID
    }
    func savedConnectionID(_ record: MCPServiceCreationRecord) -> UUID? {
        savedIDs.contains(record.connectionID) ? record.connectionID : nil
    }
    func stop(_ record: MCPServiceCreationRecord) async throws {
        calls.append(("stop", record))
        if let stopGate { await stopGate.wait() }
        if stopFailuresRemaining > 0 {
            stopFailuresRemaining -= 1
            throw FloeError.validationFailed("Fixture stop failed")
        }
        await generationGate?.open(); await verificationGate?.open()
    }
    func release(_ record: MCPServiceCreationRecord) { calls.append(("release", record)) }
}

@Suite("MCP service creation lifecycle")
@MainActor
struct MCPServiceCreationTests {
    private func request() -> MCPServiceCreationRequest {
        .init(name: "Test service", details: "Create a read-only status tool",
              workspaceID: UUID(), environmentID: "selected-project", port: 8080)
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await condition())
    }
    private func coordinator(_ backend: MCPServiceTestBackend, _ settings: MCPServiceTestSettings = .init()) -> MCPServiceCreationCoordinator {
        MCPServiceCreationCoordinator(backend: backend, settings: settings)
    }

    @Test("Preparation persists the owner before the first model or job action")
    func persistentOwnerBeforeExecution() async throws {
        let settings = MCPServiceTestSettings(), backend = MCPServiceTestBackend()
        let gate = MCPServiceTestGate(); backend.generationGate = gate
        let center = coordinator(backend, settings)
        await center.start(request())
        try await wait { backend.calls.contains { $0.0 == "generate" } }
        let record = try #require(center.selected)
        let values = try await settings.allValues()
        let persisted = try #require(values["mcp.creation.operation." + record.id.uuidString])
        let decoded = try JSONDecoder().decode(MCPServiceCreationRecord.self, from: Data(persisted.utf8))
        #expect(decoded.runID == record.runID)
        #expect(decoded.binding != nil)
        #expect(decoded.phase == .generating)
        await center.cancelSelected()
    }

    @Test("Every stage keeps the same task, run, environment and project")
    func sameOwnerThroughout() async throws {
        let backend = MCPServiceTestBackend(), center = coordinator(backend)
        await center.start(request()); try await wait { center.selected?.phase == .ready }
        let record = try #require(center.selected)
        #expect(backend.calls.map(\.0) == ["resolve", "prepare", "generate", "submitBuild", "waitBuild", "submitService", "endpoint", "verify"])
        #expect(backend.calls.allSatisfy { $0.1.id == record.id && $0.1.conversationID == record.conversationID
            && $0.1.runID == record.runID && $0.1.request == record.request })
        #expect(record.buildJobID == backend.buildID)
        #expect(record.serviceJobID == backend.serviceID)
        await center.cancelSelected()
    }

    @Test("Listener readiness cannot make a connection addable before native verification")
    func actualVerificationRequired() async throws {
        let backend = MCPServiceTestBackend(), gate = MCPServiceTestGate()
        backend.verificationGate = gate
        let center = coordinator(backend)
        await center.start(request()); try await wait { center.selected?.phase == .verifying }
        #expect(center.selected?.canSave == false)
        await center.saveSelected()
        #expect(!backend.calls.contains { $0.0 == "save" })
        await gate.open(); try await wait { center.selected?.phase == .ready }
        #expect(center.selected?.canSave == true)
        await center.cancelSelected()
    }

    @Test("A receipt for a different owner is rejected instead of displaying Ready")
    func foreignReceiptRejected() async throws {
        let backend = MCPServiceTestBackend(); backend.forgedReceipt = true
        let center = coordinator(backend)
        await center.start(request()); try await wait { center.selected?.phase == .failed }
        #expect(center.selected?.canSave == false)
        #expect(center.selected?.receipt == nil)
        await center.saveSelected()
        #expect(!backend.calls.contains { $0.0 == "save" })
        await center.cancelSelected()
    }

    @Test("Cancel retains ownership until the existing backend confirms cleanup")
    func cancelWaitsForSettlement() async throws {
        let backend = MCPServiceTestBackend(), generation = MCPServiceTestGate(), stopping = MCPServiceTestGate()
        backend.generationGate = generation; backend.stopGate = stopping
        let center = coordinator(backend)
        await center.start(request()); try await wait { center.selected?.phase == .generating }
        let cancellation = Task { await center.cancelSelected() }
        try await wait { center.selected?.phase == .stopping }
        #expect(!backend.calls.contains { $0.0 == "release" })
        await stopping.open(); await cancellation.value
        #expect(center.selected?.phase == .stopped)
        #expect(backend.calls.last?.0 == "release")
        #expect(!backend.calls.contains { $0.0 == "submitBuild" })
    }

    @Test("A failed stop preserves ownership and permits a second explicit stop")
    func failedStopCanBeRetried() async throws {
        let backend = MCPServiceTestBackend()
        backend.stopFailuresRemaining = 1
        let center = coordinator(backend)
        await center.start(request()); try await wait { center.selected?.phase == .ready }
        let owner = try #require(center.selected)
        await center.cancelSelected()
        #expect(center.selected?.phase == .stopping)
        #expect(!center.isStopping)
        #expect(center.isWorking)
        #expect(center.selected?.canSave == false)
        #expect(center.actionError != nil)
        #expect(!backend.calls.contains { $0.0 == "release" })
        #expect(center.selected?.id == owner.id)
        #expect(center.selected?.serviceJobID == owner.serviceJobID)
        await center.cancelSelected()
        #expect(center.selected?.phase == .stopped)
        #expect(!center.isStopping)
        #expect(!center.isWorking)
        #expect(center.actionError == nil)
        #expect(backend.calls.filter { $0.0 == "stop" }.count == 2)
        #expect(backend.calls.filter { $0.0 == "release" }.count == 1)
    }

    @Test("An in-flight stop rejects reentry without duplicating cleanup")
    func inFlightStopHasSingleOwner() async throws {
        let backend = MCPServiceTestBackend(), gate = MCPServiceTestGate()
        backend.stopGate = gate
        let center = coordinator(backend)
        await center.start(request()); try await wait { center.selected?.phase == .ready }
        let first = Task { await center.cancelSelected() }
        try await wait { await gate.entered }
        #expect(center.isStopping)
        await center.cancelSelected()
        #expect(center.isStopping)
        #expect(backend.calls.filter { $0.0 == "stop" }.count == 1)
        #expect(!backend.calls.contains { $0.0 == "release" })
        await gate.open(); await first.value
        #expect(center.selected?.phase == .stopped)
        #expect(!center.isStopping)
        #expect(backend.calls.filter { $0.0 == "stop" }.count == 1)
        #expect(backend.calls.filter { $0.0 == "release" }.count == 1)
    }

    @Test("A late verification callback cannot publish Ready after cancellation")
    func lateCallbackFenced() async throws {
        let backend = MCPServiceTestBackend(), gate = MCPServiceTestGate()
        backend.verificationGate = gate
        let center = coordinator(backend)
        await center.start(request()); try await wait { center.selected?.phase == .verifying }
        await center.cancelSelected()
        #expect(center.selected?.phase == .stopped)
        #expect(center.selected?.canSave == false)
        #expect(!backend.calls.contains { $0.0 == "save" })
    }

    @Test("Closing an observer has no stop or replay side effect")
    func observerReentryDoesNotRestart() async throws {
        let backend = MCPServiceTestBackend(), gate = MCPServiceTestGate()
        backend.generationGate = gate
        let center = coordinator(backend)
        await center.start(request()); try await wait { center.selected?.phase == .generating }
        let id = try #require(center.selectedID)
        center.select(id)
        center.resumeSelected()
        #expect(backend.calls.filter { $0.0 == "generate" }.count == 1)
        #expect(!backend.calls.contains { $0.0 == "stop" })
        await center.cancelSelected()
    }

    @Test("Cold restore preserves IDs but does not pretend a cached readiness receipt is live")
    func recoveryIsHonest() async throws {
        let settings = MCPServiceTestSettings(), backend = MCPServiceTestBackend()
        let center = coordinator(backend, settings)
        await center.start(request()); try await wait { center.selected?.phase == .ready }
        let previous = try #require(center.selected)
        let restoredBackend = MCPServiceTestBackend(), restored = coordinator(restoredBackend, settings)
        await restored.load()
        #expect(restored.selected?.id == previous.id)
        #expect(restored.selected?.runID == previous.runID)
        #expect(restored.selected?.phase == .interrupted)
        #expect(restored.selected?.canSave == false)
        #expect(restoredBackend.calls.isEmpty)
        await center.cancelSelected()
    }

    @Test("Saving is exactly one existing-manager commit and its receipt wins concurrent Cancel")
    func saveCommitWinsCancel() async throws {
        let backend = MCPServiceTestBackend(), gate = MCPServiceTestGate()
        backend.saveGate = gate
        let center = coordinator(backend)
        await center.start(request()); try await wait { center.selected?.phase == .ready }
        let saving = Task { await center.saveSelected() }
        try await wait { backend.calls.contains { $0.0 == "save" } }
        let cancel = Task { await center.cancelSelected() }
        try await wait { center.selected?.phase == .stopping }
        await gate.open(); await saving.value; await cancel.value
        #expect(center.selected?.phase == .added)
        #expect(center.selected?.savedConnectionID == center.selected?.connectionID)
        #expect(backend.calls.filter { $0.0 == "save" }.count == 1)
        #expect(!backend.calls.contains { $0.0 == "stop" })
    }

    @Test("A failed manager save cannot become an Added result")
    func failedSave() async throws {
        let backend = MCPServiceTestBackend(); backend.failSave = true
        let center = coordinator(backend)
        await center.start(request()); try await wait { center.selected?.phase == .ready }
        await center.saveSelected()
        #expect(center.selected?.phase == .failed)
        #expect(center.selected?.savedConnectionID == nil)
        #expect(center.selected?.error != nil)
        await center.cancelSelected()
    }

    @Test("A real manager commit is retained even if the later feature metadata write fails")
    func commitSurvivesMetadataFailure() async throws {
        let settings = MCPServiceTestSettings(), backend = MCPServiceTestBackend()
        backend.onSaveCommit = { await settings.failNextWrite() }
        let center = coordinator(backend, settings)
        await center.start(request()); try await wait { center.selected?.phase == .ready }
        await center.saveSelected()
        #expect(center.selected?.phase == .added)
        #expect(center.selected?.savedConnectionID == center.selected?.connectionID)
        #expect(center.actionError != nil)
        #expect(backend.calls.filter { $0.0 == "save" }.count == 1)
    }

    @Test("Relaunch reconciles a committed manager entry without replaying model, jobs or save")
    func committedEntryRecovery() async throws {
        let settings = MCPServiceTestSettings(), backend = MCPServiceTestBackend()
        let center = coordinator(backend, settings)
        await center.start(request()); try await wait { center.selected?.phase == .ready }
        var record = try #require(center.selected)
        record.phase = .saving
        try await settings.setValue(record, forKey: "mcp.creation.operation." + record.id.uuidString)
        let restoredBackend = MCPServiceTestBackend()
        restoredBackend.savedIDs.insert(record.connectionID)
        let restored = coordinator(restoredBackend, settings)
        await restored.load()
        #expect(restored.selected?.phase == .added)
        #expect(restored.selected?.savedConnectionID == record.connectionID)
        #expect(restoredBackend.calls.isEmpty)
    }

    @Test("Two taps while initial persistence is suspended cannot launch two operations")
    func initialWriteRace() async throws {
        let settings = MCPServiceTestSettings(), backend = MCPServiceTestBackend(), gate = MCPServiceTestGate()
        await settings.holdNextWrite(gate)
        let center = coordinator(backend, settings)
        let first = Task { await center.start(request()) }
        try await wait { await gate.entered }
        await center.start(request())
        #expect(center.records.count == 1)
        #expect(backend.calls.isEmpty)
        await gate.open(); await first.value
        try await wait { center.selected?.phase == .ready }
        #expect(backend.calls.filter { $0.0 == "generate" }.count == 1)
        await center.cancelSelected()
    }

    @Test("A confirmed service end revokes Ready instead of keeping a stale Add action")
    func serviceEndRevokesReady() async throws {
        let backend = MCPServiceTestBackend(), center = coordinator(backend)
        await center.start(request()); try await wait { center.selected?.phase == .ready }
        let record = try #require(center.selected)
        await center.receive(.init(operationID: record.id, jobID: backend.serviceID, kind: .ended))
        #expect(center.selected?.phase == .failed)
        #expect(center.selected?.canSave == false)
        await center.cancelSelected()
    }

    @Test("A late event for another service cannot alter the selected operation")
    func foreignServiceEventIgnored() async throws {
        let backend = MCPServiceTestBackend(), center = coordinator(backend)
        await center.start(request()); try await wait { center.selected?.phase == .ready }
        let record = try #require(center.selected)
        await center.receive(.init(operationID: record.id, jobID: UUID(), kind: .ended))
        #expect(center.selected?.phase == .ready)
        #expect(center.selected?.canSave == true)
        await center.cancelSelected()
    }

    @Test("Creator fields are durable across panel replacement")
    func draftRestoration() async throws {
        let settings = MCPServiceTestSettings(), backend = MCPServiceTestBackend()
        let center = coordinator(backend, settings)
        await center.load()
        center.draft = .init(name: "Draft", details: "List my project files", workspaceID: UUID(), environmentID: "chosen", port: "8123")
        await center.saveDraft()
        let restored = coordinator(MCPServiceTestBackend(), settings)
        await restored.load()
        #expect(restored.draft == center.draft)
        #expect(restored.records.isEmpty)
    }
}
#endif
