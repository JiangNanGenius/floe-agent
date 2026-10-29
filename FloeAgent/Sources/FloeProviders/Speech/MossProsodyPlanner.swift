// FloeProviders — Accepted MOSS paragraph prosody planner (flatPause only).
//
// SPDX-License-Identifier: MPL-2.0
//
// Imported from the accepted private flatPause baseline. The planner owns ONE
// caller-supplied complete paragraph and only softens internal full stops in a
// narrow, conservative case: at least four complete declarative sentences,
// strict ZH/EN alternation, at least two sentences per language, no mixed
// language unit, no long unit and no ambiguous/opaque marker (URL, Markdown,
// table, code, quote, bracket, ellipsis, question/exclamation, dotted token).
//
// Everything else returns `spoken == source` unchanged with a machine-readable
// reason. `pairedPause`, low-temperature variants and the unverified full-URI
// acoustic candidate are deliberately NOT imported.
//
// Edits and units are declared in UTF-16 code units for BOTH the original
// source and the planned spoken text. The spoken projection is the only text
// that may reach synthesis; it never rewrites a word, case or order outside
// the declared internal terminator edits.

import Foundation

public struct MossProsodyClassifierParameters: Codable, Sendable, Equatable {
    public var minimumUnits: Int
    public var minimumUnitsPerLanguage: Int
    public var maximumCJKPerChineseUnit: Int
    public var maximumWordsPerEnglishUnit: Int
    public var maximumLatinCharactersPerEnglishUnit: Int

    public init(
        minimumUnits: Int = 4,
        minimumUnitsPerLanguage: Int = 2,
        maximumCJKPerChineseUnit: Int = 16,
        maximumWordsPerEnglishUnit: Int = 6,
        maximumLatinCharactersPerEnglishUnit: Int = 40
    ) {
        self.minimumUnits = minimumUnits
        self.minimumUnitsPerLanguage = minimumUnitsPerLanguage
        self.maximumCJKPerChineseUnit = maximumCJKPerChineseUnit
        self.maximumWordsPerEnglishUnit = maximumWordsPerEnglishUnit
        self.maximumLatinCharactersPerEnglishUnit = maximumLatinCharactersPerEnglishUnit
    }
}

public enum MossProsodyUnitKind: String, Sendable, Equatable {
    case shortChinese
    case shortEnglish
    case other

    public var language: String? {
        switch self {
        case .shortChinese: return "zh"
        case .shortEnglish: return "en"
        case .other: return nil
        }
    }
}

public struct MossProsodyUnit: Codable, Sendable, Equatable {
    public let index: Int
    public let text: String
    public let language: String
    public let utf16Start: Int
    public let utf16End: Int
    public let characterLength: Int
    public let cjkCharacterCount: Int
    public let latinLetterCount: Int
    public let wordCount: Int
    public let finalTerminator: String

    public init(
        index: Int,
        text: String,
        language: String,
        utf16Start: Int,
        utf16End: Int,
        characterLength: Int,
        cjkCharacterCount: Int,
        latinLetterCount: Int,
        wordCount: Int,
        finalTerminator: String
    ) {
        self.index = index
        self.text = text
        self.language = language
        self.utf16Start = utf16Start
        self.utf16End = utf16End
        self.characterLength = characterLength
        self.cjkCharacterCount = cjkCharacterCount
        self.latinLetterCount = latinLetterCount
        self.wordCount = wordCount
        self.finalTerminator = finalTerminator
    }
}

public struct MossProsodyEdit: Codable, Sendable, Equatable {
    public let index: Int
    public let sourceUTF16Start: Int
    public let sourceUTF16Length: Int
    public let spokenUTF16Start: Int
    public let spokenUTF16Length: Int
    public let replaced: String
    public let replacement: String

    public init(
        index: Int,
        sourceUTF16Start: Int,
        sourceUTF16Length: Int,
        spokenUTF16Start: Int,
        spokenUTF16Length: Int,
        replaced: String,
        replacement: String
    ) {
        self.index = index
        self.sourceUTF16Start = sourceUTF16Start
        self.sourceUTF16Length = sourceUTF16Length
        self.spokenUTF16Start = spokenUTF16Start
        self.spokenUTF16Length = spokenUTF16Length
        self.replaced = replaced
        self.replacement = replacement
    }
}

public struct MossProsodyPlan: Codable, Sendable, Equatable {
    public let source: String
    public let spoken: String
    public let eligible: Bool
    public let reason: String
    public let units: [MossProsodyUnit]
    public let edits: [MossProsodyEdit]
    public let parameters: MossProsodyClassifierParameters
    public let sourceUTF16Length: Int
    public let spokenUTF16Length: Int
    public let sourceWordSequencePreserved: Bool
    public let finalTerminatorPreserved: Bool

    public init(
        source: String,
        spoken: String,
        eligible: Bool,
        reason: String,
        units: [MossProsodyUnit],
        edits: [MossProsodyEdit],
        parameters: MossProsodyClassifierParameters,
        sourceUTF16Length: Int,
        spokenUTF16Length: Int,
        sourceWordSequencePreserved: Bool,
        finalTerminatorPreserved: Bool
    ) {
        self.source = source
        self.spoken = spoken
        self.eligible = eligible
        self.reason = reason
        self.units = units
        self.edits = edits
        self.parameters = parameters
        self.sourceUTF16Length = sourceUTF16Length
        self.spokenUTF16Length = spokenUTF16Length
        self.sourceWordSequencePreserved = sourceWordSequencePreserved
        self.finalTerminatorPreserved = finalTerminatorPreserved
    }
}

public enum MossProsodyPlanner {
    private static let editableTerminators: Set<Character> = [".", "。"]
    private static let hanRanges: [ClosedRange<UInt32>] = [
        0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
    ]
    private static let nonHanEastAsianRanges: [ClosedRange<UInt32>] = [
        0x3040...0x30FF, 0x31F0...0x31FF, 0xAC00...0xD7AF, 0x1100...0x11FF,
    ]
    private static let quotationCharacters: Set<Character> = [
        "\"", "'", "“", "”", "‘", "’", "「", "」", "『", "』", "《", "》", "〈", "〉",
    ]
    private static let bracketCharacters: Set<Character> = [
        "(", ")", "（", "）", "[", "]", "【", "】", "［", "］",
    ]
    private static let protectedTokenMarkers: [String] = [
        "{", "}", "<", ">", "[[", "]]", "{{", "}}", "$(",
    ]
    private static let tableMarkers: Set<Character> = ["|", "｜", "┃", "┬", "┼"]
    private static let bulletMarkers: Set<Character> = ["•", "◦", "▪", "▫", "·", "—"]
    private static let questionOrExclamation: Set<Character> = ["?", "!", "？", "！"]

    /// The accepted flatPause style: each internal sentence stop and the
    /// whitespace after it becomes one fullwidth comma. The final terminator
    /// is preserved exactly.
    public static func flatPause(
        _ source: String,
        parameters: MossProsodyClassifierParameters = MossProsodyClassifierParameters()
    ) -> MossProsodyPlan {
        func unchanged(_ reason: String) -> MossProsodyPlan {
            MossProsodyPlan(
                source: source,
                spoken: source,
                eligible: false,
                reason: reason,
                units: [],
                edits: [],
                parameters: parameters,
                sourceUTF16Length: source.utf16.count,
                spokenUTF16Length: source.utf16.count,
                sourceWordSequencePreserved: true,
                finalTerminatorPreserved: true)
        }

        guard !source.isEmpty else { return unchanged("empty") }
        guard source.trimmingCharacters(in: .whitespacesAndNewlines) == source else {
            return unchanged("outer_whitespace")
        }
        for scalar in source.unicodeScalars
        where scalar.value == 0x0A || scalar.value == 0x0D || scalar.value == 0x09 {
            return unchanged("newline_or_tab")
        }
        if source.contains(where: { tableMarkers.contains($0) }) { return unchanged("table_marker") }
        if source.contains(where: { bulletMarkers.contains($0) }) { return unchanged("list_marker") }
        if isListMarkerStart(source) { return unchanged("list_marker") }
        if source.contains("`") || source.contains("~~~") || source.contains("\u{FF40}") {
            return unchanged("code_marker")
        }
        let lower = source.lowercased()
        if lower.contains("://") || lower.contains("http") || lower.contains("www.")
            || lower.contains("mailto:") || lower.contains("ftp.") {
            return unchanged("url_or_uri")
        }
        if containsEmailAddress(source) { return unchanged("email") }
        if source.contains("](") || source.contains("![") || source.contains("<http") {
            return unchanged("markdown_link")
        }
        if protectedTokenMarkers.contains(where: { source.contains($0) }) {
            return unchanged("protected_token")
        }
        if source.contains(where: { quotationCharacters.contains($0) }) {
            return unchanged("ambiguous_quotation")
        }
        if source.contains(where: { bracketCharacters.contains($0) }) {
            return unchanged("ambiguous_bracket")
        }
        if source.contains("…") || source.contains("...") || source.contains("⋯") {
            return unchanged("ellipsis")
        }
        if source.contains(where: { questionOrExclamation.contains($0) }) {
            return unchanged("question_or_exclamation")
        }
        if containsOpaqueDottedToken(source) { return unchanged("dotted_token") }
        if containsKnownAbbreviationDot(source) { return unchanged("known_abbreviation") }

        var segmenter = TTSTextSegmenter(policy: .completeSentences)
        var units = segmenter.append(source)
        units.append(contentsOf: segmenter.finish())
        guard segmenter.finish().isEmpty else { return unchanged("segmenter_tail_not_empty") }
        guard units.count >= parameters.minimumUnits else { return unchanged("too_few_units") }

        var cursor = source.startIndex
        var mapped: [(text: String, range: Range<String.Index>)] = []
        for unit in units {
            guard let found = source.range(of: unit, range: cursor..<source.endIndex) else {
                return unchanged("span_alignment_failed")
            }
            guard source[cursor..<found.lowerBound].allSatisfy({ $0.isWhitespace }) else {
                return unchanged("span_alignment_failed")
            }
            mapped.append((unit, found))
            cursor = found.upperBound
        }
        guard cursor == source.endIndex else { return unchanged("span_alignment_failed") }

        var classified: [MossProsodyUnit] = []
        var chineseCount = 0
        var englishCount = 0
        var languages: [String] = []
        for (index, entry) in mapped.enumerated() {
            let text = entry.text
            guard let terminator = text.last, editableTerminators.contains(terminator) else {
                return unchanged("unit_not_declarative")
            }
            let body = String(text.dropLast())
            let cjk = hanScalarCount(body)
            if nonHanEastAsianCount(body) > 0 { return unchanged("unsupported_unit_language") }
            let latin = latinLetterCount(body)
            let words = wordCount(body)
            let language: String
            if cjk > 0 && latin > 0 {
                return unchanged("mixed_language_unit")
            } else if cjk > 0 {
                guard cjk <= parameters.maximumCJKPerChineseUnit else {
                    return unchanged("zh_unit_too_long")
                }
                language = "zh"
                chineseCount += 1
            } else if latin > 0 {
                guard words <= parameters.maximumWordsPerEnglishUnit,
                      latin <= parameters.maximumLatinCharactersPerEnglishUnit else {
                    return unchanged("en_unit_too_long")
                }
                language = "en"
                englishCount += 1
            } else {
                return unchanged("unsupported_unit_language")
            }
            languages.append(language)
            let start = utf16Offset(source, entry.range.lowerBound)
            let end = utf16Offset(source, entry.range.upperBound)
            classified.append(MossProsodyUnit(
                index: index,
                text: text,
                language: language,
                utf16Start: start,
                utf16End: end,
                characterLength: text.count,
                cjkCharacterCount: cjk,
                latinLetterCount: latin,
                wordCount: words,
                finalTerminator: String(terminator)))
        }
        for index in 1..<languages.count where languages[index] == languages[index - 1] {
            return unchanged("no_strict_alternation")
        }
        guard chineseCount >= parameters.minimumUnitsPerLanguage,
              englishCount >= parameters.minimumUnitsPerLanguage else {
            return unchanged("language_quota_not_met")
        }

        var edits: [MossProsodyEdit] = []
        for index in 0..<(mapped.count - 1) {
            let current = mapped[index]
            let next = mapped[index + 1]
            let terminatorIndex = source.index(before: current.range.upperBound)
            let gap = source[current.range.upperBound..<next.range.lowerBound]
            guard gap.allSatisfy({ $0.isWhitespace }) else {
                return unchanged("span_alignment_failed")
            }
            guard editableTerminators.contains(source[terminatorIndex]) else {
                return unchanged("unit_not_declarative")
            }
            let sourceStart = utf16Offset(source, terminatorIndex)
            let sourceEnd = utf16Offset(source, next.range.lowerBound)
            let replaced = String(source[terminatorIndex..<next.range.lowerBound])
            edits.append(MossProsodyEdit(
                index: index,
                sourceUTF16Start: sourceStart,
                sourceUTF16Length: sourceEnd - sourceStart,
                spokenUTF16Start: sourceStart,
                spokenUTF16Length: 1,
                replaced: replaced,
                replacement: "，"))
        }
        var cumulativeDelta = 0
        edits = edits.map { edit in
            let value = MossProsodyEdit(
                index: edit.index,
                sourceUTF16Start: edit.sourceUTF16Start,
                sourceUTF16Length: edit.sourceUTF16Length,
                spokenUTF16Start: edit.sourceUTF16Start + cumulativeDelta,
                spokenUTF16Length: 1,
                replaced: edit.replaced,
                replacement: edit.replacement)
            cumulativeDelta += 1 - edit.sourceUTF16Length
            return value
        }
        let spoken = applying(edits, to: source)
        let wordsPreserved = wordSequence(source) == wordSequence(spoken)
        guard wordsPreserved else { return unchanged("word_sequence_not_preserved") }
        guard spoken.last == source.last else { return unchanged("final_terminator_changed") }
        for edit in edits {
            guard edit.sourceUTF16Start >= 0,
                  edit.sourceUTF16Start + edit.sourceUTF16Length <= source.utf16.count,
                  edit.spokenUTF16Start >= 0,
                  edit.spokenUTF16Start + edit.spokenUTF16Length <= spoken.utf16.count else {
                return unchanged("span_alignment_failed")
            }
        }
        return MossProsodyPlan(
            source: source,
            spoken: spoken,
            eligible: true,
            reason: "eligible",
            units: classified,
            edits: edits,
            parameters: parameters,
            sourceUTF16Length: source.utf16.count,
            spokenUTF16Length: spoken.utf16.count,
            sourceWordSequencePreserved: wordsPreserved,
            finalTerminatorPreserved: true)
    }

    /// Quick classifier used only to decide whether a streaming sentence MAY
    /// join a bounded alternation candidate. The full conservative gate in
    /// `flatPause` remains authoritative.
    public static func classify(_ text: String) -> MossProsodyUnitKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, editableTerminators.contains(last) else { return .other }
        let body = String(trimmed.dropLast())
        let cjk = hanScalarCount(body)
        let latin = latinLetterCount(body)
        if cjk > 0, latin == 0, nonHanEastAsianCount(body) == 0, cjk <= 16 {
            return .shortChinese
        }
        if latin > 0, cjk == 0, wordCount(body) <= 6, latin <= 40 {
            return .shortEnglish
        }
        return .other
    }

    public static func applying(_ edits: [MossProsodyEdit], to text: String) -> String {
        var output = text
        for edit in edits.sorted(by: { $0.sourceUTF16Start > $1.sourceUTF16Start }) {
            let start = String.Index(utf16Offset: edit.sourceUTF16Start, in: output)
            let end = String.Index(utf16Offset: edit.sourceUTF16Start + edit.sourceUTF16Length, in: output)
            output.replaceSubrange(start..<end, with: edit.replacement)
        }
        return output
    }

    public static func reconstructing(_ spoken: String, with edits: [MossProsodyEdit]) -> String {
        var output = spoken
        for edit in edits.sorted(by: { $0.spokenUTF16Start > $1.spokenUTF16Start }) {
            let start = String.Index(utf16Offset: edit.spokenUTF16Start, in: output)
            let end = String.Index(utf16Offset: edit.spokenUTF16Start + edit.spokenUTF16Length, in: output)
            output.replaceSubrange(start..<end, with: edit.replaced)
        }
        return output
    }

    public static func wordSequence(_ text: String) -> String {
        String(text.filter { $0.isLetter || $0.isNumber })
    }

    // MARK: - Guard helpers

    private static func utf16Offset(_ text: String, _ index: String.Index) -> Int {
        text[..<index].utf16.count
    }

    private static func isListMarkerStart(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return false }
        if ["-", "*", "+", ">"].contains(first) {
            return trimmed.dropFirst().first?.isWhitespace ?? true
        }
        if first == "#" { return true }
        var digits = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index].isNumber, digits < 4 {
            digits += 1
            index = trimmed.index(after: index)
        }
        if digits > 0, digits <= 3, index < trimmed.endIndex {
            let marker = trimmed[index]
            if marker == "." || marker == ")" {
                let after = trimmed.index(after: index)
                return after >= trimmed.endIndex || trimmed[after].isWhitespace
            }
        }
        return false
    }

    private static func containsEmailAddress(_ source: String) -> Bool {
        let characters = Array(source)
        guard characters.contains("@") else { return false }
        for (index, character) in characters.enumerated() where character == "@" {
            let previousIsAddressCharacter = index > 0
                && (characters[index - 1].isLetter || characters[index - 1].isNumber)
            let left = previousIsAddressCharacter
            let right = index + 3 < characters.count
            if left && right && characters[(index + 1)...].contains(".")
                && characters[(index + 1)...].contains(where: { $0.isLetter }) {
                return true
            }
        }
        return false
    }

    private static func containsOpaqueDottedToken(_ source: String) -> Bool {
        let characters = Array(source)
        guard characters.count >= 3 else { return false }
        for index in 1..<(characters.count - 1) where characters[index] == "." {
            let previous = characters[index - 1]
            let next = characters[index + 1]
            if (previous.isLetter && next.isLetter) || (previous.isNumber && next.isNumber) {
                return true
            }
        }
        return false
    }

    private static func containsKnownAbbreviationDot(_ source: String) -> Bool {
        let characters = Array(source)
        for index in characters.indices where characters[index] == "." {
            var word = ""
            var probe = index
            while probe > 0 {
                let character = characters[probe - 1]
                if character.isLetter || character == "." {
                    word.insert(character, at: word.startIndex)
                } else {
                    break
                }
                probe -= 1
            }
            var candidate = word.lowercased()
            while candidate.hasSuffix(".") { candidate.removeLast() }
            if !candidate.isEmpty && TTSTextSegmenter.abbreviations.contains(candidate) {
                return true
            }
        }
        return false
    }

    private static func hanScalarCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            count + (hanRanges.contains(where: { $0.contains(scalar.value) }) ? 1 : 0)
        }
    }

    private static func nonHanEastAsianCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            count + (nonHanEastAsianRanges.contains(where: { $0.contains(scalar.value) }) ? 1 : 0)
        }
    }

    private static func latinLetterCount(_ text: String) -> Int {
        var count = 0
        for character in text where character.isLetter {
            var isHan = false
            for scalar in character.unicodeScalars {
                if hanRanges.contains(where: { $0.contains(scalar.value) }) {
                    isHan = true
                    break
                }
            }
            if !isHan { count += 1 }
        }
        return count
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace })
            .filter { token in token.contains(where: { $0.isLetter || $0.isNumber }) }
            .count
    }
}
