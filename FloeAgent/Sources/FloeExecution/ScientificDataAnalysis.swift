import Foundation

/// Fixed native operations on supplied data, with no interpreter, files or
/// environment lifecycle. UI and tools can share these same calculations.
public enum ScientificDataAnalysis {
    public enum Action: String, Codable, Sendable {
        case summarize, linearRegression, histogram
    }

    public enum MissingPolicy: String, Codable, Sendable {
        case reject, omit
    }

    public struct Request: Codable, Sendable {
        public let action: Action
        public let values: [Double?]
        public let pairedValues: [Double?]?
        public let binCount: Int?
        public let missingPolicy: MissingPolicy?

        public init(action: Action, values: [Double?], pairedValues: [Double?]? = nil,
                    binCount: Int? = nil, missingPolicy: MissingPolicy? = nil) {
            self.action = action
            self.values = values
            self.pairedValues = pairedValues
            self.binCount = binCount
            self.missingPolicy = missingPolicy
        }
    }

    public struct Summary: Codable, Sendable, Equatable {
        public let count: Int
        public let sum: Double
        public let mean: Double
        public let minimum: Double
        public let firstQuartile: Double
        public let median: Double
        public let thirdQuartile: Double
        public let maximum: Double
        public let populationVariance: Double
        public let sampleVariance: Double?
        public let sampleStandardDeviation: Double?
    }

    public struct Regression: Codable, Sendable, Equatable {
        public let count: Int
        public let intercept: Double
        public let slope: Double
        public let pearsonR: Double?
        public let rSquared: Double?
        public let residualSumOfSquares: Double
        public let rootMeanSquaredError: Double
        public let residualDegreesOfFreedom: Int
        public let residualStandardDeviation: Double?
    }

    public struct Histogram: Codable, Sendable, Equatable {
        public struct Bin: Codable, Sendable, Equatable {
            public let lowerBound: Double
            public let upperBound: Double
            public let upperBoundInclusive: Bool
            public let count: Int
        }
        public let requestedBinCount: Int
        public let constantValues: Bool
        public let bins: [Bin]
    }

    public struct Report: Codable, Sendable, Equatable {
        public let schemaVersion: Int
        public let action: Action
        public let inputCount: Int
        public let omittedCount: Int
        public let summary: Summary?
        public let regression: Regression?
        public let histogram: Histogram?
        public let conventions: [String]
    }

    public enum AnalysisError: Error, LocalizedError, Sendable, Equatable {
        case invalidInput(String)
        case numericalRange

        public var errorDescription: String? {
            switch self {
            case .invalidInput(let message): return message
            case .numericalRange:
                return "The calculation exceeds numerical precision. Rescale the data before retrying."
            }
        }
    }

    public static let maximumValues = 4_096
    public static let maximumMagnitude = 1e100

    public static func validate(_ request: Request) throws {
        guard (1...maximumValues).contains(request.values.count) else {
            throw AnalysisError.invalidInput("Supply 1 to 4096 values.")
        }
        if request.action == .linearRegression {
            guard let paired = request.pairedValues, paired.count == request.values.count else {
                throw AnalysisError.invalidInput("Regression requires equally sized x (values) and y (pairedValues).")
            }
        } else if request.pairedValues != nil {
            throw AnalysisError.invalidInput("pairedValues is only used for linearRegression.")
        }
        if let bins = request.binCount {
            guard request.action == .histogram, (1...128).contains(bins) else {
                throw AnalysisError.invalidInput("binCount is only used for histogram and must be 1 to 128.")
            }
        }
        for series in [request.values, request.pairedValues].compactMap({ $0 }) {
            for value in series {
                if let value {
                    guard value.isFinite, abs(value) <= maximumMagnitude else {
                        throw AnalysisError.invalidInput("Values must be finite and have magnitude at most 1e100.")
                    }
                } else if request.missingPolicy != .omit {
                    throw AnalysisError.invalidInput("Null values require the explicit missingPolicy=omit.")
                }
            }
        }
    }

    public static func analyze(
        _ request: Request,
        checkCancellation: @Sendable () throws -> Void = {}
    ) throws -> Report {
        try checkCancellation()
        try validate(request)
        var x: [Double] = []
        var y: [Double] = []
        for index in request.values.indices {
            if index.isMultiple(of: 256) { try checkCancellation() }
            guard let value = request.values[index] else { continue }
            if let paired = request.pairedValues {
                guard let other = paired[index] else { continue }
                y.append(other)
            }
            x.append(value)
        }
        guard !x.isEmpty else { throw AnalysisError.invalidInput("No observations remain after omitting nulls.") }
        let summary: Summary?
        let regression: Regression?
        let histogram: Histogram?
        let conventions: [String]
        switch request.action {
        case .summarize:
            summary = try summarize(x)
            regression = nil; histogram = nil
            conventions = ["Quartiles use linear interpolation at (n-1)*p (type 7).",
                           "Population variance divides by n; sample variance divides by n-1.",
                           "Undefined sample statistics are omitted; units are those of the supplied data."]
        case .linearRegression:
            summary = nil; histogram = nil
            regression = try regress(x: x, y: y, checkCancellation: checkCancellation)
            conventions = ["Unweighted ordinary least squares: y=intercept+slope*x, with an intercept.",
                           "Missing observations are omitted as pairs; no imputation or independent compaction.",
                           "For constant y, Pearson r and R squared are undefined and omitted.",
                           "Residual standard deviation divides by n-2 and is omitted when n=2.",
                           "These are descriptive results, without a significance, causality or extrapolation claim."]
        case .histogram:
            summary = nil; regression = nil
            histogram = try makeHistogram(x, count: request.binCount ?? min(20, x.count),
                                          checkCancellation: checkCancellation)
            conventions = ["Equal-width bins include their lower edge; only the last bin includes its upper edge.",
                           "Constant data produces one inclusive bin; no observation is clipped."]
        }
        try checkCancellation()
        return Report(schemaVersion: 1, action: request.action, inputCount: request.values.count,
                      omittedCount: request.values.count - x.count, summary: summary,
                      regression: regression, histogram: histogram, conventions: conventions)
    }

    // Shift before calculating moments to preserve small variations around a
    // large offset. Neumaier summation also preserves signed cancellation.
    private struct Moments {
        let mean: Double
        let centered: [Double]
        let squareSum: Double

        init(_ values: [Double]) throws {
            let offsets = values.map { $0 - values[0] }
            let offsetMean = ScientificDataAnalysis.sum(offsets) / Double(values.count)
            let deviations = offsets.map { $0 - offsetMean }
            let squares = ScientificDataAnalysis.sum(deviations.map { $0 * $0 })
            guard squares.isFinite, squares >= 0,
                  squares != 0 || values.allSatisfy({ $0 == values[0] }) else {
                throw AnalysisError.numericalRange
            }
            mean = ScientificDataAnalysis.sum(values) / Double(values.count)
            centered = deviations
            squareSum = squares
        }
    }

    private static func sum(_ values: [Double]) -> Double {
        var total = 0.0
        var correction = 0.0
        for value in values {
            let next = total + value
            correction += abs(total) >= abs(value) ? (total - next) + value : (value - next) + total
            total = next
        }
        return total + correction
    }

    private static func checked(_ value: Double) throws -> Double {
        guard value.isFinite else { throw AnalysisError.numericalRange }
        return value
    }

    private static func variance(_ numerator: Double, denominator: Int) throws -> Double {
        let result = try checked(numerator / Double(denominator))
        guard numerator == 0 || result > 0 else { throw AnalysisError.numericalRange }
        return result
    }

    private static func summarize(_ values: [Double]) throws -> Summary {
        let moments = try Moments(values)
        let sorted = values.sorted()
        func quantile(_ probability: Double) -> Double {
            let position = Double(sorted.count - 1) * probability
            let lower = Int(position)
            let fraction = position - Double(lower)
            let upper = min(lower + 1, sorted.count - 1)
            return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
        }
        let sample = values.count > 1 ? try variance(moments.squareSum, denominator: values.count - 1) : nil
        return Summary(count: values.count, sum: try checked(sum(values)), mean: try checked(moments.mean),
                       minimum: sorted[0], firstQuartile: quantile(0.25), median: quantile(0.5),
                       thirdQuartile: quantile(0.75), maximum: sorted[sorted.count - 1],
                       populationVariance: try variance(moments.squareSum, denominator: values.count),
                       sampleVariance: sample, sampleStandardDeviation: sample.map { sqrt($0) })
    }

    private static func regress(x: [Double], y: [Double],
                                checkCancellation: @Sendable () throws -> Void) throws -> Regression {
        guard x.count >= 2 else { throw AnalysisError.invalidInput("Regression requires at least two complete pairs.") }
        let xm = try Moments(x)
        let ym = try Moments(y)
        guard xm.squareSum > 0 else { throw AnalysisError.invalidInput("Regression requires variation in x.") }
        let cross = sum(zip(xm.centered, ym.centered).map { $0 * $1 })
        let slope = try checked(cross / xm.squareSum)
        let intercept = try checked(ym.mean.addingProduct(-slope, xm.mean))
        var squaredResiduals: [Double] = []
        var nonzeroResidual = false
        for index in x.indices {
            if index.isMultiple(of: 256) { try checkCancellation() }
            let residual = ym.centered[index].addingProduct(-slope, xm.centered[index])
            nonzeroResidual = nonzeroResidual || residual != 0
            squaredResiduals.append(try checked(residual * residual))
        }
        let residualSum = try checked(sum(squaredResiduals))
        guard residualSum > 0 || !nonzeroResidual else { throw AnalysisError.numericalRange }
        let r: Double?
        if ym.squareSum > 0 {
            r = min(1, max(-1, try checked(cross / sqrt(xm.squareSum) / sqrt(ym.squareSum))))
        } else { r = nil }
        return Regression(count: x.count, intercept: intercept, slope: slope,
                          pearsonR: r, rSquared: r.map { $0 * $0 }, residualSumOfSquares: residualSum,
                          rootMeanSquaredError: sqrt(try variance(residualSum, denominator: x.count)),
                          residualDegreesOfFreedom: x.count - 2,
                          residualStandardDeviation: x.count > 2
                            ? sqrt(try variance(residualSum, denominator: x.count - 2)) : nil)
    }

    private static func makeHistogram(_ values: [Double], count: Int,
                                      checkCancellation: @Sendable () throws -> Void) throws -> Histogram {
        let minimum = values.min()!
        let maximum = values.max()!
        if minimum == maximum {
            return Histogram(requestedBinCount: count, constantValues: true,
                             bins: [.init(lowerBound: minimum, upperBound: maximum,
                                          upperBoundInclusive: true, count: values.count)])
        }
        var edges = (0...count).map { minimum + (maximum - minimum) * (Double($0) / Double(count)) }
        edges[0] = minimum; edges[count] = maximum
        guard zip(edges, edges.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw AnalysisError.invalidInput("Bin edges cannot be distinguished at this precision; reduce binCount or rescale the data.")
        }
        var counts = [Int](repeating: 0, count: count)
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 256) { try checkCancellation() }
            var lower = 0
            var upper = count
            while lower + 1 < upper {
                let middle = (lower + upper) / 2
                if value < edges[middle] { upper = middle } else { lower = middle }
            }
            counts[lower] += 1
        }
        return Histogram(requestedBinCount: count, constantValues: false, bins: (0..<count).map {
            .init(lowerBound: edges[$0], upperBound: edges[$0 + 1],
                  upperBoundInclusive: $0 == count - 1, count: counts[$0])
        })
    }
}
