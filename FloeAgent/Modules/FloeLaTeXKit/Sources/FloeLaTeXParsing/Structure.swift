// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXCore

public struct LaTeXArgument: Codable, Sendable, Hashable {
    public var range: LaTeXSourceRange
    public var contentRange: LaTeXSourceRange
    public var value: String
    public var optional: Bool
}
public struct LaTeXCommand: Codable, Sendable, Identifiable {
    public var id: Int { range.start }
    public var name: String
    public var range: LaTeXSourceRange
    public var arguments: [LaTeXArgument]
    public var starred: Bool
}
public struct LaTeXBlock: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case heading, paragraph, formula, figure, table, list, code, environment }
    public var id: Int { range.start }
    public var kind: Kind
    public var name: String
    public var range: LaTeXSourceRange
    public var contentRange: LaTeXSourceRange
    public var content: String
}
public struct LaTeXSourceDiagnostic: Codable, Sendable, Equatable {
    public enum Severity: String, Codable, Sendable { case warning, error }
    public var message: String
    public var range: LaTeXSourceRange
    public var severity: Severity
}
public struct LaTeXStructure: Sendable {
    public var source: String
    public var bodyRange: LaTeXSourceRange
    public var commands: [LaTeXCommand]
    public var blocks: [LaTeXBlock]
    public var labels: [String]
    public var references: [String]
    public var citations: [String]
    public var includes: [String]
    public var packages: [String]
    public var diagnostics: [LaTeXSourceDiagnostic]
    public func original(_ range: LaTeXSourceRange) -> String {
        let bytes = Array(source.utf8)
        guard range.start >= 0, range.length >= 0, range.start <= bytes.count, range.length <= bytes.count-range.start else { return "" }
        return String(decoding: bytes[range.start..<range.end], as: UTF8.self)
    }
}

/// A lossless source index. It deliberately leaves macro expansion to TeX.
public enum LaTeXParser {
    public static func parse(_ source: String) -> LaTeXStructure {
        var scanner = Scanner(bytes: Array(source.utf8))
        return scanner.parse(source)
    }
    public static func escapeText(_ text: String) -> String {
        text.map { c in
            switch c {
            case "\\": "\\textbackslash{}"
            case "{": "\\{"; case "}": "\\}"
            case "$": "\\$"; case "&": "\\&"; case "%": "\\%"; case "#": "\\#"; case "_": "\\_"
            case "~": "\\textasciitilde{}"; case "^": "\\textasciicircum{}"
            default: String(c)
            }
        }.joined()
    }

    private struct Scanner {
        let bytes: [UInt8]
        var commands: [LaTeXCommand] = []
        var diagnostics: [LaTeXSourceDiagnostic] = []
        func slice(_ a: Int, _ b: Int) -> String { String(decoding: bytes[a..<b], as: UTF8.self) }
        func letter(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) || b == 64 }
        func space(_ b: UInt8) -> Bool { [9,10,13,32].contains(b) }
        func skip(_ start: Int) -> Int {
            var i = start
            while i < bytes.count {
                if space(bytes[i]) { i += 1 }
                else if bytes[i] == 37 { while i < bytes.count && bytes[i] != 10 { i += 1 } }
                else { break }
            }
            return i
        }
        mutating func argument(_ start: Int, optional: Bool) -> LaTeXArgument? {
            let i = skip(start), open: UInt8 = optional ? 91 : 123, close: UInt8 = optional ? 93 : 125
            guard i < bytes.count, bytes[i] == open else { return nil }
            var j = i+1, depth = 1
            while j < bytes.count {
                if bytes[j] == 92 { j = min(j+2,bytes.count); continue }
                if bytes[j] == 37 { while j < bytes.count && bytes[j] != 10 { j += 1 }; continue }
                if bytes[j] == open { depth += 1 }
                if bytes[j] == close { depth -= 1; if depth == 0 { return .init(range: .init(start:i,length:j-i+1),contentRange:.init(start:i+1,length:j-i-1),value:slice(i+1,j),optional:optional) } }
                j += 1
            }
            diagnostics.append(.init(message:"Unclosed argument",range:.init(start:i,length:bytes.count-i),severity:.error))
            return nil
        }
        mutating func command(_ start: Int) -> LaTeXCommand? {
            guard start+1 < bytes.count else { return nil }
            var end = start+1
            if letter(bytes[end]) { while end < bytes.count && (letter(bytes[end]) || bytes[end] == 58 || bytes[end] == 95) { end += 1 } }
            else { end += 1 }
            let name = slice(start+1,end)
            let starred = end < bytes.count && bytes[end] == 42
            if starred { end += 1 }
            var cursor = end, args = [LaTeXArgument]()
            if ["maketitle","tableofcontents","listoffigures","listoftables","newpage","clearpage","printbibliography"].contains(name) {
                if name=="printbibliography",let arg=argument(cursor,optional:true) {args.append(arg);cursor=arg.range.end}
                return .init(name:name,range:.init(start:start,length:cursor-start),arguments:args,starred:starred)
            }
            if name == "item" {
                if let arg=argument(cursor,optional:true) {args.append(arg);cursor=arg.range.end}
                return .init(name:name,range:.init(start:start,length:cursor-start),arguments:args,starred:starred)
            }
            let single: Set<String> = ["begin","end","label","ref","eqref","pageref","autoref","cref","Cref","cite","citep","citet","parencite","textcite","autocite","footcite","includegraphics","input","include","bibliography","bibliographystyle","addbibresource","usepackage","RequirePackage","documentclass","part","chapter","section","subsection","subsubsection","paragraph","subparagraph","title","author","date"]
            let required = single.contains(name) ? 1 : (["href","newcommand","renewcommand","providecommand","DeclareRobustCommand"].contains(name) ? 2 : 4)
            var mandatory = 0
            // Index syntax without assuming that an unknown macro's body is prose.
            for _ in 0..<6 {
                if mandatory >= required { break }
                if let arg = argument(cursor, optional:true) { args.append(arg); cursor = arg.range.end }
                else if let arg = argument(cursor, optional:false) { args.append(arg); cursor = arg.range.end; mandatory += 1 }
                else { break }
            }
            return .init(name:name,range:.init(start:start,length:cursor-start),arguments:args,starred:starred)
        }
        /// TeX also permits unbraced control-sequence definition names.
        /// Skip their balanced bodies just as the braced newcommand path does;
        /// commands written as examples/definitions must not become active
        /// dependency, citation or outline entries.
        mutating func unbracedDefinitionEnd(_ value: LaTeXCommand) -> Int? {
            let primitives: Set<String> = ["def", "edef", "gdef", "xdef"]
            let constructors: Set<String> = ["newcommand", "renewcommand", "providecommand", "DeclareRobustCommand"]
            guard value.arguments.isEmpty, primitives.contains(value.name) || constructors.contains(value.name) else { return nil }
            var cursor = skip(value.range.end)
            guard cursor < bytes.count, bytes[cursor] == 92 else { return nil }
            cursor += 1
            guard cursor < bytes.count else { return nil }
            if letter(bytes[cursor]) {
                while cursor < bytes.count && (letter(bytes[cursor]) || bytes[cursor] == 58 || bytes[cursor] == 95) { cursor += 1 }
            } else { cursor += 1 }
            if constructors.contains(value.name) {
                for _ in 0..<2 {
                    guard let option = argument(cursor, optional: true) else { break }
                    cursor = option.range.end
                }
                return argument(cursor, optional: false)?.range.end
            }
            // A primitive definition can have literal parameter delimiters
            // before its first body brace. Comments and escaped braces do
            // not delimit the body.
            while cursor < bytes.count {
                if bytes[cursor] == 37 { while cursor < bytes.count && bytes[cursor] != 10 { cursor += 1 } }
                else if bytes[cursor] == 92 { cursor = min(cursor + 2, bytes.count) }
                else if bytes[cursor] == 123 { return argument(cursor, optional: false)?.range.end }
                else { cursor += 1 }
            }
            return nil
        }
        mutating func parse(_ source: String) -> LaTeXStructure {
            var i = 0
            let definitionNames: Set<String> = ["newcommand","renewcommand","providecommand","DeclareRobustCommand","newenvironment","renewenvironment","def","edef","gdef","xdef"]
            while i < bytes.count {
                if bytes[i] == 37 { while i < bytes.count && bytes[i] != 10 { i += 1 }; continue }
                guard bytes[i] == 92, var value = command(i) else { i += 1; continue }
                if let end = unbracedDefinitionEnd(value) {
                    value.range.length = end - i
                    commands.append(value); i = end; continue
                }
                commands.append(value)
                if value.name == "verb" {
                    let delimiter = i + (value.starred ? 6 : 5)
                    if delimiter < bytes.count {
                        i = delimiter+1
                        while i < bytes.count && bytes[i] != bytes[delimiter] && bytes[i] != 10 { i += 1 }; i = min(i+1,bytes.count); continue
                    }
                }
                if value.name == "begin", let name = value.arguments.first?.value,
                   ["verbatim","Verbatim","lstlisting","minted"].contains(name),
                   let tail = source.utf8Range(of: "\\end{\(name)}", after: value.range.end) {
                    commands.append(.init(name:"end",range:tail,arguments:[.init(range:tail,contentRange:tail,value:name,optional:false)],starred:false))
                    i = tail.end; continue
                }
                if definitionNames.contains(value.name), !value.arguments.isEmpty { i = value.range.end; continue }
                var next = i+1
                if next < bytes.count && letter(bytes[next]) { while next < bytes.count && (letter(bytes[next]) || bytes[next] == 58 || bytes[next] == 95) { next += 1 } }
                else { next = min(next+1,bytes.count) }
                i = next
            }
            let beginDoc = commands.first { $0.name == "begin" && $0.arguments.first?.value == "document" }
            let endDoc = commands.last { $0.name == "end" && $0.arguments.first?.value == "document" }
            let bodyStart = beginDoc?.range.end ?? 0, bodyEnd = max(bodyStart,endDoc?.range.start ?? bytes.count)
            let body = LaTeXSourceRange(start:bodyStart,length:bodyEnd-bodyStart)
            var blocks = [LaTeXBlock](), stack = [(name:String,command:LaTeXCommand)]()
            let headings: Set<String> = ["part","chapter","section","subsection","subsubsection","paragraph","subparagraph","title","author","date"]
            let documentCommands:Set<String>=["maketitle","tableofcontents","listoffigures","listoftables","bibliography","bibliographystyle","printbibliography","newpage","clearpage"]
            for cmd in commands where cmd.range.start >= bodyStart && cmd.range.start < bodyEnd {
                if cmd.name == "begin", let name = cmd.arguments.first?.value { stack.append((name,cmd)) }
                else if cmd.name == "end", let name = cmd.arguments.first?.value {
                    guard let open = stack.last, open.name == name else {
                        diagnostics.append(.init(message:"Unmatched end of \(name)",range:cmd.range,severity:.error)); continue
                    }
                    stack.removeLast()
                    if stack.isEmpty {
                        let kind: LaTeXBlock.Kind
                        switch name {
                        case "equation","equation*","align","align*","gather","gather*","displaymath","multline","multline*": kind = .formula
                        case "figure","figure*": kind = .figure
                        case "table","table*","tabular","tabularx","longtable": kind = .table
                        case "itemize","enumerate","description": kind = .list
                        case "verbatim","Verbatim","lstlisting","minted": kind = .code
                        default: kind = .environment
                        }
                        let inner = LaTeXSourceRange(start:open.command.range.end,length:max(0,cmd.range.start-open.command.range.end))
                        blocks.append(.init(kind:kind,name:name,range:.init(start:open.command.range.start,length:cmd.range.end-open.command.range.start),contentRange:inner,content:slice(inner.start,inner.end)))
                    }
                } else if stack.isEmpty && headings.contains(cmd.name), let arg = cmd.arguments.last(where:{ !$0.optional }) {
                    blocks.append(.init(kind:.heading,name:cmd.name,range:cmd.range,contentRange:arg.contentRange,content:arg.value))
                } else if stack.isEmpty && documentCommands.contains(cmd.name) {
                    blocks.append(.init(kind:.environment,name:cmd.name,range:cmd.range,contentRange:cmd.range,content:slice(cmd.range.start,cmd.range.end)))
                }
            }
            for item in stack { diagnostics.append(.init(message:"Unclosed environment \(item.name)",range:item.command.range,severity:.error)) }
            let structural = blocks.sorted { $0.range.start < $1.range.start }
            var cursor = bodyStart
            func appendParagraphs(_ lower: Int, _ upper: Int, to result: inout [LaTeXBlock]) {
                guard lower < upper else { return }
                var start = lower, j = lower
                func emit(_ a: Int, _ b: Int) {
                    var lo = a, hi = b
                    while lo < hi && space(bytes[lo]) { lo += 1 }; while hi > lo && space(bytes[hi-1]) { hi -= 1 }
                    if lo < hi {
                        let range = LaTeXSourceRange(start:lo,length:hi-lo)
                        result.append(.init(kind:.paragraph,name:"paragraph",range:range,contentRange:range,content:slice(lo,hi)))
                    }
                }
                while j < upper {
                    if bytes[j] == 10 {
                        var k = j+1; while k < upper && [9,13,32].contains(bytes[k]) { k += 1 }
                        if k < upper && bytes[k] == 10 { emit(start,j); start = k+1; j = start; continue }
                    }
                    j += 1
                }
                emit(start,upper)
            }
            for block in structural { appendParagraphs(cursor,block.range.start,to:&blocks); cursor = block.range.end }
            appendParagraphs(cursor,bodyEnd,to:&blocks)
            func values(_ names: Set<String>) -> [String] { commands.filter { names.contains($0.name) }.compactMap { $0.arguments.last(where:{ !$0.optional })?.value }.flatMap { $0.split(separator:",").map { $0.trimmingCharacters(in:.whitespacesAndNewlines) } } }
            return .init(source:source,bodyRange:body,commands:commands,blocks:blocks.sorted{$0.range.start < $1.range.start},labels:values(["label"]),references:values(["ref","eqref","autoref","cref","Cref","pageref"]),citations:values(["cite","citep","citet","parencite","textcite","autocite","footcite"]),includes:values(["input","include","includegraphics","addbibresource","bibliography"]),packages:values(["usepackage","RequirePackage"]),diagnostics:diagnostics)
        }
    }
}

private extension String {
    func utf8Range(of needle: String, after offset: Int) -> LaTeXSourceRange? {
        let bytes = Array(utf8), target = Array(needle.utf8)
        guard offset >= 0, !target.isEmpty, bytes.count >= target.count, offset <= bytes.count-target.count else { return nil }
        for i in offset...(bytes.count-target.count) where bytes[i..<i+target.count].elementsEqual(target) { return .init(start:i,length:target.count) }
        return nil
    }
}
