import SwiftUI

struct SurfaceOptionsSheet: View {
    @Bindable var viewModel: EditorViewModel
    let featureID: FeatureID?
    @Environment(\.dismiss) private var dismiss
    @State private var initial: CADSurfaceDefinition?
    @State private var operation: CADSurfaceDefinition.Operation = .loft
    @State private var sections: [CADSurfaceSectionRow]=[]
    @State private var sources: [CADSurfaceInputChoice]=[]
    @State private var edges: [CADSurfaceEdgeChoice]=[]
    @State private var lockedSource: BodyID?
    @State private var sourceIDs: [BodyID]=[]
    @State private var ruled=false
    @State private var acrossStart=10.0
    @State private var acrossEnd=90.0
    @State private var alongStart=10.0
    @State private var alongEnd=90.0
    @State private var thickness=1.0
    @State private var reverse=false
    @State private var requireClosed=false
    @State private var generation=0
    @State private var checked: CADSurfaceInputChoice?
    @State private var failure: String?
    @State private var details=""
    private func text(_ key: String,_ fallback: String) -> String { FloeCADStrings.text("cad.loftSurface."+key,fallback) }
    private func label(_ operation: CADSurfaceDefinition.Operation) -> String {
        switch operation {
        case .loft:return text("surfaceLoft","Create surface")
        case .trim:return text("trim","Trim")
        case .patch:return text("patch","Fill planar openings")
        case .sew:return text("sew","Sew surfaces")
        case .thicken:return text("thicken","Thicken")
        }
    }
    private var available: [CADSurfaceDefinition.Operation] {
        CADLoftSurfaceUIModel.operations(openEdges:edges,sources:sources)
    }
    private var eligibleSources: [CADSurfaceInputChoice] {
        sources.filter { source in
            guard source.valid else { return false }
            if let lockedSource,operation != .sew,source.id != lockedSource { return false }
            switch operation {
            case .trim:return source.canTrim
            case .patch:return source.canPatch
            default:return true
            }
        }
    }
    private var selected: [CADSurfaceInputChoice] { sourceIDs.compactMap { id in eligibleSources.first { $0.id == id } } }
    private var settingsValid: Bool {
        if operation == .loft {
            guard (2...64).contains(sections.count),let count=sections.first?.path.segments.count,count > 0,
                  sections.allSatisfy({ $0.path.segments.count == count }) else { return false }
            return sections.allSatisfy { row in row.path.segments.allSatisfy { segment in
                edges.contains { $0.sketchID == segment.sketchID && $0.entityID == segment.entityID }
            } }
        }
        guard (operation == .sew ? selected.count >= 2 : selected.count == 1) else { return false }
        if operation == .trim {
            return [acrossStart,acrossEnd,alongStart,alongEnd].allSatisfy(\.isFinite)
                && acrossStart >= 0 && acrossEnd <= 100 && acrossStart < acrossEnd
                && alongStart >= 0 && alongEnd <= 100 && alongStart < alongEnd
        }
        if operation == .thicken { return thickness.isFinite && (0.00001...10000).contains(thickness) }
        return true
    }
    var body: some View {
        NavigationStack {
            Form {
                if featureID == nil {
                    Picker(text("operation","Operation"),selection:$operation) {
                        ForEach(available,id:\.rawValue) { Text(label($0)).tag($0).accessibilityIdentifier("CADSurfaceOperationOption-\($0.rawValue)") }
                    }
                    .accessibilityIdentifier("CADSurfaceOperation")
                } else { LabeledContent(text("operation","Operation"),value:label(operation)) }
                if available.isEmpty && featureID == nil {
                    Text(text("noInputs","Draw open curves on two sketch planes, or select an exact surface.")).foregroundStyle(.secondary)
                } else if operation == .loft { sectionEditor }
                else { sourceEditor }
                if operation == .trim { trimEditor }
                if operation == .patch { Text(text("planarHelp","Fills closed planar openings. Other boundaries are left unchanged if the operation fails.")).font(.footnote).foregroundStyle(.secondary) }
                if operation == .sew {
                    Toggle(text("requireClosed","Require a closed surface"),isOn:$requireClosed)
                        .accessibilityIdentifier("CADSurfaceRequireClosed")
                }
                if operation == .thicken {
                    LabeledContent(text("thickness","Thickness (mm)")) {
                        TextField(text("thickness","Thickness (mm)"),value:$thickness,format:.number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("CADSurfaceThickness")
                    }
                    Toggle(text("reverse","Reverse side"),isOn:$reverse).accessibilityIdentifier("CADSurfaceReverse")
                }
                if operation != .loft { inspection }
                if let failure {
                    Section {
                        Text(failure).foregroundStyle(.orange).accessibilityIdentifier("CADSurfaceFailure")
                        if !details.isEmpty { DisclosureGroup(text("details","Details")) { Text(details).font(.footnote) } }
                    }
                }
            }
            .accessibilityIdentifier("CADSurfaceOptionsForm")
            .navigationTitle(FloeCADStrings.text("cad.material.section.surface","Surface"))
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(FloeCADStrings.text("cad.ui.common.cancel","Cancel")) { dismiss() } }
                ToolbarItem(placement:.confirmationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.apply","Apply"),action:apply)
                        .disabled(!settingsValid).accessibilityIdentifier("CADSurfaceApply")
                }
            }
        }
        .onAppear(perform:load)
        .onChange(of:operation) { _,_ in checked=nil;chooseDefaultSources() }
        .onChange(of:sourceIDs) { _,_ in checked=nil }
        .presentationDetents([.large])
    }
    private var sectionEditor: some View {
        Section(text("openSections","Open sections")) {
            ForEach(Array(sections.enumerated()),id:\.element.id) { index,row in openSection(index,row) }
            Button(text("addSection","Add section")) {
                if let edge=edges.first { sections.append(.init(path:SweepPathDefinition(segments:[.init(sketchID:edge.sketchID,entityID:edge.entityID)]))) }
            }.disabled(edges.isEmpty || sections.count >= 64).accessibilityIdentifier("CADSurfaceAddSection")
            Toggle(text("ruled","Straight between sections"),isOn:$ruled).accessibilityIdentifier("CADSurfaceRuled")
        }
    }
    private func openSection(_ index: Int,_ row: CADSurfaceSectionRow) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Text("\(text("section","Section")) \(index+1)").font(.subheadline.weight(.semibold))
            ForEach(Array(row.path.segments.enumerated()),id:\.offset) { edgeIndex,segment in
                curveRow(index,edgeIndex,segment,row:row)
            }
            HStack {
                Button(text("addCurve","Add curve")) { addCurve(to:index) }.disabled(row.path.segments.count >= 256)
                Spacer()
                Button { sections=CADLoftSurfaceUIModel.moved(sections,from:index,by:-1) } label: { Image(systemName:"arrow.up").frame(minWidth:44,minHeight:44) }.disabled(index == 0)
                    .accessibilityLabel(text("moveSectionUp","Move section up")).accessibilityIdentifier("CADSurfaceMoveSectionUp-\(index)")
                Button { sections=CADLoftSurfaceUIModel.moved(sections,from:index,by:1) } label: { Image(systemName:"arrow.down").frame(minWidth:44,minHeight:44) }.disabled(index+1 == sections.count)
                    .accessibilityLabel(text("moveSectionDown","Move section down"))
                Button(role:.destructive) { sections.removeAll { $0.id == row.id } } label: { Image(systemName:"trash").frame(minWidth:44,minHeight:44) }.disabled(sections.count <= 2)
                    .accessibilityLabel(text("removeSection","Remove section"))
            }.buttonStyle(.borderless)
        }
    }
    private func curveRow(_ index: Int,_ edgeIndex: Int,_ segment: SweepPathDefinition.Segment,row: CADSurfaceSectionRow) -> some View {
        VStack {
            HStack {
                Picker(text("curve","Curve"),selection:Binding(get:{ segment.sketchID.raw.uuidString+":"+segment.entityID.uuidString },
                    set:{ selectCurve($0,section:index,edge:edgeIndex) })) {
                    ForEach(curveChoices(row:row,edge:edgeIndex)) { Text($0.title).tag($0.id) }
                }.accessibilityIdentifier("CADSurfaceSection-\(index)-Curve-\(edgeIndex)")
                Toggle(text("reverseCurve","Reverse curve"),isOn:Binding(get:{ segment.reversed },set:{ value in
                    guard sections.indices.contains(index),sections[index].path.segments.indices.contains(edgeIndex) else { return }
                    sections[index].path.segments[edgeIndex].reversed=value
                })).labelsHidden().accessibilityIdentifier("CADSurfaceSection-\(index)-Reverse-\(edgeIndex)")
            }
            HStack {
                Button { moveEdge(index,edgeIndex,-1) } label: { Image(systemName:"arrow.up").frame(minWidth:44,minHeight:44) }
                    .disabled(edgeIndex == 0).accessibilityLabel(text("moveUp","Move up"))
                Button { moveEdge(index,edgeIndex,1) } label: { Image(systemName:"arrow.down").frame(minWidth:44,minHeight:44) }
                    .disabled(edgeIndex+1 == row.path.segments.count).accessibilityLabel(text("moveDown","Move down"))
                Spacer()
                Button(role:.destructive) {
                    guard sections.indices.contains(index),sections[index].path.segments.indices.contains(edgeIndex) else { return }
                    sections[index].path.segments.remove(at:edgeIndex)
                } label: { Image(systemName:"minus.circle").frame(minWidth:44,minHeight:44) }
                .disabled(row.path.segments.count <= 1).accessibilityLabel(text("remove","Remove"))
            }.buttonStyle(.borderless)
        }
    }
    private func curveChoices(row: CADSurfaceSectionRow,edge: Int) -> [CADSurfaceEdgeChoice] {
        edges.filter { candidate in
            guard edge == 0 || candidate.sketchID == row.path.segments.first?.sketchID else { return false }
            return !row.path.segments.enumerated().contains { index,segment in
                index != edge && candidate.sketchID == segment.sketchID && candidate.entityID == segment.entityID
            }
        }
    }
    private func selectCurve(_ id: String,section: Int,edge: Int) {
        guard sections.indices.contains(section),sections[section].path.segments.indices.contains(edge),
              let choice=edges.first(where:{ $0.id == id }) else { return }
        if edge == 0 && sections[section].path.segments[0].sketchID != choice.sketchID {
            sections[section].path=SweepPathDefinition(segments:[.init(sketchID:choice.sketchID,entityID:choice.entityID)])
        } else {
            let reversed=sections[section].path.segments[edge].reversed
            sections[section].path.segments[edge] = .init(sketchID:choice.sketchID,entityID:choice.entityID,reversed:reversed)
        }
    }
    private var sourceEditor: some View {
        Section(text("surfaces","Surfaces")) {
            if operation == .sew {
                ForEach(eligibleSources) { source in
                    Toggle(source.title,isOn:Binding(get:{ sourceIDs.contains(source.id) },set:{ selected in
                        if selected { if !sourceIDs.contains(source.id) { sourceIDs.append(source.id) } }
                        else { sourceIDs.removeAll { $0 == source.id } }
                    })).disabled(source.id == lockedSource)
                    .accessibilityIdentifier("CADSurfaceSource-\(source.id.raw)")
                }
                ForEach(Array(selected.enumerated()),id:\.element.id) { index,source in
                    HStack {
                        Text("\(index+1). \(source.title)")
                        Spacer()
                        Button { sourceIDs=CADLoftSurfaceUIModel.moved(sourceIDs,from:index,by:-1) } label: { Image(systemName:"arrow.up").frame(minWidth:44,minHeight:44) }.disabled(index == 0 || (lockedSource != nil && index == 1))
                            .accessibilityLabel(text("moveUp","Move up"))
                        Button { sourceIDs=CADLoftSurfaceUIModel.moved(sourceIDs,from:index,by:1) } label: { Image(systemName:"arrow.down").frame(minWidth:44,minHeight:44) }.disabled(index+1 == selected.count || (lockedSource != nil && index == 0))
                            .accessibilityLabel(text("moveDown","Move down"))
                    }.buttonStyle(.borderless)
                }
            } else {
                Picker(text("surface","Surface"),selection:Binding(get:{ sourceIDs.first },set:{ id in sourceIDs=id.map { [$0] } ?? [] })) {
                    Text(text("chooseSurface","Choose a surface")).tag(Optional<BodyID>.none)
                    ForEach(eligibleSources) { Text($0.title).tag(Optional($0.id)) }
                }.disabled(featureID != nil).accessibilityIdentifier("CADSurfaceSource")
            }
        }
    }
    private var trimEditor: some View {
        Section(text("trimArea","Trim area")) {
            percent(text("acrossStart","Across: start (%)"),$acrossStart,"CADSurfaceAcrossStart")
            percent(text("acrossEnd","Across: end (%)"),$acrossEnd,"CADSurfaceAcrossEnd")
            percent(text("alongStart","Along: start (%)"),$alongStart,"CADSurfaceAlongStart")
            percent(text("alongEnd","Along: end (%)"),$alongEnd,"CADSurfaceAlongEnd")
        }
    }
    private func percent(_ label: String,_ value: Binding<Double>,_ identifier: String) -> some View {
        LabeledContent(label) { TextField(label,value:value,format:.number.precision(.fractionLength(0...6)))
            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).accessibilityIdentifier(identifier) }
    }
    private var inspection: some View {
        Section(text("check","Check surface")) {
            Button(text("check","Check surface")) {
                guard viewModel.session.changeCount == generation else { failure=text("stale","The design changed. Reopen these settings.");return }
                let snapshot=viewModel.loftSurfaceUISnapshot(before:featureID)
                sources=snapshot.sources;checked=sourceIDs.first.flatMap { id in sources.first { $0.id == id } }
            }.disabled(selected.isEmpty).accessibilityIdentifier("CADSurfaceCheck")
            if let checked {
                LabeledContent(text("geometry","Geometry"),value:checked.valid ? text("valid","Valid") : text("invalid","Needs repair"))
                LabeledContent(text("closed","Closed"),value:checked.closed ? text("yes","Yes") : text("no","No"))
                    .accessibilityIdentifier("CADSurfaceClosed")
                    .accessibilityValue(checked.closed ? text("yes","Yes") : text("no","No"))
                LabeledContent(text("freeEdges","Open edges"),value:"\(checked.freeEdges)")
                    .accessibilityIdentifier("CADSurfaceFreeEdges").accessibilityValue("\(checked.freeEdges)")
            }
        }
    }
    private func moveEdge(_ index: Int,_ edge: Int,_ delta: Int) {
        guard sections.indices.contains(index) else { return }
        sections[index].path.segments=CADLoftSurfaceUIModel.moved(sections[index].path.segments,from:edge,by:delta)
    }
    private func addCurve(to index: Int) {
        guard sections.indices.contains(index),let sketch=sections[index].path.segments.first?.sketchID,
              let edge=edges.first(where:{ candidate in candidate.sketchID == sketch && !sections[index].path.segments.contains(where:{ $0.entityID == candidate.entityID }) }) else { return }
        sections[index].path.segments.append(.init(sketchID:edge.sketchID,entityID:edge.entityID))
    }
    private func chooseDefaultSources() {
        let retained=sourceIDs.filter { id in eligibleSources.contains { $0.id == id } }
        sourceIDs=operation == .sew ? retained : Array(retained.prefix(1))
        if sourceIDs.isEmpty,featureID == nil,let first=eligibleSources.first { sourceIDs=[first.id] }
    }
    private func load() {
        let snapshot=viewModel.loftSurfaceUISnapshot(before:featureID)
        generation=snapshot.generation;sources=snapshot.sources;edges=snapshot.openEdges
        if let id=featureID,case let .surface(definition)?=viewModel.session.document.features.node(id)?.kind {
            initial=definition;lockedSource=definition.sources.first?.bodyID;operation=definition.operation;sections=definition.sections.map { .init(path:$0) };sourceIDs=definition.sources.map(\.bodyID)
            ruled=definition.ruled;thickness=abs(definition.thickness ?? 1);reverse=(definition.thickness ?? 1) < 0
            requireClosed=definition.requireClosed
            if let trim=definition.trim,let domain=sources.first(where:{ $0.id == sourceIDs.first })?.domain {
                acrossStart=(trim.uMin-domain.uMin)/(domain.uMax-domain.uMin)*100
                acrossEnd=(trim.uMax-domain.uMin)/(domain.uMax-domain.uMin)*100
                alongStart=(trim.vMin-domain.vMin)/(domain.vMax-domain.vMin)*100
                alongEnd=(trim.vMax-domain.vMin)/(domain.vMax-domain.vMin)*100
            }
        } else {
            sourceIDs=sources.filter { viewModel.selection.contains($0.id) }.map(\.id)
            if sourceIDs.count >= 2 { operation = .sew }
            else if sourceIDs.count == 1 { operation = .thicken }
            else { operation=available.first ?? .loft }
            var sketches: [SketchID]=[]
            for edge in edges where !sketches.contains(edge.sketchID) { sketches.append(edge.sketchID) }
            sections=sketches.prefix(2).compactMap { id in edges.first(where:{ $0.sketchID == id }).map {
                CADSurfaceSectionRow(path:SweepPathDefinition(segments:[.init(sketchID:$0.sketchID,entityID:$0.entityID)]))
            } }
        }
        chooseDefaultSources()
    }
    private func apply() {
        guard settingsValid,viewModel.session.changeCount == generation else {
            failure=text("stale","The design changed. Reopen these settings.");return
        }
        do {
            var definition=initial ?? CADSurfaceDefinition(operation:operation)
            if operation == .loft { definition.sections=sections.map(\.path);definition.ruled=ruled }
            else { definition.sources=selected.map(\.reference) }
            if operation == .trim,let domain=selected.first?.domain {
                definition.trim=try CADLoftSurfaceUIModel.trim(domain:domain,across:acrossStart...acrossEnd,along:alongStart...alongEnd)
            }
            if operation == .sew { definition.requireClosed=requireClosed }
            if operation == .thicken { definition.thickness=thickness*(reverse ? -1 : 1) }
            try definition.validate()
            let reply=viewModel.applyNativeSurface(definition,editing:featureID,generation:generation)
            if reply["ok"] as? Bool == true { dismiss() }
            else { failure=text("failed","Couldn't apply these settings. Your design is unchanged.")
                details=(reply["details"] as? [String] ?? []).joined(separator:"\n") }
        } catch { failure=text("failed","Couldn't apply these settings. Your design is unchanged.");details=error.localizedDescription }
    }
}
