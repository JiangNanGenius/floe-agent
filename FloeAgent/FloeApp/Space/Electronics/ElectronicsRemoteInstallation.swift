// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import ZIPFoundation
import FloeCore
import FloeSkills
import FloeElectronicsCore
import FloeElectronicsUI
import FloeCAD

/// App-owned adapter from the verified remote catalogue to the native library.
/// It reads the exact original file from the already-verified per-library ZIP
/// (never a model path), builds one small immutable package in Core, installs
/// through the store CAS and reads the exact native reference back.
enum ElectronicsRemoteInstallSupport {
    nonisolated static let maximumOriginalBytes = 32 * 1_024 * 1_024
    nonisolated static let maximumLicenseBytes = 1_048_576
    nonisolated static let maximumNestedArchiveBytes = 64 * 1_024 * 1_024

    static func install(service: ElectronicsRemoteService, library: EDLibraryController,
                        libraryID: String, partID: String,
                        progress: ElectronicsRemoteProgress,
                        cancelled: @escaping @Sendable () -> Bool = { false }) async throws -> ElectronicsRemoteInstallResult {
        try Task.checkCancellation()
        guard !cancelled() else { throw CancellationError() }
        let material = try await service.partMaterial(libraryID: libraryID, id: partID, progress: progress)
        guard !cancelled() else { throw CancellationError() }
        // Nested ZIP extraction is bounded but can be tens of MiB; keep it off
        // the main actor. The detached handle is cancelled and joined with the
        // caller before any native commit.
        let sourcePath = material.record.sourcePath
        let archiveURL = material.libraryArchiveURL
        let originalsEntryName = material.originalsArchiveEntry
        let expectedOriginals = material.source.originals
        guard expectedOriginals.bytes <= maximumNestedArchiveBytes else {
            throw ElectronicsRemoteInstallError.budget("the selected original-source archive exceeds its byte budget")
        }
        let worker = Task.detached(priority: .utility) { () async throws -> [String: Data] in
            try Task.checkCancellation()
            guard !cancelled() else { throw CancellationError() }
            let originalsEntry = try await ElectronicsRemoteTool.readArchiveEntry(archiveURL, originalsEntryName)
            guard originalsEntry.count == expectedOriginals.bytes,
                  ElectronicsRemoteDigest.sha256(originalsEntry) == expectedOriginals.sha256 else {
                throw ElectronicsRemoteInstallError.integrity("the verified library's original-source archive changed")
            }
            let archive: Archive
            do { archive = try Archive(data: originalsEntry, accessMode: .read) }
            catch { throw ElectronicsRemoteInstallError.integrity("the verified original-source archive cannot be opened") }
            guard let source = try readEntry(archive, "originals/" + sourcePath, maximum: maximumOriginalBytes, cancelled: cancelled) else {
                throw ElectronicsRemoteInstallError.integrity("the publisher original file is absent from the verified archive")
            }
            var files = [sourcePath: source]
            if let license = try readEntry(archive, "originals/LICENSE.md", maximum: maximumLicenseBytes, cancelled: cancelled) {
                files["LICENSE.md"] = license
            }
            if let license = try readEntry(archive, "licenses/CC-BY-SA-4.0.txt", maximum: maximumLicenseBytes, cancelled: cancelled) {
                files["licenses/CC-BY-SA-4.0.txt"] = license
            }
            return files
        }
        let files: [String: Data]
        do {
            files = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            guard !cancelled() else { throw CancellationError() }
        } catch {
            worker.cancel(); _ = try? await worker.value
            throw error
        }
        let verified = ElectronicsRemotePartMaterial(libraryID: material.libraryID, record: material.record,
            recordJSON: material.recordJSON, recordSHA256: material.recordSHA256, source: material.source,
            libraryArchiveURL: material.libraryArchiveURL, modelRecords: material.modelRecords,
            originalFiles: files)
        _ = try await library.prepare()
        let revision = try await library.store.inventory().revision
        let result = try await ElectronicsRemoteInstaller.install(material: verified, into: library.store,
            expectedInventoryRevision: revision, cancelled: cancelled)
        try await library.refresh()
        return result
    }

    nonisolated private static func readEntry(_ archive: Archive, _ path: String, maximum: Int,
                                             cancelled: @Sendable () -> Bool) throws -> Data? {
        try Task.checkCancellation()
        guard !cancelled() else { throw CancellationError() }
        guard ElectronicsRemoteValidation.safeRelativePath(path),
              let entry = archive[path], entry.type == .file else { return nil }
        guard entry.uncompressedSize <= UInt32(maximum) else {
            throw ElectronicsRemoteInstallError.integrity("archive entry \(path) exceeds its byte budget")
        }
        var data = Data(); data.reserveCapacity(Int(entry.uncompressedSize))
        _ = try archive.extract(entry) { chunk in
            try Task.checkCancellation()
            guard !cancelled() else { throw CancellationError() }
            guard data.count <= maximum - chunk.count else {
                throw ElectronicsRemoteInstallError.integrity("archive entry \(path) exceeds its byte budget")
            }
            data.append(chunk)
        }
        return data
    }
}

/// Shared UI/AI adapter over the verified catalogue. Long installs are owned by
/// this App object; a dismissed sheet cannot orphan or duplicate one silently.
@MainActor final class ElectronicsRemoteLibraryService: EDRemoteLibraryServing {
    private let policyStore: GitHubTransportMirrorPolicyStore
    private let cacheRootProvider: @Sendable () throws -> URL
    private let manifestDownload: @Sendable () async throws -> GitHubTransportMirrorPolicyStore.Downloaded

    init(policyStore: GitHubTransportMirrorPolicyStore,
         cacheRootProvider: @escaping @Sendable () throws -> URL,
         manifestDownload: @escaping @Sendable () async throws -> GitHubTransportMirrorPolicyStore.Downloaded) {
        self.policyStore = policyStore
        self.cacheRootProvider = cacheRootProvider
        self.manifestDownload = manifestDownload
    }

    private func service() async throws -> ElectronicsRemoteService {
        let policy = await policyStore.policyForTransfer(download: manifestDownload)
        let network = ElectronicsRemoteTool.network(policy: policy.roles,
            archiveReader: ElectronicsRemoteTool.readArchiveEntry)
        return ElectronicsRemoteService(storeRoot: try cacheRootProvider(), network: network)
    }

    private func library() throws -> EDLibraryController { try ElectronicsLibraryService.shared() }

    func status() async throws -> ElectronicsRemoteStatus { try await service().status() }

    func refresh(progress: ElectronicsRemoteProgress) async throws -> ElectronicsRemoteRefreshReceipt {
        try await service().refresh(progress: progress)
    }

    func searchLibraries(text: String, offset: Int, limit: Int) async throws -> ElectronicsRemoteLibraryPage {
        try await service().searchLibraries(.init(text: text, offset: offset, limit: limit))
    }

    func searchParts(libraryID: String, text: String, kind: String?, status: String?,
                     offset: Int, limit: Int, progress: ElectronicsRemoteProgress) async throws -> ElectronicsRemotePartPage {
        try await service().searchParts(libraryID: libraryID,
            query: .init(text: text, kind: kind, status: status, offset: offset, limit: limit), progress: progress)
    }

    func searchModels(text: String, format: String?, offset: Int, limit: Int) async throws -> ElectronicsRemoteModelPage {
        try await service().searchModels(.init(text: text, format: format, offset: offset, limit: limit))
    }

    func install(libraryID: String, partID: String,
                 progress: ElectronicsRemoteProgress) async throws -> ElectronicsRemoteInstallResult {
        try await ElectronicsRemoteInstallSupport.install(service: try await service(), library: try library(),
            libraryID: libraryID, partID: partID, progress: progress)
    }

    func downloadModel(id: String, progress: ElectronicsRemoteProgress) async throws -> ElectronicsRemoteModelReceipt {
        try await service().downloadModel(id: id, progress: progress)
    }

    func isModelCached(reference: EDAFootprintModelReference) async -> Bool {
        guard let root = try? cacheRootProvider() else { return false }
        let store = ElectronicsRemoteStore(root: root)
        return await store.cachedModel(reference: reference) != nil
    }
}

/// Bridges the UI cancellation token to the one global gated CAD importer.
private nonisolated final class ElectronicsModelCancellationBridge: MeshImportCancellationChecking, @unchecked Sendable {
    let token: EDBoard3DModelCancellation
    init(token: EDBoard3DModelCancellation) { self.token = token }
    var isCancelled: Bool { token.isCancelled }
}

/// Reads only App-owned verified model cache bytes, then asks the coordinator-
/// owned exact CAD bridge for bounded millimetre mesh values. No CAD document,
/// kernel handle, URL or host path crosses into Core/UI.
struct AppElectronicsBoard3DModelLoader: EDBoard3DModelLoading {
    let cacheRootProvider: @Sendable () throws -> URL

    func loadModel(_ reference: EDAFootprintModelReference,
                   cancellation token: EDBoard3DModelCancellation) async throws -> EDBoard3DModelGeometry {
        guard !token.isCancelled else { throw EDBoard3DModelLoadError.cancelled }
        guard reference.isExactRenderable else {
            throw EDBoard3DModelLoadError.unsupportedFormat(reference.format)
        }
        let root = try cacheRootProvider()
        let store = ElectronicsRemoteStore(root: root)
        guard let cached = await store.cachedModel(reference: reference) else {
            throw EDBoard3DModelLoadError.notDownloaded
        }
        guard let size = try? cached.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= CADImportedModelMeshLoader.maximumInputBytes else {
            throw EDBoard3DModelLoadError.invalidGeometry
        }
        let data = try Data(contentsOf: cached.url, options: [.mappedIfSafe])
        guard data.count <= CADImportedModelMeshLoader.maximumInputBytes else {
            throw EDBoard3DModelLoadError.invalidGeometry
        }
        guard !token.isCancelled else { throw EDBoard3DModelLoadError.cancelled }
        let cancellation = MeshImportCancellation(observed: ElectronicsModelCancellationBridge(token: token))
        let value: CADImportedModelGeometry
        do {
            value = try await withTaskCancellationHandler {
                try await CADImportedModelMeshLoader.loadExactOffMain(data: data, format: reference.format,
                    fileName: reference.fileName, cancellation: cancellation)
            } onCancel: {
                token.cancel(); cancellation.cancel()
            }
        } catch {
            if token.isCancelled || error is CancellationError { throw EDBoard3DModelLoadError.cancelled }
            throw EDBoard3DModelLoadError.invalidGeometry
        }
        guard !token.isCancelled else { throw EDBoard3DModelLoadError.cancelled }
        guard !value.meshes.isEmpty, value.triangleCount > 0, value.bufferBytes > 0 else {
            throw EDBoard3DModelLoadError.invalidGeometry
        }
        let parts = value.meshes.map {
            EDBoard3DModelPart(name: $0.name, positions: $0.positions, normals: $0.normals, indices: $0.indices)
        }
        return EDBoard3DModelGeometry(parts: parts, triangleCount: value.triangleCount, bufferBytes: value.bufferBytes)
    }
}
#endif
