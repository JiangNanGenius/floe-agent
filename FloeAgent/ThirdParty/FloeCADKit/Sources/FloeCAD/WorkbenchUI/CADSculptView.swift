// SPDX-License-Identifier: MPL-2.0
import SwiftUI

struct CADSculptPanel:View {
    let document:FloeCADDocument
    @Bindable var viewModel:EditorViewModel
    let selectedBodyIDs:[UUID]
    @Environment(\.dismiss) private var dismiss
    @State private var choice:UUID?
    @State private var busy=false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    private func t(_ key:String,_ fallback:String) -> String { FloeCADStrings.text("cad.sculpt."+key,fallback) }
    private var choices:[Body] {
        document.session.document.bodies.filter { body in
            guard body.brep==nil,body.surfaceBRep==nil,body.uvData==nil,body.render.texcoords==nil,body.materialFaceBindings.isEmpty else { return false }
            let graph=document.session.document.features
            guard let node=graph.nodes.prefix(graph.rollbackIndex ?? graph.nodes.count).last(where:{ !$0.suppressed && $0.outputBodyIDs.contains(body.id) }),case .polygonCage=node.kind else { return false };return true
        }
    }
    var body:some View {
        PanelSection(title:t("title","Sculpt")) {
            Picker(t("mesh","Mesh"),selection:$choice) {
                Text(t("choose","Choose an editable mesh")).tag(UUID?.none)
                ForEach(choices) { Text($0.name).tag(Optional($0.id.raw)) }
            }.accessibilityIdentifier("CADSculptBody")
            Button(t("start","Start sculpting"),action:start).disabled(choice==nil || busy || document.isReadOnly)
                .accessibilityIdentifier("CADSculptStart")
            Text(t("entryHelp","Use an editable polygon mesh without face textures. Apple Pencil pressure controls the brush; two fingers move the view."))
                .font(.caption).foregroundStyle(.secondary)
            if busy { ProgressView() }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
        }
        .onAppear { choice=viewModel.polygonCageEditingBody?.raw ?? selectedBodyIDs.first(where:{ id in choices.contains { $0.id.raw==id } }) ?? choices.first?.id.raw }
        .onChange(of:document.session.changeCount) { _,_ in if choice==nil { choice=choices.first?.id.raw } }
        .onDisappear { task?.cancel() }
    }
    private func start() {
        guard let raw=choice,let active=CADPolygonMeshService.currentCage(in:document.session,bodyID:BodyID(raw:raw)),!busy else { return }
        busy=true;failure=nil
        task=Task { @MainActor in
            defer { busy=false;task=nil }
            if active.definition.sculpt==nil {
                let reply=await viewModel.sculptActionHandler?("sculpt.begin",["bodyID":raw.uuidString,"cageDigest":active.definition.digest,"expectedChangeCount":document.session.changeCount])
                guard !Task.isCancelled else { return }
                guard reply?["ok"] as? Bool == true else { failure=t("failed","Couldn't apply the stroke. Your mesh is unchanged.");return }
                if reply?["saved"] as? Bool == false { failure=t("saveFailed","The mesh changed but couldn't be saved. Try saving again.");return }
            }
            guard !Task.isCancelled,!document.isClosed else { return }
            viewModel.beginSculptEditing(BodyID(raw:raw));dismiss()
        }
    }
}
struct CADSculptHUD:View {
    @Bindable var viewModel:EditorViewModel
    @State private var task:Task<Void,Never>?
    private func t(_ key:String,_ fallback:String) -> String { FloeCADStrings.text("cad.sculpt."+key,fallback) }
    var body:some View {
        VStack(spacing:8) {
            HStack {
                Text(t("title","Sculpt")).font(.headline)
                Spacer()
                Button(t("done","Done")) { task?.cancel();viewModel.endSculptEditing() }.accessibilityIdentifier("CADSculptDone")
            }
            Picker(t("brush","Brush"),selection:$viewModel.sculptBrush.mode) {
                Text(t("draw","Draw")).tag(CADSculptBrush.Mode.inflate)
                Text(t("smooth","Smooth")).tag(CADSculptBrush.Mode.smooth)
                Text(t("mask","Mask")).tag(CADSculptBrush.Mode.mask)
                Text(t("unmask","Unmask")).tag(CADSculptBrush.Mode.unmask)
            }.pickerStyle(.segmented).disabled(viewModel.sculptBusy || viewModel.sculptHasStroke).accessibilityIdentifier("CADSculptBrush")
            HStack {
                Text(t("radius","Radius"))
                ExpressionValueField(placeholder:"mm",value:$viewModel.sculptBrush.radius,clamp:1e-4...10000,identifier:"CADSculptRadius")
                Text("mm").foregroundStyle(.secondary)
                Toggle(t("invert","Invert"),isOn:$viewModel.sculptBrush.inverted).accessibilityIdentifier("CADSculptInvert")
            }.disabled(viewModel.sculptBusy || viewModel.sculptHasStroke)
            HStack {
                Text(t("strength","Strength"))
                Slider(value:$viewModel.sculptBrush.strength,in:0...1).accessibilityIdentifier("CADSculptStrength")
            }.disabled(viewModel.sculptBusy || viewModel.sculptHasStroke)
            if let state=viewModel.activeSculptCage?.definition.sculpt {
                HStack {
                    Picker(t("level","Level"),selection:Binding(get:{ state.activeLevel },set:{ if $0 != state.activeLevel { run("sculpt.level",["level":$0]) } })) {
                        ForEach(state.levels.indices,id:\.self) { index in Text("\(index)").tag(index) }
                    }.accessibilityValue(Text("\(state.activeLevel)"))
                        .accessibilityIdentifier("CADSculptLevel")
                    Button(t("subdivide","Subdivide")) { run("sculpt.subdivide") }
                        .disabled(state.levels.count>=4 || state.activeLevel != state.levels.count-1).accessibilityIdentifier("CADSculptSubdivide")
                    Button(t("clearMask","Clear mask")) { run("sculpt.mask.clear") }.accessibilityIdentifier("CADSculptClearMask")
                }.disabled(viewModel.sculptBusy || viewModel.sculptHasStroke)
            }
            HStack {
                Button(FloeCADStrings.text("cad.ui.common.undo","Undo")) { viewModel.cancelSculptStroke();viewModel.session.undo();viewModel.refreshSculptDisplay() }
                    .disabled(!viewModel.session.undoStack.canUndo || viewModel.sculptBusy).accessibilityIdentifier("CADSculptUndo")
                Button(FloeCADStrings.text("cad.ui.common.redo","Redo")) { viewModel.cancelSculptStroke();viewModel.session.redo();viewModel.refreshSculptDisplay() }
                    .disabled(!viewModel.session.undoStack.canRedo || viewModel.sculptBusy).accessibilityIdentifier("CADSculptRedo")
                Spacer()
                if viewModel.sculptBusy { ProgressView().accessibilityIdentifier("CADSculptBusy") }
            }
            if viewModel.sculptAppliedGeneration==viewModel.session.changeCount {
                Text(t("applied","Stroke applied")+" \(viewModel.sculptStrokeCount)").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("CADSculptApplied")
            }
            if let message=viewModel.sculptMessage { Text(message).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("CADSculptMessage") }
        }
        .padding(12).frame(maxWidth:440).background(.regularMaterial,in:RoundedRectangle(cornerRadius:14))
        .padding(.horizontal,12).padding(.bottom,12).accessibilityElement(children:.contain).accessibilityIdentifier("CADSculptHUD")
        .onChange(of:viewModel.session.changeCount) { _,_ in
            if viewModel.activeSculptCage==nil { viewModel.endSculptEditing();return }
            if let draft=viewModel.sculptDraft,draft.generation != viewModel.session.changeCount { viewModel.cancelSculptStroke() }
            if !viewModel.sculptBusy { viewModel.refreshSculptDisplay() }
        }
        .onDisappear { task?.cancel();viewModel.cancelSculptStroke() }
    }
    private func run(_ action:String,_ args:[String:Any]=[:]) {
        guard task==nil else { return }
        task=Task { @MainActor in defer { task=nil };_ = await viewModel.performSculptAction(action,extra:args) }
    }
}
