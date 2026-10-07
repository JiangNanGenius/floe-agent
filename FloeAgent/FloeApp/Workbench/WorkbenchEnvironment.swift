// FloeApp — Workbench environment wiring.
//
// Builds the AI bridge from the EXISTING app services (configured image
// providers through ConversationCenter, durable video jobs through
// MediaGenerationService) and registers the `media.project` tool against the
// workbench center. No new provider integrations; prices are never invented.

import Foundation
import FloeCore
import FloePersistence
import FloeProviders
import FloeTools
import FloeWorkbench

extension WorkbenchAIBridge {
    /// Live bridge over the app's configured providers and durable jobs.
    @MainActor
    static func live(environment: AppEnvironment) -> WorkbenchAIBridge {
        WorkbenchAIBridge(
            isAvailable: { [weak environment] in
                await MainActor.run {
                    guard let environment else { return false }
                    return !environment.conversationCenter.agentVideoRoutes().isEmpty
                        || !environment.conversationCenter.imageModels.isEmpty
                }
            },
            imageModels: { [weak environment] in
                guard let environment else { return [] }
                let center = environment.conversationCenter
                let providers = center.providers
                return center.imageModels.compactMap { model in
                    guard let provider = providers.first(where: { $0.id == model.providerID }),
                          provider.isEnabled,
                          ImageProviderAdapterFactory().adapter(for: provider) != nil else { return nil }
                    return WorkbenchAIModelInfo(id: model.id,
                                                displayName: model.displayName ?? model.remoteModelID,
                                                remoteModelID: model.remoteModelID,
                                                providerName: provider.displayName ?? provider.kind.rawValue)
                }
            },
            videoModels: { [weak environment] in
                guard let environment else { return [] }
                let center = environment.conversationCenter
                return center.agentVideoRoutes().map { route in
                    WorkbenchAIModelInfo(id: route.modelID, displayName: route.displayName,
                                         remoteModelID: route.remoteModelID,
                                         providerName: route.providerName)
                }
            },
            generateImages: { [weak environment] prompt, modelID, size, count, sourceURL in
                guard let environment else {
                    throw FloeError.invalidConfiguration("App environment unavailable")
                }
                let center = environment.conversationCenter
                var sources: [Data] = []
                if let sourceURL {
                    let accessing = sourceURL.startAccessingSecurityScopedResource()
                    defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
                    let data = try Data(floeContentsOf: sourceURL)
                    guard data.count <= 12 * 1_024 * 1_024 else {
                        throw FloeError.validationFailed("Source image exceeds 12 MiB")
                    }
                    sources = [data]
                }
                let operation: RemoteImageOperation = sources.isEmpty ? .generate : .edit
                let selection = ImageGenerationSelection(nativeSizeOverride: size)
                let routed = try await center.performAgentImage(
                    operation: operation, prompt: prompt, sourceImages: sources,
                    modelID: modelID, selection: selection, count: count)
                guard !routed.0.images.isEmpty else {
                    throw FloeError.internalError("The image provider returned no image")
                }
                return try Self.writeCandidates(routed.0.images, extension: "png")
            },
            submitVideo: { [weak environment] prompt, modelID, options, projectID, _ in
                guard let environment else {
                    throw FloeError.invalidConfiguration("App environment unavailable")
                }
                let center = environment.conversationCenter
                let model = try await Self.requireVideoModel(modelID: modelID, center: center)
                var generationOptions = VideoGenerationOptions()
                generationOptions.durationSeconds = options.durationSeconds.map(Int.init)
                generationOptions.aspectRatio = options.aspectRatio
                generationOptions.resolution = options.resolution
                let request = RemoteVideoRequest(prompt: prompt, modelRemoteID: model.remoteModelID,
                                                 options: generationOptions)
                let submission = try await environment.mediaGenerationService.submitVideo(
                    modelID: modelID, owner: .document(projectID), originRunID: nil,
                    request: request, idempotencyKey: "workbench:\(projectID.uuidString):\(UUID().uuidString)")
                return submission.job.id
            },
            refreshJob: { [weak environment] jobID in
                guard let environment else { throw FloeError.invalidConfiguration("App environment unavailable") }
                _ = try await environment.mediaGenerationService.refreshVideoJob(jobID: jobID)
                return await Self.describeJob(jobID: jobID, environment: environment)
            },
            cancelJob: { [weak environment] jobID in
                guard let environment else { throw FloeError.invalidConfiguration("App environment unavailable") }
                try await environment.mediaGenerationService.cancelVideo(jobID: jobID)
            },
            jobs: { [weak environment] projectID in
                guard let environment else { return [] }
                let store = MediaGenerationJobStore(database: environment.database)
                let owned = (try? await store.allOwnedJobs(limit: 100)) ?? []
                var result: [WorkbenchAIJobInfo] = []
                for entry in owned where entry.owner.kind == .document && entry.owner.id == projectID {
                    result.append(Self.describe(entry, environment: environment))
                }
                return result.sorted { $0.isActive && !$1.isActive }
            },
            deliverResult: { [weak environment] jobID in
                guard let environment else { throw FloeError.invalidConfiguration("App environment unavailable") }
                return try await Self.deliver(jobID: jobID, environment: environment)
            },
            costNote: { _ in
                FloeLocalized.t(
                    "实际费用以供应商账户账单为准；Floe 不推算价格。",
                    "Actual charges appear on your provider account; Floe does not estimate prices.")
            }
        )
    }

    @MainActor private static func requireVideoModel(modelID: UUID, center: ConversationCenter) async throws -> ModelProfile {
        let routes = center.agentVideoRoutes()
        guard let route = routes.first(where: { $0.modelID == modelID }) else {
            throw FloeError.invalidConfiguration(
                FloeLocalized.t("所选视频模型当前不可用或未配置适配器。",
                                "The selected video model is not enabled with a configured adapter."))
        }
        return try await Self.modelProfile(id: route.modelID, center: center)
    }

    @MainActor private static func modelProfile(id: UUID, center: ConversationCenter) async throws -> ModelProfile {
        guard let model = center.videoModels.first(where: { $0.id == id }) else {
            throw FloeError.invalidConfiguration("model \(id.uuidString) is unavailable")
        }
        return model
    }

    @MainActor private static func describeJob(jobID: UUID, environment: AppEnvironment) async -> WorkbenchAIJobInfo {
        let store = MediaGenerationJobStore(database: environment.database)
        guard let owned = try? await store.ownedJob(id: jobID) else {
            return WorkbenchAIJobInfo(id: jobID, state: "unknown", progress: nil,
                                      message: nil, isActive: false, isWaitStopped: false,
                                      modelName: "")
        }
        return describe(owned, environment: environment)
    }

    @MainActor private static func describe(_ owned: OwnedMediaGenerationJob, environment: AppEnvironment) -> WorkbenchAIJobInfo {
        let state = owned.job.state
        let active = !state.isTerminal
        return WorkbenchAIJobInfo(
            id: owned.job.id,
            state: state.rawValue,
            progress: state == .running ? 0.5 : nil,
            message: owned.job.lastError,
            isActive: active,
            isWaitStopped: false,
            modelName: "")
    }

    @MainActor private static func writeCandidates(_ images: [Data], extension fileExtension: String) throws -> [URL] {
        let root = WorkbenchPaths.mediaRoot(preferred: WorkspaceCenter.toolRootProvider())
        let directory = root.appendingPathComponent("Workbench/Candidates", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (index, data) in images.enumerated() {
            let url = directory.appendingPathComponent("candidate-\(UUID().uuidString.prefix(8))-\(index).\(fileExtension)")
            try data.write(to: url, options: .atomic)
            urls.append(url)
        }
        return urls
    }

    @MainActor private static func deliver(jobID: UUID, environment: AppEnvironment) async throws -> URL {
        let store = MediaGenerationJobStore(database: environment.database)
        guard let owned = try? await store.ownedJob(id: jobID),
              owned.job.state == .ready,
              let localAssetID = owned.job.localAssetID,
              let asset = try? await environment.creativeAssetStore.asset(id: localAssetID),
              let relative = asset.localRelativePath else {
            throw FloeError.validationFailed(
                FloeLocalized.t("生成任务尚未完成，暂无可导入的结果。",
                                "The generation job is not ready; there is no result to import yet."))
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: false)
        let source = support.appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw FloeError.notFound("generated asset \(relative)")
        }
        let root = WorkbenchPaths.mediaRoot(preferred: WorkspaceCenter.toolRootProvider())
        let directory = root.appendingPathComponent("Workbench/Candidates", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("video-\(jobID.uuidString.prefix(8))-\(source.lastPathComponent)")
        let staging = directory.appendingPathComponent(".floe-candidate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        return destination
    }
}

enum FloeLocalized {
    static func t(_ zh: String, _ en: String) -> String {
        Locale.current.identifier.hasPrefix("zh") ? zh : en
    }
}

func registerWorkbenchTools(center: WorkbenchCenter, registry: ToolRunnerRegistry = .shared) {
    ToolCatalog.register(MediaProjectTool.self)
    registry.register(MediaProjectTool(host: center))
}
