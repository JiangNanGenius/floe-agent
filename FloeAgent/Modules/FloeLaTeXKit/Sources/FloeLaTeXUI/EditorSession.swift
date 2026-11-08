// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import UIKit
import FloeLaTeXCore
import FloeLaTeXParsing
import FloeLaTeXReferences
import FloeLaTeXEngine

public typealias LaTeXFormulaRenderer = @MainActor @Sendable (String,CGFloat)->UIImage?
public typealias LaTeXTypesetAction = @MainActor @Sendable (LaTeXProjectStore,Int64,LaTeXBuildConfiguration) async throws -> LaTeXBuildRecord

@MainActor @Observable public final class LaTeXEditorSession {
    public enum Mode:String,CaseIterable {case visual,source}
    public let store:LaTeXProjectStore
    public let builds:LaTeXBuildService
    public let formulaRenderer:LaTeXFormulaRenderer?
    private let lifetime:(any LaTeXBuildLifetime)?
    private let typesetAction:LaTeXTypesetAction?
    private let engineCapabilities:(@MainActor @Sendable () async -> [LaTeXEngineCapability])?
    private let operationIsActive:@MainActor @Sendable ()->Bool
    public var chinese:Bool
    public private(set) var manifest:LaTeXProjectManifest?
    public private(set) var source=""
    public private(set) var path="main.tex"
    public private(set) var structure=LaTeXParser.parse("")
    public private(set) var dirty=false
    public private(set) var saving=false
    public private(set) var preparingTypeset=false
    public private(set) var build:LaTeXBuildRecord?
    public private(set) var pdfBuild:LaTeXBuildRecord?
    public private(set) var sync:LaTeXSyncTeX?
    public private(set) var history=[LaTeXHistoryEntry]()
    public private(set) var buildHistory=[LaTeXBuildRecord]()
    public private(set) var references=[LaTeXBibEntry]()
    public private(set) var projectLabels=[String]()
    public private(set) var statistics=LaTeXWritingStatistics()
    public private(set) var capabilities=[LaTeXEngineCapability]()
    public var mode:Mode = .visual
    public var autoCompile=false
    public var offline=false
    public var error:String?
    public var conflict:String?
    public var sourceSelection=NSRange(location:0,length:0)
    public var focusedBlock:Int?
    public var pdfLocation:LaTeXPDFLocation?
    public var sourceReveal=UUID()
    public var searchQuery=""
    public var searchRegex=false
    public var searchCaseSensitive=false
    public var searchResults=[LaTeXSearchHit]()
    public var replacement=""
    public private(set) var undoAvailable=false
    public private(set) var redoAvailable=false
    @ObservationIgnored private var undoValues=[String]()
    @ObservationIgnored private var redoValues=[String]()
    @ObservationIgnored private var savedSource=""
    @ObservationIgnored private var saveTask:Task<Void,Never>?
    @ObservationIgnored private var compileTask:Task<Void,Never>?
    @ObservationIgnored private var typesetTask:Task<LaTeXBuildRecord,Error>?
    @ObservationIgnored private var stopRequested=false
    @ObservationIgnored private var lastEdit=Date.distantPast
    @ObservationIgnored private let editorID=UUID()

    public init(store:LaTeXProjectStore,builds:LaTeXBuildService,chinese:Bool = Locale.preferredLanguages.first?.hasPrefix("zh") == true,lifetime:(any LaTeXBuildLifetime)?=nil,formulaRenderer:LaTeXFormulaRenderer?=nil,typesetAction:LaTeXTypesetAction?=nil,engineCapabilities:(@MainActor @Sendable () async -> [LaTeXEngineCapability])?=nil,operationIsActive:@escaping @MainActor @Sendable ()->Bool = {false}) {
        self.store=store;self.builds=builds;self.chinese=chinese;self.lifetime=lifetime;self.formulaRenderer=formulaRenderer;self.typesetAction=typesetAction;self.engineCapabilities=engineCapabilities
        self.operationIsActive=operationIsActive
    }
    public func t(_ zh:String,_ en:String)->String {chinese ? zh:en}
    public func updateCapabilities(_ values:[LaTeXEngineCapability]) {capabilities=values}
    public func commitInput() {UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),to:nil,from:nil,for:nil)}
    public var sourceCompletions:[LaTeXCompletion] {
        guard sourceSelection.location<=source.utf16.count else{return []}
        let before=(source as NSString).substring(to:sourceSelection.location)
        return LaTeXSourceCompletion.suggestions(source:source,offset:before.utf8.count,labels:Array(Set(projectLabels+structure.labels)),citations:references.map(\.key))
    }
    public func complete(_ value:LaTeXCompletion) {
        commitInput()
        guard structure.original(value.range)==value.expected else {report(LaTeXError.invalidRange);return}
        do {
            let bytes=Array(source.utf8),prefix=String(decoding:bytes.prefix(value.range.start),as:UTF8.self)
            let position=value.replacement.range(of:"{}").map{value.replacement[..<$0.lowerBound].utf16.count+1} ?? value.replacement.utf16.count
            update(try value.range.replacing(in:source,with:value.replacement),groupTyping:false)
            sourceSelection = .init(location:prefix.utf16.count+position,length:0);sourceReveal=UUID()
        }catch {report(error)}
    }
    public var pdfURL:URL? {guard let record=pdfBuild,let relative=record.pdfRelativePath else{return nil};return store.root.appendingPathComponent("Builds/"+record.id.uuidString).appendingPathComponent(relative)}
    public var pdfIsCurrent:Bool {pdfBuild?.revision == manifest?.revision && !dirty}
    public var isBuilding:Bool {preparingTypeset || build?.isActive == true || operationIsActive()}
    public func load() async {
        do {
            let current=try await store.manifest()
            try await loadPath(current.mainFile)
            if let engineCapabilities {capabilities=await engineCapabilities()}else {capabilities=await builds.capabilities()}
            try await reloadPanels()
        } catch {report(error)}
    }
    private func loadPath(_ selected:String,discardDraft:Bool=false) async throws {
        guard discardDraft || !dirty else {throw LaTeXError.invalidOperation(t("请先保存当前输入。","Save the current input first."))}
        let captured=try await store.file(selected)
        guard let value=String(data:captured.data,encoding:.utf8) else {throw LaTeXError.invalidText}
        // Awaiting the store can interleave a new keyboard/IME edit. Keep that
        // draft and its original revision rather than silently replacing it.
        guard discardDraft || !dirty else {throw LaTeXError.invalidOperation(t("请先保存当前输入。","Save the current input first."))}
        manifest=captured.manifest
        path=selected;source=value;savedSource=value;structure=LaTeXParser.parse(value);dirty=false;conflict=nil
        undoValues=[];redoValues=[];updateUndoState();sourceSelection = .init(location:0,length:0);sourceReveal=UUID()
        if LaTeXFileKind.infer(path) != .source {mode = .source}
    }
    public func open(_ selected:String) async {
        commitInput();do {try await save();try await loadPath(selected)}catch {report(error)}
    }
    public func update(_ value:String,groupTyping:Bool = true) {
        guard value != source else {return}
        if !groupTyping || Date().timeIntervalSince(lastEdit)>0.7 || undoValues.isEmpty {
            undoValues.append(source)
            while undoValues.count>100 || (undoValues.count>1 && undoValues.reduce(0,{$0+$1.utf8.count})>16*1024*1024) {undoValues.removeFirst()}
        }
        redoValues=[];lastEdit=Date();source=value;structure=LaTeXParser.parse(value);dirty=source != savedSource;updateUndoState();scheduleSave()
    }
    @discardableResult public func update(range:LaTeXSourceRange,original:String,replacement:String)->Bool {
        do {
            guard structure.original(range) == original else {throw LaTeXError.invalidRange}
            update(try range.replacing(in:source,with:replacement))
            return true
        } catch {report(error);return false}
    }
    // Structural indexing trims layout whitespace. Keep horizontal whitespace
    // at the active text's end so a newly typed space survives the next render.
    func editableText(in range:LaTeXSourceRange)->String {
        func read(_ bytes:UnsafeBufferPointer<UInt8>)->String {
            guard range.start>=0,range.length>=0,range.start<=bytes.count,range.length<=bytes.count-range.start else{return ""}
            var end=range.end
            while end<bytes.count,[9,32].contains(bytes[end]) {end+=1}
            return String(decoding:bytes[range.start..<end],as:UTF8.self)
        }
        return source.utf8.withContiguousStorageIfAvailable(read) ?? Array(source.utf8).withUnsafeBufferPointer(read)
    }
    private func updateUndoState() {undoAvailable = !undoValues.isEmpty;redoAvailable = !redoValues.isEmpty}
    public func undo() {guard let value=undoValues.popLast() else{return};redoValues.append(source);source=value;dirty=source != savedSource;structure=LaTeXParser.parse(source);updateUndoState();scheduleSave()}
    public func redo() {guard let value=redoValues.popLast() else{return};undoValues.append(source);source=value;dirty=source != savedSource;structure=LaTeXParser.parse(source);updateUndoState();scheduleSave()}
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask=Task {try? await Task.sleep(for:.milliseconds(600));guard !Task.isCancelled else{return};do {try await self.save()}catch {self.report(error)}}
    }
    public func save() async throws {
        guard dirty else {return}
        guard !saving else {throw LaTeXError.invalidOperation(t("正在保存，请稍后再试。","Saving is in progress. Try again shortly."))}
        guard let manifest else {throw LaTeXError.invalidProject}
        saving=true;defer {saving=false}
        let value=source,selected=path
        do {
            let committed=try await store.apply([.put(path:selected,data:Data(value.utf8))],expectedRevision:manifest.revision,label:"Writing",origin:"user")
            // Publish only this transaction's known revision. Reading a newer
            // manifest here could hide a concurrent AI edit from refresh/CAS.
            var updated=manifest;updated.revision=committed.revision;updated.modifiedAt=Date()
            updated.files.removeAll{$0.path==selected};updated.files.append(.init(path:selected,data:Data(value.utf8)));updated.files.sort{$0.path<$1.path}
            self.manifest=updated;savedSource=value;dirty=source != value
            try? FileManager.default.removeItem(at:draftURL(selected))
            if dirty {scheduleSave()}
            else if autoCompile && !isBuilding {scheduleCompile()}
        } catch {
            let target=draftURL(selected);try? FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
            try? Data(source.utf8).write(to:target,options:.atomic)
            if case LaTeXError.revisionConflict = error {conflict=try? await store.text(selected)}
            throw error
        }
    }
    private func draftURL(_ path:String)->URL {store.root.appendingPathComponent("Drafts/"+editorID.uuidString).appendingPathComponent(LaTeXDigest.hash(Data(path.utf8))+".tex")}
    public func resolveConflict(keepDraft:Bool) async {
        do {
            manifest=try await store.manifest()
            if keepDraft {savedSource=try await store.text(path);dirty=source != savedSource;conflict=nil;try await save()}
            else {try await loadPath(path,discardDraft:true)}
        }catch {report(error)}
    }
    public func refresh() async {
        do {
            if preparingTypeset {
                let values=try await builds.history(store:store)
                if let latest=values.first {build=latest;buildHistory=values}
            }
            let current=try await store.manifest()
            if current.revision != manifest?.revision,!dirty,!saving {
                if current.files.contains(where:{$0.path==path}) {try await loadPath(path)}else {try await loadPath(current.mainFile)}
                try await reloadPanels()
            }
            if let id=build?.id,let latest=await builds.record(id),latest.state != build?.state || latest.messages.count != build?.messages.count {
                build=latest
                if !latest.isActive {try await reloadPanels()}
            }
        }catch {report(error)}
    }
    public func reloadPanels() async throws {
        history=try await store.history();buildHistory=try await builds.history(store:store)
        if let latest=buildHistory.first {build=latest}
        if let success=buildHistory.first(where:{$0.succeeded}) {
            pdfBuild=success
            if let path=success.synctexRelativePath {
                sync=try? LaTeXSyncTeX(url:store.root.appendingPathComponent("Builds/"+success.id.uuidString).appendingPathComponent(path),sourceRoot:store.root.appendingPathComponent("Snapshots/"+success.snapshotID.uuidString),mainFile:manifest?.mainFile ?? "main.tex")
            }
        }
        references=try await LaTeXProjectEditing.bibliography(store:store).flatMap(\.bibliography.entries)
        let inputs=try await store.textFiles()
        projectLabels=Array(Set(inputs.manifest.files.filter{$0.kind == .source}.flatMap{LaTeXParser.parse(inputs.files[$0.path] ?? "").labels})).sorted()
        var counts=LaTeXWritingStatistics()
        for file in inputs.manifest.files where file.kind == .source {counts.add(.init(source:inputs.files[file.path] ?? ""))}
        statistics=counts
    }
    public func reloadHistory() async {
        do {let values=try await store.history();try Task.checkCancellation();history=values}catch {report(error)}
    }
    private func scheduleCompile() {
        compileTask?.cancel();compileTask=Task {try? await Task.sleep(for:.seconds(1.5));guard !Task.isCancelled,!self.isBuilding else{return};await self.compile()}
    }
    public func compile() async {
        guard !isBuilding else {return}
        stopRequested=false
        preparingTypeset=true
        defer {
            preparingTypeset=false;typesetTask=nil
            if autoCompile,!dirty,let built=build?.revision,let current=manifest?.revision,built<current {scheduleCompile()}
        }
        do {
            try await save();guard let revision=manifest?.revision else {throw LaTeXError.invalidProject}
            try Task.checkCancellation()
            guard !stopRequested else {throw CancellationError()}
            if let typesetAction {
                let store=self.store,configuration=LaTeXBuildConfiguration(offline:offline)
                let task=Task { @MainActor in try await typesetAction(store,revision,configuration) }
                typesetTask=task
                build=try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
            }
            else {build=try await builds.start(store:store,expectedRevision:revision,configuration:.init(offline:offline),lifetime:lifetime)}
            try await reloadPanels()
        }catch is CancellationError {} catch {report(error)}
    }
    public func stop() {
        stopRequested=true
        typesetTask?.cancel()
        if let id=build?.id {Task {await builds.cancel(id)}}
    }
    public func insert(_ text:String) {
        do {
            if mode == .source,let range=Range(sourceSelection,in:source) {
                let start=source.utf8.distance(from:source.utf8.startIndex,to:range.lowerBound),length=source[range].utf8.count
                update(try LaTeXSourceRange(start:start,length:length).replacing(in:source,with:text),groupTyping:false)
            } else {
                let offset=focusedBlock.flatMap {id in structure.blocks.first {$0.id==id}?.range.end} ?? structure.bodyRange.end
                update(try LaTeXSourceRange(start:offset,length:0).replacing(in:source,with:"\n\n"+text+"\n"),groupTyping:false)
            }
        } catch {report(error)}
    }
    public func selectSource(path:String,line:Int) async {
        if path != self.path {await open(path)}
        mode = .source
        let lines=source.components(separatedBy:"\n"),prefix=lines.prefix(max(0,min(line-1,lines.count))).joined(separator:"\n")
        sourceSelection = .init(location:min(source.utf16.count,prefix.utf16.count+(line>1 ? 1:0)),length:0);sourceReveal=UUID()
    }
    public func revealPDF() {
        guard !dirty,pdfIsCurrent else {error=t("先排版最新内容，再定位到 PDF。","Typeset the latest content before locating it in the PDF.");return}
        let prefix=(source as NSString).substring(to:min(sourceSelection.location,source.utf16.count))
        let line=mode == .source ? prefix.components(separatedBy:"\n").count : focusedBlock.map {id in String(decoding:Array(source.utf8).prefix(id),as:UTF8.self).components(separatedBy:"\n").count} ?? 1
        pdfLocation=sync?.forward(path:path,line:line)
    }
    public func reversePDF(page:Int,x:Double,y:Double) {
        guard pdfIsCurrent,let location=sync?.reverse(page:page,x:x,y:y) else{return}
        Task {await self.selectSource(path:location.path,line:location.line)}
    }
    public func createFile(path:String,text:String="") async {
        guard manifest?.files.contains(where:{$0.path==path}) != true else {report(LaTeXError.duplicatePath(path));return}
        await mutate([.put(path:path,data:Data(text.utf8))],label:"New file");if manifest?.files.contains(where:{$0.path==path})==true {await open(path)}
    }
    public func renameFile(_ from:String,to:String) async {await mutate([.rename(from:from,to:to)],label:"Rename file");if path==from {await open(to)}}
    public func deleteFile(_ selected:String) async {await mutate([.delete(path:selected)],label:"Delete file");if path==selected,let main=manifest?.mainFile {await open(main)}}
    public func setMain(_ path:String) async {await mutate([.mainFile(path)],label:"Main file")}
    public func setEngine(_ engine:LaTeXEngine) async {await mutate([.engine(engine)],label:"Engine")}
    public func mutate(_ edits:[LaTeXEdit],label:String) async {
        do {
            try await save();guard let manifest else {throw LaTeXError.invalidProject}
            _=try await store.apply(edits,expectedRevision:manifest.revision,label:label)
            let current=try await store.manifest()
            try await loadPath(current.files.contains(where:{$0.path==path}) ? path:current.mainFile)
            try await reloadPanels()
        }catch {report(error)}
    }
    public func restore(_ revision:Int64) async {
        do {try await save();guard let manifest else {return};_=try await store.restore(revision:revision,expectedRevision:manifest.revision);await load()}catch {report(error)}
    }
    public func search() async {
        do {try await save();searchResults=try await LaTeXProjectEditing.search(store:store,query:searchQuery,caseSensitive:searchCaseSensitive,regularExpression:searchRegex)}catch {report(error)}
    }
    public func replaceAll() async {
        do {try await save();guard let manifest else{return};_=try await LaTeXProjectEditing.replaceAll(store:store,expectedRevision:manifest.revision,query:searchQuery,replacement:replacement,caseSensitive:searchCaseSensitive,regularExpression:searchRegex);await load();await search()}catch {report(error)}
    }
    public func cite(_ key:String) async {
        do {
            try await save();guard let manifest else{return}
            let offset:Int
            if mode == .source,let range=Range(sourceSelection,in:source) {offset=source.utf8.distance(from:source.utf8.startIndex,to:range.lowerBound)}
            else {offset=focusedBlock.flatMap {id in structure.blocks.first {$0.id==id}?.range.end} ?? structure.bodyRange.end}
            _=try await LaTeXProjectEditing.insertCitation(store:store,path:path,offset:offset,key:key,expectedRevision:manifest.revision)
            try await loadPath(path);try await reloadPanels()
        } catch {report(error)}
    }
    public func importFile(_ url:URL) async {
        let scoped=url.startAccessingSecurityScopedResource();defer {if scoped {url.stopAccessingSecurityScopedResource()}}
        do {
            let kind=LaTeXFileKind.infer(url.lastPathComponent)
            let path=(kind == .image || kind == .data ? "Assets/":"")+url.lastPathComponent
            guard manifest?.files.contains(where:{$0.path==path}) != true else {throw LaTeXError.duplicatePath(path)}
            let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard size<=256*1024*1024 else {throw LaTeXError.limitExceeded(url.lastPathComponent)}
            let data=try Data(contentsOf:url)
            guard data.count<=256*1024*1024 else {throw LaTeXError.limitExceeded(url.lastPathComponent)}
            await mutate([.put(path:path,data:data)],label:"Import asset")
        }catch {report(error)}
    }
    public func ensurePackages(_ required:[String]) async {
        guard !required.isEmpty else{return}
        do {
            try await save();guard let manifest else{return}
            let main=try await store.text(manifest.mainFile),index=LaTeXParser.parse(main)
            let missing=required.filter{!index.packages.contains($0)}
            guard !missing.isEmpty else{return}
            for package in missing {try LaTeXBlockBuilder.identifier(package)}
            let insertion="\n\\usepackage{"+missing.joined(separator:",")+"}\n"
            await mutate([.replace(path:manifest.mainFile,range:.init(start:index.commands.first(where:{$0.name=="begin" && $0.arguments.first?.value=="document"})?.range.start ?? 0,length:0),text:insertion)],label:"Prepare document packages")
        }catch {report(error)}
    }
    public func exportZIP() async throws -> URL {
        try await save();let snapshot=try await store.snapshot()
        let url=store.root.appendingPathComponent("Exports/Project-\(snapshot.manifest.revision).zip")
        do {try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);if FileManager.default.fileExists(atPath:url.path) {try FileManager.default.removeItem(at:url)}
            try LaTeXProjectArchive.export(snapshot,to:url);try await store.releaseSnapshot(snapshot);return url
        }catch {try? await store.releaseSnapshot(snapshot);throw error}
    }
    public func report(_ error:Error) {if error is CancellationError {return};self.error=error.localizedDescription}
}
#endif
