// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeMedia
import FloeWorkbench

/// App-owned seam to the SAME shared `ModelArtifactStore` used by the
/// existing signed-catalog path. No parallel installer, weight cache or
/// credential store is introduced; imports go through `installLocalBundle`
/// and reads through the store's installed records filtered to capability
/// `audio.separate.vocals`. The synchronous snapshot exists only so the
/// existing capability list can answer availability without awaiting; every
/// operation refreshes from the store first.
@MainActor enum MediaV2StemLocalBridge {
    struct Model: Sendable, Hashable, Identifiable {
        let id: String
        let version: String
        let license: String?
    }
    struct Handlers {
        /// Live read of installed compatible stem bundles from the store.
        let installed: @Sendable () async -> [Model]
        /// The verified install root for one installed compatible model, or
        /// nil when it is not installed in the shared store.
        let resolve: @Sendable (String) async -> URL?
        /// Security-scoped directory import through the same store. The UI
        /// starts/stops scoped access around the call.
        let importBundle: @MainActor @Sendable (URL) async throws -> Model
        let remove: @MainActor @Sendable (String) async throws -> Void
    }
    private static var handlers: Handlers?
    private static var cache: [Model] = []
    static func install(_ value: Handlers) { handlers = value }
    /// Scoped dependency replacement for focused tests and temporary states.
    static func withTemporaryHandlers<Result: Sendable>(_ value: Handlers?,
        operation: @MainActor () async throws -> Result) async rethrows -> Result {
        let previous = handlers, previousCache = cache
        handlers = value; cache = []
        defer { handlers = previous; cache = previousCache }
        return try await operation()
    }
    static var isConfigured: Bool { handlers != nil }
    /// Synchronous availability answer for the existing capability list.
    static var installedSnapshot: [Model] { cache }
    static func refresh() async { cache = await handlers?.installed() ?? [] }
    /// Fresh read for operation starts.
    static func models() async -> [Model] { await refresh(); return cache }
    static func resolve(_ id: String) async -> URL? { await handlers?.resolve(id) }
    @MainActor static func importBundle(_ directory: URL) async throws -> Model {
        guard let handlers else {
            throw MediaPreparedCoreError.invalidOperation("Model storage is not connected yet")
        }
        let model = try await handlers.importBundle(directory)
        await refresh()
        return model
    }
    @MainActor static func remove(_ id: String) async throws {
        guard let handlers else {
            throw MediaPreparedCoreError.invalidOperation("Model storage is not connected yet")
        }
        try await handlers.remove(id)
        await refresh()
    }
    /// The single installed bundle used when the user/AI selects the local
    /// route without naming a model. Ambiguity is reported, never guessed.
    @MainActor static func automaticModel() async -> Model? {
        let fresh = await models()
        return fresh.count == 1 ? fresh[0] : nil
    }
}

/// The AppEnvironment install seam: the SAME shared `ModelArtifactStore`
/// instance the signed catalog path already uses.
enum MediaV2StemLocalInstaller {
    static let capability = "audio.separate.vocals"
    static func handlers(store: ModelArtifactStore) -> MediaV2StemLocalBridge.Handlers {
        .init(
            installed: {
                let records = await store.installed()
                return records.filter { $0.capability == capability }
                    .map { MediaV2StemLocalBridge.Model(id: $0.id, version: $0.version, license: $0.license) }
                    .sorted { $0.id < $1.id }
            },
            resolve: { identifier in
                guard let record = await store.installed(id: identifier), record.capability == capability,
                      FileManager.default.fileExists(atPath: record.rootPath) else { return nil }
                return URL(fileURLWithPath: record.rootPath).standardizedFileURL
            },
            importBundle: { directory in
                let record = try await store.installLocalBundle(at: directory, scope: .shared)
                guard record.capability == capability else {
                    try? await store.remove(id: record.id)
                    throw MediaPreparedCoreError.invalidOperation(
                        WorkbenchText.t("该目录不是兼容的人声分离模型包。", "That folder is not a compatible voice-separation model bundle."))
                }
                return MediaV2StemLocalBridge.Model(id: record.id, version: record.version, license: record.license)
            },
            remove: { identifier in
                guard let record = await store.installed(id: identifier), record.capability == capability else {
                    throw MediaV2CommandError.invalidInput
                }
                try await store.remove(id: identifier)
            })
    }
}
#endif
