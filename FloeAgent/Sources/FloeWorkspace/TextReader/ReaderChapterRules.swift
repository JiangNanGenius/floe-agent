// FloeWorkspace — Deterministic chapter/heading rules for the text reader.
//
// SPDX-License-Identifier: MPL-2.0
//
// Contents navigation must be explainable: every heading is derived from the
// document text by a fixed rule. No model call, no network request and no
// heuristic scoring is involved. When a line is ambiguous it stays body text.

import Foundation

public enum ReaderChapterRules {

    public struct Candidate: Sendable, Equatable {
        public var title: String
        public var level: Int
        public init(title: String, level: Int) {
            self.title = title
            self.level = level
        }
    }

    /// Full-width and ASCII separators that may follow a chapter marker.
    private static let separators: Set<Character> = [
        " ", "\t", "\u{3000}", ":", "：", "、", ".", "．", "-", "—", "·", "|", "/"
    ]

    /// Sentence punctuation: a candidate that reads like prose is not a
    /// heading.
    private static let sentencePunctuation: Set<Character> = [
        "。", "！", "？", "；", "，", "…", "!", "?", ";", ",", "\n", "\"", "“", "”", "'"
    ]

    private static let cjkNumerals: Set<Character> = Set("0123456789０１２３４５６７８９零一二三四五六七八九十百千万两〇")

    private static let volumeMarkers: Set<Character> = Set("卷篇部集")
    private static let chapterMarkers: Set<Character> = Set("章回话")
    private static let sectionMarkers: Set<Character> = Set("节")

    /// Full-line special headings (序章, 楔子, 番外, …).
    private static let specialHeadings: [String] = [
        "序章", "序言", "序幕", "楔子", "引子", "前言", "后记", "尾声", "终章",
        "结局", "大结局", "番外", "外传", "附录", "作者的话", "正文", "上卷", "下卷"
    ]

    private static let englishHeadings: [String] = [
        "prologue", "epilogue", "foreword", "afterword", "interlude", "preface",
        "introduction", "conclusion"
    ]

    /// Classifies one decoded line (without its line break) as a heading.
    ///
    /// Exactly one rule must match the whole trimmed line:
    /// - Markdown ATX (`#`…`######` followed by a space);
    /// - `第<number><marker>` (章/卷/回/节/篇/部/集/话) with an optional
    ///   separator + title, or a very short title without punctuation;
    /// - a full-line special heading (序章/楔子/番外/…);
    /// - `Chapter <n>` / `Part <n>` / a standalone English section word.
    public static func heading(forLine line: String, maxCharacters: Int) -> Candidate? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= maxCharacters else { return nil }
        if let markdown = markdownHeading(trimmed) { return markdown }
        if let numbered = numberedCJKHeading(trimmed) { return numbered }
        if let special = specialHeading(trimmed) { return special }
        if let english = englishSectionHeading(trimmed) { return english }
        return nil
    }

    // MARK: - Markdown

    private static func markdownHeading(_ line: String) -> Candidate? {
        var hashes = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", hashes < 7 {
            hashes += 1
            index = line.index(after: index)
        }
        guard (1...6).contains(hashes) else { return nil }
        guard index < line.endIndex, line[index] == " " || line[index] == "\t" else { return nil }
        let title = line[index...].trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        // A closing run of hashes is decorative and removed.
        var body = title
        while body.hasSuffix("#") { body.removeLast() }
        body = body.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        return Candidate(title: body, level: hashes)
    }

    /// Setext underline (`===` level 1, `---` level 2). The caller applies it
    /// only to the immediately preceding single-line paragraph.
    public static func setextLevel(forLine line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    // MARK: - 第N章 / 第N节 / …

    private static func numberedCJKHeading(_ line: String) -> Candidate? {
        var index = line.startIndex
        guard index < line.endIndex, line[index] == "第" else { return nil }
        index = line.index(after: index)
        var numberCount = 0
        while index < line.endIndex, cjkNumerals.contains(line[index]) {
            numberCount += 1
            index = line.index(after: index)
        }
        guard (1...12).contains(numberCount), index < line.endIndex else { return nil }
        let marker = line[index]
        let level: Int
        if volumeMarkers.contains(marker) { level = 1 }
        else if chapterMarkers.contains(marker) { level = 1 }
        else if sectionMarkers.contains(marker) { level = 2 }
        else { return nil }
        index = line.index(after: index)
        let remainder = line[index...].trimmingCharacters(in: .whitespaces)
        if remainder.isEmpty { return Candidate(title: line, level: level) }
        if let first = remainder.first, separators.contains(first) {
            return Candidate(title: line, level: level)
        }
        // Without a separator only a very short, punctuation-free run is a
        // title; anything longer reads like prose ("第二章的内容主要讲了…").
        guard remainder.count <= 12,
              !remainder.contains(where: { sentencePunctuation.contains($0) }) else { return nil }
        return Candidate(title: line, level: level)
    }

    // MARK: - 序章 / 楔子 / 番外 …

    private static func specialHeading(_ line: String) -> Candidate? {
        for token in specialHeadings where line.hasPrefix(token) {
            let remainder = line.dropFirst(token.count).trimmingCharacters(in: .whitespaces)
            if remainder.isEmpty { return Candidate(title: line, level: 1) }
            if let first = remainder.first, separators.contains(first) {
                return Candidate(title: line, level: 1)
            }
            if remainder.count <= 20,
               !remainder.contains(where: { sentencePunctuation.contains($0) }) {
                return Candidate(title: line, level: 1)
            }
            return nil
        }
        return nil
    }

    // MARK: - English sections

    private static func englishSectionHeading(_ line: String) -> Candidate? {
        let lowered = line.lowercased()
        for keyword in ["chapter", "part", "book", "volume"] where lowered.hasPrefix(keyword) {
            let remainder = line.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
            guard !remainder.isEmpty else { return nil }
            // A number (arabic or roman, ≤ 12 characters) must follow.
            var number = ""
            var rest = remainder[...]
            while let first = rest.first, first.isLetter || first.isNumber {
                number.append(first)
                rest = rest.dropFirst()
                if number.count > 12 { return nil }
            }
            guard !number.isEmpty else { return nil }
            let tail = rest.trimmingCharacters(in: .whitespaces)
            if tail.isEmpty { return Candidate(title: line, level: 1) }
            if let first = tail.first, separators.contains(first) {
                return Candidate(title: line, level: 1)
            }
            if tail.count <= 40, !tail.contains(where: { sentencePunctuation.contains($0) }) {
                return Candidate(title: line, level: 1)
            }
            return nil
        }
        for keyword in englishHeadings where lowered.hasPrefix(keyword) {
            let remainder = line.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
            if remainder.isEmpty { return Candidate(title: line, level: 1) }
            if let first = remainder.first, separators.contains(first) {
                return Candidate(title: line, level: 1)
            }
            return nil
        }
        return nil
    }
}
