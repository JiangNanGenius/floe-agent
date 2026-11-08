// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CryptoKit
import FloeFontKit
import FloeHeavyEditorSupport

struct FontDesignManagedSource: Sendable {
    let record: ManagedFontRecord
    let data: Data
}

struct FontDesignProject: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var title: String
    var revision: UInt64
    var modifiedAt: Date
    let sourceID: String?
    let sourceFileName: String?
    let sourceDigest: String?
    var sourceImported: Bool
}

struct FontDesignOutput: Codable, Identifiable, Sendable {
    let id: UUID
    let designID: UUID
    let sourceRevision: UInt64
    let receipt: HeavyEditorExportReceipt
    let mediaType: String
    let createdAt: Date
}

struct FontDesignInstallation: Codable, Sendable {
    let designID: UUID
    let sourceRevision: UInt64
    let outputDigest: String
    let managedFontID: String
    let outputFileID: String
    let installedAt: Date
}

struct FontDesignShareItem: Identifiable, Sendable {
    let output: FontDesignOutput
    let url: URL
    var id: UUID { output.id }
}

enum FontDesignError: LocalizedError {
    case unavailable, invalidProject, invalidOutput, nameInUse(String), registrationFailed
    var errorDescription: String? {
        switch self {
        case .unavailable: EditorText.t("无法打开字体设计库。", "The font design library could not be opened.")
        case .invalidProject: EditorText.t("字体草稿或输入原件不完整。", "The font draft or its original source is incomplete.")
        case .invalidOutput: EditorText.t("导出的字体未能通过保存核验。请重新导出。", "The exported font could not be verified. Export it again.")
        case .nameInUse(let name): EditorText.t("已有字体使用名称“", "A font already uses the name “") + name + EditorText.t("”。请为编辑版本使用不同的家族名称。", "”. Use a different family name for the edited version.")
        case .registrationFailed: EditorText.t("新字体未能注册为当前可用版本。草稿和原件已保留。", "The new font could not be activated. The draft and original have been retained.")
        }
    }
}

/// A fixed App-owned library, separate from DeviceFontStore's installable files.
/// Paths and fontLibrary ownership are never accepted from imported documents.
actor FontDesignLibrary {
    static let shared = FontDesignLibrary()
    private init() {}

    func list() async throws -> [FontDesignProject] {
        let projects = try projectsDirectory()
        let urls = try FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var result: [FontDesignProject] = []
        for url in urls {
            guard let id = UUID(uuidString: url.lastPathComponent), let record = try? await project(id) else { continue }
            result.append(record)
        }
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func project(_ id: UUID) async throws -> FontDesignProject {
        var record = try metadata(id)
        let store = try HeavyEditorProjectStore(directory: projectDirectory(id), documentID: id, kind: .font)
        let document = try await store.read()
        record.title = document.title; record.revision = document.revision; record.modifiedAt = document.modifiedAt
        return record
    }

    func create(source: FontDesignManagedSource? = nil) async throws -> FontDesignProject {
        let number: Int
        if source == nil { number = try await list().count + 1 } else { number = 0 }
        let id = UUID(), directory = try projectsDirectory().appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let title = source.map { $0.record.displayName + EditorText.t(" · 编辑版", " · Edited") } ?? EditorText.t("新字体 ", "New typeface ") + String(number)
        var record = FontDesignProject(id: id, title: title, revision: 0, modifiedAt: Date(), sourceID: source?.record.id, sourceFileName: source?.record.fileName, sourceDigest: source.map { Self.digest($0.data) }, sourceImported: source == nil)
        if let source {
            let ext = URL(fileURLWithPath: source.record.fileName).pathExtension.lowercased()
            guard ["ttf", "otf"].contains(ext), record.sourceDigest == source.record.id else { throw FontDesignError.invalidProject }
            let original = directory.appendingPathComponent("Original", isDirectory: true)
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
            let target = original.appendingPathComponent("Input." + ext)
            try source.data.write(to: target, options: [.atomic])
            guard try Data(contentsOf: target) == source.data else { throw FontDesignError.invalidProject }
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: target.path)
        }
        var document = FontWorkbench.makeDocument(title: title, id: id)
        // A new draft is already distinguishable from another new draft by its
        // host-generated family; an imported project's own name remains intact.
        if source == nil {
            let family = "Floe Typeface " + String(number)
            document.content = document.content.fontDesignReplacing("info", document.content["info"].fontDesignReplacing("familyName", .string(family)))
        }
        let store = try HeavyEditorProjectStore(directory: directory, documentID: id, kind: .font)
        try await store.create(document)
        record.modifiedAt = document.modifiedAt
        try writeMetadata(record)
        return record
    }

    /// Native-only reserved creation. The task authority reserves id/payload;
    /// a staged original moves into the fixed library only after a fresh check.
    func createForTask(id: UUID, title: String, authorize: @Sendable () async throws -> Void) async throws -> FontDesignProject {
        try await authorize()
        if let existing = try? await project(id) { return existing }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200 else { throw FontDesignError.invalidProject }
        let projects = try projectsDirectory(), destination = projects.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw FontDesignError.invalidProject }
        let staging = projects.appendingPathComponent(".creating-" + id.uuidString + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let document = FontWorkbench.makeDocument(title: title, id: id)
        let store = try HeavyEditorProjectStore(directory: staging, documentID: id, kind: .font)
        try await store.create(document)
        let record = FontDesignProject(id: id, title: title, revision: document.revision, modifiedAt: document.modifiedAt,
            sourceID: nil, sourceFileName: nil, sourceDigest: nil, sourceImported: true)
        try encode(record, to: staging.appendingPathComponent("Project.json"))
        guard try await store.read() == document,
              try JSONDecoder().decode(FontDesignProject.self, from: Data(contentsOf: staging.appendingPathComponent("Project.json"))) == record else { throw FontDesignError.invalidProject }
        try await authorize(); try Task.checkCancellation()
        // FileManager's move fails if another creator already committed. Never
        // overwrite a different or partially present original on replay.
        try FileManager.default.moveItem(at: staging, to: destination)
        return try await project(id)
    }

    func containerDirectory() throws -> URL { try baseDirectory() }
    func taskAuthorityDirectory() throws -> URL { try baseDirectory().appendingPathComponent("TaskAuthority", isDirectory: true) }

    func directory(for id: UUID) throws -> URL { _ = try metadata(id); return try projectDirectory(id) }

    func sourceForImport(_ id: UUID) throws -> (name: String, data: Data)? {
        let record = try metadata(id)
        guard !record.sourceImported else { return nil }
        guard let name = record.sourceFileName, let digest = record.sourceDigest else { throw FontDesignError.invalidProject }
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        guard ["ttf", "otf"].contains(ext) else { throw FontDesignError.invalidProject }
        let original = try projectDirectory(id).appendingPathComponent("Original", isDirectory: true)
        try requireDirectory(original)
        let url = original.appendingPathComponent("Input." + ext)
        try requireFile(url)
        let data = try Data(contentsOf: url)
        guard Self.digest(data) == digest else { throw FontDesignError.invalidProject }
        return (name, data)
    }

    func markSourceImported(_ id: UUID) throws {
        var record = try metadata(id); record.sourceImported = true; try writeMetadata(record)
    }

    func authorize(_ request: HeavyEditorAccessRequest, designID: UUID) async throws {
        guard request.documentID == designID, request.owner == .fontLibrary(designID) else { throw HeavyEditorError.wrongDocument }
        try await requireRevision(designID: designID, revision: request.revision)
    }

    func requireRevision(designID: UUID, revision: UInt64) async throws {
        let current = try await project(designID)
        guard current.revision == revision else { throw HeavyEditorError.revisionConflict }
    }

    func export(designID: UUID, sourceRevision: UInt64, artifact: HeavyEditorArtifact, authorize: (@Sendable () async throws -> Void)? = nil) async throws -> HeavyEditorExportReceipt {
        let project = try await project(designID)
        guard project.revision == sourceRevision else { throw HeavyEditorError.revisionConflict }
        try await authorize?(); try Task.checkCancellation()
        let outputID = UUID(), outputs = try outputsDirectory(designID)
        let directory = outputs.appendingPathComponent(outputID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let files = directory.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: false)
        let url = files.appendingPathComponent(artifact.name)
        try artifact.data.write(to: url, options: [.atomic])
        guard try Data(contentsOf: url) == artifact.data else { throw FontDesignError.invalidOutput }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        let receipt = try HeavyEditorExportReceipt(fileID: "font-design/" + designID.uuidString + "/" + outputID.uuidString, artifact: artifact)
        let record = FontDesignOutput(id: outputID, designID: designID, sourceRevision: sourceRevision, receipt: receipt, mediaType: artifact.mediaType, createdAt: Date())
        try encode(record, to: directory.appendingPathComponent("Output.json"))
        let decoded = try readOutput(designID: designID, outputID: outputID)
        guard decoded.receipt.sha256 == receipt.sha256, decoded.receipt.fileID == receipt.fileID else { throw FontDesignError.invalidOutput }
        return receipt
    }

    func outputs(_ id: UUID) throws -> [FontDesignShareItem] {
        _ = try metadata(id)
        let directory = try outputsDirectory(id)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        return urls.compactMap { url in
            guard let outputID = UUID(uuidString: url.lastPathComponent), let output = try? readOutput(designID: id, outputID: outputID), let file = try? outputURL(output, verifyDigest: false) else { return nil }
            return FontDesignShareItem(output: output, url: file)
        }.sorted { $0.output.createdAt > $1.output.createdAt }
    }

    func verifiedOutput(designID: UUID, fileID: String, sourceRevision: UInt64) throws -> FontDesignShareItem {
        let parts = fileID.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "font-design", UUID(uuidString: String(parts[1])) == designID,
              let outputID = UUID(uuidString: String(parts[2])) else { throw FontDesignError.invalidOutput }
        let output = try readOutput(designID: designID, outputID: outputID)
        guard output.sourceRevision == sourceRevision, output.receipt.fileID == fileID else { throw FontDesignError.invalidOutput }
        return FontDesignShareItem(output: output, url: try outputURL(output, verifyDigest: true))
    }

    func compiledOutput(designID: UUID, fileID: String, sourceRevision: UInt64, format: String) throws -> FontDesignShareItem {
        let parts = fileID.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "font-design", UUID(uuidString: String(parts[1])) == designID,
              let outputID = UUID(uuidString: String(parts[2])) else { throw FontDesignError.invalidOutput }
        let output = try readOutput(designID: designID, outputID: outputID)
        guard output.sourceRevision == sourceRevision, output.receipt.fileID == fileID,
              ["ttf", "otf"].contains(format), URL(fileURLWithPath: output.receipt.name).pathExtension.lowercased() == format,
              output.mediaType == (format == "ttf" ? "font/ttf" : "font/otf") else { throw FontDesignError.invalidOutput }
        return FontDesignShareItem(output: output, url: try outputURL(output, verifyDigest: true))
    }

    func recordInstallation(_ item: FontDesignShareItem, installed: ManagedFontRecord) throws {
        let output = item.output
        guard output.receipt.sha256 == installed.id, Int64(output.receipt.byteCount) == installed.byteCount else { throw FontDesignError.invalidOutput }
        let record = FontDesignInstallation(designID: output.designID, sourceRevision: output.sourceRevision, outputDigest: output.receipt.sha256, managedFontID: installed.id, outputFileID: output.receipt.fileID, installedAt: Date())
        let directory = try outputsDirectory(output.designID).appendingPathComponent(output.id.uuidString, isDirectory: true)
        try encode(record, to: directory.appendingPathComponent("Installation.json"))
        let read = try JSONDecoder().decode(FontDesignInstallation.self, from: Data(contentsOf: directory.appendingPathComponent("Installation.json")))
        guard read.designID == record.designID, read.sourceRevision == record.sourceRevision, read.outputDigest == record.outputDigest, read.managedFontID == record.managedFontID else { throw FontDesignError.invalidOutput }
    }

    private func baseDirectory() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw FontDesignError.unavailable }
        let root = support.appendingPathComponent("FloeAgent", isDirectory: true).appendingPathComponent("FontDesign", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try requireDirectory(root)
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }
    private func projectsDirectory() throws -> URL {
        let url = try baseDirectory().appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); try requireDirectory(url); return url
    }
    private func projectDirectory(_ id: UUID) throws -> URL {
        let url = try projectsDirectory().appendingPathComponent(id.uuidString, isDirectory: true)
        try requireDirectory(url); return url
    }
    private func outputsDirectory(_ id: UUID) throws -> URL {
        let url = try projectDirectory(id).appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); try requireDirectory(url); return url
    }
    private func metadata(_ id: UUID) throws -> FontDesignProject {
        let url = try projectDirectory(id).appendingPathComponent("Project.json")
        try requireFile(url)
        let record = try JSONDecoder().decode(FontDesignProject.self, from: Data(contentsOf: url))
        guard record.id == id else { throw FontDesignError.invalidProject }; return record
    }
    private func writeMetadata(_ record: FontDesignProject) throws {
        let url = try projectDirectory(record.id).appendingPathComponent("Project.json")
        try encode(record, to: url)
        guard try metadata(record.id) == record else { throw FontDesignError.invalidProject }
    }
    private func readOutput(designID: UUID, outputID: UUID) throws -> FontDesignOutput {
        let directory = try outputsDirectory(designID).appendingPathComponent(outputID.uuidString, isDirectory: true)
        try requireDirectory(directory)
        let url = directory.appendingPathComponent("Output.json"); try requireFile(url)
        let output = try JSONDecoder().decode(FontDesignOutput.self, from: Data(contentsOf: url))
        guard output.id == outputID, output.designID == designID else { throw FontDesignError.invalidOutput }
        return output
    }
    private func outputURL(_ output: FontDesignOutput, verifyDigest: Bool) throws -> URL {
        // Reuse the bundled artifact filename validation before joining paths.
        _ = try HeavyEditorArtifact(name: output.receipt.name, mediaType: "application/octet-stream", data: Data())
        let directory = try outputsDirectory(output.designID).appendingPathComponent(output.id.uuidString, isDirectory: true)
        try requireDirectory(directory)
        let files = directory.appendingPathComponent("Files", isDirectory: true); try requireDirectory(files)
        let url = files.appendingPathComponent(output.receipt.name); try requireFile(url)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == output.receipt.byteCount else { throw FontDesignError.invalidOutput }
        if verifyDigest { guard Self.digest(try Data(contentsOf: url)) == output.receipt.sha256 else { throw FontDesignError.invalidOutput } }
        return url
    }
    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw FontDesignError.invalidProject }
    }
    private func requireFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw FontDesignError.invalidProject }
    }
    private func encode<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic])
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Authorization state is per controller. Another controller cannot overwrite
/// the source revision attached to this controller's export callback.
actor FontDesignAccessSession {
    let designID: UUID
    private let library: FontDesignLibrary
    private var exportRevision: UInt64?
    init(designID: UUID, library: FontDesignLibrary) { self.designID = designID; self.library = library }
    func authorize(_ request: HeavyEditorAccessRequest) async throws {
        try await library.authorize(request, designID: designID)
        if request.access == .exportFile { exportRevision = request.revision }
    }
    func export(documentID: UUID, artifact: HeavyEditorArtifact) async throws -> HeavyEditorExportReceipt {
        guard documentID == designID, let revision = exportRevision else { throw HeavyEditorError.wrongDocument }
        return try await library.export(designID: designID, sourceRevision: revision, artifact: artifact)
    }
}

extension EditorJSON {
    func fontDesignReplacing(_ key: String, _ value: EditorJSON) -> EditorJSON { var object = self.object; object[key] = value; return .object(object) }
    var fontDesignData: EditorJSON { self["data"] == .null ? self : self["data"] }
}
#endif
