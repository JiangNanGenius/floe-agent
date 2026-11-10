// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeElectronicsCore

/// Selection chooses a definition; placement happens on the existing canvas.
struct EDPartChooser: View {
    let project: EDAProject
    let footprints: Bool
    var library: EDLibraryController? = nil
    let choose: (UUID) -> Void
    var chooseLibrary: ((EDALibraryPlacementSelection) -> Void)? = nil
    var replaceLibrary: ((EDALibrarySnapshot) -> Void)? = nil
    var onUpdates: (() -> Void)? = nil
    @State private var collection = 0
    var body: some View {
        VStack(spacing: 0) {
            if library != nil {
                Picker(edText("元件来源", "Part source"), selection: $collection) {
                    Text(edText("元件库", "Libraries")).tag(0); Text(edText("当前项目", "This project")).tag(1)
                }.pickerStyle(.segmented).padding(12)
            }
            if collection == 0, let library, let chooseLibrary {
                EDLibraryChooser(project: project, footprints: footprints, library: library, choose: chooseLibrary, replace: replaceLibrary, onUpdates: onUpdates)
            } else { EDProjectPartChooser(project: project, footprints: footprints, choose: choose) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EDProjectPartChooser: View {
    let project: EDAProject
    let footprints: Bool
    let choose: (UUID) -> Void
    @State private var query = ""
    private var items: [(id: UUID, name: String, detail: String)] {
        let all = footprints
            ? project.footprints.map { ($0.id, $0.name, edText("焊盘 ", "Pads: ") + String($0.pads.count)) }
            : project.symbols.map { ($0.id, $0.name, $0.referencePrefix + " · " + edText("引脚 ", "Pins: ") + String($0.pins.count)) }
        return all.filter { query.isEmpty || $0.1.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(footprints ? edText("搜索封装", "Search footprints") : edText("搜索元件", "Search parts"), text: $query)
                    .textFieldStyle(.plain)
            }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10)).padding(12)
            if items.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    ForEach(items, id: \.id) { item in
                        Button { choose(item.id) } label: {
                            HStack(spacing: 16) {
                                partPreview(item.id)
                                    .frame(width: 88, height: 68).background(.background).clipShape(RoundedRectangle(cornerRadius: 6))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name).foregroundStyle(.primary)
                                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "plus.circle").foregroundStyle(Color.accentColor)
                            }.padding(.vertical, 4)
                        }.accessibilityLabel(edText("放置 ", "Place ") + item.name)
                            .accessibilityIdentifier("electronics.part." + item.id.uuidString.lowercased())
                    }
                }.listStyle(.plain)
            }
        }
    }
    private func partPreview(_ id:UUID)->some View{
        let scene:EDInspectorPreviewScene?
        if footprints{scene=project.footprints.first(where:{$0.id==id}).map{.libraryFootprint($0,project:project)}}
        else{scene=project.symbols.first(where:{$0.id==id}).map{.symbol($0,project:project)}}
        return Canvas{canvas,size in
            guard let scene else{return}
            let projection=EDAProjection(bounds:scene.bounds,size:size,padding:6)
            EDAPlot.draw(project:scene.project,context:scene.context,projection:projection,in:&canvas)
        }
    }
}

struct EDProjectNavigator: View {
    @Bindable var session: EDWorkbenchSession
    let tab: EDWorkspaceTab
    @Binding var sheetID: UUID?
    @Binding var boardID: UUID?
    @Binding var symbolID: UUID?
    @Binding var footprintID: UUID?
    let didChoose: () -> Void
    @State private var query = ""
    var body: some View {
        List {
            if tab == .schematic {
                Section(edText("图页", "Sheets")) {
                    ForEach(session.project.sheets) { sheet in
                        Button { sheetID = sheet.id; session.selection = .none; didChoose() } label: {
                            Label(sheet.name, systemImage: "doc")
                        }
                    }
                    Button(edText("添加图页", "Add sheet"), systemImage: "plus") {
                        let sheet = EDASheet(name: edText("图页 ", "Sheet ") + String(session.project.sheets.count + 1))
                        apply([.putSheet(sheet)]) { sheetID = sheet.id }; didChoose()
                    }
                }
                if let sheet = session.project.sheets.first(where: { $0.id == sheetID }) ?? session.project.sheets.first {
                    Section(edText("元件", "Components")) {
                        ForEach(sheet.symbols) { placement in
                            if let component = session.project.components.first(where: { $0.id == placement.componentID }),
                               query.isEmpty || (component.reference + " " + component.value).localizedCaseInsensitiveContains(query) {
                                Button {
                                    session.requestFocus(.init(context: .schematic(sheetID: sheet.id), positionMillimetres: placement.position, objectIDs: [placement.id])); didChoose()
                                } label: { Label(component.reference + " " + component.value, systemImage: "cpu") }
                            }
                        }
                    }
                }
            } else if tab == .board {
                Section("PCB") {
                    ForEach(session.project.boards) { board in
                        Button { boardID = board.id; session.selection = .none; didChoose() } label: { Label(board.name, systemImage: "square") }
                    }
                }
                if let board = session.project.boards.first(where: { $0.id == boardID }) ?? session.project.boards.first {
                    Section(edText("元件", "Components")) {
                        ForEach(board.footprints.filter { query.isEmpty || ($0.reference + " " + $0.value).localizedCaseInsensitiveContains(query) }) { item in
                            Button {
                                session.requestFocus(.init(context: .board(boardID: board.id), positionMillimetres: item.position, objectIDs: [item.id])); didChoose()
                            } label: { Label(item.reference + (item.value.isEmpty ? "" : " " + item.value), systemImage: item.locked ? "lock" : "cpu") }
                        }
                    }
                }
            } else if tab == .symbols {
                Section(edText("符号", "Symbols")) {
                    ForEach(session.project.symbols.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { item in
                        Button { symbolID = item.id; session.selection = .none; didChoose() } label: { Text(item.name) }
                    }
                    Button(edText("新建符号", "New symbol"), systemImage: "plus") {
                        let item = EDASymbolDefinition(name: edText("自建符号", "Custom symbol"), pins: [.init(number: "1", position: .init(-2.54, 0)), .init(number: "2", position: .init(2.54, 0))], graphics: [.rectangle(.init(-1.27, -1.27), .init(1.27, 1.27), width: 0.2)])
                        apply([.putSymbol(item)]) { symbolID = item.id }; didChoose()
                    }
                }
            } else if tab == .footprints {
                Section(edText("封装", "Footprints")) {
                    ForEach(session.project.footprints.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { item in
                        Button { footprintID = item.id; session.selection = .none; didChoose() } label: { Text(item.name) }
                    }
                    Button(edText("新建封装", "New footprint"), systemImage: "plus") {
                        let item = EDAFootprintDefinition(name: edText("自建封装", "Custom footprint"), pads: [.init(number: "1", position: .zero)])
                        apply([.putFootprintDefinition(item)]) { footprintID = item.id }; didChoose()
                    }
                }
            }
        }.listStyle(.sidebar).searchable(text: $query, prompt: edText("搜索项目", "Search project"))
    }
    private func apply(_ edits: [EDAEdit], after: @escaping @MainActor () -> Void) {
        let revision = session.revision
        Task { do { try await session.apply(edits, expectedRevision: revision); after() } catch { session.report(error) } }
    }
}
