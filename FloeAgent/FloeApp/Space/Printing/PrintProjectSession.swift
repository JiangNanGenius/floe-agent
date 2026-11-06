// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CryptoKit
import Darwin
import Observation
import FloePrintCore

struct PrintPlateDocument: Codable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var resultAsset: String?
    var resultFingerprint: String?
    var resultLayerCount: Int?
}
struct PrintObjectDocument: Codable, Sendable, Identifiable {
    var id = UUID()
    var plateID: UUID
    var name: String
    var meshAsset: String
    var toolID = 0
}
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
    var meshName: String?
    var sourceSnapshot: PrintSourceSnapshot?
    var processSettings: [String: Double]?
    var machine: PrintMachineConfiguration?
    var plates: [PrintPlateDocument]?
    var objects: [PrintObjectDocument]?
}

nonisolated enum PrintMeshEdit: Sendable {
    case translate(Double, Double, Double)
    case rotate(axis: Int, degrees: Double)
    case scale(Double)
    case center, dropToBed
}
/// Shared manual/AI transaction. A batch is committed once against the exact revision.
struct PrintProjectEdit: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        case addPlate, selectPlate, removePlate, addCube, duplicateObject, removeObject, moveObject, transform, arrange, renameObject, settings, assignTool
    }
    var action: Action
    var objectID: UUID?
    var plateID: UUID?
    var name: String?
    var x: Double?, y: Double?, z: Double?
    var axis: Int?, degrees: Double?, scale: Double?
    var preset: PrintPreset?
    var layerHeight: Double?
    var processSettings: [String: Double]?
    var machine: PrintMachineConfiguration?
    var toolID: Int?
}

/// Immutable assets and a locked manifest CAS preserve prior bytes on a failed edit.
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
        guard bytes.count < 512 * 1_024 else { throw PersonalContentError.invalidProject }
        let document = try JSONDecoder().decode(PrintProjectDocument.self, from: bytes)
        let assets = [document.meshAsset, document.resultAsset].compactMap { $0 }
            + (document.objects ?? []).map(\.meshAsset) + (document.plates ?? []).compactMap(\.resultAsset)
        for name in assets { try validateAssetName(name) }
        try document.machine?.validate()
        try document.sourceSnapshot?.validate()
        guard (document.plates?.count ?? 1) <= 32, (document.objects?.count ?? 1) <= 200 else { throw PrintError.sizeLimit }
        return document
    }
    private func validateAssetName(_ name: String) throws {
        guard name == (name as NSString).lastPathComponent, !name.contains("\\"), !name.hasPrefix(".") else { throw PersonalContentError.invalidProject }
    }
    private func store(_ asset: Data, fileExtension: String) throws -> String {
        guard ["mesh", "gcode", "ctb"].contains(fileExtension), asset.count <= 128 * 1_024 * 1_024 else { throw PrintError.sizeLimit }
        let digest = hash(asset), name = digest + "." + fileExtension, url = root.appendingPathComponent(digest + "." + fileExtension)
        if FileManager.default.fileExists(atPath: url.path) {
            guard hash(try Data(contentsOf: url, options: .mappedIfSafe)) == digest else { throw PrintError.invalidArtifact }
        } else { try asset.write(to: url, options: .atomic) }
        return name
    }
    func storeMesh(_ mesh: PrintMesh) throws -> String {
        try locked { try store(mesh.positions.withUnsafeBytes { Data($0) }, fileExtension: "mesh") }
    }
    func commit(_ proposed: PrintProjectDocument, expectedRevision: UInt64,
                asset: Data? = nil, fileExtension: String = "mesh") throws -> PrintProjectDocument {
        try locked {
            let current = try load()
            guard current.projectID == proposed.projectID, current.revision == expectedRevision,
                  expectedRevision < UInt64.max else { throw PersonalContentError.changedDocument }
            var next = proposed
            if let asset {
                let name = try store(asset, fileExtension: fileExtension)
                if fileExtension == "mesh" { next.meshAsset = name } else {
                    next.resultAsset = name
                    if let index = next.plates?.firstIndex(where: { $0.id == next.plateID }) {
                        next.plates?[index].resultAsset = name
                        next.plates?[index].resultFingerprint = next.resultFingerprint
                        next.plates?[index].resultLayerCount = next.resultLayerCount
                    }
                }
            }
            next.revision = expectedRevision + 1
            try JSONEncoder().encode(next).write(to: manifest, options: .atomic)
            return next
        }
    }
    func meshAsset(_ name: String) throws -> PrintMesh {
        try validateAssetName(name)
        let data = try Data(contentsOf: root.appendingPathComponent(name), options: .mappedIfSafe)
        guard data.count <= 36_000_000, data.count % 4 == 0, name == hash(data) + ".mesh" else { throw PrintError.invalidMesh }
        var positions = [Float](); positions.reserveCapacity(data.count / 4)
        data.withUnsafeBytes { buffer in
            for offset in stride(from: 0, to: data.count, by: 4) {
                positions.append(Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))))
            }
        }
        return try PrintMesh(positions: positions)
    }
    func mesh(_ document: PrintProjectDocument) throws -> PrintMesh {
        if let objects = document.objects {
            var positions = [Float]()
            for object in objects where object.plateID == document.plateID {
                let part = try meshAsset(object.meshAsset)
                guard positions.count + part.positions.count <= 9_000_000 else { throw PrintError.sizeLimit }
                positions += part.positions
            }
            return try PrintMesh(positions: positions)
        }
        guard let name = document.meshAsset else { throw PrintError.invalidMesh }
        return try meshAsset(name)
    }
    func resultURL(_ document: PrintProjectDocument) throws -> URL? {
        guard let name = document.resultAsset else { return nil }
        try validateAssetName(name)
        let url = root.appendingPathComponent(name), data = try Data(contentsOf: root.appendingPathComponent(name), options: .mappedIfSafe)
        guard data.count <= 128 * 1_024 * 1_024, name.hasPrefix(hash(data) + ".") else { throw PrintError.invalidArtifact }
        return url
    }
}

@MainActor @Observable final class PrintProjectSession {
    private static var sessions: [UUID: PrintProjectSession] = [:]
    private static let service = PrintSlicingService(backend: NativePrintBackend())
    let id: UUID
    let disk: PrintProjectDisk
    private(set) var document: PrintProjectDocument
    var preset: PrintPreset
    var layerHeight: Double
    var machine: PrintMachineConfiguration
    var processSettings: [String: Double]
    var selectedObjectID: UUID?
    private(set) var triangleCount = 0
    private(set) var isBusy = false
    private(set) var isCancelling = false
    private(set) var progress = 0.0
    private(set) var completed = false
    private(set) var result: URL?
    var diagnostic: String?
    private(set) var isEditing = false
    private var undoDocuments: [PrintProjectDocument] = []
    private var redoDocuments: [PrintProjectDocument] = []
    var canUndo: Bool { !undoDocuments.isEmpty && !isBusy && !isEditing }
    var canRedo: Bool { !redoDocuments.isEmpty && !isBusy && !isEditing }
    var plates: [PrintPlateDocument] { document.plates ?? [] }
    var objects: [PrintObjectDocument] { (document.objects ?? []).filter { $0.plateID == document.plateID } }
    var selectedObject: PrintObjectDocument? { objects.first { $0.id == selectedObjectID } ?? objects.first }
    var hasUnsavedSettings: Bool { preset != document.preset || layerHeight != document.layerHeight || processSettings != (document.processSettings ?? [:]) || machine != (document.machine ?? .generic(for: document.preset)) }
    var resultIsCurrent: Bool { result != nil && !hasUnsavedSettings && document.resultFingerprint != nil }
    private var operation: Task<Void, Never>?
    private var identity: PrintRequestIdentity?
    private var lastError: (any Error)?

    private init(document: PrintProjectDocument, disk: PrintProjectDisk) {
        self.document = document; id = document.projectID; self.disk = disk
        preset = document.preset; layerHeight = document.layerHeight
        processSettings = document.processSettings ?? [:]; machine = document.machine ?? .generic(for: document.preset)
        self.document.plates = document.plates ?? [.init(id: document.plateID, name: IDELanguageRunText.t("盘 1", "Plate 1"), resultAsset: document.resultAsset, resultFingerprint: document.resultFingerprint, resultLayerCount: document.resultLayerCount)]
        if document.objects == nil {
            self.document.objects = document.meshAsset.map { [.init(plateID: document.plateID, name: document.meshName ?? IDELanguageRunText.t("模型", "Model"), meshAsset: $0)] } ?? []
        }
        selectedObjectID = self.document.objects?.first?.id
    }
    static func open(id: UUID, directory: URL) async throws -> PrintProjectSession {
        if let existing = sessions[id] { return existing }
        let disk = PrintProjectDisk(root: directory), document = try await disk.load()
        guard document.projectID == id else { throw PersonalContentError.invalidProject }
        let value = PrintProjectSession(document: document, disk: disk)
        try await value.refresh()
        sessions[id] = value; return value
    }
    private func refresh() async throws {
        triangleCount = objects.isEmpty ? 0 : try await disk.mesh(document).triangleCount
        result = try await disk.resultURL(document); completed = result != nil
        if !objects.contains(where: { $0.id == selectedObjectID }) { selectedObjectID = objects.first?.id }
    }
    private func remember(_ previous: PrintProjectDocument) {
        undoDocuments.append(previous)
        if undoDocuments.count > 50 { undoDocuments.removeFirst(undoDocuments.count - 50) }
        redoDocuments.removeAll()
    }
    func importSTL(_ url: URL) async {
        do { try await importSTL(url, expectedRevision: document.revision) } catch { diagnostic = error.localizedDescription }
    }
    func importSTL(_ url: URL, expectedRevision: UInt64) async throws {
        guard !isBusy, !isEditing, document.revision == expectedRevision else { throw PrintError.busy }
        isEditing = true; defer { isEditing = false }
        let mesh = try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 50_000_084 else { throw PrintError.sizeLimit }
            return try PrintMesh(binarySTL: Data(contentsOf: url, options: .mappedIfSafe))
        }.value
        var next = document
        let object = PrintObjectDocument(plateID: next.plateID, name: String(url.deletingPathExtension().lastPathComponent.prefix(160)), meshAsset: try await disk.storeMesh(mesh))
        guard (next.objects?.count ?? 0) < 200 else { throw PrintError.sizeLimit }
        next.objects?.append(object); next.meshAsset = next.objects?.first(where: { $0.plateID == next.plateID })?.meshAsset; invalidate(&next, plateID: next.plateID)
        let previous = document
        document = try await disk.commit(next, expectedRevision: expectedRevision); remember(previous)
        selectedObjectID = object.id; try await refresh(); diagnostic = nil
    }
    func addCube() async { await perform(.init(action: .addCube)) }
    func perform(_ edit: PrintProjectEdit) async {
        do { try await apply([edit], expectedRevision: document.revision) } catch { diagnostic = error.localizedDescription }
    }
    func editMesh(_ edit: PrintMeshEdit) async {
        do {
            guard let object = selectedObject else { return }
            var command = PrintProjectEdit(action: .transform, objectID: object.id)
            switch edit {
            case .translate(let x, let y, let z): command.x = x; command.y = y; command.z = z
            case .rotate(let axis, let degrees): command.axis = axis; command.degrees = degrees
            case .scale(let scale): command.scale = scale
            case .center, .dropToBed:
                let mesh = try await disk.meshAsset(object.meshAsset), bounds = Self.bounds(mesh)
                if case .center = edit { command.x = -(bounds.low[0] + bounds.high[0]) / 2; command.y = -(bounds.low[1] + bounds.high[1]) / 2 }
                else { command.z = -bounds.low[2] }
            }
            try await apply([command], expectedRevision: document.revision)
        } catch { diagnostic = error.localizedDescription }
    }
    private func invalidate(_ value: inout PrintProjectDocument, plateID: UUID?) {
        for index in (value.plates ?? []).indices where plateID == nil || value.plates?[index].id == plateID {
            value.plates?[index].resultFingerprint = nil
        }
        if plateID == nil || value.plateID == plateID { value.resultFingerprint = nil }
    }
    func apply(_ edits: [PrintProjectEdit], expectedRevision: UInt64) async throws {
        guard !isBusy, !isEditing, document.revision == expectedRevision else { throw PersonalContentError.changedDocument }
        guard (1...100).contains(edits.count) else { throw PrintError.sizeLimit }
        isEditing = true; defer { isEditing = false }
        var next = document
        if hasUnsavedSettings {
            next.preset = preset; next.layerHeight = layerHeight; next.processSettings = processSettings; next.machine = machine
            invalidate(&next, plateID: nil)
        }
        for edit in edits {
            switch edit.action {
            case .settings:
                next.preset = edit.preset ?? next.preset; next.layerHeight = edit.layerHeight ?? next.layerHeight
                if let settings = edit.processSettings { next.processSettings = settings }
                if let machine = edit.machine { next.machine = machine }
                else if next.preset != document.preset { next.machine = .generic(for: next.preset) }
                try (next.machine ?? .generic(for: next.preset)).validate()
                guard next.layerHeight.isFinite, (next.preset == .genericMarlinPLA ? 0.02...1 : 0.005...0.5).contains(next.layerHeight) else { throw PrintError.invalidSetting("layer height") }
                invalidate(&next, plateID: nil)
            case .addPlate:
                guard (next.plates?.count ?? 0) < 32 else { throw PrintError.sizeLimit }
                let plate = PrintPlateDocument(name: edit.name ?? IDELanguageRunText.t("盘", "Plate") + " \((next.plates?.count ?? 0) + 1)")
                next.plates?.append(plate); next.plateID = plate.id
            case .selectPlate:
                guard let plateID = edit.plateID, next.plates?.contains(where: { $0.id == plateID }) == true else { throw PrintError.invalidSetting("plate") }
                next.plateID = plateID
            case .removePlate:
                let plateID = edit.plateID ?? next.plateID
                guard (next.plates?.count ?? 0) > 1 else { throw PrintError.invalidSetting("last plate") }
                next.objects?.removeAll { $0.plateID == plateID }; next.plates?.removeAll { $0.id == plateID }
                if next.plateID == plateID, let first = next.plates?.first { next.plateID = first.id }
            case .addCube:
                guard (next.objects?.count ?? 0) < 200 else { throw PrintError.sizeLimit }
                let mesh = try Self.cube()
                let object = PrintObjectDocument(plateID: next.plateID, name: edit.name ?? IDELanguageRunText.t("立方体", "Cube"), meshAsset: try await disk.storeMesh(mesh))
                next.objects?.append(object); selectedObjectID = object.id; invalidate(&next, plateID: next.plateID)
            case .arrange:
                let indices = (next.objects ?? []).indices.filter { next.objects?[$0].plateID == next.plateID }
                let machine = next.machine ?? .generic(for: next.preset), columns = max(1, Int(ceil(sqrt(Double(indices.count)))))
                for (slot, index) in indices.enumerated() {
                    guard let object = next.objects?[index] else { continue }
                    let mesh = try await disk.meshAsset(object.meshAsset), b = Self.bounds(mesh)
                    let x = (Double(slot % columns) + 0.5) * machine.bedWidth / Double(columns) - machine.bedWidth / 2
                    let rows = max(1, Int(ceil(Double(indices.count) / Double(columns))))
                    let y = (Double(slot / columns) + 0.5) * machine.bedDepth / Double(rows) - machine.bedDepth / 2
                    let moved = try Self.transform(mesh, .translate(x - (b.low[0] + b.high[0]) / 2, y - (b.low[1] + b.high[1]) / 2, -b.low[2]))
                    next.objects?[index].meshAsset = try await disk.storeMesh(moved)
                }
                invalidate(&next, plateID: next.plateID)
            default:
                guard let objectID = edit.objectID ?? selectedObjectID,
                      let index = next.objects?.firstIndex(where: { $0.id == objectID }), let object = next.objects?[index] else { throw PrintError.invalidSetting("object") }
                switch edit.action {
                case .duplicateObject:
                    guard (next.objects?.count ?? 0) < 200 else { throw PrintError.sizeLimit }
                    let moved = try Self.transform(try await disk.meshAsset(object.meshAsset), .translate(10, 10, 0))
                    let copy = PrintObjectDocument(plateID: object.plateID, name: object.name + IDELanguageRunText.t(" 副本", " copy"), meshAsset: try await disk.storeMesh(moved), toolID: object.toolID)
                    next.objects?.append(copy); selectedObjectID = copy.id
                case .removeObject: next.objects?.remove(at: index)
                case .moveObject:
                    guard let plateID = edit.plateID, next.plates?.contains(where: { $0.id == plateID }) == true else { throw PrintError.invalidSetting("plate") }
                    next.objects?[index].plateID = plateID; invalidate(&next, plateID: plateID)
                case .renameObject:
                    guard let name = edit.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.utf8.count <= 160 else { throw PrintError.invalidSetting("name") }
                    next.objects?[index].name = name
                case .assignTool:
                    guard let tool = edit.toolID, (next.machine ?? .generic(for: next.preset)).tools.contains(where: { $0.id == tool }) else { throw PrintError.invalidSetting("tool") }
                    next.objects?[index].toolID = tool
                case .transform:
                    var mesh = try await disk.meshAsset(object.meshAsset)
                    if edit.x != nil || edit.y != nil || edit.z != nil { mesh = try Self.transform(mesh, .translate(edit.x ?? 0, edit.y ?? 0, edit.z ?? 0)) }
                    if let degrees = edit.degrees { mesh = try Self.transform(mesh, .rotate(axis: edit.axis ?? 2, degrees: degrees)) }
                    if let scale = edit.scale { mesh = try Self.transform(mesh, .scale(scale)) }
                    next.objects?[index].meshAsset = try await disk.storeMesh(mesh)
                default: break
                }
                invalidate(&next, plateID: object.plateID)
            }
        }
        if let plate = next.plates?.first(where: { $0.id == next.plateID }) {
            next.resultAsset = plate.resultAsset; next.resultFingerprint = plate.resultFingerprint; next.resultLayerCount = plate.resultLayerCount
        }
        next.meshAsset = next.objects?.first(where: { $0.plateID == next.plateID })?.meshAsset
        let previous = document
        document = try await disk.commit(next, expectedRevision: expectedRevision); remember(previous)
        preset = document.preset; layerHeight = document.layerHeight; processSettings = document.processSettings ?? [:]; machine = document.machine ?? .generic(for: preset)
        try await refresh(); diagnostic = nil
    }
    func saveSettings() async {
        await perform(.init(action: .settings, preset: preset, layerHeight: layerHeight, processSettings: processSettings, machine: machine))
    }
    func changePreset(_ value: PrintPreset) { preset = value; layerHeight = value == .genericMarlinPLA ? 0.2 : 0.05; processSettings = [:]; machine = .generic(for: value) }
    func undo() async { await restoreHistory(undoing: true) }
    func redo() async { await restoreHistory(undoing: false) }
    private func restoreHistory(undoing: Bool) async {
        guard !isBusy, !isEditing, let stored = undoing ? undoDocuments.last : redoDocuments.last else { return }
        isEditing = true; defer { isEditing = false }
        do {
            let previous = document; document = try await disk.commit(stored, expectedRevision: document.revision)
            if undoing { undoDocuments.removeLast(); redoDocuments.append(previous) } else { redoDocuments.removeLast(); undoDocuments.append(previous) }
            preset = document.preset; layerHeight = document.layerHeight; processSettings = document.processSettings ?? [:]; machine = document.machine ?? .generic(for: preset)
            try await refresh(); diagnostic = nil
        } catch { diagnostic = error.localizedDescription }
    }
    func updateSettings(preset: PrintPreset, layerHeight: Double, expectedRevision: UInt64) async throws {
        try await apply([.init(action: .settings, preset: preset, layerHeight: layerHeight)], expectedRevision: expectedRevision)
    }
    func slice() {
        guard !isBusy, !isEditing, !objects.isEmpty else { return }
        isBusy = true; isCancelling = false; diagnostic = nil; lastError = nil; completed = false; progress = 0
        let preset = self.preset, height = layerHeight, process = processSettings
        var machine = self.machine
        if let assignedTool = objects.first?.toolID { machine.selectedTool = assignedTool }
        self.machine = machine
        operation = Task { [self] in
            defer { isBusy = false; isCancelling = false; operation = nil; identity = nil }
            do {
                // The current adapter outputs one selected tool per plate; never silently flatten a multi-tool assignment.
                let assigned = Set(objects.map(\.toolID))
                guard assigned.count <= 1 else { throw PrintError.invalidSetting("Multiple tools on one plate require separate slicing") }
                var next = document; next.preset = preset; next.layerHeight = height; next.processSettings = process; next.machine = machine
                document = try await disk.commit(next, expectedRevision: document.revision)
                let frozen = document
                var overrides = frozen.processSettings ?? [:]; overrides[preset == .genericMarlinPLA ? "sliceHeight" : "slaSlice"] = height
                var configured = machine
                if let selected = assigned.first { configured.selectedTool = selected }
                let input = try PrintInput(mesh: try await disk.mesh(frozen), preset: preset, overrides: overrides, machine: configured)
                let request = PrintRequest(identity: .init(projectID: id, plateID: frozen.plateID, revision: frozen.revision), input: input)
                identity = request.identity
                let artifact = try await Self.service.slice(request) { [weak self] update in
                    await MainActor.run { guard let self, self.identity == update.identity, !self.isCancelling else { return }; self.progress = max(self.progress, update.fraction) }
                }
                try Task.checkCancellation()
                guard identity == artifact.identity, document.revision == frozen.revision else { throw PrintError.staleResult }
                next = frozen; next.resultFingerprint = artifact.inputFingerprint; next.resultLayerCount = artifact.layerCount
                document = try await disk.commit(next, expectedRevision: frozen.revision, asset: artifact.data, fileExtension: artifact.format == .gcode ? "gcode" : "ctb")
                result = try await disk.resultURL(document); progress = 1; completed = true
            } catch { lastError = error; if !Task.isCancelled, (error as? PrintError) != .cancelled { diagnostic = error.localizedDescription } }
        }
    }
    func exportConfiguration() async -> URL? {
        do {
            let url = disk.root.appendingPathComponent("print-configuration-\(document.revision).json")
            struct Configuration: Encodable { var preset: PrintPreset; var layerHeight: Double; var processSettings: [String: Double]; var machine: PrintMachineConfiguration }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Configuration(preset: preset, layerHeight: layerHeight, processSettings: processSettings, machine: machine)).write(to: url, options: .atomic)
            return url
        } catch { diagnostic = error.localizedDescription; return nil }
    }
    func cancel() { guard isBusy else { return }; isCancelling = true; operation?.cancel() }
    func sliceAndWait() async throws -> URL {
        guard !isBusy, !isEditing else { throw PrintError.busy }
        guard !objects.isEmpty else { throw PrintError.invalidMesh }; slice()
        await withTaskCancellationHandler { await operation?.value } onCancel: { Task { @MainActor in self.cancel() } }
        try Task.checkCancellation(); if let lastError { throw lastError }; guard completed, let result else { throw PrintError.invalidArtifact }; return result
    }
    nonisolated static func bounds(_ mesh: PrintMesh) -> (low: [Double], high: [Double]) {
        var low = [Double](repeating: .infinity, count: 3), high = [Double](repeating: -.infinity, count: 3)
        for i in stride(from: 0, to: mesh.positions.count, by: 3) { for axis in 0..<3 { low[axis] = min(low[axis], Double(mesh.positions[i + axis])); high[axis] = max(high[axis], Double(mesh.positions[i + axis])) } }
        return (low, high)
    }
    nonisolated private static func transform(_ mesh: PrintMesh, _ edit: PrintMeshEdit) throws -> PrintMesh {
        var p = mesh.positions; let bounds = bounds(mesh), center = zip(bounds.low, bounds.high).map { Float(($0.0 + $0.1) / 2) }
        for i in stride(from: 0, to: p.count, by: 3) {
            switch edit {
            case .translate(let x, let y, let z):
                guard [x,y,z].allSatisfy({ $0.isFinite && abs($0) <= 10_000 }) else { throw PrintError.invalidSetting("position") }; p[i] += Float(x); p[i + 1] += Float(y); p[i + 2] += Float(z)
            case .scale(let scale):
                guard scale.isFinite, (0.001...1_000).contains(scale) else { throw PrintError.invalidSetting("scale") }
                for axis in 0..<3 { let anchor = axis == 2 ? Float(bounds.low[axis]) : center[axis]; p[i + axis] = anchor + (p[i + axis] - anchor) * Float(scale) }
            case .rotate(let axis, let degrees):
                guard (0..<3).contains(axis), degrees.isFinite, abs(degrees) <= 36_000 else { throw PrintError.invalidSetting("rotation") }
                let a = (axis + 1) % 3, b = (axis + 2) % 3, angle = Float(degrees * .pi / 180), x = p[i + a] - center[a], y = p[i + b] - center[b]
                p[i + a] = center[a] + x * cos(angle) - y * sin(angle); p[i + b] = center[b] + x * sin(angle) + y * cos(angle)
            case .center: p[i] -= center[0]; p[i + 1] -= center[1]
            case .dropToBed: p[i + 2] -= Float(bounds.low[2])
            }
        }
        if case .rotate = edit { let minimum = stride(from: 2, to: p.count, by: 3).map { p[$0] }.min() ?? 0; for i in stride(from: 2, to: p.count, by: 3) { p[i] -= minimum } }
        return try PrintMesh(positions: p)
    }
    nonisolated private static func cube() throws -> PrintMesh {
        let v: [[Float]] = [[-10,-10,0],[10,-10,0],[10,10,0],[-10,10,0],[-10,-10,20],[10,-10,20],[10,10,20],[-10,10,20]]
        let faces = [[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],[1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]]
        return try PrintMesh(positions: faces.flatMap { $0.flatMap { v[$0] } })
    }
}
#endif
