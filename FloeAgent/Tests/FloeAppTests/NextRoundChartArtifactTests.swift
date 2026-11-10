// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
import FloeExecution
import FloeNativeChartsCore

@Suite("Forty native charts in saved answer artifacts", .serialized)
struct NextRoundChartArtifactTests {
    @Test func allContractsReachTheRealWriterAndReturnAnOwnedInlineReference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inline-chart-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        let writer = PresentationArtifactTool(rootURLProvider: { root })
        for kind in ChartKind.allCases {
            let contract = try await PresentationChartContractTool().execute(.init(type: kind), context: context)
            // The runtime consumes the authoritative capture; the display
            // summary is deliberately bounded and may end within JSON.
            let contractText = contract.capturedOutput ?? contract.summary
            #expect(FloeDigest.sha256Hex(Data(contractText.utf8)) == contract.fullOutputSHA256)
            let output = try #require(JSONSerialization.jsonObject(with: Data(contractText.utf8)) as? [String: Any])
            let example = try #require(output["chart"] as? [String: Any])
            let args = try JSONDecoder().decode(PresentationArtifactTool.Arguments.self,
                from: JSONSerialization.data(withJSONObject: ["kind": "chart", "chart": example]))
            let created = try await writer.execute(args, context: context)
            let artifact = try #require(created.artifacts.first)
            let data = try Data(contentsOf: root.appendingPathComponent(artifact.relativePath))
            #expect(FloeDigest.sha256Hex(data) == artifact.sha256)
            #expect(ChatInlineContentCatalog.accepts(artifact, runID: context.runID, tool: PresentationArtifactTool.name))
            guard case .v2(let saved) = try ChartDocumentCodec.decode(data) else { Issue.record("New chart became legacy"); continue }
            #expect(saved.document.type == kind)
            #expect(saved.document == args.chart?.document)
            let summary = try #require(JSONSerialization.jsonObject(with: Data(created.summary.utf8)) as? [String: String])
            let reference = try #require(summary["inlineMarkdown"])
            #expect(reference.contains(context.runID.uuidString) && reference.contains(artifact.id.uuidString))
            let verified = try VerifiedChatInlineArtifact.load(artifact, runID: context.runID, tool: PresentationArtifactTool.name, root: root)
            #expect(verified.data == data)
        }
    }

    @Test func unknownNestedFieldsAreReportedInsteadOfSilentlyLost() throws {
        let input = #"{"kind":"chart","chart":{"schemaVersion":2,"type":"scatter","data":{"kind":"cartesian","records":[{"id":"a","x":{"kind":"number","value":1},"y":2,"madeUpUnit":"mm"}]}}}"#
        do {
            _ = try JSONDecoder().decode(PresentationArtifactTool.Arguments.self, from: Data(input.utf8))
            Issue.record("An unsupported field was discarded")
        } catch {
            // Error bridging across the App/test-host images need not retain
            // the concrete Swift type. The caller-facing field error must.
            let detail = error.localizedDescription
            #expect(detail.contains("data.records[0]"))
            #expect(detail.contains("unknown fields: madeUpUnit"))
        }
    }

    @Test func legacyInputStaysLegacyAndConflictingContractsAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-chart-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = PresentationArtifactTool(rootURLProvider: { root })
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        let old = try await writer.execute(.init(kind: .chart, chartType: .line,
            series: [.init(name: "Original", points: [.init(label: "A", value: 2)])]), context: context)
        let artifact = try #require(old.artifacts.first)
        let data = try Data(contentsOf: root.appendingPathComponent(artifact.relativePath))
        guard case .legacy(let saved) = try ChartDocumentCodec.decode(data) else { Issue.record("Legacy chart changed format"); return }
        #expect(saved.type == .line && saved.series.first?.points.first?.value == 2)
        let chart = try InlineChartPayload(document: .init(type: .scatter, data: .cartesian([.init(id: "a", x: .number(1), y: 2)])))
        #expect(throws: FloeError.self) { try writer.validate(.init(kind: .chart, chartType: .line, chart: chart)) }
        #expect(throws: FloeError.self) { try writer.validate(.init(kind: .table, chart: chart)) }
    }

    @Test func fieldSchemaResolvesEveryReferenceAndListsAllFortyTypes() throws {
        let schema = try #require(JSONSerialization.jsonObject(with: Data(PresentationArtifactTool.parametersJSON.utf8)) as? [String: Any])
        let definitions = try #require(schema["$defs"] as? [String: Any])
        func check(_ value: Any) {
            if let object = value as? [String: Any] {
                if let reference = object["$ref"] as? String {
                    #expect(reference.hasPrefix("#/$defs/") && definitions[String(reference.dropFirst(8))] != nil)
                }
                for child in object.values { check(child) }
            } else if let array = value as? [Any] { for child in array { check(child) } }
        }
        check(schema)
        let kinds = try #require(definitions["ChartKind"] as? [String: Any])
        #expect(Set(kinds["enum"] as? [String] ?? []) == Set(ChartKind.allCases.map(\.rawValue)))
    }
}
#endif
