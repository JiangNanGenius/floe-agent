// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeBiologyCore

/// Freeze both the source revision and visible atom identity when opening.
/// An AI edit while this sheet is open must produce a conflict, never silently
/// rebase the user's transform onto different data.
struct BiologyStructureTransformRequest:Identifiable {
    let id=UUID()
    let asset:BiologyAsset
    let visibleAtomIDs:[Int]
    let selectedAtomIDs:[Int]
}

@MainActor struct BiologyStructureTransformSheet:View {
    let model:BiologyWorkbenchModel
    let request:BiologyStructureTransformRequest
    @Environment(\.dismiss) private var dismiss
    @State private var selectedOnly=false
    @State private var x=0.0
    @State private var y=0.0
    @State private var z=0.0
    @State private var axisX=0.0
    @State private var axisY=0.0
    @State private var axisZ=1.0
    @State private var degrees=0.0
    @State private var saving=false
    @State private var error:String?

    var body:some View {
        NavigationStack {
            Form {
                Section {
                    Text(request.asset.title)
                    Picker(biologyText("Apply to","应用范围"),selection:$selectedOnly) {
                        Text(biologyText("Current model and chain","当前模型和链")).tag(false)
                        if !request.selectedAtomIDs.isEmpty {Text(biologyText("Selected atoms","选中的原子")).tag(true)}
                    }
                    Text(biologyText("Atoms: ","原子数：")+String(atomIDs.count)).foregroundStyle(.secondary)
                }
                Section(biologyText("Translation · Å","平移 · Å")) {
                    coordinate(biologyText("X offset","X 偏移"),value:$x)
                    coordinate(biologyText("Y offset","Y 偏移"),value:$y)
                    coordinate(biologyText("Z offset","Z 偏移"),value:$z)
                }
                Section {
                    coordinate(biologyText("Angle · degrees","角度 · 度"),value:$degrees)
                    coordinate(biologyText("Axis X","旋转轴 X"),value:$axisX)
                    coordinate(biologyText("Axis Y","旋转轴 Y"),value:$axisY)
                    coordinate(biologyText("Axis Z","旋转轴 Z"),value:$axisZ)
                } header:{Text(biologyText("Rotation","旋转"))}
                  footer:{Text(biologyText("Rotate around an axis through the coordinate origin, then translate. Original imported data is retained.","先绕经过坐标原点的轴旋转，再平移。导入原件会保留。"))}
                if let error {Text(error).foregroundStyle(.red)}
            }
            .disabled(saving)
            .navigationTitle(biologyText("Move or rotate structure","移动或旋转结构"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction){Button(biologyText("Cancel","取消")){dismiss()}.disabled(saving)}
                ToolbarItem(placement:.confirmationAction){Button(biologyText("Apply","应用")){Task{await save()}}.disabled(saving || atomIDs.isEmpty).accessibilityIdentifier("biology.applyStructureTransform")}
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private var atomIDs:[Int] {selectedOnly ? request.selectedAtomIDs:request.visibleAtomIDs}
    private func coordinate(_ label:String,value:Binding<Double>)->some View {
        TextField(label,value:value,format:.number).keyboardType(.numbersAndPunctuation).biologyNamedInput(label)
    }
    private func save() async {
        guard !saving else {return}
        saving=true;defer{saving=false}
        do {
            guard [x,y,z,axisX,axisY,axisZ,degrees].allSatisfy(\.isFinite),!atomIDs.isEmpty else {
                throw BiologyError.invalid(biologyText("Enter finite coordinates and select atoms.","请输入有效坐标并选择原子。"))
            }
            try Task.checkCancellation()
            _=try await model.service.update(model.projectID,operation:"structure.transform",assetID:request.asset.id,
                expectedRevision:request.asset.revision,parameters:.object([
                    "translation":.array([x,y,z].map(JSONValue.number)),
                    "axis":.array([axisX,axisY,axisZ].map(JSONValue.number)),
                    "angleRadians":.number(degrees * .pi / 180),
                    "atomIDs":.array(atomIDs.map{.number(Double($0))})]))
            model.rememberUndo(request.asset)
            await model.refresh()
            dismiss()
        } catch {self.error=error.localizedDescription}
    }
}
#endif
