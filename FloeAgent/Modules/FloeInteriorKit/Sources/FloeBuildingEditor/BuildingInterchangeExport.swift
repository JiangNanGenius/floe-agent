// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import CoreGraphics
import CryptoKit
import FloeCAD

public enum BuildingInterchangeFormat: String, CaseIterable, Codable, Sendable {
    case dwg, dxf, pdf, ifc, step, glb, obj, stl

    public var isDrawing: Bool { self == .dwg || self == .dxf || self == .pdf }
}

public struct BuildingInterchangeReceipt: Sendable {
    public let url: URL
    public let format: BuildingInterchangeFormat
    public let byteCount: Int
    public let sha256: String
    public let losses: [String]
}

@MainActor public enum BuildingInterchangeExport {
    public typealias Encoder = @MainActor (Data) async throws -> Data

    public static func write(document: FloeCADDocument, scope: CADBuildingExportScope = .wholeProject,
                             pageID: UUID? = nil, format: BuildingInterchangeFormat, to destination: URL,
                             encodeDWG: Encoder? = nil, encodeIFC: Encoder? = nil) async throws -> BuildingInterchangeReceipt {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let target = parent.appendingPathComponent(destination.lastPathComponent, isDirectory: false)
        let source = document.url.resolvingSymlinksInPath().standardizedFileURL
        var directory: ObjCBool = false
        guard destination.isFileURL, target.pathExtension.lowercased() == format.rawValue,
              !target.pathComponents.starts(with: source.pathComponents),
              fm.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue,
              !fm.fileExists(atPath: target.path) else { throw CADBuildingError.invalid("Choose a new exchange file outside the source document.") }
        guard pageID == nil || (format.isDrawing && scope == .wholeProject) else {
            throw CADBuildingError.invalid("Choose either an existing drawing page or a building scope.")
        }
        let identity = document.savedIdentity, changes = document.buildingChangeCount
        func checkSource() throws {
            try Task.checkCancellation()
            guard !document.isClosed, !document.isReadOnly, !document.hasUnsavedChanges, !document.hasUnfinishedBuildingDraftingInput,
                  identity == document.savedIdentity, changes == document.buildingChangeCount else {
                throw CADBuildingError.invalid("Save the current building before exporting this file.")
            }
        }
        try checkSource()
        var losses: [String] = []
        let bytes: Data
        if let pageID {
            let service = CADDrawingService(document: document)
            if format == .dwg {
                guard let encode = encodeDWG ?? document.drawingDWGEncoder else { throw CADBuildingError.invalid("The native DWG encoder is unavailable.") }
                let dxf = try await service.exportDataAsync(pageID: pageID, format: "dxf")
                bytes = try await encode(dxf)
            } else { bytes = try await service.exportDataAsync(pageID: pageID, format: format.rawValue) }
        } else {
            let selection = try document.buildingExportSelection(scope)
            if scope == .wholeProject, try document.hasBuildingAssemblyPlacementsForExport() {
                throw CADBuildingError.invalid("This drawing contains separate assembly placements. Choose a building scope, an authored page, or export the assembly from its CAD workbench.")
            }
            if format.isDrawing {
                let temp = fm.temporaryDirectory.appendingPathComponent("FloeBuildingPlan-" + UUID().uuidString, isDirectory: true)
                try fm.createDirectory(at: temp, withIntermediateDirectories: false)
                defer { try? fm.removeItem(at: temp) }
                let plan = try await document.createScopedBuildingPlan(scope, at: temp.appendingPathComponent("Plan.floecad"))
                defer { plan.close() }
                let planData = try plan.buildingPlanInterchange(format: format == .pdf ? "pdf" : "dxf", storeys: selection.storeys)
                if format == .dwg {
                    guard let encode = encodeDWG ?? document.drawingDWGEncoder else { throw CADBuildingError.invalid("The native DWG encoder is unavailable.") }
                    bytes = try await encode(planData)
                } else { bytes = planData }
                losses = ["Floor plans contain projected linework. Curves are segmented; sketch constraints and solid history are omitted."]
                if format != .pdf { losses.append("DXF and DWG use compact ASCII layer names and retain floor elevations in millimetres.") }
            } else if format == .ifc {
                guard let encodeIFC else { throw CADBuildingError.invalid("The local IFC writer is unavailable.") }
                bytes = try await encodeIFC(document.buildingIFCInterchangeInput(scope))
                try await Task.detached(priority: .userInitiated) { try selection.verifyBuildingIFC(bytes) }.value
                losses = ["IFC4 stores tessellated solids and authored floor membership. Parametric history, native host relationships, and room boundary sketches are omitted."]
            } else {
                guard !selection.bodyIDs.isEmpty else { throw CADBuildingError.invalid("The scope has no saved 3D bodies for this format.") }
                let selected = CADExchangeSelection(scope: .part, bodyIDs: selection.bodyIDs,
                    expectedRevision: identity.revision, expectedChangeCount: changes, expectedContentSHA256: identity.contentSHA256)
                switch document.nativeExchangeExport(format: format.rawValue, pageID: nil, selection: selected, dryRun: false) {
                case let .success(data, _, coverage):
                    guard coverage.complete, coverage.excludedCount == 0, coverage.includedCount == selection.bodyIDs.count,
                          Set(coverage.items.filter(\.included).map(\.bodyID)) == Set(selection.bodyIDs) else {
                        throw CADBuildingError.invalid("The writer did not cover all selected bodies.")
                    }
                    bytes = data
                    losses = coverage.formatLoss + coverage.notes
                    if selection.elements.contains(where: { $0.kind == .space }) {
                        losses.append("Room boundaries have no 3D body and are present only in planar or semantic outputs.")
                    }
                case let .failure(error): throw error
                case .coverageRequired, .coverage: throw CADBuildingError.invalid("The format cannot represent every selected body with the requested fidelity.")
                }
            }
        }
        try checkSource()
        let stage = parent.appendingPathComponent(".building-exchange-" + UUID().uuidString)
        defer { try? fm.removeItem(at: stage) }
        let digest = try await Task.detached(priority: .userInitiated) {
            try validate(bytes, format: format)
            try bytes.write(to: stage, options: .withoutOverwriting)
            guard try Data(contentsOf: stage, options: .mappedIfSafe) == bytes else {
                throw CADBuildingError.invalid("The exchange file did not read back with the written bytes.")
            }
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }.value
        let disk = await FloeCADDocument.storedIdentity(at: document.url)
        try checkSource()
        guard disk?.revision == identity.revision, disk?.contentSHA256 == identity.contentSHA256 else {
            throw CADBuildingError.invalid("The saved building changed before this export finished.")
        }
        try fm.moveItem(at: stage, to: target)
        return .init(url: target, format: format, byteCount: bytes.count, sha256: digest, losses: losses)
    }

    nonisolated private static func validate(_ data: Data, format: BuildingInterchangeFormat) throws {
        let valid: Bool
        switch format {
        case .pdf:
            valid = CGDataProvider(data: data as CFData).flatMap { CGPDFDocument($0) }.map { $0.numberOfPages > 0 } == true
        case .dwg:
            valid = data.count > 128 && ["AC1015", "AC1018", "AC1021", "AC1024", "AC1027", "AC1032"].contains(String(decoding: data.prefix(6), as: UTF8.self))
        case .glb:
            valid = data.count >= 20 && data.starts(with: Data("glTF".utf8)) &&
                data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian == 2 &&
                    $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian == data.count }
        case .stl:
            valid = data.count > 84 && data.withUnsafeBytes { buffer in
                let count = Int(buffer.loadUnaligned(fromByteOffset: 80, as: UInt32.self).littleEndian)
                return count > 0 && 84 + count * 50 == data.count
            }
        case .dxf:
            let body = String(decoding: data, as: UTF8.self)
            valid = body.contains("\nENTITIES\n") && body.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("EOF")
        case .obj:
            let body = String(decoding: data, as: UTF8.self)
            valid = body.contains("\nv ") && body.contains("\nf ")
        case .step, .ifc:
            let head = String(decoding: data.prefix(4096), as: UTF8.self).uppercased()
            let tail = String(decoding: data.suffix(256), as: UTF8.self).uppercased()
            valid = head.contains("ISO-10303-21;") && head.contains("FILE_SCHEMA") && tail.contains("END-ISO-10303-21;") &&
                (format != .ifc || head.contains("IFC4"))
        }
        guard valid else { throw CADBuildingError.invalid("The writer returned an invalid " + format.rawValue.uppercased() + " file.") }
    }
}

nonisolated extension CADBuildingExportSelection {
    /// The on-device web-ifc writer already reopens its file. Also tie the bytes
    /// returned by the host callback to this request's exact products and floors.
    func verifyBuildingIFC(_ data: Data) throws {
        let types: [CADBuildingElement.Kind: String] = [.wall:"IFCWALL", .slab:"IFCSLAB", .roof:"IFCROOF",
            .stair:"IFCSTAIR", .column:"IFCCOLUMN", .beam:"IFCBEAM", .door:"IFCDOOR", .window:"IFCWINDOW",
            .space:"IFCSPACE", .pipe:"IFCPIPESEGMENT", .duct:"IFCDUCTSEGMENT"]
        var identified = Set(types.values)
        identified.insert("IFCBUILDINGSTOREY")
        var required = Set(storeys.map { "IFCBUILDINGSTOREY/" + Self.ifcGlobalID($0.id) })
        for element in elements { required.insert(types[element.kind]! + "/" + Self.ifcGlobalID(element.id)) }
        let bad = CADBuildingError.invalid("The IFC file does not contain exactly the selected floors, products and body meshes.")
        guard !required.isEmpty, !data.isEmpty, data.count <= 128 * 1024 * 1024 else { throw bad }
        var meshes = 0
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let bytes = buffer.bindMemory(to: UInt8.self)
            let end = bytes.count
            var i = 0
            func skipSpace() { while i < end, bytes[i] <= 32 { i += 1 } }
            while i < end {
                let character = bytes[i]
                i += 1
                if character == 39 {
                    // Strings can contain a doubled quote and text resembling a STEP record.
                    while i < end {
                        let next = bytes[i]; i += 1
                        if next == 39 { if i < end, bytes[i] == 39 { i += 1 } else { break } }
                    }
                    continue
                }
                if character == 47, i < end, bytes[i] == 42 {
                    i += 1
                    while i + 1 < end, !(bytes[i] == 42 && bytes[i + 1] == 47) { i += 1 }
                    i = min(end, i + 2)
                    continue
                }
                guard character == 35 else { continue }
                let number = i
                while i < end, (48...57).contains(bytes[i]) { i += 1 }
                guard i > number else { continue }
                skipSpace()
                guard i < end, bytes[i] == 61 else { continue }
                i += 1; skipSpace()
                let begin = i
                while i < end, (65...90).contains(bytes[i]) || (48...57).contains(bytes[i]) { i += 1 }
                guard i > begin, i - begin <= 64 else { continue }
                let type = String(decoding: bytes[begin..<i], as: UTF8.self)
                if type == "IFCTRIANGULATEDFACESET" { meshes += 1; continue }
                guard identified.contains(type) else { continue }
                skipSpace()
                guard i < end, bytes[i] == 40 else { throw bad }
                i += 1; skipSpace()
                guard i + 23 < end, bytes[i] == 39, bytes[i + 23] == 39 else { throw bad }
                let id = String(decoding: bytes[(i + 1)..<(i + 23)], as: UTF8.self)
                guard required.remove(type + "/" + id) != nil else { throw bad }
                i += 24
            }
        }
        guard required.isEmpty, meshes == bodyIDs.count else { throw bad }
    }

    private static func ifcGlobalID(_ id: UUID) -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_$".utf8)
        var bits = 4, pending = 0, result: [UInt8] = []
        withUnsafeBytes(of: id.uuid) { uuid in
            for byte in uuid {
                pending = pending << 8 | Int(byte)
                bits += 8
                while bits >= 6 { bits -= 6; result.append(alphabet[(pending >> bits) & 63]) }
                pending &= (1 << bits) - 1
            }
        }
        return String(decoding: result, as: UTF8.self)
    }
}
#endif
