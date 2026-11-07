// SPDX-License-Identifier: MPL-2.0
import Foundation
import SwiftUI
import FloeHeavyEditorSupport
public enum FontWorkbench {
    public static var descriptor: HeavyEditorDescriptor {
        HeavyEditorDescriptor(kind:.font,title:EditorText.t("字体设计","Font design"),symbol:"character.textbox",
            resourceRoot:Bundle.module.url(forResource:"Web",withExtension:nil)!,projectExtension:"floefont",
            importExtensions:["floefont","ttf","otf","woff","woff2","svg","ufo","zip","designspace"])
    }
    public static func makeDocument(title:String=EditorText.t("新字体","New typeface"),id:UUID=UUID())->HeavyEditorDocument {
        HeavyEditorDocument(id:id,kind:.font,title:title,content:.object([
            "title":.string(title),"info":.object(["familyName":.string(title),"styleName":.string("Regular"),"unitsPerEm":.number(1000),"ascender":.number(800),"descender":.number(-200),"xHeight":.number(500),"capHeight":.number(700)]),
            "glyphs":.array([]),"kerning":.object([:]),"groups":.object([:]),"features":.string(""),"axes":.array([]),"masters":.array([]),"instances":.array([])
        ]))
    }
    @MainActor public static func open(directory:URL,documentID:UUID,owner:HeavyEditorOwner,hooks:HeavyEditorHostHooks) async throws->HeavyEditorController {
        let store=try HeavyEditorProjectStore(directory:directory,documentID:documentID,kind:.font)
        let compiler=try FontCompilerService(scratchRoot:directory.appendingPathComponent(".compilation",isDirectory:true))
        return try HeavyEditorController(descriptor:descriptor,document:await store.read(),store:store,owner:owner,hooks:hooks,nativeExtension:compiler.nativeExtension)
    }
}
public struct FontEditorView:View {
    private let controller:HeavyEditorController
    private let onClose:()->Void
    public init(controller:HeavyEditorController,onClose:@escaping()->Void={}){self.controller=controller;self.onClose=onClose}
    public var body:some View{HeavyEditorView(controller:controller,onClose:onClose)}
}
