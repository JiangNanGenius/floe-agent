// FloeProviders — Read-aloud text projection with URL-aware speech routing.
//
// SPDX-License-Identifier: MPL-2.0
//
// The final answer body, the read-aloud display text and the spoken projection
// are deliberately separate:
//
//   * `sourceText` is the cleaned Markdown body (code/tables/markup already
//     handled by the caller's projection). It keeps the authored URL/label.
//   * `spokenText` is the ONLY text a speech provider may receive.
//   * `spans` map every URL replacement back to its source UTF-16 range and
//     forward to its spoken UTF-16 range, so UI/progress code can keep the
//     display body while audio follows the spoken projection.
//
// Cloud voices receive the full final prose, including the literal URL. Local
// voices default to keeping a Markdown label and skipping the URL; when the
// user turns "Read links" on, the whole URL is pronounced component by
// component (scheme, host, port, path, query, fragment and a final slash).
// The pronunciation is a text projection only: no source letter, digit, case
// or order is changed outside the URL replacement itself.

import Foundation

public enum SpeechLinkLanguage: String, Sendable, Equatable, Hashable {
    case chinese
    case english
}

/// Where the spoken text is going. Cloud routes receive the authored prose,
/// including URLs. Local routes use the user's Read-links preference.
public enum SpeechTextDestination: Sendable, Equatable, Hashable {
    case cloud
    case local(readLinks: Bool, language: SpeechLinkLanguage)

    public var includesURLs: Bool {
        switch self {
        case .cloud: return true
        case .local(let readLinks, _): return readLinks
        }
    }
}

/// One token of a URL pronunciation. `sourceUTF16Start/Length` identify the
/// exact authored characters and `spokenUTF16Start/Length` the replacement in
/// `SpeechURLPronunciation.spoken`. Every source character belongs to exactly
/// one unit; units preserve order.
public struct SpeechURLUnit: Sendable, Equatable, Hashable {
    public let sourceUTF16Start: Int
    public let sourceUTF16Length: Int
    public let spokenUTF16Start: Int
    public let spokenUTF16Length: Int
    public let text: String

    public init(
        sourceUTF16Start: Int,
        sourceUTF16Length: Int,
        spokenUTF16Start: Int,
        spokenUTF16Length: Int,
        text: String
    ) {
        self.sourceUTF16Start = sourceUTF16Start
        self.sourceUTF16Length = sourceUTF16Length
        self.spokenUTF16Start = spokenUTF16Start
        self.spokenUTF16Length = spokenUTF16Length
        self.text = text
    }
}

public struct SpeechURLPronunciation: Sendable, Equatable, Hashable {
    public let url: String
    public let spoken: String
    public let units: [SpeechURLUnit]

    public init(url: String, spoken: String, units: [SpeechURLUnit]) {
        self.url = url
        self.spoken = spoken
        self.units = units
    }
}

/// One URL replacement with both coordinate systems. Removed URLs (local
/// Read-links off) keep a zero-length spoken span at the insertion point.
public struct SpeechTextSpan: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Equatable, Hashable {
        case url
        case removedURL
    }

    public let kind: Kind
    public let url: String
    public let sourceUTF16Start: Int
    public let sourceUTF16Length: Int
    public let spokenUTF16Start: Int
    public let spokenUTF16Length: Int

    public init(
        kind: Kind,
        url: String,
        sourceUTF16Start: Int,
        sourceUTF16Length: Int,
        spokenUTF16Start: Int,
        spokenUTF16Length: Int
    ) {
        self.kind = kind
        self.url = url
        self.sourceUTF16Start = sourceUTF16Start
        self.sourceUTF16Length = sourceUTF16Length
        self.spokenUTF16Start = spokenUTF16Start
        self.spokenUTF16Length = spokenUTF16Length
    }
}

public struct SpeechTextProjection: Sendable, Equatable {
    public let sourceText: String
    public let spokenText: String
    public let spans: [SpeechTextSpan]
    public let urls: [SpeechURLPronunciation]

    public init(
        sourceText: String,
        spokenText: String,
        spans: [SpeechTextSpan],
        urls: [SpeechURLPronunciation]
    ) {
        self.sourceText = sourceText
        self.spokenText = spokenText
        self.spans = spans
        self.urls = urls
    }

    /// Source range of one URL, if present. Both offsets are UTF-16 units.
    public func sourceRange(forURLIndex index: Int) -> Range<Int>? {
        guard spans.indices.contains(index) else { return nil }
        let span = spans[index]
        return span.sourceUTF16Start..<(span.sourceUTF16Start + span.sourceUTF16Length)
    }
}

public enum SpeechAnswerProjection {
    /// Projects already-cleaned Markdown/final prose. Fenced code, tables,
    /// images and block markers are the caller's responsibility; this function
    /// owns inline emphasis cleanup, Markdown links, bare URLs/autolinks and
    /// the destination-specific spoken form.
    public static func project(
        _ text: String,
        destination: SpeechTextDestination
    ) -> SpeechTextProjection {
        let tokens = URLTokenScanner.tokens(in: text)
        var output = ""
        var spans: [SpeechTextSpan] = []
        var pronunciations: [SpeechURLPronunciation] = []
        var cursor = text.startIndex

        for token in tokens {
            guard token.fullRange.lowerBound >= cursor else { continue }
            output += inlineClean(String(text[cursor..<token.fullRange.lowerBound]))
            let literalBeforeURL = output.utf16.count
            let label = token.label.map(inlineClean)
            let pronunciation = SpeechURLPronouncer.pronounce(
                token.url, language: destination.linkLanguage)
            pronunciations.append(pronunciation)

            let replacement: String
            let urlSpokenOffset: Int
            switch destination {
            case .cloud:
                let rawURL = token.url
                if let label, !label.isEmpty {
                    replacement = label + " " + rawURL
                    urlSpokenOffset = label.utf16.count + 1
                } else {
                    replacement = rawURL
                    urlSpokenOffset = 0
                }
            case .local(let readLinks, _):
                if readLinks {
                    if let label, !label.isEmpty {
                        replacement = label + " " + pronunciation.spoken
                        urlSpokenOffset = label.utf16.count + 1
                    } else {
                        replacement = pronunciation.spoken
                        urlSpokenOffset = 0
                    }
                } else {
                    let keptLabel = label ?? ""
                    replacement = keptLabel
                    urlSpokenOffset = keptLabel.utf16.count
                }
            }
            output += replacement
            let spokenLength = destination.includesURLs
                ? (destination == .cloud ? token.url.utf16.count : pronunciation.spoken.utf16.count)
                : 0
            spans.append(SpeechTextSpan(
                kind: spokenLength > 0 ? .url : .removedURL,
                url: token.url,
                sourceUTF16Start: token.urlUTF16Start,
                sourceUTF16Length: token.url.utf16.count,
                spokenUTF16Start: literalBeforeURL + urlSpokenOffset,
                spokenUTF16Length: spokenLength))
            cursor = token.fullRange.upperBound
        }
        output += inlineClean(String(text[cursor...]))

        // Derive the removed leading run explicitly so spans shift by exactly
        // the prefix that trimming removed (not by the combined tail length).
        var leading = 0
        for character in output {
            guard character.isWhitespace else { break }
            leading += String(character).utf16.count
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let adjusted: [SpeechTextSpan] = spans.map { span in
            let start = max(0, span.spokenUTF16Start - leading)
            let end = min(trimmed.utf16.count, max(start,
                span.spokenUTF16Start + span.spokenUTF16Length - leading))
            return SpeechTextSpan(
                kind: span.kind,
                url: span.url,
                sourceUTF16Start: span.sourceUTF16Start,
                sourceUTF16Length: span.sourceUTF16Length,
                spokenUTF16Start: start,
                spokenUTF16Length: end - start)
        }
        return SpeechTextProjection(
            sourceText: text,
            spokenText: trimmed,
            spans: adjusted,
            urls: pronunciations)
    }

    /// Inline emphasis/code markers are display syntax, never speech content.
    /// Removed only from literal prose and link labels; URL bytes are handled
    /// by `URLTokenScanner` before this runs.
    static func inlineClean(_ value: String) -> String {
        value.replacingOccurrences(of: "[*_`~]", with: "", options: .regularExpression)
    }
}

extension SpeechTextDestination {
    var linkLanguage: SpeechLinkLanguage {
        switch self {
        case .cloud:
            return .english
        case .local(_ , let language):
            return language
        }
    }
}

// MARK: - URL detection

private enum URLTokenScanner {
    struct Token {
        let fullRange: Range<String.Index>
        let url: String
        let urlUTF16Start: Int
        let label: String?
    }

    private static let linkPattern = try! NSRegularExpression(
        pattern: #"\[([^\]\n]{0,2000})\]\(([^\s)]{1,4096})\)"#)

    static func tokens(in text: String) -> [Token] {
        let links = linkTokens(in: text)
        var tokens = links
        var cursor = text.startIndex
        for link in links {
            if cursor < link.fullRange.lowerBound {
                tokens.append(contentsOf: bareTokens(
                    in: text, range: cursor..<link.fullRange.lowerBound))
            }
            cursor = max(cursor, link.fullRange.upperBound)
        }
        if cursor < text.endIndex {
            tokens.append(contentsOf: bareTokens(in: text, range: cursor..<text.endIndex))
        }
        return tokens.sorted { $0.fullRange.lowerBound < $1.fullRange.lowerBound }
    }

    private static func linkTokens(in text: String) -> [Token] {
        let ns = text as NSString
        let matches = linkPattern.matches(
            in: text, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match in
            guard match.numberOfRanges == 3,
                  let full = Range(match.range(at: 0), in: text),
                  let labelRange = Range(match.range(at: 1), in: text),
                  let urlRange = Range(match.range(at: 2), in: text) else { return nil }
            var rawURL = String(text[urlRange])
            var rawURLStart = urlRange.lowerBound
            if rawURL.hasPrefix("<"), rawURL.hasSuffix(">"), rawURL.utf16.count >= 2 {
                rawURL.removeFirst()
                rawURL.removeLast()
                rawURLStart = text.index(after: rawURLStart)
            }
            return Token(
                fullRange: full,
                url: rawURL,
                urlUTF16Start: text[..<rawURLStart].utf16.count,
                label: String(text[labelRange]))
        }
    }

    private static func bareTokens(
        in text: String,
        range: Range<String.Index>
    ) -> [Token] {
        var result: [Token] = []
        var search = range.lowerBound
        while search < range.upperBound,
              let http = text.range(
                of: "http", options: [.caseInsensitive],
                range: search..<range.upperBound) {
            guard let schemeEnd = text.range(
                of: "://", options: [], range: http.lowerBound..<range.upperBound),
                text[http.lowerBound..<schemeEnd.lowerBound].lowercased() == "http"
                    || text[http.lowerBound..<schemeEnd.lowerBound].lowercased() == "https" else {
                search = text.index(after: http.lowerBound)
                continue
            }
            if http.lowerBound > range.lowerBound {
                let previous = text[text.index(before: http.lowerBound)]
                if previous.isLetter || previous.isNumber {
                    search = text.index(after: http.lowerBound)
                    continue
                }
            }
            var urlEnd = schemeEnd.upperBound
            while urlEnd < range.upperBound, !isURLTerminator(text[urlEnd]) {
                urlEnd = text.index(after: urlEnd)
            }
            var trimmedEnd = urlEnd
            while trimmedEnd > schemeEnd.upperBound,
                  isTrailingPunctuation(text[text.index(before: trimmedEnd)]) {
                trimmedEnd = text.index(before: trimmedEnd)
            }
            guard trimmedEnd > schemeEnd.upperBound else {
                search = urlEnd
                continue
            }
            var fullStart = http.lowerBound
            var fullEnd = trimmedEnd
            var angleWrapped = false
            if fullStart > range.lowerBound,
               text[text.index(before: fullStart)] == "<",
               fullEnd < range.upperBound,
               text[fullEnd] == ">" {
                fullStart = text.index(before: fullStart)
                fullEnd = text.index(after: fullEnd)
                angleWrapped = true
            }
            _ = angleWrapped
            let urlRange = http.lowerBound..<trimmedEnd
            let url = String(text[urlRange])
            result.append(Token(
                fullRange: fullStart..<fullEnd,
                url: url,
                urlUTF16Start: text[..<urlRange.lowerBound].utf16.count,
                label: nil))
            search = max(urlEnd, fullEnd)
        }
        return result
    }

    private static func isURLTerminator(_ character: Character) -> Bool {
        if character.isWhitespace { return true }
        switch character {
        case "<", ">", "(", ")", "[", "]", "\"", "'",
             "，", "。", "；", "：", "！", "？", "、", "“", "”", "‘", "’":
            return true
        default:
            return false
        }
    }

    private static func isTrailingPunctuation(_ character: Character) -> Bool {
        switch character {
        case ".", ",", ";", ":", "!", "?", "，", "。", "；", "：", "！", "？", "、":
            return true
        default:
            return false
        }
    }
}

// MARK: - URL pronunciation

public enum SpeechURLPronouncer {
    private static let englishLetters: [Character: String] = [
        "a": "ay", "b": "bee", "c": "cee", "d": "dee", "e": "ee",
        "f": "eff", "g": "gee", "h": "aitch", "i": "eye", "j": "jay",
        "k": "kay", "l": "ell", "m": "em", "n": "en", "o": "oh",
        "p": "pee", "q": "cue", "r": "ar", "s": "ess", "t": "tee",
        "u": "you", "v": "vee", "w": "double you", "x": "ex", "y": "why",
        "z": "zee",
    ]
    /// Conservative Chinese letter names. This is a pronunciation
    /// projection, not an acoustic-completeness claim.
    private static let chineseLetters: [Character: String] = [
        "a": "诶", "b": "必", "c": "西", "d": "迪", "e": "伊",
        "f": "艾弗", "g": "吉", "h": "诶尺", "i": "艾", "j": "杰",
        "k": "开", "l": "艾勒", "m": "艾姆", "n": "艾恩", "o": "哦",
        "p": "屁", "q": "丘", "r": "啊", "s": "艾丝", "t": "提",
        "u": "优", "v": "维", "w": "达不溜", "x": "艾克斯", "y": "歪",
        "z": "贼",
    ]
    private static let englishDigits: [Character: String] = [
        "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
        "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine",
    ]
    private static let chineseDigits: [Character: String] = [
        "0": "零", "1": "一", "2": "二", "3": "三", "4": "四",
        "5": "五", "6": "六", "7": "七", "8": "八", "9": "九",
    ]

    public static func pronounce(
        _ url: String,
        language: SpeechLinkLanguage
    ) -> SpeechURLPronunciation {
        let characters = Array(url)
        var units: [SpeechURLUnit] = []
        var spokenOffset = 0
        var sourceOffset = 0
        var index = 0

        while index < characters.count {
            let start = index
            let startSource = sourceOffset
            if characters[index].isASCII,
               characters[index].isLetter || characters[index].isNumber {
                var names: [String] = []
                while index < characters.count,
                      characters[index].isASCII,
                      characters[index].isLetter || characters[index].isNumber {
                    names.append(name(of: characters[index], language: language))
                    sourceOffset += String(characters[index]).utf16.count
                    index += 1
                }
                let token = names.joined(separator: " ")
                units.append(SpeechURLUnit(
                    sourceUTF16Start: startSource,
                    sourceUTF16Length: sourceOffset - startSource,
                    spokenUTF16Start: spokenOffset,
                    spokenUTF16Length: token.utf16.count,
                    text: token))
                spokenOffset += token.utf16.count + 1
                continue
            }

            let token = symbolName(characters[index], language: language)
                ?? String(characters[index])
            sourceOffset += String(characters[index]).utf16.count
            index += 1
            units.append(SpeechURLUnit(
                sourceUTF16Start: startSource,
                sourceUTF16Length: sourceOffset - startSource,
                spokenUTF16Start: spokenOffset,
                spokenUTF16Length: token.utf16.count,
                text: token))
            spokenOffset += token.utf16.count + 1
            _ = start
        }
        let spoken = units.map(\.text).joined(separator: " ")
        return SpeechURLPronunciation(url: url, spoken: spoken, units: units)
    }

    private static func name(of character: Character, language: SpeechLinkLanguage) -> String {
        let key = Character(String(character).lowercased())
        switch language {
        case .english:
            if let letter = englishLetters[key] { return letter }
            return englishDigits[key] ?? String(character)
        case .chinese:
            if let letter = chineseLetters[key] { return letter }
            return chineseDigits[key] ?? String(character)
        }
    }

    private static func symbolName(
        _ character: Character,
        language: SpeechLinkLanguage
    ) -> String? {
        switch language {
        case .english:
            switch character {
            case ":": return "colon"
            case "/": return "slash"
            case ".": return "dot"
            case "-": return "hyphen"
            case "_": return "underscore"
            case "?": return "question mark"
            case "&": return "and"
            case "=": return "equals"
            case "%": return "percent"
            case "#": return "hash"
            case "@": return "at"
            case "~": return "tilde"
            case "+": return "plus"
            case ";": return "semicolon"
            case ",": return "comma"
            case "!": return "exclamation mark"
            case "*": return "asterisk"
            case "'": return "apostrophe"
            case "(": return "left parenthesis"
            case ")": return "right parenthesis"
            case "[": return "left bracket"
            case "]": return "right bracket"
            default: return nil
            }
        case .chinese:
            switch character {
            case ":": return "冒号"
            case "/": return "斜杠"
            case ".": return "点"
            case "-": return "连字符"
            case "_": return "下划线"
            case "?": return "问号"
            case "&": return "和"
            case "=": return "等于"
            case "%": return "百分号"
            case "#": return "井号"
            case "@": return "艾特"
            case "~": return "波浪号"
            case "+": return "加号"
            case ";": return "分号"
            case ",": return "逗号"
            case "!": return "感叹号"
            case "*": return "星号"
            case "'": return "撇号"
            case "(": return "左括号"
            case ")": return "右括号"
            case "[": return "左方括号"
            case "]": return "右方括号"
            default: return nil
            }
        }
    }
}
