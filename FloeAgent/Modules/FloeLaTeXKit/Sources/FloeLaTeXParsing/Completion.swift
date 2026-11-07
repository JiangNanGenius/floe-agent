// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXCore

public struct LaTeXCompletion:Sendable,Identifiable {
    public var id:String {title+":"+String(range.start)}
    public var title:String
    public var range:LaTeXSourceRange
    public var replacement:String
    public var expected:String
}
public enum LaTeXSourceCompletion {
    private static let snippets=["\\section{}","\\subsection{}","\\subsubsection{}","\\textbf{}","\\textit{}","\\emph{}","\\underline{}","\\texttt{}","\\footnote{}","\\label{}","\\ref{}","\\eqref{}","\\cite{}","\\includegraphics[width=0.8\\linewidth]{}","\\input{}","\\include{}","\\usepackage{}","\\frac{}{}","\\sqrt{}","\\sum_{}^{}","\\int_{}^{}","\\begin{equation}\n\n\\end{equation}","\\begin{itemize}\n\\item \n\\end{itemize}","\\begin{enumerate}\n\\item \n\\end{enumerate}"]
    public static func suggestions(source:String,offset:Int,labels:[String],citations:[String])->[LaTeXCompletion] {
        let bytes=Array(source.utf8)
        guard offset>=0,offset<=bytes.count,let before=String(bytes:bytes[..<offset],encoding:.utf8) else{return []}
        let tail=String(before.suffix(2048)),after=String(decoding:bytes[offset...],as:UTF8.self)
        // No completion inside an ordinary comment; an escaped percent is text.
        let line=String(tail.split(separator:"\n",omittingEmptySubsequences:false).last ?? "")
        if line.range(of:#"(?<!\\)%"#,options:.regularExpression) != nil {return []}
        let pattern=#"\\(cite|citep|citet|parencite|textcite|autocite|ref|eqref|pageref|autoref|cref|Cref)\{([^{}]*)$"#
        if let regex=try? NSRegularExpression(pattern:pattern),let match=regex.firstMatch(in:tail,range:NSRange(tail.startIndex...,in:tail)),
           let commandRange=Range(match.range(at:1),in:tail),let keyRange=Range(match.range(at:2),in:tail) {
            let command=String(tail[commandRange]),content=String(tail[keyRange]),partial=String(content.split(separator:",",omittingEmptySubsequences:false).last ?? "")
            let keys=command.lowercased().contains("cite") ? citations:labels
            return Array(Set(keys)).sorted().filter{$0.hasPrefix(partial) && (try? LaTeXBlockBuilder.identifier($0)) != nil}.prefix(40).map {key in
                .init(title:key,range:.init(start:offset-partial.utf8.count,length:partial.utf8.count),replacement:key+(after.hasPrefix("}") ? "":"}"),expected:partial)
            }
        }
        let prefix:String
        if let range=tail.range(of:#"\\[A-Za-z]*$"#,options:.regularExpression) {prefix=String(tail[range])}else {prefix=""}
        return snippets.filter {prefix.isEmpty || $0.hasPrefix(prefix)}.prefix(40).map {snippet in
            let replacement=after.hasPrefix("{") ? String(snippet.prefix(while:{$0 != "{" && $0 != "["})):snippet
            return .init(title:snippet,range:.init(start:offset-prefix.utf8.count,length:prefix.utf8.count),replacement:replacement,expected:prefix)
        }
    }
}
