// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXCore
import FloeLaTeXParsing
import FloeLaTeXReferences

public enum LaTeXProjectEditing {
    public static func preambleEdits(source:String,path:String,values:[String:String]) throws -> [LaTeXEdit] {
        let index=LaTeXParser.parse(source),allowed:Set<String>=["title","author","date"]
        guard Set(values.keys).isSubset(of:allowed) else {throw LaTeXError.invalidOperation("Unknown paper information field.")}
        var replacements=[(LaTeXSourceRange,String)](),missing=[String]()
        for key in values.keys.sorted() {
            let value=values[key]!
            guard value.utf8.count<=65536 else {throw LaTeXError.limitExceeded("paper information")}
            if let command=index.commands.last(where:{$0.name==key && $0.range.start<index.bodyRange.start}),let argument=command.arguments.last(where:{!$0.optional}) {
                if argument.value != value {replacements.append((argument.contentRange,value))}
            }else if !value.isEmpty {missing.append("\\\(key){\(value)}\n")}
        }
        if !missing.isEmpty {
            let offset=index.commands.first(where:{$0.name=="begin" && $0.arguments.first?.value=="document"})?.range.start ?? 0
            replacements.append((.init(start:offset,length:0),missing.joined()))
        }
        return replacements.sorted{$0.0.start>$1.0.start}.map{.replace(path:path,range:$0.0,text:$0.1)}
    }
    /// Insert from the end so every range refers to the same inspected revision.
    public static func replaceAll(store:LaTeXProjectStore,expectedRevision:Int64,query:String,replacement:String,
                                  paths:[String]? = nil,caseSensitive:Bool = false,regularExpression:Bool = false) async throws -> LaTeXMutationResult {
        let manifest=try await store.manifest()
        guard manifest.revision == expectedRevision else {throw LaTeXError.revisionConflict(expected:expectedRevision,actual:manifest.revision)}
        var edits=[LaTeXEdit]()
        for file in manifest.files where file.kind.isText && (paths == nil || paths!.contains(file.path)) {
            let source=try await store.text(file.path)
            let hits=try LaTeXSourceSearch.search(source,path:file.path,query:query,caseSensitive:caseSensitive,regularExpression:regularExpression,limit:10001)
            guard edits.count+hits.count<=10000 else {throw LaTeXError.limitExceeded("search results")}
            for hit in hits.reversed() {edits.append(.replace(path:file.path,range:hit.range,text:replacement))}
        }
        return try await store.apply(edits,expectedRevision:expectedRevision,label:"Replace all")
    }
    public static func insertCitation(store:LaTeXProjectStore,path:String,offset:Int,key:String,expectedRevision:Int64,requestID:UUID = UUID()) async throws -> LaTeXMutationResult {
        let manifest=try await store.manifest(),source=try await store.text(path)
        let citation=try LaTeXBlockBuilder.citation([key])
        var files=[String:LaTeXBibliography]()
        for file in manifest.files where file.kind == .bibliography {files[file.path]=LaTeXBibParser.parse(try await store.text(file.path))}
        guard files.values.contains(where:{$0.entries.contains(where:{$0.key == key})}) else {throw LaTeXError.missingFile("citation: "+key)}
        var edits=[LaTeXEdit.replace(path:path,range:.init(start:offset,length:0),text:citation)]
        let main=try await store.text(manifest.mainFile)
        let structure=LaTeXParser.parse(main)
        if !structure.commands.contains(where:{$0.name == "bibliography" || $0.name == "addbibresource"}) {
            let basenames=files.keys.sorted().map {($0 as NSString).deletingPathExtension}
            for name in basenames {try LaTeXBlockBuilder.identifier(name)}
            let names=basenames.joined(separator:",")
            let style=structure.commands.contains(where:{$0.name == "bibliographystyle"}) ? "" : "\\bibliographystyle{plain}\n"
            let insertion="\n"+style+"\\bibliography{\(names)}\n"
            if path == manifest.mainFile {
                let edited=try LaTeXSourceRange(start:offset,length:0).replacing(in:source,with:citation)
                let document=LaTeXParser.parse(edited)
                edits=[.put(path:path,data:Data(try LaTeXSourceRange(start:document.bodyRange.end,length:0).replacing(in:edited,with:insertion).utf8))]
            } else {edits.append(.replace(path:manifest.mainFile,range:.init(start:structure.bodyRange.end,length:0),text:insertion))}
        }
        return try await store.apply(edits,expectedRevision:expectedRevision,requestID:requestID,label:"Insert citation")
    }
    public static func bibliography(store:LaTeXProjectStore) async throws -> [(path:String,bibliography:LaTeXBibliography)] {
        let manifest=try await store.manifest();var result=[(String,LaTeXBibliography)]()
        for file in manifest.files where file.kind == .bibliography {result.append((file.path,LaTeXBibParser.parse(try await store.text(file.path))))}
        return result
    }
    public static func search(store:LaTeXProjectStore,query:String,caseSensitive:Bool = false,regularExpression:Bool = false) async throws -> [LaTeXSearchHit] {
        let manifest=try await store.manifest();var hits=[LaTeXSearchHit]()
        for file in manifest.files where file.kind.isText {
            hits+=try LaTeXSourceSearch.search(try await store.text(file.path),path:file.path,query:query,caseSensitive:caseSensitive,regularExpression:regularExpression,limit:max(1,1000-hits.count))
            if hits.count>=1000 {break}
        };return hits
    }
}
