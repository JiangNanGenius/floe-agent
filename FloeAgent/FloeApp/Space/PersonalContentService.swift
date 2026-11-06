// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCanvasCore
import FloeCanvasIntegration
import FloeDiagramCore
import FloeDiagramIntegration
import FloeManufacturingCore
import FloeMusicCore
import FloeMeetings

/// Shared by Files, Creative, and agent tools. Editor commits stay in the
/// corresponding native repository; this service owns their durable location.
actor PersonalContentService {
    static let shared = PersonalContentService()
    private let storage: Result<PersonalContentLibrary, Error>

    init(root: URL? = nil) {
        storage = Result { PersonalContentLibrary(root: try root ?? PersonalContentLibrary.applicationRoot()) }
    }

    func library() throws -> PersonalContentLibrary { try storage.get() }

    func create(kind: PersonalContentKind, title: String, folders: [String] = [], id: UUID = UUID()) async throws -> PersonalContentRecord {
        let library = try library()
        let record = try await library.create(kind: kind, title: title, in: folders, id: id) { directory, id in
            switch kind {
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
        case .canvas:
            _ = try await FileCanvasRepository(root: location.url.appendingPathComponent("Canvas")).load(canvasID: record.id)
        case .diagram:
            _ = try await FileDiagramRepository(directory: location.url.appendingPathComponent("Diagram")).load(record.id)
        case .music:
            _ = try await NativeMusicRepository(root: location.url.appendingPathComponent("Music")).load(projectID: .init(rawValue: record.id.uuidString.lowercased()))
        case .printing:
            let document = try await PrintProjectDisk(root: location.url.appendingPathComponent("Printing")).load()
            guard document.projectID == record.id else { throw PersonalContentError.invalidProject }
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
        case .cad2D: "ruler"
        case .cad3D: "cube.transparent"
        case .printing: "printer"
        case .manufacturing: "gearshape.2"
        case .document: "doc"
        }
    }
    static var creationKinds: [Self] { [.canvas, .diagram, .music, .meeting, .printing, .manufacturing] }
}
#endif
