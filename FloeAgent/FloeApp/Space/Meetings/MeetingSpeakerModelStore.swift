// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CryptoKit
import FloeCore
import FloeLocalModelCatalog

/// Fixed, verified native diarization pack. Downloads use the existing
/// persistent speech-transfer service and its durable settlement ledger.
/// This store owns preparation; a view disappearing cannot cancel it.
actor MeetingSpeakerModelStore {
    static let shared = MeetingSpeakerModelStore()
    static let revision = "556fc52a13327837688f02289457cded017802e9"
    static let totalBytes: Int64 = 11_243_231
    enum Status: Sendable, Equatable {
        case absent, downloading(Double), ready, failed(String), unsupported
    }
    struct Asset: Sendable {
        let path: String
        let byteCount: Int64
        let sha256: String
        var url: URL { URL(string: "https://huggingface.co/argmaxinc/speakerkit-coreml/resolve/\(MeetingSpeakerModelStore.revision)/\(path)")! }
    }
    static let assets: [Asset] = [
        .init(path: "speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc/analytics/coremldata.bin", byteCount: 243, sha256: "3e13c8f4df77ea27cbbcdd6d083c63f5e7b3f32566cc5bf223fab92d40b81b8b"),
        .init(path: "speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc/coremldata.bin", byteCount: 327, sha256: "6f6820ccf221d4cc7c107101d0ae4d716eb224e4fdffaf8f7ca36af70ae64c40"),
        .init(path: "speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc/metadata.json", byteCount: 1766, sha256: "acc86b4a4f542d8e7eaf84fc290fe72bd8629b0ffcc16e5b1a9e13d777abd9d8"),
        .init(path: "speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc/model.mil", byteCount: 8128, sha256: "209e641bf4d9c3868c9dc43ab8705094997917eb2df5f5d8c8fda09fed54b1d4"),
        .init(path: "speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc/weights/weight.bin", byteCount: 199040, sha256: "a1dbbb651a0a67fcfe5334672f459df090fa960917a6ee3a5423245a7ab92ced"),
        .init(path: "speaker_clusterer/pyannote-v4/W32A32/README.txt", byteCount: 98, sha256: "1714fe351f449b3e0d54f9b5be5219d4168fa2a56e1ab2cae509d5c38a7af915"),
        .init(path: "speaker_embedder/pyannote-v3/W8A16/README.txt", byteCount: 122, sha256: "c6ac9e9755ca881df5d0493e425a1841b398f7efdfa8c5a5175914587ee45310"),
        .init(path: "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc/analytics/coremldata.bin", byteCount: 243, sha256: "ba8405dfc9b9348ade705e052888b4bdc7fb8d079ef3ff71108a5f692d0209f2"),
        .init(path: "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc/coremldata.bin", byteCount: 370, sha256: "1597d6c037ac52436b5c2e1abc47e6c68483c19eeac75267dfb8795a78ec07c5"),
        .init(path: "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc/metadata.json", byteCount: 2367, sha256: "29ea3421161c8344f6ea95db9b472217638a869f686f2494d10e5d11f11f4cda"),
        .init(path: "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc/model.mil", byteCount: 451487, sha256: "5eee9f6aa380aef88fee604d75c5deaa23adc83c9480cb8f6dedc72803973e77"),
        .init(path: "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc/weights/weight.bin", byteCount: 6661888, sha256: "a02861969f47cf3a67e3b0d276e54b3c8bc3a6e43d40d77d1cccbd57da0e5795"),
        .init(path: "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc/analytics/coremldata.bin", byteCount: 243, sha256: "ce9bef9fb3125a5401300b5c5998c5d8f211094692cae780645d3e2757410f2c"),
        .init(path: "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc/coremldata.bin", byteCount: 330, sha256: "b4ebd0b9ce5a84768672663aff426eb19f9648d4b9f74286f0e19fc753ad76ba"),
        .init(path: "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc/metadata.json", byteCount: 1979, sha256: "789f81c17dc04d469611d253684e534565fb4a008e54c722b925f1608bf87fce"),
        .init(path: "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc/model.mil", byteCount: 14224, sha256: "42e552ebd7efb12ea813eceb474018dd0f46168e84ad3a1c54945bfc47be7a82"),
        .init(path: "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc/weights/weight.bin", byteCount: 2181696, sha256: "5f2c284bd22f1f7ab76901c1c6e57f82d4ebbf057fa0b924aad057f124f77a89"),
        .init(path: "speaker_segmenter/pyannote-v3/W8A16/README.txt", byteCount: 105, sha256: "b84da4b3cdd7619435f45833d88cad15530a93fb99ef56ee6c4786d7f4664016"),
        .init(path: "speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc/analytics/coremldata.bin", byteCount: 243, sha256: "40637aa0cb2a073bc303c7ca9ee79da35fa81d2cad1ead180e93b134005b95de"),
        .init(path: "speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc/coremldata.bin", byteCount: 497, sha256: "6c356ed983b2a3332ce51299ca0f9747a35cb6c2a67b0ac24c69dbef3f989634"),
        .init(path: "speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc/metadata.json", byteCount: 3757, sha256: "2fd6aaf6beb17b3758f5d0c5b2cf5feeacb0cc0c9267dbcd7536b247b1a5860e"),
        .init(path: "speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc/model.mil", byteCount: 193092, sha256: "423c358915acab0d440c99f5162c17456936c2c02f7394b05ab226b9a34c122a"),
        .init(path: "speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc/weights/weight.bin", byteCount: 1520986, sha256: "75ff1725ef4e58dacf9176466ec274a8a13a6132c296d6b571fb78ddad5455c4"),
    ]
    private let requestKey = "meeting.speakers.preparation.requested.v1"
    private let disabledKey = "meeting.speakers.preparation.disabled.v1"
    private var installation: Task<Void, Never>?
    private var current: Status = .absent
    private var verified: URL?
    private var checkedDisk = false
    private var epoch = UUID()
    enum Failure: Error { case invalidPack }

    func status() -> Status {
        #if !canImport(SpeakerKit)
        return .unsupported
        #else
        if !checkedDisk, installation == nil {
            checkedDisk = true
            if let folder = try? destination(), (try? verifyPack(folder)) != nil {
                verified = folder; current = .ready
            }
        }
        return current
        #endif
    }
    func readyFolder() throws -> URL {
        guard case .ready = status(), let verified else { throw Failure.invalidPack }
        return verified
    }
    func requestIfNeeded(explicit: Bool = false) {
        #if canImport(SpeakerKit)
        guard installation == nil, status() != .ready else { return }
        if explicit { UserDefaults.standard.set(false, forKey: disabledKey) }
        guard !UserDefaults.standard.bool(forKey: disabledKey) else { return }
        UserDefaults.standard.set(true, forKey: requestKey)
        let token = UUID(); epoch = token; current = .downloading(0)
        installation = Task { [self] in
            do {
                let folder = try await install(token: token)
                guard epoch == token else { return }
                verified = folder; current = .ready; checkedDisk = true
                UserDefaults.standard.set(false, forKey: requestKey)
            } catch is CancellationError {
                if epoch == token { current = .absent }
            } catch {
                if epoch == token { current = .failed(IDELanguageRunText.t("说话人模型准备未完成，可重试。", "Speaker preparation is unfinished. Try again.")) }
            }
            if epoch == token { installation = nil }
        }
        #endif
    }
    func restoreInstallation() {
        if UserDefaults.standard.bool(forKey: requestKey) { requestIfNeeded() }
    }
    func cancelPreparation() async {
        UserDefaults.standard.set(false, forKey: requestKey)
        UserDefaults.standard.set(true, forKey: disabledKey)
        let task = installation
        task?.cancel(); await task?.value
        // The existing coordinator persists resume data for this exact URL;
        // unrelated speech/model transfers and committed files are untouched.
    }
    private func base() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FloeAgent/SpeechModels/MeetingSpeakers", isDirectory: true)
    }
    private func destination() throws -> URL { try base().appendingPathComponent(Self.revision, isDirectory: true) }
    private func install(token: UUID) async throws -> URL {
        let base = try base(), destination = try destination()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let staging = base.appendingPathComponent(".download-" + Self.revision, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try requireDirectory(base); try requireDirectory(staging)
        if let free = try base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < Self.totalBytes * 2 { throw CocoaError(.fileWriteOutOfSpace) }
        let ledger = ModelDownloadSettlementLedger(); defer { ledger.drain() }
        var completed: Int64 = 0
        for (index, asset) in Self.assets.enumerated() {
            try Task.checkCancellation()
            guard epoch == token else { throw CancellationError() }
            let target = staging.appendingPathComponent(asset.path)
            try requireParents(target, below: staging)
            if (try? verify(target, asset: asset)) != nil { completed += asset.byteCount; continue }
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            let previous = completed
            let temporary = try await WhisperDownloadCoordinator.shared.download(asset.url, ledger: ledger) { [weak self] bytes in
                Task { await self?.progress(previous + min(bytes, asset.byteCount), token: token) }
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            try verify(temporary, asset: asset)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try requireParents(target, below: staging)
            try FileManager.default.moveItem(at: temporary, to: target)
            completed += asset.byteCount
            progress(completed, token: token)
            if index < Self.assets.count - 1 { ledger.checkpoint() }
        }
        try Task.checkCancellation()
        try Data(Self.revision.utf8).write(to: staging.appendingPathComponent("installed.json"), options: .atomic)
        try verifyPack(staging)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else { try FileManager.default.moveItem(at: staging, to: destination) }
        return destination
    }
    private func progress(_ bytes: Int64, token: UUID) {
        guard epoch == token else { return }
        current = .downloading(min(1, max(0, Double(bytes) / Double(Self.totalBytes))))
    }
    private func verifyPack(_ folder: URL) throws {
        try requireDirectory(folder)
        guard try String(contentsOf: folder.appendingPathComponent("installed.json"), encoding: .utf8) == Self.revision else { throw Failure.invalidPack }
        for asset in Self.assets {
            let file = folder.appendingPathComponent(asset.path)
            try requireParents(file, below: folder)
            try verify(file, asset: asset)
        }
    }
    private func requireDirectory(_ directory: URL) throws {
        let value = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard value.isDirectory == true, value.isSymbolicLink != true else { throw Failure.invalidPack }
    }
    private func requireParents(_ file: URL, below root: URL) throws {
        var directory = file.deletingLastPathComponent()
        let prefix = root.standardizedFileURL.path + "/"
        while directory.standardizedFileURL.path.hasPrefix(prefix) {
            if FileManager.default.fileExists(atPath: directory.path) { try requireDirectory(directory) }
            directory.deleteLastPathComponent()
        }
        guard directory.standardizedFileURL == root.standardizedFileURL else { throw Failure.invalidPack }
        try requireDirectory(root)
    }
    private func verify(_ file: URL, asset: Asset) throws {
        let value = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard value.isRegularFile == true, value.isSymbolicLink != true, Int64(value.fileSize ?? -1) == asset.byteCount else { throw Failure.invalidPack }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256 else { throw Failure.invalidPack }
    }
}
#endif
