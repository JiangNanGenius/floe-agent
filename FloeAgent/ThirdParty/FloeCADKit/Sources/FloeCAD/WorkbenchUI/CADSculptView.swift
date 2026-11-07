// SPDX-License-Identifier: MPL-2.0
import SwiftUI

struct CADSculptPanel:View {
    let document:FloeCADDocument
    @Bindable var viewModel:EditorViewModel
    let selectedBodyIDs:[UUID]
    @Binding var allowMeshConversion:Bool
    @Environment(\.dismiss) private var dismiss
    @State private var choice:UUID?
    @State private var busy=false
    @State private var failure:String?
    @State private var diagnostic:String?
    @State private var task:Task<Void,Never>?
    private func t(_ key:String,_ fallback:String) -> String { FloeCADStrings.text("cad.sculpt."+key,fallback) }
    // Show actual source bodies, including imported render meshes that have
    // not acquired a polygon-cage feature yet. Unsupported sources stay
    // addressable so the user sees the exact preparation limitation.
    private var choices:[Body] { document.session.document.bodies }
    private var selected:Body? { choices.first { $0.id.raw==choice } }
    private var needsCapture:Bool {
        guard let selected else { return false }
        return CADPolygonMeshService.currentCage(in:document.session,bodyID:selected.id)==nil
    }
    private var preparationIssue:CADPolygonMeshService.CaptureIssue? {
        guard let selected else { return nil }
        let issue=CADPolygonMeshService.captureIssue(for:selected)
        // Existing sculpt levels can exceed the source-capture limit.
        return !needsCapture && issue == .triangleLimit ? nil:issue
    }
    private var canStart:Bool {
        selected != nil && preparationIssue==nil && !busy && !document.isReadOnly
            && (selected?.brep==nil || allowMeshConversion)
    }
    var body:some View {
        PanelSection(title:t("title","Sculpt")) {
            Picker(t("mesh","Mesh"),selection:$choice) {
                Text(t("chooseBody","Choose a body")).tag(UUID?.none)
                ForEach(choices) { Text($0.name).tag(Optional($0.id.raw)) }
            }.disabled(busy).accessibilityIdentifier("CADSculptBody")
            if selected?.brep != nil {
                Toggle(t("allowConversion","Convert the selected solid to a mesh"),isOn:$allowMeshConversion)
                    .disabled(busy || document.isReadOnly).accessibilityIdentifier("CADSculptAllowConversion")
            }
            Button(needsCapture ? t("prepareStart","Prepare and start sculpting"):t("start","Start sculpting"),action:start)
                .disabled(!canStart).accessibilityIdentifier("CADSculptStart")
            if choices.isEmpty {
                Text(t("empty","Import a mesh or create a body to start sculpting."))
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("CADSculptPreparationHint")
            } else if let issue=preparationIssue {
                Text(issueText(issue)).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("CADSculptPreparationHint")
            } else if selected?.brep != nil && !allowMeshConversion {
                Text(t("conversionNeeded","Enable mesh conversion to prepare this solid; Undo can restore it."))
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("CADSculptPreparationHint")
            }
            Text(t("prepareHelp","Imported meshes are prepared for sculpting first. Apple Pencil pressure controls the brush; two fingers move the view."))
                .font(.caption).foregroundStyle(.secondary)
            if busy { ProgressView() }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("CADSculptPreparationFailure") }
            if let diagnostic,!diagnostic.isEmpty {
                DisclosureGroup(FloeCADStrings.text("cad.ui.common.details","Details")) {
                    Text(diagnostic).font(.caption).textSelection(.enabled)
                }
            }
        }
        .onAppear { chooseSourceIfNeeded() }
        .onChange(of:document.session.changeCount) { _,_ in chooseSourceIfNeeded() }
        .onDisappear { task?.cancel() }
    }
    private func issueText(_ issue:CADPolygonMeshService.CaptureIssue) -> String {
        switch issue {
        case .openSurface: return t("openSurface","Open CAD surfaces cannot be prepared for sculpting.")
        case .triangleLimit: return t("captureLimit","This mesh exceeds the preparation limit. Use Mesh → Simplify before sculpting.")
        case .faceAttributes: return t("captureAttributes","Meshes with UVs or face textures cannot be prepared yet. The source is kept.")
        }
    }
    private func chooseSourceIfNeeded() {
        if let choice,choices.contains(where:{ $0.id.raw==choice }) { return }
        choice=(viewModel.polygonCageEditingBody?.raw).flatMap { id in choices.contains(where:{ $0.id.raw==id }) ? id:nil }
            ?? selectedBodyIDs.first(where:{ id in choices.contains { $0.id.raw==id } })
            ?? choices.first(where:{ $0.brep==nil && CADPolygonMeshService.captureIssue(for:$0)==nil })?.id.raw
            ?? choices.first?.id.raw
    }
    private func accepted(_ reply:[String:Any]) -> Bool {
        guard reply["ok"] as? Bool == true else {
            failure=t("prepareFailed","Couldn't prepare this body for sculpting.")
            diagnostic=reply["message"] as? String;return false
        }
        if reply["saved"] as? Bool == false {
            failure=t("saveFailed","The mesh changed but couldn't be saved. Try saving again.");return false
        }
        return true
    }
    private func start() {
        guard let selected,canStart else { return }
        guard let action=viewModel.sculptActionHandler else {
            failure=t("serviceUnavailable","Sculpting is unavailable for this document. Reopen it and try again.");return
        }
        let raw=selected.id.raw,conversionAllowed=allowMeshConversion
        busy=true;failure=nil;diagnostic=nil
        task=Task { @MainActor in
            defer { busy=false;task=nil }
            guard !Task.isCancelled,!document.isClosed else { return }
            if CADPolygonMeshService.currentCage(in:document.session,bodyID:BodyID(raw:raw))==nil {
                var args:[String:Any]=["bodyID":raw.uuidString]
                if selected.brep != nil { args["forceMesh"]=conversionAllowed }
                let reply=await action("topology.capture",args)
                guard !Task.isCancelled,!document.isClosed,accepted(reply) else { return }
            }
            guard let active=CADPolygonMeshService.currentCage(in:document.session,bodyID:BodyID(raw:raw)) else {
                failure=t("sourceChanged","The selected body changed. Choose it again.");return
            }
            if active.definition.sculpt==nil {
                let reply=await action("sculpt.begin",["bodyID":raw.uuidString,"cageDigest":active.definition.digest,
                    "expectedChangeCount":document.session.changeCount])
                guard !Task.isCancelled,!document.isClosed,accepted(reply) else { return }
            }
            guard !Task.isCancelled,!document.isClosed else { return }
            viewModel.beginSculptEditing(BodyID(raw:raw))
            guard viewModel.sculptEditingBody==BodyID(raw:raw) else {
                failure=t("sourceChanged","The selected body changed. Choose it again.");return
            }
            dismiss()
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
