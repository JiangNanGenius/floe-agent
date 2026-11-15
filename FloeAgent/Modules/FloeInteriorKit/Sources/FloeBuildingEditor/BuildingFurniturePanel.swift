// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import SwiftUI
import FloeInteriorCore
import FloeBuildingAssets

struct BuildingFurniturePanel: View {
    @Bindable var workspace:BuildingFurnitureWorkspace
    @Environment(\.locale) private var locale
    private func copy(_ zh:String,_ en:String)->String {locale.language.languageCode?.identifier=="zh" ? zh:en}
    var body:some View {
        Form {
            Section(copy("家具库","Furniture library")) {
                TextField(copy("搜索名称或分类","Search names or categories"),text:$workspace.search)
                    .accessibilityIdentifier("building.furniture.search")
                if workspace.rows.isEmpty {
                    Text(copy("导入家具模型包，或添加一把基础扶手椅开始布置。","Import a furniture package, or add the starter armchair."))
                        .foregroundStyle(.secondary)
                    Button(copy("添加基础扶手椅","Add starter armchair")){workspace.importStarter()}
                        .disabled(workspace.busy).accessibilityIdentifier("building.furniture.starter")
                }
                ForEach(workspace.visibleRows,id:\.buildingViewID) { row in
                    Button {workspace.select(row)} label:{
                        HStack {
                            VStack(alignment:.leading,spacing:4){Text(row.name);Text(row.version).font(.caption).foregroundStyle(.secondary)}
                            Spacer()
                            if workspace.selection == BuildingFurnitureKey(row) {Image(systemName:"checkmark")}
                        }
                    }.disabled(workspace.busy)
                }
                Button(copy("刷新库","Refresh library")){workspace.reload()}.disabled(workspace.busy)
            }
            if let bundle=workspace.selectedBundle {
                Section(copy("放置尺寸","Placement size")) {
                    Text(bundle.manifest.name).font(.headline)
                    if let dimensions=bundle.manifest.declaredDimensions {
                        Toggle(copy("按标称尺寸放置","Use catalog dimensions"),isOn:$workspace.useCatalogDimensions)
                        if workspace.useCatalogDimensions {
                            Text("\(dimensions.width.formatted()) × \(dimensions.depth.formatted()) × \(dimensions.height.formatted()) \(dimensions.unit.rawValue)")
                            Toggle(copy("允许按各方向适配","Allow fitting each axis"),isOn:$workspace.allowNonUniformScaling)
                        }
                    }
                    if !workspace.useCatalogDimensions || bundle.manifest.declaredDimensions == nil {
                        Picker(copy("源模型单位","Source model unit"),selection:$workspace.sourceUnit) {
                            Text(copy("请选择","Choose a unit")).tag(Optional<FurnitureLengthUnit>.none)
                            ForEach(FurnitureLengthUnit.allCases,id:\.self){Text($0.rawValue).tag(Optional($0))}
                        }
                    }
                }.disabled(workspace.busy)
                Section(copy("位置（毫米）","Position (mm)")) {
                    TextField("X",text:$workspace.xText).keyboardType(.numbersAndPunctuation)
                    TextField("Y",text:$workspace.yText).keyboardType(.numbersAndPunctuation)
                    TextField(copy("距楼面高度","Height above floor"),text:$workspace.elevationText).keyboardType(.numbersAndPunctuation)
                    TextField(copy("旋转角度","Rotation (degrees)"),text:$workspace.yawText).keyboardType(.numbersAndPunctuation)
                    Picker(copy("定位点","Anchor"),selection:$workspace.anchor) {
                        Text(copy("底面中心","Bottom center")).tag(FurnitureAnchor.bottomCenter)
                        Text(copy("底面左前角","Bottom front left")).tag(FurnitureAnchor.bottomFrontLeft)
                        Text(copy("几何中心","Geometric center")).tag(FurnitureAnchor.geometricCenter)
                    }
                    Button(copy("放入当前模型","Place in current model")){workspace.place()}
                        .accessibilityIdentifier("building.furniture.place")
                }.disabled(workspace.busy)
                DisclosureGroup(copy("来源与版本","Source and version")) {
                    LabeledContent(copy("来源","Source"),value:bundle.manifest.provenance.source)
                    LabeledContent(copy("许可","License"),value:bundle.manifest.provenance.license.identifier)
                    Text(bundle.manifest.provenance.license.basis).font(.caption).textSelection(.enabled)
                }
            }
            if workspace.busy {
                Section {ProgressView(copy("正在处理家具…","Processing furniture…"));Button(copy("取消","Cancel")){workspace.cancel()}}
            }
            if workspace.completedPlacementID != nil {Section {Label(copy("家具已放入模型","Furniture placed"),systemImage:"checkmark.circle")}}
            if let error=workspace.errorDetails {
                Section {Label(copy("操作未完成","Operation incomplete"),systemImage:"exclamationmark.circle")
                    DisclosureGroup(copy("详细信息","Details")){Text(error).font(.caption).textSelection(.enabled)}}
            }
        }.task {if workspace.rows.isEmpty{workspace.reload()}}
    }
}
private extension FurnitureAssetSummary {
    var buildingViewID:BuildingFurnitureKey {BuildingFurnitureKey(self)}
}
#endif
