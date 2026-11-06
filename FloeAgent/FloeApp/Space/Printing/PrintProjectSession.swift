// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CryptoKit
import Darwin
import Observation
import FloePrintCore

struct PrintProjectDocument: Codable, Sendable {
    var projectID: UUID
    var plateID = UUID()
    var revision: UInt64 = 0
    var preset: PrintPreset = .genericMarlinPLA
    var layerHeight = 0.2
    var meshAsset: String?
    var resultAsset: String?
    var resultFingerprint: String?
    var resultLayerCount: Int?
}

/// One manifest commits settings, input identity, and output identity together.
/// Meshes and results are immutable; a failed CAS leaves prior bytes intact.
actor PrintProjectDisk {
    let root: URL
    init(root: URL) { self.root = root }
    private var manifest: URL { root.appendingPathComponent("print.json") }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func locked<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = Darwin.open(root.appendingPathComponent(".print.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw PersonalContentError.storageUnavailable }
        defer { Darwin.close(fd) }
        while flock(fd, LOCK_EX) != 0 { if errno != EINTR { throw PersonalContentError.storageUnavailable } }
        defer { _ = flock(fd, LOCK_UN) }
        return try operation()
    }
    func create(_ document: PrintProjectDocument) throws {
        try locked {
            guard !FileManager.default.fileExists(atPath: manifest.path) else { throw PersonalContentError.changedDocument }
            try JSONEncoder().encode(document).write(to: manifest, options: .atomic)
        }
    }
    func load() throws -> PrintProjectDocument {
        let bytes = try Data(contentsOf: manifest)
        guard bytes.count < 64 * 1_024 else { throw PersonalContentError.invalidProject }
        let document = try JSONDecoder().decode(PrintProjectDocument.self, from: bytes)
        for name in [document.meshAsset, document.resultAsset].compactMap({ $0 }) {
            guard name == (name as NSString).lastPathComponent, !name.contains("\\"), !name.hasPrefix(".") else {
                throw PersonalContentError.invalidProject
            }
        }
        return document
    }
    func commit(_ proposed: PrintProjectDocument, expectedRevision: UInt64,
                asset: Data? = nil, fileExtension: String = "mesh") throws -> PrintProjectDocument {
        try locked {
            let current = try load()
            guard current.projectID == proposed.projectID, current.revision == expectedRevision,
                  expectedRevision < UInt64.max else { throw PersonalContentError.changedDocument }
            var next = proposed
            if let asset {
                guard ["mesh", "gcode", "ctb"].contains(fileExtension), asset.count <= 128 * 1_024 * 1_024 else { throw PrintError.sizeLimit }
                let name = hash(asset) + "." + fileExtension
                let url = root.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    guard hash(try Data(contentsOf: url, options: .mappedIfSafe)) == hash(asset) else { throw PrintError.invalidArtifact }
                } else { try asset.write(to: url, options: .atomic) }
                if fileExtension == "mesh" { next.meshAsset = name }
                else { next.resultAsset = name }
            }
            next.revision = expectedRevision + 1
            try JSONEncoder().encode(next).write(to: manifest, options: .atomic)
            return next
        }
    }
    func mesh(_ document: PrintProjectDocument) throws -> PrintMesh {
        guard let name = document.meshAsset else { throw PrintError.invalidMesh }
        let data = try Data(contentsOf: root.appendingPathComponent(name), options: .mappedIfSafe)
        guard data.count <= 36_000_000, data.count % 4 == 0,
              name == hash(data) + ".mesh" else { throw PrintError.invalidMesh }
        var positions = [Float](); positions.reserveCapacity(data.count / 4)
        data.withUnsafeBytes { buffer in
            for offset in stride(from: 0, to: data.count, by: 4) {
                positions.append(Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))))
            }
        }
        return try PrintMesh(positions: positions)
    }
    func resultURL(_ document: PrintProjectDocument) throws -> URL? {
        guard let name = document.resultAsset else { return nil }
        let url = root.appendingPathComponent(name)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard name.hasPrefix(hash(data) + ".") else { throw PrintError.invalidArtifact }
        return url
    }
}

/// Process-owned sessions retain in-flight jobs when the editor is closed.
@MainActor @Observable final class PrintProjectSession {
    private static var sessions: [UUID: PrintProjectSession] = [:]
    private static let service = PrintSlicingService(backend: NativePrintBackend())
    let id: UUID
    let disk: PrintProjectDisk
    private(set) var document: PrintProjectDocument
    var preset: PrintPreset
    var layerHeight: Double
    private(set) var triangleCount = 0
    private(set) var isBusy = false
    private(set) var isCancelling = false
    private(set) var progress = 0.0
    private(set) var completed = false
    private(set) var result: URL?
    var diagnostic: String?
    private var operation: Task<Void, Never>?
    private var identity: PrintRequestIdentity?
    private var lastError: (any Error)?

    private init(document: PrintProjectDocument, disk: PrintProjectDisk) {
        self.document = document; id = document.projectID; self.disk = disk
        preset = document.preset; layerHeight = document.layerHeight
    }
    static func open(id: UUID, directory: URL) async throws -> PrintProjectSession {
        if let existing = sessions[id] { return existing }
        let disk = PrintProjectDisk(root: directory)
        let document = try await disk.load()
        guard document.projectID == id else { throw PersonalContentError.invalidProject }
        let value = PrintProjectSession(document: document, disk: disk)
        if document.meshAsset != nil { value.triangleCount = try await disk.mesh(document).triangleCount }
        value.result = try await disk.resultURL(document)
        value.completed = value.result != nil
        sessions[id] = value
        return value
    }
    func importSTL(_ url: URL) async {
        guard !isBusy else { return }
        do {
            let mesh = try await Task.detached(priority: .userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= 50_000_084 else { throw PrintError.sizeLimit }
                return try PrintMesh(binarySTL: Data(contentsOf: url, options: .mappedIfSafe))
            }.value
            try await installMesh(mesh)
        } catch { diagnostic = error.localizedDescription }
    }
    func addCube() async {
        guard !isBusy else { return }
        do {
            let vertices: [[Float]] = [[-10,-10,0],[10,-10,0],[10,10,0],[-10,10,0],
                                       [-10,-10,20],[10,-10,20],[10,10,20],[-10,10,20]]
            let faces = [[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],
                         [1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]]
            try await installMesh(PrintMesh(positions: faces.flatMap { $0.flatMap { vertices[$0] } }))
        } catch { diagnostic = error.localizedDescription }
    }
    private func installMesh(_ mesh: PrintMesh) async throws {
        let data = mesh.positions.withUnsafeBytes { Data($0) }
        var next = document
        next.resultAsset = nil; next.resultFingerprint = nil; next.resultLayerCount = nil
        document = try await disk.commit(next, expectedRevision: document.revision, asset: data)
        triangleCount = mesh.triangleCount; result = nil; completed = false; diagnostic = nil
    }
    func updateSettings(preset: PrintPreset, layerHeight: Double, expectedRevision: UInt64) async throws {
        guard !isBusy, document.revision == expectedRevision else { throw PersonalContentError.changedDocument }
        guard layerHeight.isFinite, (0.01...2).contains(layerHeight) else { throw PrintError.invalidSetting("layer height") }
        var proposed = document
        proposed.preset = preset; proposed.layerHeight = layerHeight
        document = try await disk.commit(proposed, expectedRevision: expectedRevision)
        self.preset = preset; self.layerHeight = layerHeight
    }
    func slice() {
        guard !isBusy, document.meshAsset != nil else { return }
        isBusy = true; isCancelling = false; diagnostic = nil; lastError = nil; completed = false; progress = 0
        let preset = self.preset, height = layerHeight
        operation = Task { [self] in
            defer { isBusy = false; isCancelling = false; operation = nil; identity = nil }
            do {
                var next = document
                next.preset = preset; next.layerHeight = height
                document = try await disk.commit(next, expectedRevision: document.revision)
                let frozen = document
                let input = try PrintInput(mesh: try await disk.mesh(frozen), preset: preset,
                    overrides: [preset == .genericMarlinPLA ? "sliceHeight" : "slaSlice": height])
                let request = PrintRequest(identity: .init(projectID: id, plateID: frozen.plateID, revision: frozen.revision), input: input)
                identity = request.identity
                let artifact = try await Self.service.slice(request) { [weak self] update in
                    await MainActor.run {
                        guard let self, self.identity == update.identity, !self.isCancelling else { return }
                        self.progress = max(self.progress, update.fraction)
                    }
                }
                try Task.checkCancellation()
                guard identity == artifact.identity, document.revision == frozen.revision else { throw PrintError.staleResult }
                next = frozen
                next.resultFingerprint = artifact.inputFingerprint; next.resultLayerCount = artifact.layerCount
                document = try await disk.commit(next, expectedRevision: frozen.revision, asset: artifact.data,
                    fileExtension: artifact.format == .gcode ? "gcode" : "ctb")
                result = try await disk.resultURL(document)
                progress = 1; completed = true
            } catch {
                lastError = error
                if !Task.isCancelled, (error as? PrintError) != .cancelled { diagnostic = error.localizedDescription }
            }
        }
    }
    func cancel() { guard isBusy else { return }; isCancelling = true; operation?.cancel() }
    /// The same operation is awaitable by a run/job; closing the editor alone
    /// does not cancel it, while cancelling its owning tool does.
    func sliceAndWait() async throws -> URL {
        guard !isBusy else { throw PrintError.busy }
        slice()
        await withTaskCancellationHandler {
            await operation?.value
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
        try Task.checkCancellation()
        if let lastError { throw lastError }
        guard completed, let result else { throw PrintError.invalidArtifact }
        return result
    }
}
#endif
