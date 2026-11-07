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
            })
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
    func prepareToolchain(profile:String?) async {
        guard !preparingToolchain,!editor.isBuilding else {return}
        preparingToolchain=true;defer {preparingToolchain=false;preparationTask=nil}
        do {
            editor.commitInput();try await editor.save()
            guard let revision=editor.manifest?.revision else {throw LaTeXError.invalidProject}
            let task=Task { @MainActor in try await self.composition.nativeRuntime.prepare(self.editor.store,revision:revision,installProfile:profile) }
            preparationTask=task
            let values=try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
            editor.updateCapabilities(values)
        } catch {editor.report(error)}
    }
    func cancelPreparation() {preparationTask?.cancel();composition.nativeRuntime.cancel(projectID:original.id)}
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
        LaTeXWorkbench(session:session.editor,pdfRenderer:renderPreview,onAssistant:onAssistant)
            .toolbar {ToolbarItem(placement:.topBarTrailing) {toolchainControl}}
    }
    private func renderPreview(_ preview:LaTeXPreviewContext)->AnyView {
        let destination:PDFReadingDestination?
        if let location=preview.location {destination=PDFReadingDestination(page:location.page,x:location.x,y:location.y)}else {destination=nil}
        let sourceAction:(@MainActor (Int,Double,Double)->Void)?
        if session.editor.pdfIsCurrent {sourceAction=preview.onSource}else {sourceAction=nil}
        return AnyView(InlinePDFReader(url:preview.url,destination:destination,onSource:sourceAction))
    }
    @ViewBuilder private var toolchainControl:some View {
            if session.preparingToolchain {
                HStack {ProgressView();Button(IDELanguageRunText.t("停止准备","Stop preparation")) {session.cancelPreparation()}}
            } else {
                Menu {
                    Button(IDELanguageRunText.t("检查工具链","Check toolchain")) {Task {await session.prepareToolchain(profile:nil)}}
                    Button(IDELanguageRunText.t("安装常用工具链","Install standard toolchain")) {Task {await session.prepareToolchain(profile:"standard")}}
                    Button(IDELanguageRunText.t("安装完整工具链（下载较大）","Install full toolchain (large download)")) {Task {await session.prepareToolchain(profile:"full")}}
                } label:{Label(IDELanguageRunText.t("排版工具","Typesetting tools"),systemImage:"shippingbox")}
                    .disabled(session.editor.isBuilding).accessibilityIdentifier("latex.toolchain")
            }
    }
}
#endif
