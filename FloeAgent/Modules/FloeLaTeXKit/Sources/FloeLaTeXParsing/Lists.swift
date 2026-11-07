// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXCore

public struct LaTeXListItem:Sendable,Identifiable {
    public var id:Int {range.start}
    public var range:LaTeXSourceRange
    public var content:String
    public var label:String?
}
/// Lossless top-level item projection. Nested environments remain inside an
/// item's exact source; its own block editor can expand them separately.
public struct LaTeXListProjection:Sendable {
    public var items:[LaTeXListItem]
    public init?(content:String) {
        let index=LaTeXParser.parse(content),bytes=Array(content.utf8)
        var depth=0,commands=[LaTeXCommand]()
        for command in index.commands {
            if command.name=="begin" {depth+=1}
            else if command.name=="end" {depth-=1;guard depth>=0 else{return nil}}
            else if command.name=="item",depth==0 {commands.append(command)}
        }
        guard depth==0,!commands.isEmpty,commands.count<=10000 else{return nil}
        items=commands.enumerated().map {position,command in
            var a=command.range.end,b=position+1<commands.count ? commands[position+1].range.start:bytes.count
            while a<b,[9,10,13,32].contains(bytes[a]) {a+=1};while b>a,[9,10,13,32].contains(bytes[b-1]) {b-=1}
            return .init(range:.init(start:a,length:b-a),content:String(decoding:bytes[a..<b],as:UTF8.self),label:command.arguments.first?.value)
        }
    }
}
