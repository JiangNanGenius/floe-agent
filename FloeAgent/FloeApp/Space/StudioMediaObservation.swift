// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeMusicCore
import FloeWorkbench

nonisolated struct StudioImageRegionObservation: Codable, Sendable {
    let shapeCount: Int
    let pointCount: Int
    /// Actual point bounds [minX,minY,maxX,maxY] in normalized canvas coordinates.
    let pointBounds: [Double]?
    let inverted: Bool
    let feather: Double
    /// Full native shape data is hashed, never silently replaced by its bounds.
    let contentSHA256: String
}
nonisolated struct StudioMediaSelectionObservation: Codable, Sendable {
    let projectID: UUID
    let revision: Int64
    let selectionFence: String
    let selectedLayerID: UUID?
    let selectedLayerIDs: [UUID]
    let selectedLayerCount: Int
    let selectedLayerIDsTruncated: Bool
    let selectedTrackID: UUID?
    let selectedClipID: UUID?
    let playheadSeconds: Double
    let imageRegion: StudioImageRegionObservation?
}
nonisolated struct StudioMusicSelectionObservation: Codable, Sendable {
    let projectID: UUID
    let revision: Int64
    let selectionFence: String
    let selectedTrackID: MusicTrackID?
    let selectedClipID: MusicClipID?
    let playheadSeconds: Double
    let looping: Bool
}
nonisolated struct StudioSelectionObservation: Encodable, Sendable {
    /// Existing service state, not a claim that an editor is visible/on-screen.
    let status: String
    let media: StudioMediaSelectionObservation?
    let music: StudioMusicSelectionObservation?
}

@MainActor enum StudioMediaObservation {
    /// Does not open an editor or synthesize a default selection for a read.
    static func selection(record: PersonalContentRecord, directory: URL) throws -> StudioSelectionObservation? {
        switch record.kind {
        case .image, .drawing, .video:
            guard let session = try MediaV2Session.existingForAudioObservation(id: record.id,
                root: directory.appendingPathComponent("Media")) else {
                return .init(status: "noExistingNativeSession", media: nil, music: nil)
            }
            return .init(status: "existingNativeSession", media: try media(session), music: nil)
        case .music:
            guard let session = try MusicProjectSession.existingForAudioObservation(id: record.id,
                directory: directory.appendingPathComponent("Music")) else {
                return .init(status: "noExistingNativeSession", media: nil, music: nil)
            }
            return .init(status: "existingNativeSession", media: nil, music: try music(session))
        default: return nil
        }
    }

    static func media(_ session: MediaV2Session) throws -> StudioMediaSelectionObservation {
        let document = session.document
        let layerID = session.selectedLayerID.flatMap { document.layer($0)?.id }
        let layers = session.selectedLayerIDs.filter { document.layer($0) != nil }.sorted { $0.uuidString < $1.uuidString }
        let trackID = session.selectedTrackID.flatMap { document.trackGraph.track($0)?.id }
        let clipID = session.selectedClipID.flatMap { id in
            document.trackGraph.clip(id: id).flatMap { $0.track.id == trackID ? id : nil }
        }
        guard session.playhead.isFinite else { throw PersonalContentError.changedDocument }
        let region: StudioImageRegionObservation?
        if let native = session.selection {
            let bytes = try StudioToolOutput.data(native)
            guard bytes.count <= 2 * 1_024 * 1_024 else { throw FloeError.validationFailed("Native selection exceeds observation budget") }
            let points = native.shapes.flatMap(\.points)
            guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), native.feather.isFinite else { throw PersonalContentError.changedDocument }
            let bounds: [Double]? = points.isEmpty ? nil : [points.map(\.x).min()!, points.map(\.y).min()!, points.map(\.x).max()!, points.map(\.y).max()!]
            region = .init(shapeCount: native.shapes.count, pointCount: points.count, pointBounds: bounds,
                inverted: native.inverted, feather: native.feather, contentSHA256: StudioToolOutput.hash(bytes))
        } else { region = nil }
        // Bind ALL selected IDs, even when the bounded display list is truncated.
        struct Identity: Encodable {
            let epoch: UUID; let revision: Int64; let layer: UUID?; let layers: [UUID]
            let track: UUID?; let clip: UUID?; let playhead: Double; let region: StudioImageRegionObservation?
        }
        let token = StudioToolOutput.hash(try StudioToolOutput.data(Identity(epoch: session.observationIdentity,
            revision: document.revision, layer: layerID, layers: layers, track: trackID, clip: clipID, playhead: session.playhead, region: region)))
        return .init(projectID: session.id, revision: document.revision, selectionFence: token, selectedLayerID: layerID,
            selectedLayerIDs: Array(layers.prefix(256)), selectedLayerCount: layers.count, selectedLayerIDsTruncated: layers.count > 256,
            selectedTrackID: trackID, selectedClipID: clipID, playheadSeconds: session.playhead, imageRegion: region)
    }

    static func music(_ session: MusicProjectSession) throws -> StudioMusicSelectionObservation {
        let document = session.document
        let track = session.selectedTrack.flatMap { id in document.tracks.first { $0.id == id } }
        let clip = session.selectedClip.flatMap { id in track?.clips.first { $0.id == id }?.id }
        guard session.playheadSeconds.isFinite else { throw PersonalContentError.changedDocument }
        struct Identity: Encodable {
            let epoch: UUID; let revision: Int64; let track: MusicTrackID?; let clip: MusicClipID?
            let playhead: Double; let looping: Bool
        }
        let token = StudioToolOutput.hash(try StudioToolOutput.data(Identity(epoch: session.observationIdentity,
            revision: document.revision, track: track?.id, clip: clip, playhead: session.playheadSeconds, looping: session.looping)))
        return .init(projectID: session.id, revision: document.revision, selectionFence: token, selectedTrackID: track?.id,
            selectedClipID: clip, playheadSeconds: session.playheadSeconds, looping: session.looping)
    }
}
#endif
