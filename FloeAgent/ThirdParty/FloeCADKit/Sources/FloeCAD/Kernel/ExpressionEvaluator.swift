//
//  ExpressionEvaluator.swift
//  openshape3d
//
//  Tiny, self-contained arithmetic evaluator for dimension input fields
//  (plan §C2, spec §18): lets the user type "25.4/2", "10 + 5", "(1+2)*3"
//  into a dimension box and have it resolve to a number. Supports + - * /,
//  parentheses, unary minus, and a trailing unit suffix ("20 mm") which is
//  ignored. Pure Swift recursive descent — deliberately NOT NSExpression,
//  which raises an uncatchable Obj-C exception on malformed input.
//
//  Phase D (task A1): the parser now also carries a `variables` context and a
//  small function library, so dimension/variable expressions can reference
//  named variables ("w * 2") and call functions (sqrt, min, mod, radians, …).
//
//  nonisolated + Double math to match the kernel.
//

import Foundation

nonisolated enum ExpressionEvaluator {

    /// Names recognised as function calls (identifier immediately followed by
    /// "("). Used both for dispatch and to exclude them from `identifiers(in:)`.
    static let functionNames: Set<String> = [
        "sqrt", "sign", "floor", "ceil", "round", "abs",
        "mod", "min", "max", "avg",
        "sin", "cos", "tan", "asin", "acos", "atan", "atan2",
        "pi", "radians",
    ]

    /// Fully unit-qualified additive lengths, returned in document millimetres.
    /// Kept separate from the legacy scalar/variable evaluator: changing that
    /// evaluator's unit convention would double-convert existing formulas.
    /// Products, unqualified terms and angle/length mixtures are not accepted.
    static func additiveLengthMM(_ text: String) -> Double? {
        var source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.hasPrefix("=") { source.removeFirst() }
        let number = #"(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?"#
        let term = #"([+-]?)\s*("# + number + #")\s*(mm|cm|m|ft|in)"#
        guard let regex = try? NSRegularExpression(pattern: term) else { return nil }
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 2 else { return nil }
        var end = 0
        var total = 0.0
        for (index, match) in matches.enumerated() {
            let gap = ns.substring(with: NSRange(location: end, length: match.range.location - end))
            guard gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let value = Double(ns.substring(with: match.range(at: 2))) else { return nil }
            let sign = ns.substring(with: match.range(at: 1))
            guard index == 0 || !sign.isEmpty else { return nil }
            let unit = ns.substring(with: match.range(at: 3))
            let scale: Double
            switch unit {
            case "m": scale = 1000
            case "cm": scale = 10
            case "ft": scale = 304.8
            case "in": scale = 25.4
            default: scale = 1
            }
            total += (sign == "-" ? -value : value) * scale
            end = NSMaxRange(match.range)
        }
        guard ns.substring(from: end).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              total.isFinite else { return nil }
        return total
    }

    /// Evaluate `text` to a Double, or nil when it is empty / malformed.
    /// A trailing alphabetic unit suffix (mm, cm, in, "), whitespace, and a
    /// leading "=" are tolerated. Backwards-compatible entry point: no
    /// variables in scope.
    static func evaluate(_ text: String) -> Double? {
        evaluate(text, variables: [:])
    }

    /// Evaluate `text` against a `[name: value]` variable context.
    static func evaluate(_ text: String, variables: [String: Double]) -> Double? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("=") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // First attempt: parse the string as written (identifier-aware). This
        // lets expressions END in a variable/function ("b + a", "sqrt(9)").
        if let value = tryParse(s, variables: variables) { return value }

        // Retry after dropping a trailing unit suffix ("20 mm" -> "20"). Only
        // retry when stripping actually changed something non-empty, so we
        // never turn a genuinely-malformed expression into a valid one twice.
        let stripped = stripTrailingUnit(s)
        guard stripped != s, !stripped.isEmpty else { return nil }
        return tryParse(stripped, variables: variables)
    }

    /// Diagnostic for an invalid dimension draft. Use the parser's actual
    /// denominator evaluation, not a textual `/0` heuristic (e.g. `1/0.5`).
    static func validationMessage(_ text: String, variables: [String: Double]) -> String? {
        guard evaluate(text, variables: variables) == nil else { return nil }
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("=") { value.removeFirst() }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "A value is needed but none is given."
        }
        for candidate in [value, stripTrailingUnit(value)] {
            var parser = Parser(Array(candidate), variables: variables)
            _ = parser.parseExpression()
            if parser.dividedByZero {
                return "Expression is invalid. Cannot divide by zero."
            }
        }
        return "Expression contains a syntax error that cannot be parsed."
    }

    /// Set of maximal identifier tokens in `text` that denote VARIABLE
    /// references — i.e. excluding function-call names (an identifier
    /// immediately followed by "(", or any name in the function library).
    /// Real tokenization, not substring matching.
    static func identifiers(in text: String) -> Set<String> {
        let chars = Array(text)
        var result: Set<String> = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isLetter || c == "_" {
                var name = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                    name.append(chars[i])
                    i += 1
                }
                // Look past spaces for a "(" — that makes it a function call.
                var j = i
                while j < chars.count, chars[j] == " " { j += 1 }
                let isCall = j < chars.count && chars[j] == "("
                if !isCall && !functionNames.contains(name) {
                    result.insert(name)
                }
            } else {
                i += 1
            }
        }
        return result
    }

    private static func tryParse(_ s: String, variables: [String: Double]) -> Double? {
        var parser = Parser(Array(s), variables: variables)
        guard let value = parser.parseExpression(), parser.atEnd else { return nil }
        guard value.isFinite else { return nil }
        return value
    }

    /// Remove a trailing run of letters / quote (a unit like "mm" or `"`).
    private static func stripTrailingUnit(_ s: String) -> String {
        var chars = Array(s)
        while let last = chars.last, last.isLetter || last == "\"" || last == "'" || last == " " {
            chars.removeLast()
        }
        return String(chars)
    }

    // MARK: - Recursive descent

    private struct Parser {
        private let chars: [Character]
        private let variables: [String: Double]
        private var i = 0
        private(set) var dividedByZero = false

        init(_ chars: [Character], variables: [String: Double]) {
            self.chars = chars
            self.variables = variables
        }

        var atEnd: Bool {
            mutating get {
                skipSpaces()
                return i >= chars.count
            }
        }

        private mutating func skipSpaces() {
            while i < chars.count, chars[i] == " " { i += 1 }
        }

        private mutating func peek() -> Character? {
            skipSpaces()
            return i < chars.count ? chars[i] : nil
        }

        private mutating func consume() -> Character? {
            skipSpaces()
            guard i < chars.count else { return nil }
            defer { i += 1 }
            return chars[i]
        }

        // expression := term (('+'|'-') term)*
        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                _ = consume()
                guard let rhs = parseTerm() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        // term := factor (('*'|'/') factor)*
        private mutating func parseTerm() -> Double? {
            guard var value = parseFactor() else { return nil }
            while let op = peek(), op == "*" || op == "/" {
                _ = consume()
                guard let rhs = parseFactor() else { return nil }
                if op == "/" {
                    guard rhs != 0 else {
                        dividedByZero = true
                        return nil
                    }
                    value /= rhs
                } else {
                    value *= rhs
                }
            }
            return value
        }

        // factor := '-' factor | '+' factor | '(' expression ')'
        //         | identifier ['(' args ')'] | number
        private mutating func parseFactor() -> Double? {
            guard let c = peek() else { return nil }
            if c == "-" {
                _ = consume()
                guard let v = parseFactor() else { return nil }
                return -v
            }
            if c == "+" {
                _ = consume()
                return parseFactor()
            }
            if c == "(" {
                _ = consume()
                guard let v = parseExpression() else { return nil }
                guard peek() == ")" else { return nil }
                _ = consume()
                return v
            }
            if c.isLetter || c == "_" {
                return parseIdentifier()
            }
            return parseNumber()
        }

        // identifier := (letter|'_') (letter|digit|'_')*
        // If followed by "(" it is a function call; otherwise a variable ref.
        private mutating func parseIdentifier() -> Double? {
            skipSpaces()
            var name = ""
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                name.append(chars[i])
                i += 1
            }
            guard !name.isEmpty else { return nil }

            if peek() == "(" {
                _ = consume() // "("
                guard let args = parseArgList() else { return nil }
                return applyFunction(name, args)
            }

            // Variable reference.
            return variables[name]
        }

        // args := ε | expression (',' expression)*   (assumes "(" consumed)
        private mutating func parseArgList() -> [Double]? {
            var args: [Double] = []
            if peek() == ")" {
                _ = consume()
                return args
            }
            while true {
                guard let a = parseExpression() else { return nil }
                args.append(a)
                if peek() == "," {
                    _ = consume()
                    continue
                }
                break
            }
            guard peek() == ")" else { return nil }
            _ = consume()
            return args
        }

        private func applyFunction(_ name: String, _ args: [Double]) -> Double? {
            switch name {
            case "sqrt":    return args.count == 1 ? sqrt(args[0]) : nil
            case "sign":    return args.count == 1 ? (args[0] > 0 ? 1 : (args[0] < 0 ? -1 : 0)) : nil
            case "floor":   return args.count == 1 ? args[0].rounded(.down) : nil
            case "ceil":    return args.count == 1 ? args[0].rounded(.up) : nil
            case "round":   return args.count == 1 ? args[0].rounded() : nil
            case "abs":     return args.count == 1 ? Swift.abs(args[0]) : nil
            case "mod":
                guard args.count == 2, args[1] != 0 else { return nil }
                return args[0].truncatingRemainder(dividingBy: args[1])
            case "min":     return args.isEmpty ? nil : args.min()
            case "max":     return args.isEmpty ? nil : args.max()
            case "avg":     return args.isEmpty ? nil : args.reduce(0, +) / Double(args.count)
            case "sin":     return args.count == 1 ? sin(args[0]) : nil
            case "cos":     return args.count == 1 ? cos(args[0]) : nil
            case "tan":     return args.count == 1 ? tan(args[0]) : nil
            case "asin":    return args.count == 1 ? asin(args[0]) : nil
            case "acos":    return args.count == 1 ? acos(args[0]) : nil
            case "atan":    return args.count == 1 ? atan(args[0]) : nil
            case "atan2":   return args.count == 2 ? atan2(args[0], args[1]) : nil
            case "pi":      return args.isEmpty ? Double.pi : nil
            case "radians": return args.count == 1 ? args[0] * Double.pi / 180 : nil
            default:        return nil
            }
        }

        private mutating func parseNumber() -> Double? {
            skipSpaces()
            var digits = ""
            var sawDot = false
            while i < chars.count {
                let c = chars[i]
                if c.isNumber {
                    digits.append(c)
                    i += 1
                } else if c == "." && !sawDot {
                    sawDot = true
                    digits.append(c)
                    i += 1
                } else {
                    break
                }
            }
            return digits.isEmpty ? nil : Double(digits)
        }
    }
}
