// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import UniformTypeIdentifiers
import FloeElectronicsCore

struct EDLibraryChooser: View {
    let project: EDAProject
    let footprints: Bool
    @Bindable var library: EDLibraryController
    let choose: (EDALibraryPlacementSelection) -> Void
    var replace: ((EDALibrarySnapshot) -> Void)?
    var onUpdates: (() -> Void)?
    @State private var query = ""
    @State private var category: String?
    @State private var source = 0
    @State private var manufacturer: String?
    @State private var pinCount: Int?
    @State private var selected: String?
    @State private var visible = 100
    @State private var filePicker = false
    @State private var directoryPicker = false
    @State private var managing = false
    private var categories: [String] {
        let available = Set(library.catalog.entries.map(\.part.category))
        return EDLibraryLabels.categories.filter(available.contains) + available.subtracting(EDLibraryLabels.categories).sorted()
    }
    private var filteredCatalog: EDALibraryCatalog {
        let entries = library.catalog.entries.filter { entry in
            if footprints ? entry.part.footprint == nil : entry.part.symbol == nil { return false }
            let key = EDALibraryPreferences.key(packageID: entry.reference.packageID, partID: entry.reference.partID)
            switch source {
            case 1: return library.catalog.preferences.recent.contains(key)
            case 2: return library.catalog.preferences.favorites.contains(key)
            case 3: return entry.reference.packageID.hasPrefix("user.")
            default: return true
            }
        }
        return .init(inventoryRevision: library.catalog.inventoryRevision, entries: entries, preferences: library.catalog.preferences)
    }
    private var results: (entries: [EDALibraryEntry], total: Int) {
        var entries: [EDALibraryEntry] = [], offset = 0, total = 0
        repeat {
            guard let page = try? filteredCatalog.search(.init(text: query, category: category, manufacturer: manufacturer, pinCount: pinCount, offset: offset, limit: min(200, visible - entries.count))) else { break }
            entries += page.entries; total = page.total
            guard let next = page.nextOffset, entries.count < visible else { break }; offset = next
        } while entries.count < visible
        if source == 1 {
            let recent = library.catalog.preferences.recent
            entries.sort { (recent.firstIndex(of: EDALibraryPreferences.key(packageID: $0.reference.packageID, partID: $0.reference.partID)) ?? Int.max) < (recent.firstIndex(of: EDALibraryPreferences.key(packageID: $1.reference.packageID, partID: $1.reference.partID)) ?? Int.max) }
        }
        return (entries, total)
    }
    var body: some View {
        VStack(spacing: 0) {
            controls
            if library.busy && library.canCancel {
                HStack { ProgressView().controlSize(.small); Text(edText("正在读取库文件…", "Reading library files…")).font(.caption); Spacer(); Button(edText("取消", "Cancel")) { library.cancelCurrentOperation() } }.padding(12)
            }
            if let message = library.message {
                HStack { Label(message, systemImage: "exclamationmark.triangle").font(.caption); Spacer(); Button(edText("重试", "Retry")) { library.start() } }.padding(12).foregroundStyle(.orange)
            }
            if library.busy && library.catalog.entries.isEmpty { ProgressView(edText("正在载入元件库…", "Loading parts…")).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                GeometryReader { geometry in
                    if geometry.size.width >= 760 {
                        HStack(spacing: 0) {
                            if geometry.size.width >= 1_050 { categoryList.frame(width: 170); Divider() }
                            entryList(wide: true).frame(width: min(340, geometry.size.width * 0.39))
                            Divider()
                            if let entry = results.entries.first(where: { $0.id == selected }) {
                                EDLibraryPartDetail(entry: entry, project: project, footprints: footprints, library: library, choose: choose, replace: replace).id(entry.id)
                            } else { ContentUnavailableView(edText("选择元件", "Choose a part"), systemImage: "cpu", description: Text(edText("在左侧浏览，查看符号、封装和引脚。", "Browse the list to inspect symbols, footprints and pins."))).frame(maxWidth: .infinity, maxHeight: .infinity) }
                        }
                    } else { entryList(wide: false) }
                }
            }
        }
        .onAppear { library.start() }
        .onChange(of: query) { _, _ in visible = 100 }
        .onChange(of: category) { _, _ in visible = 100; selected = nil }
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.item], allowsMultipleSelection: true, onCompletion: selectedFiles)
        .fileImporter(isPresented: $directoryPicker, allowedContentTypes: [.folder], allowsMultipleSelection: true, onCompletion: selectedFiles)
        .sheet(isPresented: Binding(get: { library.importDraft != nil }, set: { if !$0 { library.cancelImport() } })) { EDLibraryImportReview(library: library) }
        .sheet(isPresented: $managing) { EDLibraryVersions(library: library) }
        .accessibilityIdentifier("electronics.library.browser")
    }
    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(edText("型号、参数、封装或引脚", "Part, parameter, package or pin"), text: $query).textFieldStyle(.plain).autocorrectionDisabled()
                }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                filters
                Menu {
                    if library.canImport {
                        Button(edText("导入库文件或压缩包…", "Import library files or ZIP…"), systemImage: "doc.badge.plus") { filePicker = true }
                        Button(edText("导入库目录…", "Import library folder…"), systemImage: "folder.badge.plus") { directoryPicker = true }
                    }
                    Button(edText("管理库版本…", "Manage library versions…"), systemImage: "books.vertical") { managing = true }
                    if let onUpdates { Button(edText("浏览库更新…", "Browse library updates…"), systemImage: "arrow.triangle.2.circlepath", action: onUpdates) }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 34, height: 34) }
                    .disabled(library.busy).accessibilityLabel(edText("元件库选项", "Library options"))
            }
            HStack {
                Picker(edText("范围", "Collection"), selection: $source) {
                    Text(edText("全部", "All")).tag(0); Text(edText("最近", "Recent")).tag(1); Text(edText("收藏", "Favorites")).tag(2); Text(edText("我的库", "My libraries")).tag(3)
                }.pickerStyle(.segmented)
                Picker(edText("分类", "Category"), selection: $category) {
                    Text(edText("所有分类", "All categories")).tag(String?.none)
                    ForEach(categories, id: \.self) { Text(EDLibraryLabels.category($0)).tag(Optional($0)) }
                }.pickerStyle(.menu).fixedSize()
            }
        }.padding(12).background(.bar)
    }
    private var filters: some View {
        Menu {
            Picker(edText("厂商", "Manufacturer"), selection: $manufacturer) {
                Text(edText("全部厂商", "All manufacturers")).tag(String?.none)
                ForEach(Array(Set(library.catalog.entries.map(\.part.manufacturer).filter { !$0.isEmpty })).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
            }
            Picker(edText("引脚数", "Pin count"), selection: $pinCount) {
                Text(edText("全部引脚数", "Any pin count")).tag(Int?.none)
                ForEach(Array(Set(library.catalog.entries.map(\.part.pinCount))).sorted(), id: \.self) { Text(String($0)).tag(Optional($0)) }
            }
            Button(edText("清除筛选", "Clear filters")) { category = nil; manufacturer = nil; pinCount = nil }
        } label: { Image(systemName: "line.3.horizontal.decrease").frame(width: 34, height: 34) }
            .accessibilityLabel(edText("筛选元件", "Filter parts"))
    }
    private var categoryList: some View {
        List(selection: $category) {
            Text(edText("所有分类", "All categories")).tag(String?.none)
            ForEach(categories, id: \.self) { Text(EDLibraryLabels.category($0)).tag(Optional($0)) }
        }.listStyle(.sidebar)
    }
    private func entryList(wide: Bool) -> some View {
        let value = results
        return List {
            Section {
                ForEach(value.entries) { entry in
                    if wide { Button { selected = entry.id } label: { row(entry).contentShape(Rectangle()) }.buttonStyle(.plain).listRowBackground(selected == entry.id ? Color.accentColor.opacity(0.12) : .clear) }
                    else {
                        NavigationLink { EDLibraryPartDetail(entry: entry, project: project, footprints: footprints, library: library, choose: choose, replace: replace).navigationTitle(edText("元件", "Part")) } label: { row(entry) }
                    }
                }
                if value.entries.count < value.total { Button(edText("载入更多", "Load more")) { visible += 100 } }
            } header: { Text(edText("元件 ", "Parts ") + String(value.total)) }
        }
        .listStyle(.plain)
        .overlay { if value.entries.isEmpty { ContentUnavailableView.search(text: query) } }
    }
    private func row(_ entry: EDALibraryEntry) -> some View {
        HStack(spacing: 12) {
            EDLibraryGeometryPreview(part: entry.part, footprint: footprints).frame(width: 72, height: 60).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.part.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                Text(EDLibraryLabels.kind(entry.part.kind) + " · " + String(entry.part.pinCount) + edText(" 引脚", " pins")).font(.caption).foregroundStyle(.secondary)
                if !entry.part.manufacturer.isEmpty { Text(entry.part.manufacturer).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if library.isFavorite(entry) { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
        }.padding(.vertical, 4).accessibilityIdentifier("electronics.library.entry." + entry.id)
    }
    private func selectedFiles(_ result: Result<[URL], Error>) { if case .success(let urls) = result { library.inspect(urls) } }
}
