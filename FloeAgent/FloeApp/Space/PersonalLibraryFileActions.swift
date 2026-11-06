// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CryptoKit
import Darwin
import FloeDiagramCore
import FloeDiagramIntegration
import FloeDiagramExchange
import FloePrintCore

nonisolated enum PersonalFileAction: String, Sendable { case move, duplicate, share }
nonisolated enum PersonalFileActionError: Error, LocalizedError {
    case busy, closeFirst, unsupported, tooLarge, changed
    case moveRecovery(String)
    var errorDescription: String? {
        switch self {
        case .busy: IDELanguageRunText.t("正在处理这个文件，请稍后重试。", "This file is being processed. Try again shortly.")
        case .closeFirst: IDELanguageRunText.t("请先保存并关闭这个作品，再整理文件。", "Save and close this work before organizing its files.")
        case .unsupported: IDELanguageRunText.t("请在作品编辑器中导出副本，原件会保留。", "Export a copy from the work editor. The original will be kept.")
        case .tooLarge: IDELanguageRunText.t("这个工程超过文件菜单的大小限制，请在编辑器中导出。", "This project exceeds the file-menu size limit. Export it from the editor.")
        case .changed: IDELanguageRunText.t("文件已改变，请刷新后重试。", "The file changed. Refresh and try again.")
        case .moveRecovery(let location): IDELanguageRunText.t("移动记录未完成，文件保留在：", "The move record could not be completed. The file is kept at: ") + location
        }
    }
}

@MainActor final class PersonalShareArtifact: Identifiable {
    nonisolated let id = UUID()
    let url: URL
    private let directory: URL
    private var finished = false
    init(url: URL, directory: URL) { self.url = url; self.directory = directory }
    func finish() {
        guard !finished else { return }; finished = true
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Narrow native menu operations. A process-local barrier prevents a new
/// document/CAD owner from reopening an old path during a supported move.
/// Other feature types retain their existing roots and running services.
@MainActor enum PersonalLibraryFileActions {
    private static var active: Set<UUID> = []
    private static let files = PersonalLibraryFileIO()
    static func requireAvailable(_ id: UUID) throws {
        guard !active.contains(id) else { throw PersonalFileActionError.busy }
    }
    static func supports(_ action: PersonalFileAction, kind: PersonalContentKind) -> Bool {
        switch action {
        case .move: [.document, .cad2D, .cad3D].contains(kind)
        case .duplicate: [.document, .printing].contains(kind)
        case .share: [.document, .diagram, .printing].contains(kind)
        }
    }
    static func limitation(_ action: PersonalFileAction, kind: PersonalContentKind) -> String {
        if action == .move {
            return IDELanguageRunText.t("这个类型暂不能在文件菜单中移动。请先在编辑器导出副本，原件和正在进行的工作会保留。", "This type cannot be moved from the file menu yet. Export a copy from its editor; the original and ongoing work will be kept.")
        }
        return IDELanguageRunText.t("这个类型需要在编辑器中导出副本。", "Export a copy of this type from its editor.")
    }

    static func move(_ selection: PersonalContentRecord, to folders: [String]) async throws -> PersonalContentRecord {
        guard supports(.move, kind: selection.kind) else { throw PersonalFileActionError.unsupported }
        try begin(selection.id); defer { active.remove(selection.id) }
        let library = try await PersonalContentService.shared.library(), source = try await library.resolve(selection.id)
        guard source.record.relativePath == selection.relativePath, source.record.kind == selection.kind else { throw PersonalFileActionError.changed }
        switch source.record.kind {
        case .document:
            try PersonalTextDocument.requireClosedForFileAction(projectID: selection.id)
            try PersonalOfficeDocument.requireClosedForFileAction(projectID: selection.id)
        case .cad2D, .cad3D:
            try PersonalCADSessions.prepareForLibraryMove(id: selection.id, directory: source.url)
        default: throw PersonalFileActionError.unsupported
        }
        try Task.checkCancellation()
        let result = try await library.move(selection.id, to: folders, expectedRelativePath: source.record.relativePath)
        changed(result.id)
        return result
    }

    static func duplicate(_ selection: PersonalContentRecord, title: String, to folders: [String]) async throws -> PersonalContentRecord {
        guard supports(.duplicate, kind: selection.kind) else { throw PersonalFileActionError.unsupported }
        try begin(selection.id); defer { active.remove(selection.id) }
        let library = try await PersonalContentService.shared.library(), source = try await library.resolve(selection.id)
        guard source.record.relativePath == selection.relativePath, source.record.kind == selection.kind else { throw PersonalFileActionError.changed }
        let result: PersonalContentRecord
        if source.record.kind == .document {
            try PersonalTextDocument.requireClosedForFileAction(projectID: selection.id)
            try PersonalOfficeDocument.requireClosedForFileAction(projectID: selection.id)
            let original = try await PersonalContentService.shared.originalFile(selection.id)
            guard original.deletingLastPathComponent().standardizedFileURL == (try checkedChildDirectory("Original", under: source.url)) else { throw PersonalContentError.invalidProject }
            let io = files
            result = try await library.create(kind: .document, title: title, in: folders) { directory, id in
                let target = directory.appendingPathComponent("Original", isDirectory: true)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                let receipt = try await io.copyRegular(original, to: target.appendingPathComponent(original.lastPathComponent))
                try await verifyLocation(selection.id, expected: source.record.relativePath)
                try writeCopyReceipt(directory: directory, source: source.record, newID: id, revision: receipt)
            }
        } else {
            let disk = PrintProjectDisk(root: try checkedChildDirectory("Printing", under: source.url)), frozen = try await disk.load()
            guard frozen.projectID == source.record.id else { throw PersonalFileActionError.changed }
            result = try await library.create(kind: .printing, title: title, in: folders) { directory, id in
                _ = try await copyEditablePrint(frozen, from: disk, to: directory.appendingPathComponent("Printing"), newID: id)
                guard try await disk.load().revision == frozen.revision else { throw PersonalFileActionError.changed }
                try await verifyLocation(selection.id, expected: source.record.relativePath)
                try writeCopyReceipt(directory: directory, source: source.record, newID: id, revision: "print:\(frozen.revision)")
            }
        }
        changed(result.id)
        return result
    }

    static func share(_ selection: PersonalContentRecord) async throws -> PersonalShareArtifact {
        guard supports(.share, kind: selection.kind) else { throw PersonalFileActionError.unsupported }
        try begin(selection.id); defer { active.remove(selection.id) }
        let library = try await PersonalContentService.shared.library(), source = try await library.resolve(selection.id)
        guard source.record.relativePath == selection.relativePath, source.record.kind == selection.kind else { throw PersonalFileActionError.changed }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floe-personal-share-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var adopted = false
        defer { if !adopted { try? FileManager.default.removeItem(at: directory) } }
        let url: URL
        switch source.record.kind {
        case .document:
            try PersonalTextDocument.requireClosedForFileAction(projectID: selection.id)
            try PersonalOfficeDocument.requireClosedForFileAction(projectID: selection.id)
            let original = try await PersonalContentService.shared.originalFile(selection.id)
            guard original.deletingLastPathComponent().standardizedFileURL == (try checkedChildDirectory("Original", under: source.url)) else { throw PersonalContentError.invalidProject }
            url = directory.appendingPathComponent(original.lastPathComponent)
            _ = try await files.copyRegular(original, to: url)
        case .diagram:
            let documentRoot = try checkedChildDirectory("Diagram", under: source.url)
            let assetRoot = try checkedChildDirectory("Assets", under: source.url)
            let repository = try FileDiagramRepository(directory: documentRoot)
            let frozen = try await repository.load(selection.id)
            guard frozen.id == selection.id, frozen.assets.count <= 2_000,
                  frozen.assets.allSatisfy({ $0.byteCount >= 0 && $0.byteCount <= 64 * 1_024 * 1_024 }),
                  frozen.assets.reduce(Int64(0), { $0 + Int64($1.byteCount) }) <= 128 * 1_024 * 1_024 else { throw PersonalFileActionError.tooLarge }
            let assets = try FileDiagramAssets(directory: assetRoot)
            let output = try await DiagramExchange.export(frozen, format: .floemap, assets: assets)
            guard output.data.count <= PersonalLibraryFileIO.maximumBytes,
                  try await repository.load(selection.id).revision == frozen.revision else { throw PersonalFileActionError.changed }
            url = directory.appendingPathComponent(safeName(source.record.title) + ".floemap")
            try output.data.write(to: url, options: .atomic)
        case .printing:
            let disk = PrintProjectDisk(root: try checkedChildDirectory("Printing", under: source.url)), frozen = try await disk.load()
            guard frozen.projectID == selection.id else { throw PersonalFileActionError.changed }
            let package = directory.appendingPathComponent("EditablePrint", isDirectory: true)
            _ = try await copyEditablePrint(frozen, from: disk, to: package.appendingPathComponent("Printing"), newID: frozen.projectID)
            struct Envelope: Encodable { let format = "org.floe.print.editable"; let version = 1; let projectID: UUID; let sourceRevision: UInt64 }
            try JSONEncoder().encode(Envelope(projectID: frozen.projectID, sourceRevision: frozen.revision))
                .write(to: package.appendingPathComponent("print-project.json"), options: .atomic)
            url = directory.appendingPathComponent(safeName(source.record.title) + ".floeprint.zip")
            try await files.zipDirectory(package, to: url)
            try FileManager.default.removeItem(at: package)
            guard try await disk.load().revision == frozen.revision else { throw PersonalFileActionError.changed }
        default: throw PersonalFileActionError.unsupported
        }
        try await verifyLocation(selection.id, expected: source.record.relativePath)
        try Task.checkCancellation()
        adopted = true
        return .init(url: url, directory: directory)
    }

    private static func copyEditablePrint(_ frozen: PrintProjectDocument, from source: PrintProjectDisk, to root: URL, newID: UUID) async throws -> PrintProjectDocument {
        let disk = PrintProjectDisk(root: root)
        let plates = frozen.plates ?? [.init(id: frozen.plateID, name: "Plate 1")]
        guard !plates.isEmpty, plates.count <= 32, Set(plates.map(\.id)).count == plates.count else { throw PrintError.invalidMesh }
        let rebase = newID != frozen.projectID
        let mapping = Dictionary(uniqueKeysWithValues: plates.map { ($0.id, rebase ? UUID() : $0.id) })
        var next = frozen; next.projectID = newID; next.revision = rebase ? 0 : frozen.revision
        guard let selectedPlate = mapping[frozen.plateID] else { throw PrintError.invalidMesh }
        next.plateID = selectedPlate
        next.plates = plates.map { .init(id: mapping[$0.id]!, name: $0.name) }
        next.resultAsset = nil; next.resultFingerprint = nil; next.resultLayerCount = nil
        var objects = frozen.objects ?? frozen.meshAsset.map { [.init(plateID: frozen.plateID, name: frozen.meshName ?? "Model", meshAsset: $0)] } ?? []
        guard objects.count <= 200 else { throw PrintError.sizeLimit }
        var stored = Set<String>(), bytes = 0
        let sourceRoot = source.root
        for index in objects.indices {
            try Task.checkCancellation()
            guard let plate = mapping[objects[index].plateID] else { throw PrintError.invalidMesh }
            try checkRegularAsset(objects[index].meshAsset, under: sourceRoot)
            let mesh = try await source.meshAsset(objects[index].meshAsset)
            if stored.insert(objects[index].meshAsset).inserted { bytes += mesh.positions.count * 4 }
            guard bytes <= PersonalLibraryFileIO.maximumBytes else { throw PersonalFileActionError.tooLarge }
            objects[index].meshAsset = try await disk.storeMesh(mesh)
            objects[index].plateID = plate
            if rebase { objects[index].id = UUID() }
        }
        if let provenance = frozen.sourceSnapshot {
            try checkRegularAsset(provenance.geometryAsset, under: sourceRoot)
            let mesh = try await source.meshAsset(provenance.geometryAsset)
            if stored.insert(provenance.geometryAsset).inserted { bytes += mesh.positions.count * 4 }
            guard bytes <= PersonalLibraryFileIO.maximumBytes,
                  try await disk.storeMesh(mesh) == provenance.geometryAsset else { throw PrintError.invalidMesh }
        }
        next.objects = objects
        next.meshAsset = objects.first(where: { $0.plateID == next.plateID })?.meshAsset
        next.meshName = objects.first(where: { $0.plateID == next.plateID })?.name
        try await disk.create(next)
        let verified = try await disk.load()
        guard verified.projectID == newID, verified.objects?.count == objects.count else { throw PrintError.invalidMesh }
        return verified
    }
    private static func verifyLocation(_ id: UUID, expected: String) async throws {
        try Task.checkCancellation()
        guard try await PersonalContentService.shared.library().resolve(id).record.relativePath == expected else { throw PersonalFileActionError.changed }
    }
    private static func begin(_ id: UUID) throws { guard active.insert(id).inserted else { throw PersonalFileActionError.busy } }
    private nonisolated static func checkedChildDirectory(_ name: String, under root: URL) throws -> URL {
        let parent = root.standardizedFileURL.resolvingSymlinksInPath(), child = parent.appendingPathComponent(name)
        let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              child.resolvingSymlinksInPath() == child else { throw PersonalContentError.invalidProject }
        return child
    }
    private nonisolated static func checkRegularAsset(_ name: String, under root: URL) throws {
        guard name == (name as NSString).lastPathComponent, !name.hasPrefix("."), !name.contains("\\") else { throw PrintError.invalidMesh }
        let asset = root.appendingPathComponent(name)
        let values = try asset.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              asset.standardizedFileURL.resolvingSymlinksInPath() == asset.standardizedFileURL else { throw PrintError.invalidMesh }
    }
    private static func changed(_ id: UUID) { NotificationCenter.default.post(name: .floeStudioDocumentDidChange, object: id) }
    private nonisolated static func writeCopyReceipt(directory: URL, source: PersonalContentRecord, newID: UUID, revision: String) throws {
        struct Receipt: Encodable { let format = "org.floe.library.copy"; let sourceProjectID: UUID; let projectID: UUID; let sourceRevision: String; let date: Date }
        try JSONEncoder().encode(Receipt(sourceProjectID: source.id, projectID: newID, sourceRevision: revision, date: Date()))
            .write(to: directory.appendingPathComponent("LibraryCopy.json"), options: .atomic)
    }
    private static func safeName(_ value: String) -> String {
        let name = String(value.prefix(120)).replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: "\\", with: " ")
            .replacingOccurrences(of: ":", with: " ").components(separatedBy: .controlCharacters).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Floe" : name
    }
}

private actor PersonalLibraryFileIO {
    nonisolated static let maximumBytes = 128 * 1_024 * 1_024
    func copyRegular(_ source: URL, to target: URL) throws -> String { try Self.copyBounded(source, to: target) }
    /// A bounded descriptor copy, not a path-recursive project clone. Original
    /// bytes stay intact; cancellation removes only our incomplete output.
    private nonisolated static func copyBounded(_ source: URL, to target: URL) throws -> String {
        try Task.checkCancellation()
        guard source.isFileURL, target.isFileURL else { throw PersonalFileActionError.changed }
        let input = Darwin.open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard input >= 0 else { throw PersonalFileActionError.changed }
        defer { Darwin.close(input) }
        var before = stat()
        guard fstat(input, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0, before.st_size <= Int64(Self.maximumBytes) else { throw PersonalFileActionError.tooLarge }
        let output = Darwin.open(target.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard output >= 0 else { throw PersonalFileActionError.changed }
        var completed = false
        defer { Darwin.close(output); if !completed { try? FileManager.default.removeItem(at: target) } }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024), total = 0, hash = SHA256()
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress!, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0, count <= Self.maximumBytes - total else { throw PersonalFileActionError.tooLarge }
            if count == 0 { break }
            let chunk = Data(buffer.prefix(count)); hash.update(data: chunk); total += count
            try chunk.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try Task.checkCancellation()
                    let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw PersonalContentError.storageUnavailable }
                    offset += written
                }
            }
        }
        var after = stat(), path = stat()
        guard fstat(input, &after) == 0, lstat(source.path, &path) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_size == Int64(total),
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              path.st_dev == after.st_dev, path.st_ino == after.st_ino, (path.st_mode & S_IFMT) == S_IFREG,
              path.st_size == after.st_size, path.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              path.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw PersonalFileActionError.changed }
        guard fsync(output) == 0 else { throw PersonalContentError.storageUnavailable }
        completed = true
        return "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func zipDirectory(_ directory: URL, to output: URL) throws {
        try Task.checkCancellation()
        var coordinationError: NSError?, result: Result<Void, Error>?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading, error: &coordinationError) { archive in
            result = Result { _ = try Self.copyBounded(archive, to: output) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw PersonalContentError.storageUnavailable }
        try result.get(); try Task.checkCancellation()
    }
}
#endif
