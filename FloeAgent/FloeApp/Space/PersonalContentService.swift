// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCanvasCore
import FloeCanvasIntegration
import FloeCanvasTemplates
import FloeDiagramCore
import FloeDiagramIntegration
import FloeManufacturingCore
import FloeMusicCore
import FloeMeetings
import FloeChemistryCore
import FloeCAD
import FloeLaTeXCore
import FloeElectronicsCore
import FloeElectronicsUI

/// Shared by Files, Creative, and agent tools. Editor commits stay in the
/// corresponding native repository; this service owns their durable location.
actor PersonalContentService {
    static let shared = PersonalContentService()
    private let storage: Result<PersonalContentLibrary, Error>
    private var biologyHost: BiologyHostServices?

    func configureBiology(_ host: BiologyHostServices) { biologyHost = host }

    func configuredBiology() throws -> BiologyHostServices {
        guard let biologyHost else { throw PersonalContentError.storageUnavailable }
        return biologyHost
    }

    init(root: URL? = nil) {
        storage = Result { PersonalContentLibrary(root: try root ?? PersonalContentLibrary.applicationRoot()) }
    }

    func library() throws -> PersonalContentLibrary { try storage.get() }

    func createCanvas(template: CanvasTemplate?, chinese: Bool, goal: String? = nil) async throws -> PersonalContentRecord {
        let id = UUID()
        let title = template?.title.value(chinese: chinese) ?? (chinese ? "未命名画布" : "Untitled canvas")
        let brief = goal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard brief.utf8.count <= 128_000 else { throw PersonalContentError.invalidProject }
        let snapshot: CanvasSnapshot
        if let template {
            snapshot = try CanvasTemplateEngine.instantiate(template, name: title,
                inputs: brief.isEmpty ? [:] : ["brief": .text(brief)], newCanvasID: id).snapshot
        } else {
            var page = CanvasPageSnapshot(name: chinese ? "画布" : "Canvas")
            if !brief.isEmpty {
                page.nodes = [CanvasNodeSnapshot(title: chinese ? "创作目标" : "Goal", content: .text(brief),
                    frame: .init(center: .zero, size: .init(width: 320, height: 200)))]
            }
            snapshot = CanvasSnapshot(id: id, name: title, pages: [page])
        }
        let library = try library()
        return try await library.create(kind: .canvas, title: title, id: id) { directory, id in
            let repository = try FileCanvasRepository(root: directory.appendingPathComponent("Canvas"))
            try await repository.create(canvasID: id, snapshot: snapshot, requestID: UUID())
        }
    }

    func create(kind: PersonalContentKind, title: String, folders: [String] = [], id: UUID = UUID()) async throws -> PersonalContentRecord {
        let library = try library()
        let record = try await library.create(kind: kind, title: title, in: folders, id: id) { directory, id in
            switch kind {
            case .image, .drawing, .video:
                try await PersonalMediaFactory.create(kind: kind, title: title, id: id, directory: directory)
            case .document:
                let original = directory.appendingPathComponent("Original")
                try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
                try Data(("# " + title + "\n\n").utf8).write(to: original.appendingPathComponent("Document.md"), options: .atomic)
            case .cad2D, .cad3D:
                let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("Document.floecad"), name: title)
                if kind == .cad2D { await document.activate2DWorkspace() }
                let saved = await document.save()
                await document.close()
                guard saved.succeeded else { throw PersonalContentError.storageUnavailable }
            case .canvas:
                let repository = try FileCanvasRepository(root: directory.appendingPathComponent("Canvas"))
                let page = CanvasPageSnapshot(name: IDELanguageRunText.t("画布", "Canvas"))
                let snapshot = CanvasSnapshot(id: id, name: title, pages: [page])
                try await repository.create(canvasID: id, snapshot: snapshot, requestID: UUID())
            case .diagram:
                let repository = try FileDiagramRepository(directory: directory.appendingPathComponent("Diagram"))
                try await repository.create(DiagramDocument(id: id, title: title))
            case .printing:
                try await PrintProjectDisk(root: directory.appendingPathComponent("Printing")).create(.init(projectID: id))
            case .manufacturing:
                let destination = directory.appendingPathComponent("Manufacturing")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                var study = ManufacturingStudy.shaft()
                study.id = id; study.name = title
                try study.encoded().write(to: destination.appendingPathComponent("draft.json"), options: .atomic)
            case .music:
                let repository = try NativeMusicRepository(root: directory.appendingPathComponent("Music"))
                let document = try MusicDocument(id: .init(rawValue: id.uuidString.lowercased()), name: title)
                _ = try await repository.save(document: document, expectedRevision: nil, fence: nil)
            case .geography:
                try await GISProjectOriginal.create(id: id, title: title, directory: directory)
            case .electronics:
                let project = await EDABuiltinLibrary.makeProject(id: id, title: title)
                _ = try await EDAProjectStore.create(root: directory.appendingPathComponent("Electronics"), project: project)
            case .chemistry:
                try await ChemistryHostFactory.create(id: id, title: title, directory: directory)
            case .biology:
                let host = try await self.configuredBiology()
                try await host.createReserved(id: id, title: title)
                try BiologyOriginalBinding(projectID: id).write(to: directory)
            case .latex:
                let template=IDELanguageRunText.isChinese ? "chinese":"article"
                _ = try Self.createLaTeXOriginal(id:id,title:title,templateID:template,directory:directory)
            case .meeting:
                let destination = directory.appendingPathComponent("Meeting")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let database = try MeetingDatabase(path: destination.appendingPathComponent("meeting.sqlite").path)
                _ = try await MeetingService(database: database).createMeeting(id: MeetingID(id), title: title)
            default:
                throw PersonalContentError.invalidProject
            }
        }
        try await verify(record)
        return record
    }

    /// A retry validates the actual editor original before returning success.
    func verify(_ record: PersonalContentRecord) async throws {
        let location = try await library().resolve(record.id)
        switch record.kind {
        case .image, .drawing, .video:
            try await PersonalMediaFactory.verify(kind: record.kind, id: record.id, directory: location.url)
        case .document:
            _ = try await originalFile(record.id)
        case .cad2D, .cad3D:
            let document = try await FloeCADDocument.open(at: location.url.appendingPathComponent("Document.floecad"))
            await document.close()
        case .canvas:
            _ = try await FileCanvasRepository(root: location.url.appendingPathComponent("Canvas")).load(canvasID: record.id)
        case .diagram:
            _ = try await FileDiagramRepository(directory: location.url.appendingPathComponent("Diagram")).load(record.id)
        case .music:
            _ = try await NativeMusicRepository(root: location.url.appendingPathComponent("Music")).load(projectID: .init(rawValue: record.id.uuidString.lowercased()))
        case .geography:
            _ = try await personalPreviewOffMain { try GISProjectOriginal.read(id: record.id, directory: location.url) }
        case .electronics:
            _ = try await EDAProjectStore(root: location.url.appendingPathComponent("Electronics"), projectID: record.id, readOnly: true).load()
        case .printing:
            let document = try await PrintProjectDisk(root: location.url.appendingPathComponent("Printing")).load()
            guard document.projectID == record.id else { throw PersonalContentError.invalidProject }
        case .chemistry:
            _ = try await ChemistryHostFactory.verifiedStore(id: record.id, directory: location.url)
        case .biology:
            try BiologyOriginalBinding.verify(id: record.id, directory: location.url)
            let project = try await configuredBiology().store.load(record.id)
            guard project.id == record.id else { throw PersonalContentError.invalidProject }
        case .latex:
            let store=try LaTeXProjectStore(root:location.url.appendingPathComponent("LaTeX"))
            let manifest=try await store.manifest()
            guard manifest.id==record.id,manifest.owner == .init(kind:.space,id:record.id) else {throw PersonalContentError.invalidProject}
        case .meeting:
            let file = location.url.appendingPathComponent("Meeting/meeting.sqlite")
            guard FileManager.default.fileExists(atPath: file.path) else { throw PersonalContentError.invalidProject }
            _ = try await MeetingService(database: MeetingDatabase(path: file.path)).meeting(MeetingID(record.id))
        case .manufacturing:
            let data = try Data(contentsOf: location.url.appendingPathComponent("Manufacturing/draft.json"))
            guard data.count <= 32_000_000 else { throw PersonalContentError.invalidProject }
            try JSONDecoder().decode(ManufacturingStudy.self, from: data).validate(requireOperations: false)
        default:
            throw PersonalContentError.invalidProject
        }
    }

    func importFile(_ source: URL, folders: [String]) async throws -> PersonalContentRecord {
        if ["floegis", "geojson", "gpkg", "gpx", "kml", "kmz", "asc", "mbtiles"].contains(source.pathExtension.lowercased()) { return try await importGeography(source, folders: folders) }
        if source.pathExtension.lowercased()=="floeeda" {return try await importElectronics(source,folders:folders)}
        if source.pathExtension.lowercased()=="tex" {return try await importLaTeX(source,folders:folders)}
        let library = try library()
        let title = source.deletingPathExtension().lastPathComponent
        return try await library.create(kind: .document, title: title, in: folders) { directory, _ in
            try await Task.detached(priority: .userInitiated) {
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                var coordinationError: NSError?
                var copyResult: Result<Void, Error>?
                let coordinator = NSFileCoordinator()
                coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
                    copyResult = Result {
                        let attributes = try FileManager.default.attributesOfItem(atPath: readable.path)
                        guard attributes[.type] as? FileAttributeType == .typeRegular,
                              let size = attributes[.size] as? NSNumber, size.int64Value <= 2_147_483_648 else {
                            throw PersonalContentError.invalidProject
                        }
                        let target = directory.appendingPathComponent("Original", isDirectory: true)
                        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                        try FileManager.default.copyItem(at: readable, to: target.appendingPathComponent(source.lastPathComponent))
                    }
                }
                if let coordinationError { throw coordinationError }
                guard let copyResult else { throw PersonalContentError.storageUnavailable }
                try copyResult.get()
            }.value
        }
    }

    func importLaTeX(_ source:URL,folders:[String]) async throws -> PersonalContentRecord {
        let files=try await Task.detached(priority:.userInitiated) {
            let scoped=source.startAccessingSecurityScopedResource();defer {if scoped {source.stopAccessingSecurityScopedResource()}}
            var coordinationError:NSError?,result:Result<[String:Data],Error>?
            NSFileCoordinator().coordinate(readingItemAt:source,options:[],error:&coordinationError) {readable in
                result=Result {
                    let values=try readable.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
                    guard values.isRegularFile==true,values.isSymbolicLink != true,(values.fileSize ?? 0)<=512*1024*1024 else {throw PersonalContentError.invalidProject}
                    if source.pathExtension.lowercased()=="zip" {return try LaTeXProjectArchive.inspect(readable)}
                    guard source.pathExtension.lowercased()=="tex",(values.fileSize ?? 0)<=16*1024*1024 else {throw PersonalContentError.invalidProject}
                    let data=try Data(contentsOf:readable);guard String(data:data,encoding:.utf8) != nil else {throw LaTeXError.invalidText}
                    return ["main.tex":data]
                }
            }
            if let coordinationError {throw coordinationError}
            guard let result else {throw PersonalContentError.storageUnavailable};return try result.get()
        }.value
        let main=try LaTeXProjectArchive.recommendedMainFile(files),title=source.deletingPathExtension().lastPathComponent
        let record=try await library().create(kind:.latex,title:title,in:folders) {directory,id in
            _ = try LaTeXProjectStore.create(root:directory.appendingPathComponent("LaTeX"),id:id,owner:.init(kind:.space,id:id),title:title,files:files,mainFile:main,engine:.xeLaTeX)
        }
        try await verify(record);return record
    }

    nonisolated static func createLaTeXOriginal(id:UUID,title:String,templateID:String,directory:URL) throws -> LaTeXProjectStore {
        guard let template=LaTeXTemplates.all.first(where:{$0.id==templateID}) else {throw PersonalContentError.invalidProject}
        return try LaTeXProjectStore.create(root:directory.appendingPathComponent("LaTeX"),id:id,
            owner:.init(kind:.space,id:id),title:title,files:template.files,mainFile:template.mainFile,engine:template.engine)
    }

    func createLaTeX(title:String,templateID:String,folders:[String]=[],id:UUID=UUID()) async throws -> PersonalContentRecord {
        let record=try await library().create(kind:.latex,title:title,in:folders,id:id) {directory,id in
            _ = try Self.createLaTeXOriginal(id:id,title:title,templateID:templateID,directory:directory)
        }
        try await verify(record);return record
    }

    func originalFile(_ id: UUID) async throws -> URL {
        let library = try library()
        let value = try await library.resolve(id)
        guard value.record.kind == .document else { throw PersonalContentError.invalidProject }
        let directory = value.url.appendingPathComponent("Original")
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard files.count == 1, let file = files.first else { throw PersonalContentError.invalidProject }
        let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw PersonalContentError.invalidProject }
        return file
    }
}

extension PersonalContentKind {
    var title: String {
        switch self {
        case .canvas: IDELanguageRunText.t("混合画布", "Canvas")
        case .diagram: IDELanguageRunText.t("图示", "Diagram")
        case .image: IDELanguageRunText.t("图像", "Image")
        case .drawing: IDELanguageRunText.t("绘画", "Drawing")
        case .video: IDELanguageRunText.t("视频", "Video")
        case .music: IDELanguageRunText.t("音乐", "Music")
        case .meeting: IDELanguageRunText.t("会议", "Meeting")
        case .chemistry: IDELanguageRunText.t("化学工程", "Chemistry project")
        case .biology: IDELanguageRunText.t("生物工程", "Biology project")
        case .latex: IDELanguageRunText.t("LaTeX 论文", "LaTeX document")
        case .electronics: IDELanguageRunText.t("电路设计", "Electronics")
        case .geography: IDELanguageRunText.t("地理信息", "Geography")
        case .cad2D: IDELanguageRunText.t("二维设计", "2D design")
        case .cad3D: IDELanguageRunText.t("三维设计", "3D design")
        case .printing: IDELanguageRunText.t("3D 打印", "3D printing")
        case .manufacturing: IDELanguageRunText.t("加工", "Manufacturing")
        case .document: IDELanguageRunText.t("文件", "File")
        }
    }
    var systemImage: String {
        switch self {
        case .canvas: "rectangle.and.pencil.and.ellipsis"
        case .diagram: "point.3.connected.trianglepath.dotted"
        case .image: "photo"
        case .drawing: "paintbrush.pointed"
        case .video: "film"
        case .music: "pianokeys"
        case .meeting: "waveform.and.mic"
        case .chemistry: "atom"
        case .biology: "microbe"
        case .latex: "doc.richtext"
        case .electronics: "cpu"
        case .geography: "map"
        case .cad2D: "ruler"
        case .cad3D: "cube.transparent"
        case .printing: "printer"
        case .manufacturing: "gearshape.2"
        case .document: "doc"
        }
    }
    // Printing and machining are created from CAD's Manufacturing workspace.
    // Keep their record kinds readable for existing projects and results.
    static var creationKinds: [Self] { [.canvas, .diagram, .latex, .music, .meeting, .chemistry, .biology, .document, .drawing, .image, .video, .cad2D, .cad3D, .electronics, .geography] }
}
#endif
