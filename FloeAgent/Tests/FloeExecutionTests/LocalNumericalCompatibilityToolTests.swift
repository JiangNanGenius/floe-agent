import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

@Suite("FloeExecution local numerical compatibility")
struct LocalNumericalCompatibilityToolTests {
    @Test("MATLAB-compatible matrices and statistics run locally")
    func matlabMatrices() async throws {
        let tool = LocalNumericalCompatibilityTool()
        let output = try await tool.execute(
            .init(
                dialect: .matlabCompatible,
                script: "a = [1,2;3,4]\nb = a' * a\nmean(b)"
            ),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("b = [10, 14; 14, 20]"))
        #expect(output.summary.contains("14.5"))
    }

    @Test("R-compatible assignment vectors and sample deviation run locally")
    func rVectors() async throws {
        let tool = LocalNumericalCompatibilityTool()
        let output = try await tool.execute(
            .init(dialect: .r, script: "x <- c(1,2,3,4)\nmean(x)\nsd(x)"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("x = [1, 2, 3, 4]"))
        #expect(output.summary.contains("2.5"))
        #expect(output.summary.contains("1.29099444874"))
    }

    @Test("R-compatible descriptive statistics quantiles and correlation run locally")
    func rStatistics() async throws {
        let output = try await LocalNumericalCompatibilityTool().execute(
            .init(
                dialect: .r,
                script: "x <- c(1,2,3,4,5)\ny <- c(2,4,6,8,10)\nsummary(x)\nquantile(x,0.75)\ncor(x,y)\nregress(y,x)"
            ),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("[5, 3, 1.58113883008, 1, 5]"))
        #expect(output.summary.contains("4"))
        #expect(output.summary.contains("[0, 2, 1, 5]"))
    }

    @Test("Stata-compatible common commands run without pretending to bundle Stata")
    func stataCommands() async throws {
        let output = try await LocalNumericalCompatibilityTool().execute(
            .init(
                dialect: .stataCompatible,
                script: "* bounded Stata-compatible surface\ngenerate x = c(1,2,3,4)\ngen y = c(3,5,7,9)\nsummarize x\ncorrelate x y\nregress y x"
            ),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("dialect=stataCompatible"))
        #expect(output.summary.contains("[4, 2.5, 1.29099444874, 1, 4]"))
        #expect(output.summary.contains("[1, 2, 1, 4]"))
    }

    @Test("JSON input is numeric-only and exposed without file or network access")
    func jsonInput() async throws {
        let tool = LocalNumericalCompatibilityTool()
        try tool.validate(.init(dialect: .r, script: "sum(input)", inputJSON: "[2,3,5]"))
        #expect(throws: FloeError.self) {
            try tool.validate(.init(dialect: .r, script: "input", inputJSON: #"{"secret":"value"}"#))
        }
        let output = try await tool.execute(
            .init(dialect: .r, script: "sum(input)", inputJSON: "[2,3,5]"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.summary.contains("10"))
    }

    @Test("unknown functions fail honestly instead of pretending full compatibility")
    func unsupportedFunction() async throws {
        let output = try await LocalNumericalCompatibilityTool().execute(
            .init(dialect: .matlabCompatible, script: "simulink(1)"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 2)
        #expect(output.summary.contains("unknown: function simulink"))
    }

    @Test("common constructors transforms and element-wise arithmetic are compatible")
    func commonNumericalSurface() async throws {
        let output = try await LocalNumericalCompatibilityTool().execute(
            .init(
                dialect: .matlabCompatible,
                script: "x = linspace(0,4,5)\ny = (x .* x) + ones(1,5)\nsum(y)\nt(eye(3))"
            ),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("x = [0, 1, 2, 3, 4]"))
        #expect(output.summary.contains("y = [1, 2, 5, 10, 17]"))
        #expect(output.summary.contains("35"))
        #expect(output.summary.contains("[1, 0, 0; 0, 1, 0; 0, 0, 1]"))
    }

    @Test("allocation and compute limits reject oversized jobs before allocating")
    func boundedResources() async throws {
        let tool = LocalNumericalCompatibilityTool()
        let allocation = try await tool.execute(
            .init(dialect: .matlabCompatible, script: "zeros(100000,100000)"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(allocation.exitStatus == 2)
        #expect(allocation.summary.contains("limit: matrix exceeds"))

        let compute = try await tool.execute(
            .init(dialect: .matlabCompatible, script: "ones(101,101) * ones(101,101)"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(compute.exitStatus == 2)
        #expect(compute.summary.contains("limit: operation budget exceeded"))
    }

    @Test("fractional dimensions and oversized source fail validation or execution")
    func invalidBounds() async throws {
        let tool = LocalNumericalCompatibilityTool()
        #expect(throws: FloeError.self) {
            try tool.validate(.init(dialect: .r, script: String(repeating: "1", count: 65_537)))
        }
        let output = try await tool.execute(
            .init(dialect: .r, script: "matrix(c(1,2),2.5,1)"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 2)
        #expect(output.summary.contains("shape: matrix dimensions must be integers"))
    }
}
