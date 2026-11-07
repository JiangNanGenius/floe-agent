import SwiftUI
import UIKit
import FloeLaTeXCore
import FloeLaTeXEngine
import FloeLaTeXNativeExperiment
import FloeLaTeXUI

@main @MainActor struct LaTeXQualificationApp:App {
    @State private var session:LaTeXEditorSession?
    @State private var error:String?
    var body:some Scene {
        WindowGroup {
            NavigationStack {
                if let session {
                    LaTeXWorkbench(session:session,pdfRenderer:{context in AnyView(QualificationPDF(context:context))})
                        .navigationTitle("LaTeX")
                }else if let error {Text(error).textSelection(.enabled)}
                else {ProgressView().task {await open()}}
            }
        }
    }
    func open() async {
        do {
            let documents=try FileManager.default.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            let arguments=ProcessInfo.processInfo.arguments
            let qualificationID=arguments.firstIndex(of:"--qualification-project").flatMap {index in index+1<arguments.count ? UUID(uuidString:arguments[index+1]):nil}
            let root=documents.appendingPathComponent("LaTeXQualification"+(qualificationID.map{"-"+$0.uuidString} ?? ""))
            let store:LaTeXProjectStore
            if FileManager.default.fileExists(atPath:root.appendingPathComponent("LaTeXProject.json").path) {store=try .init(root:root)}
            else {
                let template=LaTeXTemplates.template("chinese"),id=UUID()
                store=try .create(root:root,id:id,owner:.init(kind:.externalDocument,id:id),title:"原生论文",files:template.files)
            }
            let builds=try LaTeXBuildService(cacheRoot:documents.appendingPathComponent("TypesettingCache"),engine:LaTeXNativeExperiment())
            session=LaTeXEditorSession(store:store,builds:builds,chinese:true,formulaRenderer:QualificationMathRenderer.image)
        }catch {self.error=error.localizedDescription}
    }
}

/// Only the qualification host uses this Core Graphics renderer. The App
/// injects its existing protected PDF reading session into the same interface.
private struct QualificationPDF:View {
    var context:LaTeXPreviewContext
    @State private var images=[UIImage]()
    var body:some View {
        ScrollView {LazyVStack {ForEach(images.indices,id:\.self) {index in Image(uiImage:images[index]).resizable().scaledToFit().background(.white).id(index+1)}}.padding(12)}
            .background(Color(uiColor:.systemGray5))
            .accessibilityIdentifier("latex.pdfPreview")
            .task(id:context.url) {
                guard let document=CGPDFDocument(context.url as CFURL) else{return}
                images=(1...document.numberOfPages).prefix(30).compactMap {index in
                    guard let page=document.page(at:index) else{return nil}
                    let size=page.getBoxRect(.mediaBox).size,scale=min(1,1000/size.width)
                    let target=CGSize(width:size.width*scale,height:size.height*scale)
                    return UIGraphicsImageRenderer(size:target).image {renderer in
                        UIColor.white.setFill();renderer.fill(CGRect(origin:.zero,size:target))
                        let cg=renderer.cgContext;cg.translateBy(x:0,y:target.height);cg.scaleBy(x:scale,y:-scale);cg.drawPDFPage(page)
                    }
                }
            }
    }
}
