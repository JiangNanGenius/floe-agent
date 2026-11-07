// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXCore
import CLaTeXSupport

public struct LaTeXPDFLocation: Codable, Hashable, Sendable {
    /// One-based PDF page; coordinates are PDF points from the top-left.
    public var page:Int;public var x:Double;public var y:Double;public var width:Double;public var height:Double
}
public struct LaTeXSourceLocation: Codable, Hashable, Sendable {
    public var path:String;public var line:Int
    public init(path:String,line:Int) {self.path=path;self.line=line}
}
public struct LaTeXSyncTeX: Sendable {
    public struct Node: Sendable {
        public var source:LaTeXSourceLocation
        public var pdf:LaTeXPDFLocation
    }
    public var nodes:[Node]
    public init(url:URL,sourceRoot:URL,mainFile:String) throws {
        let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size <= 32*1024*1024 else {throw LaTeXError.limitExceeded("SyncTeX")}
        let input=try Data(contentsOf:url)
        var bytes=input
        if url.pathExtension == "gz" {
            var output:UnsafeMutablePointer<UInt8>?,count=0
            let code=input.withUnsafeBytes { raw in floe_tex_gunzip(raw.bindMemory(to:UInt8.self).baseAddress,raw.count,64*1024*1024,&output,&count) }
            guard code == 0,let output else {throw LaTeXError.invalidOperation("The source map could not be read.")}
            defer {floe_tex_buffer_free(output)}
            bytes=Data(bytes:output,count:count)
        }
        guard let text=String(data:bytes,encoding:.utf8) else {throw LaTeXError.invalidText}
        self.init(text:text,sourceRoot:sourceRoot,mainFile:mainFile)
    }
    public init(text:String,sourceRoot:URL,mainFile:String) {
        var files=[Int:String](),page=0,unit=1.0,mag=1000.0,xOffset=0.0,yOffset=0.0,lastY=0.0
        var result=[Node]()
        let root=sourceRoot.standardizedFileURL.path+"/"
        for record in text.split(separator:"\n") {
            if record.hasPrefix("Input:") {
                let parts=record.split(separator:":",maxSplits:2,omittingEmptySubsequences:false)
                guard parts.count==3,let tag=Int(parts[1]) else {continue}
                var path=String(parts[2])
                if path == "texput" || (path.isEmpty && tag == 1) {path=mainFile}
                if path.hasPrefix(root) {path=String(path.dropFirst(root.count))}
                if path.hasPrefix("./") {path=String(path.dropFirst(2))}
                if !path.isEmpty,(try? LaTeXPath.validate(path)) != nil {files[tag]=path}
            } else if record.hasPrefix("Unit:") {unit=Double(record.dropFirst(5)) ?? 1}
            else if record.hasPrefix("Magnification:") {mag=Double(record.dropFirst(14)) ?? 1000}
            else if record.hasPrefix("X Offset:") {xOffset=Double(record.dropFirst(9)) ?? 0}
            else if record.hasPrefix("Y Offset:") {yOffset=Double(record.dropFirst(9)) ?? 0}
            else if record.first == "{" {page=Int(record.dropFirst()) ?? 0}
            else if let kind=record.first,"([hvxgk$r".contains(kind),page>0 {
                let parts=record.dropFirst().split(separator:":",omittingEmptySubsequences:false)
                guard parts.count>=2 else {continue}
                let reference=parts[0].split(separator:","),position=parts[1].split(separator:",",omittingEmptySubsequences:false)
                guard reference.count>=2,let tag=Int(reference[0]),let line=Int(reference[1]),let path=files[tag],position.count>=2,let x=Double(position[0]) else {continue}
                let y=Double(position[1]) ?? lastY;lastY=y
                let dimensions=parts.count>2 ? parts[2].split(separator:",").compactMap {Double($0)} : []
                let scale=unit*mag/1000.0/65536.0*72.0/72.27
                let width=dimensions.first.map {abs($0)*scale} ?? 3
                let ascent=dimensions.count>1 ? abs(dimensions[1])*scale : 6
                let depth=dimensions.count>2 ? abs(dimensions[2])*scale : 2
                result.append(.init(source:.init(path:path,line:line),pdf:.init(page:page,x:(x+xOffset)*scale,y:(y+yOffset)*scale-ascent,width:max(3,width),height:max(6,ascent+depth))))
                if result.count >= 1000000 {break}
            }
        }
        nodes=result
    }
    public func forward(path:String,line:Int) -> LaTeXPDFLocation? {
        nodes.filter {$0.source.path == path}.min {
            let a=abs($0.source.line-line),b=abs($1.source.line-line)
            if a != b {return a<b}
            return $0.pdf.width*$0.pdf.height < $1.pdf.width*$1.pdf.height
        }?.pdf
    }
    public func reverse(page:Int,x:Double,y:Double) -> LaTeXSourceLocation? {
        func distance(_ n:Node)->Double {
            let p=n.pdf,dx=max(p.x-x,0,x-p.x-p.width),dy=max(p.y-y,0,y-p.y-p.height)
            return dx*dx+dy*dy + min(100,p.width*p.height/10000)
        }
        return nodes.filter {$0.pdf.page == page}.min {distance($0)<distance($1)}?.source
    }
}
