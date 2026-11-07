// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXCore

public enum LaTeXBlockBuilder {
    public static func heading(_ title:String,level:Int)->String { "\\"+["section","subsection","subsubsection"][max(0,min(level,2))]+"{"+LaTeXParser.escapeText(title)+"}\n" }
    public static func formula(_ expression:String,numbered:Bool = true,label:String? = nil)throws->String {
        if let label { try identifier(label) }
        let name=numbered ? "equation":"equation*"
        return "\\begin{\(name)}"+(label.map{"\\label{\($0)}"} ?? "")+"\n"+expression+"\n\\end{\(name)}\n"
    }
    public static func figure(path:String,caption:String,label:String? = nil,width:Double = 0.8)throws->String {
        _=try LaTeXPath.validate(path)
        guard !path.contains("{"),!path.contains("}"),width>0,width<=1 else{throw LaTeXError.invalidOperation("Choose a valid image width and filename.")}
        if let label { try identifier(label) }
        return "\\begin{figure}[htbp]\n\\centering\n\\includegraphics[width=\(String(format:"%.2f",width))\\linewidth]{\\detokenize{\(path)}}\n\\caption{"+LaTeXParser.escapeText(caption)+"}"+(label.map{"\\label{\($0)}"} ?? "")+"\n\\end{figure}\n"
    }
    public static func table(_ rows:[[String]],caption:String? = nil,label:String? = nil)throws->String {
        guard let columns=rows.map(\.count).max(),columns>0,columns<=64,rows.count<=1000 else{throw LaTeXError.limitExceeded("table size")}
        if let label { try identifier(label) }
        var output="\\begin{table}[htbp]\n\\centering\n\\begin{tabular}{"+String(repeating:"l",count:columns)+"}\n\\toprule\n"
        for (index,row) in rows.enumerated() {
            output += (0..<columns).map{LaTeXParser.escapeText($0<row.count ? row[$0]:"")}.joined(separator:" & ")+" \\\\\n"
            if index==0 && rows.count>1 { output += "\\midrule\n" }
        }
        output += "\\bottomrule\n\\end{tabular}\n"
        if let caption { output += "\\caption{"+LaTeXParser.escapeText(caption)+"}\n" }
        if let label { output += "\\label{\(label)}\n" }
        return output+"\\end{table}\n"
    }
    public static func list(_ items:[String],numbered:Bool)throws->String {
        guard !items.isEmpty,items.count<=10_000 else{throw LaTeXError.limitExceeded("list size")}
        let name=numbered ? "enumerate":"itemize"
        return "\\begin{\(name)}\n"+items.map{"\\item "+LaTeXParser.escapeText($0)}.joined(separator:"\n")+"\n\\end{\(name)}\n"
    }
    public static func citation(_ keys:[String],command:String = "cite")throws->String {
        guard ["cite","citep","citet","parencite","textcite","autocite"].contains(command),!keys.isEmpty else{throw LaTeXError.invalidOperation("Choose a citation style and reference.")}
        for key in keys { try identifier(key) };return "\\\(command){"+keys.joined(separator:",")+"}"
    }
    public static func identifier(_ value:String)throws {
        let allowed=CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"_:-./+"))
        guard !value.isEmpty,value.utf8.count<=512,value.unicodeScalars.allSatisfy(allowed.contains) else{throw LaTeXError.invalidOperation("Enter a valid reference key.")}
    }
}

public struct LaTeXSearchHit: Codable, Sendable {
    public var path:String
    public var range:LaTeXSourceRange
    public var line:Int
    public var excerpt:String
}
public enum LaTeXSourceSearch {
    public static func search(_ source:String,path:String,query:String,caseSensitive:Bool = false,regularExpression:Bool = false,limit:Int = 1000)throws->[LaTeXSearchHit] {
        guard !query.isEmpty else{return []}
        let pattern=regularExpression ? query:NSRegularExpression.escapedPattern(for:query)
        let regex=try NSRegularExpression(pattern:pattern,options:caseSensitive ? []:[.caseInsensitive])
        let range=NSRange(source.startIndex..<source.endIndex,in:source)
        var hits=[LaTeXSearchHit]()
        regex.enumerateMatches(in:source,range:range) { match,_,stop in
            guard let match,let area=Range(match.range,in:source) else{return}
            let start=source.utf8.distance(from:source.utf8.startIndex,to:area.lowerBound)
            let end=source.utf8.distance(from:source.utf8.startIndex,to:area.upperBound)
            let line=source[..<area.lowerBound].reduce(1){$1=="\n" ? $0+1:$0}
            let lineRange=source.lineRange(for:area)
            hits.append(.init(path:path,range:.init(start:start,length:end-start),line:line,excerpt:String(source[lineRange]).trimmingCharacters(in:.newlines)))
            if hits.count>=max(1,limit){stop.pointee=true}
        };return hits
    }
}
