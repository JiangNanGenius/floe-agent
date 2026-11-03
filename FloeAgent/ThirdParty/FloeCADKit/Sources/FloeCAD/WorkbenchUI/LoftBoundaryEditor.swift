import SwiftUI
import simd

nonisolated struct CADLoftBoundaryDraft {
    var mode=0
    var tangent=SIMD3<Double>(0,0,1)
    var curvature=SIMD3<Double>.zero
    var angularTolerance=1e-5
    var curvatureTolerance=1e-6
    init(_ value:LoftDefinition.BoundaryConstraint?=nil,direction:SIMD3<Double>=SIMD3(0,0,1)) {
        tangent=direction
        if let value {
            mode=value.curvature == nil ? 1:2;tangent=value.tangent.point;curvature=value.curvature?.point ?? .zero
            angularTolerance=value.angularTolerance;curvatureTolerance=value.curvatureTolerance
        }
    }
    var constraint:LoftDefinition.BoundaryConstraint? {
        mode==0 ? nil:.init(tangent:PointWrapper(tangent),curvature:mode==2 ? PointWrapper(curvature):nil,
            angularTolerance:angularTolerance,curvatureTolerance:curvatureTolerance)
    }
}
/// Native numeric controls edit an actual generation constraint. No G1/G2
/// toggle is shown: this operation does not match an adjacent support face.
struct CADLoftBoundaryEditor:View {
    let title:String
    let identifier:String
    @Binding var draft:CADLoftBoundaryDraft
    private func text(_ key:String,_ fallback:String) -> String { FloeCADStrings.text("cad.loftSurface."+key,fallback) }
    var body:some View {
        Section(title) {
            Picker(text("boundaryCondition","Boundary condition"),selection:$draft.mode) {
                Text(text("automaticBoundary","Automatic")).tag(0)
                Text(text("boundaryDirection","Direction")).tag(1)
                Text(text("boundaryCurvature","Direction and curvature")).tag(2)
            }.accessibilityIdentifier(identifier+"Mode")
            if draft.mode>0 {
                vector(text("boundaryDirection","Direction"),value:$draft.tangent,suffix:"Tangent")
                if draft.mode==2 { vector(text("boundaryCurvatureVector","Normal curvature (1/mm)"),value:$draft.curvature,suffix:"Curvature") }
                DisclosureGroup(text("details","Details")) {
                    TextField(text("angularTolerance","Angle tolerance (rad)"),value:$draft.angularTolerance,format:.number)
                        .accessibilityIdentifier(identifier+"AngularTolerance")
                    if draft.mode==2 {
                        TextField(text("curvatureTolerance","Curvature tolerance (1/mm)"),value:$draft.curvatureTolerance,format:.number)
                            .accessibilityIdentifier(identifier+"CurvatureTolerance")
                    }
                }
                Text(text("boundaryHelp","Directions follow section order. Curvature is perpendicular to the direction. Use two to four evenly spaced parallel sections."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    private func vector(_ title:String,value:Binding<SIMD3<Double>>,suffix:String) -> some View {
        VStack(alignment:.leading) {
            Text(title).font(.subheadline)
            HStack {
                ForEach(0..<3,id:\.self) { axis in
                    TextField(["X","Y","Z"][axis],value:Binding(get:{ value.wrappedValue[axis] },set:{ value.wrappedValue[axis]=$0 }),format:.number)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier(identifier+suffix+["X","Y","Z"][axis])
                }
            }
        }
    }
}
