// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CoreGraphics
import FloeBiologyCore

extension PersonalContentPreviewService {
    /// Same permanent store as BiologyAppComposition, read directly without
    /// constructing a store (its init/load create directories and a write lock).
    func savedBiology(ownerID: String, projectID: UUID, originalDirectory: URL, storeRoot: URL,
                      maximumPixelSize: Int = 640,
                      validate: @escaping @MainActor @Sendable () async throws -> Void) async throws -> PersonalContentPreviewRequest {
        try await validate()
        let prepared = try await personalPreviewOffMain {
            let bindingFile = try PersonalPreviewFile(root: originalDirectory,
                url: originalDirectory.appendingPathComponent("biology-binding.json"), maximumBytes: 4_096)
            let binding = try JSONDecoder().decode(BiologyOriginalBinding.self, from: bindingFile.data())
            guard binding.schemaVersion == 1, binding.projectID == projectID else { throw PersonalContentPreviewError.sourceChanged }
            let directory = storeRoot.appendingPathComponent(projectID.uuidString.lowercased(), isDirectory: true)
            let headFile = try PersonalPreviewFile(root: storeRoot, url: directory.appendingPathComponent("HEAD.json"), maximumBytes: 4_096)
            let head = try JSONDecoder().decode(SavedBiologyPreviewHead.self, from: headFile.data())
            guard head.revision > 0, head.digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw PersonalContentPreviewError.unavailable }
            let revision = try PersonalPreviewFile(root: storeRoot,
                url: directory.appendingPathComponent("revisions/\(head.revision).json"), maximumBytes: BiologyProjectStore.maximumProjectBytes)
            let project = try JSONDecoder().decode(BiologyProject.self, from: revision.data(expectedSHA256: head.digest))
            guard project.id == projectID, project.revision == head.revision, project.deletedAt == nil else { throw PersonalContentPreviewError.sourceChanged }
            try BiologyProjectStore.validate(project)
            // Prefer the saved active dataset when this adapter can faithfully
            // show it; otherwise identify the first supported saved dataset.
            let supported = project.assets.filter { asset in
                switch asset.payload {
                case .sequence, .proteinStructure, .microscopyImage, .expressionMatrix, .biochemicalNetwork: true
                case .externalDataset: false
                }
            }
            guard let asset = supported.first(where: { $0.id == project.activeAssetID }) ?? supported.first else { throw PersonalContentPreviewError.notPrepared }
            try headFile.validate(); try bindingFile.validate()
            return (bindingFile, headFile, revision, project.revision, asset)
        }
        try await validate()
        let asset = prepared.4
        let key = PersonalContentPreviewKey(ownerID: ownerID, objectID: asset.id.uuidString,
            revision: "\(prepared.3):\(asset.revision)",
            variant: "savedBiology:\(prepared.0.identity.token):\(prepared.1.identity.token):savedTypedV2:c0z0t0", maximumPixelSize: maximumPixelSize)
        let check: @MainActor @Sendable () async throws -> Void = {
            try await validate(); try prepared.0.validate(); try prepared.1.validate(); try prepared.2.validate()
        }
        return .init(key: key, validate: check, produce: {
            try await check()
            let result = try await personalPreviewOffMain {
                let value: PersonalContentPreviewArtifact
                switch asset.payload {
                case .sequence(let records):
                    guard let first = records.first else { throw PersonalContentPreviewError.notPrepared }
                    let prefix = Array(first.sequence.prefix(1_200)), name = String(first.name.prefix(160)).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                    let lines = stride(from: 0, to: prefix.count, by: 80).map { String(prefix[$0..<min(prefix.count, $0 + 80)]) }
                    value = .init(.text(">\(name)\n" + lines.joined(separator: "\n")), provenance: .moduleSnapshot,
                        detail: previewText("已保存序列 · 前 \(prefix.count)/\(first.sequence.count) 个字符 · \(records.count) 条序列", "Saved sequence · first \(prefix.count)/\(first.sequence.count) symbols · \(records.count) records"))
                case .proteinStructure(let structure):
                    value = try biologyPreviewStructure(structure)
                case .expressionMatrix(let matrix):
                    value = try biologyPreviewMatrix(matrix)
                case .biochemicalNetwork(let network):
                    value = try biologyPreviewNetwork(network)
                case .microscopyImage(let image):
                    let bytes = try biologyPreviewPlane(image)
                    let content = try PersonalContentPreviewProducers.image(bytes, maximumPixelSize: key.maximumPixelSize, provenance: .moduleSnapshot)
                    value = .init(content.content, provenance: .moduleSnapshot,
                        detail: previewText("已保存显微图 · C1/Z1/T1 · 按本平面最小/最大值灰阶显示", "Saved microscopy · C1/Z1/T1 · plane min/max grayscale display"))
                case .externalDataset: throw PersonalContentPreviewError.notPrepared
                }
                try prepared.0.validate(); try prepared.1.validate(); try prepared.2.validate(); try Task.checkCancellation()
                return value
            }
            try await check(); return result
        })
    }
}

private nonisolated struct SavedBiologyPreviewHead: Decodable, Sendable { let revision: UInt64; let digest: String }

/// These are bounded read-only tables over the validated native payload, not
/// an inferred structure, normalized matrix, simulated trajectory or title card.
private nonisolated func biologyPreviewStructure(_ structure: ProteinStructure) throws -> PersonalContentPreviewArtifact {
    let atoms = structure.atoms.prefix(24)
    guard !atoms.isEmpty else { throw PersonalContentPreviewError.notPrepared }
    var lines = [previewText("模型\t原子序号\t元素\t原子\t链\t残基\t残基号\t插入码\tX\tY\tZ",
                             "Model\tSerial\tElement\tAtom\tChain\tResidue\tResidue no.\tInsertion\tX\tY\tZ")]
    for atom in atoms {
        try Task.checkCancellation()
        lines.append([String(atom.model), String(atom.serial), biologyPreviewCell(atom.element), biologyPreviewCell(atom.name),
            biologyPreviewCell(atom.chain), biologyPreviewCell(atom.residue), String(atom.residueNumber), biologyPreviewCell(atom.insertionCode),
            String(atom.x), String(atom.y), String(atom.z)].joined(separator: "\t"))
    }
    return .init(.text(lines.joined(separator: "\n")), provenance: .moduleSnapshot,
        detail: previewText("已保存结构 · 前 \(atoms.count)/\(structure.atoms.count) 个原子的原始坐标 · 名称可能截短",
                            "Saved structure · raw coordinates of first \(atoms.count)/\(structure.atoms.count) atoms · names may be abbreviated"))
}

private nonisolated func biologyPreviewMatrix(_ matrix: ExpressionMatrix) throws -> PersonalContentPreviewArtifact {
    let rows = min(12, matrix.geneIDs.count), columns = min(6, matrix.cellIDs.count)
    guard rows > 0, columns > 0 else { throw PersonalContentPreviewError.notPrepared }
    var lines = [([previewText("基因 / 细胞", "Gene / cell")] + matrix.cellIDs.prefix(columns).map(biologyPreviewCell)).joined(separator: "\t")]
    for row in 0..<rows {
        try Task.checkCancellation()
        let values = (0..<columns).map { String(matrix.values[row * matrix.cellIDs.count + $0]) }
        lines.append(([biologyPreviewCell(matrix.geneIDs[row])] + values).joined(separator: "\t"))
    }
    return .init(.text(lines.joined(separator: "\n")), provenance: .moduleSnapshot,
        detail: previewText("已保存表达矩阵 · 前 \(rows)/\(matrix.geneIDs.count) 行 × \(columns)/\(matrix.cellIDs.count) 列 · 原始数值，名称可能截短",
                            "Saved expression matrix · first \(rows)/\(matrix.geneIDs.count) rows × \(columns)/\(matrix.cellIDs.count) columns · raw values, names may be abbreviated"))
}

private nonisolated func biologyPreviewNetwork(_ network: BiochemicalNetwork) throws -> PersonalContentPreviewArtifact {
    let reactions = network.reactions.prefix(12), species = network.species.prefix(12)
    guard !species.isEmpty else { throw PersonalContentPreviewError.notPrepared }
    var lines = [previewText("反应（已存计量与方向；k 为已存速率常数）", "Reactions (saved stoichiometry and direction; k is the stored rate constant)")]
    for reaction in reactions {
        try Task.checkCancellation()
        lines.append("\(biologyPreviewSymbol(reaction.id)): \(biologyPreviewReactionSide(reaction.reactants)) → \(biologyPreviewReactionSide(reaction.products)); k = \(reaction.rateConstant)")
    }
    if reactions.isEmpty { lines.append(previewText("尚无反应", "No reactions saved")) }
    lines.append("")
    lines.append(previewText("初始量", "Initial amounts") + " (\(biologyPreviewCell(network.amountUnit)))")
    for item in species {
        try Task.checkCancellation()
        lines.append("\(biologyPreviewSymbol(item.id)) = \(item.initialAmount)")
    }
    lines.append(previewText("时间单位", "Time unit") + ": \(biologyPreviewCell(network.timeUnit))")
    return .init(.text(lines.joined(separator: "\n")), provenance: .moduleSnapshot,
        detail: previewText("已保存网络 · 前 \(reactions.count)/\(network.reactions.count) 条反应和 \(species.count)/\(network.species.count) 个物种 · 每侧最多 8 个物种，名称可能截短 · 未运行模拟",
                            "Saved network · first \(reactions.count)/\(network.reactions.count) reactions and \(species.count)/\(network.species.count) species · at most 8 species per side, names may be abbreviated · no simulation"))
}

private nonisolated func biologyPreviewReactionSide(_ terms: [String: Int]) -> String {
    if terms.isEmpty { return "∅" }
    let names = terms.keys.sorted(), shown = names.prefix(8)
    var result = shown.map { id in
        let coefficient = terms[id] ?? 1
        return (coefficient == 1 ? "" : "\(coefficient) ") + biologyPreviewSymbol(id)
    }
    if shown.count < names.count { result.append("… (+\(names.count - shown.count))") }
    return result.joined(separator: " + ")
}

private nonisolated func biologyPreviewCell(_ text: String) -> String {
    String(decoding: text.utf8.prefix(96), as: UTF8.self)
        .replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
}

private nonisolated func biologyPreviewSymbol(_ text: String) -> String {
    "\"" + biologyPreviewCell(text).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// Pure display adapter over saved typed samples. It uses the same min/max
/// mapping as BiologyUI/DomainViews.displayImage; it does not segment, solve,
/// change calibration, sample an external file or alter original samples.
private nonisolated func biologyPreviewPlane(_ image: MicroscopyImage) throws -> Data {
    let pixels = try image.plane(channel: 0, slice: 0, frame: 0)
    try Task.checkCancellation()
    let low = pixels.min() ?? 0, high = pixels.max() ?? 1
    guard (high - low).isFinite else { throw PersonalContentPreviewError.unavailable }
    let span = max(high - low, 1e-12)
    var display = Data(capacity: pixels.count)
    for (index, value) in pixels.enumerated() {
        if index % 65_536 == 0 { try Task.checkCancellation() }
        let level = min(255.0, max(0.0, (value - low) / span * 255))
        guard level.isFinite else { throw PersonalContentPreviewError.unavailable }
        display.append(UInt8(level))
    }
    guard let provider = CGDataProvider(data: display as CFData),
          let rendered = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw PersonalContentPreviewError.unavailable }
    let output = try PersonalContentPreviewProducers.encode(rendered)
    guard output.count <= 8 * 1_024 * 1_024 else { throw PersonalContentPreviewError.tooLarge }
    try Task.checkCancellation(); return output
}
#endif
