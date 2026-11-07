// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXCore

public enum LaTeXLogParser {
    public static func diagnostics(_ log: String, defaultPath: String) -> [LaTeXDiagnostic] {
        let lines=log.split(separator:"\n",omittingEmptySubsequences:false).map(String.init)
        var result=[LaTeXDiagnostic](),pending:String?,current=defaultPath
        let location=try? NSRegularExpression(pattern:#"^(.+\.(?:tex|sty|cls|bib)):(\d+):\s*(.+)$"#)
        let sourceLine=try? NSRegularExpression(pattern:#"^l\.(\d+)\s*(.*)$"#)
        for line in lines.prefix(100000) {
            if let match=location?.firstMatch(in:line,range:NSRange(line.startIndex...,in:line)),
               let p=Range(match.range(at:1),in:line),let l=Range(match.range(at:2),in:line),let m=Range(match.range(at:3),in:line) {
                let path=String(line[p]),relative=path.hasPrefix("./") ? String(path.dropFirst(2)):path
                result.append(.init(severity:line.localizedCaseInsensitiveContains("warning") ? .warning : .error,message:String(line[m]),path:relative,line:Int(line[l])));continue
            }
            if line.hasPrefix("(") {
                let value=String(line.dropFirst()).split(whereSeparator: { $0.isWhitespace || $0 == ")" }).first.map(String.init)
                if let value,value.hasSuffix(".tex"),!value.hasPrefix("/") { current=value.hasPrefix("./") ? String(value.dropFirst(2)) : value }
            }
            if line.hasPrefix("! ") { pending=String(line.dropFirst(2));continue }
            if let message=pending,let match=sourceLine?.firstMatch(in:line,range:NSRange(line.startIndex...,in:line)),let range=Range(match.range(at:1),in:line) {
                result.append(.init(severity:.error,message:message,path:current,line:Int(line[range])));pending=nil
            }
            else if line.contains("Warning:") || line.contains("Overfull ") || line.contains("Underfull ") {
                result.append(.init(severity:.warning,message:String(line.prefix(4096)),path:current))
            }
            if result.count >= 2000 { break }
        }
        if let pending { result.append(.init(severity:.error,message:pending,path:current)) }
        var seen=Set<String>()
        return result.filter { seen.insert("\($0.path ?? ""):\($0.line ?? 0):\($0.message)").inserted }
    }
}

public struct LaTeXLineChange: Sendable, Identifiable {
    public enum Kind: Sendable { case equal, inserted, removed }
    public var id: Int; public var kind:Kind;public var text:String
}
public enum LaTeXTextDiff {
    public static func lines(before:String,after:String) -> [LaTeXLineChange] {
        let old=before.components(separatedBy:"\n"),new=after.components(separatedBy:"\n")
        // Keep comparison bounded for imported generated sources.
        guard old.count+new.count <= 20000 else { return [.init(id:0,kind:.removed,text:before),.init(id:1,kind:.inserted,text:after)] }
        let difference=new.difference(from:old)
        var removed=Set<Int>(),inserted=Set<Int>()
        for change in difference { switch change {case .remove(let offset,_,_):removed.insert(offset);case .insert(let offset,_,_):inserted.insert(offset)} }
        var output=[LaTeXLineChange](),a=0,b=0
        func append(_ kind:LaTeXLineChange.Kind,_ text:String) {output.append(.init(id:output.count,kind:kind,text:text))}
        while a<old.count || b<new.count {
            if a<old.count,removed.contains(a) {append(.removed,old[a]);a+=1}
            else if b<new.count,inserted.contains(b) {append(.inserted,new[b]);b+=1}
            else if a<old.count,b<new.count {append(.equal,new[b]);a+=1;b+=1}
            else if a<old.count {append(.removed,old[a]);a+=1}
            else {append(.inserted,new[b]);b+=1}
        }
        return output
    }
}
