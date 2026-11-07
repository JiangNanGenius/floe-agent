// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum BiologyAssetKind: String, Codable, CaseIterable, Sendable {
    case sequence, proteinStructure, microscopyImage, expressionMatrix, biochemicalNetwork, externalDataset
}
public struct SequenceAnnotation: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    /// Zero-based, half-open coordinates; unsupported original features remain in originalData.
    public var start: Int
    public var end: Int
    public var strand: Int = 1
    public var qualifiers: [String: [String]] = [:]
    public init(name: String, start: Int, end: Int, strand: Int = 1) { self.name = name; self.start = start; self.end = end; self.strand = strand }
}
public struct SequenceRecord: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var sequence: String
    public var alphabet: String
    public var quality: String?
    public var annotations: [SequenceAnnotation] = []
    public init(name: String, sequence: String, alphabet: String = "dna") { self.name = name; self.sequence = sequence; self.alphabet = alphabet }
}
public struct StructureAtom: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var serial: Int
    public var name: String
    public var element: String
    public var chain: String
    public var residue: String
    public var residueNumber: Int
    public var insertionCode: String
    public var model: Int
    public var x: Double
    public var y: Double
    public var z: Double
    public var occupancy: Double
    public var hetero: Bool
    public init(id: Int, serial: Int, name: String, element: String, chain: String, residue: String, residueNumber: Int, insertionCode: String = "", model: Int = 1, x: Double, y: Double, z: Double, occupancy: Double = 1, hetero: Bool = false) {
        self.id = id; self.serial = serial; self.name = name; self.element = element; self.chain = chain; self.residue = residue; self.residueNumber = residueNumber; self.insertionCode = insertionCode; self.model = model
        self.x = x; self.y = y; self.z = z; self.occupancy = occupancy; self.hetero = hetero
    }
    public var residueID: String { "\(model):\(chain):\(residueNumber):\(insertionCode)" }
}
public struct ProteinStructure: Codable, Sendable, Equatable {
    public var atoms: [StructureAtom]
    public var title: String
    public init(atoms: [StructureAtom], title: String = "") { self.atoms = atoms; self.title = title }
}
public struct MicroscopyImage: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var channels: Int = 1
    public var slices: Int = 1
    public var frames: Int = 1
    public var bitDepth: Int = 16
    /// TZCYX order, with x varying fastest. Display normalization never changes these samples.
    public var samples: [Double]
    public var pixelSizeX: Double?
    public var pixelSizeY: Double?
    public var calibrationUnit: String = "µm"
    public init(width: Int, height: Int, samples: [Double]) { self.width = width; self.height = height; self.samples = samples }
    public func validate() throws {
        guard width > 0, height > 0, channels > 0, slices > 0, frames > 0,
              width <= 16_384, height <= 16_384, channels <= 32, slices <= 512, frames <= 512,
              Double(width) * Double(height) * Double(channels) * Double(slices) * Double(frames) <= 4_194_304,
              samples.count == width * height * channels * slices * frames,
              [8, 16, 32, 64].contains(bitDepth), samples.allSatisfy(\.isFinite),
              pixelSizeX.map({ $0.isFinite && $0 > 0 }) ?? true,
              pixelSizeY.map({ $0.isFinite && $0 > 0 }) ?? true,
              (pixelSizeX == nil) == (pixelSizeY == nil) else { throw BiologyError.invalid("Invalid image dimensions, samples or calibration.") }
    }
    public func plane(channel: Int = 0, slice: Int = 0, frame: Int = 0) throws -> [Double] {
        try validate()
        guard (0..<channels).contains(channel), (0..<slices).contains(slice), (0..<frames).contains(frame) else { throw BiologyError.invalid("Image plane is outside the dataset.") }
        let offset = ((frame * slices + slice) * channels + channel) * width * height
        return Array(samples[offset..<(offset + width * height)])
    }
}
public struct ExpressionMatrix: Codable, Sendable, Equatable {
    public var geneIDs: [String]
    public var cellIDs: [String]
    /// Genes are rows; cells are columns.
    public var values: [Double]
    public init(geneIDs: [String], cellIDs: [String], values: [Double]) { self.geneIDs = geneIDs; self.cellIDs = cellIDs; self.values = values }
    public func validate(counts: Bool = true) throws {
        guard !geneIDs.isEmpty, !cellIDs.isEmpty, geneIDs.count <= 100_000, cellIDs.count <= 100_000,
              Double(geneIDs.count) * Double(cellIDs.count) <= 2_000_000,
              values.count == geneIDs.count * cellIDs.count,
              Set(geneIDs).count == geneIDs.count, Set(cellIDs).count == cellIDs.count,
              (geneIDs + cellIDs).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              values.allSatisfy({ $0.isFinite && (!counts || $0 >= 0) }) else { throw BiologyError.invalid("Invalid matrix dimensions, identifiers or values.") }
    }
}
public struct NetworkSpecies: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var initialAmount: Double
    public init(id: String, initialAmount: Double) { self.id = id; self.initialAmount = initialAmount }
}
public struct NetworkReaction: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var reactants: [String: Int]
    public var products: [String: Int]
    public var rateConstant: Double
    public init(id: String, reactants: [String: Int], products: [String: Int], rateConstant: Double) { self.id = id; self.reactants = reactants; self.products = products; self.rateConstant = rateConstant }
}
public struct BiochemicalNetwork: Codable, Sendable, Equatable {
    public var species: [NetworkSpecies]
    public var reactions: [NetworkReaction]
    public var timeUnit: String = "s"
    public var amountUnit: String = "arbitrary amount"
    public init(species: [NetworkSpecies], reactions: [NetworkReaction]) { self.species = species; self.reactions = reactions }
    public func validate() throws {
        let ids = Set(species.map(\.id))
        guard !species.isEmpty, species.count <= 128, reactions.count <= 512, ids.count == species.count,
              Set(reactions.map(\.id)).count == reactions.count,
              species.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 128 && $0.initialAmount.isFinite && $0.initialAmount >= 0 }),
              reactions.allSatisfy({ r in r.rateConstant.isFinite && r.rateConstant >= 0 && !r.id.isEmpty &&
                  !r.reactants.isEmpty && r.reactants.allSatisfy({ ids.contains($0.key) && (1...8).contains($0.value) }) &&
                  r.products.allSatisfy({ ids.contains($0.key) && (1...8).contains($0.value) }) }) else { throw BiologyError.invalid("Invalid network species, stoichiometry or rate constants.") }
    }
}
public enum BiologyAssetPayload: Codable, Sendable, Equatable {
    case sequence([SequenceRecord]), proteinStructure(ProteinStructure), microscopyImage(MicroscopyImage)
    case expressionMatrix(ExpressionMatrix), biochemicalNetwork(BiochemicalNetwork), externalDataset(String)
    public var kind: BiologyAssetKind {
        switch self {
        case .sequence: .sequence
        case .proteinStructure: .proteinStructure
        case .microscopyImage: .microscopyImage
        case .expressionMatrix: .expressionMatrix
        case .biochemicalNetwork: .biochemicalNetwork
        case .externalDataset: .externalDataset
        }
    }
}
public struct BiologyAsset: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var title: String
    public var revision: UInt64 = 1
    public var payload: BiologyAssetPayload
    public let originalData: Data
    public let originalFormat: String
    /// Opaque host-owned file identity for datasets larger than inline storage.
    /// This metadata never grants access; the host revalidates project/task scope.
    public var fileReference: BiologyFileReference?
    public var warnings: [String] = []
    public var provenance: [String: String] = [:]
    public var kind: BiologyAssetKind { payload.kind }
    public init(title: String, payload: BiologyAssetPayload, originalData: Data, originalFormat: String, fileReference: BiologyFileReference? = nil) { self.title = title; self.payload = payload; self.originalData = originalData; self.originalFormat = originalFormat; self.fileReference=fileReference }
}
public struct BiologyFileReference: Codable, Sendable, Equatable, Identifiable {
    public var id:UUID
    public var projectID:UUID
    public var fileName:String
    public var byteCount:UInt64
    public var sha256:String
    public var environmentID:String
    public init(id:UUID,projectID:UUID,fileName:String,byteCount:UInt64,sha256:String,environmentID:String) {
        self.id=id;self.projectID=projectID;self.fileName=fileName;self.byteCount=byteCount;self.sha256=sha256;self.environmentID=environmentID
    }
    public func validate() throws {
        guard !fileName.isEmpty,fileName.utf8.count<=4096,byteCount>0,byteCount<=512*1024*1024*1024,
              sha256.count==64,sha256.allSatisfy({"0123456789abcdef".contains($0)}),
              !environmentID.isEmpty,environmentID.utf8.count<=4096 else {throw BiologyError.invalid("Invalid referenced dataset identity.")}
    }
}
public struct BiologyAnalysisResult: Codable, Sendable, Equatable {
    public var summary: String
    public var metrics: [String: Double] = [:]
    public var columns: [String] = []
    public var rows: [[Double]] = []
    public var rowNames: [String] = []
    public var labels: [Int] = []
    public var text: String = ""
    public var details: [String: String] = [:]
    public init(summary: String) { self.summary = summary }
    public func csv() -> String {
        func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return ([(["item"] + columns).map(quote).joined(separator: ",")] + rows.enumerated().map { i, row in
            quote(rowNames.indices.contains(i) ? rowNames[i] : String(i + 1)) + "," + row.map { String($0) }.joined(separator: ",")
        }).joined(separator: "\n") + "\n"
    }
}
public enum BiologyRunStatus: String, Codable, Sendable { case queued, running, cancelling, succeeded, failed, cancelled, interrupted }
public struct BiologyExecutionOwner: Codable, Sendable, Hashable {
    public var taskID: UUID
    public var hostRunID: UUID
    public init(taskID: UUID, hostRunID: UUID) { self.taskID = taskID; self.hostRunID = hostRunID }
}
public struct BiologyRun: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var assetID: UUID
    public var assetRevision: UInt64
    public var inputDigest: String
    public var method: String
    public var options: JSONValue
    public var environmentID: String
    public var engineVersion: String
    public var owner: BiologyExecutionOwner?
    public var status: BiologyRunStatus = .queued
    public var createdAt = Date()
    public var result: BiologyAnalysisResult?
    public var error: String?
    public var workerStopUnconfirmed:Bool?
    public var isActive: Bool {workerStopUnconfirmed==true || [.queued, .running, .cancelling].contains(status)}
    public init(asset: BiologyAsset, inputDigest: String, method: String, options: JSONValue, environmentID: String, engineVersion: String, owner: BiologyExecutionOwner?) {
        assetID = asset.id; assetRevision = asset.revision; self.inputDigest = inputDigest; self.method = method; self.options = options; self.environmentID = environmentID; self.engineVersion = engineVersion; self.owner = owner
    }
}
public struct BiologyProject: Codable, Sendable, Equatable, Identifiable {
    public var schemaVersion = 1
    public var id = UUID()
    public var title: String
    public var revision: UInt64 = 0
    public var modifiedAt = Date()
    public var assets: [BiologyAsset] = []
    public var runs: [BiologyRun] = []
    public var notes = ""
    public var chemistryLinks: [String] = []
    public var activeAssetID:UUID?
    public var selections:[String:JSONValue]?
    public var mutationReceipts:[BiologyMutationReceipt]?
    public var deletedAt:Date?
    public var createdByOperation:BiologyMutationIdentity?
    public init(title: String) { self.title = title }
}
public struct BiologyMutationIdentity: Codable, Sendable, Equatable {
    public var owner:BiologyExecutionOwner
    public var requestID:String
    public var argumentDigest:String
    public init(owner:BiologyExecutionOwner,requestID:String,argumentDigest:String) {
        self.owner=owner;self.requestID=requestID;self.argumentDigest=argumentDigest
    }
}
public struct BiologyMutationReceipt: Codable, Sendable, Equatable {
    public var identity:BiologyMutationIdentity
    public var result:Data
    public var createdAt:Date
    public init(identity:BiologyMutationIdentity,result:Data) {self.identity=identity;self.result=result;createdAt=Date()}
}
public enum BiologyCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    public static func json<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: encode(value)) }
}
