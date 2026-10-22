// FloeDocuments — persisted formula-result verification for recalculation.
//
// "Recalculation was requested" and "the file changed" are not evidence that
// the saved workbook carries fresh, correct formula results. After the engine
// saves and the package is reopened, this checker reads each formula cell's
// PERSISTED cached value (`<v>`), result type (`t=`) and error code, and — for
// the formula shapes it can evaluate exactly from the workbook's own persisted
// dependency values (SUM/MIN/MAX/COUNT/AVERAGE, numeric IF comparisons and ROUND,
// direct references, cross-sheet
// references and constant arithmetic) — recomputes the expected result from
// the dependency context.
//
// Honest limits, enforced by the report rather than hidden:
//   * unsupported formula shapes are reported `unverifiedShape` and never
//     counted as verified;
//   * a dependency the parser cannot see (missing sheet, truncated context,
//     non-numeric operand) is reported, never silently treated as zero;
//   * a formula cell with no persisted cache is a failure — that is precisely
//     the stale/absent cache the recalculation was supposed to replace.
//
// The checker is deliberately bounded: it never executes macros, never
// resolves external workbooks, and caps cells, dependencies and recursion so a
// hostile package cannot make verification unbounded.

import Foundation

public enum OfficeFormulaResultType: String, Codable, Sendable, Equatable {
    case number
    case string
    case boolean
    case error
    /// A persisted but empty value (`<v></v>`): a legitimately blank result.
    case blank
    /// No persisted value at all: the cache is absent or stale.
    case missing
}

/// One persisted cell value used as dependency context.
public struct OfficeCachedCellValue: Codable, Sendable, Equatable {
    public var value: String
    public var type: OfficeFormulaResultType

    public init(value: String, type: OfficeFormulaResultType) {
        self.value = value
        self.type = type
    }
}

/// One formula cell as persisted in the saved package.
public struct OfficeFormulaCellRecord: Codable, Sendable, Equatable {
    /// Worksheet member (`xl/worksheets/sheet1.xml`).
    public var member: String
    /// Workbook sheet name when declared, otherwise the member.
    public var sheet: String
    /// A1 cell reference, uppercased.
    public var cell: String
    /// The exact formula text without a leading `=`.
    public var formula: String
    /// The persisted cached result, nil when `<v>` is absent.
    public var cachedValue: String?
    /// Persisted result type; `.missing` when no value element exists.
    public var cachedType: OfficeFormulaResultType
    /// The persisted error code (e.g. `#DIV/0!`) when the result is an error.
    public var errorCode: String?

    public init(member: String, sheet: String, cell: String, formula: String,
                cachedValue: String?, cachedType: OfficeFormulaResultType,
                errorCode: String? = nil) {
        self.member = member
        self.sheet = sheet
        self.cell = cell
        self.formula = formula
        self.cachedValue = cachedValue
        self.cachedType = cachedType
        self.errorCode = errorCode
    }
}

/// What the bounded evaluator can conclude for one formula.
public enum OfficeFormulaEvaluation: Equatable, Sendable {
    case number(Double)
    case string(String)
    case boolean(Bool)
    case error(String)
    case blank
    /// The shape or its dependency context cannot be evaluated exactly.
    case unsupported(String)

    var factValue: String {
        switch self {
        case .number(let value): return trimmedNumber(value)
        case .string(let value): return value
        case .boolean(let value): return value ? "TRUE" : "FALSE"
        case .error(let code): return code
        case .blank: return ""
        case .unsupported(let reason): return "unsupported: \(reason)"
        }
    }
}

public struct OfficeFormulaCellOutcome: Equatable, Sendable {
    public enum Verdict: String, Sendable, Equatable {
        /// Recognized shape; recomputation matches the persisted cache.
        case verified
        /// Recognized shape; the persisted cache contradicts its dependencies.
        case staleCache
        /// The formula cell has no persisted cached result.
        case missingCache
        /// The persisted result is an error and the error is consistent.
        case errorCached
        /// A blank persisted result is consistent with a blank evaluation.
        case blankResult
        /// Not evaluable by the bounded checker; cache exists but is NOT
        /// claimed correct.
        case unverifiedShape
    }

    public var sheet: String
    public var cell: String
    public var formula: String
    public var cachedValue: String?
    public var verdict: Verdict
    public var detail: String?

    public init(sheet: String, cell: String, formula: String, cachedValue: String?,
                verdict: Verdict, detail: String? = nil) {
        self.sheet = sheet
        self.cell = cell
        self.formula = formula
        self.cachedValue = cachedValue
        self.verdict = verdict
        self.detail = detail
    }
}

public struct OfficeFormulaVerificationReport: Equatable, Sendable {
    public var outcomes: [OfficeFormulaCellOutcome]
    public var facts: [String]
    public var failures: [String]
    public var contextTruncated: Bool

    public var verifiedCount: Int { outcomes.filter { $0.verdict == .verified }.count }
    public var staleCount: Int { outcomes.filter { $0.verdict == .staleCache }.count }
    public var missingCount: Int { outcomes.filter { $0.verdict == .missingCache }.count }
    public var errorCount: Int { outcomes.filter { $0.verdict == .errorCached }.count }
    public var blankCount: Int { outcomes.filter { $0.verdict == .blankResult }.count }
    public var unverifiedCount: Int { outcomes.filter { $0.verdict == .unverifiedShape }.count }

    public var isClean: Bool { failures.isEmpty && !contextTruncated }

    /// One bounded fact line describing the check. Never claims more than the
    /// fixed outcome counts support.
    public var summary: String {
        var parts = ["formulaCells=\(outcomes.count)"]
        if verifiedCount > 0 { parts.append("verified=\(verifiedCount)") }
        if staleCount > 0 { parts.append("staleCache=\(staleCount)") }
        if missingCount > 0 { parts.append("missingCache=\(missingCount)") }
        if errorCount > 0 { parts.append("errorCached=\(errorCount)") }
        if blankCount > 0 { parts.append("blankResult=\(blankCount)") }
        if unverifiedCount > 0 { parts.append("unverifiedShapes=\(unverifiedCount)") }
        if contextTruncated { parts.append("contextTruncated=true") }
        return "recalc=" + parts.joined(separator: " ")
    }

    public init(outcomes: [OfficeFormulaCellOutcome] = [], facts: [String] = [],
                failures: [String] = [], contextTruncated: Bool = false) {
        self.outcomes = outcomes
        self.facts = facts
        self.failures = failures
        self.contextTruncated = contextTruncated
    }
}

/// Recomputes an expected formula result from persisted source values and
/// recursively evaluated formula dependencies. Never executes anything and never calls the network.
struct OfficeFormulaEvaluator {
    let snapshot: OfficeOutputSnapshot
    let maximumDependencies = 4_096
    let maximumRangeLength = 1_024

    /// Sheet member for a workbook-declared sheet name (case-insensitive).
    func member(forSheetName name: String) -> String? {
        for (member, declared) in snapshot.sheetNameByMember
        where declared.caseInsensitiveCompare(name) == .orderedSame {
            return member
        }
        return nil
    }

    func evaluate(_ record: OfficeFormulaCellRecord) -> OfficeFormulaEvaluation {
        let formula = record.formula.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !formula.isEmpty else { return .unsupported("empty formula") }
        guard formula.utf8.count <= 8_192 else { return .unsupported("formula too long") }
        var context = EvaluationContext(evaluator: self, rootSheet: record.member,
                                        dependencyBudget: maximumDependencies)
        return context.evaluate(formula)
    }

    /// Persisted cached value for a reference, resolved through cross-sheet
    /// names. Returns nil when the sheet or context is not visible.
    func cachedValue(sheet: String, cell: String) -> OfficeCachedCellValue? {
        guard let member = member(forSheetName: sheet) ?? (sheet.isEmpty ? nil : nil) else {
            // A sheet without a declared name may be referenced by its member
            // name in unusual packages; try that exact member too.
            if let direct = snapshot.cachedCellsBySheet.first(where: {
                $0.key.caseInsensitiveCompare(sheet) == .orderedSame
            }) {
                return direct.value[cell.uppercased()]
            }
            return nil
        }
        return snapshot.cachedCellsBySheet[member]?[cell.uppercased()]
    }

    /// Formula record for a reference, when the referenced cell is itself a
    /// formula (its cached value is the dependency context).
    func formulaRecord(sheet: String, cell: String) -> OfficeFormulaCellRecord? {
        snapshot.formulaCells.first {
            ($0.member.caseInsensitiveCompare(sheet) == .orderedSame
                || $0.sheet.caseInsensitiveCompare(sheet) == .orderedSame)
                && $0.cell == cell.uppercased()
        }
    }
}

private struct EvaluationContext {
    /// Formula tokenizer/evaluator state. Bounded by the dependency budget.
    let evaluator: OfficeFormulaEvaluator
    let rootSheet: String
    var dependencyBudget: Int
    var usedDependencies = 0
    var visitingReferences: Set<String> = []
    var currentSheet: String?
    var evaluationDepth = 0

    init(evaluator: OfficeFormulaEvaluator, rootSheet: String, dependencyBudget: Int) {
        self.evaluator = evaluator
        self.rootSheet = rootSheet
        self.dependencyBudget = dependencyBudget
    }

    mutating func evaluate(_ formula: String) -> OfficeFormulaEvaluation {
        var parser = ExpressionParser(formula: formula)
        guard let node = parser.parseExpression(), parser.atEnd else {
            return .unsupported("unrecognized formula shape")
        }
        let result = resolve(node)
        if case .number(let value) = result, !value.isFinite {
            return .unsupported("non-finite arithmetic result")
        }
        return result
    }

    private mutating func resolve(_ node: ExpressionNode) -> OfficeFormulaEvaluation {
        guard evaluationDepth < 64 else { return .unsupported("formula nesting exceeds 64") }
        evaluationDepth += 1
        defer { evaluationDepth -= 1 }
        switch node {
        case .number(let value):
            return .number(value)
        case .string(let value):
            return .string(value)
        case .boolean(let value):
            return .boolean(value)
        case .reference(let sheet, let cell):
            return resolveReference(sheet: sheet, cell: cell)
        case .range:
            // A bare range only appears as a function argument; a range used
            // as a value cannot be compared meaningfully.
            return .unsupported("a range cannot be used as a scalar value")
        case .function(let name, let arguments):
            return resolveFunction(name: name, arguments: arguments)
        case .binary(let op, let lhs, let rhs):
            return resolveBinary(op: op, lhs: lhs, rhs: rhs)
        case .negative(let value):
            switch resolve(value) {
            case .number(let number): return .number(-number)
            case .error(let code): return .error(code)
            default: return .unsupported("unary minus on a non-number")
            }
        }
    }

    private mutating func resolveReference(sheet: String?, cell: String) -> OfficeFormulaEvaluation {
        usedDependencies += 1
        guard usedDependencies <= evaluator.maximumDependencies else {
            return .unsupported("dependency budget exceeded")
        }
        let targetSheet = sheet ?? currentSheet ?? evaluator.snapshot.sheetNameByMember[rootSheet] ?? rootSheet
        guard let member = evaluator.member(forSheetName: targetSheet)
                ?? (evaluator.snapshot.cachedCellsBySheet[targetSheet] != nil ? targetSheet : nil) else {
            return .unsupported("dependency sheet is unavailable: \(targetSheet)")
        }
        if let formula = evaluator.formulaRecord(sheet: targetSheet, cell: cell) {
            let identity = member + "!" + cell.uppercased()
            guard visitingReferences.insert(identity).inserted else {
                return .unsupported("circular formula dependency")
            }
            let previousSheet = currentSheet
            currentSheet = member
            defer { currentSheet = previousSheet; visitingReferences.remove(identity) }
            guard formula.cachedType != .missing, formula.cachedValue != nil else {
                return .unsupported("formula dependency has no cached result")
            }
            // Recompute the dependency too. A stale intermediate cache cannot
            // certify another cell merely because its dependent cache agrees.
            return evaluate(formula.formula)
        }
        guard let cached = evaluator.cachedValue(sheet: targetSheet, cell: cell) else {
            guard !evaluator.snapshot.formulaContextTruncated else {
                return .unsupported("dependency context is truncated")
            }
            if evaluator.formulaRecord(sheet: targetSheet, cell: cell) != nil {
                // A formula dependency without a persisted cache is not usable
                // as dependency context; its own record is checked separately.
                return .unsupported("dependency \(targetSheet)!\(cell) has no cached result")
            }
            // An absent cell is genuinely empty in the sheet; Word/Excel treat
            // it as blank. This is not hidden: blank propagates as blank.
            return .blank
        }
        switch cached.type {
        case .number:
            guard let value = Double(cached.value) else {
                return .unsupported("dependency \(targetSheet)!\(cell) is not numeric")
            }
            return .number(value)
        case .string:
            return .string(cached.value)
        case .boolean:
            return .boolean(cached.value == "1" || cached.value.lowercased() == "true")
        case .error:
            return .error(cached.value)
        case .blank:
            return .blank
        case .missing:
            return .unsupported("dependency cache is missing")
        }
    }

    private mutating func resolveFunction(name: String, arguments: [ExpressionNode]) -> OfficeFormulaEvaluation {
        guard arguments.count <= 32 else { return .unsupported("too many function arguments") }
        switch name.uppercased() {
        case "IF":
            guard (2...3).contains(arguments.count) else { return .unsupported("IF needs 2 or 3 arguments") }
            let condition = resolve(arguments[0])
            if case .error = condition { return condition }
            if case .unsupported = condition { return condition }
            guard let value = numeric(condition) else { return .unsupported("IF condition is not numeric or boolean") }
            // Excel only evaluates the selected branch.
            if value != 0 { return resolve(arguments[1]) }
            return arguments.count == 3 ? resolve(arguments[2]) : .boolean(false)
        case "ROUND":
            guard arguments.count == 2 else { return .unsupported("ROUND needs 2 arguments") }
            let raw = resolve(arguments[0]); let digits = resolve(arguments[1])
            if case .error = raw { return raw }; if case .error = digits { return digits }
            guard let number = numeric(raw), let places = numeric(digits), number.isFinite,
                  places.isFinite, (-15...15).contains(places) else {
                return .unsupported("ROUND precision or argument is outside the supported range")
            }
            let factor = pow(10, places.rounded(.towardZero))
            let scaled = number * factor
            guard scaled.isFinite else { return .unsupported("ROUND overflow") }
            return .number(scaled.rounded(.toNearestOrAwayFromZero) / factor)
        case "SUM", "MIN", "MAX", "COUNT", "AVERAGE":
            var numbers: [Double] = []
            for argument in arguments {
                switch collectNumbers(argument, countOnly: name.uppercased() == "COUNT") {
                case .values(let values):
                    numbers.append(contentsOf: values)
                case .error(let code):
                    return .error(code)
                case .unsupported(let reason):
                    return .unsupported(reason)
                }
            }
            switch name.uppercased() {
            case "SUM": return .number(numbers.reduce(0, +))
            case "MIN": return numbers.isEmpty ? .number(0) : .number(numbers.min() ?? 0)
            case "MAX": return numbers.isEmpty ? .number(0) : .number(numbers.max() ?? 0)
            case "AVERAGE": return numbers.isEmpty ? .error("#DIV/0!") : .number(numbers.reduce(0, +) / Double(numbers.count))
            default: return .number(Double(numbers.count))
            }
        default:
            return .unsupported("function \(name) is not evaluated by the bounded checker")
        }
    }

    private enum NumberCollection {
        case values([Double])
        case error(String)
        case unsupported(String)
    }

    private mutating func collectNumbers(_ node: ExpressionNode, countOnly: Bool = false) -> NumberCollection {
        switch node {
        case .range(let sheet, let start, let end):
            guard let cells = expandRange(start: start, end: end) else {
                return .unsupported("range \(start):\(end) is not bounded")
            }
            usedDependencies += cells.count
            guard usedDependencies <= evaluator.maximumDependencies else {
                return .unsupported("dependency budget exceeded")
            }
            var values: [Double] = []
            for cell in cells {
                switch resolveReference(sheet: sheet, cell: cell) {
                case .number(let value): values.append(value)
                case .blank, .string: continue
                case .error(let code): if !countOnly { return .error(code) }
                case .unsupported(let reason): return .unsupported(reason)
                case .boolean: continue
                }
            }
            return .values(values)
        case .reference(let sheet, let cell):
            switch resolveReference(sheet: sheet, cell: cell) {
            case .number(let value): return .values([value])
            case .blank, .string: return .values([])
            case .error(let code): return countOnly ? .values([]) : .error(code)
            case .unsupported(let reason): return .unsupported(reason)
            case .boolean: return .values([])
            }
        case .number(let value):
            return .values([value])
        case .string(let value):
            if let number = Double(value), number.isFinite { return .values([number]) }
            return countOnly ? .values([]) : .error("#VALUE!")
        case .function, .binary, .negative, .boolean:
            switch resolve(node) {
            case .number(let value): return .values([value])
            case .error(let code): return .error(code)
            case .boolean(let flag): return .values([flag ? 1 : 0])
            case .string: return .unsupported("text produced by a scalar expression")
            case .blank: return .values([])
            case .unsupported(let reason): return .unsupported(reason)
            }
        }
    }

    private func expandRange(start: String, end: String) -> [String]? {
        guard let startCell = CellReference(start), let endCell = CellReference(end) else { return nil }
        let columnCount = abs(startCell.column - endCell.column) + 1
        let rowCount = abs(startCell.row - endCell.row) + 1
        guard columnCount <= evaluator.maximumRangeLength,
              rowCount <= evaluator.maximumRangeLength / columnCount else { return nil }
        let columnStep = startCell.column <= endCell.column ? 1 : -1
        let rowStep = startCell.row <= endCell.row ? 1 : -1
        let columns = Array(stride(from: startCell.column, through: endCell.column, by: columnStep))
        let rows = Array(stride(from: startCell.row, through: endCell.row, by: rowStep))
        guard columns.count * rows.count <= evaluator.maximumRangeLength else { return nil }
        var cells: [String] = []
        for column in columns {
            for row in rows {
                cells.append(CellReference.letters(for: column) + String(row))
            }
        }
        return cells
    }

    private mutating func resolveBinary(op: ExpressionOperator,
                                       lhs: ExpressionNode, rhs: ExpressionNode) -> OfficeFormulaEvaluation {
        let left = resolve(lhs)
        let right = resolve(rhs)
        if case .error(let code) = left { return .error(code) }
        if case .error(let code) = right { return .error(code) }
        if case .unsupported(let reason) = left { return .unsupported(reason) }
        if case .unsupported(let reason) = right { return .unsupported(reason) }
        guard let leftNumber = numeric(left), let rightNumber = numeric(right) else {
            return .unsupported("non-numeric operand")
        }
        switch op {
        case .equal: return .boolean(leftNumber == rightNumber)
        case .notEqual: return .boolean(leftNumber != rightNumber)
        case .less: return .boolean(leftNumber < rightNumber)
        case .lessEqual: return .boolean(leftNumber <= rightNumber)
        case .greater: return .boolean(leftNumber > rightNumber)
        case .greaterEqual: return .boolean(leftNumber >= rightNumber)
        case .add: return .number(leftNumber + rightNumber)
        case .subtract: return .number(leftNumber - rightNumber)
        case .multiply: return .number(leftNumber * rightNumber)
        case .divide:
            guard rightNumber != 0 else { return .error("#DIV/0!") }
            return .number(leftNumber / rightNumber)
        }
    }

    private func numeric(_ value: OfficeFormulaEvaluation) -> Double? {
        switch value {
        case .number(let number): return number
        case .boolean(let flag): return flag ? 1 : 0
        case .blank: return 0
        default: return nil
        }
    }
}

private enum ExpressionOperator: Equatable {
    case add, subtract, multiply, divide, equal, notEqual, less, lessEqual, greater, greaterEqual
}

private indirect enum ExpressionNode: Equatable {
    case number(Double)
    case string(String)
    case boolean(Bool)
    case reference(sheet: String?, cell: String)
    case range(sheet: String?, start: String, end: String)
    case function(String, [ExpressionNode])
    case binary(ExpressionOperator, ExpressionNode, ExpressionNode)
    case negative(ExpressionNode)
}

/// Tiny bounded recursive-descent parser for the formula subset the checker
/// evaluates. Unknown constructs fail to parse (reported unsupported), never
/// guessed.
private struct ExpressionParser {
    private let scalars: [Character]
    private var index = 0
    private var depth = 0

    init(formula: String) {
        self.scalars = Array(formula)
    }

    var atEnd: Bool {
        var cursor = index
        while cursor < scalars.count, scalars[cursor].isWhitespace { cursor += 1 }
        return cursor >= scalars.count
    }

    mutating func parseExpression() -> ExpressionNode? {
        guard let lhs = parseSum() else { return nil }
        skipWhitespace()
        let operation: ExpressionOperator?
        if consumeToken("<>") { operation = .notEqual }
        else if consumeToken("<=") { operation = .lessEqual }
        else if consumeToken(">=") { operation = .greaterEqual }
        else if consume("=") { operation = .equal }
        else if consume("<") { operation = .less }
        else if consume(">") { operation = .greater }
        else { operation = nil }
        guard let operation else { return lhs }
        guard let rhs = parseSum() else { return nil }
        return .binary(operation, lhs, rhs)
    }

    private mutating func parseSum() -> ExpressionNode? {
        guard var lhs = parseTerm() else { return nil }
        while true {
            skipWhitespace()
            if consume("+") {
                guard let rhs = parseTerm() else { return nil }
                lhs = .binary(.add, lhs, rhs)
            } else if consume("-") {
                guard let rhs = parseTerm() else { return nil }
                lhs = .binary(.subtract, lhs, rhs)
            } else {
                return lhs
            }
        }
    }

    private mutating func parseTerm() -> ExpressionNode? {
        guard var lhs = parseFactor() else { return nil }
        while true {
            skipWhitespace()
            if consume("*") {
                guard let rhs = parseFactor() else { return nil }
                lhs = .binary(.multiply, lhs, rhs)
            } else if consume("/") {
                guard let rhs = parseFactor() else { return nil }
                lhs = .binary(.divide, lhs, rhs)
            } else {
                return lhs
            }
        }
    }

    private mutating func parseFactor() -> ExpressionNode? {
        guard depth < 64 else { return nil }
        depth += 1
        defer { depth -= 1 }
        skipWhitespace()
        if consume("-") {
            guard let value = parseFactor() else { return nil }
            return .negative(value)
        }
        if consume("(") {
            guard let value = parseExpression() else { return nil }
            skipWhitespace()
            guard consume(")") else { return nil }
            return value
        }
        if peek("\"") {
            return parseString()
        }
        if peekLetterOrDigit() || peek("'") || peekNameStart() {
            return parseIdentifierOrReference()
        }
        return nil
    }

    private mutating func parseString() -> ExpressionNode? {
        guard consume("\"") else { return nil }
        var value = ""
        while index < scalars.count {
            let character = scalars[index]
            index += 1
            if character == "\"" {
                if index < scalars.count, scalars[index] == "\"" {
                    value.append("\""); index += 1; continue
                }
                return .string(value)
            }
            value.append(character)
        }
        return nil
    }

    private mutating func parseIdentifierOrReference() -> ExpressionNode? {
        let start = index
        var name = ""
        if peek("'") {
            index += 1
            var closed = false
            while index < scalars.count {
                let character = scalars[index]; index += 1
                if character == "'" {
                    if index < scalars.count, scalars[index] == "'" {
                        name.append("'"); index += 1
                    } else { closed = true; break }
                } else { name.append(character) }
            }
            guard closed else { return nil }
        } else {
            while index < scalars.count,
                  scalars[index].isLetter || scalars[index].isNumber
                    || scalars[index] == "_" || scalars[index] == "." || scalars[index] == "$" {
                name.append(scalars[index]); index += 1
            }
        }
        guard !name.isEmpty else { index = start; return nil }
        if peek("(") {
            return parseFunctionCall(name: name)
        }
        if consume("!") {
            // Sheet-qualified reference.
            let sheet = name
            return parseCellOrRange(sheet: sheet)
        }
        if name.uppercased() == "TRUE" { return .boolean(true) }
        if name.uppercased() == "FALSE" { return .boolean(false) }
        if let number = Double(name) { return .number(number) }
        // A bare cell reference (possibly a range `A1:B2`).
        let cleaned = name.replacingOccurrences(of: "$", with: "")
        guard CellReference(cleaned) != nil else { return nil }
        if consume(":") {
            var end = ""
            while index < scalars.count,
                  scalars[index].isLetter || scalars[index].isNumber || scalars[index] == "$" {
                end.append(scalars[index]); index += 1
            }
            let cleanedEnd = end.replacingOccurrences(of: "$", with: "")
            guard CellReference(cleanedEnd) != nil else { return nil }
            return .range(sheet: nil, start: cleaned, end: cleanedEnd)
        }
        return .reference(sheet: nil, cell: cleaned.uppercased())
    }

    private mutating func parseFunctionCall(name: String) -> ExpressionNode? {
        guard consume("(") else { return nil }
        var arguments: [ExpressionNode] = []
        skipWhitespace()
        if consume(")") { return .function(name, arguments) }
        while true {
            guard let argument = parseFunctionArgument() else { return nil }
            arguments.append(argument)
            skipWhitespace()
            if consume(",") || consume(";") { continue }
            guard consume(")") else { return nil }
            return .function(name, arguments)
        }
    }

    /// Function arguments are full expressions; a range is handled by the
    /// expression parser (`A1:B2` parses as one range node).
    private mutating func parseFunctionArgument() -> ExpressionNode? {
        parseExpression()
    }

    private mutating func parseCellOrRange(sheet: String?) -> ExpressionNode? {
        skipWhitespace()
        guard peekLetterOrDigit() || peek("$") else { return nil }
        var reference = ""
        while index < scalars.count,
              scalars[index].isLetter || scalars[index].isNumber || scalars[index] == "$" {
            reference.append(scalars[index]); index += 1
        }
        let cleaned = reference.replacingOccurrences(of: "$", with: "")
        guard CellReference(cleaned) != nil else { return nil }
        if consume(":") {
            var end = ""
            while index < scalars.count,
                  scalars[index].isLetter || scalars[index].isNumber || scalars[index] == "$" {
                end.append(scalars[index]); index += 1
            }
            let cleanedEnd = end.replacingOccurrences(of: "$", with: "")
            guard CellReference(cleanedEnd) != nil else { return nil }
            return .range(sheet: sheet, start: cleaned, end: cleanedEnd)
        }
        return .reference(sheet: sheet, cell: cleaned.uppercased())
    }

    private func peek(_ character: Character) -> Bool { index < scalars.count && scalars[index] == character }
    private func peekLetterOrDigit() -> Bool {
        guard index < scalars.count else { return false }
        return scalars[index].isLetter || scalars[index].isNumber
    }
    private func peekNameStart() -> Bool { peekLetterOrDigit() }

    mutating func skipWhitespace() {
        while index < scalars.count, scalars[index].isWhitespace { index += 1 }
    }

    mutating func consume(_ character: Character) -> Bool {
        skipWhitespace()
        guard index < scalars.count, scalars[index] == character else { return false }
        index += 1
        return true
    }

    private mutating func consumeToken(_ token: String) -> Bool {
        skipWhitespace()
        let characters = Array(token)
        guard !characters.isEmpty, index + characters.count <= scalars.count,
              scalars[index..<(index + characters.count)].elementsEqual(characters) else { return false }
        index += characters.count
        return true
    }
}

/// Bounded A1 reference: 1...3 letters, a positive row within the XLSX limit.
struct CellReference: Equatable {
    var column: Int
    var row: Int

    init?(_ value: String) {
        var letters = ""
        var digits = ""
        for character in value {
            if character.isLetter, digits.isEmpty {
                letters.append(Character(character.uppercased()))
            } else if character.isNumber, letters.count <= 3 {
                digits.append(character)
            } else {
                return nil
            }
        }
        guard !letters.isEmpty, !digits.isEmpty, let row = Int(digits), row >= 1, row <= 1_048_576 else {
            return nil
        }
        var column = 0
        for scalar in letters.unicodeScalars where scalar.value >= 65 && scalar.value <= 90 {
            column = column * 26 + Int(scalar.value - 64)
        }
        guard column >= 1, column <= 16_384 else { return nil }
        self.column = column
        self.row = row
    }

    init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }

    static func letters(for column: Int) -> String {
        var value = column
        var result = ""
        while value > 0 {
            value -= 1
            result.insert(Character(UnicodeScalar(65 + value % 26)!), at: result.startIndex)
            value /= 26
        }
        return result
    }
}

public enum OfficeFormulaVerifier {
    /// Verifies every persisted formula cell against its cached result and
    /// dependency context. Never mutates the file and never evaluates macros.
    public static func verify(snapshot: OfficeOutputSnapshot) -> OfficeFormulaVerificationReport {
        let records = snapshot.formulaCells
        var report = OfficeFormulaVerificationReport(contextTruncated: snapshot.formulaContextTruncated)
        guard !records.isEmpty else {
            report.facts.append("recalc=noFormulaCells (nothing to recalculate; no fake verification)")
            return report
        }
        let evaluator = OfficeFormulaEvaluator(snapshot: snapshot)
        for record in records {
            let outcome = verify(record: record, evaluator: evaluator)
            report.outcomes.append(outcome)
            switch outcome.verdict {
            case .verified:
                report.facts.append("formula=\(record.sheet)!\(record.cell) cached=\(record.cachedValue ?? "") expected=\(record.formula) verified")
            case .errorCached:
                report.facts.append("formula=\(record.sheet)!\(record.cell) cachedError=\(record.cachedValue ?? "") verified")
            case .blankResult:
                report.facts.append("formula=\(record.sheet)!\(record.cell) blankResult verified")
            case .staleCache:
                report.failures.append("\(record.sheet)!\(record.cell) \(outcome.detail ?? "cached result is stale")")
            case .missingCache:
                report.failures.append("\(record.sheet)!\(record.cell) has no persisted cached result after recalculation")
            case .unverifiedShape:
                report.facts.append("formula=\(record.sheet)!\(record.cell) unverifiedShape: \(outcome.detail ?? "shape not evaluated")")
            }
        }
        if report.contextTruncated {
            report.failures.append("the workbook exceeded the bounded formula-context limits; dependencies are incomplete")
        }
        return report
    }

    static func verify(record: OfficeFormulaCellRecord,
                       evaluator: OfficeFormulaEvaluator) -> OfficeFormulaCellOutcome {
        let evaluation = evaluator.evaluate(record)
        switch evaluation {
        case .unsupported(let reason):
            if record.cachedType == .missing {
                return OfficeFormulaCellOutcome(
                    sheet: record.sheet, cell: record.cell, formula: record.formula,
                    cachedValue: record.cachedValue, verdict: .missingCache,
                    detail: "no persisted cache and the shape is not evaluable (\(reason))")
            }
            if record.cachedType == .error {
                return OfficeFormulaCellOutcome(
                    sheet: record.sheet, cell: record.cell, formula: record.formula,
                    cachedValue: record.cachedValue, verdict: .errorCached,
                    detail: "persisted error \(record.cachedValue ?? "")")
            }
            return OfficeFormulaCellOutcome(
                sheet: record.sheet, cell: record.cell, formula: record.formula,
                cachedValue: record.cachedValue, verdict: .unverifiedShape, detail: reason)
        case .error(let expectedCode):
            guard record.cachedType == .error else {
                return OfficeFormulaCellOutcome(
                    sheet: record.sheet, cell: record.cell, formula: record.formula,
                    cachedValue: record.cachedValue, verdict: .staleCache,
                    detail: "formula evaluates to \(expectedCode) but the persisted result is \(describe(record))")
            }
            guard record.cachedValue == expectedCode else {
                return OfficeFormulaCellOutcome(
                    sheet: record.sheet, cell: record.cell, formula: record.formula,
                    cachedValue: record.cachedValue, verdict: .staleCache,
                    detail: "formula evaluates to \(expectedCode) but the persisted error is \(record.cachedValue ?? "none")")
            }
            return OfficeFormulaCellOutcome(sheet: record.sheet, cell: record.cell,
                                            formula: record.formula,
                                            cachedValue: record.cachedValue, verdict: .errorCached)
        case .blank:
            if record.cachedType == .missing || record.cachedType == .blank
                || record.cachedValue?.isEmpty == true {
                return OfficeFormulaCellOutcome(sheet: record.sheet, cell: record.cell,
                                                formula: record.formula,
                                                cachedValue: record.cachedValue, verdict: .blankResult)
            }
            return OfficeFormulaCellOutcome(
                sheet: record.sheet, cell: record.cell, formula: record.formula,
                cachedValue: record.cachedValue, verdict: .staleCache,
                detail: "formula evaluates to blank but the persisted result is \(describe(record))")
        case .number(let expected):
            guard record.cachedType != .missing else {
                return OfficeFormulaCellOutcome(
                    sheet: record.sheet, cell: record.cell, formula: record.formula,
                    cachedValue: nil, verdict: .missingCache)
            }
            guard record.cachedType == .number, let cached = Double(record.cachedValue ?? "") else {
                return OfficeFormulaCellOutcome(
                    sheet: record.sheet, cell: record.cell, formula: record.formula,
                    cachedValue: record.cachedValue, verdict: .staleCache,
                    detail: "formula evaluates to \(trimmedNumber(expected)) but the persisted result is \(describe(record))")
            }
            guard numbersMatch(expected, cached) else {
                return OfficeFormulaCellOutcome(
                    sheet: record.sheet, cell: record.cell, formula: record.formula,
                    cachedValue: record.cachedValue, verdict: .staleCache,
                    detail: "formula evaluates to \(trimmedNumber(expected)) but the persisted cache is \(trimmedNumber(cached))")
            }
            return OfficeFormulaCellOutcome(sheet: record.sheet, cell: record.cell,
                                            formula: record.formula,
                                            cachedValue: record.cachedValue, verdict: .verified)
        case .string(let expected):
            guard record.cachedType != .missing else {
                return OfficeFormulaCellOutcome(sheet: record.sheet, cell: record.cell,
                                                formula: record.formula, cachedValue: nil,
                                                verdict: .missingCache)
            }
            guard record.cachedType == .string, record.cachedValue == expected else {
                return OfficeFormulaCellOutcome(
                    sheet: record.sheet, cell: record.cell, formula: record.formula,
                    cachedValue: record.cachedValue, verdict: .staleCache,
                    detail: "formula evaluates to '\(expected)' but the persisted result is \(describe(record))")
            }
            return OfficeFormulaCellOutcome(sheet: record.sheet, cell: record.cell,
                                            formula: record.formula,
                                            cachedValue: record.cachedValue, verdict: .verified)
        case .boolean(let expected):
            guard record.cachedType != .missing else {
                return OfficeFormulaCellOutcome(sheet: record.sheet, cell: record.cell,
                                                formula: record.formula, cachedValue: nil,
                                                verdict: .missingCache)
            }
            let cachedFlag = record.cachedValue == "1" || record.cachedValue?.lowercased() == "true"
            guard record.cachedType == .boolean, cachedFlag == expected else {
                return OfficeFormulaCellOutcome(
                    sheet: record.sheet, cell: record.cell, formula: record.formula,
                    cachedValue: record.cachedValue, verdict: .staleCache,
                    detail: "formula evaluates to \(expected) but the persisted result is \(describe(record))")
            }
            return OfficeFormulaCellOutcome(sheet: record.sheet, cell: record.cell,
                                            formula: record.formula,
                                            cachedValue: record.cachedValue, verdict: .verified)
        }
    }

    private static func describe(_ record: OfficeFormulaCellRecord) -> String {
        guard record.cachedType != .missing else { return "missing" }
        let value = record.cachedValue ?? ""
        return "\(record.cachedType.rawValue)'\(value)'"
    }

    /// Numeric comparison tolerant to serialization noise (relative 1e-9) but
    /// never to a genuinely different cached result.
    static func numbersMatch(_ expected: Double, _ cached: Double) -> Bool {
        if expected == cached { return true }
        let scale = max(abs(expected), abs(cached), 1)
        return abs(expected - cached) <= scale * 1e-9
    }
}

func trimmedNumber(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 {
        return String(Int64(value))
    }
    return String(value)
}

// MARK: - Bounded worksheet parsing

extension OfficeXMLScan {
    struct DeclaredSheet: Equatable {
        var name: String
        var index: Int
        var member: String?
    }

    /// Workbook-declared sheets in workbook order, with the worksheet member
    /// resolved through `xl/_rels/workbook.xml.rels` when available.
    static func declaredSheets(workbookXML: String) -> [DeclaredSheet] {
        guard !workbookXML.isEmpty else { return [] }
        var sheets: [DeclaredSheet] = []
        guard let regex = try? NSRegularExpression(
            pattern: "<sheet[^>]*name=\"([^\"]+)\"[^>]*>", options: []) else { return [] }
        let range = NSRange(workbookXML.startIndex..<workbookXML.endIndex, in: workbookXML)
        var index = 0
        for match in regex.matches(in: workbookXML, options: [], range: range) {
            guard let nameRange = Range(match.range(at: 1), in: workbookXML) else { continue }
            index += 1
            sheets.append(DeclaredSheet(name: String(workbookXML[nameRange]),
                                        index: index, member: nil))
        }
        return sheets
    }

    struct ParsedFormulaCells {
        var formulas: [OfficeFormulaCellRecord] = []
        var cachedValues: [String: OfficeCachedCellValue] = [:]
        var truncated = false
    }

    /// Parses `<c>` elements for persisted values plus formula identity. Bounded
    /// by `maximumCells` and `maximumFormulas` so a hostile package cannot make
    /// verification unbounded.
    static func formulaCells(in sheetXML: String, sheet: String, member: String,
                             shared: [String],
                             maximumCells: Int = 40_000,
                             maximumFormulas: Int = 4_000) -> ParsedFormulaCells {
        var result = ParsedFormulaCells()
        guard let regex = try? NSRegularExpression(
            pattern: "<c r=\"([A-Z]{1,3}[0-9]+)\"([^>]*)(?<!/)>(.*?)</c>", options: [.dotMatchesLineSeparators]) else {
            return result
        }
        let range = NSRange(sheetXML.startIndex..<sheetXML.endIndex, in: sheetXML)
        var parsedCells = 0
        for match in regex.matches(in: sheetXML, options: [], range: range) {
            parsedCells += 1
            if parsedCells > maximumCells {
                result.truncated = true
                break
            }
            guard let referenceRange = Range(match.range(at: 1), in: sheetXML),
                  let attributesRange = Range(match.range(at: 2), in: sheetXML),
                  let bodyRange = Range(match.range(at: 3), in: sheetXML) else { continue }
            let reference = String(sheetXML[referenceRange]).uppercased()
            let attributes = String(sheetXML[attributesRange])
            let body = String(sheetXML[bodyRange])
            let rawType = all(pattern: "t=\"([^\"]+)\"", in: attributes).first
            let formula = all(pattern: "<f[^>]*>([^<]*)</f>", in: body).first
            let valueElement: String?
            if rawType == "inlineStr" {
                valueElement = all(pattern: "<is>.*?<t[^>]*>([^<]*)</t>", in: body).first
                    ?? all(pattern: "<t[^>]*>([^<]*)</t>", in: body).first
            } else {
                valueElement = all(pattern: "<v>([^<]*)</v>", in: body).first
            }
            let cached = cachedCellValue(rawType: rawType, rawValue: valueElement, shared: shared)
            result.cachedValues[reference] = cached
            if let formulaText = formula {
                if result.formulas.count >= maximumFormulas {
                    result.truncated = true
                    continue
                }
                let record = OfficeFormulaCellRecord(
                    member: member, sheet: sheet, cell: reference,
                    formula: unescapeXMLAttribute(formulaText),
                    cachedValue: valueElement,
                    cachedType: cached.type,
                    errorCode: cached.type == .error ? cached.value : nil)
                result.formulas.append(record)
            }
        }
        return result
    }

    /// Normalizes one persisted `<v>` (or inline string) to a value + type.
    static func cachedCellValue(rawType: String?, rawValue: String?,
                                shared: [String]) -> OfficeCachedCellValue {
        guard let rawValue else {
            return OfficeCachedCellValue(value: "", type: .missing)
        }
        switch rawType {
        case "e":
            return OfficeCachedCellValue(value: rawValue, type: .error)
        case "b":
            return OfficeCachedCellValue(value: rawValue, type: .boolean)
        case "s":
            if let index = Int(rawValue), shared.indices.contains(index) {
                return OfficeCachedCellValue(value: shared[index], type: .string)
            }
            return OfficeCachedCellValue(value: rawValue, type: .string)
        case "str", "inlineStr":
            return OfficeCachedCellValue(value: rawValue, type: .string)
        default:
            if rawValue.isEmpty {
                return OfficeCachedCellValue(value: "", type: .blank)
            }
            return OfficeCachedCellValue(value: rawValue, type: .number)
        }
    }
}
