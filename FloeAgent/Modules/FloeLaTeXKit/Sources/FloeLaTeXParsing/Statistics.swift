// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct LaTeXWritingStatistics:Codable,Sendable {
    public var words=0
    public var hanCharacters=0
    public var textCharacters=0
    public var formulas=0
    public var figures=0
    public var tables=0
    public var citationKeys=0
    public var estimated=true
    public init() {}
    public init(source:String) {
        let index=LaTeXParser.parse(source)
        var prose=[String]()
        for block in index.blocks {
            switch block.kind {
            case .paragraph,.heading,.list:prose.append(block.content)
            case .environment where block.name=="abstract" || block.name=="proof" || block.name=="theorem":prose.append(block.content)
            case .formula:formulas+=1
            case .figure:figures+=1
            case .table:tables+=1
            default:break
            }
        }
        let documents=prose.map(LaTeXInlineDocument.init(source:))
        formulas+=documents.flatMap{$0.attachments()}.filter {if case .attachment(_,let kind,_,_)=$0.node {return kind=="formula"};return false}.count
        let visible=documents.map(\.visibleText).joined(separator:"\n")
        textCharacters=visible.filter{!$0.isWhitespace && $0 != "\u{FFFC}"}.count
        let withoutHan=String(String.UnicodeScalarView(visible.unicodeScalars.map {scalar in
            if (0x3400...0x4dbf).contains(scalar.value) || (0x4e00...0x9fff).contains(scalar.value) || (0xf900...0xfaff).contains(scalar.value) || (0x20000...0x3134f).contains(scalar.value) {hanCharacters+=1;return UnicodeScalar(32)!}
            return scalar
        }))
        if let regex=try? NSRegularExpression(pattern:#"\p{L}[\p{L}\p{N}'’]*|\p{N}+"#) {words=regex.numberOfMatches(in:withoutHan,range:NSRange(withoutHan.startIndex...,in:withoutHan))}
        citationKeys=Set(index.citations).subtracting(["*"]).count
    }
    public mutating func add(_ other:Self) {
        words+=other.words;hanCharacters+=other.hanCharacters;textCharacters+=other.textCharacters;formulas+=other.formulas;figures+=other.figures;tables+=other.tables;citationKeys+=other.citationKeys
    }
}
