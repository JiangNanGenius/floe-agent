import Foundation

/// RFC822-style stanza parser/emitter used by Debian control files,
/// `Packages` indexes and `Release` files.
public struct LayerPackageControl: Sendable, Equatable {
    public struct Field: Sendable, Equatable {
        public var name: String
        public var value: String
    }

    public var fields: [Field]

    public init(fields: [Field] = []) {
        self.fields = fields
    }

    public init(_ pairs: [(String, String)]) {
        fields = pairs.map { Field(name: $0.0, value: $0.1) }
    }

    public subscript(_ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public mutating func set(_ name: String, _ value: String) {
        if let index = fields.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            fields[index].value = value
        } else {
            fields.append(Field(name: name, value: value))
        }
    }

    public var serialized: String {
        var lines: [String] = []
        for field in fields {
            let valueLines = field.value.split(separator: "\n", omittingEmptySubsequences: false)
            if valueLines.isEmpty {
                lines.append("\(field.name):")
            } else {
                lines.append("\(field.name): \(valueLines[0])")
                for continuation in valueLines.dropFirst() {
                    lines.append(continuation.isEmpty ? " ." : " \(continuation)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Parses one stanza (no blank-line separation).
    public static func parse(stanza: String) -> LayerPackageControl {
        var fields: [Field] = []
        var currentName: String?
        var currentValue: [String] = []
        func flush() {
            if let currentName {
                fields.append(Field(name: currentName, value: currentValue.joined(separator: "\n")))
            }
            currentName = nil
            currentValue = []
        }
        for rawLine in stanza.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                var continuation = String(line.dropFirst())
                if continuation == "." { continuation = "" }
                currentValue.append(continuation)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            flush()
            currentName = String(line[line.startIndex..<colon])
            var value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
            currentValue = [value]
        }
        flush()
        return LayerPackageControl(fields: fields)
    }

    /// Parses a multi-stanza document (Packages, Release, status).
    public static func parseAll(_ document: String) -> [LayerPackageControl] {
        let normalized = document.replacingOccurrences(of: "\r\n", with: "\n")
        var stanzas: [LayerPackageControl] = []
        var current: [String] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    stanzas.append(parse(stanza: current.joined(separator: "\n")))
                    current = []
                }
            } else {
                current.append(String(line))
            }
        }
        if !current.isEmpty {
            stanzas.append(parse(stanza: current.joined(separator: "\n")))
        }
        return stanzas
    }
}

/// Debian version comparison (`epoch:upstream-revision`).
public enum DebVersion {
    public enum Order: Int, Sendable {
        case older = -1
        case equal = 0
        case newer = 1
    }

    public struct Parsed: Sendable, Equatable {
        public var epoch: Int
        public var upstream: String
        public var revision: String
    }

    public static func parse(_ version: String) -> Parsed {
        var remainder = version
        var epoch = 0
        if let colon = remainder.firstIndex(of: ":") {
            let prefix = remainder[remainder.startIndex..<colon]
            if let parsed = Int(prefix) {
                epoch = parsed
                remainder = String(remainder[remainder.index(after: colon)...])
            }
        }
        var revision = ""
        if let dash = remainder.lastIndex(of: "-") {
            revision = String(remainder[remainder.index(after: dash)...])
            remainder = String(remainder[remainder.startIndex..<dash])
        }
        return Parsed(epoch: epoch, upstream: remainder, revision: revision)
    }

    public static func compare(_ lhs: String, _ rhs: String) -> Order {
        let left = parse(lhs)
        let right = parse(rhs)
        if left.epoch != right.epoch {
            return left.epoch < right.epoch ? .older : .newer
        }
        let upstream = compareFragment(left.upstream, right.upstream)
        if upstream != .equal { return upstream }
        return compareFragment(left.revision, right.revision)
    }

    public static func satisfies(_ version: String, constraint: String) -> Bool {
        let trimmed = constraint.trimmingCharacters(in: .whitespaces)
        let operators = [">=", "<=", ">>", "<<", "=", ">", "<"]
        for op in operators {
            guard trimmed.hasPrefix(op) else { continue }
            let target = String(trimmed.dropFirst(op.count)).trimmingCharacters(in: .whitespaces)
            let order = compare(version, target)
            switch op {
            case ">=", ">>": return order == .newer || order == .equal
            case "<=", "<<": return order == .older || order == .equal
            case "=": return order == .equal
            case ">": return order == .newer
            case "<": return order == .older
            default: break
            }
        }
        return compare(version, trimmed) == .equal
    }

    private static func compareFragment(_ lhs: String, _ rhs: String) -> Order {
        var leftIndex = lhs.startIndex
        var rightIndex = rhs.startIndex
        while leftIndex < lhs.endIndex || rightIndex < rhs.endIndex {
            while leftIndex < lhs.endIndex, !lhs[leftIndex].isNumber, lhs[leftIndex] != "~" {
                if rightIndex < rhs.endIndex, !rhs[rightIndex].isNumber, rhs[rightIndex] != "~" {
                    let leftChar = lhs[leftIndex]
                    let rightChar = rhs[rightIndex]
                    let leftOrder = characterOrder(leftChar)
                    let rightOrder = characterOrder(rightChar)
                    if leftOrder != rightOrder { return leftOrder < rightOrder ? .older : .newer }
                    leftIndex = lhs.index(after: leftIndex)
                    rightIndex = rhs.index(after: rightIndex)
                } else if rightIndex < rhs.endIndex {
                    // Non-digit on the left vs digit on the right: right wins.
                    return .newer
                } else {
                    return .newer
                }
            }
            while rightIndex < rhs.endIndex, !rhs[rightIndex].isNumber, rhs[rightIndex] != "~" {
                return .older
            }
            if leftIndex < lhs.endIndex, lhs[leftIndex] == "~" { return .older }
            if rightIndex < rhs.endIndex, rhs[rightIndex] == "~" { return .newer }
            var leftDigits = String()
            while leftIndex < lhs.endIndex, lhs[leftIndex].isNumber {
                leftDigits.append(lhs[leftIndex])
                leftIndex = lhs.index(after: leftIndex)
            }
            var rightDigits = String()
            while rightIndex < rhs.endIndex, rhs[rightIndex].isNumber {
                rightDigits.append(rhs[rightIndex])
                rightIndex = rhs.index(after: rightIndex)
            }
            let leftNumber = Int(leftDigits) ?? 0
            let rightNumber = Int(rightDigits) ?? 0
            if leftNumber != rightNumber { return leftNumber < rightNumber ? .older : .newer }
        }
        return .equal
    }

    /// Debian's ordering: `~` < end-of-string < ASCII bytes with letters
    /// before non-letters.
    private static func characterOrder(_ character: Character) -> Int {
        if character == "~" { return -1 }
        guard let ascii = character.asciiValue else { return Int(character.unicodeScalars.first?.value ?? 0) }
        if character.isLetter { return Int(ascii) }
        return Int(ascii) + 256
    }
}
