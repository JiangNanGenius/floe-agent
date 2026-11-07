// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXCore

public struct LaTeXTableCell:Sendable,Identifiable {public var id:Int {range.start};public var range:LaTeXSourceRange;public var source:String}
public struct LaTeXTableProjection:Sendable {
    public var rows:[[LaTeXTableCell]]
    /// Index ordinary tabular cells without expanding commands or rewriting layout.
    /// Complex span/array preambles remain available through the source editor.
    public init?(source:String) {
        let index=LaTeXParser.parse(source),bytes=Array(source.utf8)
        guard let begin=index.commands.first(where:{$0.name=="begin" && ["tabular","tabularx","longtable"].contains($0.arguments.first?.value ?? "")}),
              let end=index.commands.last(where:{$0.name=="end" && $0.arguments.first?.value==begin.arguments.first?.value}) else {return nil}
        var cursor=begin.range.end
        func skipSpace() {while cursor<end.range.start,[9,10,13,32].contains(bytes[cursor]) {cursor+=1}}
        func skipGroup(_ open:UInt8,_ close:UInt8)->Bool {
            skipSpace();guard cursor<bytes.count,bytes[cursor]==open else{return false}
            cursor+=1;var depth=1
            while cursor<end.range.start,depth>0 {
                if bytes[cursor]==92 {cursor=min(cursor+2,bytes.count);continue}
                if bytes[cursor]==open {depth+=1};if bytes[cursor]==close {depth-=1};cursor+=1
            };return depth==0
        }
        skipSpace();if cursor<bytes.count,bytes[cursor]==91 {_=skipGroup(91,93)}
        guard skipGroup(123,125) else{return nil}
        if begin.arguments.first?.value=="tabularx" {guard skipGroup(123,125) else{return nil}}
        var result=[[LaTeXTableCell]](),row=[LaTeXTableCell](),start=cursor,depth=0
        func cell(_ end:Int) {
            var a=start,b=end
            while a<b,[9,10,13,32].contains(bytes[a]) {a+=1};while b>a,[9,10,13,32].contains(bytes[b-1]) {b-=1}
            row.append(.init(range:.init(start:a,length:b-a),source:String(decoding:bytes[a..<b],as:UTF8.self)))
        }
        let rules:Set<String>=["toprule","midrule","bottomrule","hline","endhead","endfirsthead","endfoot","endlastfoot"]
        while cursor<end.range.start {
            if bytes[cursor]==37 {while cursor<end.range.start,bytes[cursor] != 10 {cursor+=1};continue}
            if bytes[cursor]==92,cursor+1<end.range.start {
                if depth==0,bytes[cursor+1]==92 {
                    cell(cursor);result.append(row);row=[];cursor+=2
                    if cursor<end.range.start,bytes[cursor]==91 {_=skipGroup(91,93)}
                    start=cursor;continue
                }
                if depth==0,row.isEmpty,let command=index.commands.first(where:{$0.range.start==cursor}),rules.contains(command.name) {
                    let pending=String(decoding:bytes[start..<cursor],as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
                    if pending.isEmpty {cursor=command.range.start+1+command.name.utf8.count;start=cursor;continue}
                }
                cursor+=2;continue
            }
            if bytes[cursor]==123 {depth+=1};if bytes[cursor]==125 {depth-=1}
            if depth<0 {return nil}
            if bytes[cursor]==38,depth==0 {cell(cursor);cursor+=1;start=cursor;continue}
            cursor+=1
        }
        if !String(decoding:bytes[start..<end.range.start],as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {cell(end.range.start);result.append(row)}
        guard depth==0,!result.isEmpty,result.count<=1000,result.allSatisfy({$0.count<=64}) else{return nil}
        rows=result
    }
}
