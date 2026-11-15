import Foundation
import FloeChemistryCore
import FloeMoleculePreviewNative

public enum ChemistryPreviewOrigin: String, Sendable { case original, generated, cached }

public struct ChemistryMoleculePreview: Sendable {
    public let origin: ChemistryPreviewOrigin
    public let key: ChemistryPreviewKey
    public let cjson: String
    public let molblock: String?
    public let atomCount: Int
    public let bondCount: Int
    public let optimizationStatus: String?
}

public enum ChemistryPreviewError: Error, Equatable, Sendable {
    case emptyDrawing, unsupported, changed, invalidMolecule, tooLarge, timedOut, failed
}

extension ChemistryService {
    public func moleculePreview(_ projectID: UUID, objectID: UUID, expectedObjectRevision: UInt64,
                                options: MoleculePreviewOptions = .init(),
                                convertDrawing: (@Sendable (String) async throws -> String)? = nil) async throws -> ChemistryMoleculePreview {
        try await makeMoleculePreview(projectID, objectID: objectID, expectedObjectRevision: expectedObjectRevision,
            options: options, convertDrawing: convertDrawing) { source, format, options in
            try await MoleculePreviewNative.generate(input: source, format: format, options: options)
        }
    }

    func makeMoleculePreview(_ projectID: UUID, objectID: UUID, expectedObjectRevision: UInt64,
                             options: MoleculePreviewOptions = .init(), convertDrawing: (@Sendable (String) async throws -> String)? = nil,
                             generate: @Sendable (String, MoleculePreviewFormat, MoleculePreviewOptions) async throws -> MoleculePreviewResult) async throws -> ChemistryMoleculePreview {
        try Task.checkCancellation()
        try await access(projectID, .read)
        let project = try await store.load(projectID)
        guard let original = project.objects.first(where: { $0.id == objectID }),
              original.revision == expectedObjectRevision else { throw ChemistryPreviewError.changed }
        guard original.kind == .molecule else { throw ChemistryPreviewError.unsupported }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        struct Parameters: Encodable { let method: String; let options: MoleculePreviewOptions }
        let parameters = String(decoding: try encoder.encode(Parameters(method: "ETKDGv3", options: options)), as: UTF8.self)
        let key = try ChemistryPreviewKey(projectID: projectID, object: original, engine: MoleculePreviewNative.version, parameters: parameters)
        var object = original
        let format = object.format.lowercased()
        if ["mol", "sdf", "sd"].contains(format), object.source.contains("$$$$") {
            object.source = try singleMoleculeRecord(object.source)
        }
        let graphOnly = ["smi", "smiles", "ket"].contains(format)
        if !graphOnly, object.facts?["preparationRequired"] == .bool(true) {
            object.facts = try await NativeChemistryBackend().evaluate(.init(operation: "parse", format: format, data: object.source))
        }
        if !graphOnly, !object.requires3DPreparation,
           let cjson = object.facts?["cjson"]?.string ?? (format == "cjson" ? object.source : nil),
           let counts = previewGeometry(cjson) {
            try await access(projectID, .read)
            try await store.checkPreviewSource(key)
            return .init(origin: .original, key: key, cjson: cjson, molblock: nil,
                         atomCount: counts.atoms, bondCount: counts.bonds, optimizationStatus: nil)
        }
        if let saved = try await store.cachedMoleculePreview(key), let counts = previewGeometry(saved.cjson) {
            try Task.checkCancellation()
            return .init(origin: .cached, key: key, cjson: saved.cjson, molblock: saved.molblock,
                         atomCount: counts.atoms, bondCount: counts.bonds, optimizationStatus: saved.optimizationStatus)
        }
        let input = try await previewInput(object, convertDrawing: convertDrawing)
        try Task.checkCancellation()
        let output: MoleculePreviewResult
        do { output = try await generate(input.source, input.format, options) }
        catch let error as MoleculePreviewError {
            switch error.code {
            case "cancelled": throw CancellationError()
            case "timeout": throw ChemistryPreviewError.timedOut
            case "atomLimit": throw ChemistryPreviewError.tooLarge
            case "invalidInput" where input.source.utf8.count > 256 * 1024: throw ChemistryPreviewError.tooLarge
            case "invalidMolecule", "invalidInput", "unsupportedMolecule", "multipleFragments", "stereoMismatch": throw ChemistryPreviewError.invalidMolecule
            default: throw ChemistryPreviewError.failed
            }
        }
        try Task.checkCancellation()
        guard let counts = previewGeometry(output.cjson), counts.atoms == output.atomCount, counts.bonds == output.bondCount else {
            throw ChemistryPreviewError.failed
        }
        let saved = try ChemistryCachedMoleculePreview(key: key, cjson: output.cjson, molblock: output.molblock,
                                                      optimizationStatus: output.optimizationStatus)
        try await access(projectID, .edit)
        try await store.saveMoleculePreview(saved)
        try Task.checkCancellation()
        return .init(origin: .generated, key: key, cjson: saved.cjson, molblock: saved.molblock,
                     atomCount: counts.atoms, bondCount: counts.bonds, optimizationStatus: saved.optimizationStatus)
    }

    private func previewInput(_ object: ChemicalObject, convertDrawing: (@Sendable (String) async throws -> String)?) async throws -> (source: String, format: MoleculePreviewFormat) {
        switch object.format.lowercased() {
        case "smi", "smiles": return (object.source, .smiles)
        case "mol", "sdf", "sd": return (object.source, .mol)
        case "ket":
            guard !(try ChemicalDrawing2D(object.source)).atoms.isEmpty else { throw ChemistryPreviewError.emptyDrawing }
            if let smiles = object.sketchSMILES, !smiles.isEmpty { return (smiles, .smiles) }
            guard let convertDrawing else { throw ChemistryPreviewError.unsupported }
            return (try await convertDrawing(object.source), .mol)
        case "cjson":
            let result = try await NativeChemistryBackend().evaluate(.init(operation: "export", format: object.format,
                data: object.source, options: .object(["outputFormat": .string("mol")])))
            guard let mol = result["text"]?.string, !mol.isEmpty else { throw ChemistryPreviewError.unsupported }
            return (mol, .mol)
        default: throw ChemistryPreviewError.unsupported
        }
    }
}

private func singleMoleculeRecord(_ source: String) throws -> String {
    guard let delimiter = source.range(of: #"(?m)^\$\$\$\$[ \t]*\r?$"#, options: .regularExpression) else { return source }
    guard source[delimiter.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ChemistryPreviewError.unsupported
    }
    return String(source[..<delimiter.lowerBound])
}

private func previewGeometry(_ source: String) -> (atoms: Int, bonds: Int)? {
    struct Structure: Decodable {
        struct Atoms: Decodable {
            struct Elements: Decodable { let number: [Int] }
            struct Coordinates: Decodable { let xyz: [Double]; enum CodingKeys: String, CodingKey { case xyz = "3d" } }
            let elements: Elements
            let coords: Coordinates
        }
        struct Bonds: Decodable {
            struct Connections: Decodable { let index: [Int] }
            let connections: Connections?
        }
        let atoms: Atoms
        let bonds: Bonds?
    }
    guard source.utf8.count <= 16 * 1024 * 1024,
          let structure = try? JSONDecoder().decode(Structure.self, from: Data(source.utf8)) else { return nil }
    let numbers = structure.atoms.elements.number, xyz = structure.atoms.coords.xyz
    guard !numbers.isEmpty, numbers.count <= 100_000, numbers.allSatisfy({ (1...118).contains($0) }),
          xyz.count == numbers.count * 3, xyz.allSatisfy(\.isFinite) else { return nil }
    if numbers.count > 1 && !stride(from: 3, to: xyz.count, by: 3).contains(where: {
        abs(xyz[$0]-xyz[0]) + abs(xyz[$0+1]-xyz[1]) + abs(xyz[$0+2]-xyz[2]) >= 1e-6
    }) { return nil }
    let bonds = structure.bonds?.connections?.index ?? []
    guard bonds.count.isMultiple(of: 2), bonds.allSatisfy({ numbers.indices.contains($0) }) else { return nil }
    return (numbers.count, bonds.count / 2)
}
