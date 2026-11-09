// SPDX-License-Identifier: MPL-2.0
import Foundation

/// UTF-16 positions belong to the editor. The canonical source is never
/// replaced with the display marker and remains the sole save/undo input.
public struct LaTeXFoldRegion: Sendable, Equatable {
    public var header: NSRange
    public var body: NSRange
    public var lineCount: Int
    public var id: Int { header.location }
}

public struct LaTeXSourceProjection: Sendable {
    public struct Hidden: Sendable { public var source: NSRange; public var display: NSRange }
    public let source: String
    public let text: String
    public let hidden: [Hidden]
    public init(source: String, regions: [LaTeXFoldRegion], chinese: Bool) {
        self.source = source
        let input = source as NSString
        var result = "", cursor = 0, displayCount = 0, values = [Hidden]()
        for region in regions.sorted(by: { $0.body.location == $1.body.location ? $0.body.length > $1.body.length : $0.body.location < $1.body.location }) {
            let range = region.body
            guard range.location >= cursor, range.length > 0, NSMaxRange(range) <= input.length else { continue }
            result += input.substring(with: NSRange(location: cursor, length: range.location - cursor))
            displayCount += range.location - cursor
            let marker = chinese ? "⋯ \(region.lineCount) 行已折叠\n" : "⋯ \(region.lineCount) folded lines\n"
            values.append(.init(source: range, display: NSRange(location: displayCount, length: marker.utf16.count)))
            result += marker; displayCount += marker.utf16.count; cursor = NSMaxRange(range)
        }
        result += input.substring(from: cursor)
        text = result; hidden = values
    }
    public func touchesMarker(_ range: NSRange) -> Bool {
        let range = boundedFoldRange(range, limit: text.utf16.count)
        return hidden.contains { item in
            range.length == 0 ? (range.location >= item.display.location && range.location < NSMaxRange(item.display)) : NSIntersectionRange(range, item.display).length > 0
        }
    }
    public func sourceRange(_ range: NSRange) -> NSRange {
        let range = boundedFoldRange(range, limit: text.utf16.count)
        let lower = sourceOffset(range.location, upper: false)
        if range.length == 0 { return NSRange(location: lower, length: 0) }
        let upper = sourceOffset(NSMaxRange(range), upper: true)
        return NSRange(location: lower, length: max(0, upper - lower))
    }
    public func displayRange(_ range: NSRange) -> NSRange {
        let range = boundedFoldRange(range, limit: source.utf16.count)
        let lower = displayOffset(range.location)
        return NSRange(location: lower, length: max(0, displayOffset(NSMaxRange(range)) - lower))
    }
    private func sourceOffset(_ offset: Int, upper: Bool) -> Int {
        let point = min(max(0, offset), text.utf16.count)
        var delta = 0
        for item in hidden {
            if point < item.display.location { break }
            if point < NSMaxRange(item.display) { return upper ? NSMaxRange(item.source) : item.source.location }
            delta += item.source.length - item.display.length
        }
        return min(source.utf16.count, point + delta)
    }
    private func displayOffset(_ offset: Int) -> Int {
        let point = min(max(0, offset), source.utf16.count)
        var delta = 0
        for item in hidden {
            if point < item.source.location { break }
            if point < NSMaxRange(item.source) { return item.display.location }
            delta += item.source.length - item.display.length
        }
        return min(text.utf16.count, point - delta)
    }
}

public struct LaTeXSourceFolding: Sendable {
    public enum Command: Sendable { case toggleCurrent, collapseAll, expandAll }
    public enum EditError: Error { case displayMarkerChanged }
    public private(set) var source: String
    public private(set) var folded = [LaTeXFoldRegion]()
    public var chinese: Bool
    public init(source: String, chinese: Bool = false) { self.source = source; self.chinese = chinese }
    public var projection: LaTeXSourceProjection { .init(source: source, regions: folded, chinese: chinese) }
    public mutating func reset(_ source: String) { self.source = source; folded = [] }
    public mutating func perform(_ command: Command, selection: NSRange) -> NSRange {
        let selection = boundedFoldRange(selection, limit: source.utf16.count)
        switch command {
        case .expandAll: folded = []
        case .collapseAll: folded = Self.regions(in: source)
        case .toggleCurrent:
            let point = min(selection.location, source.utf16.count)
            if let region = Self.regions(in: source).filter({ point >= $0.header.location && point <= NSMaxRange($0.body) }).min(by: { NSMaxRange($0.body) - $0.header.location < NSMaxRange($1.body) - $1.header.location }) {
                if folded.contains(where: { $0.id == region.id }) { folded.removeAll { $0.id == region.id } }
                else { folded.append(region) }
            }
        }
        // Keep the caret on a visible heading rather than inside a marker.
        if let region = folded.sorted(by: { $0.body.location < $1.body.location }).first(where: { selection.location >= $0.body.location && selection.location < NSMaxRange($0.body) }) {
            return NSRange(location: region.header.location, length: 0)
        }
        return selection
    }
    public mutating func reveal(_ selection: NSRange) {
        let selection = boundedFoldRange(selection, limit: source.utf16.count)
        folded.removeAll { region in
            selection.length == 0 ? (selection.location >= region.body.location && selection.location < NSMaxRange(region.body)) : NSIntersectionRange(selection, region.body).length > 0
        }
    }
    /// Called only after IME composition commits. A diff is computed in
    /// Unicode scalars, so emoji/surrogates cannot split a canonical edit.
    public mutating func accept(displayText: String, selection: NSRange) throws -> NSRange {
        let before = projection
        let old = Array(before.text.unicodeScalars), new = Array(displayText.unicodeScalars)
        var prefix = 0, suffix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        while suffix < min(old.count - prefix, new.count - prefix), old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        func width(_ values: ArraySlice<Unicode.Scalar>) -> Int { values.reduce(0) { $0 + ($1.value > 0xFFFF ? 2 : 1) } }
        let displayEdit = NSRange(location: width(old[0..<prefix]), length: width(old[prefix..<(old.count - suffix)]))
        guard !before.touchesMarker(displayEdit) else { throw EditError.displayMarkerChanged }
        let replacement = String(String.UnicodeScalarView(new[prefix..<(new.count - suffix)]))
        let edit = before.sourceRange(displayEdit)
        let removed = (source as NSString).substring(with: edit)
        source = (source as NSString).replacingCharacters(in: edit, with: replacement)
        let delta = replacement.utf16.count - edit.length
        for index in folded.indices {
            if folded[index].body.location >= NSMaxRange(edit) { folded[index].body.location += delta }
            if folded[index].header.location >= NSMaxRange(edit) { folded[index].header.location += delta }
        }
        let canonicalSelection = projection.sourceRange(selection)
        // Structural changes invalidate inferred boundaries. Reveal rather
        // than hide an incorrectly reinterpreted environment or comment.
        if (replacement + removed).contains(where: { "\\{}%\n\r".contains($0) }) { folded = [] }
        return canonicalSelection
    }
    public static func regions(in source: String) -> [LaTeXFoldRegion] {
        guard source.utf16.count <= 300_000 else { return [] }
        let structure = LaTeXParser.parse(source), bytes = Array(source.utf8), text = source as NSString
        // One linear index converts parser byte positions into UIKit offsets.
        var offsets = [Int: Int](), byte = 0, utf16 = 0
        offsets[0] = 0
        for scalar in source.unicodeScalars {
            byte += scalar.utf8.count; utf16 += scalar.value > 0xFFFF ? 2 : 1; offsets[byte] = utf16
        }
        func region(_ headerStart: Int, _ openingEnd: Int, _ closingStart: Int) -> LaTeXFoldRegion? {
            guard let start = offsets[headerStart], let opening = offsets[openingEnd], let closing = offsets[closingStart], opening < closing else { return nil }
            let first = NSMaxRange(text.lineRange(for: NSRange(location: opening, length: 0)))
            let last = closing == text.length ? closing : text.lineRange(for: NSRange(location: closing, length: 0)).location
            guard first < last else { return nil }
            let body = NSRange(location: first, length: last - first)
            let units = Array(text.substring(with: body).utf16)
            let count = units.indices.reduce(0) { count, index in
                count + ((units[index] == 10 || (units[index] == 13 && (index + 1 == units.count || units[index + 1] != 10))) ? 1 : 0)
            }
            guard count > 0 else { return nil }
            return .init(header: NSRange(location: start, length: NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0))) - start), body: body, lineCount: count)
        }
        var result = [LaTeXFoldRegion](), stack = [(String, LaTeXCommand)]()
        for command in structure.commands {
            if command.name == "begin", let name = command.arguments.first?.value { stack.append((name, command)) }
            else if command.name == "end", let name = command.arguments.first?.value, let open = stack.last, open.0 == name {
                stack.removeLast()
                if name != "document", let value = region(open.1.range.start, open.1.range.end, command.range.start) { result.append(value) }
            }
        }
        let ranks = ["part": 0, "chapter": 1, "section": 2, "subsection": 3, "subsubsection": 4, "paragraph": 5, "subparagraph": 6]
        let headings = structure.blocks.filter { $0.kind == .heading && ranks[$0.name] != nil }
        var headingStack = [LaTeXBlock]()
        for heading in headings {
            while let previous = headingStack.last, ranks[previous.name]! >= ranks[heading.name]! {
                headingStack.removeLast()
                if let value = region(previous.range.start, previous.range.end, heading.range.start) { result.append(value) }
            }
            headingStack.append(heading)
        }
        for heading in headingStack {
            let end = min(bytes.count, structure.bodyRange.end)
            if let value = region(heading.range.start, heading.range.end, end) { result.append(value) }
        }
        return result.sorted { $0.header.location == $1.header.location ? $0.body.length > $1.body.length : $0.header.location < $1.header.location }
    }
}

private func boundedFoldRange(_ range: NSRange, limit: Int) -> NSRange {
    let location = min(max(0, range.location), limit)
    return NSRange(location: location, length: min(max(0, range.length), limit - location))
}
