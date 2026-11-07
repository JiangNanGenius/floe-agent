// SPDX-License-Identifier: MPL-2.0
import SwiftUI

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

struct HeavyEditorParameterView: View {
  @Bindable var controller: HeavyEditorController
  let request: HeavyEditorCommandRequest
  @State private var schema: EditorJSON = .null
  @State private var values: [String: EditorJSON]
  @State private var feedback: String?
  @State private var applying = false
  @State private var resultRequest: HeavyEditorResultRequest?
  init(controller: HeavyEditorController, request: HeavyEditorCommandRequest) {
    self.controller = controller
    self.request = request
    _values = State(initialValue: request.arguments.object)
  }
  var body: some View {
    Group {
      if let resultRequest {
        HeavyEditorResultView(request: resultRequest) { controller.nativeModal = nil }
      } else { parameterForm }
    }.editorSheetSizing().task(id: values) { await refreshSchema() }
  }
  private var parameterForm: some View {
    NavigationStack {
      Form {
        if schema == .null { ProgressView() }
        ForEach(Array(schema["fields"].array.enumerated()), id: \.offset) { _, field in
          if let key = field["key"].string { fieldView(field, key: key) }
        }
        if let feedback { Section { Text(feedback).foregroundStyle(.red) } }
      }.formStyle(.grouped)
        .navigationTitle(schema["title"].string ?? controller.descriptor.title)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(EditorText.t("取消", "Cancel")) { controller.nativeModal = nil }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button(EditorText.t("应用", "Apply")) { apply() }.disabled(
              schema == .null || applying || controller.isWorking)
          }
        }
    }
  }
  @ViewBuilder private func fieldView(_ field: EditorJSON, key: String) -> some View {
    let label = field["label"].string ?? key
    switch field["type"].string ?? "text" {
    case "checkbox":
      Toggle(
        label, isOn: Binding(get: { values[key]?.bool ?? false }, set: { values[key] = .bool($0) }))
    case "select":
      let options = field["options"].array
      Picker(
        label,
        selection: Binding(
          get: { options.firstIndex { optionValue($0) == values[key] } ?? 0 },
          set: { index in
            if options.indices.contains(index) { values[key] = optionValue(options[index]) }
          })
      ) {
        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
          Text(option["label"].string ?? display(optionValue(option))).tag(index)
        }
      }
    case "textarea":
      Section(label) {
        TextEditor(text: textBinding(key)).font(.body.monospaced()).frame(minHeight: 120)
      }
    case "color":
      ColorPicker(
        label,
        selection: Binding(
          get: { color(values[key]?.string ?? "#2879c7") }, set: { values[key] = .string(hex($0)) }),
        supportsOpacity: false)
    case "range":
      let lower = field["min"].number ?? 0
      let upper = max(lower + 0.001, field["max"].number ?? 100)
      LabeledContent(label) {
        Slider(
          value: Binding(
            get: { min(upper, max(lower, values[key]?.number ?? lower)) },
            set: { values[key] = .number($0) }), in: lower...upper)
        Text(display(values[key] ?? .number(lower))).monospacedDigit().frame(minWidth: 44)
      }
    case "number":
      TextField(
        label,
        text: Binding(
          get: { display(values[key] ?? .string("")) },
          set: { text in
            values[key] = Double(text).flatMap { $0.isFinite ? .number($0) : nil } ?? .string(text)
          })
      )
      #if os(iOS)
        .keyboardType(.numbersAndPunctuation)
      #endif
    default:
      TextField(label, text: textBinding(key))
    }
  }
  private func textBinding(_ key: String) -> Binding<String> {
    Binding(get: { display(values[key] ?? .string("")) }, set: { values[key] = .string($0) })
  }
  private func optionValue(_ option: EditorJSON) -> EditorJSON {
    if case .object = option { return option["value"] }
    return option
  }
  private func refreshSchema() async {
    do {
      let result = try await controller.commandForm(request.command, arguments: .object(values))
      guard !Task.isCancelled else { return }
      var updated = values
      for field in result["fields"].array {
        guard let key = field["key"].string else { continue }
        if updated[key] == nil, field["default"] != .null { updated[key] = field["default"] }
        if field["type"].string == "select" {
          let options = field["options"].array.map(optionValue)
          if !options.contains(updated[key] ?? .null) {
            updated[key] =
              options.contains(field["default"]) ? field["default"] : options.first ?? .string("")
          }
        }
      }
      schema = result
      if updated != values { values = updated }
    } catch { if !Task.isCancelled { feedback = error.localizedDescription } }
  }
  private func apply() {
    applying = true
    Task { @MainActor in
      defer { applying = false }
      do {
        var arguments = values
        for field in schema["fields"].array where field["type"].string == "number" {
          guard let key = field["key"].string else { continue }
          if values[key] == nil || values[key] == .string("") {
            guard field["required"].bool != true else {
              throw HeavyEditorError.engine(EditorText.t("请输入有效数字。", "Enter a valid number."))
            }
            arguments[key] = nil
            continue
          }
          guard let number = values[key]?.number, number.isFinite else {
            throw HeavyEditorError.engine(EditorText.t("请输入有效数字。", "Enter a valid number."))
          }
          if let lower = field["min"].number, number < lower {
            throw HeavyEditorError.engine(
              EditorText.t("数值低于允许范围。", "The value is below the allowed range."))
          }
          if let upper = field["max"].number, number > upper {
            throw HeavyEditorError.engine(
              EditorText.t("数值超出允许范围。", "The value exceeds the allowed range."))
          }
        }
        let response = try await controller.execute(
          request.command, arguments: .object(arguments), expectedRevision: request.baseRevision)
        if !response["exports"].array.isEmpty {
          let files = response["exports"].array.map {
            EditorJSON.object(["name": $0["name"], "bytes": $0["byteCount"]])
          }
          resultRequest = .init(title: schema["title"].string ?? controller.descriptor.title, value: .array(files))
        } else if schema["access"].string == "read", schema["sideEffecting"].bool != true {
          resultRequest = .init(title: schema["title"].string ?? controller.descriptor.title, value: response["result"])
        } else {
          controller.nativeModal = nil
        }
      } catch { feedback = error.localizedDescription }
    }
  }
  private func color(_ text: String) -> Color {
    let n =
      UInt64(text.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x2879c7
    return Color(
      red: Double(n >> 16 & 255) / 255, green: Double(n >> 8 & 255) / 255,
      blue: Double(n & 255) / 255)
  }
  private func hex(_ color: Color) -> String {
    #if canImport(UIKit)
      var r: CGFloat = 0
      var g: CGFloat = 0
      var b: CGFloat = 0
      var a: CGFloat = 0
      UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
    #else
      let native = NSColor(color).usingColorSpace(.deviceRGB) ?? .black
      let r = native.redComponent
      let g = native.greenComponent
      let b = native.blueComponent
    #endif
    return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
  }
}

private func display(_ value: EditorJSON) -> String {
  switch value {
  case .string(let text): text
  case .number(let number): number.formatted(.number.grouping(.never))
  case .null: ""
  default: (try? value.text()) ?? ""
  }
}

struct HeavyEditorResultView: View {
  let request: HeavyEditorResultRequest
  let close: () -> Void
  var body: some View {
    NavigationStack {
      ScrollView([.vertical, .horizontal]) {
        VStack(alignment: .leading, spacing: 16) {
          if request.value.array.count > 2,
            request.value.array.contains(where: { $0["elevation"].number != nil })
          {
            elevationPlot.frame(width: 520, height: 180)
          }
          if !request.value.array.isEmpty,
            request.value.array.allSatisfy({ if case .object = $0 { true } else { false } })
          {
            resultTable
          } else {
            NativeJSONValue(value: request.value, depth: 0)
          }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
      }.navigationTitle(request.title)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button(EditorText.t("完成", "Done"), action: close)
          }
        }
    }.editorSheetSizing()
  }
  private var fields: [String] {
    Array(Set(request.value.array.flatMap { $0.object.keys })).sorted()
  }
  private var resultTable: some View {
    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
      GridRow {
        ForEach(fields, id: \.self) { Text($0).font(.caption.bold()).foregroundStyle(.secondary) }
      }
      Divider()
      ForEach(Array(request.value.array.prefix(2000).enumerated()), id: \.offset) { _, row in
        GridRow {
          ForEach(fields, id: \.self) {
            Text(display(row[$0])).textSelection(.enabled).frame(maxWidth: 280, alignment: .leading)
          }
        }
      }
    }
  }
  private var elevationPlot: some View {
    Canvas { context, size in
      let points = request.value.array.filter {
        $0["meters"].number != nil && $0["elevation"].number != nil
      }
      let heights = points.compactMap { $0["elevation"].number }
      let low = heights.min() ?? 0
      let high = heights.max() ?? 1
      let distance = max(1, points.compactMap { $0["meters"].number }.max() ?? 1)
      var path = Path()
      for (index, point) in points.enumerated() {
        let p = CGPoint(
          x: (point["meters"].number ?? 0) / distance * size.width,
          y: size.height - ((point["elevation"].number ?? 0) - low) / max(0.001, high - low)
            * size.height)
        if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
      }
      context.stroke(path, with: .color(.accentColor), lineWidth: 2)
    }.accessibilityLabel(EditorText.t("高程剖面", "Elevation profile"))
  }
}

private struct NativeJSONValue: View {
  let value: EditorJSON
  let depth: Int
  var body: some View {
    Group {
      if depth >= 7 {
        Text(display(value)).textSelection(.enabled)
      } else if !value.object.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(Array(value.object.keys.sorted().prefix(256)), id: \.self) { key in
            DisclosureGroup(key) { NativeJSONValue(value: value[key], depth: depth + 1) }
          }
        }
      } else if case .array(let rows) = value {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(Array(rows.prefix(500).enumerated()), id: \.offset) { _, row in
            NativeJSONValue(value: row, depth: depth + 1)
          }
        }
      } else {
        Text(display(value)).textSelection(.enabled)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
