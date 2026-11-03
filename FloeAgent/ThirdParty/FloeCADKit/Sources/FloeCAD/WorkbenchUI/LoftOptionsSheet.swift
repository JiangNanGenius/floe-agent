import SwiftUI
import simd

/// Same sheet from the existing loftBar and the existing History edit action.
/// Draft changes stay local until Apply; graph changes use one service edit.
struct LoftOptionsSheet: View {
    @Bindable var viewModel: EditorViewModel
    let featureID: FeatureID?
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [CADLoftSectionRow]=[]
    @State private var choices: [CADLoftSectionChoice]=[]
    @State private var ruled=false
    @State private var initial=LoftDefinition()
    @State private var startDraft=CADLoftBoundaryDraft()
    @State private var endDraft=CADLoftBoundaryDraft()
    private var hasEndpoints:Bool { startDraft.mode>0 || endDraft.mode>0 }
    private var endpointsAllowed:Bool { guide.isEmpty && !ruled && rows.count<=4 && rows.allSatisfy { $0.reference.holeEntityIDs.count<=3 } }
    @State private var guide:[SweepPathDefinition.Segment]=[]
    @State private var guideChoices:[CADSurfaceEdgeChoice]=[]
    @State private var applying=false
    @State private var applyTask:Task<Void,Never>?
    @State private var generation=0
    @State private var failure: String?
    @State private var details=""
    private func text(_ suffix: String,_ fallback: String) -> String { FloeCADStrings.text("cad.loftSurface."+suffix,fallback) }
    private var guideAllowed:Bool {
        !hasEndpoints && rows.count <= 8 && !ruled && rows.allSatisfy { $0.reference.holeEntityIDs.isEmpty }
    }
    private var valid: Bool {
        (!hasEndpoints || endpointsAllowed) && (guide.isEmpty || (guideAllowed && guide.count <= 8)) && rows.count >= 2 && rows.count <= 64
            && Set(rows.map { choiceID($0.reference) }).count == rows.count
            && rows.allSatisfy { row in choices.filter { $0.matches(row.reference) }.count == 1 }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(text("sections","Sections")) {
                    ForEach(Array(rows.enumerated()),id:\.element.id) { index,row in
                        VStack(alignment:.leading,spacing:4) {
                            Picker("\(index+1)",selection:Binding(get:{ choiceID(row.reference) },set:{ selected in
                                guard rows.indices.contains(index),let choice=choices.first(where:{ $0.id == selected }) else { return }
                                rows[index].reference=choice.reference
                            })) {
                                Text(text("missingSection","Choose a section")).tag("")
                                ForEach(choices) { Text($0.title).tag($0.id) }
                            }
                            .accessibilityIdentifier("CADLoftSection-\(index)")
                            HStack {
                                moveButton(index,-1,"arrow.up","moveUp","Move up")
                                moveButton(index,1,"arrow.down","moveDown","Move down")
                                Spacer()
                                Button(role:.destructive) { rows.removeAll { $0.id == row.id } } label: {
                                    Label(text("remove","Remove"),systemImage:"minus.circle")
                                }
                                .disabled(rows.count <= 2).accessibilityIdentifier("CADLoftRemoveSection-\(index)")
                            }
                        }
                    }
                    Button { if let next=choices.first(where:{ choice in !rows.contains { choice.matches($0.reference) } }) {
                        rows.append(CADLoftSectionRow(reference:next.reference))
                    } } label: { Label(text("addSection","Add section"),systemImage:"plus") }
                    .disabled(rows.count >= 64 || choices.allSatisfy { choice in rows.contains { choice.matches($0.reference) } })
                    .accessibilityIdentifier("CADLoftAddSection")
                }
                Section {
                    Toggle(text("ruled","Straight between sections"),isOn:$ruled)
                        .accessibilityIdentifier("CADLoftRuled")
                }
                guideEditor
                if endpointsAllowed || hasEndpoints {
                    CADLoftBoundaryEditor(title:text("startBoundary","Start"),identifier:"CADLoftStart",draft:$startDraft)
                    CADLoftBoundaryEditor(title:text("endBoundary","End"),identifier:"CADLoftEnd",draft:$endDraft)
                }
                if let failure {
                    Section {
                        Text(failure).foregroundStyle(.orange).accessibilityIdentifier("CADLoftFailure")
                        if !details.isEmpty { DisclosureGroup(text("details","Details")) { Text(details).font(.footnote) } }
                    }
                }
            }
            .accessibilityIdentifier("CADLoftOptionsForm").disabled(applying)
            .navigationTitle(FloeCADStrings.text("cad.ui.tool.loft","Loft"))
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(FloeCADStrings.text("cad.ui.common.cancel","Cancel")) { applyTask?.cancel();dismiss() } }
                ToolbarItem(placement:.confirmationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.apply","Apply"),action:apply)
                        .disabled(!valid || applying).accessibilityIdentifier("CADLoftOptionsApply")
                }
            }
        }
        .onAppear(perform:load).presentationDetents([.large])
        .interactiveDismissDisabled(applying)
        .onDisappear { applyTask?.cancel() }
    }
    private var guideEditor:some View {
        Section(text("guide","Guide")) {
            ForEach(Array(guide.enumerated()),id:\.offset) { index,edge in
                VStack {
                    Picker(text("curve","Curve"),selection:Binding(get:{ edge.sketchID.raw.uuidString+":"+edge.entityID.uuidString },set:{ id in
                        guard guide.indices.contains(index),let choice=guideChoices.first(where:{ $0.id == id }) else { return }
                        guide[index] = .init(sketchID:choice.sketchID,entityID:choice.entityID,reversed:guide[index].reversed)
                    })) { ForEach(guideChoices) { Text($0.title).tag($0.id) } }
                    .accessibilityIdentifier("CADLoftGuideCurve-\(index)")
                    Toggle(text("reverseCurve","Reverse curve"),isOn:Binding(get:{ edge.reversed },set:{ value in
                        if guide.indices.contains(index) { guide[index].reversed=value }
                    })).accessibilityIdentifier("CADLoftGuideReverse-\(index)")
                    HStack {
                        Button { guide=CADLoftSurfaceUIModel.moved(guide,from:index,by:-1) } label: { Image(systemName:"arrow.up").frame(minWidth:44,minHeight:44) }.disabled(index == 0)
                            .accessibilityLabel(text("moveUp","Move up")).accessibilityIdentifier("CADLoftGuideMoveUp-\(index)")
                        Button { guide=CADLoftSurfaceUIModel.moved(guide,from:index,by:1) } label: { Image(systemName:"arrow.down").frame(minWidth:44,minHeight:44) }.disabled(index+1 == guide.count)
                            .accessibilityLabel(text("moveDown","Move down"))
                        Spacer()
                        Button(role:.destructive) { guide.remove(at:index) } label: { Image(systemName:"minus.circle").frame(minWidth:44,minHeight:44) }
                            .accessibilityLabel(text("remove","Remove")).accessibilityIdentifier("CADLoftGuideRemove-\(index)")
                    }.buttonStyle(.borderless)
                }.disabled(applying)
            }
            Button(text("addGuideCurve","Add guide curve")) {
                if let choice=guideChoices.first(where:{ choice in !guide.contains { $0.sketchID == choice.sketchID && $0.entityID == choice.entityID } }) {
                    guide.append(.init(sketchID:choice.sketchID,entityID:choice.entityID))
                }
            }.disabled(!guideAllowed || guide.count >= 8 || guideChoices.isEmpty || applying).accessibilityIdentifier("CADLoftAddGuideCurve")
            if !guide.isEmpty {
                Text(text("guideHelp","The guide must meet every section. Use up to eight parallel sections without inner loops. The surface is checked to a tolerance."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if applying { ProgressView(text("applyingGuide","Building loft…")).accessibilityIdentifier("CADLoftBuilding") }
        }
    }
    private func choiceID(_ ref: ProfileRef) -> String {
        let matches=choices.filter { $0.matches(ref) };return matches.count == 1 ? matches[0].id : ""
    }
    private func moveButton(_ index: Int,_ delta: Int,_ image: String,_ key: String,_ fallback: String) -> some View {
        Button { rows=CADLoftSurfaceUIModel.moved(rows,from:index,by:delta) } label: {
            Label(text(key,fallback),systemImage:image).labelStyle(.iconOnly).frame(minWidth:44,minHeight:44)
        }
        .buttonStyle(.borderless).disabled(!rows.indices.contains(index+delta))
        .accessibilityIdentifier("CADLoftMove\(delta < 0 ? "Up" : "Down")-\(index)")
    }
    private func load() {
        let snapshot=viewModel.loftSurfaceUISnapshot();choices=snapshot.closedSections;generation=snapshot.generation
        failure=nil;details=""
        guideChoices=snapshot.openEdges.filter { edge in
            guard let sketch=viewModel.session.document.sketches.first(where:{ $0.id == edge.sketchID }),
                  let entity=sketch.entities.first(where:{ $0.id == edge.entityID }),let curve=try? SketchCurveDefinition(entity) else { return false }
            return CADGuidedLoftSnapshot.accepts(curve)
        }
        if let id=featureID,case let .loft(sections,_,definition)?=viewModel.session.document.features.node(id)?.kind {
            rows=sections.map { CADLoftSectionRow(reference:$0) };ruled=definition?.ruled ?? false
            initial=definition ?? LoftDefinition();guide=initial.guides.first?.segments ?? []
            do { try (definition ?? LoftDefinition()).requireSupported(sectionCount:sections.count) }
            catch { failure=text("failed","Couldn't apply these settings. Your design is unchanged.");details=error.localizedDescription }
        } else if let context=viewModel.toolContext,case .loft=context.kind {
            ruled=context.loftRuled;initial=LoftDefinition(ruled:ruled,guides:context.loftGuides,start:context.loftStart,end:context.loftEnd);guide=context.loftGuides.first?.segments ?? []
            rows=context.loftProfiles.map { section in
                CADLoftSectionRow(reference:ProfileRef(sketchID:section.sketchID,
                    entityIDs:Array(section.profile.sourceEntityIDs),holeEntityIDs:section.holes.map { Array($0.sourceEntityIDs) },
                    seedPoint:section.profile.interiorPoint))
            }
        }
        let selected=rows.compactMap { row in choices.first { $0.matches(row.reference) } }
        let direction:SIMD3<Double>
        if let first=selected.first,let last=selected.last,simd_length(last.plane.origin-first.plane.origin)>1e-9 {
            direction=simd_normalize(last.plane.origin-first.plane.origin)
        } else { direction=SIMD3(0,0,1) }
        startDraft=CADLoftBoundaryDraft(initial.start,direction:direction);endDraft=CADLoftBoundaryDraft(initial.end,direction:direction)
    }
    private func apply() {
        guard viewModel.session.changeCount == generation else {
            failure=text("stale","The design changed. Reopen these settings.");return
        }
        guard valid,!applying else { return }
        var definition=initial;definition.ruled=ruled
        definition.guides=guide.isEmpty ? [] : [SweepPathDefinition(segments:guide)]
        definition.start=startDraft.constraint;definition.end=endDraft.constraint
        let sections=rows.map(\.reference)
        applying=true;failure=nil;details=""
        applyTask=Task { @MainActor in
            defer { applying=false;applyTask=nil }
            if let id=featureID {
                let reply=await viewModel.applyNativeGuidedLoftSettings(id,sections:sections,definition:definition,generation:generation)
                guard !Task.isCancelled else { return }
                if reply["ok"] as? Bool == true { viewModel.session.save();dismiss() }
                else { failure=text("failed","Couldn't apply these settings. Your design is unchanged.")
                    details=(reply["details"] as? [String] ?? []).joined(separator:"\n") }
            } else {
                let ready=await viewModel.configureNativeGuidedLoftDraft(sections:sections,definition:definition,generation:generation)
                guard !Task.isCancelled else { return }
                if ready { dismiss() }
                else { failure=text("failed","Couldn't apply these settings. Your design is unchanged.") }
            }
        }
    }
}
