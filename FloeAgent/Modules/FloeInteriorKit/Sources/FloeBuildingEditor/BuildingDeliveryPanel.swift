// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import SwiftUI
import FloeBuildingCAD

struct BuildingDeliveryPanel:View {
    @Bindable var project:BuildingEditorProjectSession
    let previewFile:((URL)->Void)?
    @Environment(\.locale) private var locale
    private func copy(_ zh:String,_ en:String)->String {locale.language.languageCode?.identifier=="zh" ? zh:en}
    var body:some View {
        if let delivery=project.deliveries {content(delivery)}
    }
    private func content(_ service:BuildingDeliveryWorkspace)->some View {
        @Bindable var delivery=service
        return Form {
            Section(copy("柜体成套图纸","Cabinet drawing set")) {
                if project.cad.manifest.cabinets.isEmpty {
                    Text(copy("先在“柜体与图纸”中把柜体放入模型。","Place a cabinet from Cabinets & sheets first."))
                        .foregroundStyle(.secondary)
                } else {
                    Picker(copy("选择柜体","Choose a cabinet"),selection:$delivery.selectedCabinetID) {
                        Text(copy("请选择","Choose a cabinet")).tag(Optional<UUID>.none)
                        ForEach(project.cad.manifest.cabinets,id:\.cabinetID){Text($0.recipe.name).tag(Optional($0.cabinetID))}
                    }
                    Button(copy("生成或更新成套图纸","Generate or refresh drawing set")){delivery.makeSheets()}
                        .disabled(delivery.selectedCabinetID==nil).accessibilityIdentifier("building.delivery.generate")
                    Button(copy("导出柜体图纸与二维／三维项目","Export cabinet sheets and 2D/3D projects")){delivery.exportSelected()}
                        .disabled(delivery.selectedCabinetID.flatMap{project.cad.manifest.sheet(cabinetID:$0)}==nil)
                        .accessibilityIdentifier("building.delivery.export")
                }
            }.disabled(delivery.busy || project.busy)
            Section(copy("整工程与选定图纸","Whole project and selected drawing")) {
                Button(copy("导出三维模型","Export 3D model")){delivery.exportWholeProject(includeSelectedPage:false)}
                    .accessibilityIdentifier("building.delivery.project3d")
                if delivery.projectPages.isEmpty {
                    Text(copy("在模型的图纸工作台创建图纸后，可导出对应的二维项目。","Create a page in the model drawing workbench to export its 2D project."))
                        .foregroundStyle(.secondary)
                } else {
                    Picker(copy("选择二维图纸","Choose a 2D drawing"),selection:$delivery.selectedProjectPageID) {
                        Text(copy("请选择","Choose a drawing")).tag(Optional<UUID>.none)
                        ForEach(delivery.projectPages){Text($0.title).tag(Optional($0.id))}
                    }
                    Button(copy("导出所选二维图纸和三维模型","Export selected 2D drawing and 3D model")){delivery.exportWholeProject(includeSelectedPage:true)}
                        .disabled(delivery.selectedProjectPageID==nil).accessibilityIdentifier("building.delivery.project2d")
                    Text(copy("二维项目使用图纸坐标和纸面毫米；模型关联与格式损失记在成果范围中。","The 2D project uses drawing coordinates and paper millimetres. Output scope records model links and format losses."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(copy("刷新图纸目录","Refresh drawing list")){delivery.reload()}
            }.disabled(delivery.busy || project.busy)
            if delivery.generatedCabinetID != nil {Section {Label(copy("成套图纸已生成","Drawing set generated"),systemImage:"checkmark.circle")}}
            if delivery.busy {
                Section {ProgressView(delivery.activity == .registering
                    ? copy("正在添加到空间…","Adding to Space…")
                    : copy("正在准备图纸…","Preparing drawings…"));Button(copy("取消","Cancel")){delivery.cancel()}}
            }
            if let details=delivery.errorDetails {
                Section {Label(delivery.failureActivity == .registering
                    ? copy("添加到空间未完成","Couldn’t add to Space")
                    : copy("图纸操作未完成","Drawing operation incomplete"),systemImage:"exclamationmark.circle")
                    DisclosureGroup(copy("详细信息","Details")){Text(details).font(.caption).textSelection(.enabled)}}
            }
            ForEach(delivery.records) { record in
                Section(record.receipt.pageTitle) {
                    Text(record.receipt.createdAtISO8601).font(.caption).foregroundStyle(.secondary)
                    ForEach(record.receipt.files,id:\.relativePath) { file in
                        if let url=record.fileURL(file) {
                            HStack {
                                if let previewFile,file.format=="pdf" {
                                    Button {previewFile(url)} label:{Label(file.relativePath,systemImage:"doc.richtext")}
                                } else {Text(file.relativePath)}
                                Spacer()
                                ShareLink(item:url){Image(systemName:"square.and.arrow.up")}
                                    .accessibilityLabel(copy("分享 ","Share ")+file.relativePath)
                            }
                        }
                    }
                    if !record.receipt.unsupported.isEmpty {
                        DisclosureGroup(copy("成果范围","Output scope")) {
                            ForEach(record.receipt.unsupported,id:\.self){Text($0).font(.caption).foregroundStyle(.secondary)}
                        }
                    }
                }
            }
        }.task {delivery.reload()}
    }
}
#endif
