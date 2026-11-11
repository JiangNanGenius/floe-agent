import Foundation
import FloeToolboxCore

/// Deterministic, dependency-free scientific expression evaluation. No script
/// engine, no host interpreter, no external evaluator: one lexer, one recursive
/// descent parser, and a bounded set of elementary functions.
public enum EverydayCalculator {
    public enum AngleMode: String, Codable, Sendable, CaseIterable {
        case degrees, radians
    }

    /// Canonical form only: ASCII dot as the decimal separator, `e` for the
    /// exponent marker, and the operator set `+ - * / ^ ( )`. Callers localize
    /// typed input before evaluation; results are plain finite doubles.
    public static func evaluate(_ expression: String, angleMode: AngleMode = .degrees) throws -> Double {
        let tokens = try lex(expression)
        guard !tokens.isEmpty else { throw ToolboxError.invalid("empty expression") }
        var parser = Parser(tokens: tokens, angleMode: angleMode)
        let value = try parser.parseExpression()
        guard parser.isAtEnd else { throw ToolboxError.invalid("calculator syntax") }
        return try finite(value)
    }

    private static func finite(_ value: Double, _ message: String = "number overflow") throws -> Double {
        guard value.isFinite else { throw ToolboxError.invalid(message) }
        return value
    }

    // MARK: - Lexer

    private enum Token: Equatable {
        case number(Double)
        case binary(Character)
      // + - * / ^
        case leftParenthesis, rightParenthesis
        case function(String)
        case constant(String)
      // pi e
    }

    private static let functions: Set<String> = ["sqrt", "cbrt", "log", "ln", "exp", "sin", "cos", "tan", "asin", "acos", "atan"]
    private static let constants: Set<String> = ["pi", "e"]

    private static func lex(_ input: String) throws -> [Token] {
        var tokens: [Token] = []
        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]
            if character == " " || character == "\t" || character == "\n" {
                index = input.index(after: index); continue
            }
            if character == "\u{2212}" { tokens.append(.binary("-")); index = input.index(after: index); continue }
            if character == "+" || character == "-" || character == "*" || character == "/" || character == "^" || character == "\u{00D7}" || character == "\u{00F7}" {
                let normalized: Character = character == "\u{00D7}" ? "*" : character == "\u{00F7}" ? "/" : character
                tokens.append(.binary(normalized)); index = input.index(after: index); continue
            }
            if character == "(" { tokens.append(.leftParenthesis); index = input.index(after: index); continue }
            if character == ")" { tokens.append(.rightParenthesis); index = input.index(after: index); continue }
            if character.isASCII, character.isLetter {
                let start = index
                while index < input.endIndex, input[index].isASCII, input[index].isLetter { index = input.index(after: index) }
                let word = String(input[start..<index])
                if functions.contains(word) { tokens.append(.function(word)) }
                else if constants.contains(word) { tokens.append(.constant(word)) }
                else { throw ToolboxError.invalid("calculator syntax") }
                continue
            }
            if character.isNumber || character == "." {
                let start = index
                var sawDigit = false, sawDot = false
                while index < input.endIndex {
                    let current = input[index]
                    if current.isNumber { sawDigit = true; index = input.index(after: index); continue }
                    if current == ".", !sawDot { sawDot = true; index = input.index(after: index); continue }
                    break
                }
                guard sawDigit else { throw ToolboxError.invalid("calculator syntax") }
                // Exponent: `e`/`E` directly followed by an optional sign and digits.
                if index < input.endIndex, input[index] == "e" || input[index] == "E" {
                    var probe = input.index(after: index)
                    if probe < input.endIndex, input[probe] == "+" || input[probe] == "-" { probe = input.index(after: probe) }
                    if probe < input.endIndex, input[probe].isNumber {
                        index = input.index(after: index)
                        if input[index] == "+" || input[index] == "-" { index = input.index(after: index) }
                        while index < input.endIndex, input[index].isNumber { index = input.index(after: index) }
                    }
                }
                let text = String(input[start..<index])
                guard let value = Double(text) else { throw ToolboxError.invalid("calculator syntax") }
                tokens.append(.number(value)); continue
            }
            throw ToolboxError.invalid("calculator syntax")
        }
        return tokens
    }

    // MARK: - Parser
    // expression := term (('+'|'-') term)*
    // term       := unary (('*'|'/') unary)*
    // unary      := ('-'|'+') unary | power
    // power      := postfix ('^' unary)?        right-associative
    // postfix    := number | constant | function '(' expression ')' | '(' expression ')'
    // Unary minus binds more loosely than `^`, so -2^2 == -(2^2) == -4 and
    // 2^-2 == 2^(-2) == 0.25, matching ordinary scientific calculators.

    private struct Parser {
        let tokens: [Token]
        let angleMode: AngleMode
        var position = 0

        init(tokens: [Token], angleMode: EverydayCalculator.AngleMode) { self.tokens = tokens; self.angleMode = angleMode }

        var isAtEnd: Bool { position >= tokens.count }
        private func peek() -> Token? { position < tokens.count ? tokens[position] : nil }

        private mutating func advance() -> Token? {
            guard position < tokens.count else { return nil }
            let token = tokens[position]; position += 1; return token
        }

        mutating func parseExpression() throws -> Double {
            var value = try parseTerm()
            while let token = peek(), case .binary(let op) = token, op == "+" || op == "-" {
                _ = advance()
                let rhs = try parseTerm()
                value = try EverydayCalculator.finite(op == "+" ? value + rhs : value - rhs)
            }
            return value
        }

        private mutating func parseTerm() throws -> Double {
            var value = try parseUnary()
            while let token = peek(), case .binary(let op) = token, op == "*" || op == "/" {
                _ = advance()
                let rhs = try parseUnary()
                if op == "/" {
                    guard rhs != 0 else { throw ToolboxError.invalid("division by zero") }
                    value = try EverydayCalculator.finite(value / rhs)
                } else {
                    value = try EverydayCalculator.finite(value * rhs)
                }
            }
            return value
        }

        private mutating func parseUnary() throws -> Double {
            guard let token = advance() else { throw ToolboxError.invalid("calculator syntax") }
            if case .binary(let op) = token, op == "-" { return try EverydayCalculator.finite(-parseUnary()) }
            if case .binary(let op) = token, op == "+" { return try parseUnary() }
            position -= 1
            return try parsePower()
        }

        private mutating func parsePower() throws -> Double {
            let base = try parsePostfix()
            guard let token = peek(), case .binary("^") = token else { return base }
            _ = advance()
            let exponent = try parseUnary()
            if base < 0, exponent != exponent.rounded() {
                throw ToolboxError.invalid("outside the function domain")
            }
            return try EverydayCalculator.finite(pow(base, exponent))
        }

        private mutating func parsePostfix() throws -> Double {
            guard let token = advance() else { throw ToolboxError.invalid("calculator syntax") }
            switch token {
            case .number(let value): return value
            case .constant(let name): return name == "pi" ? Double.pi : M_E
            case .function(let name):
                guard case .leftParenthesis? = advance() else { throw ToolboxError.invalid("calculator syntax") }
                let argument = try parseExpression()
                guard case .rightParenthesis? = advance() else { throw ToolboxError.invalid("calculator syntax") }
                return try EverydayCalculator.apply(name, to: argument, angleMode: angleMode)
            case .leftParenthesis:
                let value = try parseExpression()
                guard case .rightParenthesis? = advance() else { throw ToolboxError.invalid("calculator syntax") }
                return value
            default: throw ToolboxError.invalid("calculator syntax")
            }
        }
    }

    private static func apply(_ function: String, to raw: Double, angleMode: AngleMode) throws -> Double {
        let radians = angleMode == .degrees ? raw * Double.pi / 180 : raw
        let value: Double
        switch function {
        case "sqrt":
            guard raw >= 0 else { throw ToolboxError.invalid("outside the function domain") }
            value = raw.squareRoot()
        case "cbrt": value = cbrt(raw)
        case "log":
            guard raw > 0 else { throw ToolboxError.invalid("outside the function domain") }
            value = log10(raw)
        case "ln":
            guard raw > 0 else { throw ToolboxError.invalid("outside the function domain") }
            value = log(raw)
        case "exp": value = exp(raw)
        case "sin": value = sin(radians)
        case "cos": value = cos(radians)
        case "tan":
            value = tan(radians)
            // At odd multiples of 90 degrees the argument rounds to a finite
            // double just off the pole and libm returns ~1e16, not infinity.
            // Treat anything past 1e15 as the undefined pole, deterministically.
            guard abs(value) <= 1e15 else { throw ToolboxError.invalid("outside the function domain") }
        case "asin":
            guard abs(raw) <= 1 else { throw ToolboxError.invalid("outside the function domain") }
            value = asin(raw); return angleMode == .degrees ? try finite(value * 180 / Double.pi) : try finite(value)
        case "acos":
            guard abs(raw) <= 1 else { throw ToolboxError.invalid("outside the function domain") }
            value = acos(raw); return angleMode == .degrees ? try finite(value * 180 / Double.pi) : try finite(value)
        case "atan":
            value = atan(raw); return angleMode == .degrees ? try finite(value * 180 / Double.pi) : try finite(value)
        default: throw ToolboxError.invalid("calculator syntax")
        }
        return try finite(value, function == "tan" ? "outside the function domain" : "number overflow")
    }
}

/// Plain, locale-aware number text for calculator results, history rows and
/// unit conversions. Grouping separators are deliberately omitted so copied
/// values stay machine-usable; only the decimal separator is localized.
public enum EverydayNumberText {
    public static func calculatorString(for value: Double, locale: Locale = .current) -> String {
        guard value.isFinite else { return "Error" }
        let negative = value < 0
        let magnitude = abs(value)
        let body: String
        if magnitude == 0 {
            body = "0"
        } else if magnitude >= 1e16 || magnitude < 1e-6 {
            body = scientific(magnitude)
        } else if magnitude == magnitude.rounded() {
            body = String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), magnitude)
        } else {
            var text = String(format: "%.10f", locale: Locale(identifier: "en_US_POSIX"), magnitude)
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            body = text
        }
        let localized = locale.decimalSeparator == "." ? body : body.replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
        return (negative ? "-" : "") + localized
    }

    private static func scientific(_ magnitude: Double) -> String {
        let text = String(format: "%.8e", locale: Locale(identifier: "en_US_POSIX"), magnitude)
        // "%.8e" -> "d.dddddddde±xx" (uppercase on some platforms); trim
        // mantissa zeros and normalize the exponent.
        guard let marker = text.firstIndex(where: { $0 == "e" || $0 == "E" }) else { return text }
        var mantissa = String(text[text.startIndex..<marker])
        var exponent = String(text[text.index(after: marker)...])
        while mantissa.hasSuffix("0") { mantissa.removeLast() }
        if mantissa.hasSuffix(".") { mantissa.removeLast() }
        var sign = ""
        if exponent.hasPrefix("+") { exponent.removeFirst() }
        else if exponent.hasPrefix("-") { sign = "-"; exponent.removeFirst() }
        while exponent.count > 1, exponent.hasPrefix("0") { exponent.removeFirst() }
        return mantissa + "e" + sign + exponent
    }

    /// Converts user-typed text (localized decimal separator, typographic
    /// operators) into the canonical calculator form before evaluation.
    public static func canonical(_ input: String, locale: Locale = .current) -> String {
        var text = input.replacingOccurrences(of: "\u{2212}", with: "-")
        text = text.replacingOccurrences(of: "\u{00D7}", with: "*")
        text = text.replacingOccurrences(of: "\u{00F7}", with: "/")
        if let separator = locale.decimalSeparator, separator != "." {
            text = text.replacingOccurrences(of: separator, with: ".")
        }
        return text
    }
}

/// One immutable history row. The expression stays in canonical calculator
/// form so a re-used entry evaluates identically on every locale.
public struct EverydayCalculatorHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let expression: String
    public let result: String
    public let timestamp: Date
    public init(id: UUID = UUID(), expression: String, result: String, timestamp: Date = Date()) {
        self.id = id; self.expression = expression; self.result = result; self.timestamp = timestamp
    }
}

/// Bounded, file-backed history. Corrupt archives throw and never turn into a
/// silent empty list; writes are atomic so an interruption cannot strand a
/// partially written store.
public actor EverydayCalculatorHistoryStore {
    public let url: URL
    nonisolated public let maximumCount: Int
    public init(url: URL, maximumCount: Int = 200) {
        self.url = url
        self.maximumCount = max(1, min(maximumCount, 1000))
    }

    public func load() throws -> [EverydayCalculatorHistoryEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_048_576 else { throw ToolboxError.limit("calculator history") }
        let decoded: [EverydayCalculatorHistoryEntry]
        do { decoded = try JSONDecoder().decode([EverydayCalculatorHistoryEntry].self, from: Data(contentsOf: url)) }
        catch { throw ToolboxError.corruptStore }
        guard decoded.count <= maximumCount, Set(decoded.map(\.id)).count == decoded.count,
              decoded.allSatisfy({ !$0.expression.isEmpty && $0.expression.utf8.count <= 1024 && $0.result.utf8.count <= 256 && $0.timestamp.timeIntervalSince1970.isFinite }) else {
            throw ToolboxError.corruptStore
        }
        return decoded
    }

    @discardableResult public func add(_ entry: EverydayCalculatorHistoryEntry) throws -> [EverydayCalculatorHistoryEntry] {
        guard !entry.expression.isEmpty, entry.expression.utf8.count <= 1024, entry.result.utf8.count <= 256 else {
            throw ToolboxError.invalid("calculator history entry")
        }
        var values = try load()
        values.insert(entry, at: 0)
        if values.count > maximumCount { values = Array(values.prefix(maximumCount)) }
        try write(values)
        return values
    }

    public func removeAll() throws {
        try write([])
    }

    private func write(_ values: [EverydayCalculatorHistoryEntry]) throws {
        let data = try JSONEncoder().encode(values)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
