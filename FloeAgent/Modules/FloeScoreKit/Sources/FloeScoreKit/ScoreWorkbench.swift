// SPDX-License-Identifier: MPL-2.0
import Foundation
import SwiftUI
import FloeHeavyEditorSupport
public enum ScoreWorkbench {
    public static var descriptor:HeavyEditorDescriptor {
        HeavyEditorDescriptor(kind:.score,title:EditorText.t("乐谱","Score"),symbol:"music.note.list",
            resourceRoot:Bundle.module.url(forResource:"Web",withExtension:nil)!,projectExtension:"floescore",
            importExtensions:["floescore","musicxml","xml","mxl","mid","midi"])
    }
    public static func makeDocument(title:String=EditorText.t("新乐谱","New score"),id:UUID=UUID())->HeavyEditorDocument {
        let xml="""
        <?xml version="1.0" encoding="UTF-8"?><score-partwise version="4.0"><work><work-title>New score</work-title></work><identification><creator type="composer"></creator></identification><part-list><score-part id="P1"><part-name>Piano</part-name><part-abbreviation>Pno.</part-abbreviation><score-instrument id="I1"><instrument-name>Piano</instrument-name></score-instrument><midi-instrument id="I1"><midi-channel>1</midi-channel><midi-program>1</midi-program></midi-instrument></score-part></part-list><part id="P1"><measure number="1"><attributes><divisions>960</divisions><key><fifths>0</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes><direction><direction-type><metronome><beat-unit>quarter</beat-unit><per-minute>120</per-minute></metronome></direction-type><sound tempo="120"/></direction><note><rest measure="yes"/><duration>3840</duration><voice>1</voice><type>whole</type></note><barline location="right"><bar-style>light-heavy</bar-style></barline></measure></part></score-partwise>
        """
        return HeavyEditorDocument(id:id,kind:.score,title:title,content:.object(["title":.string(title),"xml":.string(xml),"layout":.object(["paper":.string("A4_P"),"continuous":.bool(false),"zoom":.number(1)]),"playback":.object(["tempoScale":.number(1),"loop":.bool(false),"metronome":.bool(false),"parts":.object([:])])]))
    }
    @MainActor public static func open(directory:URL,documentID:UUID,owner:HeavyEditorOwner,hooks:HeavyEditorHostHooks,playback:ScorePlaybackAdapter? = nil)async throws->HeavyEditorController {
        let store=try HeavyEditorProjectStore(directory:directory,documentID:documentID,kind:.score)
        let service = ScorePlaybackService()
        let native = playback?.nativeExtension ?? service.nativeExtension
        return try HeavyEditorController(descriptor:descriptor,document:await store.read(),store:store,owner:owner,hooks:hooks,nativeExtension:native)
    }
}
public struct ScoreEditorView:View {
    private let controller:HeavyEditorController
    private let onClose:()->Void
    public init(controller:HeavyEditorController,onClose:@escaping()->Void={}){self.controller=controller;self.onClose=onClose}
    public var body:some View{HeavyEditorView(controller:controller,onClose:onClose)}
}
