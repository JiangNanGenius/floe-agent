#if canImport(UIKit)
import XCTest
@testable import FloeCanvasUI
import FloeCanvasCore
import FloeCanvasIntegration
import FloeCanvasFlow

/// P1d run-output placement transaction regressions: async identity
/// fencing across the result-fetch suspension, truthful committed/draft
/// outcome through the single CAS pipeline, lost-ack idempotent replay,
/// repeated-button replay of the pending draft, full-list JSON + typed
/// asset materialization, resource bounds, and durable reopen.
///
/// Native iOS only (UIKit-gated): the headless macOS package test does
/// NOT verify UI.
@MainActor
final class CanvasRunOutputTransactionTests: XCTestCase {

    // MARK: Fixtures

    private func waitFor(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("waitFor timed out", file: file, line: line)
                return
            }
            await Task.yield()
        }
    }

    private struct FakeBindingResolver: FlowCanvasBindingResolver {
        var value: FlowValue
        func resolve(canvasBinding name: String, context: CanvasRuntimeContext) async throws -> FlowValue {
            value
        }
    }

    private func makeStore(
        snapshot: CanvasSnapshot,
        documentStore: any CanvasDocumentStore,
        bindingResolver: (any FlowCanvasBindingResolver)? = nil
    ) -> CanvasEditorStore {
        CanvasEditorStore(
            canvasID: snapshot.id,
            services: CanvasEditorServices(
                documentStore: documentStore,
                makeFlowRuntime: { FlowRuntimeService(executor: nil, bindingResolver: bindingResolver) },
                makeRunConfiguration: { snapshot, pageID, graph in
                    FlowRunConfiguration(
                        identity: FlowRunIdentity(
                            canvasID: snapshot.id,
                            canvasRevision: snapshot.revision,
                            flowGraphID: graph.id,
                            flowGraphRevision: graph.revision,
                            environmentID: ""),
                        pageID: pageID,
                        configurationDigest: "test-digest")
                }))
    }

    /// source(constant "hello") → output(resultKey "text")
    private func textGraph() -> FlowGraph {
        let source = FlowNode(
            kind: .source,
            name: "S",
            ports: [FlowPort(name: "text", dataType: .string, direction: .output)],
            parameters: [
                "sourceKind": .string("constant"),
                "literal": .string("hello"),
            ])
        let output = FlowNode(
            kind: .output,
            name: "O",
            ports: [FlowPort(name: "text", dataType: .string, direction: .input)],
            parameters: ["resultKey": .string("text")])
        return FlowGraph(
            revision: 0,
            nodes: [source, output],
            edges: [FlowEdge(
                sourceNodeID: source.id, sourcePortID: source.ports[0].id,
                destinationNodeID: output.id, destinationPortID: output.ports[0].id)])
    }

    /// source(canvasBinding "batch") → output(resultKey "items")
    private func batchGraph() -> FlowGraph {
        let source = FlowNode(
            kind: .source,
            name: "S",
            ports: [FlowPort(name: "items", dataType: .list, direction: .output)],
            parameters: [
                "sourceKind": .string("canvasBinding"),
                "bindingKey": .string("batch"),
            ])
        let output = FlowNode(
            kind: .output,
            name: "O",
            ports: [FlowPort(name: "items", dataType: .list, direction: .input)],
            parameters: ["resultKey": .string("items")])
        return FlowGraph(
            revision: 0,
            nodes: [source, output],
            edges: [FlowEdge(
                sourceNodeID: source.id, sourcePortID: source.ports[0].id,
                destinationNodeID: output.id, destinationPortID: output.ports[0].id)])
    }

    private func runToCompletion(_ store: CanvasEditorStore) async -> UUID {
        let started = await store.startFlowRun()
        XCTAssertTrue(started)
        await waitFor(timeout: 10) { store.flowRun?.phase == .completed }
        return try! XCTUnwrap(store.flowRun?.runID)
    }

    private func batchValue(locatorA: CanvasAssetLocator, locatorB: CanvasAssetLocator) -> FlowValue {
        .list([
            .string("intro"),
            .asset(locatorA),
            .list([.number(2.5), .json(.number("9007199254740993")), .asset(locatorB)]),
        ])
    }

    // MARK: Truthful commit outcome

    func testPlacementCommitFailureStaysRecoverableWithoutFalseSuccess() async throws {
        let graph = textGraph()
        let page = CanvasPageSnapshot(name: "P", flowGraphs: [graph])
        let snapshot = CanvasSnapshot(name: "s", pages: [page])
        let base = InMemoryCanvasRepository(snapshot: snapshot)
        let failing = CanvasTestStubs.FailingCommitStore(base: base, failNextCommit: true)
        let store = makeStore(snapshot: snapshot, documentStore: failing)
        await store.load()
        _ = await runToCompletion(store)

        let result = await store.placeFlowRunOutputsOnPage()
        XCTAssertEqual(result?.committed, false, "unconfirmed placement never claims success")
        XCTAssertEqual(result?.placedCount, 0)
        XCTAssertEqual(store.alert?.kind, .saveFailed)
        XCTAssertEqual(store.revision, 0, "failed commit must not advance the revision")
        XCTAssertEqual(store.page.nodes.count, 0, "no cards appear without a confirmed commit")
        let draft = try XCTUnwrap(store.drafts.first, "failure stays recoverable as a draft")
        XCTAssertFalse(draft.didConflict)

        await store.retryDraft(draft)
        XCTAssertTrue(store.drafts.isEmpty)
        XCTAssertEqual(store.revision, 1)
        XCTAssertEqual(store.page.nodes.count, 1)
        await store.undo()
        XCTAssertEqual(store.page.nodes.count, 0, "the recovered placement is still exactly one undo unit")
    }

    func testPlacementLostAcknowledgementRetryReplaysSameRequest() async throws {
        let graph = textGraph()
        let page = CanvasPageSnapshot(name: "P", flowGraphs: [graph])
        let snapshot = CanvasSnapshot(name: "s", pages: [page])
        let base = InMemoryCanvasRepository(snapshot: snapshot)
        let lostAck = CanvasTestStubs.LostAckStore(base: base)
        let store = makeStore(snapshot: snapshot, documentStore: lostAck)
        await store.load()
        _ = await runToCompletion(store)

        let result = await store.placeFlowRunOutputsOnPage()
        XCTAssertEqual(result?.committed, false, "lost acknowledgement is not a confirmed placement")
        XCTAssertEqual(store.drafts.count, 1)
        XCTAssertEqual(store.revision, 0, "store could not observe the repository-side commit")

        let draft = try XCTUnwrap(store.drafts.first)
        await store.retryDraft(draft)
        XCTAssertTrue(store.drafts.isEmpty)
        XCTAssertEqual(store.revision, 1, "replay returned the original receipt")
        XCTAssertEqual(store.page.nodes.count, 1, "no duplicate insert")
        let history = try await base.historyAvailability(canvasID: snapshot.id)
        XCTAssertEqual(history.undoCount, 1, "exactly one undo unit — the lost batch never mutated twice")
    }

    func testRepeatedPlaceButtonReplaysPendingDraftWithoutDuplicates() async throws {
        let graph = textGraph()
        let page = CanvasPageSnapshot(name: "P", flowGraphs: [graph])
        let snapshot = CanvasSnapshot(name: "s", pages: [page])
        let base = InMemoryCanvasRepository(snapshot: snapshot)
        let lostAck = CanvasTestStubs.LostAckStore(base: base)
        let store = makeStore(snapshot: snapshot, documentStore: lostAck)
        await store.load()
        _ = await runToCompletion(store)

        let first = await store.placeFlowRunOutputsOnPage()
        XCTAssertEqual(first?.committed, false)
        XCTAssertEqual(store.drafts.count, 1)

        // Pressing the button again replays the SAME batch/request/nodes
        // instead of minting a duplicate placement.
        let second = await store.placeFlowRunOutputsOnPage()
        XCTAssertEqual(second?.committed, true, "replay of the pending draft confirms once the failure clears")
        XCTAssertEqual(second?.placedCount, 1)
        XCTAssertEqual(store.drafts.count, 0)
        XCTAssertEqual(store.revision, 1)
        XCTAssertEqual(store.page.nodes.count, 1, "no duplicate outputs")
        let history = try await base.historyAvailability(canvasID: snapshot.id)
        XCTAssertEqual(history.undoCount, 1, "repeated button never produced a second mutation")
    }

    // MARK: Async identity fencing

    func testPlacementRefusesWhenPageChangesWhileFetchingResult() async throws {
        let graph = textGraph()
        let pageA = CanvasPageSnapshot(name: "A", flowGraphs: [graph])
        let pageB = CanvasPageSnapshot(name: "B")
        let snapshot = CanvasSnapshot(name: "s", pages: [pageA, pageB])
        let base = InMemoryCanvasRepository(snapshot: snapshot)
        let store = makeStore(snapshot: snapshot, documentStore: base)
        await store.load()
        _ = await runToCompletion(store)

        // The placement task is enqueued first; fetching the run result
        // hops off the main actor, so the page switch lands mid-flight.
        let placement = Task { await store.placeFlowRunOutputsOnPage() }
        await store.selectPage(pageB.id)
        let result = await placement.value

        XCTAssertNil(result, "placement must refuse when the page changes across the suspension")
        XCTAssertEqual(store.alert?.kind, .invalidFlow)
        XCTAssertTrue(store.page.nodes.isEmpty, "nothing lands on the newly selected page")
        XCTAssertTrue(store.drafts.isEmpty, "a refused placement never leaves a draft")
        await store.selectPage(pageA.id)
        XCTAssertTrue(store.page.nodes.isEmpty, "the original page receives no partial placement either")
    }

    func testPlacementHonorsRealCASConflictAsRecoverableDraft() async throws {
        let graph = textGraph()
        let page = CanvasPageSnapshot(name: "P", flowGraphs: [graph])
        let snapshot = CanvasSnapshot(name: "s", pages: [page])
        let base = InMemoryCanvasRepository(snapshot: snapshot)
        let store = makeStore(snapshot: snapshot, documentStore: base)
        await store.load()
        _ = await runToCompletion(store)

        // A concurrent writer commits underneath the store.
        let concurrent = CanvasDocumentBatch(
            scope: .wholeDocument,
            operations: [.editPage(.init(
                pageID: page.id,
                scope: .wholeDocument,
                operations: [.insertNode(CanvasTestStubs.textNode(
                    "concurrent", center: .init(x: 20, y: 20)))]))])
        _ = try await base.commitDocument(
            concurrent, canvasID: snapshot.id,
            expectedRevision: 0, requestID: UUID())

        let result = await store.placeFlowRunOutputsOnPage()
        XCTAssertEqual(result?.committed, false, "real CAS conflict is not a confirmed placement")
        XCTAssertEqual(result?.placedCount, 0)
        XCTAssertEqual(store.alert?.kind, .revisionConflict)
        let draft = try XCTUnwrap(store.drafts.first)
        XCTAssertTrue(draft.didConflict)
        XCTAssertEqual(store.revision, 1, "current content reloaded")
        XCTAssertEqual(store.page.nodes.count, 1, "concurrent content visible, no run cards")

        await store.rebaseDraft(draft)
        XCTAssertTrue(store.drafts.isEmpty)
        XCTAssertEqual(store.revision, 2)
        XCTAssertEqual(store.page.nodes.count, 2, "explicit rebase commits the same cards as a new request")
        await store.undo()
        XCTAssertEqual(store.page.nodes.count, 1, "placement is exactly one undo unit on top")
    }

    // MARK: Full-list JSON + typed asset materialization

    func testBatchListOutputSavedAsFullJSONWithTypedAssetCards() async throws {
        let locatorA = CanvasAssetLocator(
            contentHash: "hash-a", relativePath: "media/a.png",
            mimeType: "image/png", byteCount: 128)
        let locatorB = CanvasAssetLocator(
            relativePath: "media/b.pdf", mimeType: "application/pdf", byteCount: 2048)
        let graph = batchGraph()
        let page = CanvasPageSnapshot(name: "P", flowGraphs: [graph])
        let snapshot = CanvasSnapshot(name: "s", pages: [page])
        let base = InMemoryCanvasRepository(snapshot: snapshot)
        let store = makeStore(
            snapshot: snapshot, documentStore: base,
            bindingResolver: FakeBindingResolver(
                value: batchValue(locatorA: locatorA, locatorB: locatorB)))
        await store.load()
        let runID = await runToCompletion(store)

        let result = await store.placeFlowRunOutputsOnPage()
        XCTAssertEqual(result?.placedCount, 3, "one full-list JSON card + two typed asset media cards")
        XCTAssertEqual(result?.unsupportedCount, 0)
        XCTAssertEqual(result?.committed, true)
        let placedNodes = store.page.nodes.filter { $0.createdByRunID == runID }
        XCTAssertEqual(placedNodes.count, 3)

        // The whole batch survives as valid, editable JSON — full values,
        // exact Unicode, exact number literals, structured asset identity.
        let jsonCard = try XCTUnwrap(placedNodes.first(where: {
            $0.metadata[CanvasEditorStore.RunOutputMetadataKeys.runOutputKey] == "items"
        }))
        guard case .code(let language, let source) = jsonCard.content else {
            return XCTFail("batch output becomes an editable JSON code card")
        }
        XCTAssertEqual(language, "json")
        let parsed = try JSONFidelity.parse(Data(source.utf8))
        guard case .array(let elements) = parsed, elements.count == 3 else {
            return XCTFail("full list preserved as a JSON array")
        }
        XCTAssertEqual(elements[0].stringValue, "intro")
        let embeddedA = try XCTUnwrap(elements[1].objectValue)
        XCTAssertEqual(embeddedA["id"]?.stringValue, locatorA.id.uuidString)
        XCTAssertEqual(embeddedA["mimeType"]?.stringValue, "image/png")
        let nested = try XCTUnwrap(elements[2].arrayValue)
        XCTAssertEqual(nested.count, 3)
        XCTAssertEqual(nested[0].numberLiteral, "2.5")
        XCTAssertEqual(nested[1].numberLiteral, "9007199254740993",
                       "exact literal preserved — no Int64(Double) overflow")
        let embeddedB = try XCTUnwrap(nested[2].objectValue)
        XCTAssertEqual(embeddedB["relativePath"]?.stringValue, "media/b.pdf")

        // Typed asset leaves become real media cards with structured
        // output-key/path metadata — the archive embeds bytes from these,
        // never by scanning the opaque JSON text.
        let assetA = try XCTUnwrap(placedNodes.first(where: {
            $0.metadata[CanvasEditorStore.RunOutputMetadataKeys.runOutputKey] == "items[1]"
        }))
        guard case .media(let mediaA) = assetA.content else {
            return XCTFail("typed asset leaf becomes a media card")
        }
        XCTAssertEqual(mediaA.id, locatorA.id)
        XCTAssertEqual(assetA.metadata[CanvasEditorStore.RunOutputMetadataKeys.runOutputAssetPath], "[1]")
        let assetB = try XCTUnwrap(placedNodes.first(where: {
            $0.metadata[CanvasEditorStore.RunOutputMetadataKeys.runOutputKey] == "items[2][2]"
        }))
        guard case .media(let mediaB) = assetB.content else {
            return XCTFail("nested typed asset leaf becomes a media card")
        }
        XCTAssertEqual(mediaB.id, locatorB.id)
        XCTAssertEqual(assetB.metadata[CanvasEditorStore.RunOutputMetadataKeys.runOutputAssetPath], "[2][2]")

        await store.undo()
        XCTAssertEqual(store.page.nodes.count, 0, "one undo removes the whole batch placement")
    }

    func testBatchAssetCardsDedupePerRunKeyAndPath() async throws {
        let locatorA = CanvasAssetLocator(
            contentHash: "hash-a", relativePath: "media/a.png",
            mimeType: "image/png", byteCount: 128)
        let locatorB = CanvasAssetLocator(
            relativePath: "media/b.pdf", mimeType: "application/pdf", byteCount: 2048)
        let graph = batchGraph()
        let page = CanvasPageSnapshot(name: "P", flowGraphs: [graph])
        let snapshot = CanvasSnapshot(name: "s", pages: [page])
        let base = InMemoryCanvasRepository(snapshot: snapshot)
        let store = makeStore(
            snapshot: snapshot, documentStore: base,
            bindingResolver: FakeBindingResolver(
                value: batchValue(locatorA: locatorA, locatorB: locatorB)))
        await store.load()
        _ = await runToCompletion(store)

        let first = await store.placeFlowRunOutputsOnPage()
        XCTAssertEqual(first?.placedCount, 3)
        let jsonCard = try XCTUnwrap(store.page.nodes.first(where: {
            $0.metadata[CanvasEditorStore.RunOutputMetadataKeys.runOutputKey] == "items"
        }))
        // Delete only the JSON card; the asset cards stay.
        store.select(jsonCard.id)
        await store.apply(.deleteSelection)
        XCTAssertEqual(store.page.nodes.count, 2)

        let again = await store.placeFlowRunOutputsOnPage()
        XCTAssertEqual(again?.placedCount, 1, "only the missing card is recreated")
        XCTAssertEqual(again?.alreadyPlacedCount, 2, "dedupe is per run + output key + path")
        XCTAssertEqual(again?.committed, true)
        XCTAssertEqual(store.page.nodes.count, 3)
    }

    // MARK: Resource bounds (explicit, recoverable)

    func testOversizedBatchIsRecoverableAndRetainsRunResult() async throws {
        // 70 nested lists exceed the default 64-level depth bound.
        var deep: FlowValue = .string("bottom")
        for _ in 0..<70 { deep = .list([deep]) }
        let graph = batchGraph()
        let page = CanvasPageSnapshot(name: "P", flowGraphs: [graph])
        let snapshot = CanvasSnapshot(name: "s", pages: [page])
        let base = InMemoryCanvasRepository(snapshot: snapshot)
        let store = makeStore(
            snapshot: snapshot, documentStore: base,
            bindingResolver: FakeBindingResolver(value: deep))
        await store.load()
        _ = await runToCompletion(store)

        let result = await store.placeFlowRunOutputsOnPage()
        XCTAssertNil(result, "an unmaterializable batch is an explicit refusal, not a truncated success")
        XCTAssertEqual(store.alert?.kind, .invalidFlow)
        XCTAssertEqual(store.page.nodes.count, 0, "nothing is placed, nothing is dropped")
        XCTAssertEqual(store.flowRun?.phase, .completed, "the runtime result stays intact")
    }

    func testPrepareBatchBoundsAreEnforced() throws {
        var deep: FlowValue = .string("x")
        for _ in 0..<70 { deep = .list([deep]) }
        XCTAssertThrowsError(
            try CanvasRunOutputPlacement.prepareBatch([deep])
        ) { error in
            XCTAssertEqual(
                (error as? CanvasRunOutputPlacement.MappingError)?.code, .listTooDeep)
        }

        let manyAssets = FlowValue.list(
            (0..<70).map { _ in FlowValue.asset(CanvasAssetLocator()) })
        XCTAssertThrowsError(
            try CanvasRunOutputPlacement.prepareBatch([manyAssets])
        ) { error in
            XCTAssertEqual(
                (error as? CanvasRunOutputPlacement.MappingError)?.code, .tooManyAssetCards)
        }

        let tightLimits = CanvasRunOutputPlacement.Limits(
            maxListDepth: 64, maxListJSONByteCount: 16, maxListAssetCards: 64)
        XCTAssertThrowsError(
            try CanvasRunOutputPlacement.prepareBatch(
                [.string("a string clearly longer than sixteen bytes")],
                limits: tightLimits)
        ) { error in
            XCTAssertEqual(
                (error as? CanvasRunOutputPlacement.MappingError)?.code, .listTooLarge)
        }

        let prepared = try CanvasRunOutputPlacement.prepareBatch([.string("a")])
        guard case .code(let language, _) = prepared.content else {
            return XCTFail("in-bounds batch maps to a JSON code card")
        }
        XCTAssertEqual(language, "json")
        XCTAssertTrue(prepared.assetLeaves.isEmpty)
    }

    // MARK: Durable reopen

    func testPlacedBatchCardsSurviveStoreReopen() async throws {
        let locatorA = CanvasAssetLocator(
            contentHash: "hash-a", relativePath: "media/a.png",
            mimeType: "image/png", byteCount: 128)
        let locatorB = CanvasAssetLocator(
            relativePath: "media/b.pdf", mimeType: "application/pdf", byteCount: 2048)
        let graph = batchGraph()
        let page = CanvasPageSnapshot(name: "P", flowGraphs: [graph])
        let snapshot = CanvasSnapshot(name: "s", pages: [page])
        let base = InMemoryCanvasRepository(snapshot: snapshot)
        let store = makeStore(
            snapshot: snapshot, documentStore: base,
            bindingResolver: FakeBindingResolver(
                value: batchValue(locatorA: locatorA, locatorB: locatorB)))
        await store.load()
        let runID = await runToCompletion(store)
        let result = await store.placeFlowRunOutputsOnPage()
        XCTAssertEqual(result?.committed, true)

        // A fresh store over the same repository sees the committed cards.
        let reopened = makeStore(snapshot: snapshot, documentStore: base)
        await reopened.load()
        let placed = reopened.page.nodes.filter { $0.createdByRunID == runID }
        XCTAssertEqual(placed.count, 3, "placed cards are durable committed state")
        XCTAssertEqual(
            placed.first(where: {
                $0.metadata[CanvasEditorStore.RunOutputMetadataKeys.runOutputKey] == "items"
            })?.content.isCodeContent ?? false, true)
        let asset = try XCTUnwrap(placed.first(where: {
            $0.metadata[CanvasEditorStore.RunOutputMetadataKeys.runOutputKey] == "items[1]"
        }))
        XCTAssertEqual(
            asset.metadata[CanvasEditorStore.RunOutputMetadataKeys.runOutputAssetPath], "[1]",
            "structured asset metadata survives reopen")

        await reopened.undo()
        XCTAssertEqual(reopened.page.nodes.count, 0, "one undo still removes the whole placement after reopen")
    }

    func testBatchTooLargeStringsLocalized() {
        let english = CanvasStrings(language: .english)[.debuggerRunBatchTooLarge]
        let chinese = CanvasStrings(language: .simplifiedChinese)[.debuggerRunBatchTooLarge]
        XCTAssertTrue(english.contains("%@"))
        XCTAssertTrue(chinese.contains("%@"))
        XCTAssertFalse(english.isEmpty)
        XCTAssertFalse(chinese.isEmpty)
    }
}

private extension CanvasContent {
    var isCodeContent: Bool {
        if case .code = self { return true }
        return false
    }
}

#endif // canImport(UIKit)
