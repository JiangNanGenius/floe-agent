// SPDX-License-Identifier: MPL-2.0
//
// RB-1 typed result carrier qualification (MAIN RB1_TYPED_RESULT_CARRIER
// decision + final Kotlin consumer schema `value`/`valueBytes` +
// `page`/`pageBytes`).
//
// Scope proven HERE (host, real original file-backed DatabaseManager):
//  * canonical declared byte counts (kotlinx `JsonObject.toString()` lexemes)
//    for slash URLs, control escapes, quotes/backslashes, CJK, emoji and
//    Unicode separators — plus a fixture emitted for the Kotlin JVM mirror;
//  * pump append acceptance/refusal on ACTUAL encoded sizes, peek/ack
//    separation (failed delivery can never mark data read), retained
//    terminal under ring pressure;
//  * configuration-scope composition for shared keys (no last-register-wins);
//  * a REAL store read (SQLiteSettingsStore through the ONE owned
//    DatabaseManager) -> RuntimeCommandResult typed page -> mailbox ->
//    native `effect.poll` v3 entry -> strict response decode, including a
//    near-48 KiB CJK/emoji/quote/control page, a multi-page split, an
//    oversize atomic item settled typed-recoverable, a failed poll that does
//    not advance the cursor, a foreign receipt, and retired-generation
//    readability after a real close.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloePersistence
@testable import FloeAndroidCore

final class RuntimeEffectCarrierTests: XCTestCase {

    private var roots: [String] = []
    private var fixtureDirectory: String? {
        ProcessInfo.processInfo.environment["RB1_CARRIER_FIXTURE_DIR"]
    }

    /// Monotonic fixture identity: every boot gets a FRESH epoch. The
    /// previous fixed epoch-1/2 reuse raced the previous test's asynchronous
    /// lifecycle (synchronous resetForTesting + epoch collision after the
    /// late close), which the G02 composition install's real build window
    /// made observable (MAIN lifecycle-ordering review 2026-10-20).
    /// Lock-protected Sendable epoch counter (Swift-6 safe): every access
    /// is behind the real lock; tests in one class never overlap, but the
    /// compiler cannot know that, so the discipline is explicit.
    private enum FixtureEpoch {
        nonisolated(unsafe) private static var lock = NSLock()
        nonisolated(unsafe) private static var value: UInt64 = 1
        static func allocate() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            let epoch = value
            value &+= 1
            return epoch
        }
    }
    private static func allocateEpoch() -> UInt64 {
        FixtureEpoch.allocate()
    }

    override func setUp() {
        super.setUp()
        AndroidRuntimeBootstrap.resetForTesting()
        RuntimeRetiredEffectRegistry.shared.removeAllForTesting()
    }

    override func tearDown() {
        G02RuntimeComposition.shared.resetForTesting()
        AndroidRuntimeBootstrap.resetForTesting()
        RuntimeRetiredEffectRegistry.shared.removeAllForTesting()
        for root in roots { try? FileManager.default.removeItem(atPath: root) }
        roots.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func freshRoot() throws -> String {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("floe-rb1-carrier-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: base,
                                                withIntermediateDirectories: true)
        roots.append(base.path)
        return base.standardizedFileURL.path
    }

    private func exchange(_ request: String) -> [String: Any]? {
        let data = AndroidBridge.exchange(Data(request.utf8))
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func effectEnvelope(correlation: String, receipt: String,
                                sequence: Int) -> String {
        "{\"version\":3,\"operation\":\"effect.poll\","
            + "\"requestID\":\"\(correlation)\","
            + "\"envelope\":{\"schema\":\"floe.effect-cursor/3\","
            + "\"scope\":\"applicationConfiguration\","
            + "\"configurationScope\":\"system\",\"command\":\"effect.poll\","
            + "\"stateful\":false,\"correlationID\":\"\(correlation)\","
            + "\"effect\":{\"operationReceiptID\":\"\(receipt)\","
            + "\"sequence\":\(sequence)}}}"
    }

    private func waitStoreReady(timeout: TimeInterval = 20) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if AndroidRuntimeBootstrap.statusSnapshotJSON()
                .contains("\"ownedStoreReady\":true") { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("store never ready: \(AndroidRuntimeBootstrap.statusSnapshotJSON())")
    }

    /// Awaits the ACTUAL bootstrap job terminal (open+recover+commit+G02
    /// composition install settled) for the accepted start receipt — never
    /// proceeds on storeReady alone (the composition install still runs
    /// after the store-ready publication).
    private func waitBootstrapTerminal(_ receipt: String,
                                       timeout: TimeInterval = 20) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let gen = AndroidRuntimeBootstrap.currentGenerationForTesting(),
               gen.effects.isTerminal(receipt: receipt) { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("bootstrap terminal did not settle for \(receipt)")
    }

    private struct PollOutcome {
        let terminal: [String: Any]?
        let lastPage: [String: Any]
    }

    private func pollUntilTerminal(receipt: String,
                                   timeout: TimeInterval = 10) async throws
        -> PollOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        var lastPage: [String: Any] = [:]
        while Date() < deadline {
            attempt += 1
            guard let page = exchange(effectEnvelope(
                correlation: "carrier-poll-\(attempt)", receipt: receipt,
                sequence: 0)) else {
                return PollOutcome(terminal: nil, lastPage: lastPage)
            }
            lastPage = page
            if let effects = page["effects"] as? [[String: Any]],
               let terminal = effects.last(where: { item in
                   ["accepted", "failed", "rejected", "cancelled",
                    "replaced", "closed"].contains(item["kind"] as? String ?? "")
               }) {
                return PollOutcome(terminal: terminal, lastPage: lastPage)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return PollOutcome(terminal: nil, lastPage: lastPage)
    }

    private func canonicalBytes(_ document: DesignJSONValue) -> Int? {
        FacadeFrameBudget.canonicalSerializedBytes(
            RuntimeEffectDocumentTestProjection.foundationObject(document))
    }

    // MARK: - Canonical lexemes (Swift side of the cross-language contract)

    func testCanonicalCarrierBytesFollowKotlinLexemes() throws {
        // Each expected canonical encoding is an explicit literal: compact
        // punctuation, `/` NOT escaped (Foundation escapes it on the wire),
        // short escapes for \b \t \n \f \r, lowercase `\u00xx` for other
        // controls, raw UTF-8 for CJK/emoji/DEL/C1/U+2028/U+2029.
        let cases: [(String, DesignJSONValue, String)] = [
            ("slash",
             .object(["path": .string("https://example.com/a/b?x=1&y=2")]),
             "{\"path\":\"https://example.com/a/b?x=1&y=2\"}"),
            ("quote-backslash",
             .object(["s": .string("a\"b\\c")]),
             "{\"s\":\"a\\\"b\\\\c\"}"),
            ("controls",
             .object(["s": .string("a\u{0001}b\u{0008}c\u{0009}d\u{000A}e"
                                   + "\u{000C}f\u{000D}g\u{0000}h")]),
             "{\"s\":\"a\\u0001b\\bc\\td\\ne\\ff\\rg\\u0000h\"}"),
            ("cjk",
             .object(["s": .string("中文测试")]),
             "{\"s\":\"中文测试\"}"),
            ("emoji",
             .object(["s": .string("😀🚀")]),
             "{\"s\":\"😀🚀\"}"),
            ("unicode-separators",
             .object(["s": .string("a\u{2028}b\u{2029}c")]),
             "{\"s\":\"a\u{2028}b\u{2029}c\"}"),
            ("del-c1",
             .object(["s": .string("a\u{007F}b\u{0085}c")]),
             "{\"s\":\"a\u{007F}b\u{0085}c\"}"),
        ]
        var fixtureCases: [[String: Any]] = []
        for (name, value, expected) in cases {
            let bytes = try XCTUnwrap(canonicalBytes(value), name)
            XCTAssertEqual(bytes, expected.utf8.count, name)
            fixtureCases.append([
                "name": name,
                "json": RuntimeEffectDocumentTestProjection.foundationObject(value),
                "canonicalBytes": bytes,
            ])
        }
        if let directory = fixtureDirectory {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
            let payload: [String: Any] = ["schema": "floe.rb1.carrier-fixtures/1",
                                          "cases": fixtureCases]
            let data = try JSONSerialization.data(withJSONObject: payload,
                                                  options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent("rb1-carrier-fixtures.json"))
        }
    }

    // MARK: - Pump semantics

    func testPumpCarrierDeclaresCanonicalBytesAndRefusesOversizeAtomically() throws {
        let pump = FacadeEffectPump(generation: 1)
        let receipt = try XCTUnwrap(pump.register(correlationID: "carrier-pump"))
        let page = DesignJSONValue.object([
            "nextOffset": .null,
            "done": .bool(true),
            "content": .string("中😀\"\\\u{0001}"),
        ])
        let outcome = pump.append(receipt: receipt, kind: .prepared, code: nil,
                                  detail: ["page": "1"], page: page, value: nil)
        guard case .appended(let sequence) = outcome else {
            return XCTFail("carrier append must be accepted: \(outcome)")
        }
        XCTAssertEqual(sequence, 1)
        if case .page(let items, let next, let hasMore, _) =
            pump.poll(receipt: receipt, afterSequence: 0) {
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items[0].page, page)
            XCTAssertEqual(items[0].pageBytes, canonicalBytes(page))
            XCTAssertEqual(next, 1)
            XCTAssertFalse(hasMore)
        } else {
            XCTFail("expected a carrier page")
        }
        // An atomic item beyond the actual effect body is refused WITHOUT
        // mutation (the frozen stream stays exactly as it was).
        let huge = DesignJSONValue.object([
            "content": .string(String(repeating: "中", count: 20_000)),
        ])
        let refused = pump.append(receipt: receipt, kind: .accepted,
                                  code: nil, detail: nil, page: huge, value: nil)
        guard case .refused(.payloadTooLarge(let encoded, let available)) = refused
        else {
            return XCTFail("oversize atomic carrier must be refused: \(refused)")
        }
        XCTAssertGreaterThan(encoded, available)
        XCTAssertFalse(pump.isTerminal(receipt: receipt))
        if case .page(let again, _, _, _) = pump.poll(receipt: receipt,
                                                      afterSequence: 0) {
            XCTAssertEqual(again.count, 1)      // nothing changed, nothing lost
        } else {
            XCTFail("page expected after refusal")
        }
    }

    func testPeekNeverAdvancesAndAcknowledgementIsTheOnlyReadBoundary() throws {
        let pump = FacadeEffectPump(generation: 1)
        let receipt = try XCTUnwrap(pump.register(correlationID: "peek-ack"))
        XCTAssertTrue(pump.append(receipt: receipt, kind: .prepared))
        XCTAssertTrue(pump.append(receipt: receipt, kind: .accepted,
                                  detail: ["ownedStoreReady": "true"]))
        // A tiny body budget selects NOTHING and keeps hasMore truthful; the
        // same cursor still sees BOTH effects afterwards (no read marking).
        if case .page(let selected, let next, let hasMore, _) =
            pump.peekPage(receipt: receipt, afterSequence: 0,
                          bodyBudgetBytes: 0) {
            XCTAssertTrue(selected.isEmpty)
            XCTAssertEqual(next, 0)
            XCTAssertTrue(hasMore)
        } else {
            XCTFail("peek expected")
        }
        if case .page(let full, let next, let hasMore, _) =
            pump.peekPage(receipt: receipt, afterSequence: 0,
                          bodyBudgetBytes: Int.max) {
            XCTAssertEqual(full.map(\.sequence), [1, 2])
            XCTAssertEqual(next, 2)
            XCTAssertFalse(hasMore)
        } else {
            XCTFail("peek expected")
        }
        // Before ack the effects are still fully selectable again.
        if case .page(let again, _, _, _) = pump.peekPage(
            receipt: receipt, afterSequence: 0, bodyBudgetBytes: Int.max) {
            XCTAssertEqual(again.count, 2)
        } else {
            XCTFail("unacknowledged effects must remain selectable")
        }
        XCTAssertTrue(pump.acknowledge(receipt: receipt, throughSequence: 2))
        if case .page(let afterAck, _, _, _) = pump.peekPage(
            receipt: receipt, afterSequence: 0, bodyBudgetBytes: Int.max) {
            // Bounded replay by cursor is unchanged (deliveries are idempotent
            // by sequence); ack governs retention/read accounting.
            XCTAssertEqual(afterAck.count, 2)
        } else {
            XCTFail("page expected")
        }
        // The available composer budget is derived from the complete wire.
        let available = try XCTUnwrap(pump.availableEffectBodyBytes(receipt: receipt))
        XCTAssertGreaterThan(available, 40_000)
        XCTAssertLessThanOrEqual(available, FacadeFrameBudget.pageBudgetBytes)
    }

    func testConfigurationScopeCompositionNeverOverwritesSiblings() async {
        let registry = RuntimeDomainRegistry()
        let key = BridgeV3.handlerKey(scope: .applicationConfiguration,
                                      command: "content.read")
        func recorder(_ label: String) -> RuntimeAsyncProcessor {
            RuntimeAsyncProcessor { _ in .accepted(detail: ["owner": label]) }
        }
        func probe(_ scope: String?) async -> String? {
            guard let processor = registry.processor(for: key,
                                                     configurationScope: scope) else {
                return nil
            }
            let job = RuntimeCommandEnvelopeJob(
                correlationID: "probe", handlerKey: key, command: "content.read",
                scope: .applicationConfiguration, configurationScope: scope,
                receipt: "op:v1:00000000000000000000000000000000",
                envelope: Data("{}".utf8))
            let result = await processor.execute(job)
            return result.detail?["owner"]
        }
        registry.register(handlerKey: key, configurationScope: "conversations",
                          processor: recorder("conversations"))
        registry.register(handlerKey: key, configurationScope: "personalization",
                          processor: recorder("personalization"))
        XCTAssertEqual(registry.boundScopedKeys.count, 2)
        // Sibling isolation: replacing one label never steals the other.
        registry.register(handlerKey: key, configurationScope: "conversations",
                          processor: recorder("conversations-2"))
        XCTAssertEqual(registry.boundScopedKeys.count, 2)
        let conversations = await probe("conversations")
        XCTAssertEqual(conversations, "conversations-2")
        let personalization = await probe("personalization")
        XCTAssertEqual(personalization, "personalization")
        // An unregistered label on a composed key fails closed.
        let unregistered = await probe("settings.defaults")
        XCTAssertNil(unregistered)
        let unlabeled = await probe(nil)
        XCTAssertNil(unlabeled)
        XCTAssertTrue(registry.unregister(handlerKey: key,
                                          configurationScope: "personalization"))
        let afterUnregister = await probe("personalization")
        XCTAssertNil(afterUnregister)
        let sibling = await probe("conversations")
        XCTAssertEqual(sibling, "conversations-2")
    }

    // MARK: - Real store read -> mailbox -> native effect.poll -> decode

    private func contentReadKey() -> String {
        BridgeV3.handlerKey(scope: .applicationConfiguration,
                            command: "content.read")
    }

    func testRealStoreDomainReadCarrierThroughActualV3Entry() async throws {
        let root = try freshRoot()
        let token = String(repeating: "c", count: 32)
        let firstEpoch = Self.allocateEpoch()
        guard case .accepted(let bootstrapReceipt) = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: token, epoch: firstEpoch) else {
            return XCTFail("start")
        }
        await waitStoreReady()
        await waitBootstrapTerminal(bootstrapReceipt)
        let gen = try XCTUnwrap(AndroidRuntimeBootstrap.currentGenerationForTesting())

        // A REAL settings value written through the ORIGINAL store on the
        // ONE owned DatabaseManager (no fixture dictionary, no second DB).
        let bigText = "中文😀\"\\\u{0001}\u{2028} "
            + String(repeating: "内容-emoji😀", count: 2_900)
        let owner = gen.owner
        let seededJSON = "{\"note\":\(Self.jsonQuoted(bigText)),\"revision\":7}"
        let seeded: Bool = await {
            guard let store = await owner.settingsStore else { return false }
            do {
                try await store.setValue(seededJSON,
                                         forKey: "rb1.carrier.probe")
                return true
            } catch { return false }
        }()
        XCTAssertTrue(seeded, "real settings store must accept the seed")

        // Compose the domain read under the frozen content.read label.
        let key = contentReadKey()
        gen.registry.register(
            handlerKey: key, configurationScope: "settings.defaults",
            processor: RuntimeAsyncProcessor { _ in
                guard let store = await owner.settingsStore else {
                    return .failed(.storeOpenFailed, detail: ["stage": "storeNil"])
                }
                do {
                    guard let stored = try await store.value(
                        forKey: "rb1.carrier.probe") else {
                        return .failed(.storeOpenFailed, detail: ["stage": "valueNil"])
                    }
                    let page = DesignJSONValue.object([
                        "key": .string("rb1.carrier.probe"),
                        "document": .string(stored),
                        "done": .bool(true),
                        "nextOffset": .null,
                    ])
                    return .accepted(detail: ["scope": "settings.defaults"],
                                     page: page)
                } catch {
                    return .failed(.storeOpenFailed, detail: ["stage": "readThrew"])
                }
            })
        let receipt = try XCTUnwrap(gen.effects.register(correlationID: "carrier-real"))
        let job = RuntimeCommandEnvelopeJob(
            correlationID: "carrier-real", handlerKey: key,
            command: "content.read", scope: .applicationConfiguration,
            configurationScope: "settings.defaults", receipt: receipt,
            envelope: Data("{}".utf8))
        guard case .queued = gen.mailbox.submit(job) else {
            return XCTFail("content.read carrier job must be queued")
        }
        let polled = try await pollUntilTerminal(receipt: receipt)
        guard let terminal = polled.terminal else {
            return XCTFail("no terminal: \(polled.lastPage)")
        }
        XCTAssertEqual(terminal["kind"] as? String, "accepted", "\(terminal)")
        let page = try XCTUnwrap(terminal["page"] as? [String: Any])
        let declared = try XCTUnwrap(terminal["pageBytes"] as? Int)
        XCTAssertEqual(page["key"] as? String, "rb1.carrier.probe")
        let document = try XCTUnwrap(page["document"] as? String)
        XCTAssertEqual(document, seededJSON)
        // The declared size equals the canonical encoding of the page object
        // (recomputed independently from the parsed Foundation tree).
        let recomputed = try XCTUnwrap(
            FacadeFrameBudget.canonicalSerializedBytes(page))
        XCTAssertEqual(declared, recomputed)
        XCTAssertGreaterThan(declared, 40_000)   // genuinely large carrier
        XCTAssertLessThan(declared, 48_000)      // near the 48 KiB page target

        // Cursor acknowledgement: the next poll at the delivered cursor is
        // an honest empty page, not a re-emit.
        let nextCursor = try XCTUnwrap(
            (polled.lastPage["cursor"] as? [String: Any])?["sequence"] as? Int)
        let empty = try XCTUnwrap(exchange(effectEnvelope(
            correlation: "carrier-poll-ack", receipt: receipt,
            sequence: nextCursor)))
        XCTAssertEqual((empty["effects"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(empty["hasMore"] as? Bool, false)

        // A malformed request never marks the cursor/read state.
        let malformed = try XCTUnwrap(exchange(
            "{\"version\":3,\"operation\":\"effect.poll\",\"requestID\":\"bad-1\","
            + "\"envelope\":{\"schema\":\"floe.effect-cursor/3\","
            + "\"scope\":\"applicationConfiguration\","
            + "\"configurationScope\":\"system\",\"command\":\"effect.poll\","
            + "\"stateful\":false,\"correlationID\":\"bad-1\","
            + "\"effect\":{\"operationReceiptID\":\"\(receipt)\","
            + "\"sequence\":\"0\"}}}"))
        XCTAssertEqual(malformed["error"] as? String, "invalidEnvelope")
        let replay = try XCTUnwrap(exchange(effectEnvelope(
            correlation: "carrier-poll-replay", receipt: receipt, sequence: 0)))
        XCTAssertEqual((replay["effects"] as? [[String: Any]])?.count, 1)

        // Foreign receipt: typed notFound, never fabricated.
        let foreign = try XCTUnwrap(exchange(effectEnvelope(
            correlation: "carrier-poll-foreign",
            receipt: "op:v1:" + String(repeating: "ab", count: 16),
            sequence: 0)))
        XCTAssertEqual(foreign["error"] as? String, "runtimeUnavailable")
        XCTAssertEqual(foreign["reason"] as? String, "effectReceiptNotFound")

        // Oversize ATOMIC carrier: a document beyond the actual effect body
        // settles the small typed recoverable terminal (no partial page,
        // no silent drop, no oversize frame).
        let oversizeReceipt = try XCTUnwrap(
            gen.effects.register(correlationID: "carrier-oversize"))
        let oversizeJob = RuntimeCommandEnvelopeJob(
            correlationID: "carrier-oversize", handlerKey: key,
            command: "content.read", scope: .applicationConfiguration,
            configurationScope: "settings.defaults", receipt: oversizeReceipt,
            envelope: Data("{}".utf8))
        gen.registry.register(
            handlerKey: key, configurationScope: "settings.defaults",
            processor: RuntimeAsyncProcessor { _ in
                .accepted(page: DesignJSONValue.object([
                    "content": .string(String(repeating: "中", count: 20_000)),
                ]))
            })
        guard case .queued = gen.mailbox.submit(oversizeJob) else {
            return XCTFail("oversize job must be queued")
        }
        let oversizeOutcome = try await pollUntilTerminal(receipt: oversizeReceipt)
        XCTAssertEqual(oversizeOutcome.terminal?["kind"] as? String, "failed")
        XCTAssertEqual(oversizeOutcome.terminal?["code"] as? String,
                       "frameBudgetExceeded")
        XCTAssertNil(oversizeOutcome.terminal?["page"])

        // Real close: the same terminal stays readable through the retired
        // route; a NEW generation cannot resurrect it into its own pump.
        guard case .accepted = AndroidRuntimeBootstrap.shutdown(
            expectedEpoch: firstEpoch, ownerToken: token) else {
            return XCTFail("stop")
        }
        let retireDeadline = Date().addingTimeInterval(20)
        while AndroidRuntimeBootstrap.currentGenerationForTesting() != nil,
              Date() < retireDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(AndroidRuntimeBootstrap.currentGenerationForTesting())
        let retired = try await pollUntilTerminal(receipt: receipt)
        XCTAssertEqual(retired.terminal?["kind"] as? String, "accepted")
        XCTAssertEqual((retired.terminal?["page"] as? [String: Any])?["key"] as? String,
                       "rb1.carrier.probe")
        let secondEpoch = Self.allocateEpoch()
        guard case .accepted(let secondBootstrapReceipt) = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: token, epoch: secondEpoch) else {
            return XCTFail("start two")
        }
        await waitStoreReady()
        await waitBootstrapTerminal(secondBootstrapReceipt)
        let gen2 = try XCTUnwrap(AndroidRuntimeBootstrap.currentGenerationForTesting())
        if case .notFound = gen2.effects.poll(receipt: receipt, afterSequence: 0) {
            // Old receipt never appears in the new generation's pump.
        } else {
            XCTFail("old generation receipt must not resolve in the new pump")
        }
        let acrossGenerations = try await pollUntilTerminal(receipt: receipt)
        XCTAssertEqual(acrossGenerations.terminal?["kind"] as? String, "accepted")
    }

    func testMultiPageCarrierSplitsByExactFrameBudgetThenAcks() async throws {
        let root = try freshRoot()
        let token = String(repeating: "d", count: 32)
        let epoch = Self.allocateEpoch()
        guard case .accepted(let bootstrapReceipt) = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: token, epoch: epoch) else {
            return XCTFail("start")
        }
        await waitStoreReady()
        await waitBootstrapTerminal(bootstrapReceipt)
        let gen = try XCTUnwrap(AndroidRuntimeBootstrap.currentGenerationForTesting())
        let receipt = try XCTUnwrap(gen.effects.register(correlationID: "carrier-pages"))
        let first = DesignJSONValue.object([
            "page": .integer(1),
            "content": .string(String(repeating: "A", count: 35_000)),
        ])
        let second = DesignJSONValue.object([
            "page": .integer(2),
            "content": .string(String(repeating: "中", count: 10_000)),
        ])
        XCTAssertTrue(gen.effects.append(receipt: receipt, kind: .prepared,
                                         code: nil, detail: nil,
                                         page: first, value: nil).isAppended)
        XCTAssertTrue(gen.effects.append(receipt: receipt, kind: .accepted,
                                         code: nil, detail: nil,
                                         page: second, value: nil).isAppended)
        let one = try XCTUnwrap(exchange(effectEnvelope(
            correlation: "carrier-pages-1", receipt: receipt, sequence: 0)))
        let firstEffects = try XCTUnwrap(one["effects"] as? [[String: Any]])
        XCTAssertEqual(firstEffects.count, 1)             // exact frame split
        XCTAssertEqual(one["hasMore"] as? Bool, true)
        XCTAssertEqual((firstEffects.first?["page"] as? [String: Any])?["page"] as? Int, 1)
        let cursor = try XCTUnwrap(
            (one["cursor"] as? [String: Any])?["sequence"] as? Int)
        let two = try XCTUnwrap(exchange(effectEnvelope(
            correlation: "carrier-pages-2", receipt: receipt, sequence: cursor)))
        let secondEffects = try XCTUnwrap(two["effects"] as? [[String: Any]])
        XCTAssertEqual(secondEffects.count, 1)
        XCTAssertEqual(two["hasMore"] as? Bool, false)
        XCTAssertEqual((secondEffects.first?["page"] as? [String: Any])?["page"] as? Int, 2)
        let end = try XCTUnwrap(
            (two["cursor"] as? [String: Any])?["sequence"] as? Int)
        let done = try XCTUnwrap(exchange(effectEnvelope(
            correlation: "carrier-pages-3", receipt: receipt, sequence: end)))
        XCTAssertEqual((done["effects"] as? [[String: Any]])?.count, 0)
        guard case .accepted = AndroidRuntimeBootstrap.shutdown(
            expectedEpoch: epoch, ownerToken: token) else {
            return XCTFail("stop")
        }
    }

    private static func jsonQuoted(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value,
                                               options: [.fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }
}

/// Test-local projection (the production projection is internal to the core
/// module; tests must not widen its access).
enum RuntimeEffectDocumentTestProjection {
    static func foundationObject(_ value: DesignJSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let flag): return flag
        case .integer(let number): return NSNumber(value: number)
        case .unsigned(let number): return NSNumber(value: number)
        case .decimal(let number):
            return NSDecimalNumber(decimal: number)
        case .number(let double): return NSNumber(value: double)
        case .string(let text): return text
        case .array(let items): return items.map(foundationObject)
        case .object(let pairs):
            var object: [String: Any] = [:]
            for (key, item) in pairs { object[key] = foundationObject(item) }
            return object
        }
    }
}
