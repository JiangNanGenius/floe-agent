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
  var body: some View {
    Group {
      if let current = workspace.current {
        HeavyEditorView(controller: current, onClose: { workspace.close() })
      } else {
        NavigationStack {
          ScrollView {
            VStack(alignment: .leading, spacing: 24) {
              Picker(EditorText.t("打开位置", "Open from"), selection: $workspace.entry) {
                ForEach(QualificationEntry.allCases) { entry in Text(entry.title).tag(entry) }
              }.pickerStyle(.segmented)
              Text(EditorText.t("新建作品", "Create work")).font(.title2.bold())
              LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
                ForEach(HeavyEditorKind.allCases, id: \.self) { kind in
                  let descriptor = QualificationWorkspace.descriptor(kind)
                  Button {
                    launch { _ = try await workspace.create(kind) }
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
              Text(EditorText.t("最近作品", "Recent work")).font(.title2.bold())
              let records = workspace.records.filter { $0.entry == workspace.entry }
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
                      Text(workspace.entry.title).font(.caption).foregroundStyle(.secondary)
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
  private func detail(_ kind: HeavyEditorKind) -> String {
    switch kind {
    case .gis: EditorText.t("图层、空间分析与地形", "Layers, spatial analysis and terrain")
    case .score: EditorText.t("五线谱、总谱与分谱", "Notation, scores and parts")
    case .font: EditorText.t("字形、字距与变量字体", "Glyphs, kerning and variable fonts")
    }
  }
}
