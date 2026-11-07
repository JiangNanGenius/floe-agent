// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import ImageIO
import FloeLaTeXCore
import FloeLaTeXParsing

struct LaTeXTableEditor:View {
    @Bindable var session:LaTeXEditorSession
    var block:LaTeXBlock
    var projection:LaTeXTableProjection
    var body:some View {
        ScrollView(.horizontal) {
            VStack(spacing:1) {
                ForEach(projection.rows.indices,id:\.self) {row in
                    HStack(alignment:.top,spacing:1) {
                        ForEach(projection.rows[row]) {cell in
                            LaTeXRichTextEditor(source:session.editableText(in:.init(start:block.contentRange.start+cell.range.start,length:cell.range.length)),fontSize:16,formulaRenderer:session.formulaRenderer,onChange:{original,value in
                                let global=LaTeXSourceRange(start:block.contentRange.start+cell.range.start,length:original.utf8.count)
                                return session.update(range:global,original:original,replacement:value)
                            },onFocus:{session.focusedBlock=block.id},onAttachment:{_,_ in
                                Task {await session.selectSource(path:session.path,line:String(decoding:Array(session.source.utf8).prefix(block.range.start),as:UTF8.self).components(separatedBy:"\n").count)}
                            }).padding(8).frame(minWidth:140,maxWidth:220).background(Color(uiColor:.systemBackground))
                        }
                    }
                }
            }.padding(1).background(Color(uiColor:.separator))
        }
    }
}
struct LaTeXFigurePreview:View {
    @Bindable var session:LaTeXEditorSession
    var block:LaTeXBlock
    @State private var image:UIImage?
    var body:some View {
        VStack(spacing:8) {
            if let image {Image(uiImage:image).resizable().scaledToFit().frame(maxHeight:320)}
            else {Image(systemName:"photo").font(.largeTitle).foregroundStyle(.secondary)}
            if let command=LaTeXParser.parse(block.content).commands.first(where:{$0.name=="caption"}),let argument=command.arguments.last {
                LaTeXRichTextEditor(source:session.editableText(in:.init(start:block.contentRange.start+argument.contentRange.start,length:argument.contentRange.length)),fontSize:15,formulaRenderer:session.formulaRenderer,onChange:{original,value in
                    session.update(range:.init(start:block.contentRange.start+argument.contentRange.start,length:original.utf8.count),original:original,replacement:value)
                },onFocus:{session.focusedBlock=block.id},onAttachment:{_,_ in})
            }
        }.task(id:block.content) {
            let commands=LaTeXParser.parse(block.content).commands
            guard let value=commands.first(where:{$0.name=="includegraphics"})?.arguments.last?.value else{return}
            var path=value
            if value.hasPrefix("\\detokenize{"),value.hasSuffix("}") {path=String(value.dropFirst(12).dropLast())}
            let candidates=[path,path+".png",path+".jpg",path+".jpeg"]
            guard let selected=candidates.first(where:{candidate in session.manifest?.files.contains(where:{$0.path==candidate})==true}),
                  let url=try? LaTeXPath.child(selected,root:session.store.root.appendingPathComponent("Source")) else{return}
            image=await Task.detached {
                guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let cg=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:1200,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else{return Optional<UIImage>.none}
                return UIImage(cgImage:cg)
            }.value
        }
    }
}
#endif
