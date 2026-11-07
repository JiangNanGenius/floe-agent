import Foundation
import FloeCore
import FloeTools

/// A compiled data operation, never a language-specific execution alias.
public struct NativeDataAnalysisTool: AgentTool {
    public typealias Arguments = ScientificDataAnalysis.Request
    public static let name = "data.analyze"
    public static let toolDescription = "Analyze supplied numeric data offline using fixed native operations: summarize (sum, mean, quartiles, population/sample variance and sample standard deviation); linearRegression (values=x, pairedValues=y, unweighted OLS with intercept, Pearson r, R squared and residuals); histogram (equal-width bin counts and actual edges). Up to 4096 observations per series, finite magnitude <=1e100. Nulls fail unless missingPolicy=omit; regression omits complete rows as pairs. Undefined sample/correlation statistics are omitted, never invented as zero. Returns complete structured JSON with numerical conventions. No file access, scripts, interpreters, packages, network, persistence or environment startup. Read larger/source data using the existing authorized file tools; use exec.shell in the resolved Linux environment for general programs, advanced statistics or symbolic mathematics."
    public static let parametersJSON = #"""
    {"type":"object","properties":{"action":{"type":"string","enum":["summarize","linearRegression","histogram"]},"values":{"type":"array","minItems":1,"maxItems":4096,"items":{"type":["number","null"]},"description":"Observations, or x for linearRegression; magnitude at most 1e100."},"pairedValues":{"type":"array","minItems":1,"maxItems":4096,"items":{"type":["number","null"]},"description":"y, required only for linearRegression, same length as values."},"binCount":{"type":"integer","minimum":1,"maximum":128,"description":"Only for histogram; defaults to min(20, retained observation count). Constant data yields one bin."},"missingPolicy":{"type":"string","enum":["reject","omit"],"description":"Default reject. omit explicitly drops null observations, pairwise for regression."}},"required":["action","values"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    public init() {}

    public func validate(_ args: Arguments) throws {
        do { try ScientificDataAnalysis.validate(args) }
        catch { throw FloeError.validationFailed(error.localizedDescription) }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let report = try ScientificDataAnalysis.analyze(args, checkCancellation: {
            try context.cancellation.throwIfCancelled()
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(report)
        try context.cancellation.throwIfCancelled()
        return ToolExecutionOutput(digesting: String(decoding: json, as: UTF8.self),
                                   exitStatus: 0, maximumSummaryCharacters: 65_536)
    }
}
