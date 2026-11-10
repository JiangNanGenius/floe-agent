// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeElectronicsCore

/// A focused EDA association dialog. The editor remains the existing canvas;
/// here the user chooses actual geometry and confirms the electrical mapping.
struct EDLibraryAssociationSheet: View {
    let source: EDALibraryEntry
    @Bindable var library: EDLibraryController
    let created: (EDALibraryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var physicalID: String?
    @State private var assignment: [String: [String]] = [:]
    @State private var acknowledgeUnused = false
    @State private var confirmed = false
    @State private var name = ""
    @State private var saving = false
    @State private var failure: String?
    private var physical: EDALibraryEntry? { library.catalog.entries.first { $0.id == physicalID } }
    private var pins: [String] { Array(Set(source.part.symbol?.pins.map(\.number) ?? [])).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    private var pads: [String] { Array(Set(physical?.part.footprint?.pads.map(\.number).filter { !$0.isEmpty } ?? [])).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    private var unused: [String] { let assigned = Set(assignment.values.flatMap { $0 }); return pads.filter { !assigned.contains($0) } }
    private var map: EDALibraryPinMap { .init(pinToPads: assignment, unconnectedPads: acknowledgeUnused ? unused : []) }
    private var valid: Bool {
        guard let symbol = source.part.symbol, let footprint = physical?.part.footprint, confirmed else { return false }
        do { try map.validate(symbol: symbol, footprint: footprint); return true } catch { return false }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(edText("组合名称（可选）", "Combination name (optional)"), text: $name)
                    Text(edText("这是由你明确关联的自定义组合，不代表已核定的厂商型号。原符号、封装和来源会完整保留。", "This is an explicitly assigned custom combination, not a qualified manufacturer part. Original geometry and sources are preserved.")).font(.caption).foregroundStyle(.secondary)
                    NavigationLink {
                        EDLibraryFootprintPicker(library: library) { entry in select(entry) }
                    } label: { LabeledContent(edText("选择封装", "Choose footprint"), value: physical?.part.footprint?.name ?? edText("未选择", "Not selected")) }
                }
                Section {
                    HStack(spacing: 12) {
                        EDLibraryGeometryPreview(part: source.part, footprint: false).frame(height: 145)
                        if let physical { EDLibraryGeometryPreview(part: physical.part, footprint: true).frame(height: 145) }
                    }
                }
                if physical != nil {
                    Section(edText("引脚 → 焊盘", "Pin → pad")) {
                        ForEach(pins, id: \.self) { pin in mappingRow(pin) }
                    }
                    if !unused.isEmpty {
                        Section {
                            Toggle(edText("以下焊盘不连接逻辑引脚", "These pads have no logical connection"), isOn: $acknowledgeUnused)
                            Text(unused.joined(separator: ", ")).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Section { Toggle(edText("已核对全部引脚与焊盘", "I reviewed all pin-to-pad assignments"), isOn: $confirmed) }
                }
                if let failure { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            .navigationTitle(edText("关联符号与封装", "Assign a footprint")).edLibraryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(edText("取消", "Cancel")) { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button(edText("保存组合", "Save combination")) { save() }.disabled(!valid || saving || library.busy) }
            }
            .overlay { if saving { ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        }.interactiveDismissDisabled(saving)
    }
    private func mappingRow(_ number: String) -> some View {
        let names = Array(Set(source.part.symbol?.pins.filter { $0.number == number }.map(\.name) ?? [])).sorted().joined(separator: " / ")
        return HStack {
            Text(number).monospacedDigit().frame(width: 34, alignment: .leading)
            Text(names).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
            Menu {
                Button(edText("不连接焊盘", "No pad connection")) { assignment[number] = []; confirmed = false }
                Divider()
                ForEach(pads, id: \.self) { pad in
                    Toggle(pad, isOn: Binding(get: { assignment[number]?.contains(pad) == true }, set: { enabled in
                        var value = Set(assignment[number] ?? []); if enabled { value.insert(pad) } else { value.remove(pad) }
                        assignment[number] = value.sorted(); confirmed = false; acknowledgeUnused = false
                    }))
                }
                Divider()
                Button(edText("清除选择", "Clear assignment")) { assignment[number] = nil; confirmed = false }
            } label: {
                if let value = assignment[number] { Text(value.isEmpty ? edText("不连接", "No connection") : value.joined(separator: ", ")).monospacedDigit() }
                else { Text(edText("未指定", "Unassigned")).foregroundStyle(.orange) }
            }
        }
    }
    private func select(_ entry: EDALibraryEntry) {
        physicalID = entry.id; confirmed = false; acknowledgeUnused = false
        if let symbol = source.part.symbol, let footprint = entry.part.footprint,
           let matching = try? EDALibraryPinMap.matchingNumbers(symbol: symbol, footprint: footprint) { assignment = matching.pinToPads }
        else { assignment = [:] }
    }
    private func save() {
        guard let physical, valid else { return }; saving = true; failure = nil
        Task {
            defer { saving = false }
            do {
                let value = try await library.associate(symbol: source.reference, footprint: physical.reference, map: map, name: name)
                created(value); dismiss()
            } catch { failure = edText("未保存。请核对映射，或重新选择封装后重试。", "Not saved. Check the mapping, or reselect the footprint and retry.") }
        }
    }
}

private struct EDLibraryFootprintPicker: View {
    @Bindable var library: EDLibraryController
    let select: (EDALibraryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var entries: [EDALibraryEntry] {
        library.catalog.entries.filter { $0.part.footprint != nil && $0.part.isPlaceable && (query.isEmpty || ($0.part.name + " " + ($0.part.footprint?.name ?? "")).localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        List(entries) { entry in
            Button { select(entry); dismiss() } label: {
                HStack(spacing: 12) {
                    EDLibraryGeometryPreview(part: entry.part, footprint: true).frame(width: 78, height: 65)
                    VStack(alignment: .leading, spacing: 4) { Text(entry.part.footprint?.name ?? entry.part.name); Text(String(entry.part.footprint?.pads.count ?? 0) + edText(" 个焊盘", " pads")).font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 3)
            }
        }.searchable(text: $query, prompt: edText("搜索封装", "Search footprints"))
            .navigationTitle(edText("选择封装", "Choose footprint")).edLibraryInlineNavigationTitle()
    }
}
