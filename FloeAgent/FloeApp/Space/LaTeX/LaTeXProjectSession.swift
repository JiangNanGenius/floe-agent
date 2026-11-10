// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import Observation
import SwiftMath
import FloeLaTeXCore
import FloeLaTeXUI
import FloeLaTeXEngine
import FloeLaTeXHostAdapter

@MainActor @Observable final class LaTeXProjectSession {
    let original:LaTeXOriginal
    let editor:LaTeXEditorSession
    private let access:LaTeXHostProject
    private let composition:LaTeXAppComposition
    private(set) var preparingToolchain=false
    @ObservationIgnored private var shownNativeFailureID:UUID?
    @ObservationIgnored private var preparationTask:Task<[LaTeXEngineCapability],Error>?
    private init(original:LaTeXOriginal,access:LaTeXHostProject,composition:LaTeXAppComposition,editor:LaTeXEditorSession) {
        self.original=original;self.access=access;self.composition=composition;self.editor=editor
    }
    static func open(id:UUID,composition:LaTeXAppComposition) async throws -> LaTeXProjectSession {
        let host=try await composition.host(),original=try await composition.original(id)
        let access=try await composition.acquireNative(original)
        let editor=LaTeXEditorSession(store:access.store,builds:host.builds,chinese:IDELanguageRunText.isChinese,
            lifetime:access,formulaRenderer:LaTeXFormulaImage.image,typesetAction:{store,revision,configuration in
                try await composition.nativeRuntime.typeset(store,revision:revision,configuration:configuration)
            },operationIsActive:{composition.nativeRuntime.operations[id] != nil})
        await editor.load()
        return .init(original:original,access:access,composition:composition,editor:editor)
    }
    func flushForClose() async -> Bool {
        editor.commitInput()
        do {
            try await editor.save()
            if original.libraryRecord != nil {try await PersonalContentService.shared.library().markChanged(original.id,title:editor.manifest?.title)}
            return true
        } catch {editor.report(error);return false}
    }
    func refresh() async {await editor.refresh()}
    var nativeFailureID:UUID? {composition.nativeRuntime.failures[original.id]?.id}
    func presentNativeFailure() {
        guard let failure=composition.nativeRuntime.failures[original.id],shownNativeFailureID != failure.id else {return}
        shownNativeFailureID=failure.id;editor.report(LaTeXError.unavailable(failure.message))
    }
    var workbenchOperation:LaTeXWorkbenchOperation? {
        let operation=composition.nativeRuntime.operations[original.id]
        guard preparingToolchain || operation != nil else {return nil}
        let phase=operation?.preparationProgress
        let preparing=operation?.kind != .typesetting || (phase != nil && phase?.stage != .compiling)
        let status:String
        if operation?.waitingRecovery==true {status=IDELanguageRunText.t("正在确认任务已停止…","Confirming the task has stopped…")}
        else if operation?.cancelling==true {status=IDELanguageRunText.t("正在停止…","Stopping…")}
        else if phase?.stage == .downloading,let bytes=phase?.downloadBytes,bytes>0 {
            let amount=ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file)
            status=IDELanguageRunText.t("正在下载排版所需内容（约 \(amount)）…","Downloading typesetting resources (about \(amount))…")
        } else {status=preparing ? IDELanguageRunText.t("正在准备排版所需内容…","Preparing typesetting resources…"):IDELanguageRunText.t("正在排版…","Typesetting…")}
        return .init(status:status,stopLabel:preparing ? IDELanguageRunText.t("停止准备","Stop preparation"):IDELanguageRunText.t("停止排版","Stop typesetting"),stop:{self.cancelPreparation()})
    }
    func prepareToolchain() async {
        guard workbenchOperation==nil,!editor.isBuilding else {return}
        preparingToolchain=true;defer {preparingToolchain=false;preparationTask=nil}
        do {
            editor.commitInput();try await editor.save()
            guard let revision=editor.manifest?.revision else {throw LaTeXError.invalidProject}
            let task=Task { @MainActor in try await self.composition.nativeRuntime.prepare(self.editor.store,revision:revision) }
            preparationTask=task
            let values=try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
            editor.updateCapabilities(values)
        } catch {editor.report(error)}
    }
    func cancelPreparation() {editor.stop();preparationTask?.cancel();composition.nativeRuntime.cancel(projectID:original.id)}
}

@MainActor enum LaTeXFormulaImage {
    static func image(_ source:String,size:CGFloat)->UIImage? {
        guard source.utf8.count<=8192 else {return nil}
        var depth=0
        for character in source {
            if character=="{" {depth+=1};if character=="}" {depth-=1}
            if depth<0 || depth>64 {return nil}
        }
        guard depth==0 else {return nil}
        var formula=MathImage(latex:source,fontSize:size,textColor:.label)
        let (error,image,_)=formula.asImage()
        guard error==nil,let image,image.size.width>0,image.size.height>0,image.size.width<1600,image.size.height<800 else {return nil}
        return image
    }
}

struct LaTeXEditorSurface:View {
    let session:LaTeXProjectSession
    var onAssistant:(@MainActor ()->Void)?=nil
    var body:some View {
        LaTeXWorkbench(session:session.editor,pdfRenderer:renderPreview,onAssistant:onAssistant,operation:session.workbenchOperation)
            .onChange(of:session.nativeFailureID,initial:true) {_,_ in session.presentNativeFailure()}
    }
    private func renderPreview(_ preview:LaTeXPreviewContext)->AnyView {
        let destination:PDFReadingDestination?
        if let location=preview.location {destination=PDFReadingDestination(page:location.page,x:location.x,y:location.y)}else {destination=nil}
        let sourceAction:(@MainActor (Int,Double,Double)->Void)?
        if session.editor.pdfIsCurrent {sourceAction=preview.onSource}else {sourceAction=nil}
        return AnyView(InlinePDFReader(url:preview.url,destination:destination,onSource:sourceAction))
    }
}
#endif
