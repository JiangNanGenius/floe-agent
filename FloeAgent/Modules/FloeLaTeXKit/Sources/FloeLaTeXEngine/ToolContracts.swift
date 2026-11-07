// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXCore
import FloeLaTeXParsing
import FloeLaTeXReferences

public struct LaTeXFileOperation:Codable,Sendable {
    public enum Kind:String,Codable,Sendable {case write,replace,rename,delete,setMain,setEngine,renameProject}
    public var operation:Kind
    public var path:String?
    public var text:String?
    public var start:Int?
    public var length:Int?
    public var destination:String?
    public var engine:LaTeXEngine?
    public init(operation:Kind,path:String? = nil,text:String? = nil,start:Int? = nil,length:Int? = nil,destination:String? = nil,engine:LaTeXEngine? = nil) {
        self.operation=operation;self.path=path;self.text=text;self.start=start;self.length=length;self.destination=destination;self.engine=engine
    }
    public func edit() throws -> LaTeXEdit {
        func required(_ value:String?)->String {value ?? ""}
        switch operation {
        case .write:guard let text else {throw LaTeXError.invalidText};return .put(path:try LaTeXPath.validate(required(path)),data:Data(text.utf8))
        case .replace:guard let start,let length,let text,start>=0,length>=0 else {throw LaTeXError.invalidRange};return .replace(path:try LaTeXPath.validate(required(path)),range:.init(start:start,length:length),text:text)
        case .rename:return .rename(from:try LaTeXPath.validate(required(path)),to:try LaTeXPath.validate(required(destination)))
        case .delete:return .delete(path:try LaTeXPath.validate(required(path)))
        case .setMain:return .mainFile(try LaTeXPath.validate(required(path)))
        case .setEngine:guard let engine else {throw LaTeXError.invalidOperation("Choose a typesetting engine.")};return .engine(engine)
        case .renameProject:guard let text,!text.isEmpty,text.utf8.count<=2048 else {throw LaTeXError.invalidOperation("Enter a project title.")};return .title(text)
        }
    }
}

public struct LaTeXReadPage:Codable,Sendable {
    public var projectID:UUID;public var revision:Int64;public var path:String;public var sha256:String
    public var offset:Int;public var text:String;public var nextOffset:Int?
    public var offsetUnit:String = "UTF-8 bytes"
}
public struct LaTeXProjectInspection:Codable,Sendable {
    public var manifest:LaTeXProjectManifest
    public var capabilities:[LaTeXEngineCapability]
    public var latestBuild:LaTeXBuildRecord?
    public var templates:[String]
    public var editContract:String
    public var fileCount:Int
    public var nextFileOffset:Int?
    public init(manifest:LaTeXProjectManifest,capabilities:[LaTeXEngineCapability],latestBuild:LaTeXBuildRecord?,fileOffset:Int=0,fileLimit:Int=100) {
        self.manifest=manifest;self.capabilities=capabilities;self.latestBuild=latestBuild;templates=LaTeXTemplates.all.map(\.id)
        fileCount=manifest.files.count
        let offset=max(0,min(fileOffset,fileCount)),end=min(fileCount,offset+max(1,min(500,fileLimit)))
        self.manifest.files=Array(manifest.files[offset..<end]);nextFileOffset=end<fileCount ? end:nil
        editContract="Use the exact revision with a stable mutationID. operation is write(path,text), replace(path,start,length,text), rename(path,destination), delete(path), setMain(path), setEngine(engine), or renameProject(text). Ranges use UTF-8 bytes. Read content and its ranges before editing; preserve custom macros and comments. Typeset, inspect actual diagnostics, repair and typeset again. The same mutationID replays the same transaction without duplicating edits."
    }
}
public struct LaTeXStructureInspection:Codable,Sendable {
    public var revision:Int64;public var path:String;public var commands:[LaTeXCommand];public var blocks:[LaTeXBlock]
    public var labels:[String];public var references:[String];public var citations:[String];public var includes:[String];public var packages:[String];public var diagnostics:[LaTeXSourceDiagnostic]
    public var statistics:LaTeXWritingStatistics
}
public struct LaTeXReferenceInspection:Codable,Sendable {
    public var path:String;public var entries:[LaTeXBibEntry];public var diagnostics:[String];public var duplicateKeys:[String];public var missingCitations:[String]
}
public enum LaTeXToolOperations {
    public static func read(store:LaTeXProjectStore,path:String,offset:Int=0,limit:Int=12000) async throws -> LaTeXReadPage {
        guard offset>=0,(1...48000).contains(limit) else {throw LaTeXError.invalidRange}
        let captured=try await store.file(path)
        guard let file=captured.manifest.files.first(where:{$0.path==path}),file.kind.isText else {throw LaTeXError.missingFile(path)}
            let data=captured.data
            guard offset<=data.count else {throw LaTeXError.invalidRange}
            var end=min(data.count,offset+limit)
            while end>offset,end<data.count,data[end]&0xc0==0x80 {end-=1}
            if end==offset,offset<data.count {end+=1;while end<data.count,data[end]&0xc0==0x80 {end+=1}}
            guard let text=String(data:data[offset..<end],encoding:.utf8) else {throw LaTeXError.invalidRange}
            return LaTeXReadPage(projectID:captured.manifest.id,revision:captured.manifest.revision,path:path,sha256:file.sha256,offset:offset,text:text,nextOffset:end<data.count ? end:nil)
    }
    public static func structure(store:LaTeXProjectStore,path:String) async throws -> LaTeXStructureInspection {
        let captured=try await store.file(path)
            let data=captured.data
            guard let source=String(data:data,encoding:.utf8) else {throw LaTeXError.invalidText}
            let parsed=LaTeXParser.parse(source)
            return LaTeXStructureInspection(revision:captured.manifest.revision,path:path,commands:parsed.commands,blocks:parsed.blocks,labels:parsed.labels,references:parsed.references,citations:parsed.citations,includes:parsed.includes,packages:parsed.packages,diagnostics:parsed.diagnostics,statistics:.init(source:source))
    }
    public static func references(store:LaTeXProjectStore) async throws -> [LaTeXReferenceInspection] {
        let snapshot=try await store.textFiles()
            var citations=[String](),result=[LaTeXReferenceInspection]()
            for file in snapshot.manifest.files where file.kind == .source {
                let source=snapshot.files[file.path] ?? ""
                citations+=LaTeXParser.parse(source).citations
            }
            var allKeys=Set<String>()
            for file in snapshot.manifest.files where file.kind == .bibliography {
                let source=snapshot.files[file.path] ?? "",parsed=LaTeXBibParser.parse(source)
                allKeys.formUnion(parsed.entries.map(\.key))
                result.append(.init(path:file.path,entries:parsed.entries,diagnostics:parsed.diagnostics,duplicateKeys:parsed.duplicateKeys,missingCitations:[]))
            }
            let missing=Array(Set(citations).subtracting(allKeys).subtracting(["*"])).sorted()
            for index in result.indices {result[index].missingCitations=missing}
            return result
    }
    public static func apply(store:LaTeXProjectStore,operations:[LaTeXFileOperation],expectedRevision:Int64,mutationID:UUID,origin:String) async throws -> LaTeXMutationResult {
        guard !operations.isEmpty,operations.count<=10000 else {throw LaTeXError.limitExceeded("edit operations")}
        return try await store.apply(operations.map{try $0.edit()},expectedRevision:expectedRevision,requestID:mutationID,label:"AI edit",origin:origin)
    }
}
