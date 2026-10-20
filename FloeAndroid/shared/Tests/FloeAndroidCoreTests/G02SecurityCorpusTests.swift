// SPDX-License-Identifier: MPL-2.0
//
// CORPUS-FIRST production-wiring regressions (Main cloud-ready prerequisite).
//
// The prior Run-domain fixture injected `RunIngressContext.catastrophicCorpusBytes`
// DIRECTLY, so it could never catch the production composition shipping
// `catastrophicCorpusBytes: nil`. These tests go through the REAL production
// bootstrap and composition instead:
//
//   App bootstrap (trusted asset read) -> G02SecurityCorpus.freeze (ORIGINAL
//   loader pin/bounds/schema) -> AndroidRuntimeBootstrap.start ->
//   G02InstalledComposition.build -> RunIngressContext.frozenBytes()
//
// Only the model stream is a synthetic double at the external edge (the same
// documented test seam the existing suites use); the store, composition,
// corpus gate and run pipeline are the real production ones. No real key,
// account, network or device is involved.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloeProviders
import FloePersistence
import FloeAgentRuntime
import FloeSecurity
@testable import FloeAndroidCore

final class G02SecurityCorpusTests: XCTestCase {

    private var tracked: [Boot] = []

    override func tearDown() async throws {
        for boot in tracked.reversed() where !boot.retired {
            await shutdownAndAwaitClosed(boot)
        }
        tracked.removeAll()
        RunDomainFacade.uninstall()
        SecretGatewayRegistry.shared.unregister()
        G02RuntimeComposition.shared.resetForTesting()
        AndroidRuntimeBootstrap.resetForTesting()
        G02SecurityCorpus.resetForTesting()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private enum FixtureEpoch {
        nonisolated(unsafe) static var lock = NSLock()
        nonisolated(unsafe) static var value: UInt64 =
            UInt64(DispatchTime.now().uptimeNanoseconds)
        static func allocate() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            let now = UInt64(DispatchTime.now().uptimeNanoseconds)
            value = Swift.max(value &+ 1, now)
            return value
        }
    }

    private final class Boot {
        let epoch: UInt64
        let receipt: String
        let rootPath: String
        let token: String
        var retired = false
        init(epoch: UInt64, receipt: String, rootPath: String, token: String) {
            self.epoch = epoch
            self.receipt = receipt
            self.rootPath = rootPath
            self.token = token
        }
    }

    private enum TestError: Error {
        case bootstrap
    }

    /// The EXACT bundled trusted corpus (byte-identical to the APK asset the
    /// production host reads; pinned by the ORIGINAL loader).
    private func bundledCorpusData() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Sources/FloeSecurity/Resources/"
                                    + "catastrophic-patterns.json")
            .standardizedFileURL
        return try Data(floeContentsOf: url)
    }

    /// Real production bootstrap over a synthetic trusted root; returns only
    /// after the accepted bootstrap terminal settled AND the ordinary
    /// production graph installed.
    @discardableResult
    private func bootInstalledGeneration(
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> (Boot, G02InstalledComposition) {
        let root = NSTemporaryDirectory()
            .appending("corpus-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root,
                                                withIntermediateDirectories: true)
        let token = String((0..<16).map { _ in "0123456789abcdef".randomElement()! })
        let epoch = FixtureEpoch.allocate()
        guard case .accepted(let receipt) = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: token, epoch: epoch) else {
            XCTFail("bootstrap not accepted (root preserved: \(root))",
                    file: file, line: line)
            throw TestError.bootstrap
        }
        let boot = Boot(epoch: epoch, receipt: receipt, rootPath: root,
                        token: token)
        tracked.append(boot)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard let gen = AndroidRuntimeBootstrap.currentGenerationForTesting(),
                  gen.epoch == epoch else {
                XCTFail("generation vanished before its accepted terminal: "
                            + AndroidRuntimeBootstrap.statusSnapshotJSON(),
                        file: file, line: line)
                throw TestError.bootstrap
            }
            guard case .page(let effects, _, _, _) =
                    gen.effects.poll(receipt: receipt, afterSequence: 0),
                  let terminal = effects.first(where: { $0.isTerminal }) else {
                try await Task.sleep(nanoseconds: 10_000_000)
                continue
            }
            guard terminal.kind == .accepted else {
                XCTFail("bootstrap terminal not accepted: \(terminal.kind)",
                        file: file, line: line)
                throw TestError.bootstrap
            }
            guard let installed = G02RuntimeComposition.shared.installedComposition,
                  installed.epoch == epoch else {
                XCTFail("ordinary graph not installed for the accepted bootstrap",
                        file: file, line: line)
                throw TestError.bootstrap
            }
            return (boot, installed)
        }
        XCTFail("bootstrap terminal did not settle", file: file, line: line)
        throw TestError.bootstrap
    }

    private func shutdownAndAwaitClosed(_ boot: Boot,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) async {
        guard !boot.retired else { return }
        defer { boot.retired = true }
        switch AndroidRuntimeBootstrap.shutdown(
            expectedEpoch: boot.epoch, ownerToken: boot.token) {
        case .accepted, .idempotent:
            break
        case .rejected(let code):
            if code == .notInstalled,
               AndroidRuntimeBootstrap.currentGenerationForTesting() == nil {
                return
            }
            XCTFail("shutdown not accepted for epoch \(boot.epoch): \(code.rawValue)",
                    file: file, line: line)
            return
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if AndroidRuntimeBootstrap.currentGenerationForTesting() == nil {
                let status = AndroidRuntimeBootstrap.statusSnapshotJSON()
                if status.contains("\"ownedStorePhase\":\"closed\"")
                    || !status.contains("\"generation\"") {
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("generation did not reach closed/gone for epoch \(boot.epoch)",
                file: file, line: line)
    }

    private func tampered(_ corpus: Data) -> Data {
        var copy = corpus
        // Flip one byte inside a pattern string (hash mismatch, still JSON).
        if copy.count > 40 {
            copy[copy.count / 2] = copy[copy.count / 2] ^ 0x01
        }
        return copy
    }

    // MARK: - 1. The bundled corpus freezes and keeps ORIGINAL precision

    func testFreezeAcceptsBundledCorpusAndKeepsOriginalGatePrecision() throws {
        let corpus = try bundledCorpusData()
        XCTAssertEqual(G02SecurityCorpus.freeze(corpus), G02SecurityCorpusStatus.ok)
        XCTAssertEqual(G02SecurityCorpus.frozenBytes(), corpus,
                       "frozen bytes must be the exact trusted corpus")

        let gate = AndroidCatastrophicCorpus.loadFailClosed(
            from: G02SecurityCorpus.frozenBytes())
        // Precision: a real corpus allows a benign command and blocks a
        // destructive one. A fail-closed substitute (or empty gate) cannot
        // satisfy both.
        XCTAssertFalse(gate.evaluate(command: "list the workspace files").stopped,
                       "benign command must pass the REAL corpus")
        XCTAssertTrue(gate.evaluate(command: "rm -rf / --no-preserve-root").stopped,
                      "destructive command must be stopped")

        // Idempotent re-freeze (the App may restart its bootstrap).
        XCTAssertEqual(G02SecurityCorpus.freeze(corpus),
                       G02SecurityCorpusStatus.idempotentOk)
        XCTAssertEqual(G02SecurityCorpus.frozenBytes(), corpus)
    }

    // MARK: - 2. Empty / oversized / tampered corpora NEVER freeze

    func testEmptyOversizedAndTamperedCorporaNeverFreeze() throws {
        XCTAssertEqual(G02SecurityCorpus.freeze(Data()),
                       G02SecurityCorpusStatus.empty)
        XCTAssertNil(G02SecurityCorpus.frozenBytes())

        let oversized = Data(count: AndroidCatastrophicCorpus.maximumCorpusBytes + 1)
        XCTAssertEqual(G02SecurityCorpus.freeze(oversized),
                       G02SecurityCorpusStatus.oversized)
        XCTAssertNil(G02SecurityCorpus.frozenBytes())

        let corpus = try bundledCorpusData()
        XCTAssertEqual(G02SecurityCorpus.freeze(tampered(corpus)),
                       G02SecurityCorpusStatus.invalid)
        XCTAssertNil(G02SecurityCorpus.frozenBytes(),
                     "tampered bytes must never be frozen")

        // A truncated corpus is likewise refused.
        XCTAssertEqual(G02SecurityCorpus.freeze(Data(corpus.dropLast(16))),
                       G02SecurityCorpusStatus.invalid)
        XCTAssertNil(G02SecurityCorpus.frozenBytes())

        // The trusted corpus still freezes afterwards.
        XCTAssertEqual(G02SecurityCorpus.freeze(corpus), G02SecurityCorpusStatus.ok)
    }

    // MARK: - 3. PRODUCTION bootstrap carries the frozen bytes (the old
    //            fixture-injected RunIngressContext could never see this)

    func testProductionBootstrapCarriesFrozenCorpusIntoRunIngressContext() async throws {
        let corpus = try bundledCorpusData()
        XCTAssertEqual(G02SecurityCorpus.freeze(corpus), G02SecurityCorpusStatus.ok)
        let (boot, installed) = try await bootInstalledGeneration()
        XCTAssertEqual(boot.epoch, installed.epoch)
        let context = installed.runComponents.context
        XCTAssertEqual(context.catastrophicCorpusBytes, corpus,
                       "production RunIngressContext must carry the frozen trusted corpus")
        guard case .usable(let gate) = RunGateAdmission.admit(context: context) else {
            return XCTFail("production gate admission must be usable, not needsCorpus")
        }
        XCTAssertTrue(gate.evaluate(command: "rm -rf /").stopped)
        XCTAssertFalse(gate.evaluate(command: "summarize this note").stopped)
    }

    // MARK: - 4. Missing corpus keeps the TRUTHFUL production refusal

    func testMissingCorpusKeepsProductionNeedsCorpusRefusal() async throws {
        G02SecurityCorpus.resetForTesting()
        let (_, installed) = try await bootInstalledGeneration()
        let context = installed.runComponents.context
        XCTAssertNil(context.catastrophicCorpusBytes,
                     "without a freeze the production context must stay corpus-less")
        guard case .needsCorpus = RunGateAdmission.admit(context: context) else {
            return XCTFail("absent corpus must keep the honest needsCorpus refusal")
        }
    }

    // MARK: - 5. run.start through the PRODUCTION composition reaches C1

    /// Seeds ONE synthetic provider/model row into the PRODUCTION model store
    /// (+ default preference + synthetic gateway secret). Returns the ids.
    @discardableResult
    private func seedProductionProviderAndModel(
        _ components: RunDomainComponents
    ) async throws -> (providerID: UUID, modelID: UUID) {
        let providerID = UUID()
        let modelID = UUID()
        var provider = ProviderProfile(
            kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://fixtures.invalid/v1")!)
        provider.id = providerID
        provider.secretRef = SecretReference(keychainAccount: "corpus-fixture-provider",
                                             synchronizable: false)
        provider.displayName = "Corpus Fixture"
        var model = ModelProfile(
            providerID: providerID, remoteModelID: "fixture-model",
            displayName: "Fixture Model",
            limits: ModelLimits(contextTokens: 16_000, maxOutputTokens: 2_048),
            capabilities: [.text, .tools, .vision])
        model.id = modelID
        try await components.modelStore.saveProvider(provider)
        try await components.modelStore.saveModel(model)
        var preferences = try await components.modelStore.preferences()
        preferences.defaultAgentModelID = modelID
        try await components.modelStore.savePreferences(preferences)
        let gateway = TestSecretGateway()
        SecretGatewayRegistry.shared.register(gateway)
        if let ref = provider.secretRef {
            gateway.seed(reference: SecretGatewayNaming.opaqueReference(for: ref),
                         value: "sk-fixture-not-a-real-key")
        }
        return (providerID, modelID)
    }

    /// REAL ordinary conversation through the original atomic launch store,
    /// with its seeding run closed so it never looks live.
    private func makeProductionConversation(
        _ components: RunDomainComponents, providerID: UUID, modelID: UUID
    ) async throws -> (conversationID: UUID, revision: String) {
        let prepared = try await components.durable.launches.prepare(RunLaunchRequest(
            goal: "seed",
            conversationMode: "chat",
            initialPolicy: DraftTaskPolicy(approvalMode: .ask),
            providerID: providerID,
            modelID: modelID))
        try await components.durable.runs.updateRunState(id: prepared.run.id,
                                                         state: "completed",
                                                         endedAt: Date())
        let conversationID = prepared.conversation.id
        let revision = try await components.conversationRevisions
            .digest(conversationID: conversationID) ?? ""
        return (conversationID, revision)
    }

    private func productionStartEnvelope(
        conversationID: UUID, revision: String,
        providerID: UUID, modelID: UUID, correlation: String
    ) -> RunCommandEnvelope {
        RunCommandEnvelope(object: [
            "schema": BridgeV3.commandSchema,
            "scope": BridgeV3.Scope.launch.rawValue,
            "command": "run.start",
            "stateful": true,
            "correlationID": correlation,
            "owner": ["taskID": conversationID.uuidString],
            "revision": [
                "resourceID": ConversationRowRevision.resourceID(
                    conversationID: conversationID),
                "version": revision,
            ],
            "payload": [
                "goal": "say hello through the trusted corpus path",
                "mode": "chat",
                "providerID": providerID.uuidString,
                "modelID": modelID.uuidString,
                "approvalMode": "ask",
            ],
        ])
    }

    /// Positive end-to-end: real production bootstrap + composition, a real
    /// provider/model row in the production model store, a real conversation
    /// (original atomic launch store), and run.start through the same facade
    /// entry the wire handler uses. ONLY the model stream is scripted.
    func testProductionRunStartReachesFirstModelRequestWithTrustedCorpus() async throws {
        let corpus = try bundledCorpusData()
        XCTAssertEqual(G02SecurityCorpus.freeze(corpus), G02SecurityCorpusStatus.ok)
        let (_, installed) = try await bootInstalledGeneration()

        // Engineering/test transport-admission wiring authority (the same
        // value the existing run-launch fixtures inject): the flip
        // truthfully propagates into the LIVE production RunContext snapshot.
        G02RuntimeComposition.shared.transportGate.markQualified(true)

        // Production components, unchanged except the documented external
        // model-stream test seam.
        var components = installed.runComponents
        XCTAssertTrue(components.context.isTransportQualified,
                      "the engineering admission flip must reach the live snapshot")
        let adapter = ScriptedRunAdapter(defaultScript: .init(events: [
            .textDelta(.init(text: "corpus wiring answer")),
            .completed(.init(stopReason: .endTurn)),
        ]))
        components.adapterFactoryOverride = { _ in adapter }
        RunDomainFacade.install(components: components, registry: installed.registry)
        guard let (domain, _) = RunDomainFacade.current(epoch: installed.epoch) else {
            return XCTFail("production run domain missing after install")
        }

        let ids = try await seedProductionProviderAndModel(components)
        let (conversationID, revision) = try await makeProductionConversation(
            components, providerID: ids.providerID, modelID: ids.modelID)
        XCTAssertFalse(revision.isEmpty)

        let correlation = "op:v1:" + String(repeating: "c", count: 32)
        let envelope = productionStartEnvelope(
            conversationID: conversationID, revision: revision,
            providerID: ids.providerID, modelID: ids.modelID,
            correlation: correlation)
        let reply = await domain.start(envelope: envelope, receipt: correlation,
                                       correlation: correlation)
        guard case .mutationAccepted(let detail) = reply.outcome else {
            if case .rejected(let error) = reply.outcome {
                return XCTFail("run.start refused: \(error.code)/\(error.reason) "
                                + "(corpusAbsent must NOT occur with the frozen corpus)")
            }
            return XCTFail("run.start did not accept: \(reply.outcome)")
        }
        let runID = try XCTUnwrap(UUID(uuidString: detail["runID"] ?? ""))
        XCTAssertNotNil(detail["runID"])

        // C1: the ORIGINAL pipeline actually dispatched the first model
        // request (no corpusAbsent, no fake acceptance).
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, adapter.requestCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(adapter.requestCount, 1,
                                    "run.start must reach the first model request (C1)")
        XCTAssertEqual(adapter.lastRequest?.messages.isEmpty, false)

        // And the REAL service drives the scripted stream to its durable
        // terminal through the ORIGINAL stores.
        var state: String?
        while Date() < deadline {
            state = try await components.durable.runs.run(id: runID)?.state
            if state == "completed" || state == "failed" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(state, "completed")
    }

    // MARK: - 6. Missing corpus: PRODUCTION run.start refuses corpusAbsent
    //            BEFORE any provider/store side effect

    /// The honest negative through the REAL production graph: no freeze, a
    /// fully seeded provider/model + conversation, and run.start must refuse
    /// `needsConfiguration/corpusAbsent` with NO model request (C1 never
    /// happens) and NO committed run row (C0 durable honesty).
    func testProductionRunStartRefusesCorpusAbsentBeforeAnyEffect() async throws {
        G02SecurityCorpus.resetForTesting()   // no corpus frozen
        let (_, installed) = try await bootInstalledGeneration()
        G02RuntimeComposition.shared.transportGate.markQualified(true)

        var components = installed.runComponents
        let adapter = ScriptedRunAdapter(defaultScript: .init(events: [
            .textDelta(.init(text: "must never stream")),
            .completed(.init(stopReason: .endTurn)),
        ]))
        components.adapterFactoryOverride = { _ in adapter }
        RunDomainFacade.install(components: components, registry: installed.registry)
        guard let (domain, _) = RunDomainFacade.current(epoch: installed.epoch) else {
            return XCTFail("production run domain missing after install")
        }

        let ids = try await seedProductionProviderAndModel(components)
        let (conversationID, revision) = try await makeProductionConversation(
            components, providerID: ids.providerID, modelID: ids.modelID)

        let correlation = "op:v1:" + String(repeating: "d", count: 32)
        let envelope = productionStartEnvelope(
            conversationID: conversationID, revision: revision,
            providerID: ids.providerID, modelID: ids.modelID,
            correlation: correlation)
        let reply = await domain.start(envelope: envelope, receipt: correlation,
                                       correlation: correlation)
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("run.start must refuse without the corpus, got \(reply.outcome)")
        }
        XCTAssertEqual(error.code, .needsConfiguration)
        XCTAssertEqual(error.reason, .corpusAbsent,
                       "the refusal must be the truthful corpusAbsent, not a substitute")
        XCTAssertEqual(error.phase, .gateAdmission,
                       "the bounded phase must localize the refusal to the corpus gate")

        // BEFORE any effect: no model request, no committed run row, and no
        // durable run events for this conversation beyond the seeding run.
        XCTAssertEqual(adapter.requestCount, 0,
                       "corpusAbsent must fire BEFORE the first provider request (C1)")
        let runs = try await components.durable.runs.runs(conversationID: conversationID)
        XCTAssertEqual(runs.count, 1, "only the closed seeding run may exist")
        XCTAssertEqual(runs.first?.state, "completed")
    }
}
