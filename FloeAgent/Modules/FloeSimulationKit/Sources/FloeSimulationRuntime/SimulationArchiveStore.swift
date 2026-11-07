import Foundation
import CryptoKit
import FloeSimulationCore
import FloeSimulationGeometry

public struct SimulationWorkspaceDocument: Codable, Equatable, Sendable {
    public var formatVersion = 1
    public var source: SimulationSourceRef
    public var materials: [SimulationMaterial]
    public var studies: [SimulationStudy]
    public var meshes: [SimulationMesh]
    public var resultIDs: [UUID]
    public var animationGraphData: Data?
    public var meshSettings: SimulationMeshSettings?
    public init(source: SimulationSourceRef, materials: [SimulationMaterial] = [], studies: [SimulationStudy] = [], meshes: [SimulationMesh] = [], resultIDs: [UUID] = []) {
        self.source = source; self.materials = materials; self.studies = studies; self.meshes = meshes; self.resultIDs = resultIDs
    }
}

public struct SimulationSavedResult: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var source: SimulationSourceRef
    public var studyID: UUID
    public var studyRevision: UInt64
    public var name: String
    public var backendID: String
    public var kind: SimulationStudyKind
    public var savedAt: Date
}

/// The host must supply a project-owned directory. Result datasets are immutable
/// packages with checksummed binary chunks, never one unbounded JSON value.
public actor SimulationArchiveStore {
    public let directory: URL
    private let maximumBytes: Int
    private struct Chunk: Codable { var file: String; var count: Int; var sha256: String }
    private struct Field: Codable { var metadata: SimulationResultField; var real: Chunk; var imaginary: Chunk? }
    private struct Frame: Codable { var metadata: SimulationResultFrame; var fields: [Field] }
    private struct Manifest: Codable { var version: Int; var request: SimulationRequest; var result: SimulationResult; var frames: [Frame] }

    public init(directory: URL, maximumBytes: Int = 256_000_000) throws {
        guard directory.isFileURL, maximumBytes > 0 else { throw SimulationError.invalidInput("A project-owned file directory and positive archive budget are required.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory.resolvingSymlinksInPath().standardizedFileURL; self.maximumBytes = maximumBytes
    }

    private func validateDocument(_ document: SimulationWorkspaceDocument) throws {
        try document.source.validate()
        guard document.formatVersion == 1, Set(document.studies.map(\.id)).count == document.studies.count,
              Set(document.materials.map(\.id)).count == document.materials.count,
              Set(document.meshes.map(\.id)).count == document.meshes.count,
              document.studies.count <= 256, document.materials.count <= 4096, document.meshes.count <= 16, document.resultIDs.count <= 4096,
              document.animationGraphData.map({ $0.count <= 16_000_000 }) ?? true else { throw SimulationError.invalidInput("Invalid workspace format, identities or document budget.") }
        var configurationBytes = 0, remainingNodes = 1_000_000, remainingElements = 5_000_000
        for study in document.studies {
            guard study.name.utf8.count <= 2048, study.configuration.count <= 8_000_000, configurationBytes <= 64_000_000-study.configuration.count else { throw SimulationError.resourceLimit("Study names or configurations exceed the document budget.") }
            configurationBytes += study.configuration.count
        }
        for mesh in document.meshes {
            guard mesh.nodes.count <= remainingNodes, mesh.elements.count <= remainingElements else { throw SimulationError.resourceLimit("Workspace meshes exceed the document budget.") }
            remainingNodes -= mesh.nodes.count; remainingElements -= mesh.elements.count
        }
        for mesh in document.meshes { try mesh.validate(); guard mesh.source == document.source else { throw SimulationError.staleSource } }
    }

    public func saveDocument(_ document: SimulationWorkspaceDocument) throws {
        try validateDocument(document)
        let data = try encode(document)
        guard data.count <= maximumBytes else { throw SimulationError.resourceLimit("The workspace exceeds its archive budget.") }
        try data.write(to: checkedURL(directory.appendingPathComponent("workspace.json")), options: .atomic)
    }

    public func readDocument() throws -> SimulationWorkspaceDocument {
        let document = try JSONDecoder().decode(SimulationWorkspaceDocument.self, from: boundedData(directory.appendingPathComponent("workspace.json")))
        try validateDocument(document)
        return document
    }

    public func saveResult(_ result: SimulationResult, request: SimulationRequest) throws {
        try result.validate(for: request)
        let fm = FileManager.default
        let parent = try checkedURL(directory.appendingPathComponent("results", isDirectory: true))
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appendingPathComponent(result.id.uuidString, isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else { throw SimulationError.invalidInput("A result with this identity already exists.") }
        let staging = parent.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        var frames: [Frame] = [], written = 0
        for (fi, frame) in result.frames.enumerated() {
            var fields: [Field] = []
            for (vi, field) in frame.fields.enumerated() {
                let real = try writeChunk(field.values, name: "\(fi)-\(vi)-real.f64", to: staging, written: &written)
                let imaginary = try field.imaginaryValues.map { try writeChunk($0, name: "\(fi)-\(vi)-imag.f64", to: staging, written: &written) }
                var metadata = field; metadata.values = []; metadata.imaginaryValues = nil
                fields.append(.init(metadata: metadata, real: real, imaginary: imaginary))
            }
            var metadata = frame; metadata.fields = []
            frames.append(.init(metadata: metadata, fields: fields))
        }
        var metadata = result; metadata.frames = []
        let data = try encode(Manifest(version: 1, request: request, result: metadata, frames: frames))
        guard data.count <= maximumBytes - written else { throw SimulationError.resourceLimit("The result package exceeds its archive budget.") }
        try data.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        let summary = SimulationSavedResult(id:result.id,source:result.source,studyID:result.studyID,studyRevision:result.studyRevision,name:request.study.name,backendID:result.backend.id,kind:request.study.kind,savedAt:Date())
        try encode(summary).write(to:staging.appendingPathComponent("summary.json"),options:.atomic)
        try fm.moveItem(at: staging, to: destination)
    }

    public func readResult(_ id: UUID) throws -> SimulationResult {
        let parent = directory.appendingPathComponent("results", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        let manifestData = try boundedData(parent.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        try manifest.request.validate()
        guard manifest.version == 1, manifest.result.id == id else { throw SimulationError.corruptArchive("The result package identity or format is invalid.") }
        var result = manifest.result, read = manifestData.count
        result.frames = try manifest.frames.map { frame in
            var restored = frame.metadata
            restored.fields = try frame.fields.map { field in
                var value = field.metadata
                value.values = try readChunk(field.real, in: parent, read: &read)
                value.imaginaryValues = try field.imaginary.map { try readChunk($0, in: parent, read: &read) }
                return value
            }
            return restored
        }
        try manifest.request.validate(); try result.validate(for: manifest.request)
        return result
    }

    public func exportCSV(_ result: SimulationResult) throws -> URL {
        let folder = try checkedURL(directory.appendingPathComponent("exports", isDirectory: true))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = try checkedURL(folder.appendingPathComponent(result.id.uuidString + ".csv"))
        var text = "frame,time_s,frequency_hz,field,unit,location,entity,component,real,imaginary\n"
        var byteCount = text.utf8.count
        func escaped(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        for frame in result.frames { for field in frame.fields {
            try field.validate()
            for i in field.values.indices {
                let row = "\(frame.id),\(frame.timeSeconds.map(String.init(describing:)) ?? ""),\(frame.frequencyHz.map(String.init(describing:)) ?? ""),\(escaped(field.id)),\(escaped(field.unit)),\(field.location.rawValue),\(i / field.components),\(i % field.components),\(field.values[i]),\(field.imaginaryValues.map { String($0[i]) } ?? "")\n"
                guard row.utf8.count <= maximumBytes-byteCount else { throw SimulationError.resourceLimit("The CSV exceeds its export budget.") }
                byteCount += row.utf8.count; text += row
            }
        } }
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    public func saveAttachment<T: Encodable & Sendable>(_ value: T, id: UUID, fileExtension: String) throws -> URL {
        guard ["animation.json"].contains(fileExtension) else { throw SimulationError.invalidInput("Unsupported simulation attachment type.") }
        let folder = try checkedURL(directory.appendingPathComponent("exports",isDirectory:true))
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let data = try encode(value)
        guard data.count <= maximumBytes else { throw SimulationError.resourceLimit("The attachment exceeds its export budget.") }
        let url = try checkedURL(folder.appendingPathComponent(id.uuidString+"."+fileExtension))
        try data.write(to:url,options:.atomic); return url
    }

    public func resultIDs() throws -> [UUID] {
        let folder = try checkedURL(directory.appendingPathComponent("results",isDirectory:true))
        guard FileManager.default.fileExists(atPath:folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:.skipsHiddenFiles).compactMap { url in
            let metadata = try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard metadata.isDirectory == true, metadata.isSymbolicLink != true else { return nil }
            return UUID(uuidString:url.lastPathComponent)
        }.sorted { $0.uuidString < $1.uuidString }
    }

    public func savedResults() throws -> [SimulationSavedResult] {
        let ids = try resultIDs()
        guard ids.count <= 4096 else { throw SimulationError.resourceLimit("There are too many result packages to list in one workspace.") }
        return try ids.map { id in
            let path = directory.appendingPathComponent("results/"+id.uuidString+"/summary.json")
            let data = try boundedData(path)
            guard data.count <= 64_000 else { throw SimulationError.corruptArchive("A result summary is too large.") }
            let value = try JSONDecoder().decode(SimulationSavedResult.self,from:data)
            try value.source.validate()
            guard value.id == id else { throw SimulationError.corruptArchive("A result summary has the wrong identity.") }
            return value
        }.sorted { $0.savedAt < $1.savedAt }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(value) }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func boundedData(_ url: URL) throws -> Data {
        _ = try checkedURL(url)
        let metadata = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard metadata.isSymbolicLink != true, metadata.isRegularFile == true, let size = metadata.fileSize, size >= 0, size <= maximumBytes else { throw SimulationError.corruptArchive("Invalid archive file or size.") }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
    private func checkedURL(_ url: URL) throws -> URL {
        let candidate = url.standardizedFileURL
        let root = directory.pathComponents, parts = candidate.pathComponents
        guard parts.starts(with:root) else { throw SimulationError.invalidInput("The artifact path is outside this workspace.") }
        var current = directory
        var ancestors = [directory]
        for part in parts.dropFirst(root.count) { current.appendPathComponent(part); ancestors.append(current) }
        for current in ancestors {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath:current.path)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw SimulationError.corruptArchive("Symbolic links are not allowed inside simulation artifacts.") }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && [CocoaError.fileNoSuchFile.rawValue,CocoaError.fileReadNoSuchFile.rawValue].contains(error.code) { continue }
        }
        return candidate
    }
    private func writeChunk(_ values: [Double], name: String, to parent: URL, written: inout Int) throws -> Chunk {
        guard values.count <= (maximumBytes - written) / 8 else { throw SimulationError.resourceLimit("The result exceeds its archive budget.") }
        var data = Data(capacity: values.count * 8)
        for value in values { var bits = value.bitPattern.littleEndian; withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) } }
        try data.write(to: parent.appendingPathComponent(name), options: .atomic); written += data.count
        return .init(file: name, count: values.count, sha256: digest(data))
    }
    private func readChunk(_ chunk: Chunk, in parent: URL, read: inout Int) throws -> [Double] {
        guard chunk.file.range(of: #"^[0-9]+-[0-9]+-(real|imag)\.f64$"#, options: .regularExpression) != nil,
              chunk.count >= 0, chunk.count <= (maximumBytes - read) / 8 else { throw SimulationError.corruptArchive("Invalid result chunk reference or budget.") }
        let data = try boundedData(parent.appendingPathComponent(chunk.file))
        guard data.count == chunk.count * 8, digest(data) == chunk.sha256 else { throw SimulationError.corruptArchive("The result chunk checksum or length does not match.") }
        read += data.count
        return data.withUnsafeBytes { raw in (0..<chunk.count).map { Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self))) } }
    }
}
