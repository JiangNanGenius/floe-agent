#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeExecution
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
    var failWaitBuild: Error?
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
    func waitForBuild(_ record: MCPServiceCreationRecord) async throws {
        calls.append(("waitBuild", record))
        if let failWaitBuild { throw failWaitBuild }
    }
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

    // MARK: - Bounded owned build phases

    @Test("A failed build phase stays failed and cannot start the service")
    func failedBuildPhaseBlocksService() async throws {
        let backend = MCPServiceTestBackend()
        backend.failWaitBuild = FloeError.validationFailed("phase test failed: exit=124")
        let center = coordinator(backend)
        await center.start(request())
        try await wait { center.selected?.phase == .failed }
        #expect(backend.calls.map(\.0) == ["resolve", "prepare", "generate", "submitBuild", "waitBuild"])
        #expect(!backend.calls.contains { $0.0 == "submitService" })
        #expect(center.selected?.serviceJobID == nil)
        #expect(center.selected?.receipt == nil)
        #expect(center.selected?.canSave == false)
        await center.cancelSelected()
    }

    @Test("Resume decisions skip completed phases, attach live or failed rows, and never stop at the first completion")
    func buildResumeDecisionTable() {
        #expect(MCPServiceCreationAppBackend.nextBuildPhaseAction(states: [nil, nil, nil]) == .submitPhase(0))
        #expect(MCPServiceCreationAppBackend.nextBuildPhaseAction(states: [.running, nil, nil]) == .attachPhase(0))
        #expect(MCPServiceCreationAppBackend.nextBuildPhaseAction(states: [.completed, .queued, nil]) == .attachPhase(1))
        #expect(MCPServiceCreationAppBackend.nextBuildPhaseAction(states: [.completed, .completed, nil]) == .submitPhase(2))
        // Terminal failure/cancel/interrupt rows are attached and judged by
        // waitForBuild: failure stays failure and no later phase is replayed
        // or skipped over it.
        #expect(MCPServiceCreationAppBackend.nextBuildPhaseAction(states: [.completed, .failed, nil]) == .attachPhase(1))
        #expect(MCPServiceCreationAppBackend.nextBuildPhaseAction(states: [.cancelled, nil, nil]) == .attachPhase(0))
        #expect(MCPServiceCreationAppBackend.nextBuildPhaseAction(states: [.interrupted, nil, nil]) == .attachPhase(0))
        // All phases completed: the final row is attached (no replay) and
        // waitForBuild validates fixed inputs before the service may start.
        #expect(MCPServiceCreationAppBackend.nextBuildPhaseAction(states: [.completed, .completed, .completed]) == .allCompleted)
    }

    @Test("Phase identities are deterministic per record and cannot bind another record's rows")
    func phaseIdentityBinding() {
        let recordID = UUID()
        let foreign = UUID()
        let calls = MCPServiceCreationAppBackend.buildPhaseCallIDs(recordID)
        #expect(calls.count == MCPServiceCreationAppBackend.buildPhaseSpecs.count)
        #expect(Set(calls).count == calls.count)
        #expect(MCPServiceCreationAppBackend.buildPhaseCallIDs(recordID) == calls)
        for (index, call) in calls.enumerated() {
            #expect(MCPServiceCreationAppBackend.phaseIndex(forCallID: call, recordID: recordID) == index)
            #expect(MCPServiceCreationAppBackend.phaseIndex(forCallID: call, recordID: foreign) == nil)
        }
        #expect(MCPServiceCreationAppBackend.phaseIndex(forCallID: "mcp.build.\(recordID.uuidString)", recordID: recordID) == nil)
    }

    @Test("Phase commands carry every frozen contract command exactly once")
    func phaseCommandsPreserveFrozenContract() {
        let install = MCPServiceCreationAppBackend.installCommand
        let compile = MCPServiceCreationAppBackend.compileCommand
        let test = MCPServiceCreationAppBackend.testCommand
        for command in [install, compile, test] {
            #expect(command.hasPrefix("set -eu\n"))
            #expect(command.contains("Node 20.19 or newer is required"))
        }
        // Install: the exact pinned npm ci invocation, once, nothing else.
        #expect(install.contains("npm ci --ignore-scripts --no-audit --no-fund"))
        #expect(!compile.contains("npm ci"))
        #expect(!test.contains("npm ci"))
        // Compile: the required TypeScript build, once, in no other phase.
        #expect(compile.contains("npm run build"))
        #expect(!install.contains("npm run build"))
        #expect(!test.contains("npm run build"))
        // Test: the pinned fixed HTTP test invocation directly, with no
        // duplicated full rebuild smuggled back through `npm test`.
        #expect(test.contains("node --test tests/http.test.mjs"))
        #expect(!test.contains("npm test"))
        #expect(!install.contains("node --test"))
        #expect(!compile.contains("node --test"))
        // Every executable command line of the retained monolithic contract
        // survives in exactly one phase, `npm test` represented by its node
        // step. Nothing is dropped from the reviewed workload.
        let phaseLines = Set([install, compile, test]
            .flatMap { $0.split(separator: "\n").map(String.init) })
        for line in MCPServiceCreationAppBackend.buildCommand.split(separator: "\n")
        where line.hasPrefix("npm ") || line.hasPrefix("node ") {
            if line == "npm test" {
                #expect(phaseLines.contains("node --test tests/http.test.mjs"))
            } else {
                #expect(phaseLines.contains(String(line)))
            }
        }
    }

    // MARK: - Exact owned command payload binding

    @Test("A present row must be bound before its state may advance the resume scan")
    func completedPredecessorMustBeBoundBeforeAdvancing() {
        typealias Row = MCPServiceCreationAppBackend.MCPServiceBuildRow
        let boundCompleted = Row(state: .completed, bound: true)
        let boundRunning = Row(state: .running, bound: true)
        let unboundCompleted = Row(state: .completed, bound: false)
        let unboundFailed = Row(state: .failed, bound: false)
        let unboundRunning = Row(state: .running, bound: false)
        let unboundCancelled = Row(state: .cancelled, bound: false)
        // Bound rows keep the predecessor decision table exactly as it was.
        #expect(MCPServiceCreationAppBackend.nextBuildPhaseAction(
            rows: [boundCompleted, nil, nil]) == .submitPhase(1))
        #expect(MCPServiceCreationAppBackend.nextBuildPhaseAction(
            rows: [boundCompleted, boundRunning, nil]) == .attachPhase(1))
        #expect(MCPServiceCreationAppBackend.nextBuildPhaseAction(
            rows: [boundCompleted, boundCompleted, boundCompleted]) == .allCompleted)
        // Absence is not a rejection: a missing row still submits its own phase.
        #expect(MCPServiceCreationAppBackend.nextBuildPhaseAction(rows: [nil, nil, nil]) == .submitPhase(0))
        // A completed row production cannot bind — a foreign conversation,
        // environment, root or another command payload under the same owner —
        // rejects the whole scan instead of skipping its predecessor or
        // authorizing the next phase.
        #expect(MCPServiceCreationAppBackend.nextBuildPhaseAction(
            rows: [unboundCompleted, nil, nil]) == .reject)
        #expect(MCPServiceCreationAppBackend.nextBuildPhaseAction(
            rows: [boundCompleted, unboundCompleted, nil]) == .reject)
        #expect(MCPServiceCreationAppBackend.nextBuildPhaseAction(
            rows: [boundCompleted, unboundFailed, boundCompleted]) == .reject)
        // An unbound live or honestly terminal row is rejected too: it is
        // never attached, never replayed and never cancelled as ours.
        #expect(MCPServiceCreationAppBackend.nextBuildPhaseAction(rows: [unboundRunning]) == .reject)
        #expect(MCPServiceCreationAppBackend.nextBuildPhaseAction(rows: [unboundCancelled]) == .reject)
    }

    @Test("The native build payload is fixed per call ID and resolves no other row")
    func expectedBuildPayloadIsFixedPerCallID() throws {
        let recordID = UUID(); let foreign = UUID()
        let relative = "MCPServices/" + recordID.uuidString.lowercased()
        let legacy = try #require(MCPServiceCreationAppBackend.expectedBuildPayload(
            callID: MCPServiceCreationAppBackend.legacyBuildCallID(recordID),
            recordID: recordID, projectRelativePath: relative))
        #expect(legacy.command == MCPServiceCreationAppBackend.buildCommand)
        #expect(legacy.script == nil && legacy.env == nil && legacy.stdin == nil)
        #expect(legacy.cwd == relative + "/node-http")
        #expect(legacy.timeout == 600 && legacy.maxOutputBytes == 262_144)
        let calls = MCPServiceCreationAppBackend.buildPhaseCallIDs(recordID)
        for (index, call) in calls.enumerated() {
            let args = try #require(MCPServiceCreationAppBackend.expectedBuildPayload(
                callID: call, recordID: recordID, projectRelativePath: relative))
            #expect(args.command == MCPServiceCreationAppBackend.buildPhaseSpecs[index].command)
            #expect(args.script == nil && args.env == nil && args.stdin == nil)
            #expect(args.cwd == relative + "/node-http")
            #expect(args.timeout == 600 && args.maxOutputBytes == 262_144)
            // Another record's row, a free-form ID and a prefixed-but-wrong ID
            // resolve no expected payload at all.
            #expect(MCPServiceCreationAppBackend.expectedBuildPayload(
                callID: call, recordID: foreign, projectRelativePath: relative) == nil)
        }
        #expect(MCPServiceCreationAppBackend.expectedBuildPayload(
            callID: "echo-done", recordID: recordID, projectRelativePath: relative) == nil)
        #expect(MCPServiceCreationAppBackend.expectedBuildPayload(
            callID: "mcp.build.install." + foreign.uuidString,
            recordID: recordID, projectRelativePath: relative) == nil)
    }

    @Test("A real job row carrying the exact native payload is bound")
    func genuineNativePayloadsAreBound() throws {
        let conversationID = UUID(); let runID = UUID(); let recordID = UUID()
        let relative = "MCPServices/" + recordID.uuidString.lowercased()
        for call in [MCPServiceCreationAppBackend.legacyBuildCallID(recordID)]
                        + MCPServiceCreationAppBackend.buildPhaseCallIDs(recordID) {
            let expected = try #require(MCPServiceCreationAppBackend.expectedBuildPayload(
                callID: call, recordID: recordID, projectRelativePath: relative))
            // The real persisted type, exactly as `submit` stores it.
            let job = BackgroundJob(conversationID: conversationID, runID: runID, toolCallID: call,
                                    kind: .tool, targetTool: "exec.shell",
                                    payloadJSON: try JSONEncoder().encode(expected), state: .completed)
            #expect(MCPServiceCreationAppBackend.matchesNativeBuildPayload(
                job.payloadJSON, callID: call, recordID: recordID, projectRelativePath: relative))
            // The tool's own canonical aliases carry the identical fixed
            // execution and stay bound: the same command bytes as `script`,
            // and `timeoutSeconds` equal to the canonical `timeout`.
            let aliased = LocalShellTool.Arguments(script: expected.command, cwd: expected.cwd,
                                                   timeoutSeconds: 600, maxOutputBytes: 262_144)
            let aliasBytes = try JSONEncoder().encode(aliased)
            #expect(MCPServiceCreationAppBackend.matchesNativeBuildPayload(
                aliasBytes, callID: call, recordID: recordID,
                projectRelativePath: relative))
        }
        let service = MCPServiceCreationAppBackend.expectedServicePayload(projectRelativePath: relative, port: 8080)
        let serviceJob = BackgroundJob(conversationID: conversationID, runID: runID,
                                       toolCallID: "mcp.service." + recordID.uuidString, kind: .tool,
                                       targetTool: "exec.localService", payloadJSON: try JSONEncoder().encode(service))
        #expect(MCPServiceCreationAppBackend.matchesNativeServicePayload(
            serviceJob.payloadJSON, projectRelativePath: relative, port: 8080))
    }

    @Test("A forged or drifted same-owner payload never binds a build row")
    func forgedBuildPayloadsAreRefused() throws {
        let recordID = UUID()
        let relative = "MCPServices/" + recordID.uuidString.lowercased()
        let installCall = MCPServiceCreationAppBackend.buildPhaseCallIDs(recordID)[0]
        let legacyCall = MCPServiceCreationAppBackend.legacyBuildCallID(recordID)
        let expected = try #require(MCPServiceCreationAppBackend.expectedBuildPayload(
            callID: installCall, recordID: recordID, projectRelativePath: relative))
        let expectedLegacy = try #require(MCPServiceCreationAppBackend.expectedBuildPayload(
            callID: legacyCall, recordID: recordID, projectRelativePath: relative))
        func buildPayload(_ mutate: (inout LocalShellTool.Arguments) -> Void) throws -> Data {
            var args = expected
            mutate(&args)
            return try JSONEncoder().encode(args)
        }
        func bound(_ bytes: Data, _ call: String) -> Bool {
            MCPServiceCreationAppBackend.matchesNativeBuildPayload(bytes, callID: call, recordID: recordID,
                                                                   projectRelativePath: relative)
        }
        func refused(_ bytes: Data, _ label: String) {
            #expect(!bound(bytes, installCall), Comment(rawValue: "install slot must refuse: " + label))
        }
        // The echo-done row that "completes" the install slot is refused, and
        // so is every quieter drift of the fixed bounds or injected inputs:
        // none of them may count as a finished phase or authorize a new one.
        refused(try buildPayload { $0.command = "echo done" }, "echo done")
        refused(try buildPayload { $0.command = "npm ci && npm run build && node --test tests/http.test.mjs" },
                "one-line fake equivalent")
        refused(try buildPayload { $0.command = "set -eu\nnode --test tests/http.test.mjs" }, "truncated phase")
        // Another genuine phase command is still not THIS slot's command.
        refused(try buildPayload { $0.command = MCPServiceCreationAppBackend.compileCommand }, "compile bytes in the install slot")
        refused(try buildPayload { $0.command = MCPServiceCreationAppBackend.testCommand }, "test bytes in the install slot")
        refused(try buildPayload { $0.command = MCPServiceCreationAppBackend.buildCommand }, "monolithic bytes in the install slot")
        // Drifted or missing bounds and injected inputs are refused, even an
        // empty channel: this backend writes those keys never, not empty.
        refused(try buildPayload { $0.cwd = "MCPServices/other-project/node-http" }, "other project cwd")
        refused(try buildPayload { $0.cwd = nil }, "missing cwd")
        refused(try buildPayload { $0.timeout = 30 }, "shortened timeout")
        refused(try buildPayload { $0.timeout = nil }, "missing timeout")
        refused(try buildPayload { $0.timeout = 600; $0.timeoutSeconds = 30 }, "disagreeing timeout alias")
        refused(try buildPayload { $0.maxOutputBytes = 24_576 }, "smaller output bound")
        refused(try buildPayload { $0.maxOutputBytes = nil }, "missing output bound")
        refused(try buildPayload { $0.env = ["PATH": "/tmp/evil/bin"] }, "injected environment")
        refused(try buildPayload { $0.env = [:] }, "empty environment key")
        refused(try buildPayload { $0.stdin = "yes" }, "injected stdin")
        refused(try buildPayload { $0.packages = ["requests==2.0"] }, "package install channel")
        refused(try buildPayload { $0.packages = [] }, "empty package channel")
        refused(try buildPayload { $0.packagePurpose = "install" }, "package purpose")
        refused(try buildPayload { $0.packageCapabilities = ["network"] }, "package capabilities")
        // A second, different command smuggled in the `script` alias is not the
        // canonical identical-bytes form.
        refused(try buildPayload { $0.script = "echo done" }, "second command in the script alias")
        // Undecodable or wrongly shaped bodies are not receipts.
        refused(Data("not-json".utf8), "undecodable body")
        refused(Data("[]".utf8), "wrongly shaped body")
        refused(Data(), "empty body")
        let expectedBytes = try JSONEncoder().encode(expected)
        let legacyBytes = try JSONEncoder().encode(expectedLegacy)
        // Slot cross-binding: the legacy payload cannot fill a phase slot and a
        // phase payload cannot fill the legacy slot; another record's install
        // slot binds nothing here at all.
        #expect(!bound(legacyBytes, installCall), "legacy payload cannot fill the install slot")
        #expect(!bound(expectedBytes, legacyCall), "install payload cannot fill the legacy slot")
        #expect(!bound(expectedBytes, "mcp.build.install." + UUID().uuidString),
                "another record's install slot binds nothing here")
        // The genuine install payload is still bound (no over-rejection).
        #expect(bound(expectedBytes, installCall))
    }

    @Test("A drifted service payload cannot keep or start the owned service")
    func forgedServicePayloadsAreRefused() throws {
        let recordID = UUID()
        let relative = "MCPServices/" + recordID.uuidString.lowercased()
        let expected = MCPServiceCreationAppBackend.expectedServicePayload(projectRelativePath: relative, port: 8080)
        func servicePayload(_ mutate: (inout LocalServiceTool.Arguments) -> Void) throws -> Data {
            var args = expected
            mutate(&args)
            return try JSONEncoder().encode(args)
        }
        func bound(_ bytes: Data) -> Bool {
            MCPServiceCreationAppBackend.matchesNativeServicePayload(bytes, projectRelativePath: relative, port: 8080)
        }
        func refusedService(_ mutate: (inout LocalServiceTool.Arguments) -> Void) throws {
            let bytes = try servicePayload(mutate)
            #expect(!bound(bytes))
        }
        let expectedBytes = try JSONEncoder().encode(expected)
        #expect(bound(expectedBytes))
        try refusedService { $0.port = 8081 }
        try refusedService { $0.entry = relative + "/node-http/other-start.mjs" }
        try refusedService { $0.entry = "MCPServices/other/node-http/floe-start.mjs" }
        try refusedService { $0.runtime = "python" }
        try refusedService { $0.arguments = ["--argv0", "./evil.js"] }
        try refusedService { $0.cwd = relative }
        try refusedService { $0.cwd = nil }
        #expect(!bound(Data("not-json".utf8)))
        // A different record's directory is a different payload.
        let otherBytes = try JSONEncoder().encode(MCPServiceCreationAppBackend.expectedServicePayload(
            projectRelativePath: "MCPServices/" + UUID().uuidString.lowercased(), port: 8080))
        #expect(!MCPServiceCreationAppBackend.matchesNativeServicePayload(
            otherBytes, projectRelativePath: relative, port: 8080))
    }
}
#endif
