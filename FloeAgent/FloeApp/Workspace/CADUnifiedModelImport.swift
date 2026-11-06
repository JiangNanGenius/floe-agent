// SPDX-License-Identifier: MPL-2.0
import Foundation
import SwiftUI
import CryptoKit
import FloeCAD
import FloeWorkspace

/// Source formats open the same native workbench as .floecad. Import writes a
/// separately named package, committed only after the import/save succeeds;
/// the original exchange file is never overwritten. Source digest AND chosen
/// units select the working copy, so a changed source never opens stale data.
@MainActor
enum CADUnifiedModelImport {
    static let extensions:Set<String>=["stl","obj","step","stp","iges","igs"]
    static func open(sourcePath:String,service:WorkspaceFileService,unitScale:Double?,unitTag:String) async throws -> (document:FloeCADDocument,path:String) {
        let token=MeshImportCancellation()
        return try await withTaskCancellationHandler {
            let source=try service.guardResolver.resolve(sourcePath,for:.read(maxBytes:128*1024*1024))
            let data=try await Task.detached(priority:.userInitiated) {try Data(floeContentsOf:source)}.value
            try Task.checkCancellation()
            let sha=SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()
            let format=(sourcePath as NSString).pathExtension.lowercased()
            let resources=format=="obj" ? try await objResources(path:sourcePath,service:service,sourceSHA256:sha):[:]
            let resourceHashes=try CADImportResources.hashes(resources)
            let identity=resourceHashes.isEmpty ? sha:CADImportResources.sha256(try JSONSerialization.data(withJSONObject:["source":sha,"resources":resourceHashes],options:.sortedKeys))
            let stem=String(((sourcePath as NSString).lastPathComponent as NSString).deletingPathExtension.prefix(64))
                .replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"\\",with:"_")
            let name="\(stem)-\(unitTag)-\(identity).floecad"
            let parent=(sourcePath as NSString).deletingLastPathComponent
            let relative=parent.isEmpty ? name:(parent as NSString).appendingPathComponent(name)
            let destination=try service.guardResolver.resolve(relative)
            if FileManager.default.fileExists(atPath:destination.path) {
                if case .damaged = await FloeCADDocument.recoveryInspection(at:destination) {
                    throw CADDocumentError(code:"recovery_required",message:String(localized:"cad.modelImport.recoveryRequired"))
                }
                let document=try await FloeCAD3DBridge.shared.openDocument(at:destination)
                CADDrawingModelBridge.configure(document)
                return (document,relative)
            }
            let stageName=".floe-model-import-\(UUID().uuidString).floecad"
            let stagePath=parent.isEmpty ? stageName:(parent as NSString).appendingPathComponent(stageName)
            let stage=try service.guardResolver.resolve(stagePath,for:.createNew)
            var temporary:FloeCADDocument?
            defer {temporary?.close();try? FileManager.default.removeItem(at:stage)}
            let document=try await FloeCADDocument.create(at:stage,name:stem)
            temporary=document
            let outcome:CADCommandOutcome
            if ["step","stp","igs","iges"].contains(format) {
                let plan=try await CADExactImportService.parseOffMain(data:data,format:format,fileName:source.lastPathComponent,cancellation:token)
                outcome=try CADExactImportService.apply(plan,to:document,cancellation:token,undoMode:.singleStep).outcome
            } else {
                guard let unitScale,unitScale.isFinite,unitScale>0 else {throw CADDocumentError(code:"unit_required",message:String(localized:"cad.modelImport.chooseUnits"))}
                if format=="obj" {
                    let plan=try await CADMeshImportService.parseOffMain(data:data,fileName:source.lastPathComponent,siblings:resources,unitScale:unitScale,requireExplicitUnits:true,cancellation:token)
                    outcome=try CADMeshImportService.apply(plan,to:document,cancellation:token)
                } else {
                    let plan=try await CADMeshImportService.parseSingleMeshOffMain(data:data,fileName:source.lastPathComponent,format:format,unitScale:unitScale,cancellation:token)
                    outcome=try CADMeshImportService.applySingleMesh(plan,to:document,cancellation:token)
                }
            }
            guard outcome.isOK else {throw CADDocumentError(code:outcome.errorCode ?? "import_failed",message:outcome.message ?? String(localized:"cad.modelImport.failed"))}
            try Task.checkCancellation()
            let saved=await document.save()
            guard saved.succeeded else {throw CADDocumentError(code:"save_failed",message:String(localized:"cad.modelImport.saveFailed"))}
            // Re-read the guarded source before publication. An external edit
            // during parsing cannot silently bind an older model to new bytes.
            let current=try service.guardResolver.resolve(sourcePath,for:.read(maxBytes:128*1024*1024))
            let currentHash=try await Task.detached(priority:.userInitiated) {
                SHA256.hash(data:try Data(floeContentsOf:current)).map {String(format:"%02x",$0)}.joined()
            }.value
            guard currentHash==sha else {throw CADDocumentError(code:"source_changed",message:String(localized:"cad.modelImport.sourceChanged"))}
            if format=="obj" {
                let currentResources=try await objResources(path:sourcePath,service:service,sourceSHA256:sha)
                guard try CADImportResources.hashes(currentResources)==resourceHashes else {throw CADDocumentError(code:"source_changed",message:String(localized:"cad.modelImport.sourceChanged"))}
            }
            try Task.checkCancellation()
            document.close();temporary=nil
            let publication=try service.guardResolver.resolve(relative,for:.createNew)
            let currentStage=try service.guardResolver.resolve(stagePath)
            try FileManager.default.moveItem(at:currentStage,to:publication)
            let opened=try await FloeCAD3DBridge.shared.openDocument(at:publication)
            CADDrawingModelBridge.configure(opened)
            return (opened,relative)
        } onCancel:{token.cancel()}
    }
    private static func objResources(path:String,service:WorkspaceFileService,sourceSHA256:String) async throws -> [String:Data] {
        let bounded=WorkspaceFileService(guard:service.guardResolver.withReadLimit(128*1024*1024))
        let package=try await Task.detached(priority:.userInitiated) {
            try EngineeringPreviewPackage.load(path:path,service:bounded,limits:.init(maximumBytes:128*1024*1024,maximumFiles:128))
        }.value
        guard package.provenance.sourceSHA256==sourceSHA256 else {throw CADDocumentError(code:"source_changed",message:String(localized:"cad.modelImport.sourceChanged"))}
        guard package.missingReferences.isEmpty else {throw CADDocumentError(code:"missing_resources",message:String(localized:"cad.modelImport.missingResources"))}
        return try Dictionary(uniqueKeysWithValues:package.files.filter{$0.name != package.name}.map {file in
            guard let data=Data(base64Encoded:file.base64) else {throw CADDocumentError(code:"invalid_resource",message:String(localized:"cad.modelImport.failed"))}
            return (file.name,data)
        })
    }
}

struct CADUnifiedModelImportEntry:View {
    let sourcePath:String
    let service:WorkspaceFileService
    let onImported:(FloeCADDocument,String)->Void
    @State private var unit:String?
    @State private var started=false
    @State private var error:String?
    @State private var task:Task<Void,Never>?
    private var unitless:Bool {["stl","obj"].contains((sourcePath as NSString).pathExtension.lowercased())}
    private let units:[(String,String,Double)]=[("mm","mm",1),("cm","cm",10),("m","m",1000),("in","in",25.4),("ft","ft",304.8)]
    var body:some View {
        Form {
            Section {
                Text((sourcePath as NSString).lastPathComponent).font(.headline)
                Text("cad.modelImport.originalKept").font(.footnote).foregroundStyle(.secondary)
                if unitless {
                    Picker("cad.modelImport.units",selection:$unit) {
                        Text("cad.modelImport.chooseUnits").tag(String?.none)
                        ForEach(units,id:\.0) {value in Text(value.1).tag(String?.some(value.0))}
                    }.accessibilityIdentifier("CADDirectImportUnits")
                    Button("cad.modelImport.open") {start()}.disabled(started || unit==nil)
                        .accessibilityIdentifier("CADDirectImportOpen")
                }
                if started {ProgressView("cad.modelImport.importing")}
                if let error {Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)}
            }
        }
        .task {if !unitless {start()}}
        .onDisappear {task?.cancel()}
    }
    private func start() {
        guard !started else {return};started=true;error=nil
        let chosen=units.first {$0.0==unit}
        task=Task {@MainActor in
            do {
                let result=try await CADUnifiedModelImport.open(sourcePath:sourcePath,service:service,unitScale:chosen?.2,unitTag:chosen?.0 ?? "source-units")
                guard !Task.isCancelled else {await FloeCAD3DBridge.shared.releaseDocument(at:result.document.url,expected:result.document);return}
                onImported(result.document,result.path)
            } catch is CancellationError {started=false}
            catch {started=false;self.error=error.localizedDescription}
        }
    }
}
