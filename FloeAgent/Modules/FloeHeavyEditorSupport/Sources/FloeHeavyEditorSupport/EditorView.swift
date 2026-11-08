// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Native controls own the workbench. The retained WebKit service draws only
/// the domain canvas and runs fixed bundled computation/format engines.
public struct HeavyEditorView: View {
  @Bindable private var controller: HeavyEditorController
  private let onClose: () -> Void
  private let closeLabel: String?
  private let outline: AnyView?
  private let canvasToolbar: AnyView?
  private let inspector: AnyView?
  private let canvasContent: AnyView?
  private let bottomBar: AnyView?
  @State private var panel: Panel?
  @State private var visibleModal: HeavyEditorNativeModal?
  private enum Panel: String, Identifiable {
    case outline, inspector
    var id: String { rawValue }
  }

  public init(
    controller: HeavyEditorController, onClose: @escaping () -> Void = {},
    outline: AnyView? = nil, canvasToolbar: AnyView? = nil,
    inspector: AnyView? = nil, canvasContent: AnyView? = nil, bottomBar: AnyView? = nil,
    closeLabel: String? = nil
  ) {
    self.controller = controller
    self.onClose = onClose
    self.closeLabel = closeLabel
    self.outline = outline
    self.canvasToolbar = canvasToolbar
    self.inspector = inspector
    self.canvasContent = canvasContent
    self.bottomBar = bottomBar
  }
  public var body: some View {
    GeometryReader { geometry in
      let wide = geometry.size.width >= 1000
      let full = geometry.size.width >= 1250
      VStack(spacing: 0) {
        header(wide: wide, full: full)
        Divider()
        HStack(spacing: 0) {
          if wide, let outline {
            outline.frame(width: 230)
            Divider()
          }
          VStack(spacing: 0) {
            if let canvasToolbar {
              canvasToolbar.padding(.horizontal, 12).padding(.vertical, 8)
              Divider()
            }
            ZStack {
              HeavyEditorWebSurface(webView: controller.webView)
                .opacity(canvasContent == nil ? 1 : 0)
                .allowsHitTesting(canvasContent == nil)
                .accessibilityHidden(canvasContent != nil)
              if let canvasContent { canvasContent.background(.background) }
              if !controller.isReady, controller.errorMessage == nil {
                ProgressView(EditorText.t("正在打开…", "Opening…"))
              }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let bottomBar {
              Divider()
              bottomBar.padding(10)
            }
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
          if full, let inspector {
            Divider()
            inspector.frame(width: 280)
          }
        }
      }.background(.background)
    }
    .sheet(item: $panel, onDismiss: { visibleModal = controller.nativeModal }) { value in
      NavigationStack {
        Group { if value == .outline { outline } else { inspector } }
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button(EditorText.t("完成", "Done")) { panel = nil }
            }
          }
      }.editorSheetSizing()
    }
    .sheet(item: $visibleModal, onDismiss: { controller.nativeModal = nil }) { modal in
      switch modal {
      case .command(let request): HeavyEditorParameterView(controller: controller, request: request)
      case .result(let request):
        HeavyEditorResultView(request: request) { controller.nativeModal = nil }
      }
    }
    .onChange(of: controller.nativeModal?.id) { _, value in
      if value == nil { visibleModal = nil }
      else if panel != nil { panel = nil }
      else { visibleModal = controller.nativeModal }
    }
    .fileImporter(
      isPresented: $controller.importRequested, allowedContentTypes: allowedImports,
      allowsMultipleSelection: true
    ) { result in
      Task { @MainActor in
        do {
          for url in try result.get() {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            _ = try await controller.execute(
              controller.importCommand,
              arguments: .object([
                "name": .string(url.lastPathComponent),
                "base64": .string(try Data(contentsOf: url).base64EncodedString()),
              ]))
          }
        } catch { controller.errorMessage = error.localizedDescription }
      }
    }
    .alert(
      EditorText.t("无法完成操作", "Unable to complete action"),
      isPresented: Binding(
        get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })
    ) {
      Button(EditorText.t("好", "OK")) { controller.errorMessage = nil }
    } message: {
      Text(controller.errorMessage ?? "")
    }
  }
  private func header(wide: Bool, full: Bool) -> some View {
    HStack(spacing: 12) {
      if !wide, outline != nil {
        Button {
          panel = .outline
        } label: {
          Image(systemName: "sidebar.left")
        }.accessibilityLabel(EditorText.t("列表", "Outline"))
      }
      Label(controller.document.title, systemImage: controller.descriptor.symbol).font(.headline)
        .lineLimit(1)
      Spacer(minLength: 4)
      actionMenu
      if !full, inspector != nil {
        Button {
          panel = .inspector
        } label: {
          Image(systemName: "sidebar.right")
        }.accessibilityLabel(EditorText.t("属性", "Inspector"))
      }
      if controller.isWorking {
        ProgressView().controlSize(.small)
        Button {
          controller.cancel()
        } label: {
          Image(systemName: "stop.circle")
        }.accessibilityLabel(EditorText.t("取消当前操作", "Cancel current action"))
      }
      Button {
        controller.requestImport()
      } label: {
        Image(systemName: "square.and.arrow.down")
      }.accessibilityLabel(EditorText.t("导入", "Import"))
      if wide {
        Button {
          controller.runCommand("history.undo")
        } label: {
          Image(systemName: "arrow.uturn.backward")
        }.accessibilityLabel(EditorText.t("撤销", "Undo")).keyboardShortcut("z", modifiers: .command)
        Button {
          controller.runCommand("history.redo")
        } label: {
          Image(systemName: "arrow.uturn.forward")
        }.accessibilityLabel(EditorText.t("重做", "Redo")).keyboardShortcut(
          "z", modifiers: [.command, .shift])
      }
      Button {
        controller.runCommand("document.save")
      } label: {
        Image(systemName: "checkmark.circle")
      }.accessibilityLabel(EditorText.t("保存", "Save")).keyboardShortcut("s", modifiers: .command)
      if controller.onAssistant != nil {
        Button {
          controller.onAssistant?()
        } label: {
          Image(systemName: "sparkles")
        }.accessibilityLabel(EditorText.t("助手", "Assistant"))
      }
      Button(closeLabel ?? EditorText.t("完成", "Done")) {
        Task {
          await controller.endPresentation()
          onClose()
        }
      }
    }.buttonStyle(.borderless).controlSize(.regular).padding(.horizontal, 14).frame(minHeight: 52)
  }
  private var actionMenu: some View {
    Menu {
      ForEach(commandGroups, id: \.self) { group in
        Menu(group) {
          ForEach(
            Array(
              controller.commandCatalog.filter {
                $0["group"].string == group && $0["hidden"].bool != true
              }.enumerated()), id: \.offset
          ) { _, item in
            Button(item["title"].string ?? "") {
              if let name = item["id"].string { controller.showCommand(name) }
            }
          }
        }
      }
    } label: {
      Image(systemName: "slider.horizontal.3")
    }
    .accessibilityLabel(EditorText.t("全部工具", "All tools")).disabled(!controller.isReady)
  }
  private var commandGroups: [String] {
    var groups: [String] = []
    for value in controller.commandCatalog where value["hidden"].bool != true {
      if let group = value["group"].string, !groups.contains(group) { groups.append(group) }
    }
    return groups
  }
  private var allowedImports: [UTType] {
    let types = controller.descriptor.importExtensions.compactMap { UTType(filenameExtension: $0) }
    return types.isEmpty ? [.data] : types + [.data]
  }
}

extension View {
  @ViewBuilder func editorSheetSizing() -> some View {
    #if os(iOS)
      self.presentationDetents([.medium, .large])
    #else
      self.frame(minWidth: 440, idealWidth: 560, minHeight: 460, idealHeight: 680)
    #endif
  }
}
#if canImport(UIKit)
  private struct HeavyEditorWebSurface: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
  }
#else
  private struct HeavyEditorWebSurface: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
  }
#endif
