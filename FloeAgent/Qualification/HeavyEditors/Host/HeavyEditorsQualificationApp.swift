// SPDX-License-Identifier: MPL-2.0
import FloeFontKit
import FloeGISKit
import FloeHeavyEditorSupport
import FloeScoreKit
import SwiftUI

#if os(macOS)
  import AppKit
#endif

@main struct HeavyEditorsQualificationApp: App {
  @State private var workspace: QualificationWorkspace?
  @State private var startupError: String?
  init() {
    do { _workspace = State(initialValue: try QualificationWorkspace()) } catch {
      _startupError = State(initialValue: error.localizedDescription)
    }
  }
  var body: some Scene {
    WindowGroup("Floe Editors QA") {
      Group {
        if let workspace {
          QualificationRootView(workspace: workspace)
        } else {
          ContentUnavailableView(
            EditorText.t("无法打开工作台", "Unable to open workbench"),
            systemImage: "exclamationmark.triangle", description: Text(startupError ?? ""))
        }
      }
      #if os(macOS)
        .frame(minWidth: 900, minHeight: 650)
        .onAppear {
          NSApp.setActivationPolicy(.regular)
          NSApp.activate(ignoringOtherApps: true)
        }
      #endif
    }
  }
}
struct QualificationRootView: View {
  @Bindable var workspace: QualificationWorkspace
  @State private var path: [Destination] = []
  @State private var gisOrigin: QualificationEntry = .space
  private enum Destination: Hashable { case music, settings, fontManager }
  var body: some View {
    Group {
      if let current = workspace.current {
        switch current.descriptor.kind {
        case .gis: GISEditorView(controller: current, onClose: { workspace.close() })
        case .score: ScoreEditorView(controller: current, onClose: { workspace.close() })
        case .font: FontEditorView(controller: current, onClose: { workspace.close() })
        }
      } else {
        NavigationStack(path: $path) {
          ScrollView {
            VStack(alignment: .leading, spacing: 24) {
              Picker(EditorText.t("打开位置", "Open from"), selection: $gisOrigin) {
                ForEach([QualificationEntry.space, .notes, .task]) { entry in Text(entry.title).tag(entry) }
              }.pickerStyle(.segmented)
              Text(EditorText.t("新建作品", "Create work")).font(.title2.bold())
              LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
                ForEach([HeavyEditorKind.gis], id: \.self) { kind in
                  let descriptor = QualificationWorkspace.descriptor(kind)
                  Button {
                    launch { workspace.entry = gisOrigin; _ = try await workspace.create(kind) }
                  } label: {
                    VStack(alignment: .leading, spacing: 14) {
                      Image(systemName: descriptor.symbol).font(.system(size: 28)).foregroundStyle(
                        .tint)
                      Text(descriptor.title).font(.headline)
                      Text(detail(kind)).font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 140, alignment: .leading).padding(20)
                      .background(.background, in: RoundedRectangle(cornerRadius: 18)).overlay(
                        RoundedRectangle(cornerRadius: 18).stroke(.quaternary))
                  }.buttonStyle(.plain).disabled(workspace.isOpening).accessibilityIdentifier(
                    "create-" + kind.rawValue)
                }
              }
              NavigationLink(value: Destination.music) {
                Label(EditorText.t("音乐编辑器", "Music editor"), systemImage: "music.note.list")
                  .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(16)
              }.accessibilityIdentifier("open-music")
              NavigationLink(value: Destination.settings) {
                Label(EditorText.t("设置", "Settings"), systemImage: "gearshape")
                  .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(16)
              }.accessibilityIdentifier("open-settings")
              Text(EditorText.t("最近作品", "Recent work")).font(.title2.bold())
              let records = workspace.records.filter { $0.entry == gisOrigin && $0.kind == .gis }
              if records.isEmpty {
                ContentUnavailableView(
                  EditorText.t("还没有作品", "No work yet"), systemImage: "folder",
                  description: Text(
                    EditorText.t(
                      "从上方创建，或在编辑器中导入文件。", "Create above, or import files inside an editor.")))
              }
              ForEach(records.reversed()) { record in
                Button {
                  launch { _ = try await workspace.open(record) }
                } label: {
                  HStack(spacing: 14) {
                    Image(systemName: QualificationWorkspace.descriptor(record.kind).symbol).font(
                      .title2)
                    VStack(alignment: .leading) {
                      Text(record.title).font(.headline)
                      Text(record.entry.title).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                  }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
              }
              if !workspace.exports.isEmpty {
                Text(EditorText.t("导出文件", "Exports")).font(.title2.bold())
                ForEach(workspace.exports.reversed()) { file in
                  HStack {
                    Label(file.name, systemImage: "doc")
                    Spacer()
                    ShareLink(item: workspace.root.appendingPathComponent(file.relativePath)) {
                      Image(systemName: "square.and.arrow.up")
                    }
                  }.padding(.vertical, 8)
                }
              }
            }.padding(24).frame(maxWidth: 1100)
          }.background(Color.secondary.opacity(0.05)).navigationTitle(
            EditorText.t("预研工作台", "Editor workbenches")
          )
          .navigationDestination(for: Destination.self) { destination in
            switch destination {
            case .music:
              parentWorkspace(.score, title: EditorText.t("音乐编辑器", "Music editor"))
            case .settings:
              List {
                NavigationLink(value: Destination.fontManager) {
                  Label(EditorText.t("字体管理器", "Font manager"), systemImage: "textformat")
                }.accessibilityIdentifier("open-font-manager")
              }.navigationTitle(EditorText.t("设置", "Settings"))
            case .fontManager:
              parentWorkspace(.font, title: EditorText.t("字体管理器", "Font manager"))
            }
          }
          .overlay { if workspace.isOpening { ProgressView() } }
        }
      }
    }.overlay(alignment: .bottomLeading) {
      if let status = workspace.smokeStatus {
        Text(status).font(.caption.monospaced()).padding(8).background(
          .regularMaterial, in: RoundedRectangle(cornerRadius: 8)
        ).padding(8)
      }
    }
    .task { await QualificationSmoke.runIfRequested(workspace) }
    .alert(
      EditorText.t("无法完成操作", "Unable to complete action"),
      isPresented: Binding(
        get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })
    ) {
      Button(EditorText.t("好", "OK")) { workspace.error = nil }
    } message: {
      Text(workspace.error ?? "")
    }
  }
  private func launch(_ work: @escaping @MainActor () async throws -> Void) {
    workspace.isOpening = true
    Task {
      defer { workspace.isOpening = false }
      do { try await work() } catch { workspace.error = error.localizedDescription }
    }
  }
  private func parentWorkspace(_ kind: HeavyEditorKind, title: String) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Button {
          launch {
            workspace.entry = kind == .score ? .music : .fontManager
            _ = try await workspace.create(kind)
          }
        } label: {
          Label(kind == .score ? EditorText.t("新建乐谱", "New score") : EditorText.t("新建字体", "New font"),
                systemImage: "plus")
            .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }.accessibilityIdentifier("create-" + kind.rawValue)
        let records = workspace.records.filter { $0.kind == kind }
        if records.isEmpty {
          ContentUnavailableView(EditorText.t("还没有作品", "No work yet"), systemImage: "folder")
        }
        ForEach(records.reversed()) { record in
          Button {
            launch { _ = try await workspace.open(record) }
          } label: {
            HStack {
              Label(record.title, systemImage: QualificationWorkspace.descriptor(kind).symbol)
              Spacer()
              Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
          }.buttonStyle(.borderless)
        }
      }.padding(24)
    }.navigationTitle(title)
  }
  private func detail(_ kind: HeavyEditorKind) -> String {
    switch kind {
    case .gis: EditorText.t("图层、空间分析与地形", "Layers, spatial analysis and terrain")
    case .score: EditorText.t("五线谱、总谱与分谱", "Notation, scores and parts")
    case .font: EditorText.t("字形、字距与变量字体", "Glyphs, kerning and variable fonts")
    }
  }
}
