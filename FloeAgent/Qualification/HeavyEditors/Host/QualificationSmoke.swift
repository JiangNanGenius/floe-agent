// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import FloeHeavyEditorSupport
import Foundation
import WebKit

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Exercises the real bundled WK bridge and durable host files. This is an
/// independent native host, not evidence of production App authorization/UI.
@MainActor enum QualificationSmoke {
  private struct Plan: Decodable {
    let kind: HeavyEditorKind
    let steps: [Step]
  }
  private struct Step: Decodable {
    let command: String
    let arguments: EditorJSON
  }
  static func runIfRequested(_ workspace: QualificationWorkspace) async {
    let args = ProcessInfo.processInfo.arguments
    guard !workspace.smokeStarted, let flag = args.firstIndex(of: "--smoke-plans"),
      args.indices.contains(flag + 1)
    else { return }
    workspace.smokeStarted = true
    let modules = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
    let requestedKind = args.firstIndex(of: "--smoke-kind").flatMap {
      args.indices.contains($0 + 1) ? HeavyEditorKind(rawValue: args[$0 + 1]) : nil
    }
    var evidence: [EditorJSON] = []
    do {
      for (index, kind) in HeavyEditorKind.allCases.enumerated() {
        if let requestedKind, requestedKind != kind { continue }
        workspace.entry = QualificationEntry.allCases[index]
        workspace.smokeStatus = "Checking " + kind.rawValue
        let moduleName =
          switch kind {
          case .gis: "FloeGISKit"
          case .score: "FloeScoreKit"
          case .font: "FloeFontKit"
          }
        let planBytes = try Data(
          contentsOf: modules.appendingPathComponent(moduleName + "/Integration/smoke-plan.json"))
        let plan = try JSONDecoder().decode(Plan.self, from: planBytes)
        guard plan.kind == kind else { throw HeavyEditorError.wrongDocument }
        var controller = try await workspace.create(kind, title: "QA " + kind.rawValue)
        try await controller.waitUntilReady()
        if kind == .font {
          let initial = try await controller.webView.callAsyncJavaScript(
            "return JSON.stringify({axes:FloeEditor.state.axes.length,masters:FloeEditor.state.masters.length,glyphs:FloeEditor.state.glyphs.length,independent:FloeEditor.state.glyphs!==FloeEditor.state.axes&&FloeEditor.state.axes!==FloeEditor.state.masters});",
            arguments: [:], in: nil, contentWorld: .page)
          guard let json = initial as? String, let bytes = json.data(using: .utf8) else { throw HeavyEditorError.invalidDocument }
          let state = try EditorJSON.decode(bytes)
          guard state["axes"] == .number(0), state["masters"] == .number(0), state["glyphs"] == .number(1), state["independent"] == .bool(true) else {
            throw HeavyEditorError.engine("Empty native JSON arrays were aliased in the page")
          }
        }
        let id = controller.document.id
        let described = try await model(.describe, controller: controller, kind: kind)
        guard described["commands"].array.count > 20 else { throw HeavyEditorError.invalidDocument }
        var steps: [EditorJSON] = []
        var checks = plan.steps
        if kind == .gis {
          for format in ["png", "pdf"] {
            checks.append(.init(command: "layout.export", arguments: .object([
              "format": .string(format), "width": .number(640), "height": .number(480)
            ])))
          }
        } else if kind == .font {
          for format in ["svg", "png"] {
            checks.append(.init(command: "specimen.export", arguments: .object([
              "format": .string(format), "columns": .number(6), "rows": .number(8), "points": .bool(false)
            ])))
          }
        }
        for step in checks {
          workspace.smokeStatus = kind.rawValue + " · " + step.command
          let metadata = try await controller.commandMetadata(step.command)
          let operation: HeavyEditorToolOperation
          if metadata["access"].string == "exportFile" {
            operation = .export
          } else if metadata["access"].string == "read", metadata["sideEffecting"] != .bool(true) {
            operation = .query
          } else {
            operation = .invoke
          }
          let result = try await model(
            operation, controller: controller, kind: kind, command: step.command,
            arguments: step.arguments)
          steps.append(
            .object([
              "command": .string(step.command),
              "revision": .number(Double(controller.document.revision)),
              "resultSHA256": .string(hash(try result["result"].data())),
              "exports": result["exports"],
            ]))
        }
        let durable = controller.document
        // A stale caller may not change the durable revision or title.
        do {
          _ = try await controller.execute(
            "document.rename", arguments: .object(["title": .string("stale")]),
            expectedRevision: durable.revision + 1)
          throw HeavyEditorError.engine("Stale mutation unexpectedly succeeded")
        } catch HeavyEditorError.revisionConflict {}
        guard controller.document == durable else { throw HeavyEditorError.invalidDocument }
        if kind == .score {
          do {
            _ = try await model(
              .query, controller: controller, kind: kind, command: "score.playback.control",
              arguments: .object(["action": .string("start")]))
            throw HeavyEditorError.engine("Read-only query unexpectedly started playback")
          } catch HeavyEditorError.invalidCommand {}
        }
        let record = try workspace.records.first(where: { $0.id == id }).unwrap()
        controller = try await workspace.reopenFresh(record)
        try await controller.waitUntilReady()
        guard controller.document == durable else {
          throw HeavyEditorError.engine("Reopened document differs from committed document")
        }
        // Exact file read-back follows every managed export.
        let exports = workspace.exports.filter { $0.projectID == id }
        guard !exports.isEmpty else { throw HeavyEditorError.invalidDocument }
        for file in exports {
          let data = try Data(contentsOf: workspace.root.appendingPathComponent(file.relativePath))
          guard data.count == file.byteCount, hash(data) == file.sha256 else {
            throw HeavyEditorError.invalidDocument
          }
          try validateSignature(data, name: file.name)
        }
        try await Task.sleep(for: .milliseconds(200))
        let image = try await controller.webView.takeSnapshot(configuration: nil)
        #if os(macOS)
          guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
          else { throw HeavyEditorError.invalidDocument }
        #else
          guard let png = image.pngData() else { throw HeavyEditorError.invalidDocument }
        #endif
        try png.write(
          to: workspace.root.appendingPathComponent(kind.rawValue + "-native-host.png"),
          options: .atomic)
        evidence.append(
          .object([
            "kind": .string(kind.rawValue), "entry": .string(record.entry.rawValue),
            "projectID": .string(id.uuidString),
            "commands": .number(Double(described["commands"].array.count)),
            "planSHA256": .string(hash(planBytes)), "revision": .number(Double(durable.revision)),
            "reopenedEqual": .bool(true), "staleMutationRejected": .bool(true),
            "exportCount": .number(Double(exports.count)), "steps": .array(steps),
          ]))
        await controller.endPresentation()
      }
      workspace.smokeStatus = "\(evidence.count) editors · save, reopen, exports verified"
      try write(workspace, evidence: evidence, success: true, error: nil)
    } catch {
      if let controller = workspace.current {
        let body = """
        const e=globalThis.FloeEditor;
        if(!e)return JSON.stringify({enginePresent:false});
        const report={enginePresent:true,loaded:!!e.envelope,axes:e.state.axes,axesIsArray:Array.isArray(e.state.axes),masters:e.state.masters?.length,info:e.state.info};
        try{report.commandCount=e.catalog().length;}catch(error){report.catalogError=String(error);report.stack=error.stack;}
        try{e.configuration.normalize(structuredClone(e.state));report.normalization=true;}catch(error){report.normalizeError=String(error);report.normalizeStack=error.stack;}
        return JSON.stringify(report);
        """
        if let state = try? await controller.webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page) as? String {
          try? Data(state.utf8).write(to: workspace.root.appendingPathComponent("EngineDiagnostic.json"), options: .atomic)
        }
      }
      workspace.smokeStatus = "Qualification failed: " + error.localizedDescription
      workspace.error = error.localizedDescription
      let diagnostic = error.localizedDescription + "\n" + String(describing: (error as NSError).userInfo)
        + "\n" + (workspace.current?.engineDiagnostics.joined(separator: "\n") ?? "")
      try? write(workspace, evidence: evidence, success: false, error: diagnostic)
    }
  }
  private static func model(
    _ operation: HeavyEditorToolOperation, controller: HeavyEditorController, kind: HeavyEditorKind,
    command: String? = nil, arguments: EditorJSON? = nil
  ) async throws -> EditorJSON {
    try await HeavyEditorModelCalls.execute(
      operation, kind: kind,
      request: .init(
        projectID: controller.document.id, baseRevision: controller.document.revision,
        command: command, arguments: arguments), lease: .init(controller: controller, release: {}))
  }
  private static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private static func write(
    _ workspace: QualificationWorkspace, evidence: [EditorJSON], success: Bool, error: String?
  ) throws {
    try EditorJSON.object([
      "host": .string("independent native WK qualification"), "success": .bool(success),
      "date": .string(ISO8601DateFormatter().string(from: Date())),
      "error": error.map(EditorJSON.string) ?? .null, "editors": .array(evidence),
    ]).data().write(to: workspace.root.appendingPathComponent("SmokeResult.json"), options: .atomic)
  }
  private static func validateSignature(_ data: Data, name: String) throws {
    let prefix: [UInt8] =
      switch URL(fileURLWithPath: name).pathExtension.lowercased() {
      case "gpkg": Array("SQLite format 3".utf8)
      case "pdf": Array("%PDF".utf8)
      case "mxl": Array("PK".utf8)
      case "midi", "mid": Array("MThd".utf8)
      case "ttf": [0, 1, 0, 0]
      case "otf": Array("OTTO".utf8)
      case "woff2": Array("wOF2".utf8)
    case "png": [137, 80, 78, 71, 13, 10, 26, 10]
      default: []
      }
    guard !data.isEmpty, data.starts(with: prefix) else {
      throw HeavyEditorError.engine("Export signature mismatch: " + name)
    }
  }
}
extension Optional {
  fileprivate func unwrap() throws -> Wrapped {
    guard let self else { throw HeavyEditorError.invalidDocument }
    return self
  }
}
