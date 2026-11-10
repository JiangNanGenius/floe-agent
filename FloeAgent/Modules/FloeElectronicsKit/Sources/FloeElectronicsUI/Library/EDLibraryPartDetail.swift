// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeElectronicsCore

struct EDLibraryPartDetail: View {
    let entry: EDALibraryEntry
    let project: EDAProject
    let footprints: Bool
    @Bindable var library: EDLibraryController
    let choose: (EDALibraryPlacementSelection) -> Void
    var replace: ((EDALibrarySnapshot) -> Void)?
    @State private var associatedEntry: EDALibraryEntry?
    @State private var showingAssociation = false
    @State private var unit = 1
    @State private var componentID: UUID?
    @State private var highlightedPin: String?
    @State private var selecting = false
    @State private var failure: String?
    @State private var selectionTask: Task<Void, Never>?
    private var currentEntry: EDALibraryEntry { associatedEntry ?? entry }
    private var part: EDALibraryPart { currentEntry.part }
    private var units: [Int] { Array(Set(part.symbol?.pins.map(\.unit).filter { $0 > 0 } ?? [1])).sorted() }
    private var componentOptions: [EDAComponent] {
        let symbols = Dictionary(uniqueKeysWithValues: project.symbols.map { ($0.id, $0) })
        let footprints = Dictionary(uniqueKeysWithValues: project.footprints.map { ($0.id, $0) })
        return project.components.filter { component in
            guard component.fields["FloeLibraryPackage"] == currentEntry.reference.packageID,
                  component.fields["FloeLibraryVersion"] == currentEntry.reference.version,
                  component.fields["FloeLibraryPart"] == part.id,
                  let hash = component.fields[EDALibraryProject.snapshotField],
                  var expected = part.symbol, let actual = symbols[component.symbolID] else { return false }
            expected.id = actual.id; expected.fields[EDALibraryProject.snapshotField] = hash
            guard expected == actual else { return false }
            if var expectedFootprint = part.footprint {
                guard let id = component.footprintID, let actualFootprint = footprints[id] else { return false }
                expectedFootprint.id = id; expectedFootprint.fields[EDALibraryProject.snapshotField] = hash
                return expectedFootprint == actualFootprint
            }
            return component.footprintID == nil
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heading
                previews
                if let failure { Label(failure, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
                controls
                attributes
                pinMapping
                sources
            }.padding(16)
        }
        .sheet(isPresented: $showingAssociation) {
            EDLibraryAssociationSheet(source: currentEntry, library: library) { value in associatedEntry = value; componentID = nil; highlightedPin = nil }
        }
        .onChange(of: unit) { _, _ in highlightedPin = nil }
        .onDisappear { selectionTask?.cancel() }
        .accessibilityIdentifier("electronics.library.partDetail")
    }
    private var heading: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(part.parameters["PartNumber"].flatMap { $0.isEmpty ? nil : $0 } ?? part.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                Text((part.parameters["BindingKind"] == "user-confirmed" ? edText("自定义组合", "Custom combination") : EDLibraryLabels.kind(part.kind)) + " · " + EDLibraryLabels.category(part.category)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { library.toggleFavorite(currentEntry) } label: { Image(systemName: library.isFavorite(currentEntry) ? "star.fill" : "star").frame(width: 36, height: 36) }
                .buttonStyle(.bordered).accessibilityLabel(edText("收藏元件", "Favorite part")).disabled(library.busy)
        }
    }
    private var previews: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { preview(false).frame(minWidth: 190); preview(true).frame(minWidth: 190) }
            VStack(spacing: 12) { preview(false); preview(true) }
        }
    }
    private func preview(_ footprint: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(footprint ? edText("封装", "Footprint") : edText("符号", "Symbol")).font(.subheadline.weight(.medium))
            EDLibraryGeometryPreview(part: part, footprint: footprint, unit: unit, highlighted: footprint ? Set(highlightedPin.flatMap { part.pinMap?.pinToPads[$0] } ?? []) : Set(highlightedPin.map { [$0] } ?? []))
                .frame(height: 170)
            Text(footprint ? part.footprint?.name ?? edText("未关联封装", "No footprint assigned") : part.symbol?.name ?? "—").font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !footprints, units.count > 1 {
                Picker(edText("单元", "Unit"), selection: $unit) { ForEach(units, id: \.self) { Text(edText("单元 ", "Unit ") + String($0)).tag($0) } }.pickerStyle(.menu)
                Picker(edText("元件", "Component"), selection: $componentID) {
                    Text(edText("新元件", "New component")).tag(UUID?.none)
                    ForEach(componentOptions) { Text($0.reference).tag(Optional($0.id)) }
                }.pickerStyle(.menu)
            }
            if part.symbol != nil {
                Button { showingAssociation = true } label: { Label(part.footprint == nil ? edText("关联封装…", "Assign footprint…") : edText("另存为自定义组合…", "Create a custom combination…"), systemImage: "link") }
                    .disabled(library.busy || !part.isPlaceable)
            }
            HStack {
                Button { select(replacing: false) } label: {
                    Label(footprints ? edText("放置到 PCB", "Place on PCB") : edText("放置到原理图", "Place on schematic"), systemImage: "plus.square")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
                    .disabled(selecting || library.busy || !part.isPlaceable || (footprints ? part.footprint == nil : part.symbol == nil))
                    .accessibilityIdentifier("electronics.library.place")
                if replace != nil, part.symbol != nil {
                    Button { select(replacing: true) } label: { Image(systemName: "arrow.triangle.2.circlepath").frame(width: 24, height: 24) }
                        .buttonStyle(.bordered).disabled(selecting || library.busy).accessibilityLabel(edText("替换所选元件", "Replace selected component"))
                }
                if selecting { ProgressView().controlSize(.small) }
            }
        }
    }
    private var attributes: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            if !part.manufacturer.isEmpty { attribute(edText("厂商", "Manufacturer"), part.manufacturer) }
            attribute(edText("引脚", "Pins"), String(part.pinCount))
            if let description = part.parameters["Description"] ?? part.parameters["description"], !description.isEmpty { attribute(edText("说明", "Description"), description) }
            DisclosureGroup(edText("全部属性", "All properties")) {
                ForEach(part.parameters.keys.sorted(), id: \.self) { key in
                    HStack(alignment: .top) { Text(key).foregroundStyle(.secondary); Spacer(); Text(part.parameters[key] ?? "").textSelection(.enabled) }.font(.caption).padding(.vertical, 2)
                }
            }.gridCellColumns(2)
        }.font(.callout)
    }
    private func attribute(_ key: String, _ value: String) -> some View {
        GridRow { Text(key).foregroundStyle(.secondary); Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
    }
    @ViewBuilder private var pinMapping: some View {
        if let symbol = part.symbol {
            VStack(alignment: .leading, spacing: 7) {
                Text(edText("引脚与焊盘", "Pins & pads")).font(.headline)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(symbol.pins.sorted { $0.unit == $1.unit ? $0.number.localizedStandardCompare($1.number) == .orderedAscending : $0.unit < $1.unit }) { pin in
                            Button { highlightedPin = highlightedPin == pin.number ? nil : pin.number } label: {
                                HStack {
                                    Text(pin.number).monospacedDigit().frame(width: 34, alignment: .leading)
                                    Text(pin.name.isEmpty ? "—" : pin.name).frame(maxWidth: .infinity, alignment: .leading)
                                    if units.count > 1 { Text("U" + String(pin.unit)).foregroundStyle(.secondary) }
                                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                    Text(part.pinMap?.pinToPads[pin.number]?.joined(separator: ", ") ?? "—").monospacedDigit().frame(minWidth: 34, alignment: .trailing)
                                }.font(.caption).padding(.vertical, 7).padding(.horizontal, 8).contentShape(Rectangle())
                                    .background(highlightedPin == pin.number ? Color.accentColor.opacity(0.12) : .clear)
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }.frame(maxHeight: 200)
                if part.pinMap == nil { Text(edText("此符号尚未关联封装。", "This symbol has no assigned footprint.")).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private var sources: some View {
        DisclosureGroup(edText("来源与兼容性", "Sources & compatibility")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(currentEntry.reference.packageID + " · " + currentEntry.reference.version).font(.caption).textSelection(.enabled)
                ForEach(Array(part.sources.enumerated()), id: \.offset) { _, source in
                    if let text = source.url, let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? "") { Link(source.path, destination: url).font(.caption) }
                    else { Text(source.path).font(.caption).textSelection(.enabled) }
                }
                ForEach(Array(part.notices.enumerated()), id: \.offset) { _, notice in Text(notice.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func select(replacing: Bool) {
        guard !selecting else { return }; selecting = true; failure = nil
        selectionTask = Task {
            defer { selecting = false; selectionTask = nil }
            do {
                let snapshot = try await library.snapshot(currentEntry.reference)
                try Task.checkCancellation()
                if replacing { replace?(snapshot) }
                else { choose(.init(snapshot: snapshot, unit: unit, existingComponentID: componentID)) }
            } catch {
                guard !Task.isCancelled else { return }
                failure = edText("无法读取此版本，请刷新元件库后重试。", "Couldn’t read this version. Refresh the library and retry.")
            }
        }
    }
}
