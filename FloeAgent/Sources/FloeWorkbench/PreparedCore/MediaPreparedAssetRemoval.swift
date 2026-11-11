// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Active document references only. Journal snapshots deliberately do not count:
/// removing a table entry never deletes its backing file or historical bytes.
public struct MediaPreparedAssetUse: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable { case source, layer, clip, compound, colorReference, unknownContent }
    public let kind: Kind
    public let objectID: UUID
    public let name: String
    public let isLocked: Bool
}

public enum MediaPreparedAssetRemovalError: Error, Sendable, Equatable, LocalizedError {
    case inUse([MediaPreparedAssetUse])
    public var errorDescription: String? {
        switch self {
        case .inUse(let uses):
            return "This asset is still used by " + uses.prefix(6).map { "\($0.kind.rawValue): \($0.name)" }.joined(separator: "; ") + ". Remove its uses first."
        }
    }
}

public enum MediaPreparedAssets {
    /// Active, undo, redo and recovery sources. Logical removal does not make
    /// a journal's original bytes disposable.
    public static func retainedAssets(in project: MediaProject) -> [MediaAssetReference] {
        var result = project.assets
        func appendDocument(_ document: MediaPreparedDocument) {
            result.append(contentsOf: document.assets)
            for compound in document.trackGraph.tracks.flatMap(\.clips).compactMap(\.compound) {
                result.append(contentsOf: compound.source.assets)
                result.append(compound.proxy.video)
                if let audio = compound.proxy.audio { result.append(audio) }
            }
        }
        if let document = project.prepared { appendDocument(document) }
        for entry in project.preparedJournal?.entries ?? [] {
            for change in entry.changes + (entry.redoChanges ?? []) {
                for state in [change.before, change.after].compactMap({ $0 }) {
                    switch state {
                    case .asset(let asset): result.append(asset.reference)
                    case .clip(_, let clip):
                        if let compound = clip.compound {
                            appendDocument(compound.source); result.append(compound.proxy.video)
                            if let audio = compound.proxy.audio { result.append(audio) }
                        }
                    default: break
                    }
                }
            }
        }
        return result
    }

    public static func references(to assetID: UUID, in document: MediaPreparedDocument) -> [MediaPreparedAssetUse] {
        var uses: [MediaPreparedAssetUse] = []
        func add(_ kind: MediaPreparedAssetUse.Kind, _ id: UUID, _ name: String, locked: Bool = false) {
            uses.append(.init(kind: kind, objectID: id, name: name, isLocked: locked))
        }
        if document.sourceAssetID == assetID { add(.source, document.id, document.name) }
        for layer in document.layers {
            if case .raster(let raster) = layer.content, case .asset(let id) = raster.source, id == assetID {
                add(.layer, layer.id, layer.name, locked: layer.isLocked)
            }
        }
        for track in document.trackGraph.tracks {
            for clip in track.clips {
                if clip.assetID == assetID { add(.clip, clip.id, track.name, locked: track.isLocked) }
                if clip.videoGrade?.colorMatch?.reference.assetID == assetID {
                    add(.colorReference, clip.id, track.name, locked: track.isLocked)
                }
                if let compound = clip.compound,
                   compound.source.asset(assetID) != nil || compound.proxy.video.id == assetID || compound.proxy.audio?.id == assetID || compound.outerTemplates.contains(where: { $0.assetID == assetID }) {
                    // The retained source table is part of the editable compound
                    // contract even when an individual inner clip no longer uses it.
                    add(.compound, clip.id, compound.name, locked: track.isLocked)
                }
            }
        }
        if !document.unknownOperations.isEmpty {
            // Opaque future operations cannot prove that an asset is unused.
            add(.unknownContent, document.id, document.name)
        }
        return uses
    }

    public static func removal(assetID: UUID, in document: MediaPreparedDocument) throws -> MediaPreparedOperation {
        guard let asset = document.asset(assetID) else { throw MediaPreparedCoreError.unknownObject(.init(kind: .asset, id: assetID)) }
        let uses = references(to: assetID, in: document)
        guard uses.isEmpty else { throw MediaPreparedAssetRemovalError.inUse(uses) }
        return .init(action: .removeAsset(expected: asset, expectedRevision: document.assetRevisions?[assetID] ?? 0))
    }
}
