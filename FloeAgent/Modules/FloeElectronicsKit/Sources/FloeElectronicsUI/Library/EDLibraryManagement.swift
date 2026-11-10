// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeElectronicsCore

struct EDLibraryImportReview: View {
    @Bindable var library: EDLibraryController
    var body: some View {
        NavigationStack {
            if let draft = library.importDraft {
                List {
                    Section {
                        LabeledContent(edText("可导入", "Available"), value: String(draft.availableCount))
                        LabeledContent(edText("待处理", "Needs attention"), value: String(draft.entries.count - draft.availableCount))
                        Text(edText("原始文件随库保留。不兼容的项目不会被替换成空符号或简化封装。", "Original files stay with the library. Unsupported entries won’t be replaced with empty symbols or simplified footprints.")).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(draft.entries.enumerated()), id: \.offset) { _, entry in
                        Section {
                            if let part = draft.package?.parts.first(where: { $0.id == entry.partID }) {
                                HStack { EDLibraryGeometryPreview(part: part, footprint: part.symbol == nil).frame(width: 90, height: 70); VStack(alignment: .leading) { Text(entry.name); Text(EDLibraryLabels.kind(part.kind)).font(.caption).foregroundStyle(.secondary) } }
                            } else { Label(entry.name, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                            if !entry.notices.isEmpty {
                                DisclosureGroup(edText("兼容性详情", "Compatibility details")) {
                                    Text(entry.sourcePath).font(.caption).textSelection(.enabled)
                                    ForEach(Array(entry.notices.enumerated()), id: \.offset) { _, notice in Text(notice.detail).font(.caption).textSelection(.enabled) }
                                }
                            }
                        }
                    }
                    if let message = library.message { Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
                }
                .navigationTitle(edText("导入元件库", "Import library"))
                .edLibraryInlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(edText("取消", "Cancel")) { library.cancelImport() }.disabled(library.busy) }
                    ToolbarItem(placement: .confirmationAction) { Button(edText("导入 ", "Import ") + String(draft.availableCount)) { library.acceptImport() }.disabled(library.busy || draft.package == nil) }
                }
                .overlay { if library.busy { ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            }
        }.interactiveDismissDisabled(library.busy)
    }
}

struct EDLibraryVersions: View {
    @Bindable var library: EDLibraryController
    @Environment(\.dismiss) private var dismiss
    @State private var inventory: EDALibraryInventory?
    @State private var licenses: [EDALibraryLicense] = []
    @State private var showLicenses = false
    var body: some View {
        NavigationStack {
            List {
                if let inventory {
                    Section {
                        Text(edText("切换库版本只影响以后选择的元件。已有设计保留自己的元件快照。", "Switching versions affects future selections. Existing designs keep their own part snapshots.")).font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(Array(Set(inventory.installed.map(\.packageID))).sorted(), id: \.self) { id in
                        Section {
                            ForEach(inventory.installed.filter { $0.packageID == id }, id: \.version) { version in
                                versionRow(version, active: inventory.activeVersions[id] == version.version)
                            }
                        }
                    }
                } else { ProgressView(edText("载入库版本…", "Loading versions…")) }
                if let message = library.message { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            .navigationTitle(edText("元件库", "Libraries")).edLibraryInlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(edText("完成", "Done")) { dismiss() } } }
            .task { inventory = try? await library.store.inventory() }
            .onChange(of: library.catalog.inventoryRevision) { _, _ in Task { inventory = try? await library.store.inventory() } }
            .sheet(isPresented: $showLicenses) {
                NavigationStack {
                    List(licenses, id: \.id) { license in
                        Section(license.attribution) { Text(license.id).font(.headline); Text(license.modifications); Text(license.text).font(.caption).textSelection(.enabled) }
                    }.navigationTitle(edText("来源与许可证", "Attribution & license")).edLibraryInlineNavigationTitle()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(edText("完成", "Done")) { showLicenses = false } } }
                }
            }
        }
    }
    private func versionRow(_ version: EDALibraryInstalledVersion, active: Bool) -> some View {
        let detail = version.version + " · " + String(version.partCount) + edText(" 项", " parts")
        return HStack {
            VStack(alignment: .leading, spacing: 4) { Text(version.title); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if active { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel(edText("正在使用", "Active")) }
            else { Button(edText("使用", "Use")) { library.activate(packageID: version.packageID, version: version.version) }.disabled(library.busy) }
            Button { Task { if let value = try? await library.store.package(id: version.packageID, version: version.version) { licenses = value.licenses; showLicenses = true } } } label: { Image(systemName: "info.circle") }
                .accessibilityLabel(edText("来源与许可证", "Attribution & license"))
        }
    }
}

struct EDLibraryReplacementReview: View {
    let plan: EDALibraryReplacementPlan
    let apply: (Set<String>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmed = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack { Text(plan.original.reference).font(.headline); Image(systemName: "arrow.right"); Text(plan.snapshot.part.name) }
                    EDLibraryGeometryPreview(part: plan.snapshot.part, footprint: false).frame(height: 180)
                }
                if !plan.blockingReasons.isEmpty {
                    Section(edText("需要先处理", "Resolve before replacing")) {
                        Label(edText("引脚位置或映射不兼容，请保留原元件并手动调整连接。", "Pin positions or mapping are incompatible. Keep the original part and adjust connections explicitly."), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        DisclosureGroup(edText("差异详情", "Difference details")) { ForEach(plan.blockingReasons, id: \.self) { Text($0).font(.caption) } }
                    }
                }
                Section(edText("核对差异", "Review differences")) {
                    ForEach(plan.differences, id: \.code) { change in
                        VStack(alignment: .leading, spacing: 4) { Text(label(change.code)); Text(change.detail).font(.caption).foregroundStyle(.secondary) }
                    }
                    if plan.canApply && !plan.differences.isEmpty { Toggle(edText("已核对以上差异", "I reviewed these differences"), isOn: $confirmed) }
                }
            }
            .navigationTitle(edText("替换元件", "Replace component")).edLibraryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(edText("取消", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(edText("替换", "Replace")) { apply(Set(plan.differences.map(\.code))); dismiss() }.disabled(!plan.canApply || (!plan.differences.isEmpty && !confirmed)) }
            }
        }
    }
    private func label(_ code: String) -> String {
        switch code {
        case "device_identity": edText("器件型号", "Device identity")
        case "symbol_pin_layout": edText("引脚位置与编号", "Pin positions & numbering")
        case "symbol_graphics": edText("符号图形", "Symbol artwork")
        case "pin_properties": edText("引脚名称与电气类型", "Pin names & electrical types")
        case "library_source": edText("来源与版本", "Source & version")
        case "footprint_geometry": edText("封装", "Footprint")
        case "pin_pad_mapping": edText("引脚与焊盘映射", "Pin-to-pad mapping")
        default: edText("元件属性", "Part properties")
        }
    }
}
