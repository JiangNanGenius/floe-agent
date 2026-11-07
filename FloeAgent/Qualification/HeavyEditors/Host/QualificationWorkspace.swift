// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import FloeFontKit
import FloeGISKit
import FloeHeavyEditorSupport
import FloeScoreKit
// This qualification host deliberately uses its own workspace and explicit
// qualification owner. Its reduced hooks are never production authorization.
import Foundation
import Observation

enum QualificationEntry: String, CaseIterable, Codable, Identifiable {
  case space, notes, task, music, fontManager
  var id: String { rawValue }
  var title: String {
    switch self {
    case .space: EditorText.t("空间", "Space")
    case .notes: EditorText.t("手记附件", "Note attachments")
    case .task: EditorText.t("任务产物", "Task results")
    case .music: EditorText.t("音乐编辑器", "Music editor")
    case .fontManager: EditorText.t("字体管理器", "Font manager")
    }
  }
}
struct QualificationRecord: Codable, Identifiable {
  let id: UUID
  let kind: HeavyEditorKind
  var title: String
  let entry: QualificationEntry
  var revision: UInt64
}
struct QualificationExport: Codable, Identifiable {
  let id: String
  let projectID: UUID
  let name: String
  let relativePath: String
  let byteCount: Int
  let sha256: String
}

@MainActor @Observable final class QualificationWorkspace {
  var records: [QualificationRecord] = []
  var exports: [QualificationExport] = []
  var current: HeavyEditorController?
  var entry: QualificationEntry = .space
  var isOpening = false
  var error: String?
  var smokeStatus: String?
  var smokeStarted = false
  let root: URL
  private let qualificationID = UUID()
  private var controllers: [UUID: HeavyEditorController] = [:]
  init() throws {
    #if os(macOS)
      let arguments = ProcessInfo.processInfo.arguments
      guard let flag = arguments.firstIndex(of: "--workspace"), arguments.indices.contains(flag + 1)
      else {
        throw HeavyEditorError.engine(
          "The qualification launcher must provide its explicit workspace.")
      }
      root = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true).standardizedFileURL
        .resolvingSymlinksInPath()
    #else
      root = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
      ).appendingPathComponent("HeavyEditorsQualification", isDirectory: true)
    #endif
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let manifest = root.appendingPathComponent("Projects.json")
    if FileManager.default.fileExists(atPath: manifest.path) {
      records = try JSONDecoder().decode(
        [QualificationRecord].self, from: Data(contentsOf: manifest))
    }
    let exportManifest = root.appendingPathComponent("Exports.json")
    if FileManager.default.fileExists(atPath: exportManifest.path) {
      exports = try JSONDecoder().decode(
        [QualificationExport].self, from: Data(contentsOf: exportManifest))
    }
  }
  static func descriptor(_ kind: HeavyEditorKind) -> HeavyEditorDescriptor {
    switch kind {
    case .gis: GISWorkbench.descriptor
    case .score: ScoreWorkbench.descriptor
    case .font: FontWorkbench.descriptor
    }
  }
  func create(_ kind: HeavyEditorKind, title: String? = nil) async throws -> HeavyEditorController {
    let descriptor = Self.descriptor(kind)
    let id = UUID()
    let name = title ?? descriptor.title
    let document: HeavyEditorDocument
    switch kind {
    case .gis: document = GISWorkbench.makeDocument(title: name, id: id)
    case .score: document = ScoreWorkbench.makeDocument(title: name, id: id)
    case .font: document = FontWorkbench.makeDocument(title: name, id: id)
    }
    let directory = projectRoot(id)
    let store = try HeavyEditorProjectStore(directory: directory, documentID: id, kind: kind)
    try await store.create(document)
    let record = QualificationRecord(id: id, kind: kind, title: name, entry: entry, revision: 0)
    records.append(record)
    try saveManifest()
    return try await open(record)
  }
  func open(_ record: QualificationRecord) async throws -> HeavyEditorController {
    if let existing = controllers[record.id] {
      try await existing.reload()
      current = existing
      return existing
    }
    let id = record.id
    let owner = qualificationID
    let directory = projectRoot(id)
    let hooks = HeavyEditorHostHooks(
      authorize: { request in
        guard request.documentID == id, request.owner == .qualification(owner) else {
          throw HeavyEditorError.wrongDocument
        }
      }, didSave: { [weak self] document in await self?.saved(document) },
      export: { [weak self] documentID, artifact in
        guard let self else { throw HeavyEditorError.unavailable }
        return try await self.export(documentID: documentID, artifact: artifact)
      })
    let controller: HeavyEditorController
    switch record.kind {
    case .gis:
      controller = try await GISWorkbench.open(
        directory: directory, documentID: id, owner: .qualification(owner), hooks: hooks)
    case .score:
      controller = try await ScoreWorkbench.open(
        directory: directory, documentID: id, owner: .qualification(owner), hooks: hooks)
    case .font:
      controller = try await FontWorkbench.open(
        directory: directory, documentID: id, owner: .qualification(owner), hooks: hooks)
    }
    controllers[id] = controller
    current = controller
    return controller
  }
  func close() { current = nil }
  func reopenFresh(_ record: QualificationRecord) async throws -> HeavyEditorController {
    await controllers.removeValue(forKey: record.id)?.endPresentation()
    current = nil
    return try await open(record)
  }
  func projectRoot(_ id: UUID) -> URL {
    root.appendingPathComponent("Projects", isDirectory: true).appendingPathComponent(
      id.uuidString, isDirectory: true)
  }
  private func saveManifest() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(records)
    try data.write(to: root.appendingPathComponent("Projects.json"), options: .atomic)
  }
  private func saved(_ document: HeavyEditorDocument) {
    guard let index = records.firstIndex(where: { $0.id == document.id }) else { return }
    records[index].title = document.title
    records[index].revision = document.revision
    do { try saveManifest() } catch { self.error = error.localizedDescription }
  }
  private func export(documentID: UUID, artifact: HeavyEditorArtifact) throws
    -> HeavyEditorExportReceipt
  {
    guard records.contains(where: { $0.id == documentID }) else {
      throw HeavyEditorError.wrongDocument
    }
    let id = UUID().uuidString
    let path = "Exports/" + documentID.uuidString + "/" + id + "/" + artifact.name
    let target = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try artifact.data.write(to: target, options: .atomic)
    guard try Data(contentsOf: target) == artifact.data else {
      throw HeavyEditorError.invalidDocument
    }
    let receipt = try HeavyEditorExportReceipt(
      fileID: "qualification-file-" + id, artifact: artifact)
    exports.append(
      .init(
        id: receipt.fileID, projectID: documentID, name: artifact.name, relativePath: path,
        byteCount: receipt.byteCount, sha256: receipt.sha256))
    try JSONEncoder().encode(exports).write(
      to: root.appendingPathComponent("Exports.json"), options: .atomic)
    return receipt
  }
}
