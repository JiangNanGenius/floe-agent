// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeNativeChartsCore

/// On-demand complete contracts keep the discovery description small while
/// giving the model typed records and a working example for every chart.
public struct PresentationChartContractTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var type: ChartKind?
        public init(type: ChartKind? = nil) { self.type = type }
    }
    public static let name = "document.presentation.chartContract"
    public static let toolDescription = "Discover 40 native inline chart types, or obtain a complete JSON field contract and validated example for one type before document.presentation.createInline. Supports statistics, OHLC/price-volume, numeric/time scatter, hierarchy/network/flows and schedules. No chart is created here. 图表、统计、金融、关系与时间安排的原生字段及完整示例。"
    public static let parametersJSON: String = {
        let root: [String: Any] = ["type": "object", "properties": ["type": ["type": "string", "enum": ChartKind.allCases.map(\.rawValue)]], "additionalProperties": false]
        return String(decoding: try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), as: UTF8.self)
    }()
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false

    public init() {}
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
        var result: [String: Any] = ["types": ChartCatalog.descriptors.map {
            ["type": $0.kind.rawValue, "family": $0.family.rawValue,
             "dataKinds": $0.dataKinds.map(\.rawValue).sorted()] as [String: Any]
        }]
        if let kind = args.type {
            guard let url = Bundle.module.url(forResource: "PresentationChartExamples", withExtension: "json"),
                  let examples = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                  let example = examples[kind.rawValue] as? [String: Any] else {
                throw FloeError.validationFailed("The bundled chart example is unavailable")
            }
            let exampleData = try JSONSerialization.data(withJSONObject: example, options: [.sortedKeys])
            guard case .v2(let prepared) = try ChartDocumentCodec.decode(exampleData), prepared.document.type == kind else {
                throw FloeError.validationFailed("The bundled chart example does not match its type")
            }
            result["chart"] = example
            result["schema"] = try JSONSerialization.jsonObject(with: ChartWireSchema.documentSchema())
            result["instructions"] = "Replace the synthetic example with the user's actual data, then submit {kind:chart,chart:<document>}. Keep schemaVersion:2; do not combine chart with legacy chartType/series. Coordinate kinds are category/number/instant/localDate; date-times use ISO8601 and localDate uses YYYY-MM-DD. Axes: x and series.axisID (default y); volume may have its own unit. State statistics assumptions, interval meaning and method; never invent measurements. Samples and aggregate bins/box summaries/density are distinct payloads. Missing values are explicit nulls where allowed. Flow and hierarchy IDs must reference actual nodes. Keep provenance when supplied. Copy returned inlineMarkdown between answer paragraphs. After a correction, create a new artifact and reference the new result; retain the original."
            result["limits"] = ["documentBytes": 1_048_576, "series": 16, "records": 2_000]
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        return ToolExecutionOutput(summary: String(decoding: data, as: UTF8.self),
            fullOutputSHA256: FloeDigest.sha256Hex(data))
    }
}
