import Foundation
import Crypto
import FloeCore
import FloeTools

/// A bounded, dependency-free numerical evaluator for common R and
/// MATLAB/Octave-style expressions. This is deliberately a compatibility
/// surface, not a bundled copy of either GPL runtime and not MathWorks MATLAB.
public struct LocalNumericalCompatibilityTool: AgentTool {
    public enum Dialect: String, Decodable, Sendable { case r, matlabCompatible }

    public struct Arguments: Decodable, Sendable {
        public var dialect: Dialect
        public var script: String
        public var inputJSON: String?

        public init(dialect: Dialect, script: String, inputJSON: String? = nil) {
            self.dialect = dialect
            self.script = script
            self.inputJSON = inputJSON
        }
    }

    public static let name = "exec.localNumerical"
    public static let toolDescription =
        "Run bounded numerical code locally with common R or MATLAB/Octave-compatible syntax. This is Floe's own compatibility evaluator, not GNU R, GNU Octave, or MathWorks MATLAB. It supports scalar/vector/matrix assignment and arithmetic plus c, seq, matrix, sum, mean, sd, min, max, length, nrow, ncol, zeros, ones, eye, linspace, abs, sqrt, exp, log, sin, cos, tan and transpose. Matrix literals use commas and semicolons, for example [1,2;3,4]. It has no file, network, package, process, dynamic-code, or native-extension access. Use configured SSH/cloud execution when full language or package compatibility is required."
    public static let parametersJSON = #"{"type":"object","properties":{"dialect":{"type":"string","enum":["r","matlabCompatible"]},"script":{"type":"string","description":"Visible numerical source, max 64 KiB"},"inputJSON":{"type":"string","description":"Optional JSON number or numeric array exposed as input"}},"required":["dialect","script"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.executesLocalCode]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    public init() {}

    public func validate(_ args: Arguments) throws {
        guard !args.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("script must not be empty")
        }
        guard args.script.utf8.count <= 64 * 1_024 else {
            throw FloeError.validationFailed("script exceeds the 65536-byte limit")
        }
        if let inputJSON = args.inputJSON {
            guard let object = try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8)),
                  NumericalValue(jsonObject: object) != nil else {
                throw FloeError.validationFailed("inputJSON must be a number or a rectangular numeric array")
            }
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        do {
            var variables: [String: NumericalValue] = [:]
            if let inputJSON = args.inputJSON,
               let object = try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8)),
               let input = NumericalValue(jsonObject: object) {
                variables["input"] = input
            }
            let statements = try NumericalProgram.statements(from: args.script, dialect: args.dialect)
            guard statements.count <= 256 else { throw NumericalError.limit("at most 256 statements are allowed") }
            var lines: [String] = ["dialect=\(args.dialect.rawValue)"]
            var budget = NumericalBudget()
            for statement in statements {
                try context.cancellation.throwIfCancelled()
                let (name, expression) = NumericalProgram.assignment(in: statement)
                var parser = try NumericalParser(source: expression, variables: variables, budget: budget)
                let value = try parser.parse()
                budget = parser.budget
                if let name {
                    variables[name] = value
                    lines.append("\(name) = \(value.rendered)")
                } else {
                    lines.append(value.rendered)
                }
            }
            let text = lines.joined(separator: "\n")
            return Self.output(text, code: 0)
        } catch let error as NumericalError {
            return Self.output("status=error error=\(error.description)", code: 2)
        } catch {
            return Self.output("status=error error=\(error.localizedDescription)", code: 2)
        }
    }

    private static func output(_ text: String, code: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: code)
    }
}

private enum NumericalError: Error, CustomStringConvertible {
    case syntax(String), shape(String), unknown(String), limit(String)
    var description: String {
        switch self {
        case .syntax(let value): "syntax: \(value)"
        case .shape(let value): "shape: \(value)"
        case .unknown(let value): "unknown: \(value)"
        case .limit(let value): "limit: \(value)"
        }
    }
}

private struct NumericalBudget {
    var operations = 0
    mutating func charge(_ count: Int = 1) throws {
        operations += count
        if operations > 1_000_000 { throw NumericalError.limit("operation budget exceeded") }
    }
}

private struct NumericalValue: Equatable {
    static let maxElements = 100_000
    var rows: [[Double]]

    init(_ rows: [[Double]]) throws {
        guard !rows.isEmpty, let width = rows.first?.count, width > 0,
              rows.allSatisfy({ $0.count == width }) else {
            throw NumericalError.shape("matrix must be non-empty and rectangular")
        }
        guard rows.count * width <= Self.maxElements else {
            throw NumericalError.limit("matrix exceeds \(Self.maxElements) elements")
        }
        self.rows = rows
    }

    init(scalar: Double) { rows = [[scalar]] }

    init?(jsonObject: Any) {
        do {
            if let number = jsonObject as? NSNumber {
                try self.init([[number.doubleValue]])
            } else if let values = jsonObject as? [NSNumber] {
                try self.init([values.map(\.doubleValue)])
            } else if let matrix = jsonObject as? [[NSNumber]] {
                try self.init(matrix.map { $0.map(\.doubleValue) })
            } else { return nil }
        } catch { return nil }
    }

    var rowCount: Int { rows.count }
    var columnCount: Int { rows[0].count }
    var elementCount: Int { rowCount * columnCount }
    var isScalar: Bool { elementCount == 1 }
    var scalar: Double? { isScalar ? rows[0][0] : nil }
    var flattened: [Double] { rows.flatMap { $0 } }

    var rendered: String {
        if let scalar { return Self.format(scalar) }
        return "[" + rows.map { $0.map(Self.format).joined(separator: ", ") }.joined(separator: "; ") + "]"
    }

    private static func format(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value == .infinity { return "Inf" }
        if value == -.infinity { return "-Inf" }
        if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { return String(Int64(value)) }
        return String(format: "%.12g", value)
    }

    func map(_ transform: (Double) throws -> Double) throws -> NumericalValue {
        try NumericalValue(rows.map { try $0.map(transform) })
    }

    func transposed() throws -> NumericalValue {
        try NumericalValue((0..<columnCount).map { column in rows.map { $0[column] } })
    }
}

private enum NumericalToken: Equatable {
    case number(Double), identifier(String)
    case plus, minus, multiply, divide, elementMultiply, elementDivide, power
    case leftParen, rightParen, leftBracket, rightBracket, comma, semicolon, colon, transpose, end
}

private struct NumericalLexer {
    let characters: [Character]
    var index = 0

    init(_ source: String) { characters = Array(source) }

    mutating func next() throws -> NumericalToken {
        while index < characters.count, characters[index].isWhitespace { index += 1 }
        guard index < characters.count else { return .end }
        let current = characters[index]
        if current.isNumber || current == "." && index + 1 < characters.count && characters[index + 1].isNumber {
            let start = index
            index += 1
            while index < characters.count, characters[index].isNumber || characters[index] == "." { index += 1 }
            if index < characters.count, characters[index] == "e" || characters[index] == "E" {
                index += 1
                if index < characters.count, characters[index] == "+" || characters[index] == "-" { index += 1 }
                while index < characters.count, characters[index].isNumber { index += 1 }
            }
            guard let number = Double(String(characters[start..<index])) else { throw NumericalError.syntax("invalid number") }
            return .number(number)
        }
        if current.isLetter || current == "_" {
            let start = index
            index += 1
            while index < characters.count, characters[index].isLetter || characters[index].isNumber || characters[index] == "_" { index += 1 }
            return .identifier(String(characters[start..<index]))
        }
        index += 1
        switch current {
        case "+": return .plus
        case "-": return .minus
        case "*": return .multiply
        case "/": return .divide
        case "^": return .power
        case "(": return .leftParen
        case ")": return .rightParen
        case "[": return .leftBracket
        case "]": return .rightBracket
        case ",": return .comma
        case ";": return .semicolon
        case ":": return .colon
        case "'": return .transpose
        case ".":
            guard index < characters.count else { throw NumericalError.syntax("dangling dot") }
            let following = characters[index]
            index += 1
            if following == "*" { return .elementMultiply }
            if following == "/" { return .elementDivide }
            if following == "^" { return .power }
            throw NumericalError.syntax("unsupported dotted operator")
        default: throw NumericalError.syntax("unsupported character \(current)")
        }
    }
}

private enum NumericalProgram {
    static func statements(from source: String, dialect: LocalNumericalCompatibilityTool.Dialect) throws -> [String] {
        let commentMarker: Character = dialect == .r ? "#" : "%"
        let uncommented = source.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            String(line.prefix(while: { $0 != commentMarker }))
        }.joined(separator: "\n")
        var result: [String] = []
        var current = ""
        var parentheses = 0
        var brackets = 0
        for character in uncommented {
            if character == "(" { parentheses += 1 }
            if character == ")" { parentheses -= 1 }
            if character == "[" { brackets += 1 }
            if character == "]" { brackets -= 1 }
            guard parentheses >= 0, brackets >= 0 else { throw NumericalError.syntax("unbalanced delimiters") }
            if (character == "\n" || character == ";") && parentheses == 0 && brackets == 0 {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            } else { current.append(character) }
        }
        guard parentheses == 0, brackets == 0 else { throw NumericalError.syntax("unbalanced delimiters") }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }

    static func assignment(in statement: String) -> (String?, String) {
        var depth = 0
        let characters = Array(statement)
        for index in characters.indices {
            let character = characters[index]
            if character == "(" || character == "[" { depth += 1 }
            if character == ")" || character == "]" { depth -= 1 }
            guard depth == 0 else { continue }
            let isArrow = character == "<" && index + 1 < characters.count && characters[index + 1] == "-"
            let isEquals = character == "="
            if isArrow || isEquals {
                let left = String(characters[..<index]).trimmingCharacters(in: .whitespaces)
                let offset = isArrow ? 2 : 1
                let right = String(characters[(index + offset)...]).trimmingCharacters(in: .whitespaces)
                if left.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil {
                    return (left, right)
                }
            }
        }
        return (nil, statement)
    }
}

private struct NumericalParser {
    private var lexer: NumericalLexer
    private var token: NumericalToken
    private let variables: [String: NumericalValue]
    var budget: NumericalBudget

    init(source: String, variables: [String: NumericalValue], budget: NumericalBudget) throws {
        var lexer = NumericalLexer(source)
        let first = try lexer.next()
        self.lexer = lexer
        token = first
        self.variables = variables
        self.budget = budget
    }

    mutating func parse() throws -> NumericalValue {
        let result = try parseAdditive()
        guard token == .end else { throw NumericalError.syntax("unexpected trailing input") }
        return result
    }

    private mutating func advance() throws { token = try lexer.next() }

    private mutating func parseAdditive() throws -> NumericalValue {
        var left = try parseMultiplicative()
        while token == .plus || token == .minus {
            let operation = token
            try advance()
            let right = try parseMultiplicative()
            left = try binary(left, right, operation: operation)
        }
        return left
    }

    private mutating func parseMultiplicative() throws -> NumericalValue {
        var left = try parsePower()
        while [.multiply, .divide, .elementMultiply, .elementDivide].contains(token) {
            let operation = token
            try advance()
            let right = try parsePower()
            left = try binary(left, right, operation: operation)
        }
        return left
    }

    private mutating func parsePower() throws -> NumericalValue {
        var left = try parseRange()
        if token == .power {
            try advance()
            let right = try parsePower()
            left = try binary(left, right, operation: .power)
        }
        return left
    }

    private mutating func parseRange() throws -> NumericalValue {
        var left = try parseUnary()
        if token == .colon {
            try advance()
            let right = try parseUnary()
            guard let start = left.scalar, let end = right.scalar else { throw NumericalError.shape("range endpoints must be scalars") }
            let step = start <= end ? 1.0 : -1.0
            var values: [Double] = []
            var value = start
            while step > 0 ? value <= end : value >= end {
                values.append(value); value += step
                if values.count > NumericalValue.maxElements { throw NumericalError.limit("range is too large") }
            }
            left = try NumericalValue([values])
        }
        return left
    }

    private mutating func parseUnary() throws -> NumericalValue {
        if token == .plus { try advance(); return try parseUnary() }
        if token == .minus { try advance(); return try parseUnary().map { -$0 } }
        var value = try parsePrimary()
        while token == .transpose { try advance(); value = try value.transposed() }
        return value
    }

    private mutating func parsePrimary() throws -> NumericalValue {
        switch token {
        case .number(let number): try advance(); return NumericalValue(scalar: number)
        case .identifier(let name):
            try advance()
            if token == .leftParen { return try parseFunction(name) }
            if name.uppercased() == "TRUE" { return NumericalValue(scalar: 1) }
            if name.uppercased() == "FALSE" { return NumericalValue(scalar: 0) }
            if name.lowercased() == "pi" { return NumericalValue(scalar: .pi) }
            guard let value = variables[name] else { throw NumericalError.unknown("variable \(name)") }
            return value
        case .leftParen:
            try advance(); let value = try parseAdditive()
            guard token == .rightParen else { throw NumericalError.syntax("expected )") }
            try advance(); return value
        case .leftBracket: return try parseMatrixLiteral()
        default: throw NumericalError.syntax("expected a number, variable, function, or matrix")
        }
    }

    private mutating func parseMatrixLiteral() throws -> NumericalValue {
        try advance()
        var rows: [[Double]] = [[]]
        while token != .rightBracket {
            let value = try parseAdditive()
            rows[rows.count - 1].append(contentsOf: value.flattened)
            if token == .comma { try advance() }
            else if token == .semicolon { rows.append([]); try advance() }
            else if token != .rightBracket { throw NumericalError.syntax("matrix elements require commas; rows require semicolons") }
        }
        try advance()
        return try NumericalValue(rows)
    }

    private mutating func parseFunction(_ rawName: String) throws -> NumericalValue {
        let name = rawName.lowercased()
        try advance()
        var arguments: [NumericalValue] = []
        if token != .rightParen {
            while true {
                arguments.append(try parseAdditive())
                if token == .comma { try advance(); continue }
                break
            }
        }
        guard token == .rightParen else { throw NumericalError.syntax("expected ) after \(rawName)") }
        try advance()
        return try call(name, arguments)
    }

    private mutating func call(_ name: String, _ arguments: [NumericalValue]) throws -> NumericalValue {
        try budget.charge(arguments.reduce(1) { $0 + $1.elementCount })
        func one() throws -> NumericalValue {
            guard arguments.count == 1 else { throw NumericalError.syntax("\(name) expects one argument") }
            return arguments[0]
        }
        switch name {
        case "c": return try NumericalValue([arguments.flatMap(\.flattened)])
        case "sum": return NumericalValue(scalar: try one().flattened.reduce(0, +))
        case "mean": let values = try one().flattened; return NumericalValue(scalar: values.reduce(0, +) / Double(values.count))
        case "min": return NumericalValue(scalar: try one().flattened.min()!)
        case "max": return NumericalValue(scalar: try one().flattened.max()!)
        case "length": return NumericalValue(scalar: Double(try one().elementCount))
        case "nrow": return NumericalValue(scalar: Double(try one().rowCount))
        case "ncol": return NumericalValue(scalar: Double(try one().columnCount))
        case "sd":
            let values = try one().flattened
            guard values.count > 1 else { return NumericalValue(scalar: .nan) }
            let mean = values.reduce(0, +) / Double(values.count)
            return NumericalValue(scalar: sqrt(values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)))
        case "abs": return try one().map(Swift.abs)
        case "sqrt": return try one().map(Foundation.sqrt)
        case "exp": return try one().map(Foundation.exp)
        case "log": return try one().map(Foundation.log)
        case "sin": return try one().map(Foundation.sin)
        case "cos": return try one().map(Foundation.cos)
        case "tan": return try one().map(Foundation.tan)
        case "transpose", "t": return try one().transposed()
        case "seq":
            guard (2...3).contains(arguments.count), let start = arguments[0].scalar, let end = arguments[1].scalar,
                  let step = arguments.count == 3 ? arguments[2].scalar : (start <= end ? 1 : -1), step != 0 else {
                throw NumericalError.syntax("seq expects scalar from, to, and optional nonzero by")
            }
            var values: [Double] = [], current = start
            while step > 0 ? current <= end : current >= end {
                values.append(current); current += step
                if values.count > NumericalValue.maxElements { throw NumericalError.limit("sequence is too large") }
            }
            return try NumericalValue([values])
        case "linspace":
            guard arguments.count == 3, let start = arguments[0].scalar, let end = arguments[1].scalar,
                  let countValue = arguments[2].scalar else { throw NumericalError.syntax("linspace expects start, end, count") }
            guard countValue.rounded() == countValue else { throw NumericalError.shape("linspace count must be an integer") }
            let count = Int(countValue)
            guard count > 0, count <= NumericalValue.maxElements else { throw NumericalError.limit("invalid linspace count") }
            if count == 1 { return try NumericalValue([[start]]) }
            return try NumericalValue([(0..<count).map { start + (end - start) * Double($0) / Double(count - 1) }])
        case "zeros", "ones":
            guard (1...2).contains(arguments.count), let first = arguments[0].scalar,
                  let second = arguments.count == 2 ? arguments[1].scalar : first else { throw NumericalError.syntax("\(name) expects rows and optional columns") }
            guard first.rounded() == first, second.rounded() == second else {
                throw NumericalError.shape("dimensions must be integers")
            }
            let rows = Int(first), columns = Int(second)
            try validateDimensions(rows: rows, columns: columns)
            return try NumericalValue(Array(repeating: Array(repeating: name == "ones" ? 1 : 0, count: columns), count: rows))
        case "eye":
            guard arguments.count == 1, let sizeValue = arguments[0].scalar else { throw NumericalError.syntax("eye expects one size") }
            guard sizeValue.rounded() == sizeValue else { throw NumericalError.shape("size must be an integer") }
            let size = Int(sizeValue)
            try validateDimensions(rows: size, columns: size)
            return try NumericalValue((0..<size).map { row in (0..<size).map { row == $0 ? 1 : 0 } })
        case "matrix":
            guard arguments.count == 3, let rowValue = arguments[1].scalar, let columnValue = arguments[2].scalar else {
                throw NumericalError.syntax("matrix expects values, rows, columns")
            }
            guard rowValue.rounded() == rowValue, columnValue.rounded() == columnValue else {
                throw NumericalError.shape("matrix dimensions must be integers")
            }
            let rowCount = Int(rowValue), columnCount = Int(columnValue), values = arguments[0].flattened
            guard !values.isEmpty else { throw NumericalError.shape("matrix values must not be empty") }
            try validateDimensions(rows: rowCount, columns: columnCount)
            return try NumericalValue((0..<rowCount).map { row in (0..<columnCount).map { values[(row * columnCount + $0) % values.count] } })
        default: throw NumericalError.unknown("function \(name)")
        }
    }

    private mutating func binary(_ left: NumericalValue, _ right: NumericalValue, operation: NumericalToken) throws -> NumericalValue {
        try budget.charge(max(left.elementCount, right.elementCount))
        if operation == .multiply, !left.isScalar, !right.isScalar {
            guard left.columnCount == right.rowCount else { throw NumericalError.shape("matrix multiplication dimensions do not match") }
            let (rowColumnProduct, overflowA) = left.rowCount.multipliedReportingOverflow(by: right.columnCount)
            let (operationCount, overflowB) = rowColumnProduct.multipliedReportingOverflow(by: left.columnCount)
            guard !overflowA, !overflowB else { throw NumericalError.limit("matrix multiplication is too large") }
            try budget.charge(operationCount)
            return try NumericalValue((0..<left.rowCount).map { row in
                (0..<right.columnCount).map { column in
                    (0..<left.columnCount).reduce(0) { $0 + left.rows[row][$1] * right.rows[$1][column] }
                }
            })
        }
        let targetRows: Int, targetColumns: Int
        if left.isScalar { targetRows = right.rowCount; targetColumns = right.columnCount }
        else if right.isScalar { targetRows = left.rowCount; targetColumns = left.columnCount }
        else {
            guard left.rowCount == right.rowCount, left.columnCount == right.columnCount else {
                throw NumericalError.shape("element-wise dimensions do not match")
            }
            targetRows = left.rowCount; targetColumns = left.columnCount
        }
        return try NumericalValue((0..<targetRows).map { row in
            (0..<targetColumns).map { column in
                let lhs = left.isScalar ? left.rows[0][0] : left.rows[row][column]
                let rhs = right.isScalar ? right.rows[0][0] : right.rows[row][column]
                return switch operation {
                case .plus: lhs + rhs
                case .minus: lhs - rhs
                case .multiply, .elementMultiply: lhs * rhs
                case .divide, .elementDivide: lhs / rhs
                case .power: Foundation.pow(lhs, rhs)
                default: Double.nan
                }
            }
        })
    }

    private func validateDimensions(rows: Int, columns: Int) throws {
        guard rows > 0, columns > 0 else { throw NumericalError.shape("dimensions must be positive") }
        let (elementCount, overflow) = rows.multipliedReportingOverflow(by: columns)
        guard !overflow, elementCount <= NumericalValue.maxElements else {
            throw NumericalError.limit("matrix exceeds \(NumericalValue.maxElements) elements")
        }
    }
}
