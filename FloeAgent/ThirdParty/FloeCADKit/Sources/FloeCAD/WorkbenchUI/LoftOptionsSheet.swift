import SwiftUI

/// Same sheet from the existing loftBar and the existing History edit action.
/// Draft changes stay local until Apply; graph changes use one service edit.
struct LoftOptionsSheet: View {
    @Bindable var viewModel: EditorViewModel
    let featureID: FeatureID?
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [CADLoftSectionRow]=[]
    @State private var choices: [CADLoftSectionChoice]=[]
    @State private var ruled=false
    @State private var generation=0
    @State private var failure: String?
    @State private var details=""
    private func text(_ suffix: String,_ fallback: String) -> String { FloeCADStrings.text("cad.loftSurface."+suffix,fallback) }
    private var valid: Bool {
        rows.count >= 2 && rows.count <= 64
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
                if let failure {
                    Section {
                        Text(failure).foregroundStyle(.orange).accessibilityIdentifier("CADLoftFailure")
                        if !details.isEmpty { DisclosureGroup(text("details","Details")) { Text(details).font(.footnote) } }
                    }
                }
            }
            .accessibilityIdentifier("CADLoftOptionsForm")
            .navigationTitle(FloeCADStrings.text("cad.ui.tool.loft","Loft"))
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(FloeCADStrings.text("cad.ui.common.cancel","Cancel")) { dismiss() } }
                ToolbarItem(placement:.confirmationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.apply","Apply"),action:apply)
                        .disabled(!valid).accessibilityIdentifier("CADLoftOptionsApply")
                }
            }
        }
        .onAppear(perform:load).presentationDetents([.large])
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
        if let id=featureID,case let .loft(sections,_,definition)?=viewModel.session.document.features.node(id)?.kind {
            rows=sections.map { CADLoftSectionRow(reference:$0) };ruled=definition?.ruled ?? false
            do { try (definition ?? LoftDefinition()).requireSupported(sectionCount:sections.count) }
            catch { failure=text("failed","Couldn't apply these settings. Your design is unchanged.");details=error.localizedDescription }
        } else if let context=viewModel.toolContext,case .loft=context.kind {
            ruled=context.loftRuled
            rows=context.loftProfiles.map { section in
                CADLoftSectionRow(reference:ProfileRef(sketchID:section.sketchID,
                    entityIDs:Array(section.profile.sourceEntityIDs),holeEntityIDs:section.holes.map { Array($0.sourceEntityIDs) },
                    seedPoint:section.profile.interiorPoint))
            }
        }
    }
    private func apply() {
        guard viewModel.session.changeCount == generation else {
            failure=text("stale","The design changed. Reopen these settings.");return
        }
        if let id=featureID {
            let reply=viewModel.applyNativeLoftSettings(id,sections:rows.map(\.reference),ruled:ruled,generation:generation)
            if reply["ok"] as? Bool == true { viewModel.session.save();dismiss() }
            else { failure=text("failed","Couldn't apply these settings. Your design is unchanged.")
                details=(reply["details"] as? [String] ?? []).joined(separator:"\n") }
        } else if viewModel.configureNativeLoftDraft(sections:rows.map(\.reference),ruled:ruled,expectedChangeCount:generation) {
            dismiss()
        } else { failure=text("failed","Couldn't apply these settings. Your design is unchanged.") }
    }
}
