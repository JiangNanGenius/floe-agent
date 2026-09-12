import AVFoundation
import Foundation

struct VideoAudioExtractionService {

    // MARK: - Public Properties

    struct Dependencies {

        let makeExportSession: (AVAsset, String) -> AVAssetExportSession?
        let removeFile: (URL) -> Void

        init(
            makeExportSession: @escaping (AVAsset, String) -> AVAssetExportSession? = { asset, presetName in
                AVAssetExportSession(asset: asset, presetName: presetName)
            },
            removeFile: @escaping (URL) -> Void = { url in
                FileManager.default.removeIfExists(for: url)
            }
        ) {
            self.makeExportSession = makeExportSession
            self.removeFile = removeFile
        }

    }

    enum ExtractionError: Error, Equatable, LocalizedError, Sendable {
        case invalidVideoSource
        case audioTrackNotFound
        case unableToCreateExportSession
        case exportFailed(message: String)

        var errorDescription: String? {
            switch self {
            case .invalidVideoSource:
                VideoEditorStrings.extractionInvalidVideoSource
            case .audioTrackNotFound:
                VideoEditorStrings.extractionAudioTrackNotFound
            case .unableToCreateExportSession:
                VideoEditorStrings.extractionUnableToCreateSession
            case .exportFailed(let message):
                message
            }
        }
    }

    // MARK: - Private Properties

    private let dependencies: Dependencies

    // MARK: - Initializer

    init(_ dependencies: Dependencies = .init()) {
        self.dependencies = dependencies
    }

    // MARK: - Public Methods

    func extractAudio(from videoURL: URL) async throws -> URL {
        guard videoURL.isFileURL else {
            throw ExtractionError.invalidVideoSource
        }

        let asset = AVURLAsset(url: videoURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard !audioTracks.isEmpty else {
            throw ExtractionError.audioTrackNotFound
        }

        let outputURL = Self.makeTemporaryAudioURL()
        dependencies.removeFile(outputURL)

        guard
            let exportSession = dependencies.makeExportSession(
                asset,
                AVAssetExportPresetAppleM4A
            )
        else {
            throw ExtractionError.unableToCreateExportSession
        }

        exportSession.shouldOptimizeForNetworkUse = false

        do {
            try await exportSession.export(to: outputURL, as: .m4a)
            return outputURL
        } catch is CancellationError {
            dependencies.removeFile(outputURL)
            throw CancellationError()
        } catch {
            dependencies.removeFile(outputURL)
            throw ExtractionError.exportFailed(message: error.localizedDescription)
        }
    }

    func removeExtractedAudioIfNeeded(at url: URL) {
        dependencies.removeFile(url)
    }

    // MARK: - Private Methods

    private static func makeTemporaryAudioURL() -> URL {
        URL.temporaryDirectory.appending(
            path: "VideoEditorKit-Transcription-\(UUID().uuidString).m4a"
        )
    }

}
