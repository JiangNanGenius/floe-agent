#if os(macOS)
// FloeLocalModelsTests — Build 233 grounding-probe plan regression.
//
// Validates the bounded, qualification-only diagnostic plan used to
// discriminate why the real pinned local model fabricates tool results.
// No weights are mapped and no generation runs: these tests assert the
// plan structure, the production-composer flattening and the pure
// needle-span search only.

import Foundation
import Testing
import MLXLMCommon
import FloeCore
import FloeModels
import FloeProviders
@testable import FloeLocalModels
@testable import FloeExecution

@available(macOS 15.4, iOS 26.0, *)
private enum ProbePlanFixtures {
    static let modelID = "qwen3.8-4b-heretic-mlx4"

    static let schemas = [
        ToolSchemaDescriptor(
            name: WebSearchTool.name,
            description: WebSearchTool.toolDescription,
            parametersJSON: WebSearchTool.parametersJSON),
        ToolSchemaDescriptor(name: WebFetchTool.name,
            description: WebFetchTool.toolDescription,
            parametersJSON: WebFetchTool.parametersJSON)
    ]

    static let envelope = "SYNTHETIC ENVELOPE (test only)"

    static func plan() throws -> LocalGroundingProbePlan {
        try LocalGroundingProbePlan.standard(
            envelope: envelope, schemas: schemas, modelID: modelID)
    }

    static func caseByID(_ id: String) throws -> LocalGroundingProbePlan.Case {
        let matches = try plan().cases.filter { $0.id == id }
        #expect(matches.count == 1)
        return matches[0]
    }
}

struct LocalGroundingProbePlanTests {

    @Test @available(macOS 15.4, iOS 26.0, *)
    func standardMatrixHasSevenCasesWithExpectedHypotheses() throws {
        let cases = try ProbePlanFixtures.plan().cases
        #expect(cases.map(\.id) == [
            "copy-minimal", "flat-production", "flat-greedy",
            "flat-no-rep-penalty", "native-tool",
            "native-greedy-noRP", "flat-items-present"
        ])
        #expect(cases.map(\.hypothesis) == [
            "H-COPY", "H-REPR", "H-SAMPLING", "H-REPPENALTY",
            "H-REPR-NATIVE", "H-COMBINED", "H-ITEMS"
        ])
    }

    // MARK: - Needle-span search

    @Test @available(macOS 15.4, iOS 26.0, *)
    func firstSpanFindsNeedle() {
        let ids = [1, 2, 3, 4, 2, 3]
        #expect(LocalGroundingProbePlan.firstSpan(of: [2, 3], in: ids) == 1..<3)
    }

    @Test @available(macOS 15.4, iOS 26.0, *)
    func firstSpanReturnsNilWhenAbsent() {
        #expect(LocalGroundingProbePlan.firstSpan(of: [9], in: [1, 2]) == nil)
        #expect(LocalGroundingProbePlan.firstSpan(of: [1, 2, 3], in: [1, 2]) == nil)
        #expect(LocalGroundingProbePlan.firstSpan(of: [], in: [1]) == nil)
    }

    @Test @available(macOS 15.4, iOS 26.0, *)
    func firstSpanMatchesExactStartAndEndBoundaries() {
        #expect(LocalGroundingProbePlan.firstSpan(of: [1], in: [1, 1, 1]) == 0..<1)
        #expect(LocalGroundingProbePlan.firstSpan(of: [5, 6], in: [5, 6]) == 0..<2)
        #expect(LocalGroundingProbePlan.firstSpan(of: [7, 8], in: [9, 7, 8, 9]) == 1..<3)
    }

    // MARK: - Copy case

    @Test @available(macOS 15.4, iOS 26.0, *)
    func copyCaseIsMinimalDirectPairWithReceiptAsUserText() throws {
        let copy = try ProbePlanFixtures.caseByID("copy-minimal")
        guard case .direct(let specs) = copy.content else {
            Issue.record("copy-minimal must use direct messages"); return
        }
        #expect(specs.map(\.role) == [.system, .user])
        #expect(specs[1].content == LocalGroundingProbePlan.Fixtures.emptyReceipt)
        let messages = LocalGroundingProbePlan.resolveProbeMessages(specs)
        #expect(messages.map(\.role) == [.system, .user])
        #expect(copy.evidenceNeedles == [
            LocalGroundingProbePlan.Fixtures.emptyMarker, "synthetic fixture"
        ])
    }

    // MARK: - Flat production cases

    @Test @available(macOS 15.4, iOS 26.0, *)
    func flatRequestCarriesEnvelopeHistoryReceiptAndPendingPair() throws {
        let flat = try ProbePlanFixtures.caseByID("flat-production")
        guard case .flatContinuation(let request) = flat.content else {
            Issue.record("flat-production must use a flat continuation request"); return
        }
        #expect(request.messages.map(\.role) ==
            ["system", "user", "assistant", "user"])
        #expect(request.messages[0].content == ProbePlanFixtures.envelope)
        #expect(request.messages[3].content.contains("今天的新闻"))
        #expect(request.toolResults.count == 1)
        #expect(request.toolResults[0].output ==
            LocalGroundingProbePlan.Fixtures.emptyReceipt)
        #expect(request.pendingToolCalls.count == 1)
        #expect(request.pendingToolCalls[0].toolName == "web.search")
        #expect(request.replayedToolPairs.count == 1)
        #expect(request.replayedToolPairs[0].result.outputSummary ==
            LocalGroundingProbePlan.Fixtures.emptyReceipt)
    }

    @Test @available(macOS 15.4, iOS 26.0, *)
    func flattenedMessagesUseProductionComposerWithReceiptBeforeDirective() throws {
        let flat = try ProbePlanFixtures.caseByID("flat-production")
        guard case .flatContinuation(let request) = flat.content else {
            Issue.record("flat-production must use a flat continuation request"); return
        }
        let messages = LocalGroundingProbePlan.flattenedMessages(for: request)
        #expect(messages.count == 2)
        #expect(messages[0].role == .system)
        #expect(messages[1].role == .user)
        let user = messages[1].content
        let markerRange = try #require(user.range(
            of: LocalGroundingProbePlan.Fixtures.emptyMarker))
        let directiveRange = try #require(user.range(
            of: "TOOL RESULT GROUNDING"))
        // Receipt evidence precedes the grounding directive.
        #expect(markerRange.lowerBound < directiveRange.lowerBound)
        // The directive itself never embeds a fixture marker.
        let directive = String(user[directiveRange.lowerBound...])
        #expect(!directive.contains("FLOE_SEARCH_RECEIPT_7A31"))
        // The system paragraph carries the receipt-continuation clause.
        #expect(messages[0].content.contains(
            "A TOOL RESULT for the pending call is already present"))
    }

    @Test @available(macOS 15.4, iOS 26.0, *)
    func flatCasesShareIdenticalPreparedMessagesAcrossSamplingVariants() throws {
        func flattened(_ id: String) throws -> [Chat.Message] {
            let probeCase = try ProbePlanFixtures.caseByID(id)
            guard case .flatContinuation(let request) = probeCase.content else {
                Issue.record("\(id) must use a flat continuation request")
                return []
            }
            return LocalGroundingProbePlan.flattenedMessages(for: request)
        }
        let production = try flattened("flat-production")
        let greedy = try flattened("flat-greedy")
        let noPenalty = try flattened("flat-no-rep-penalty")
        // Chat.Message is not Equatable in the pinned revision; compare the
        // resolved roles/content field arrays instead.
        #expect(greedy.map(\.role) == production.map(\.role))
        #expect(greedy.map(\.content) == production.map(\.content))
        #expect(noPenalty.map(\.role) == production.map(\.role))
        #expect(noPenalty.map(\.content) == production.map(\.content))
    }

    // MARK: - Sampling knobs

    @Test @available(macOS 15.4, iOS 26.0, *)
    func samplingAndRepetitionKnobsVaryIndependently() throws {
        let production = try ProbePlanFixtures.caseByID("flat-production")
        #expect(production.temperature == 0.55)
        #expect(production.repetitionPenalty == 1.05)

        let greedy = try ProbePlanFixtures.caseByID("flat-greedy")
        #expect(greedy.temperature == 0)
        #expect(greedy.repetitionPenalty == 1.05)

        let noPenalty = try ProbePlanFixtures.caseByID("flat-no-rep-penalty")
        #expect(noPenalty.temperature == 0.55)
        #expect(noPenalty.repetitionPenalty == 1.0)
    }

    // MARK: - Native protocol cases

    @Test @available(macOS 15.4, iOS 26.0, *)
    func nativeCaseUsesAssistantToolCallsThenToolRole() throws {
        let native = try ProbePlanFixtures.caseByID("native-tool")
        guard case .direct(let specs) = native.content else {
            Issue.record("native-tool must use direct messages"); return
        }
        #expect(specs.map(\.role) ==
            [.system, .user, .assistant, .tool])
        #expect(specs[2].carriesToolCall)
        #expect(specs[3].content ==
            LocalGroundingProbePlan.Fixtures.emptyReceipt)
        let messages = LocalGroundingProbePlan.resolveProbeMessages(specs)
        // Chat.Message is not Equatable in the pinned revision; assert the
        // resolved roles/content field-by-field. The attached tool call is
        // already covered by specs[2].carriesToolCall.
        #expect(messages[2].role == .assistant)
        #expect(messages[2].content == "")
        #expect(messages[3].role == .tool)
        #expect(messages[3].content ==
            LocalGroundingProbePlan.Fixtures.emptyReceipt)
    }

    @Test @available(macOS 15.4, iOS 26.0, *)
    func nativeGreedyCombinesArgmaxAndNoRepetitionPenalty() throws {
        let combined = try ProbePlanFixtures.caseByID("native-greedy-noRP")
        #expect(combined.temperature == 0)
        #expect(combined.repetitionPenalty == 1.0)
        guard case .direct(let specs) = combined.content else {
            Issue.record("native-greedy-noRP must use direct messages"); return
        }
        #expect(specs.map(\.role) ==
            [.system, .user, .assistant, .tool])
    }

    // MARK: - Items-present complementary case

    @Test @available(macOS 15.4, iOS 26.0, *)
    func itemsCaseReceiptCarriesThreeLabeledSyntheticItems() throws {
        let items = try ProbePlanFixtures.caseByID("flat-items-present")
        #expect(items.evidenceNeedles == [
            LocalGroundingProbePlan.Fixtures.itemsMarker, "SYNTHETIC ITEM"
        ])
        guard case .flatContinuation(let request) = items.content else {
            Issue.record("flat-items-present must use a flat continuation request"); return
        }
        let receipt = request.toolResults[0].output
        #expect(receipt.contains(LocalGroundingProbePlan.Fixtures.itemsMarker))
        #expect(receipt.contains("SYNTHETIC ITEM 8C44-A"))
        #expect(receipt.contains("SYNTHETIC ITEM 8C44-B"))
        #expect(receipt.contains("SYNTHETIC ITEM 8C44-C"))
        // The items receipt still truthfully identifies no live search.
        #expect(receipt.contains("no live search performed"))
    }
}

#endif
