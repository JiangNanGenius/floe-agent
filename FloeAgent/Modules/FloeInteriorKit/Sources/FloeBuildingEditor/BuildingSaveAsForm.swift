// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import SwiftUI
import FloeCAD
import FloeBuildingCAD

@MainActor
struct BuildingSaveAsForm: View {
    @Bindable var project: BuildingEditorProjectSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    private enum Destination: Hashable { case building, cad2D, cad3D, exchange }
    private enum Scope: Hashable { case all, storey, elements, discipline }
    @State private var destination: Destination = .building
    @State private var scope: Scope = .all
    @State private var format: BuildingInterchangeFormat = .dxf
    @State private var storeyID: UUID?
    @State private var elements: Set<UUID> = []
    @State private var discipline: CADBuildingExportDiscipline = .architecture
    @State private var pageID: UUID?
    @State private var title = ""
    @State private var working = false
    @State private var receipt: BuildingProjectCopyReceipt?
    @State private var output: URL?
    @State private var formatNotes: [String] = []
    @State private var recentExports: [URL] = []
    @State private var error: String?

    private func label(_ zh: String, _ en: String) -> String { locale.language.languageCode?.identifier == "zh" ? zh : en }
    private var building: CADBuildingDocument? { try? project.cad.building() }
    private var pages: [BuildingEditorDrawingPageOption] { (try? project.projectDrawingPages()) ?? [] }
    private var selectedScope: CADBuildingExportScope? {
        switch scope {
        case .all: .wholeProject
        case .storey: storeyID.map(CADBuildingExportScope.storey)
        case .elements: elements.isEmpty ? nil : .elements(elements)
        case .discipline: .discipline(discipline)
        }
    }
    private var supportsPage: Bool {
        scope == .all && (destination == .cad2D || (destination == .exchange && [.dwg,.dxf,.pdf].contains(format)))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let output {
                    Section {
                        Label(output.lastPathComponent, systemImage: "checkmark.circle")
                        if !formatNotes.isEmpty {
                            DisclosureGroup(label("格式说明", "Format notes")) {
                                ForEach(formatNotes, id: \.self) { Text($0).font(.footnote) }
                            }
                        }
                        ShareLink(item: output) { Label(label("分享或存储到文件", "Share or Save to Files"), systemImage: "square.and.arrow.up") }
                    }
                } else {
                    Group {
                        Section {
                            TextField(label("副本名称", "Copy name"), text: $title)
                                .accessibilityIdentifier("building.copy.name")
                            Picker(label("另存为", "Save as"), selection: $destination) {
                                Text(label("建筑工程", "Building project")).tag(Destination.building)
                                Text(label("2D CAD 工程", "2D CAD project")).tag(Destination.cad2D)
                                Text(label("3D CAD 工程", "3D CAD project")).tag(Destination.cad3D)
                                Text(label("通用文件", "Exchange file")).tag(Destination.exchange)
                            }.accessibilityIdentifier("building.copy.kind")
                            if destination == .exchange {
                                Picker(label("格式", "Format"), selection: $format) {
                                    ForEach(BuildingInterchangeFormat.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                                }
                            }
                        }
                        if destination != .building { scopeSection }
                    }.disabled(working || receipt != nil)
                    if let error { Text(error).foregroundStyle(.red) }
                    Button {
                        Task { await save() }
                    } label: {
                        if working { ProgressView() }
                        else { Text(receipt == nil ? label("保存副本", "Save copy") : label("重新添加到空间", "Retry adding to Space")) }
                    }
                    .disabled(working || project.closed || (destination != .building && selectedScope == nil))
                    .accessibilityIdentifier("building.copy.confirm")
                    if destination == .exchange && !recentExports.isEmpty {
                        DisclosureGroup(label("已导出的文件", "Exported files")) {
                            ForEach(recentExports, id: \.self) { file in
                                ShareLink(item: file) { Label(file.lastPathComponent, systemImage: "square.and.arrow.up") }
                            }
                        }
                    }
                }
            }
            .navigationTitle(label("另存为", "Save As"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(output == nil ? label("关闭", "Close") : label("完成", "Done")) { dismiss() }.disabled(working)
                }
            }
            .onAppear {
                if title.isEmpty { title = project.nativeDocument.name + label(" 副本", " copy") }
                do { recentExports = try project.exchangeFiles() } catch { self.error = error.localizedDescription }
                if storeyID == nil { storeyID = building?.storeys.first?.id }
            }
            .interactiveDismissDisabled(working)
        }
    }

    private var scopeSection: some View {
        Section {
            Picker(label("导出范围", "Scope"), selection: $scope) {
                Text(label("整个工程", "Whole project")).tag(Scope.all)
                Text(label("楼层", "Floor")).tag(Scope.storey)
                Text(label("选择构件", "Selected elements")).tag(Scope.elements)
                Text(label("按专业", "By discipline")).tag(Scope.discipline)
            }
            if scope == .storey {
                Picker(label("楼层", "Floor"), selection: $storeyID) {
                    Text(label("选择楼层", "Choose a floor")).tag(UUID?.none)
                    ForEach(building?.storeys ?? []) { Text($0.name).tag(Optional($0.id)) }
                }
            } else if scope == .elements {
                ForEach(building?.elements ?? []) { element in
                    Toggle(element.name, isOn: Binding(get: { elements.contains(element.id) }, set: { selected in
                        if selected { elements.insert(element.id) } else { elements.remove(element.id) }
                    }))
                }
                if building?.elements.isEmpty != false { Text(label("工程里还没有构件", "This project has no elements yet")) }
            } else if scope == .discipline {
                Picker(label("专业", "Discipline"), selection: $discipline) {
                    Text(label("建筑", "Architecture")).tag(CADBuildingExportDiscipline.architecture)
                    Text(label("结构", "Structure")).tag(CADBuildingExportDiscipline.structure)
                    Text(label("机电", "MEP")).tag(CADBuildingExportDiscipline.mep)
                }
            }
            if supportsPage && !pages.isEmpty {
                Picker(label("图纸", "Drawing"), selection: $pageID) {
                    Text(label("从模型生成平面图", "Generate a plan from the model")).tag(UUID?.none)
                    ForEach(pages) { Text($0.title).tag(Optional($0.id)) }
                }
            }
        }
    }

    private func save() async {
        guard !working else { return }
        working = true
        defer { working = false }
        error = nil
        do {
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw BuildingProjectCopyError.invalidTitle }
            if destination == .exchange, let selectedScope {
                let file = try await project.exportExchangeFile(format: format, scope: selectedScope,
                    pageID: supportsPage ? pageID : nil, title: name)
                formatNotes = file.losses
                output = file.url
                return
            }
            let copy: BuildingProjectCopyReceipt
            if let receipt { copy = receipt }
            else if destination == .building { copy = try await project.saveBuildingCopy(title: name) }
            else if let selectedScope {
                copy = try await project.exportCADCopy(kind: destination == .cad2D ? .cad2D : .cad3D,
                    pageID: supportsPage ? pageID : nil, title: name, scope: selectedScope)
            } else { return }
            receipt = copy
            try await project.publishSavedCopy(copy)
            output = project.projectCopyURL(copy)
        } catch { self.error = error.localizedDescription }
    }
}
#endif
