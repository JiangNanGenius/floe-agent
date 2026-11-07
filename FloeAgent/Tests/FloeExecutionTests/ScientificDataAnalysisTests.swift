import Foundation
import Testing
#if FLOE_SCIENTIFIC_CORE_ONLY
@testable import FloeScientificAnalysisQualification
#else
import FloeCore
import FloeTools
@testable import FloeExecution
#endif

@Suite("Native scientific data analysis")
struct ScientificDataAnalysisTests {
    typealias Analysis = ScientificDataAnalysis

    @Test("Descriptive statistics distinguish population and sample conventions")
    func descriptiveStatistics() throws {
        let report = try Analysis.analyze(.init(action: .summarize, values: [1, 2, 3, 4, 5]))
        let result = try #require(report.summary)
        #expect(result.count == 5 && result.sum == 15 && result.mean == 3)
        #expect(result.minimum == 1 && result.maximum == 5)
        #expect(result.firstQuartile == 2 && result.median == 3 && result.thirdQuartile == 4)
        #expect(result.populationVariance == 2 && result.sampleVariance == 2.5)
        #expect(abs(try #require(result.sampleStandardDeviation) - sqrt(2.5)) < 1e-14)
        #expect(report.omittedCount == 0)
    }

    @Test("Even-length quartiles use the documented type 7 interpolation")
    func interpolatedQuartiles() throws {
        let result = try #require(Analysis.analyze(.init(action: .summarize, values: [4, 1, 3, 2])).summary)
        #expect(result.firstQuartile == 1.75 && result.median == 2.5 && result.thirdQuartile == 3.25)
    }

    @Test("One observation has no invented sample variance")
    func singleObservation() throws {
        let result = try #require(Analysis.analyze(.init(action: .summarize, values: [42])).summary)
        #expect(result.mean == 42 && result.populationVariance == 0)
        #expect(result.sampleVariance == nil && result.sampleStandardDeviation == nil)
    }

    @Test("Signed cancellation preserves the sum and mean")
    func compensatedSum() throws {
        let result = try #require(Analysis.analyze(.init(action: .summarize, values: [1e100, 1, -1e100])).summary)
        #expect(result.sum == 1 && result.mean == 1.0 / 3.0)
        #expect(result.sampleVariance?.isFinite == true)
    }

    @Test("Large offsets preserve measured small variations")
    func shiftedVariance() throws {
        let result = try #require(Analysis.analyze(.init(action: .summarize,
            values: [1e12 + 1, 1e12 + 2, 1e12 + 3])).summary)
        #expect(result.mean == 1e12 + 2 && result.sampleVariance == 1)
    }

    @Test("Regression computes a fitted line and residual degrees of freedom")
    func exactRegression() throws {
        let result = try #require(Analysis.analyze(.init(action: .linearRegression,
            values: [1, 2, 3, 4], pairedValues: [3, 5, 7, 9])).regression)
        #expect(result.slope == 2 && result.intercept == 1)
        #expect(abs(try #require(result.pearsonR) - 1) < 1e-14)
        #expect(abs(try #require(result.rSquared) - 1) < 1e-14)
        #expect(result.residualSumOfSquares == 0 && result.rootMeanSquaredError == 0)
        #expect(result.residualDegreesOfFreedom == 2 && result.residualStandardDeviation == 0)
    }

    @Test("A non-perfect regression agrees with a separate rational calculation")
    func noisyRegression() throws {
        // x mean=2, y mean=8/3, Sxx=2, Sxy=3, Syy=14/3;
        // intercept=-1/3, slope=3/2, SSE=1/6, R squared=27/28.
        let result = try #require(Analysis.analyze(.init(action: .linearRegression,
            values: [1, 2, 3], pairedValues: [1, 3, 4])).regression)
        #expect(abs(result.slope - 1.5) < 1e-14)
        #expect(abs(result.intercept + 1.0 / 3.0) < 1e-14)
        #expect(abs(result.residualSumOfSquares - 1.0 / 6.0) < 1e-14)
        #expect(abs(try #require(result.rSquared) - 27.0 / 28.0) < 1e-14)
    }

    @Test("Missing paired observations are dropped as rows, preserving alignment")
    func pairwiseOmission() throws {
        let report = try Analysis.analyze(.init(action: .linearRegression,
            values: [1, nil, 3, 4], pairedValues: [3, 5, nil, 9], missingPolicy: .omit))
        let result = try #require(report.regression)
        #expect(report.inputCount == 4 && report.omittedCount == 2 && result.count == 2)
        #expect(result.slope == 2 && result.intercept == 1)
        #expect(result.residualDegreesOfFreedom == 0 && result.residualStandardDeviation == nil)
    }

    @Test("Constant y has an intercept and undefined correlation, whereas constant x is rejected")
    func degenerateRegression() throws {
        let result = try #require(Analysis.analyze(.init(action: .linearRegression,
            values: [1, 2, 3], pairedValues: [4, 4, 4])).regression)
        #expect(result.slope == 0 && result.intercept == 4)
        #expect(result.pearsonR == nil && result.rSquared == nil)
        #expect(throws: Analysis.AnalysisError.self) {
            try Analysis.analyze(.init(action: .linearRegression, values: [2, 2], pairedValues: [1, 2]))
        }
    }

    @Test("Correlation avoids overflow from multiplying squared magnitudes")
    func largeMagnitudeCorrelation() throws {
        let result = try #require(Analysis.analyze(.init(action: .linearRegression,
            values: [-1e100, 0, 1e100], pairedValues: [1e100, 0, -1e100])).regression)
        #expect(result.slope == -1 && result.intercept == 0)
        #expect(abs(try #require(result.pearsonR) + 1) < 1e-14)
    }

    @Test("Histogram boundaries account for every observation exactly once")
    func histogramEdges() throws {
        let result = try #require(Analysis.analyze(.init(action: .histogram,
            values: [-2, -1, 0, 1, 2], binCount: 4)).histogram)
        #expect(result.bins.map(\.count) == [1, 1, 1, 2])
        #expect(result.bins.map(\.lowerBound) == [-2, -1, 0, 1])
        #expect(result.bins.map(\.upperBoundInclusive) == [false, false, false, true])
        #expect(result.bins.reduce(0) { $0 + $1.count } == 5)
    }

    @Test("Constant histogram values produce one inclusive bin")
    func constantHistogram() throws {
        let result = try #require(Analysis.analyze(.init(action: .histogram,
            values: [2.5, 2.5, 2.5], binCount: 8)).histogram)
        #expect(result.requestedBinCount == 8 && result.constantValues)
        #expect(result.bins.count == 1 && result.bins[0].count == 3)
        #expect(result.bins[0].lowerBound == 2.5 && result.bins[0].upperBound == 2.5)
        #expect(result.bins[0].upperBoundInclusive)
    }

    @Test("Missing values need an explicit policy and omission is reported")
    func explicitMissingPolicy() throws {
        #expect(throws: Analysis.AnalysisError.self) {
            try Analysis.analyze(.init(action: .summarize, values: [1, nil, 3]))
        }
        let report = try Analysis.analyze(.init(action: .summarize, values: [1, nil, 3], missingPolicy: .omit))
        #expect(report.summary?.mean == 2 && report.omittedCount == 1)
        #expect(throws: Analysis.AnalysisError.self) {
            try Analysis.analyze(.init(action: .summarize, values: [nil], missingPolicy: .omit))
        }
    }

    @Test("Invalid sizes, irrelevant parameters and nonfinite values are rejected")
    func inputValidation() throws {
        let invalid: [Analysis.Request] = [
            .init(action: .summarize, values: []),
            .init(action: .summarize, values: Array(repeating: 1, count: 4097)),
            .init(action: .summarize, values: [Double.nan]),
            .init(action: .summarize, values: [Double.infinity]),
            .init(action: .summarize, values: [1e101]),
            .init(action: .summarize, values: [1], pairedValues: [1]),
            .init(action: .summarize, values: [1], binCount: 1),
            .init(action: .histogram, values: [1, 2], binCount: 0),
            .init(action: .histogram, values: [1, 2], binCount: 129),
            .init(action: .linearRegression, values: [1, 2], pairedValues: [1]),
            .init(action: .linearRegression, values: [1, 2]),
            .init(action: .linearRegression, values: [1, nil], pairedValues: [2, 3], missingPolicy: .omit)
        ]
        for request in invalid {
            #expect(throws: Analysis.AnalysisError.self) { try Analysis.analyze(request) }
        }
    }

    @Test("Numerical underflow is reported instead of pretending the data is constant")
    func underflow() throws {
        #expect(throws: Analysis.AnalysisError.numericalRange) {
            try Analysis.analyze(.init(action: .summarize, values: [0, 1e-300]))
        }
    }

    @Test("Indistinguishable histogram edges require fewer bins")
    func histogramResolution() throws {
        #expect(throws: Analysis.AnalysisError.self) {
            try Analysis.analyze(.init(action: .histogram, values: [1, 1.nextUp], binCount: 128))
        }
    }

    @Test("Cancellation stops a calculation without producing a result")
    func cancellation() throws {
        #expect(throws: CancellationError.self) {
            try Analysis.analyze(.init(action: .summarize, values: [1, 2, 3]), checkCancellation: {
                throw CancellationError()
            })
        }
    }

    @Test("Reports round trip as finite JSON with declared conventions")
    func jsonRoundTrip() throws {
        let request = try JSONDecoder().decode(Analysis.Request.self,
            from: Data(#"{"action":"summarize","values":[2,null,4],"missingPolicy":"omit"}"#.utf8))
        let report = try Analysis.analyze(request)
        let bytes = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(Analysis.Report.self, from: bytes) == report)
        #expect(report.schemaVersion == 1 && report.summary?.mean == 3)
        #expect(!report.conventions.isEmpty)
    }

#if !FLOE_SCIENTIFIC_CORE_ONLY
    @Test("Tool registration is read-only and stays outside temporary chat")
    func toolContract() async throws {
        ToolCatalog.register(NativeDataAnalysisTool.self)
        let descriptor = try #require(ToolCatalog.descriptor(named: "data.analyze"))
        #expect(descriptor.effect == .readOnly && !descriptor.isSideEffecting)
        #expect(descriptor.riskLabels.isEmpty && !descriptor.requiresHostScope)
        #expect(TemporaryChatToolPolicy.readOnlyDescriptor(descriptor) == nil)
        let output = try await NativeDataAnalysisTool().execute(.init(action: .summarize, values: [2, 4, 6]),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        let report = try JSONDecoder().decode(Analysis.Report.self, from: Data(output.summary.utf8))
        #expect(report.summary?.mean == 4 && output.exitStatus == 0 && output.artifacts.isEmpty)
        #expect(output.fullOutputSHA256 == FloeDigest.sha256Hex(Data(output.summary.utf8)))
    }
#endif
}
