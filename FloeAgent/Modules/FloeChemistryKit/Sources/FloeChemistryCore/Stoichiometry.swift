import Foundation

public struct ChemicalFormula: Sendable, Equatable {
    public let elements: [String: Int64]
    public let charge: Int64
    private static let symbols = Set("H He Li Be B C N O F Ne Na Mg Al Si P S Cl Ar K Ca Sc Ti V Cr Mn Fe Co Ni Cu Zn Ga Ge As Se Br Kr Rb Sr Y Zr Nb Mo Tc Ru Rh Pd Ag Cd In Sn Sb Te I Xe Cs Ba La Ce Pr Nd Pm Sm Eu Gd Tb Dy Ho Er Tm Yb Lu Hf Ta W Re Os Ir Pt Au Hg Tl Pb Bi Po At Rn Fr Ra Ac Th Pa U Np Pu Am Cm Bk Cf Es Fm Md No Lr Rf Db Sg Bh Hs Mt Ds Rg Cn Nh Fl Mc Lv Ts Og".split(separator: " ").map(String.init))
    public init(_ source: String) throws {
        guard source.count <= 4096, !source.isEmpty else { throw ChemistryError.invalid("Invalid chemical formula.") }
        if source == "e-" { elements = [:]; charge = -1; return }
        var text = source
        for (a, b) in zip("₀₁₂₃₄₅₆₇₈₉", "0123456789") { text = text.replacingOccurrences(of: String(a), with: String(b)) }
        var q: Int64 = 0
        if let caret = text.firstIndex(of: "^") {
            let suffix = String(text[text.index(after: caret)...])
            guard let sign = suffix.last, sign == "+" || sign == "-" else { throw ChemistryError.invalid("Use charges such as Fe^3+.") }
            let magnitude = String(suffix.dropLast())
            guard let n = magnitude.isEmpty ? 1 : Int64(magnitude), n > 0, n <= 100000 else { throw ChemistryError.invalid("Invalid ionic charge.") }
            q = sign == "+" ? n : -n; text = String(text[..<caret])
        }
        var totals: [String: Int64] = [:]
        for component in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "." || $0 == "·" }) {
            var parser = FormulaParser(chars: Array(component))
            let multiplier = try parser.number()
            let values = try parser.group(ending: nil, depth: 0)
            guard !values.isEmpty, parser.index == parser.chars.count else { throw ChemistryError.invalid("Invalid formula component.") }
            for (symbol, count) in values { totals[symbol] = try checkedAdd(totals[symbol] ?? 0, checkedMultiply(count, multiplier)) }
        }
        guard !totals.isEmpty, totals.keys.allSatisfy(Self.symbols.contains) else { throw ChemistryError.invalid("Unknown element symbol.") }
        elements = totals; charge = q
    }
}

private func checkedAdd(_ a: Int64, _ b: Int64) throws -> Int64 {
    let (value, overflow) = a.addingReportingOverflow(b)
    guard !overflow else { throw ChemistryError.invalid("Stoichiometric integer overflow.") }; return value
}
private func checkedMultiply(_ a: Int64, _ b: Int64) throws -> Int64 {
    let (value, overflow) = a.multipliedReportingOverflow(by: b)
    guard !overflow, value != Int64.min else { throw ChemistryError.invalid("Stoichiometric integer overflow.") }; return value
}
private func gcd(_ a: Int64, _ b: Int64) -> Int64 {
    var x = abs(a), y = abs(b)
    while y != 0 { (x, y) = (y, x % y) }; return max(x, 1)
}
private struct FormulaParser {
    var chars: [Character]; var index = 0
    mutating func number() throws -> Int64 {
        let start = index
        while index < chars.count, chars[index].isASCII, chars[index].isNumber { index += 1 }
        if start == index { return 1 }
        guard let n = Int64(String(chars[start..<index])), n > 0, n <= 1_000_000 else { throw ChemistryError.invalid("Invalid atom count.") }
        return n
    }
    mutating func group(ending: Character?, depth: Int) throws -> [String: Int64] {
        guard depth < 16 else { throw ChemistryError.invalid("Formula nesting exceeds its limit.") }
        var result: [String: Int64] = [:]
        while index < chars.count {
            let c = chars[index]
            if c == ")" || c == "]" {
                guard ending == c else { throw ChemistryError.invalid("Mismatched formula group.") }
                index += 1; return result
            }
            var values: [String: Int64]
            if c == "(" || c == "[" {
                index += 1; values = try group(ending: c == "(" ? ")" : "]", depth: depth + 1)
                guard !values.isEmpty else { throw ChemistryError.invalid("Empty formula group.") }
            } else {
                guard c.isASCII, c.isUppercase else { throw ChemistryError.invalid("Expected an element symbol.") }
                index += 1; var symbol = String(c)
                if index < chars.count, chars[index].isASCII, chars[index].isLowercase { symbol.append(chars[index]); index += 1 }
                values = [symbol: 1]
            }
            let n = try number()
            for (symbol, count) in values { result[symbol] = try checkedAdd(result[symbol] ?? 0, checkedMultiply(count, n)) }
        }
        guard ending == nil else { throw ChemistryError.invalid("Unclosed formula group.") }; return result
    }
}

private struct Rational {
    var n: Int64; var d: Int64
    init(_ n: Int64, _ d: Int64 = 1) throws {
        guard d != 0, n != Int64.min, d != Int64.min else { throw ChemistryError.invalid("Invalid rational coefficient.") }
        let g = gcd(n, d); self.n = n / g * (d < 0 ? -1 : 1); self.d = abs(d / g)
    }
    func subtract(_ b: Rational) throws -> Rational {
        let g = gcd(d, b.d)
        let right = try checkedMultiply(b.n, d / g)
        return try Rational(checkedAdd(checkedMultiply(n, b.d / g), -right), checkedMultiply(d / g, b.d))
    }
    func multiply(_ b: Rational) throws -> Rational {
        let aGCD = gcd(n, b.d), bGCD = gcd(b.n, d)
        return try Rational(checkedMultiply(n / aGCD, b.n / bGCD), checkedMultiply(d / bGCD, b.d / aGCD))
    }
    func divide(_ b: Rational) throws -> Rational { try multiply(Rational(b.d, b.n)) }
}

public enum ReactionBalancer {
    /// Returns minimal positive integer coefficients; conserves both atoms and explicit ionic charge.
    public static func balance(reactants: [String], products: [String]) throws -> [Int64] {
        let source = reactants + products
        guard !reactants.isEmpty, !products.isEmpty, source.count <= 64 else { throw ChemistryError.invalid("Provide reactants and products.") }
        let compounds = try source.map(ChemicalFormula.init)
        let elements = Set(compounds.flatMap { $0.elements.keys }).sorted()
        var matrix = try elements.map { element in
            try compounds.enumerated().map { i, c in try Rational((c.elements[element] ?? 0) * (i < reactants.count ? 1 : -1)) }
        }
        if compounds.contains(where: { $0.charge != 0 }) {
            matrix.append(try compounds.enumerated().map { i, c in try Rational(c.charge * (i < reactants.count ? 1 : -1)) })
        }
        var pivots: [Int] = []; var row = 0
        for col in source.indices where row < matrix.count {
            guard let pivot = (row..<matrix.count).first(where: { matrix[$0][col].n != 0 }) else { continue }
            matrix.swapAt(row, pivot); let divisor = matrix[row][col]
            for j in source.indices { matrix[row][j] = try matrix[row][j].divide(divisor) }
            for i in matrix.indices where i != row {
                let factor = matrix[i][col]
                for j in source.indices { matrix[i][j] = try matrix[i][j].subtract(factor.multiply(matrix[row][j])) }
            }
            pivots.append(col); row += 1
        }
        let free = source.indices.filter { !pivots.contains($0) }
        guard free.count == 1 else { throw ChemistryError.invalid("The reaction has no unique balance with the supplied compounds.") }
        var solution = try source.map { _ in try Rational(0) }; solution[free[0]] = try Rational(1)
        for (i, col) in pivots.enumerated() { solution[col] = try Rational(-matrix[i][free[0]].n, matrix[i][free[0]].d) }
        var multiple: Int64 = 1
        for value in solution { multiple = try checkedMultiply(multiple / gcd(multiple, value.d), value.d) }
        var integers = try solution.map { try checkedMultiply($0.n, multiple / $0.d) }
        if integers.allSatisfy({ $0 < 0 }) { integers = integers.map { -$0 } }
        guard integers.allSatisfy({ $0 > 0 }) else { throw ChemistryError.invalid("No positive balance exists for these reaction sides.") }
        let divisor = integers.reduce(0) { gcd($0, $1) }; return integers.map { $0 / divisor }
    }
}

public struct SpectrumPoint: Codable, Sendable, Equatable { public let x: Double; public let y: Double }
public struct SpectrumAnalysis: Codable, Sendable {
    public let points: [SpectrumPoint]
    public let area: Double
    public let peaks: [SpectrumPoint]
    public static func csv(_ source: String) throws -> Self {
        guard source.utf8.count <= 16 * 1024 * 1024 else { throw ChemistryError.invalid("Spectrum exceeds its size limit.") }
        var points: [SpectrumPoint] = []
        for raw in source.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let cells = line.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\t" || $0 == " " })
            guard cells.count == 2, let x = Double(cells[0]), let y = Double(cells[1]), x.isFinite, y.isFinite else {
                if points.isEmpty, ["x,y", "x;y", "x\ty"].contains(line.lowercased()) { continue }
                throw ChemistryError.invalid("Expected two finite numerical columns.")
            }
            points.append(SpectrumPoint(x: x, y: y))
            guard points.count <= 500000 else { throw ChemistryError.invalid("Spectrum has too many samples.") }
        }
        guard points.count >= 2 else { throw ChemistryError.invalid("A spectrum needs at least two samples.") }
        points.sort { $0.x < $1.x }
        var area = 0.0; var peaks: [SpectrumPoint] = []
        for i in 1..<points.count {
            guard points[i].x > points[i-1].x else { throw ChemistryError.invalid("Spectrum x coordinates must be unique.") }
            area += (points[i].x - points[i-1].x) * (points[i].y + points[i-1].y) / 2
            if i < points.count - 1, points[i].y > points[i-1].y, points[i].y > points[i+1].y { peaks.append(points[i]) }
        }
        guard area.isFinite else { throw ChemistryError.invalid("Spectrum integral overflow.") }
        return Self(points: points, area: area, peaks: peaks)
    }
}
