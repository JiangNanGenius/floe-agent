// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXCore

public indirect enum LaTeXInlineNode: Sendable {
    case text(source: String, visible: String)
    case formatted(prefix: String, suffix: String, command: String, children: [LaTeXInlineNode])
    case attachment(source: String, kind: String, title: String, expression: String)
    case comment(String)

    public var source: String {
        switch self {
        case .text(let source,_), .attachment(let source,_,_,_), .comment(let source): source
        case .formatted(let prefix,let suffix,_,let children): prefix+children.map(\.source).joined()+suffix
        }
    }
    public var visible: String {
        switch self {
        case .text(_,let visible): visible
        case .formatted(_,_,_,let children): children.map(\.visible).joined()
        case .attachment: "\u{FFFC}"
        case .comment: ""
        }
    }
}

/// A visual projection with atomic unknown commands and balanced formatting.
/// The original source is reproduced byte-for-byte until the user changes it.
public struct LaTeXInlineDocument: Sendable {
    public var nodes: [LaTeXInlineNode]
    public var source: String { nodes.map(\.source).joined() }
    public var visibleText: String { nodes.map(\.visible).joined() }
    public init(source: String) { nodes=Self.parse(source,depth:0) }

    public func replacing(_ range: NSRange, with text: String) throws -> String {
        guard Range(range,in:visibleText) != nil else { throw LaTeXError.invalidRange }
        let (before,remainder)=try Self.split(nodes,at:range.location)
        let (_,after)=try Self.split(remainder,at:range.length)
        var insertion: LaTeXInlineNode = .text(source:LaTeXParser.escapeText(text),visible:text)
        for format in formats(at:range.location).reversed() {
            insertion = .formatted(prefix:format.0,suffix:format.1,command:format.2,children:[insertion])
        }
        return (before + (text.isEmpty ? [] : [insertion]) + after).map(\.source).joined()
    }
    public func formatting(_ range: NSRange, command: String) throws -> String {
        guard ["textbf","textit","emph","underline","texttt","textsc"].contains(command),
              Range(range,in:visibleText) != nil else { throw LaTeXError.invalidRange }
        let (before,remainder)=try Self.split(nodes,at:range.location)
        let (selected,after)=try Self.split(remainder,at:range.length)
        let content=selected.map(\.source).joined()
        return before.map(\.source).joined()+"\\"+command+"{"+content+"}"+after.map(\.source).joined()
    }
    public func replacingSource(_ range:NSRange,with replacement:String) throws -> String {
        guard Range(range,in:visibleText) != nil else {throw LaTeXError.invalidRange}
        let (before,remainder)=try Self.split(nodes,at:range.location)
        let (_,after)=try Self.split(remainder,at:range.length)
        return before.map(\.source).joined()+replacement+after.map(\.source).joined()
    }
    public func attachments() -> [(range:NSRange,node:LaTeXInlineNode)] {
        var result=[(NSRange,LaTeXInlineNode)](), offset=0
        func walk(_ nodes:[LaTeXInlineNode]) {
            for node in nodes {
                switch node {
                case .formatted(_,_,_,let children):walk(children)
                case .attachment:result.append((NSRange(location:offset,length:1),node));offset += 1
                default:offset += node.visible.utf16.count
                }
            }
        };walk(nodes);return result
    }
    public func styleRanges() -> [(range:NSRange,command:String)] {
        var result=[(NSRange,String)](),offset=0
        func walk(_ nodes:[LaTeXInlineNode]) {
            for node in nodes {
                if case .formatted(_,_,let command,let children)=node {
                    let start=offset;walk(children);result.append((NSRange(location:start,length:offset-start),command))
                } else { offset += node.visible.utf16.count }
            }
        };walk(nodes);return result
    }
    private func formats(at position:Int) -> [(String,String,String)] {
        func walk(_ nodes:[LaTeXInlineNode],_ position:Int)->[(String,String,String)] {
            var cursor=0
            for node in nodes {
                let end=cursor+node.visible.utf16.count
                if position >= cursor && position <= end, case .formatted(let prefix,let suffix,let command,let children)=node {
                    return [(prefix,suffix,command)]+walk(children,position-cursor)
                };cursor=end
            };return []
        };return walk(nodes,position)
    }
    private static func split(_ nodes:[LaTeXInlineNode],at position:Int) throws -> ([LaTeXInlineNode],[LaTeXInlineNode]) {
        guard position >= 0 else { throw LaTeXError.invalidRange }
        var left=[LaTeXInlineNode](),right=[LaTeXInlineNode](),remaining=position,passed=false
        for node in nodes {
            if passed { right.append(node);continue }
            let length=node.visible.utf16.count
            if length <= remaining { left.append(node);remaining -= length;continue }
            if remaining==0 { right.append(node);passed=true;continue }
            switch node {
            case .text(let raw,let visible):
                guard raw==visible, let cut=Range(NSRange(location:0,length:remaining),in:visible) else { throw LaTeXError.invalidRange }
                let prefix=String(visible[cut]),suffix=String(visible[cut.upperBound...])
                left.append(.text(source:prefix,visible:prefix));right.append(.text(source:suffix,visible:suffix))
            case .formatted(let prefix,let suffix,let command,let children):
                let (a,b)=try split(children,at:remaining)
                if !a.isEmpty { left.append(.formatted(prefix:prefix,suffix:suffix,command:command,children:a)) }
                if !b.isEmpty { right.append(.formatted(prefix:prefix,suffix:suffix,command:command,children:b)) }
            case .attachment,.comment:throw LaTeXError.invalidRange
            }
            remaining=0;passed=true
        }
        guard remaining==0 else { throw LaTeXError.invalidRange };return(left,right)
    }
    private static func parse(_ source:String,depth:Int)->[LaTeXInlineNode] {
        guard depth<32 else { return [.attachment(source:source,kind:"source",title:"LaTeX",expression:source)] }
        let bytes=Array(source.utf8),commands=Dictionary(uniqueKeysWithValues:LaTeXParser.parse(source).commands.map{($0.range.start,$0)})
        var result=[LaTeXInlineNode](),i=0
        func text(_ a:Int,_ b:Int)->String { String(decoding:bytes[a..<b],as:UTF8.self) }
        func search(_ needle:[UInt8],from start:Int)->Int? {
            guard bytes.count>=needle.count,start<=bytes.count-needle.count else{return nil}
            for j in start...(bytes.count-needle.count) {
                if bytes[j..<j+needle.count].elementsEqual(needle) {
                    var backslashes=0,k=j
                    while k>0 && bytes[k-1]==92 { backslashes += 1;k -= 1 }
                    if backslashes%2==0{return j}
                }
            };return nil
        }
        let formatting:Set<String>=["textbf","textit","emph","underline","texttt","textsc","textnormal","textrm","textsf","href"]
        while i<bytes.count {
            if bytes[i]==123 {
                var end=i+1,level=1
                while end<bytes.count && level>0 {
                    if bytes[end]==92 { end=min(end+2,bytes.count);continue }
                    if bytes[end]==123 {level += 1};if bytes[end]==125 {level -= 1};end += 1
                }
                if level==0 {
                    result.append(.formatted(prefix:"{",suffix:"}",command:"group",children:parse(text(i+1,end-1),depth:depth+1)))
                    i=end;continue
                }
            }
            if bytes[i]==37 {
                let start=i;while i<bytes.count && bytes[i] != 10{i += 1};if i<bytes.count{i += 1};result.append(.comment(text(start,i)));continue
            }
            if bytes[i]==36 {
                let doubled=i+1<bytes.count && bytes[i+1]==36, count=doubled ? 2:1
                if let end=search(Array(repeating:36,count:count),from:i+count) {
                    let raw=text(i,end+count),value=text(i+count,end)
                    result.append(.attachment(source:raw,kind:"formula",title:value,expression:value));i=end+count;continue
                }
            }
            if bytes[i]==92,let command=commands[i] {
                if formatting.contains(command.name),let argument=command.arguments.last(where:{!$0.optional}) {
                    let prefix=text(i,argument.contentRange.start),suffix=text(argument.contentRange.end,command.range.end)
                    result.append(.formatted(prefix:prefix,suffix:suffix,command:command.name,children:parse(argument.value,depth:depth+1)));i=command.range.end;continue
                }
                if ["(","["].contains(command.name) {
                    let close=command.name=="(" ? Array("\\)".utf8):Array("\\]".utf8)
                    if let end=search(close,from:i+2) {
                        let value=text(i+2,end);result.append(.attachment(source:text(i,end+2),kind:"formula",title:value,expression:value));i=end+2;continue
                    }
                }
                let escapes:[String:String]=["%":"%","$":"$","#":"#","&":"&","_":"_","{":"{","}":"}","textbackslash":"\\","textasciitilde":"~","textasciicircum":"^","\\":"\n"," ":" ",",":" ",";":" ","!":""]
                if let visible=escapes[command.name] { result.append(.text(source:text(i,command.range.end),visible:visible));i=command.range.end;continue }
                let title=command.arguments.last?.value ?? "\\"+command.name
                let kind=["cite","citep","citet","parencite","textcite","autocite","ref","eqref","autoref"].contains(command.name) ? "reference":"source"
                result.append(.attachment(source:text(i,command.range.end),kind:kind,title:title,expression:""));i=command.range.end;continue
            }
            let start=i;i += 1
            while i<bytes.count && ![37,36,92,123].contains(bytes[i]) { i += 1 }
            let raw=text(start,i);result.append(.text(source:raw,visible:raw))
        };return result
    }
}
