// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers

extension CADBuildingElement.Kind {
    var title: String { FloeCADStrings.text("cad.building.element.\(rawValue)", rawValue.capitalized) }
}
extension CADBuildingProfessionalAction {
    var title: String {
        switch self {
        case .ifc: return FloeCADStrings.text("cad.building.ifc", "IFC exchange")
        case .structure: return FloeCADStrings.text("cad.building.structure", "Structural study")
        case .mep: return FloeCADStrings.text("cad.building.mep", "MEP coordination")
        case .information: return FloeCADStrings.text("cad.building.information", "Information requirements")
        }
    }
}

/// A dedicated domain workspace over the SAME live CAD document. Tool/plan
/// selection is local to this view; geometry, undo and persistence are shared.
public struct FloeBuildingWorkbenchView: View {
    private enum Mode: String, CaseIterable { case plan, model, drawings }
    private struct Inspection: Identifiable {
        let id = UUID()
        let rows: [CADBuildingCheck]
    }
    let document: FloeCADDocument
    let incomingPlan: CADSketchTransferEnvelope?
    let onProfessionalRequest: ((CADBuildingProfessionalAction) -> Void)?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.cadBuildingProfessionalPresenter) private var professionalPresenter
    @State private var model = CADBuildingDocument()
    @State private var floorID: UUID?
    @State private var mode = Mode.plan
    @State private var drawingWall = false
    @State private var wallStart: [Double]?
    @State private var editedElement: CADBuildingElement?
    @State private var importPlan: CADSketchTransferEnvelope?
    @State private var choosingFile = false
    @State private var loading = false
    @State private var message: String?
    @State private var inspection: Inspection?
    @State private var showSettings = false
    @State private var showElements = false
    @State private var fileImportTask:Task<Void,Never>?
    @State private var fileImportGeneration=UUID()

    public init(document: FloeCADDocument, incomingPlan: CADSketchTransferEnvelope? = nil,
                onProfessionalRequest: ((CADBuildingProfessionalAction) -> Void)? = nil) {
        self.document=document; self.incomingPlan=incomingPlan; self.onProfessionalRequest=onProfessionalRequest
    }
    private var floor: CADBuildingStorey { model.storeys.first { $0.id == floorID } ?? model.storeys[0] }
    private var elements: [CADBuildingElement] { model.elements.filter { $0.storeyID == floor.id } }
    private func text(_ key: String, _ fallback: String) -> String { FloeCADStrings.text("cad.building."+key,fallback) }

    public var body: some View {
        VStack(spacing:0) {
            HStack {
                Picker(text("floor","Floor"),selection:$floorID) {
                    ForEach(model.storeys) { floor in Text(floor.name).tag(Optional(floor.id)) }
                }.pickerStyle(.menu).accessibilityIdentifier("building.floor")
                Spacer(minLength:8)
                Picker(text("workspace","Workspace"),selection:$mode) {
                    Text(text("plan","Plan")).tag(Mode.plan)
                    Text(text("model","Model")).tag(Mode.model)
                    Text(text("drawings","Drawings")).tag(Mode.drawings)
                }.pickerStyle(.segmented).frame(maxWidth:360).accessibilityIdentifier("building.mode")
                Spacer(minLength:8)
                Button { showSettings=true } label:{ Label(text("settings","Building settings"),systemImage:"building.2.crop.circle") }
                    .labelStyle(.iconOnly).frame(minWidth:44,minHeight:44).accessibilityIdentifier("building.settings")
            }.padding(.horizontal,12)
            Divider()
            switch mode {
            case .model: FloeCADWorkbenchView(document:document)
            case .drawings:
                CADDrawingPanelView(document:document,viewModel:document.viewModel())
            case .plan:
                HStack(spacing:0) {
                    if sizeClass == .regular { elementList.frame(width:250); Divider() }
                    VStack(spacing:0) {
                        planToolbar
                        CADBuildingPlanView(elements:elements,allElements:model.elements,pendingPoint:wallStart) { point in
                            if drawingWall { addWallPoint(point) }
                        }
                        .accessibilityIdentifier("building.plan.canvas")
                        if elements.isEmpty {
                            Text(text("empty","Import wall centre lines from a DWG/DXF plan, or draw a wall."))
                                .font(.callout).foregroundStyle(.secondary).padding(16)
                        }
                    }
                }
            }
            if let message {
                HStack { Text(message).font(.callout).textSelection(.enabled); Spacer()
                    Button(text("dismiss","Dismiss")) { self.message=nil }
                }.padding(12).background(.bar).accessibilityIdentifier("building.message")
            }
        }
        .toolbar {
            ToolbarItemGroup(placement:.topBarTrailing) {
                Button { document.session.undo(); reload() } label:{ Label(text("undo","Undo"),systemImage:"arrow.uturn.backward") }
                    .disabled(!document.session.undoStack.canUndo).accessibilityIdentifier("building.undo")
                Button { document.session.redo(); reload() } label:{ Label(text("redo","Redo"),systemImage:"arrow.uturn.forward") }
                    .disabled(!document.session.undoStack.canRedo).accessibilityIdentifier("building.redo")
                Menu {
                    Button(text("import","Import floor plan…"),systemImage:"square.and.arrow.down") { choosingFile=true }
                    Button(text("makeDrawing","Create drawings"),systemImage:"doc.richtext") { makeDrawing() }
                    ForEach(CADBuildingProfessionalAction.allCases) { action in
                        Button(action.title) {
                            if let onProfessionalRequest { onProfessionalRequest(action) }
                            else if let professionalPresenter { professionalPresenter.handler(document, action) }
                            else { message=text("taskRequired","Open this model from a task workspace to run a professional study.") }
                        }
                        .accessibilityIdentifier("building.professional." + action.rawValue)
                    }
                    Button(text("checks","Project checks"),systemImage:"checklist") {
                        do { inspection=Inspection(rows:try document.inspectBuilding()) } catch { message=error.localizedDescription }
                    }
                } label:{ Label(text("tools","Building tools"),systemImage:"building.2") }
                .accessibilityIdentifier("building.tools")
            }
        }
        .task { reload(); importPlan=incomingPlan }
        .onChange(of:document.buildingChangeCount) { _,_ in reload() }
        .onChange(of:floorID) { _,_ in wallStart=nil }
        .sheet(item:$editedElement) { element in
            CADBuildingElementEditor(element:element,model:model,changeCount:document.buildingChangeCount) { updated,expected in
                var next=model
                if let index=next.elements.firstIndex(where:{$0.id == updated.id}) { next.elements[index]=updated }
                else { next.elements.append(updated) }
                try commit(next,expectedChangeCount:expected)
            } remove:{ expected in
                var next=model; next.elements.removeAll { $0.id == element.id || $0.hostID == element.id }
                try commit(next,expectedChangeCount:expected)
            }
        }
        .sheet(isPresented:Binding(get:{importPlan != nil},set:{if !$0 {importPlan=nil}})) {
            if let plan=importPlan {
                CADBuildingPlanImportView(document:document,transfer:plan,storeyID:floor.id) { candidate,expected in
                    try commit(candidate,expectedChangeCount:expected); importPlan=nil
                }
            }
        }
        .sheet(isPresented:$showSettings) {
            CADBuildingSettingsView(model:model,currentFloorID:floor.id,changeCount:document.buildingChangeCount) { next,expected in try commit(next,expectedChangeCount:expected) }
        }
        .sheet(isPresented:$showElements) { NavigationStack { elementList.navigationTitle(text("elements","Elements")) } }
        .sheet(item:$inspection) { result in
            NavigationStack {
                List(result.rows) { check in
                    VStack(alignment:.leading,spacing:6) {
                        Label(check.title,systemImage:check.status == .failed ? "xmark.circle" : check.status == .passed ? "checkmark.circle" : "info.circle")
                        Text(check.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(text("status."+check.status.rawValue,check.status.rawValue)).font(.caption)
                    }.padding(.vertical,4).accessibilityIdentifier("building.check.\(check.id)")
                }.accessibilityIdentifier("building.checks.list")
                .navigationTitle(text("checks","Project checks")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button(text("done","Done")) { inspection=nil } } }
            }
        }
        .fileImporter(isPresented:$choosingFile,allowedContentTypes:[UTType(filenameExtension:"dxf") ?? .data,UTType(filenameExtension:"dwg") ?? .data,.data]) { result in
            fileImportTask?.cancel()
            let generation=UUID();fileImportGeneration=generation
            fileImportTask=Task { @MainActor in
                do {
                    let url=try result.get(), granted=url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    guard let decode=document.drawingSketchDecoder else { throw CADBuildingError.invalid(text("codecUnavailable","Open a DWG/DXF in the drawing editor and choose Building Design.")) }
                    loading=true; defer { if fileImportGeneration == generation { loading=false;fileImportTask=nil } }
                    let data=try await Task.detached(priority:.userInitiated) {
                        let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                        guard size > 0,size <= 10*1024*1024 else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.chooseADrawingSmallerThan10MB","Choose a drawing smaller than 10 MB.")) }
                        return try Data(contentsOf:url)
                    }.value
                    var transfer=try await decode(data,url.lastPathComponent)
                    guard !Task.isCancelled,!document.isClosed,fileImportGeneration == generation else { return }
                    transfer.purpose = .buildingFloorplan; transfer.placement=CADSketchTransferPlacement(target:.top)
                    importPlan=transfer
                } catch { if !Task.isCancelled,fileImportGeneration == generation { message=error.localizedDescription } }
            }
        }
        .onDisappear { fileImportTask?.cancel();fileImportTask=nil;fileImportGeneration=UUID();loading=false }
        .overlay { if loading { ProgressView().padding(20).background(.bar,in:RoundedRectangle(cornerRadius:12)) } }
    }
    private var planToolbar: some View {
        HStack {
            if sizeClass != .regular {
                Button { showElements=true } label:{ Label(text("elements","Elements"),systemImage:"list.bullet") }.labelStyle(.iconOnly)
            }
            Button { drawingWall.toggle(); wallStart=nil } label:{
                Label(drawingWall ? text("finishWalls","Finish walls"):text("drawWall","Draw wall"),systemImage:"pencil.and.outline")
            }.buttonStyle(.bordered).accessibilityIdentifier("building.drawWall")
            Menu { ForEach(CADBuildingElement.Kind.allCases,id:\.self) { kind in
                Button(kind.title) { editedElement=CADBuildingElementEditor.newElement(kind:kind,model:model,storeyID:floor.id) }
            }} label:{ Label(text("add","Add element"),systemImage:"plus") }.accessibilityIdentifier("building.addElement")
            Spacer()
            if drawingWall { Text(wallStart == nil ? text("pickStart","Tap the wall start"):text("pickEnd","Tap the wall end")).font(.caption) }
        }.padding(10)
    }
    private var elementList: some View {
        List {
            Section(text("elements","Elements")) {
                ForEach(elements) { element in Button { editedElement=element } label:{
                    VStack(alignment:.leading,spacing:4) {
                        Text(element.name).foregroundStyle(.primary)
                        Text(element.kind.title).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical,4)
                }.accessibilityIdentifier("building.element.\(element.id.uuidString)") }
            }
        }.listStyle(.sidebar)
    }
    private func reload() {
        do { if let existing=try document.building() { model=existing }
            else { model=CADBuildingDocument(name:document.name) }
            if !model.storeys.contains(where:{$0.id == floorID}) { floorID=model.storeys[0].id }
        } catch { message=error.localizedDescription }
    }
    private func commit(_ next: CADBuildingDocument,expectedChangeCount:Int?=nil) throws {
        _=try document.setBuilding(next,expectedChangeCount:expectedChangeCount ?? document.buildingChangeCount); model=next
    }
    private func addWallPoint(_ point:[Double]) {
        let snapped=point.map { ($0/50).rounded()*50 }
        guard let start=wallStart else { wallStart=snapped; return }
        do {
            var next=model
            next.elements.append(CADBuildingElement(storeyID:floor.id,kind:.wall,
                name:text("element.wall","Wall")+" \(next.elements.count+1)",a:start,b:snapped,heightMM:floor.heightMM))
            try commit(next); wallStart=snapped
        } catch { message=error.localizedDescription }
    }
    private func makeDrawing() {
        do { _=try document.createBuildingDrawing(storeyID:floor.id); mode = .drawings }
        catch { mode = .drawings;message=error.localizedDescription }
    }
}

struct CADBuildingPlanView: View {
    let elements:[CADBuildingElement]
    let allElements:[CADBuildingElement]
    var pendingPoint:[Double]?
    var onTap:([Double])->Void
    var body:some View {
        GeometryReader { geometry in
            let projection=BuildingPlanProjection(size:geometry.size,elements:elements)
            Canvas { context,size in
                for element in elements {
                    var path=Path()
                    if [.slab,.roof,.space].contains(element.kind) {
                        let a=projection.screen(element.a),b=projection.screen(element.b)
                        path.addRect(CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(b.x-a.x),height:abs(b.y-a.y)))
                        context.stroke(path,with:.color(.secondary),style:StrokeStyle(lineWidth:1,dash:element.kind == .space ? [4,4]:[]))
                    } else {
                        var a=element.a,b=element.b
                        if let hostID=element.hostID,let wall=allElements.first(where:{$0.id == hostID}),let offset=element.offsetMM,let width=element.widthMM {
                            let unit=[(wall.b[0]-wall.a[0])/wall.lengthMM,(wall.b[1]-wall.a[1])/wall.lengthMM]
                            a=[wall.a[0]+unit[0]*offset,wall.a[1]+unit[1]*offset]
                            b=[a[0]+unit[0]*width,a[1]+unit[1]*width]
                        }
                        path.move(to:projection.screen(a));path.addLine(to:projection.screen(b))
                        context.stroke(path,with:.color(element.hostID == nil ? .primary:.accentColor),
                            lineWidth:max(2,element.thicknessMM/projection.mmPerPoint))
                    }
                }
                if let pendingPoint {
                    let p=projection.screen(pendingPoint)
                    context.fill(Path(ellipseIn:CGRect(x:p.x-5,y:p.y-5,width:10,height:10)),with:.color(.accentColor))
                }
                context.draw(Text("\(Int(projection.mmPerPoint*100)) mm / 100 pt").font(.caption).foregroundStyle(.secondary),at:CGPoint(x:size.width/2,y:size.height-18))
            }.background(.background).contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in onTap(projection.plan(value.location)) })
        }
    }
}
private struct BuildingPlanProjection {
    let size:CGSize
    let centre:[Double]
    let mmPerPoint:Double
    init(size:CGSize,elements:[CADBuildingElement]) {
        self.size=size
        let points=elements.flatMap {[$0.a,$0.b]}
        let xs=points.map {$0[0]},ys=points.map {$0[1]}
        let minX=xs.min() ?? -5000,maxX=xs.max() ?? 5000,minY=ys.min() ?? -4000,maxY=ys.max() ?? 4000
        centre=[(minX+maxX)/2,(minY+maxY)/2]
        mmPerPoint=max(5,max((maxX-minX+2000)/max(1,size.width-48),(maxY-minY+2000)/max(1,size.height-48)))
    }
    func screen(_ point:[Double])->CGPoint { CGPoint(x:size.width/2+(point[0]-centre[0])/mmPerPoint,y:size.height/2-(point[1]-centre[1])/mmPerPoint) }
    func plan(_ point:CGPoint)->[Double] { [centre[0]+(point.x-size.width/2)*mmPerPoint,centre[1]-(point.y-size.height/2)*mmPerPoint] }
}
#endif
